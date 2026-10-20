[![CI](https://github.com/frgmt0/Baysick/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/frgmt0/Baysick/actions/workflows/ci.yml)

# Baysick

Baysick is a faithful re-implementation of **Dartmouth BASIC through the Fifth Edition (1970)** —
the fifteen statements of Kemeny and Kurtz's 1964 language, the Second Edition's `MAT` matrix
statements, the Third and Fourth Editions' strings, `INPUT`, `ON … GO TO`, `TAB`, `CHANGE`,
multi-line `DEF`, `MAT INPUT`, …, and the Fifth Edition's sequential files, `LEN ASC STR$ VAL`,
string `DEF` functions and string tables — as a native compiler written in modern **arm64
assembly** for macOS, much as the original compiler was hand-written in GE-225 assembly.

```
10 FOR X = 7 TO 100 STEP 7
20 PRINT X, SQR(X)
30 NEXT X
40 END
```

`baysick prog.bas` turns this into a native executable: source → lexer/parser → a small,
documented, target-independent IR → arm64 assembly text → the system `as` and `ld` → a program
linked with the Baysick runtime library (also arm64 assembly). Output formatting reproduces the
1964 rules: five 15-column print zones, six significant digits, `1.` for non-integers that round
to whole numbers, `E` form below 0.1, and so on.

```
10 DIM A(20,20), B(20,20), C(20,20)
20 READ M, N
30 MAT READ A(M,N), B(N,N)
40 MAT C = A * B
50 MAT PRINT C;
60 MAT B = INV(B)
70 MAT PRINT B
80 DATA 2, 3, 1, 2, 3, 4, 5, 6, 2, 0, 0, 0, 1, 0, 0, 0, 4
90 END
```

`MAT` (READ, PRINT, `+ - *`, `(K)*`, ZER, CON, IDN, TRN, INV) works on whole lists and tables.
Its kernels are hand-written SIMD assembly (NEON on arm64, SSE2 on x86_64) selected at startup
by CPU feature, and are benchmarked against Apple Accelerate and OpenBLAS (`docs/BENCH.md`).

## Status

Two targets:

* **`arm64-macos`** (default) — complete: `make test` passes the whole corpus.
* **`x86_64-linux`** — cross target: the compiler, still running on the Mac, emits GNU `as`
  x86_64 assembly; it is assembled and linked on an x86_64 Linux machine against an x86_64
  runtime (also hand-written assembly). Specified in `docs/DESIGN.md` §5.4, §6.4 and §8; the
  backend (`src/backend/x86_64_linux/`) and runtime (`src/runtime_x86_64_linux/`) are
  implemented and cross-tested with `make cross` against all program and run-phase error tests
  (module split: `docs/DESIGN.md` §2).

Third and Fourth Edition: implemented on both targets. Specified in `docs/LANGUAGE.md` (§3–§14,
with page references to the 1968 manual), `docs/IR.md` and `docs/DESIGN.md` (§2.2–§2.3,
§5.3–§5.4, §6.7); the binary contract is in `include/*.inc`. Their tests are
`tests/programs/ed4_*`, `manual4_*`, `text_*`, `tests/errors/c_ed4_*`, `r_ed4_*` and
`tests/ir/ed4_*`.

Fifth Edition (1970): implemented on both targets — sequential files (`FILES`, `PRINT #`,
`INPUT #`, `IF END #`, `SCRATCH #`, `RESTORE #`), `LEN ASC STR$ VAL`, string `DEF` functions and
two-dimensional string arrays. Specified in `docs/LANGUAGE.md` ("The Fifth Edition", §4.4–§4.6,
§6.1, §7.10.1, §7.21–§7.26), `docs/IR.md` §3.3 and `docs/DESIGN.md` (§2.2, §2.4, §5.3–§5.4,
§6.8, §8.5). Its tests are `tests/programs/ed5_*`, `manual5_*`, `tests/errors/c_ed5_*`,
`r_ed5_*` and `tests/ir/ed5_*`.

Sixth Edition (1971): specified, being implemented — `SEG$`, `POS`, `&` and `CALL`/`SUB`/`SUBEND`
subprograms (`docs/LANGUAGE.md` "The Sixth Edition", §6.2, §7.27; work packages `docs/DESIGN.md`
§2.5; tests `ed6_*`, `manual6_*`, `c_ed6_*`, `r_ed6_*`, `tests/ir/ed6_*`, expected to fail until
then).

## Documents

* `docs/LANGUAGE.md` — normative language spec (statements, MAT, number format, errors,
  limits), based on the October 1964 Dartmouth manual, the 1968 (Fourth Edition) manual and
  (for the Fifth Edition, the Dartmouth manual being unavailable) the 1970 GE MARK II BASIC
  manual, with every deviation marked "Baysick decision".
* `docs/DESIGN.md` — modules and file ownership, conventions, CLI, backend interface, runtime ABI
  for both targets, the Linux build and the cross-test setup.
* `docs/IR.md` — the IR: opcodes, layouts, canonical lowering, `--emit-ir` text format, and how
  to write a new backend.
* `docs/BENCH.md` — matrix benchmarks: workloads, methodology, vendor comparison, goals.
* `docs/SEA_BOOTSTRAP.md` — what writing the Sea compiler in BASIC would need, which edition to
  implement next, and whether stdin/stdout through INPUT and PRINT is enough.
* `include/*.inc` — the binary contract shared by all modules.

## Build and test

Requirements: Apple Silicon Mac, Xcode command line tools (`as`, `ld`, `ar`, `xcrun`).

```
make                 # build/baysick and build/libbaysickrt.a
make test            # assemble-check include files, build, run tests/run.sh
make check-includes  # only the include-file check
make bench           # matrix kernel benchmarks vs Accelerate (docs/BENCH.md)
make clean
```

`BAYSICK_KERNELS=baseline` (or a variant name such as `neon`) in a compiled program's
environment selects its matrix kernel variant; the default picks the best one the CPU supports
(`docs/DESIGN.md` §6.6).

Usage:

```
build/baysick prog.bas [-o prog] [-S] [--emit-ir] [--target arm64-macos|x86_64-linux] [--keep-temps]
```

The compiler looks for its runtime next to itself (`build/libbaysickrt.a`) unless
`BAYSICK_RUNTIME` names another path.

Tests live in `tests/programs` (`NAME.bas`, expected `NAME.out`, optional `NAME.err`),
`tests/errors` (`NAME.meta` with phase and exit status, `NAME.err`, optional `NAME.out`) and
`tests/ir` (`NAME.ir`, the expected `--emit-ir` dump). A program or error test may have a
`NAME.in` file, which becomes the program's standard input (otherwise `/dev/null`), on both
targets.

### x86_64-linux

`build/baysick --target x86_64-linux prog.bas` writes `prog.s` (x86_64 GNU assembler text) and
runs no tools. On an x86_64 Linux machine with GNU `as`, `ar`, `make` and `gcc`, build the
runtime once from a checkout and link:

```
make -f Makefile.linux                       # build-x86_64-linux/libbaysickrt.a
as --64 -o prog.o prog.s
gcc -no-pie -o prog prog.o build-x86_64-linux/libbaysickrt.a -lm
```

Cross testing from the Mac (compile here, assemble/link/run there over `ssh`, nothing left
behind on the remote machine):

```
make cross                                   # sh tests/cross.sh, host "desktop"
sh tests/cross.sh -H otherhost [-v] [PATTERN...]
make cross-pack                              # only build build/x86_64-linux-bundle (used by CI)
make bench-cross                             # kernel benchmarks on the Linux host vs OpenBLAS
```

CI runs `make test` on macOS, packs the bundle, and runs it on an `ubuntu-latest` x86_64 job.

## Future

* Long-term: use Baysick to bootstrap **Sea**, a fast matrix language (a MATLAB alternative with
  C/Rust-like syntax). MAT is the stepping stone: the matrix runtime, the IR matrix operations and
  the SIMD kernels with CPU-feature dispatch exist on both targets. `docs/SEA_BOOTSTRAP.md`
  analyses what a compiler written in BASIC needs: the Fourth Edition's strings and INPUT are
  not enough on their own; the Fifth Edition (files, string functions), now implemented, covers
  the rows it marks.
