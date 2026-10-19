# Baysick

Baysick is a faithful re-implementation of **Dartmouth BASIC, First Edition (1964)** — the
fifteen-statement language of Kemeny and Kurtz — as a native compiler written in modern
**arm64 assembly** for macOS, much as the original compiler was hand-written in GE-225
assembly.

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

## Status

The design phase is complete: the language specification, architecture, IR, contract include
files, build system and test corpus exist; the compiler and runtime sources are being written
(see `docs/DESIGN.md` §2 for the module split). Until then `make` stops with a message saying
which modules are missing.

## Documents

* `docs/LANGUAGE.md` — normative language spec (statements, number format, errors, limits),
  based on the 1964 Dartmouth manual, with every deviation marked "Baysick decision".
* `docs/DESIGN.md` — modules and file ownership, conventions, CLI, backend interface, runtime ABI,
  and how an x86_64-linux port would work.
* `docs/IR.md` — the IR: opcodes, layouts, canonical lowering, `--emit-ir` text format, and how
  to write a new backend.
* `include/*.inc` — the binary contract shared by all modules.

## Build and test

Requirements: Apple Silicon Mac, Xcode command line tools (`as`, `ld`, `ar`, `xcrun`).

```
make                 # build/baysick and build/libbaysickrt.a
make test            # assemble-check include files, build, run tests/run.sh
make check-includes  # only the include-file check
make clean
```

Usage:

```
build/baysick prog.bas [-o prog] [-S] [--emit-ir] [--target arm64-macos] [--keep-temps]
```

The compiler looks for its runtime next to itself (`build/libbaysickrt.a`) unless
`BAYSICK_RUNTIME` names another path.

## Future

* An `x86_64-linux` backend emitting GNU assembler text to be assembled on an x86_64 Arch Linux
  machine, plus a matching runtime (`docs/DESIGN.md` §7).
* Long-term: use Baysick as the foundation for **Sea**, an implementation of C.
