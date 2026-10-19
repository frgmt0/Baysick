# Baysick — notes for agents

Dartmouth BASIC, Second Edition (Oct 1964, incl. MAT matrix statements) compiler in arm64
assembly (Apple `as` syntax), macOS/arm64. Two targets:
`arm64-macos` (default, full pipeline) and `x86_64-linux` (cross: emits GNU `as` x86_64 text;
assembled/linked on Linux against `src/runtime_x86_64_linux/`, DESIGN.md §5.4, §6.4, §8).

## Read first
- `docs/LANGUAGE.md` — what programs must do (output bytes, errors, exit codes). Normative.
- `docs/DESIGN.md` — module boundaries, file ownership, conventions, CLI, runtime ABI.
- `docs/IR.md` — IR opcodes, canonical lowering, `--emit-ir` format.
- `include/*.inc` — the binary contract (layouts, opcodes, error codes, limits).
- `docs/BENCH.md` — matrix kernel benchmarks (workloads, methodology, goals).

## Invariants
- **Contract rule:** a layout, opcode, error code, limit or symbol shared between modules changes
  only by editing `include/*.inc` AND the matching doc section in the same change. Never
  hard-code an offset or constant that has a name in an include file.
- Module ownership (DESIGN.md §2): `src/frontend/`, `src/ir/`+`src/driver/`,
  `src/backend/arm64_macos/`, `src/runtime/`, `src/backend/x86_64_linux/`,
  `src/runtime_x86_64_linux/`, cross testing (`Makefile.linux`, `tests/cross*.sh`, CI),
  benchmarks (`bench/`). Do not edit another module's files. MAT work split: DESIGN.md §2.1.
- MAT contract staging: `OP_COUNT`/`KW_COUNT` switch with `BSK_MAT_CONTRACT`; build with
  `make clean && make BSK_MAT=1 test` until the integration step (DESIGN.md §2.2) removes it.
- Matrix kernels: GEMM may reassociate/use FMA (class R); every other MAT result must be
  bit-identical across targets and kernel variants (class E, DESIGN.md §6.6.4). Test products use
  exact data only. Never use undocumented CPU instructions; vendor BLAS is for `bench/` only.
- Error message text lives only in `include/errors.inc` (`BSK_EMIT_ERRMSG_TABLE`).
- Include files are shared with GNU `as`: `//` comments only at the start of a line, trailing
  comments as `/* ... */`, parenthesised macro conditions (DESIGN.md §3.4).
- Expected test outputs are derived from LANGUAGE.md, never from "what the implementation
  prints". If they disagree, the implementation is wrong unless the spec is changed on purpose.
  Both targets must pass the same `tests/programs` and run-phase `tests/errors` byte for byte.
- No TODOs, stubs or placeholder values.

## Commands
- Build: `make`   Test: `make test` (or `sh tests/run.sh [-v] [pattern]`)
- Include check: `make check-includes` (Mac); `make -f Makefile.linux check-includes` (Linux)
- Kernel variant: `BAYSICK_KERNELS=<variant|baseline> sh tests/run.sh`
- Benchmarks: `make bench` (Mac, vs Accelerate), `make bench-cross` (Linux host, vs OpenBLAS)
- x86_64 cross test: `make cross` / `sh tests/cross.sh [-v] [-H host] [pattern]` (ssh host,
  default `desktop`); `make cross-pack` builds `build/x86_64-linux-bundle` only;
  on Linux: `sh tests/cross_run.sh [-v] BUNDLE_DIR`, runtime: `make -f Makefile.linux`.
- Tools: Mac: `as`, `ld`, `ar`, `xcrun` (+ `ssh`, `tar` for cross testing; `xcrun cc` for
  `bench/` only). Linux: GNU `as`, `ar`, `make`, `gcc` (link only; and the bench harness with
  OpenBLAS). Python, if ever needed, via `uv` only.
- Never set a bogus `SDKROOT`/`DEVELOPER_DIR` on the Mac.

## Assembly style (compiler and arm64 runtime; x86_64 runtime: DESIGN.md §6.4.4)
- AAPCS64 (Apple) for every global function; never touch `x18`; 16-byte `sp`; frame record
  (`stp x29, x30`) in every non-leaf function; variadic args (snprintf) go on the stack.
- Header comment on every function: purpose, inputs, outputs, clobbers, callee-saved registers
  used and their role, frame size.
- A comment at least every few instructions explaining intent.
- Global symbols carry the module prefix (`_fe_ _ir_ _drv_ _ob_ _bk_arm64_ _bk_x64_ _bsk_`);
  local labels `L<module>_<function>_<what>`; numeric labels only for short skips.
- Every source file starts with `.include "baysick.inc"`; `//` comments; 4-space indent.
