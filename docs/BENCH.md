# Baysick Matrix Benchmarks

**Status: normative** for the benchmark harness (`bench/`, owner BENCH, `docs/DESIGN.md` §2):
what is measured, how, against what, and how results are reported. The kernels themselves are
specified in `docs/DESIGN.md` §6.6; their semantics in `docs/LANGUAGE.md` §7.14.

Baysick's matrix kernels are hand-written assembly (NEON on arm64-macos, SSE2 on x86_64-linux,
§6.6). The benchmarks measure them honestly against the platform's vendor library — **Apple
Accelerate** on the Mac, **OpenBLAS** on Linux — and against the measured peak of the
instruction set the kernel uses. The vendor libraries are only the measuring bar: the harness
links them, Baysick programs and the Baysick runtime never do.

## 1. What a fair comparison is

* **Single-threaded on both sides.** Baysick kernels are single-threaded; the harness forces the
  vendor library to one thread (`VECLIB_MAXIMUM_THREADS=1` set before the first Accelerate call;
  `openblas_set_num_threads(1)` and `OPENBLAS_NUM_THREADS=1` on Linux).
* **Same data, same shapes, same layout.** Row-major doubles with a row stride (`MV_LD`)
  equal to the column count; the vendor calls use `CblasRowMajor` with the same leading dimension.
* **Two bars per kernel**, always both reported:
  1. **vs vendor** — the vendor library's time for the same operation;
  2. **vs peak** — the measured peak floating-point rate of the instruction set the Baysick
     variant uses (§3.4): NEON f64 FMA peak on arm64; SSE2 `mulpd`+`addpd` peak for `sse2`
     (and the AVX2 FMA peak for the `avx2` variant).
* **On Apple M1–M3, Accelerate uses Apple's matrix hardware**, which hand-written NEON code
  cannot use, so "vs Accelerate" there is not a like-for-like contest; "vs NEON f64 peak" is the
  measure of the NEON kernel's quality. On Linux, OpenBLAS uses the best SIMD the CPU has (AVX2
  and FMA on the Haswell test machine, four times the SSE2 multiply-add peak), so a correct SSE2
  kernel cannot exceed about a quarter of OpenBLAS's GEMM rate; again "vs SSE2 peak" judges the
  kernel. Both numbers are printed side by side, with no adjustment.

## 2. Workloads

All matrices are square `n × n` unless stated; data are deterministic pseudo-random doubles in
`[-1, 1)` from the generator `s := (6364136223846793005·s + 1442695040888963407) mod 2⁶⁴`,
value `= (s >> 11) · 2⁻⁵² − 1`, seed 1964, filled row by row (A first, then B).

| Kernel | Baysick entry | Sizes | Vendor (macOS / Linux) | Rate unit (work) |
|--------|---------------|-------|------------------------|------------------|
| GEMM `C = A·B` | `_bsk_kern_gemm` | n = 64, 128, 256, 512, 1024, 2048; odd n = 127, 255, 1023 | `cblas_dgemm` (α = 1, β = 0) / same | GFLOP/s (`2n³`) |
| add `C = A + B` | `_bsk_kern_add` | n = 64, 256, 1024, 2048 | `vDSP_vaddD` / `cblas_dcopy` + `cblas_daxpy` (proxy, labelled) | GB/s (`24n²` bytes) |
| sub `C = A − B` | `_bsk_kern_sub` | same | `vDSP_vsubD` / same proxy with α = −1 | GB/s (`24n²`) |
| scale `C = k·A` | `_bsk_kern_scale` | same | `vDSP_vsmulD` / `cblas_dcopy` + `cblas_dscal` | GB/s (`16n²`) |
| transpose | `_bsk_kern_trn` | n = 64, 256, 1024, 2048 | `vDSP_mtransD` / `cblas_domatcopy` (`CblasTrans`) | GB/s (`16n²`) |
| INV | `_bsk_kern_inv` | n = 100, 250, 500, 1000 | LAPACK `dgetrf` + `dgetri` (Accelerate's LAPACK / OpenBLAS's) | GFLOP/s (nominal `2n³` for both) |
| end-to-end | compiled BASIC programs `bench/programs/e2e_*.bas` | as written | none | wall seconds |

