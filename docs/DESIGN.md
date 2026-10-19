# Baysick Design

**Status: normative** for module boundaries, file ownership, calling conventions, the CLI, the
backend interface and the runtime ABI. Language behaviour: `docs/LANGUAGE.md`. IR:
`docs/IR.md`. Binary layouts and constants: `include/*.inc` (the contract files).

## 1. Pipeline

```
 prog.bas ──► driver: read file ──► frontend (_fe_compile)
                                      │  lines → compaction → sort → scan/parse → lower
                                      ▼
                                   IR Module (src/ir builder, in arena memory)
                                      │  _ir_verify
                 ┌────────────────────┼─────────────────────────┐
           --emit-ir                  ▼                          │
           _ir_dump → text     backend BKD_EMIT → OutBuf (assembly text)
                                      │
                         write <tmp>/prog.s   (or the -S output)
                                      │
                    posix_spawnp  as -arch arm64 … -o prog.o prog.s
                    posix_spawnp  ld -o prog prog.o libbaysickrt.a -lSystem …
                                      ▼
                             native executable (runtime's _main → _bsk_program)
```

The compiler (`build/baysick`) and the runtime (`build/libbaysickrt.a`) are both hand-written
arm64 assembly for Apple's assembler. They use libSystem (libc/libm) as the system interface.

## 2. Repository layout and ownership

Four implementers work in parallel. **Each owns only its directory**; it may add, split or
rename files *inside* its directory (the Makefile globs `*.s`). Nobody edits another module's
files. The only shared files are `include/*.inc` (read-only for implementers; changed only by
the architect together with the docs).

| Module | Owner | Directory | Exports (Mach-O symbols) |
|--------|-------|-----------|--------------------------|
| Frontend | implementer F | `src/frontend/` | `_fe_compile` |
| IR + Driver | implementer D | `src/ir/`, `src/driver/` | `_main` (compiler), `_ir_*` (ir.inc), `_drv_alloc`, `_drv_fatal`, `_ob_*` (driver.inc), `_drv_targets` |
| Backend | implementer B | `src/backend/arm64_macos/` | `_bk_arm64_macos_desc` |
| Runtime | implementer R | `src/runtime/` | everything in runtime.inc "defined by the runtime" |

Required initial file split (owners may refine within their directory):

```
src/frontend/fe_compile.s   _fe_compile: orchestration, error unwinding, phase-3 checks
src/frontend/fe_lines.s     physical lines, compaction, line numbers, replace/delete, sort
src/frontend/fe_scan.s      scanner (tokens.inc), constants via _strtod
src/frontend/fe_expr.s      expression parser + lowering (IR.md §4.2)
src/frontend/fe_stmt.s      statement parsers + lowering (IR.md §4.3–4.4), FOR/NEXT stack
src/ir/ir_build.s           builder API (ir.inc)
src/ir/ir_dump.s            text dump (IR.md §5)
src/ir/ir_verify.s          verifier (IR.md §6)
src/driver/main.s           _main: CLI → compile → emit → assemble/link → exit code
src/driver/cli.s            argument parsing
src/driver/arena.s          _drv_alloc, _drv_fatal
src/driver/outbuf.s         _ob_* (driver.inc)
src/driver/fileio.s         read whole file, write file
src/driver/diag.s           BASIC error messages (BSK_EMIT_ERRMSG_TABLE), baysick: messages
src/driver/toolchain.s      temp dir, runtime lookup, SDK lookup, argv substitution, spawn/wait
src/driver/targets.s        _drv_targets: NULL-terminated list of backend descriptors
src/backend/arm64_macos/a64_desc.s   descriptor + as/ld argv templates
src/backend/arm64_macos/a64_emit.s   module-level emission (sections, data, functions)
src/backend/arm64_macos/a64_insn.s   per-opcode emission
src/runtime/rt_main.s       _main, _bsk_end, _bsk_curline, state
src/runtime/rt_print.s      column logic, output buffer, _bsk_print_*
src/runtime/rt_numfmt.s     number formatting (LANGUAGE.md §9)
src/runtime/rt_math.s       _bsk_div _bsk_pow _bsk_chk and builtins
src/runtime/rt_rnd.s        _bsk_rnd
src/runtime/rt_array.s      _bsk_aref1 _bsk_aref2
src/runtime/rt_data.s       _bsk_read
src/runtime/rt_gosub.s      _bsk_gosub_push _bsk_gosub_pop
src/runtime/rt_error.s      _bsk_err, message table (BSK_EMIT_ERRMSG_TABLE)
```

