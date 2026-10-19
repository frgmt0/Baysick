# Baysick — notes for agents

Dartmouth BASIC (1964) compiler in arm64 assembly (Apple `as` syntax), macOS/arm64.

## Read first
- `docs/LANGUAGE.md` — what programs must do (output bytes, errors, exit codes). Normative.
- `docs/DESIGN.md` — module boundaries, file ownership, conventions, CLI, runtime ABI.
- `docs/IR.md` — IR opcodes, canonical lowering, `--emit-ir` format.
- `include/*.inc` — the binary contract (layouts, opcodes, error codes, limits).

## Invariants
- **Contract rule:** a layout, opcode, error code, limit or symbol shared between modules changes
  only by editing `include/*.inc` AND the matching doc section in the same change. Never
  hard-code an offset or constant that has a name in an include file.
- Module ownership (DESIGN.md §2): `src/frontend/`, `src/ir/`+`src/driver/`,
  `src/backend/arm64_macos/`, `src/runtime/`. Do not edit another module's files.
- Error message text lives only in `include/errors.inc` (`BSK_EMIT_ERRMSG_TABLE`).
- Expected test outputs are derived from LANGUAGE.md, never from "what the implementation
  prints". If they disagree, the implementation is wrong unless the spec is changed on purpose.
- No TODOs, stubs or placeholder values.

## Commands
- Build: `make`   Test: `make test` (or `sh tests/run.sh [-v] [pattern]`)
- Include check: `make check-includes`
- Tools: only `as`, `ld`, `ar`, `xcrun`. Python, if ever needed, via `uv` only.

## Assembly style
- AAPCS64 (Apple) for every global function; never touch `x18`; 16-byte `sp`; frame record
  (`stp x29, x30`) in every non-leaf function; variadic args (snprintf) go on the stack.
- Header comment on every function: purpose, inputs, outputs, clobbers, callee-saved registers
  used and their role, frame size.
- A comment at least every few instructions explaining intent.
- Global symbols carry the module prefix (`_fe_ _ir_ _drv_ _ob_ _bk_arm64_ _bsk_`); local labels
  `L<module>_<function>_<what>`; numeric labels only for short skips.
- Every source file starts with `.include "baysick.inc"`; `//` comments; 4-space indent.