INV inputs are the random matrix plus `n·I` (diagonally dominant, well conditioned), so every
implementation succeeds and the comparison measures speed only. The nominal `2n³` count is the
work of both Gauss–Jordan and LU-plus-inverse, so the two rates are comparable.

End-to-end programs (written in Baysick's own BASIC, compiled with `build/baysick`, timed as
whole processes): `e2e_gemm.bas` (fills two `400 × 400` tables with small integers by LET
loops, computes `MAT C = A * B` ten times, prints an exact integer checksum), `e2e_inv.bas`
(`MAT B = INV(A)` of a `300 × 300` diagonally dominant table five times, then `MAT C = A * B` and
prints the number of elements of C that differ from the identity by more than 1E-9 — 0),
`e2e_mixed.bas` (MAT READ from DATA, `+ − (K)* TRN`, MAT PRINT of a summary row). Their outputs
are exact by construction, so they are the same on every target and variant. They show what a
BASIC user experiences, including the scalar fill loops.

## 3. Methodology

### 3.1 Timing

* Clock: `clock_gettime(CLOCK_MONOTONIC)` (both systems; nanosecond resolution).
* Per measurement: one untimed warm-up call (it also faults in the buffers), then repetitions
  until both **at least 5 repetitions** and **at least 1.0 s** of total time have elapsed (at most
  1000); each repetition is timed separately. The reported time is the **median** repetition;
  the minimum and maximum are written to the TSV file too.
* **Batching of very short calls.** If a single call takes less than 100 µs (measured on a warm-up
  call), each timed repetition runs the call back to back `ceil(100 µs / t)` times (at most
  100000) and records the batch time divided by the batch size, so the clock resolution does not
  dominate microsecond kernels. This is legitimate because every call is identical and independent
  (the output is fully overwritten, inputs are unmodified; there is no state to carry between
  calls), so the per-call mean over a batch measures the same quantity as one call. It is not
  applied to a measurement that has an untimed prepare step (the vendor INV call, which needs a
  fresh input before every call).
* Rate = work / median time (GFLOP/s or GB/s, 10⁹ units).
* The output matrix is fully overwritten each repetition (GEMM: β = 0), so repetitions are
  independent; inputs are not modified (INV works on a copy for the vendor call, whose `dgetrf`
  destroys its input: the copy is made outside the timed region).
* Process placement: on macOS the harness sets `pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)`
  so it runs on performance cores; on Linux it pins itself to CPU 1 with `sched_setaffinity`.
  The machine should otherwise be idle; the harness prints the 1-minute load average before and
  after and warns (does not fail) if it exceeds 1.0.

### 3.2 Validation (before timing, every size, every variant)

The harness refuses to report a number for a wrong result (exit status 1, message naming the
kernel, variant and size):

* GEMM: every element `|c − c_ref| ≤ 2·k·2⁻⁵³·Σ|a||b|` against the vendor result (the `Σ|a||b|`
  term is computed by a plain C loop for n ≤ 512; above that the bound
  `2·k·2⁻⁵³·k·max|a|·max|b|` is used).
* add, sub, scale, transpose: **bit-for-bit** equality with a plain C reference loop compiled
  with `-ffp-contract=off` (class E, DESIGN.md §6.6.4); the vendor result must agree too. The scale
  kernel uses the factor k = 0.1 (inexact in binary, so the multiplication rounds).
* INV: bit-for-bit equality with the baseline variant's result (class E), except that a position
  where both values are zero compares equal whatever their signs (the sign of a zero element is
  unspecified, LANGUAGE.md §7.14.6, DESIGN.md §6.6.4); and `max|X − X_ref| ≤ 10⁻⁸·max|X_ref|`
  against the vendor inverse.
* Every non-baseline variant is additionally compared with the baseline: bit-identical for the
  class-E kernels, within the GEMM bound for GEMM.
* End-to-end programs: their stdout must equal `bench/programs/NAME.out` (derived like any test
  output, from LANGUAGE.md; the checksums are exact by construction).

### 3.3 Variants