Dependencies (who calls whom): driver → frontend, ir, backend (via descriptor); frontend → ir
builder, `_drv_alloc`, libc `_strtod`; backend → `_ob_*`, `_drv_alloc` (reads the Module
directly through `ir.inc` offsets); ir → `_drv_alloc`, `_ob_*`; runtime → libSystem only.
Because every cross-module call is declared in an include file, each module can be unit-assembled
alone, and integration only needs the link.

## 3. Conventions inside the compiler and runtime

### 3.1 Calling convention

**Every global function in every module follows AAPCS64 as modified by Apple** — no private
conventions across module boundaries:

* arguments `x0–x7`, `d0–d7`; results `x0` (`x1`), `d0`;
* callee-saved `x19–x28`, `x29` (frame pointer), `x30` saved by the callee if it calls,
  `d8–d15` (low 64 bits);
* caller-saved `x0–x17`, `d0–d7`, `d16–d31`; `x16`/`x17` may be clobbered by linker stubs —
  use them only as scratch between two adjacent instructions;
* **`x18` is reserved by Darwin and is never read or written**;
* `sp` is 16-byte aligned at every call; every non-leaf function builds a frame record
  (`stp x29, x30, [sp, #-N]!` / `mov x29, sp`);
* **variadic calls** (e.g. `_snprintf`, `_fprintf`): on Apple arm64 *all variadic arguments are
  passed on the stack*, each in an 8-byte slot starting at `[sp]` at the call; fixed arguments
  still use registers. Example: `snprintf(buf, 32, "%.5e", x)` → `x0=buf, x1=32, x2=fmt`,
  `str d0, [sp]`.

A module may use a private convention for its *internal* (non-global) helpers, but it must be
documented in that helper's header comment.

### 3.2 Memory

The compiler never frees memory. `_drv_alloc(size)` returns zeroed, 16-byte aligned memory from
1 MiB chunks obtained with `malloc` (requests over 256 KiB get their own `malloc`). Growable
arrays (IR instructions, labels, strings, data) double their capacity by allocating a new block
and copying (`_memcpy`); the old block is abandoned. Text output is built in `OutBuf`s
(`driver.inc`), which grow with `realloc`.

### 3.3 Errors

* **BASIC compile errors.** The frontend stops at the first error (order: LANGUAGE.md §10.1) and
  returns `(code, line)` from `_fe_compile`. Internally the frontend records the error and unwinds
  directly to `_fe_compile` by restoring a stack pointer saved on entry (a private
  setjmp/longjmp; all frontend functions are written so this is safe: they hold no resources).
  The driver prints the message using the shared table (`errors.inc`) and exits 1.
* **Internal errors** (verifier failure, impossible state, backend failure) → `_drv_fatal`,
  exit 4. **Out of memory** → `baysick: out of memory`, exit 4.
* **Run-time errors** in compiled programs → `_bsk_err(code)` (never returns).

### 3.4 Assembly style

* Apple `as` syntax; `//` comments; one instruction per line; 4-space indent for instructions,
  labels in column 0.
* Every function starts with a header block: purpose; inputs (registers); outputs; clobbered
  registers; callee-saved registers it uses and what it keeps in them; frame size.
