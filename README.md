[![CI](https://github.com/frgmt0/Baysick/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/frgmt0/Baysick/actions/workflows/ci.yml)

# Baysick

Baysick is a compiler for Dartmouth BASIC, written in arm64 assembly for macOS. It covers the
language from Kemeny and Kurtz's fifteen-statement 1964 version through the Sixth Edition of
1971. The original Dartmouth compiler was hand-written in GE-225 assembly, so writing this one
in assembly seemed fair.

It also has a second job. Baysick is the implementation language of the compiler for
[Sea](https://github.com/frgmt0/Sea), a matrix language, so a 1960s teaching language ends up
compiling a modern one. Three small extensions that no Dartmouth edition had make that
practical: `LINPUT`, `PRINT #-1` to standard error, and `END e` / `STOP e` with an exit status.

```
10 FOR X = 7 TO 100 STEP 7
20 PRINT X, SQR(X)
30 NEXT X
40 END
```

`baysick prog.bas` turns this into a native executable. The lexer and parser build a small,
target-independent IR, which is documented. The backend turns the IR into arm64 assembly text,
and the system `as` and `ld` link it with the Baysick runtime library (also arm64 assembly).
Output follows the 1964 formatting rules: five 15-column print zones, six significant digits,
`1.` for non-integers that round to a whole number, `E` form below 0.1, and the rest.

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

`MAT` statements (READ, PRINT, `+ - *`, `(K)*`, ZER, CON, IDN, TRN, INV) work on whole lists and
tables. The kernels behind them are hand-written SIMD assembly: NEON on arm64, SSE2 and AVX2
with FMA on x86_64. A program picks the best variant its CPU supports when it starts. The
kernels are benchmarked against Apple Accelerate and OpenBLAS (`docs/BENCH.md`).

## Status

The current version is 0.6.0. `baysick --version` prints:

```
baysick 0.6.0 (Dartmouth BASIC, Sixth Edition 1971, with Baysick extensions)
```

There are two targets. `arm64-macos` is the default and runs the whole pipeline on the Mac.
`x86_64-linux` is a cross target: the compiler still runs on the Mac and emits GNU `as` x86_64
assembly, which is assembled and linked on an x86_64 Linux machine against an x86_64 runtime,
also hand-written assembly. That target is specified in `docs/DESIGN.md` §5.4, §6.4 and §8. Its
backend is in `src/backend/x86_64_linux/` and its runtime in `src/runtime_x86_64_linux/`. Module
ownership is in `docs/DESIGN.md` §2.

Every edition below is implemented on both targets.

The 1964 language and the Second Edition's `MAT` statements came first.

The Third and Fourth Editions add strings, `INPUT`, `ON … GO TO`, `TAB`, `CHANGE`, multi-line
`DEF` and `MAT INPUT`. They are specified in `docs/LANGUAGE.md` §3–§14, with page references to
the 1968 manual, and in `docs/IR.md` and `docs/DESIGN.md` (§2.2–§2.3, §5.3–§5.4, §6.7). Tests:
`tests/programs/ed4_*`, `manual4_*`, `text_*`, `tests/errors/c_ed4_*`, `r_ed4_*` and
`tests/ir/ed4_*`.

The Fifth Edition (1970) adds sequential files (`FILES`, `PRINT #`, `INPUT #`, `IF END #`,
`SCRATCH #`, `RESTORE #`), `LEN ASC STR$ VAL`, string `DEF` functions and two-dimensional string
arrays. Spec: `docs/LANGUAGE.md` ("The Fifth Edition", §4.4–§4.6, §6.1, §7.10.1, §7.21–§7.26),
`docs/IR.md` §3.3 and `docs/DESIGN.md` (§2.2, §2.4, §5.3–§5.4, §6.8, §8.5). Tests:
`tests/programs/ed5_*`, `manual5_*`, `tests/errors/c_ed5_*`, `r_ed5_*` and `tests/ir/ed5_*`.

The Sixth Edition (1971) adds `SEG$`, `POS`, the concatenation operator `&`, and
`CALL`/`SUB`/`SUBEND` subprograms. Subprogram parameters are passed by reference, variables are
private, and recursion works. Spec: `docs/LANGUAGE.md` ("The Sixth Edition", §4.6, §6.2, §7.27),
`docs/IR.md` §3.4 and `docs/DESIGN.md` (§2.2, §2.5, §5.3–§5.4, §6.9). Tests:
`tests/programs/ed6_*`, `manual6_*`, `tests/errors/c_ed6_*`, `r_ed6_*` and `tests/ir/ed6_*`.

The Baysick extensions are not part of any edition. `LINPUT [#k,] A$` reads a line verbatim,
and `IF END #` tests for the end of input. `PRINT #-1` writes to standard error. `END e` and
`STOP e` end the program with exit status e (0–255). Spec: `docs/LANGUAGE.md` §15, `docs/IR.md`
§3.5 and `docs/DESIGN.md` (§2.2, §2.6, §6.10, §8.6). Tests: `tests/programs/ext_*`,
`tests/errors/c_ext_*`, `r_ext_*` and `tests/ir/ext_*`.

The runtime also exports a matrix kernel API for Sea. It needed no language change. Besides
GEMM it has `_bsk_kern_gemm_sub` (C ← C − A·B), and both pass ±∞ and NaN through by the IEEE
rules (`docs/DESIGN.md` §2.7, §6.6.4).

## Documents

* `docs/LANGUAGE.md`: the normative language spec (statements, MAT, number format, errors,
  limits). It is based on the October 1964 Dartmouth manual and the 1968 Fourth Edition manual.
  The Dartmouth Fifth Edition manual is unavailable, so that part follows the 1970 GE MARK II
  BASIC manual. The Sixth Edition manual is also unavailable; that part rests on the designers'
  histories and programs of the period. Every deviation is marked "Baysick decision".
* `docs/DESIGN.md`: modules and file ownership, conventions, CLI, backend interface, the runtime
  ABI for both targets, the Linux build and the cross-test setup.
* `docs/IR.md`: the IR opcodes and layouts, canonical lowering, the `--emit-ir` text format, and
  how to write a new backend.
* `docs/BENCH.md`: matrix benchmarks, with workloads, methodology, the vendor comparison and
  goals.
* `docs/SEA_BOOTSTRAP.md`: what the Sea compiler needed from the language it is written in, and
  how each need was met (by a later Dartmouth edition, a Baysick extension, or left out on
  purpose).
* `include/*.inc`: the binary contract shared by all modules.

## Build and test

You need an Apple Silicon Mac with the Xcode command line tools (`as`, `ld`, `ar`, `xcrun`).

```
make                 # build/baysick and build/libbaysickrt.a
make test            # include-file check, build, tests/run.sh, kernel conformance test
make check-includes  # only the include-file check
make kern-check      # only the kernel conformance test
make bench           # matrix kernel benchmarks vs Accelerate (docs/BENCH.md)
make clean
```

On the Mac, `make test` runs 463 corpus tests (136 programs, 311 error tests, 16 IR tests) and
then the kernel conformance test.

A compiled program reads `BAYSICK_KERNELS` from its environment to choose a matrix kernel
variant: `baseline`, or a variant name such as `neon` or `avx2`. Without it, the program uses
the best variant the CPU supports (`docs/DESIGN.md` §6.6).

Usage:

```
build/baysick prog.bas [-o prog] [-S] [--emit-ir] [--target arm64-macos|x86_64-linux] [--keep-temps]
```

The compiler looks for its runtime next to itself (`build/libbaysickrt.a`) unless
`BAYSICK_RUNTIME` names another path.

### Test layout

* `tests/programs`: `NAME.bas`, the expected `NAME.out`, and optionally `NAME.err`.
* `tests/errors`: `NAME.meta` with the phase and exit status, `NAME.err`, and optionally
  `NAME.out`.
* `tests/ir`: `NAME.ir`, the expected `--emit-ir` dump.
* `tests/kern`: `kern_check.c`, a C program that links the runtime archive and checks the
  kernel API (GEMM and gemm_sub) on every usable variant, ±∞ and NaN inputs included
  (`docs/DESIGN.md` §8.7).

A program or error test may have a `NAME.in` file. It becomes the program's standard input on
both targets; without one, standard input is `/dev/null`. A test may also have a `NAME.files/`
directory of fixtures, copied into its fresh working directory, and a `NAME.expect/` directory
of files that must exist afterwards. A run-phase `.meta` may add `streams=merged` (standard
error goes to the same file as standard output) or `streams=no-stdout` (standard output is
closed). See `docs/DESIGN.md` §8.5–§8.6.

### x86_64-linux

`build/baysick --target x86_64-linux prog.bas` writes `prog.s`, x86_64 GNU assembler text, and
runs no tools. To finish the job you need an x86_64 Linux machine with GNU `as`, `ar`, `make`
and `gcc`. Build the runtime once from a checkout, then assemble and link:

```
make -f Makefile.linux                       # build-x86_64-linux/libbaysickrt.a
as --64 -o prog.o prog.s
gcc -no-pie -o prog prog.o build-x86_64-linux/libbaysickrt.a -lm
```

Cross testing compiles on the Mac, then assembles, links and runs on the Linux machine over
`ssh`. Nothing is left behind on the remote machine.

```
make cross                                   # sh tests/cross.sh, host "desktop"
sh tests/cross.sh -H otherhost [-v] [PATTERN...]
make cross-pack                              # only build build/x86_64-linux-bundle (used by CI)
make bench-cross                             # kernel benchmarks on the Linux host vs OpenBLAS
```

The cross run has 268 tests: the 136 programs, the 131 run-phase error tests, and the kernel
conformance test.

CI has two jobs. On `macos-14` it checks the include files, builds, runs `make test` and packs
the x86_64 bundle. An `ubuntu-latest` job then downloads that bundle, with no checkout of its
own, and runs `tests/cross_run.sh` on it, so Linux tests exactly what the Mac packed.

## Sea

Sea is a matrix language with C/Rust-like syntax, meant as an alternative to MATLAB. Its design
was agreed on 2026-10-20 and it is being built in the `sea/` submodule
([frgmt0/Sea](https://github.com/frgmt0/Sea)). The Sea compiler is a chain of Baysick programs,
with code generators for arm64 and x86_64. The core language works on both targets and the
linear algebra is under way; `sea/README.md` has the current status. When Sea needs something
Baysick lacks, it goes into Baysick: from a later Dartmouth edition where one has it, otherwise
as a labelled Baysick extension.