The harness calls `_bsk_kern_init`, then measures **every usable variant** listed by
`_bsk_kern_variants()` (switching with `_bsk_kern_use`), so a new kernel (DESIGN.md §6.6.7)
appears in the results without harness changes. End-to-end programs run for every variant (3 repetitions, median; 1 in quick mode) with
`BAYSICK_KERNELS=<variant>` in their environment.

### 3.4 Peak measurement

`bench/peak_arm64.s` (Apple `as`) and `bench/peak_x86_64.s` (GNU `as`) contain timed loops of
independent floating-point operations with no memory traffic:

* arm64: 24 independent accumulator chains of `fmla v.2d` — enough to cover the FMA latency on
  all four pipes of a P-core; peak = 4 flops per `fmla` × instructions / second;
* x86_64 SSE2: 12 independent chains of `mulpd` + `addpd` pairs (2 flops per pair per lane);
* x86_64 AVX2+FMA (only if the CPU has it, the bar for the `avx2` variant):
  12 chains of `vfmadd231pd ymm`.

The peak loop runs 0.5 s after a 0.2 s warm-up; the best of 5 runs is the peak. Reported as
GFLOP/s with the instruction set's name. (For orientation: an M2 Pro P-core at about 3.5 GHz
issues four 2-lane FMAs per cycle, about 56 GFLOP/s; the Haswell i7-4790 at 3.6–4.0 GHz issues
one `addpd` and one `mulpd` per cycle with SSE2, about 14–16 GFLOP/s, and two 4-lane FMAs per cycle
with AVX2, about 58–64 GFLOP/s. The harness reports what it measures, not these figures.)

## 4. Harness and commands

| Path | Content |
|------|---------|
| `bench/bench.c` | the harness (C, one file for both systems: `#ifdef __APPLE__` selects Accelerate vs OpenBLAS); links `libbaysickrt.a` and calls only the `_bsk_kern_*` API |
| `bench/peak_arm64.s`, `bench/peak_x86_64.s` | peak loops (§3.4) |
| `bench/programs/e2e_*.bas`, `.out` | end-to-end programs and their expected stdout |
| `bench/run_mac.sh` | macOS driver: builds the harness, runs it, runs the e2e programs, writes the report |
| `bench/cross.sh` | macOS → Linux driver, same shape as `tests/cross.sh` |

The harness is C because it is a measuring instrument, not part of Baysick; it must not include
any Baysick logic beyond calling the kernel API (so it measures exactly what BASIC programs run).
The runtime's link isolation (DESIGN.md §6.6.1) lets it link the archive with its own `main`.

**`make bench`** (macOS; depends on `all`): `sh bench/run_mac.sh`. Compiles
`xcrun cc -O2 -ffp-contract=off -o build/bench/bench bench/bench.c bench/peak_arm64.s
build/libbaysickrt.a -framework Accelerate` (`-DACCELERATE_NEW_LAPACK` for the LAPACK
prototypes), runs it, compiles and times the e2e programs with `build/baysick`, and writes
`build/bench/arm64-macos.tsv` plus the human-readable report on stdout.

**`make bench-cross`** (macOS; depends on `all`): `sh bench/cross.sh [-H HOST]` (host as for
`tests/cross.sh`: `-H`, else `$BAYSICK_CROSS_HOST`, else `desktop`). It packs `include/`,
`src/runtime_x86_64_linux/`, `Makefile.linux`, `bench/` and the e2e programs compiled with
`--target x86_64-linux`, streams them over **one** `ssh` call into a `mktemp -d` directory that
is removed on exit (as `tests/cross.sh` does, nothing is left behind), builds the runtime with
`make -f Makefile.linux`, compiles `gcc -O2 -ffp-contract=off -no-pie -o bench bench/bench.c
bench/peak_x86_64.s build-x86_64-linux/libbaysickrt.a -lopenblas -lm`, runs it, and copies the
TSV back to `build/bench/x86_64-linux.tsv`. **OpenBLAS is required on the host** (`libopenblas`
with its `cblas.h` and LAPACK symbols; Arch: `pacman -S openblas`, Debian/Ubuntu:
`apt install libopenblas-dev`). The harness checks that the BLAS it linked is OpenBLAS (it calls
`openblas_get_config()`, which reference BLAS does not have); if not, `bench-cross` stops with
`bench-cross: OpenBLAS not found on <host>` and exit status 2 — it never reports a "vendor"
number from the reference BLAS. The `desktop` host has OpenBLAS 0.3.34.