* Comments at least every few instructions explaining intent (not restating the mnemonic).
* Global symbols use the module prefix: `_fe_`, `_ir_`, `_drv_`, `_ob_`, `_bk_<target>_`,
  `_bsk_` (runtime). File-local labels: `L<module>_<function>_<what>` (e.g.
  `Lfe_expr_term_loop`); numeric local labels (`1:` / `1b`) only for jumps of a few
  instructions.
* Read-only data in `__TEXT,__const` / `__TEXT,__cstring`; tables of pointers in
  `__DATA,__const`; mutable data in `__DATA,__data`; zero-initialised in `.zerofill __DATA,__bss`.
* `.p2align 2` before code, `.p2align 3` before 8-byte data.
* Every source file begins `.include "baysick.inc"` (assembled with `-I include`).

## 4. Driver and CLI

### 4.1 Command line

```
baysick <file.bas> [-o <out>] [-S] [--emit-ir] [--target <name>] [--keep-temps]
baysick --help | -h          usage text to stdout, exit 0
baysick --version            "baysick 0.1.0 (Dartmouth BASIC, First Edition 1964)" + LF, exit 0
```

* Options and the input file may appear in any order; exactly one input file is required.
  `-o` and `--target` take the next argument. If an option is repeated, the last one wins.
* Default `--target` is `arm64-macos`.
* Output naming: *stem* = the input path with a trailing `.bas` removed, or the input path with
  `.out` appended if it does not end in `.bas`.

| Mode | Output | Tools run |
|------|--------|-----------|
| default | executable at `-o` or *stem* | as, ld |
| `-S` | assembly at `-o` or *stem*`.s` | none |
| `--emit-ir` | IR dump (IR.md §5) to `-o` file, or **stdout** if no `-o` | none (backend not invoked) |
| target without `BKF_HOST_NATIVE` | as `-S` | none |

`-S` together with `--emit-ir` is a usage error. `--keep-temps` keeps the temporary directory
(default mode only).

### 4.2 Exit status and driver messages

| Status | Meaning |
|-------:|---------|
| 0 | success |
| 1 | BASIC compile error: message per LANGUAGE.md §10.1 on stderr, nothing written |
| 2 | usage or file error |
| 3 | toolchain error (as/ld/xcrun missing or failing, runtime library missing) |
| 4 | internal error or out of memory |

Driver messages (stderr, exact text, `%s` substituted, `%d` decimal):

| Status | Text |
|-------:|------|
| 2 | `baysick: usage: baysick <file.bas> [-o out] [-S] [--emit-ir] [--target arm64-macos] [--keep-temps]` |
| 2 | `baysick: unknown option '%s'` (followed by the usage line) |
| 2 | `baysick: missing argument for '%s'` (followed by the usage line) |
| 2 | `baysick: unknown target '%s'` |
| 2 | `baysick: cannot read '%s': %s` (strerror) |
| 2 | `baysick: cannot write '%s': %s` |
| 2 | `baysick: cannot create temporary directory: %s` |
| 3 | `baysick: cannot find runtime library '%s'` |
| 3 | `baysick: cannot determine macOS SDK path` |
| 3 | `baysick: cannot run '%s': %s` |
| 3 | `baysick: '%s' failed with exit status %d` (the tool's own stderr passes through) |
| 4 | `baysick: internal error: %s` |
| 4 | `baysick: out of memory` |
| — | `baysick: temporary files kept in %s` (informational, with `--keep-temps`) |

### 4.3 Default-mode steps

1. Read the input file completely (`open`/`fstat`/`read`). Files over 1 MiB are still read; the
   frontend reports `PROGRAM TOO LONG`.
2. `_ir_module_new`, `_fe_compile`. On error print the BASIC message, exit 1.
3. `_ir_verify`; failure → internal error.
4. `BKD_EMIT(module, outbuf)`.
5. Temporary directory: `mkdtemp("$TMPDIR/baysick.XXXXXX")` (`$TMPDIR` without a trailing `/`;
   `/tmp` if `TMPDIR` is unset or empty). Files: `prog.s`, `prog.o` (suffixes from the
   descriptor).
6. Write `prog.s`; spawn the assembler argv, then the linker argv (placeholders substituted,
   §5.2) with `posix_spawnp`, inheriting stdin/stdout/stderr; `waitpid`. Non-zero status →
   exit 3 after cleanup.
7. Unless `--keep-temps`: unlink the files, `rmdir` the directory.

### 4.4 Locating the runtime library

1. If the environment variable **`BAYSICK_RUNTIME`** is set and non-empty, it is the full path
   of the runtime archive.
2. Otherwise: the directory containing the compiler executable (`_NSGetExecutablePath`, then
   `realpath`) joined with `BKD_RUNTIME_NAME` (`libbaysickrt.a`). In the build tree this is
   `build/libbaysickrt.a` next to `build/baysick`.

If the file does not exist (`access(R_OK)` fails) → exit 3.

### 4.5 Locating the SDK

`PH_SDK` is `$SDKROOT` if set and non-empty; otherwise the first line of the standard output of
`xcrun --show-sdk-path` (spawned with stdout redirected to a pipe via
`posix_spawn_file_actions_adddup2`; trailing LF removed). Failure → exit 3. The SDK path is only
computed if a template contains `PH_SDK`.

## 5. Backend interface

### 5.1 Descriptor

A backend is a 64-byte read-only descriptor (`backend.inc` `BKD_*`) exported by the backend
module and listed in `_drv_targets` (`src/driver/targets.s`, a NULL-terminated array of descriptor
pointers). `--target <name>` selects the descriptor whose `BKD_NAME` equals `<name>`.

`BKD_EMIT(x0 = Module*, x1 = OutBuf*) → x0` appends one complete assembly file; returns 0, or a
pointer to a reason string (→ internal error). The backend reads the Module only through the
`ir.inc` offsets and never modifies it.

### 5.2 Toolchain templates for `arm64-macos`

Argv templates (pointer arrays; small integers are placeholders, `backend.inc` `PH_*`):

```
as:  "as" "-arch" "arm64" "-mmacosx-version-min=11.0" "-o" PH_OBJ PH_ASM
ld:  "ld" "-o" PH_EXE PH_OBJ PH_RUNTIME "-lSystem" "-syslibroot" PH_SDK
     "-e" "_main" "-arch" "arm64" "-platform_version" "macos" "11.0" "11.0"
```

`BKD_FLAGS = BKF_HOST_NATIVE`, suffixes `.s` / `.o`, runtime name `libbaysickrt.a`.
(`-mmacosx-version-min=11.0` keeps the object's minimum OS equal to the link's, avoiding an
ld "built for newer macOS" warning.)

### 5.3 arm64-macos code generation (backend-private, specified to remove ambiguity)

**Output skeleton** (in this order):

```
// generated by baysick
    .section __TEXT,__text,regular,pure_instructions
    .globl _bsk_program
    .p2align 2
_bsk_program:        main function
Lfn_A: … Lfn_Z:      present FN functions, letter order
    .section __TEXT,__const
Lstr_0: .byte …      each string literal as decimal .byte list (Lstr_<id>), may be empty
    .section __DATA,__const
    .globl _bsk_data
    .p2align 3
_bsk_data:           .quad <bits> per DATA value (none if NDATA = 0; label still emitted)
    .globl _bsk_data_count
_bsk_data_count:     .quad NDATA
    .section __DATA,__data
    .p2align 3
Ldesc_<L>:           32-byte RTA descriptor per used array (.quad _bsk_arr_<L>, .long dims,
                     .long b1, .long b2, .long rowlen, .long letter, .long 0)
    .zerofill __DATA,__bss,_bsk_vars,<8*NSLOTS>,3
    .zerofill __DATA,__bss,_bsk_arr_<L>,<8*(b1+1)*(b2+1)>,3   per used array
```

`_bsk_vars` and `_bsk_arr_<L>` are file-local (no `.globl`). Labels of `main`:
`Lbsk_L<id>` for every label id (line and internal labels alike).

**Frames and temps.** Temps live in 8-byte stack slots. Because a temp is never read after the
next `line` (IR.md §1), slots are reused per line: slot(t) = t − *base*, where *base* is the
number of the first temp defined after the most recent `line` instruction (0 in FN functions).
The temp area is `8 × W` bytes, W = the largest number of temps defined between two consecutive
`line` instructions (or in the whole FN function). Frame of every generated function:

```
    stp x29, x30, [sp, #-32]!        // frame record
    mov x29, sp
    stp x19, x20, [sp, #16]          // x19 = &_bsk_vars, x20 = spare
    sub sp, sp, #<align16(8*W + 16)> // temps at [sp, #8*slot]; FN argument at [sp, #8*W]
    adrp x19, _bsk_vars@PAGE
    add  x19, x19, _bsk_vars@PAGEOFF
    … body …
    mov sp, x29                      // epilogue (FN functions only; main never returns)
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
```

Offsets that do not fit an instruction's immediate are materialised in `x16` (`mov`/`movk`)
and used as a register offset. FN functions receive the argument in `d0`, store it at the
argument slot, and return the result in `d0`. `_bsk_program` never returns normally (main ends
with `end`); `Lfn_*` return with `ret`.

**Per-opcode translation** (`dN` loads from temp slots; `x19` = globals base):

| Op | arm64 sequence |
|----|----------------|
| `line` | `Lbsk_L<id>:` then `adrp x16, _bsk_curline@PAGE` / `mov w17, #<n>` (`movz`/`movk` as needed) / `str w17, [x16, _bsk_curline@PAGEOFF]` |
| `label` | `Lbsk_L<id>:` |
| `const` | `mov x16, #…`/`movk` ×≤4 building the bits, `fmov d0, x16`, store |
| `ldv`/`stv` | `ldr/str d0, [x19, #8*slot]` |
| `add sub mul` | `fadd/fsub/fmul d0, d0, d1`, then the overflow check below, store |
| `div` `pow` | `bl _bsk_div` / `bl _bsk_pow` (d0, d1 → d0) |
| `neg` | `fneg d0, d0` |
| builtins | `bl _bsk_sin` … `_bsk_int` (d0 → d0); `rnd`: `bl _bsk_rnd` |
| `ald1/ald2` | `adrp/add x0, Ldesc_<L>`, `d0`(,`d1`) = subscripts, `bl _bsk_aref1/2`, `ldr d0, [x0]` |
| `ast1/ast2` | same, then load the value temp and `str d0, [x0]` |
| `callfn` | `d0` = argument, `bl Lfn_<L>`, store `d0` |
| `param` | `ldr d0, [sp, #8*W]` |
| `ret` | load A into `d0`, epilogue |
| `jmp` | `b Lbsk_L<id>` |
| `jcmp` | `fcmp d0, d1`; `b.<inverse> 1f`; `b Lbsk_L<id>`; `1:` (inverse of eq/ne/lt/le/gt/ge = ne/eq/ge/gt/le/lt; NaN cannot occur) |
| `jfor` | `fcmp dStep, #0.0`; `b.lt 2f`; `fcmp dV, dL`; `b.le 3f`; `b Ltarget`; `2: fcmp dV, dL`; `b.ge 3f`; `b Ltarget`; `3:` |
| `gosub` | `adrp x0, Lbsk_L<ret>@PAGE`; `add x0, x0, Lbsk_L<ret>@PAGEOFF`; `bl _bsk_gosub_push`; `b Lbsk_L<target>` |
| `return` | `bl _bsk_gosub_pop`; `br x0` |
| `read` | `bl _bsk_read`, store `d0` |
| `prnum` | `bl _bsk_print_num` (d0) |
| `prstr` | `adrp/add x0, Lstr_<id>`, `mov x1, #len`, `bl _bsk_print_str` |
| `prcomma prsemi prnl` | `bl _bsk_print_comma` / `_semi` / `_nl` |
| `end` `stop` | `bl _bsk_end` |

Overflow check after `fadd/fsub/fmul` (result in `d0`):

```
    fabs  d16, d0
    movz  x16, #0x7FF0, lsl #48
    fmov  d17, x16              // +infinity
    fcmp  d16, d17
    b.lo  1f                    // finite: |x| < inf (NaN is unordered → falls through)
    mov   w0, #38               // ERR_OVERFLOW
    bl    _bsk_err
1:
```

Unconditional branches (`b`, range ±128 MiB) are used for all jumps; conditional branches only
skip a few instructions, so program size never breaks branch ranges.

## 6. Runtime ABI

### 6.1 Program startup and state

The runtime provides `_main`. It initialises its state, calls `_bsk_program` (provided by the
compiled program, AAPCS64, no arguments), and if that ever returns calls `_bsk_end`.

Runtime-private state (in `src/runtime`, not visible to programs): print `col` and `out`
counters, a 4096-byte stdout buffer and its fill count, the RND state (initial value 1964), the
DATA cursor (initial 0), the GOSUB stack (1024 × 8 bytes) and its depth.

Data shared with compiled code:

| Symbol | Defined by | Type | Meaning |
|--------|-----------|------|---------|
| `_bsk_curline` | runtime | u32, initially 0 | BASIC line of the statement being executed |
| `_bsk_program` | program | code | main BASIC function |
| `_bsk_data` | program | double[] | DATA block in program order |
| `_bsk_data_count` | program | u64 | number of DATA values |

### 6.2 Entry points

All AAPCS64. "Error" means `_bsk_err(code)` is called and the function does not return.

| Function | In | Out | Semantics |
|----------|----|-----|-----------|
| `_bsk_print_num` | d0 | — | LANGUAGE.md §8 number item with §9 format |
| `_bsk_print_str` | x0 ptr, x1 len | — | string item (bytes, not NUL-terminated) |
| `_bsk_print_comma` | — | — | `,` rule |
| `_bsk_print_semi` | — | — | `;`-after-number rule (compiler emits it only after numbers) |
| `_bsk_print_nl` | — | — | newline |
| `_bsk_read` | — | d0 | next DATA value; none left → prints `OUT OF DATA IN n`, exits **0** |
| `_bsk_div` | d0 a, d1 b | d0 | b = ±0 → error 35; result not finite → error 38 |
| `_bsk_pow` | d0 a, d1 b | d0 | LANGUAGE.md §5.4 (`pow(fabs(a), b)`, 0 cases, error 36/38) |
| `_bsk_chk` | d0 | d0 | returns d0; error 38 if not finite (alternative to the inline check) |
| `_bsk_sin _bsk_cos _bsk_tan _bsk_atn _bsk_exp` | d0 | d0 | libm call, error 38 if not finite |
| `_bsk_abs _bsk_sqr _bsk_int` | d0 | d0 | `fabs`, `sqrt(fabs)`, `trunc` (`frintz`) |
| `_bsk_log` | d0 | d0 | 0 → error 37; else `log(fabs(x))` |
| `_bsk_rnd` | — | d0 | LANGUAGE.md §6 generator |
| `_bsk_aref1` | x0 desc, d0 i | x0 addr | `r = floor(i + 0.5)`; `0 <= r <= B1` else error 32; address of element r |
| `_bsk_aref2` | x0 desc, d0 i, d1 j | x0 addr | both subscripts checked; address of (ri, rj) |
| `_bsk_gosub_push` | x0 code address | — | depth 1024 → error 39 |
| `_bsk_gosub_pop` | — | x0 code address | empty → error 33 |
| `_bsk_end` | — | noreturn | pending-line newline, flush stdout, `exit(0)` |
| `_bsk_err` | w0 code | noreturn | pending-line newline, flush stdout, write `<MESSAGE> IN <_bsk_curline>` + LF to fd 2, `exit(1)` (code 34 exits 0) |

The comparison in `_bsk_aref*` is done on the rounded double before conversion to an integer, so
huge or negative subscripts can never wrap. Stdout is written with `write(1, …)`; the buffer is
flushed when full, at `_bsk_end` and in `_bsk_err`. The runtime never uses stdio.

Number formatting (`rt_numfmt.s`) may call `snprintf(buf, n, "%.5e", |x|)` to obtain the six
correctly rounded digits and the exponent (variadic double on the stack, §3.1), and must then
apply LANGUAGE.md §9 itself. Integers below 10⁹ are converted with integer arithmetic
(`fcvtzu`).

### 6.3 FOR, GOSUB and line numbers in compiled code

* FOR/NEXT is entirely lowered to IR (`stv` to hidden slots, `jfor`), IR.md §4.3. The runtime has
  no FOR support.
* GOSUB pushes the machine address of the return label; RETURN jumps to the popped address.
* Each `line` instruction stores the BASIC line number in `_bsk_curline`; run-time messages use
  the value current at the time of the error.

## 7. Porting: an `x86_64-linux` backend and runtime (not implemented)

The design keeps every target-specific decision behind the descriptor and the runtime ABI:

1. **Backend** `src/backend/x86_64_linux/` exporting `_bk_x86_64_linux_desc` (added to
   `_drv_targets`). `BKD_FLAGS = 0`, so the macOS driver only writes the `.s` file. It emits GNU
   `as` syntax (AT&T, or `.intel_syntax noprefix`) for ELF: no leading underscore on symbols
   (`bsk_program`, `bsk_print_num`, …), sections `.text/.rodata/.data/.bss`, RIP-relative
   addressing (`lea Lstr_0(%rip), %rdi`), System V ABI (args `rdi rsi rdx …`, `xmm0–xmm7`, result
   `rax`/`xmm0`, callee-saved `rbx rbp r12–r15`, 16-byte stack alignment at `call`).
   Translation is the same as §5.3: temps in `[rbp - 8*(slot+1)]`, `ucomisd` + `jcc`, `gosub` as
   `lea Lret(%rip), %rdi; call bsk_gosub_push; jmp Ltarget`, `return` as
   `call bsk_gosub_pop; jmp *%rax`. Emit `.section .note.GNU-stack,"",@progbits`.
2. **Runtime** `src/runtime_x86_64_linux/` implementing the same entry points with the same
   semantics (§6.2) under ELF names, using glibc/musl `write`, `exit`, `snprintf` (variadic
   doubles in `xmm0` with `al` = number of vector registers used), libm. It is built on the Linux
   machine into `libbaysickrt.a`.
3. **On the Arch Linux box** the user runs:
   `as -o prog.o prog.s && gcc -no-pie -o prog prog.o libbaysickrt.a -lm`.
   The runtime provides `main`; gcc supplies the C start files.
4. Nothing in the frontend, IR, verifier, dumper, tests (`tests/programs` outputs are
   target-independent by construction) or LANGUAGE.md changes.

## 8. Build and test

* `make` builds `build/baysick` from `src/frontend/*.s src/ir/*.s src/driver/*.s
  src/backend/*/*.s` and `build/libbaysickrt.a` from `src/runtime/*.s`, using only `as`, `ld`,
  `ar` and `xcrun`. The compiler is linked with the same `ld` options as user programs (§5.2),
  without the runtime.
* `make test` runs `tests/run.sh` (it builds nothing; it requires `build/baysick` and
  `build/libbaysickrt.a`).
* Test sidecar formats are documented at the top of `tests/run.sh`.