`BENCH_QUICK=1` (environment) limits sizes to n ≤ 512 (INV n ≤ 250) and the time per measurement
to 0.2 s, for a smoke run. Exit status: 0 measured and validated; 1 a validation failure;
2 setup error (missing compiler, vendor library, host).

**Drivers in detail.**

* `sh bench/run_mac.sh [--vendor-only]`: `--vendor-only` builds the harness without the Baysick
  runtime (`-DBENCH_VENDOR_ONLY`; no archive or compiler needed) and runs only the peak loops, the
  Accelerate calls and the vendor-versus-C-reference validation, as a self-test of the measuring
  instrument. Without it the script needs `build/libbaysickrt.a` and `build/baysick` (run `make`
  first) and checks that the archive exports the `_bsk_kern_*` API.
* `sh bench/run_linux.sh BUNDLE_DIR` is the Linux half, run by `bench/cross.sh` on the host from
  the unpacked bundle. It probes for OpenBLAS (status 42 if missing), builds the runtime with
  `Makefile.linux`, builds and runs the harness and the e2e programs, and, only when the harness
  succeeded, prints the TSV between the lines `@@BENCH-TSV-BEGIN@@` and `@@BENCH-TSV-END@@`.
  `bench/cross.sh` passes everything else through and writes the lines between the markers to
  `build/bench/x86_64-linux.tsv`.
* Host selection for `make bench-cross`: `make bench-cross BENCH_CROSS_ARGS='-H HOST'` (the
  arguments go to `bench/cross.sh`; default as described above).
* Harness options (`bench/bench.c`): `--tsv FILE` writes the TSV rows (§5); `--e2e DIR` also times
  the compiled programs `DIR/e2e_gemm`, `e2e_inv`, `e2e_mixed` for every usable variant (3
  repetitions each, the median is reported; 1 repetition in quick mode, `BENCH_QUICK=1`), checking
  the stdout of every repetition against `DIR/NAME.out`; `--only LIST` restricts the run to a comma-separated subset
  of `peak gemm add sub scale trn inv e2e`.

`make bench` is never part of `make test` or CI (timings on shared CI machines are meaningless).

## 5. Output

Report on stdout: a header, then one block per kernel:

```
# baysick bench  target=arm64-macos  cpu="Apple M2 Pro"  features=-  variants=neon
# peak: neon-fma 55.8 GFLOP/s   vendor: Accelerate (single thread)   load 0.21/0.25
kernel  variant  n     median_s     baysick   vendor   %vendor  peak    %peak
gemm    neon     1024  0.0472300    45.47     ...      ...      55.8    81.5
```

(`baysick`/`vendor`/`peak` columns in the kernel's rate unit; `%peak` only for GFLOP/s rows;
values above are an illustration of the layout, not results.)

TSV file (`build/bench/<target>.tsv`), one row per measurement, tab-separated, header row:

```
target  cpu  kernel  variant  m  n  k  reps  median_s  min_s  max_s  unit  baysick_rate  vendor_rate  pct_vendor  peak_rate  pct_peak
```

(`k` = inner dimension for GEMM, 0 otherwise; `vendor_rate`/`pct_vendor` empty for end-to-end
rows; `peak_rate`/`pct_peak` empty for GB/s rows.)

## 6. Initial goals (stated honestly)

Goals are reported, not enforced by exit status; they are the bar for accepting the baseline
kernels and any later variant. "Peak" is the §3.4 measurement on the same machine.

| Kernel | Goal (baseline variant) | Expected vs vendor |
|--------|-------------------------|--------------------|
| GEMM, n ≥ 512 | **≥ 70 %** of peak (stretch 85 %) | Mac: well below Accelerate on M1–M3 (matrix hardware); Linux: ≤ about 25 % of OpenBLAS (AVX2+FMA vs SSE2) |
| GEMM, n = 64–256 | ≥ 50 % of peak | — |
| GEMM, odd n | within 10 % of the neighbouring even size's rate | — |
| add, sub, scale | ≥ 80 % of the vendor GB/s at every size | — |
| transpose | ≥ 50 % of the vendor GB/s, n ≥ 256 | — |
| INV | correct; ≥ 25 % of vendor at n = 100 | unblocked Gauss–Jordan (pinned for bit-reproducibility, LANGUAGE.md §7.14.6) is matrix-vector bound; blocked LU (vendor) pulls ahead as n grows — expect 3–10× slower at n = 1000 |
| end-to-end | reported only | — |

A future `sme` GEMM variant on M4 and later is judged against the SME f64 peak the harness then
measures (an `fmopa`-based peak loop added with the variant) and against Accelerate.

### 6.1 The `avx2` variant (x86_64-linux)

Judged against the AVX2-FMA peak (§3.4) and OpenBLAS, with the same goals as the table above
(GEMM ≥ 70 % of *its* peak for n ≥ 512, stretch 85 %), plus: every class-E kernel bit-identical
to `sse2` (§3.2), and the variant as a whole faster than `sse2` (DESIGN.md §6.6.7, step 5).

Measured with `make bench-cross` on the `desktop` host (i7-4790 Haswell, OpenBLAS 0.3.34
single-threaded; peaks measured by the harness: `sse2` 15.9, `avx2-fma` 57.3 GFLOP/s; all
variants validated before timing; 1-minute load 0.68 before, 1.16 after — the harness's own
single busy thread):

| n | GEMM `avx2` GFLOP/s | % of AVX2-FMA peak | % of OpenBLAS | `sse2` GFLOP/s |
|---|---------------------|--------------------|---------------|----------------|
| 64 | 37.9 | 66.0 | 110.5 | 13.1 |
| 127 | 40.4 | 70.4 | 112.7 | 13.6 |
| 128 | 41.8 | 72.9 | 102.2 | 13.9 |
| 255 | 46.2 | 80.6 | 109.4 | 14.7 |
| 256 | 47.3 | 82.5 | 103.0 | 14.8 |
| 512 | 47.9 | 83.6 | 100.8 | 14.7 |
| 1023 | 46.8 | 81.7 | 99.6 | 14.7 |
| 1024 | 48.6 | 84.8 | 101.4 | 14.9 |
| 2048 | 49.7 | 86.7 | 101.1 | 14.9 |

GEMM goal met (worst 81.7 % of peak for n ≥ 512; the 85 % stretch is reached only at n = 2048: 86.7 %, while n = 1024 gives 84.8 %),
at parity with OpenBLAS's Haswell kernel, 3.3× the `sse2` kernel. The peak and the `avx2` kernels
run at the CPU's AVX frequency (3.6 GHz instead of 4.0 GHz on this machine: Haswell lowers the
clock while 256-bit floating-point arithmetic executes), which is why `sse2` reaches a higher
fraction of *its* peak.

| Kernel | `avx2` vs `sse2` (same n) | Notes |
|--------|---------------------------|-------|
| transpose | +26 % (64), +79 % (256), +39 % (1024), +24 % (2048) | 4 × 4 in-register tiles; moves and shuffles only, so no AVX clock reduction |
| copy, fill | specialised in `avx2` (256-bit) but not benchmarked | pure moves: no floating-point arithmetic, so no AVX clock reduction, and the harness has no copy/fill workload |
| add, sub, scale | the `avx2` variant uses the `sse2` kernels (equal by construction; the table slots point at them) | a 256-bit version was +11 % (add, sub) / +15 % (scale) at n = 64 but −8 % / −5 % at n = 256 and only ±2 % from DRAM: in L2/L3 the loop is cache-bandwidth bound and Haswell's reduced clock during 256-bit FP arithmetic (4.0 → 3.6 GHz, which also lingers into the surrounding scalar code) costs more than the width gains, so it was removed |
| INV | +40 % (100), +38 % (250), +54 % (500), +51 % (1000) | 4 × 12 delayed-update micro-kernel; 77 % of OpenBLAS at n = 100, 36 % at n = 1000 |
| end-to-end | `e2e_gemm` 0.037 s vs 0.096 s; `e2e_inv` 0.030 s vs 0.043 s | |
