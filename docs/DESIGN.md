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

There are two targets. **`arm64-macos`** (default) runs the whole pipeline above. **`x86_64-linux`**
is a cross target: the same compiler, running on the Mac, emits GNU `as` x86_64 assembly (§5.4)
and stops there (as if `-S` were given); the `.s` file is assembled and linked on an x86_64 Linux
machine against the x86_64 runtime (`src/runtime_x86_64_linux/`, x86_64 assembly, §6.4), which is
built on Linux with `make -f Makefile.linux` (§8).

## 2. Repository layout and ownership

Implementers work in parallel. **Each owns only its directory or files**; it may add, split or
rename files *inside* its directory (the Makefiles glob `*.s`). Nobody edits another module's
files. The shared files are `include/*.inc` and `tests/include_asserts.inc` (read-only for
implementers; changed only by the architect together with the docs).

| Module | Owner | Directory / files | Exports |
|--------|-------|-------------------|---------|
| Frontend | implementer F | `src/frontend/` | `_fe_compile` |
| IR + Driver | implementer D | `src/ir/`, `src/driver/` (except the one `targets.s` line owned by BX) | `_main` (compiler), `_ir_*` (ir.inc), `_drv_alloc`, `_drv_fatal`, `_ob_*` (driver.inc), `_drv_targets` |
| Backend arm64-macos | implementer B | `src/backend/arm64_macos/` | `_bk_arm64_macos_desc` |
| Runtime arm64-macos | implementer R | `src/runtime/` | everything in runtime.inc "defined by the runtime" (Mach-O names) |
| Backend x86_64-linux | implementer BX | `src/backend/x86_64_linux/`, plus the line `.quad _bk_x86_64_linux_desc` in `src/driver/targets.s` | `_bk_x86_64_linux_desc` (Mach-O symbol inside the compiler) |
| Runtime x86_64-linux | implementer RX | `src/runtime_x86_64_linux/` | the §6.4 ELF symbols (`main`, `bsk_*`) |
| Cross testing + CI | implementer T | `Makefile.linux`, `tests/cross_pack.sh`, `tests/cross_run.sh`, `tests/cross.sh`, the `cross`/`cross-pack` targets and `COMPILER_DIRS` entry in `Makefile`, `.github/workflows/ci.yml` | — |
| Benchmarks | implementer BENCH | `bench/` (everything in it), the `bench` and `bench-cross` targets in `Makefile` | — (a measuring tool, `docs/BENCH.md`) |

BX writes arm64 assembly for Apple `as` (it is part of the compiler, §3); RX writes x86_64
assembly for GNU `as` (§6.4). BX and RX never call into each other's or the arm64 modules'
private code: their only shared contract is §5.4 (what the emitted `.s` contains) and §6.4 (what
the runtime provides).

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
src/backend/x86_64_linux/x64_desc.s   _bk_x86_64_linux_desc + argv templates (§5.4)
src/backend/x86_64_linux/x64_emit.s   _bk_x64_emit: module-level emission (§5.4 skeleton)
src/backend/x86_64_linux/x64_insn.s   frames and per-opcode emission (§5.4 tables)
src/backend/x86_64_linux/x64_text.s   text helpers (formatted output of x86 operands/immediates)
src/runtime_x86_64_linux/rt_main.s    main, bsk_end, bsk_curline
src/runtime_x86_64_linux/rt_print.s   column logic, output buffer, bsk_print_*
src/runtime_x86_64_linux/rt_numfmt.s  number formatting (LANGUAGE.md §9)
src/runtime_x86_64_linux/rt_math.s    bsk_div bsk_pow bsk_chk and builtins
src/runtime_x86_64_linux/rt_rnd.s     bsk_rnd
src/runtime_x86_64_linux/rt_array.s   bsk_aref1 bsk_aref2
src/runtime_x86_64_linux/rt_data.s    bsk_read
src/runtime_x86_64_linux/rt_gosub.s   bsk_gosub_push bsk_gosub_pop
src/runtime_x86_64_linux/rt_error.s   bsk_err, message table (BSK_EMIT_ERRMSG_TABLE)
```

Files added for the MAT statements (§2.1):

```
src/frontend/fe_mat.s       MAT statement parser + lowering (LANGUAGE.md 7.14.2, IR.md 4.3)
src/runtime/rt_mat.s        _bsk_mat_*: MAT layer (shapes, redimensioning, aliasing, errors,
                            MAT READ, MAT PRINT), §6.5
src/runtime/rt_kinit.s      _bsk_kern_init/_use/_name/_variants/_features, sysctlbyname
                            detection, the KV_* variant table, the _bsk_kern_* trampolines, §6.6
src/runtime/rt_kneon_gemm.s NEON GEMM: packing, cache blocking, register-blocked micro-kernel
src/runtime/rt_kneon_elem.s NEON add/sub/scale/copy/fill
src/runtime/rt_kneon_trn.s  NEON blocked transpose
src/runtime/rt_kneon_inv.s  pinned Gauss-Jordan inverse (LANGUAGE.md 7.14.6), NEON row updates
src/runtime_x86_64_linux/rt_mat.s        bsk_mat_*: same as src/runtime/rt_mat.s
src/runtime_x86_64_linux/rt_kinit.s      bsk_kern_*: cpuid/xgetbv detection, table, trampolines
src/runtime_x86_64_linux/rt_ksse2_gemm.s SSE2 GEMM
src/runtime_x86_64_linux/rt_ksse2_elem.s SSE2 add/sub/scale/copy/fill
src/runtime_x86_64_linux/rt_ksse2_trn.s  SSE2 blocked transpose
src/runtime_x86_64_linux/rt_ksse2_inv.s  pinned Gauss-Jordan inverse, SSE2 row updates
bench/                                   BENCH: harness, peak loops, programs, scripts (BENCH.md)
```

Future kernel variants add files named `rt_k<variant>_*.s` in the runtime directory
(`rt_ksme_gemm.s`, `rt_kavx2_gemm.s`, …) and one record in the variant table (§6.6.7).

Dependencies (who calls whom): driver → frontend, ir, backend (via descriptor); frontend → ir
builder, `_drv_alloc`, libc `_strtod`; backends → `_ob_*`, `_drv_alloc` (read the Module
directly through `ir.inc` offsets); ir → `_drv_alloc`, `_ob_*`; runtime → libSystem only;
x86_64 runtime → glibc/libm only (§6.4).
Because every cross-module call is declared in an include file, each module can be unit-assembled
alone, and integration only needs the link.

### 2.1 MAT work packages

The Second Edition MAT statements (LANGUAGE.md §7.14) touch every module; each implementer
changes only its own files:

| Owner | Work |
|-------|------|
| F | `KW_MAT` in the keyword table (tested last); `fe_mat.s`: grammar and compile errors of LANGUAGE.md §7.14.2, dimensionality fixing by subscripted MAT READ targets, canonical lowering (IR.md §4.3); after all lines, every letter still of unknown dimensionality that a MAT statement names becomes a table 10 × 10 (`_ir_set_array`); `NO DATA` also for MAT READ |
| D | builder: nothing new; dumper: the text forms of IR.md §3 (`matprint A, zoned`, array-kind A/B fields); verifier: IR.md §6 field kinds; driver: the `--version` text (§4.1) |
| B | §5.3: descriptor `cap` word, the MAT rows of the per-opcode table |
| BX | §5.4: the same for x86_64 |
| R | `rt_mat.s`, `rt_kinit.s`, `rt_kneon_*.s`; `_main` calls `_bsk_kern_init`; `_bsk_aref*` already use the current bounds (no change) |
| RX | the x86_64 counterparts (`rt_ksse2_*.s`, cpuid detection), §6.4 |
| BENCH | `bench/`, `make bench`, `make bench-cross` (BENCH.md) |
| T | nothing new: the MAT corpus flows through `cross_pack.sh` unchanged |

### 2.2 Contract counts

The MAT contract raises `OP_COUNT` from 42 to 55 and `KW_COUNT` from 15 to 16. Existing modules
size tables by these counts (dumper, verifier, both backends, the keyword loop), and the build
asserts them (`tests/include_asserts.inc`: `OP_COUNT == OP_MATINV + 1`, `KW_COUNT == KW_MAT + 1`).
There is no build switch; the counts are plain constants in `include/ir.inc` and
`include/tokens.inc`.

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

The rules above are for the compiler and the arm64 runtime. The x86_64 runtime has its own
style rules (§6.4.4).

**Shared include files** (`include/*.inc`, `tests/include_asserts.inc`) are assembled by Apple
`as` (arm64) *and* by GNU `as` (x86_64, `--64`), so they use only the syntax both accept:

* comments: `//` only as the first non-blank characters of a line (GNU `as` for x86 treats `/`
  as a comment character only at the start of a line); a trailing comment after code is written
  `/* … */`; never `;` or `#` comments;
* only arch-neutral directives: `.equ`, `.ifndef`/`.if`/`.endif`, `.macro`/`.endm`, `.quad`,
  `.asciz`, `.p2align`, `.error`; no instructions, no section directives (the instantiating file
  chooses the section);
* a condition passed to a macro is fully parenthesised (`ASSERT (A == B), "…"`), because GNU `as`
  reads a bare `NAME == x` argument as the keyword argument `NAME=`.

`make check-includes` rejects trailing `//` comments (grep) and assembles `tests/include_check.s`
with Apple `as`; `make -f Makefile.linux check-includes` assembles `tests/include_check_x86_64.s`
with GNU `as`. Both include `tests/include_asserts.inc`.

## 4. Driver and CLI

### 4.1 Command line

```
baysick <file.bas> [-o <out>] [-S] [--emit-ir] [--target <name>] [--keep-temps]
baysick --help | -h          usage text to stdout, exit 0
baysick --version            "baysick 0.2.0 (Dartmouth BASIC, Second Edition 1964)" + LF, exit 0
```

* Options and the input file may appear in any order; exactly one input file is required.
  `-o` and `--target` take the next argument. If an option is repeated, the last one wins.
* Default `--target` is `arm64-macos`. The other target is `x86_64-linux` (§5.4); its descriptor
  has no `BKF_HOST_NATIVE`, so `baysick --target x86_64-linux prog.bas` writes `prog.s` (or the
  `-o` path) exactly like `-S` and runs no tools; `--keep-temps` has no effect there. The usage
  and help texts are unchanged (they name the default target only).
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

Details:

* `cannot determine macOS SDK path` also covers `xcrun` itself failing to start (spawn
  error), exiting non-zero, printing nothing, and an SDK path that fails validation (§4.5).
* A tool killed by signal *n* is reported as `'%s' failed with exit status %d` with
  status 128+*n* (e.g. 143 for SIGTERM).
* A write failure on standard output under `--emit-ir` (no `-o`) is
  `baysick: cannot write '<stdout>': %s`, exit 2.
* The compiler ignores `SIGPIPE` (`signal(SIGPIPE, SIG_IGN)` first thing in `_main`), so a
  closed stdout/stderr makes `write` fail with `EPIPE` instead of killing the process. Spawned
  tools get `SIGPIPE` reset to its default action (`POSIX_SPAWN_SETSIGDEF`).
* **Cleanup before diagnostics:** once the temporary directory exists, every failure path
  removes it (unless `--keep-temps`) *before* writing its message: tool failure, `cannot run`,
  `cannot write` for `prog.s`, `internal error` and `out of memory` (`_drv_fatal` / `_drv_oom`
  use the path recorded in driver state, `_drv_tmp_dir` / `_drv_tmp_asm` / `_drv_tmp_obj` in
  `toolchain.s`). A failing diagnostic write therefore can never leak the directory.

### 4.3 Default-mode steps

1. Read the input file (`open`/`fstat`/`read`) to EOF, but at most `LIM_SOURCE_BYTES` + 1
   bytes: reading stops there, the frontend sees a length over the limit and reports
   `PROGRAM TOO LONG` (so `baysick /dev/zero` fails fast instead of exhausting memory).
2. `_ir_module_new`, `_fe_compile`. On error print the BASIC message, exit 1.
3. `_ir_verify`; failure → internal error.
4. `BKD_EMIT(module, outbuf)`.
5. Temporary directory: `mkdtemp("$TMPDIR/baysick.XXXXXX")` (`$TMPDIR` without a trailing `/`;
   `/tmp` if `TMPDIR` is unset or empty). Files: `prog.s`, `prog.o` (suffixes from the
   descriptor).
6. Write `prog.s`; spawn the assembler argv, then the linker argv (placeholders substituted,
   §5.2) with `posix_spawnp`, inheriting stdin/stdout/stderr and the environment **with every
   `SDKROOT=` entry removed** (the SDK reaches `ld` explicitly through `-syslibroot`, so a stray
   `SDKROOT` can never reach the `/usr/bin` xcrun shims); `waitpid`. Non-zero status → cleanup,
   then the message, exit 3.
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
`posix_spawn_file_actions_adddup2`; trailing LF removed; same `SDKROOT`-free environment and
`SIGPIPE` reset as the other tools, §4.3). Whichever source it came from, the path is
**validated**: `access("<sdk>/SDKSettings.plist", R_OK)` or, failing that,
`access("<sdk>/SDKSettings.json", R_OK)` must succeed. Any failure (xcrun cannot be spawned,
exits non-zero, prints nothing, or validation fails) → `baysick: cannot determine macOS SDK
path`, exit 3, before `as` or `ld` is spawned. The SDK path is only computed if a template
contains `PH_SDK`; the `as` spawn is protected regardless because `SDKROOT` is never passed to
any tool.

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
                     .long b1, .long b2, .long rowlen, .long letter, .long cap),
                     cap = (b1+1)*(b2+1)
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
| `matredim` | `adrp/add x0, Ldesc_<X>`, `ldr d0` ← A; with B: `ldr d1` ← B, `bl _bsk_mat_redim2`; without: `bl _bsk_mat_redim1` |
| `matread` `matzer` `matcon` `matidn` | `adrp/add x0, Ldesc_<X>`, `bl _bsk_mat_read` / `_zer` / `_con` / `_idn` |
| `matprint` | `adrp/add x0, Ldesc_<X>`, `mov w1, #<IMM>`, `bl _bsk_mat_print` |
| `matcopy` `mattrn` `matinv` | `adrp/add x0, Ldesc_<X>`, `adrp/add x1, Ldesc_<A>`, `bl _bsk_mat_copy` / `_trn` / `_inv` |
| `matadd` `matsub` `matmul` | `x0` ← `Ldesc_<X>`, `x1` ← `Ldesc_<A>`, `x2` ← `Ldesc_<B>`, `bl _bsk_mat_add` / `_sub` / `_mul` |
| `matscale` | `x0` ← `Ldesc_<X>`, `x1` ← `Ldesc_<B>`, `ldr d0` ← temp A, `bl _bsk_mat_scale` |

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

### 5.4 x86_64-linux target (implementer BX; normative for the emitted text)

The backend lives in `src/backend/x86_64_linux/` and is part of the compiler: **arm64 assembly
for Apple `as`**, AAPCS64, all §3 rules, global symbols prefixed `_bk_x64_` (the descriptor is
`_bk_x86_64_linux_desc`). It *emits* x86_64 text as specified here. BX also adds the line
`.quad _bk_x86_64_linux_desc` to `_drv_targets` (`src/driver/targets.s`) after the arm64 entry,
before the terminating 0.

#### 5.4.1 Descriptor

| Field | Value |
|-------|-------|
| `BKD_NAME` | `"x86_64-linux"` |
| `BKD_EMIT` | `_bk_x64_emit` |
| `BKD_AS_ARGV` | `"as" "--64" "-o" PH_OBJ PH_ASM` |
| `BKD_LD_ARGV` | `"gcc" "-no-pie" "-o" PH_EXE PH_OBJ PH_RUNTIME "-lm"` |
| `BKD_FLAGS` | `0` (no `BKF_HOST_NATIVE`) |
| `BKD_ASM_SUFFIX` / `BKD_OBJ_SUFFIX` | `".s"` / `".o"` |
| `BKD_RUNTIME_NAME` | `"libbaysickrt.a"` |

Because `BKF_HOST_NATIVE` is clear the macOS driver never substitutes or spawns the templates
(§4.1: the target behaves as `-S`). They are nevertheless real, complete argv templates (no
`PH_SDK`): they record the exact commands that turn the `.s` into an executable on Linux, and
`tests/cross_run.sh` runs precisely these commands (`PH_RUNTIME` =
`build-x86_64-linux/libbaysickrt.a`, §8). The runtime provides `main`; `gcc` supplies the C start
files and libc; `-no-pie` matches the absolute pointers in `.data` (array descriptors) and the
direct `call bsk_*` / `bsk_curline(%rip)` references, all resolved at static link time.

#### 5.4.2 Syntax and naming

* **GNU `as`, AT&T syntax** (its default; never `.intel_syntax`), x86_64 ELF, `#` comments, one
  instruction per line, 4-space indent, labels in column 0. Chosen over `.intel_syntax noprefix`
  because it is GNU `as`'s, `gcc -S`'s and `objdump -d`'s default (generated code can be diffed
  against both without translation); `$imm`, `sym(%rip)` and `(%reg)` make immediate vs memory
  operands explicit (Intel `mov rax, sym` silently loads memory where `offset sym` was meant, and
  a noprefix symbol can collide with a register name); operand size comes from the mnemonic
  suffix (`movq`, `movl`), never from `qword ptr`. The x86_64 runtime uses the same syntax.
* **Symbols:** ELF, no leading underscore. The output defines exactly three global symbols:
  `bsk_program`, `bsk_data`, `bsk_data_count`. Everything else is an assembler-local `.L` name
  (not in the object's symbol table):

  | Name | Meaning |
  |------|---------|
  | `.Lbsk_L<id>` | label id `<id>` of `main` (line and internal labels alike) |
  | `.Lfn_<L>` | FN function `<L>` (`A`…`Z`) |
  | `.Lstr_<id>` | PRINT string literal `<id>` |
  | `.Ldesc_<L>` | 32-byte `RTA_*` descriptor of array `<L>` |
  | `.Lbsk_vars` | the `NSLOTS` global cells |
  | `.Lbsk_arr_<L>` | element storage of array `<L>` |

  Numeric local labels `1:`, `2:`, `3:` (referenced as `1f` …) are used only inside one opcode's
  sequence below. All numbers in the output are decimal except `0x` + 16 uppercase hex digits for
  IEEE bit patterns.

#### 5.4.3 Output skeleton (in this order)

```
# generated by baysick
    .text
    .globl bsk_program
    .type bsk_program, @function
    .p2align 4
bsk_program:            main function
    .p2align 4
.Lfn_A:                 each present FN function, letter order, each preceded by .p2align 4
    .section .rodata
.Lstr_0:                each literal as lines "    .byte 65, 32, 61" (decimal, at most 16 per
                        line); an empty literal is the label alone
    .p2align 3
    .globl bsk_data
    .type bsk_data, @object
bsk_data:               "    .quad 0x<16 uppercase hex>" per DATA value (none if NDATA = 0)
    .globl bsk_data_count
    .type bsk_data_count, @object
bsk_data_count:
    .quad <NDATA>
    .data
    .p2align 3
.Ldesc_<L>:             per used array, letter order:
    .quad .Lbsk_arr_<L>
    .long <dims>, <b1>, <b2>, <rowlen>, <letter>, <cap>      cap = (b1+1)*(b2+1)
    .bss
    .p2align 3
.Lbsk_vars:
    .zero <8*NSLOTS>
    .p2align 3          per used array, letter order:
.Lbsk_arr_<L>:
    .zero <8*(b1+1)*(b2+1)>
    .section .note.GNU-stack,"",@progbits
```

`.section .rodata`, `.data` and `.bss` headers are emitted even when no item follows them. The
final `.note.GNU-stack` line marks the stack non-executable (without it GNU `ld` warns and makes
the stack executable). `rowlen` = `b2+1` for tables, `1` for lists; `b2` = 0 for lists (as §5.3).

#### 5.4.4 Frames and temps

Temps live in 8-byte stack slots; slot(t) = t − *base* and the temp-area width W are defined
exactly as in §5.3 (slots reused per `line`). Every generated function:

```
    pushq %rbp
    movq  %rsp, %rbp
    pushq %rbx                       # rbx = &.Lbsk_vars for the whole function
    subq  $<F>, %rsp                 # F = align16(8*W + 16) - 8
    leaq  .Lbsk_vars(%rip), %rbx
    movsd %xmm0, <8*W>(%rsp)         # FN functions only: save the argument
    … body …
    movq  -8(%rbp), %rbx             # epilogue, FN functions only (emitted by `ret`)
    leave
    ret
```

* Temp slot *s* is `<8*s>(%rsp)`; the FN argument slot is `<8*W>(%rsp)`. `%rsp` never moves
  inside the body. Alignment: at entry `%rsp` ≡ 8 (mod 16); after the two pushes it is still ≡ 8;
  F ≡ 8 (mod 16), so `%rsp` ≡ 0 at every `call` in the body, as the System V ABI requires.
  F ≥ 8W + 8, so the temps and the argument slot fit.
* Global cell *x* is `<8*x>(%rbx)`. `%rbx` is callee-saved in the System V ABI, so it survives
  every runtime call; it is saved/restored because the caller (`main` in the runtime, or the
  calling BASIC function) relies on it.
* All displacements fit a signed 32-bit displacement (largest global offset
  8 × (286 + 2·1000 − 1) = 18288); the assembler chooses the encoding.
* Registers used by generated code: `%rax %rcx %rdi %rsi %xmm0 %xmm1 %xmm2` as scratch, `%rbx`
  globals base, `%rbp` frame pointer. No value is kept in a register across a `call`.
* `bsk_program` never returns (main ends with `end`); FN functions return through the epilogue,
  result in `%xmm0`.

#### 5.4.5 Per-opcode translation

`S(t)` denotes `<8*slot(t)>(%rsp)`, `V(x)` denotes `<8*x>(%rbx)`, "store" means
`movsd %xmm0, S(DST)`.

| Op | x86_64 sequence |
|----|-----------------|
| `line` | `.Lbsk_L<id>:` then `movl $<n>, bsk_curline(%rip)` (`bsk_curline` is the runtime's u32) |
| `label` | `.Lbsk_L<id>:` |
| `const` | `movabsq $0x<16 uppercase hex>, %rax` / `movq %rax, S(DST)` |
| `ldv` | `movsd V(x), %xmm0` / store |
| `stv` | `movsd S(A), %xmm0` / `movsd %xmm0, V(x)` |
| `add sub mul` | `movsd S(A), %xmm0` / `addsd`\|`subsd`\|`mulsd S(B), %xmm0` / overflow check (below) / store |
| `div` `pow` | `movsd S(A), %xmm0` / `movsd S(B), %xmm1` / `call bsk_div`\|`call bsk_pow` / store |
| `neg` | `movq S(A), %rax` / `btcq $63, %rax` / `movq %rax, S(DST)` (sign-bit flip, never errors) |
| builtins | `movsd S(A), %xmm0` / `call bsk_sin` … `bsk_int` / store |
| `rnd` | `call bsk_rnd` / store |
| `ald1` | `leaq .Ldesc_<L>(%rip), %rdi` / `movsd S(A), %xmm0` / `call bsk_aref1` / `movsd (%rax), %xmm0` / store |
| `ald2` | `leaq .Ldesc_<L>(%rip), %rdi` / `movsd S(A), %xmm0` / `movsd S(B), %xmm1` / `call bsk_aref2` / `movsd (%rax), %xmm0` / store |
| `ast1` | `leaq .Ldesc_<L>(%rip), %rdi` / `movsd S(A), %xmm0` / `call bsk_aref1` / `movsd S(B), %xmm0` / `movsd %xmm0, (%rax)` |
| `ast2` | `leaq .Ldesc_<L>(%rip), %rdi` / `movsd S(A), %xmm0` / `movsd S(B), %xmm1` / `call bsk_aref2` / `movsd S(C), %xmm0` / `movsd %xmm0, (%rax)` |
| `callfn` | `movsd S(A), %xmm0` / `call .Lfn_<L>` / store |
| `param` | `movsd <8*W>(%rsp), %xmm0` / store |
| `ret` | `movsd S(A), %xmm0` / epilogue (`movq -8(%rbp), %rbx` / `leave` / `ret`) |
| `jmp` | `jmp .Lbsk_L<id>` |
| `jcmp` | `movsd S(A), %xmm0` / `ucomisd S(B), %xmm0` / `j<cc> .Lbsk_L<id>` with eq→`je`, ne→`jne`, lt→`jb`, le→`jbe`, gt→`ja`, ge→`jae` |
| `jfor` | sequence below |
| `gosub` | `leaq .Lbsk_L<ret>(%rip), %rdi` / `call bsk_gosub_push` / `jmp .Lbsk_L<target>` |
| `return` | `call bsk_gosub_pop` / `jmp *%rax` |
| `read` | `call bsk_read` / store |
| `prnum` | `movsd S(A), %xmm0` / `call bsk_print_num` |
| `prstr` | `leaq .Lstr_<id>(%rip), %rdi` / `movl $<len>, %esi` / `call bsk_print_str` |
| `prcomma prsemi prnl` | `call bsk_print_comma` / `call bsk_print_semi` / `call bsk_print_nl` |
| `end` `stop` | `call bsk_end` |
| `matredim` | `leaq .Ldesc_<X>(%rip), %rdi` / `movsd S(A), %xmm0` / with B: `movsd S(B), %xmm1` / `call bsk_mat_redim2`; without B: `call bsk_mat_redim1` |
| `matread` `matzer` `matcon` `matidn` | `leaq .Ldesc_<X>(%rip), %rdi` / `call bsk_mat_read` \| `bsk_mat_zer` \| `bsk_mat_con` \| `bsk_mat_idn` |
| `matprint` | `leaq .Ldesc_<X>(%rip), %rdi` / `movl $<IMM>, %esi` / `call bsk_mat_print` |
| `matcopy` `mattrn` `matinv` | `leaq .Ldesc_<X>(%rip), %rdi` / `leaq .Ldesc_<A>(%rip), %rsi` / `call bsk_mat_copy` \| `bsk_mat_trn` \| `bsk_mat_inv` |
| `matadd` `matsub` `matmul` | `leaq .Ldesc_<X>(%rip), %rdi` / `leaq .Ldesc_<A>(%rip), %rsi` / `leaq .Ldesc_<B>(%rip), %rdx` / `call bsk_mat_add` \| `bsk_mat_sub` \| `bsk_mat_mul` |
| `matscale` | `leaq .Ldesc_<X>(%rip), %rdi` / `leaq .Ldesc_<B>(%rip), %rsi` / `movsd S(A), %xmm0` / `call bsk_mat_scale` |

**Compare semantics.** In AT&T order, `ucomisd X, %xmm0` compares `%xmm0` *with* X and sets only
ZF/PF/CF (OF = SF = 0): ZF = 1 if equal, CF = 1 if `%xmm0` < X, PF = 1 if unordered. The
*unsigned* condition codes are therefore the correct ones (`jb jbe ja jae`; never `jl jle jg
jge`). NaN cannot occur (every arithmetic result is checked), so PF is never consulted.
x86 conditional jumps reach ±2 GiB, so `jcmp` branches straight to its label (no inverse-and-skip
as on arm64).

`jfor A=v, B=l, C=s, X` (exhausted(v,l,s) = (s ≥ 0 and v > l) or (s < 0 and v < l)):

```
    movsd   S(A), %xmm0              # v
    movsd   S(B), %xmm1              # l
    xorpd   %xmm2, %xmm2             # 0.0
    ucomisd S(C), %xmm2              # compare 0.0 with s
    ja      2f                       # 0 > s: negative step
    ucomisd %xmm1, %xmm0             # s >= 0 (also s = -0): exhausted if v > l
    ja      .Lbsk_L<X>
    jmp     3f
2:
    ucomisd %xmm1, %xmm0             # s < 0: exhausted if v < l
    jb      .Lbsk_L<X>
3:
```

**Overflow check** after `addsd/subsd/mulsd` (result in `%xmm0`; an integer compare of the bit
pattern: `|x|` < +∞ exactly when x is finite, NaN patterns compare above +∞):

```
    movq    %xmm0, %rax
    btrq    $63, %rax                # bits of |x|
    movabsq $0x7FF0000000000000, %rcx  # bits of +infinity
    cmpq    %rcx, %rax
    jb      1f                       # finite
    movl    $38, %edi                # ERR_OVERFLOW
    call    bsk_err
1:
```

The error code is written as its decimal value (the emitted file includes nothing); BX takes it
from `ERR_OVERFLOW` in `errors.inc`, never from a literal in its own source.

## 6. Runtime ABI

### 6.1 Program startup and state

The runtime provides `_main`. It initialises its state, calls `_bsk_kern_init` (§6.6), calls
`_bsk_program` (provided by the compiled program, AAPCS64, no arguments), and if that ever returns
calls `_bsk_end`.

Runtime-private state (in `src/runtime`, not visible to programs): print `col` and `out`
counters, a 4096-byte stdout buffer and its fill count, the RND state (initial value 1964), the
DATA cursor (initial 0), the GOSUB stack (1024 × 8 bytes) and its depth, the selected kernel
variant and detected features (§6.6), and the static matrix buffers (§6.6.6).

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
| `_bsk_aref1` | x0 desc, d0 i | x0 addr | `r = ⌊i + ½⌋` evaluated exactly (floor, then +1 if the fractional part >= 0.5; LANGUAGE.md §7.11); `0 <= r <= B1` (the descriptor's current `RTA_B1`) else error 32; address of element r |
| `_bsk_aref2` | x0 desc, d0 i, d1 j | x0 addr | both subscripts checked against the current `RTA_B1`/`RTA_B2`; address `RTA_DATA + 8·(ri·RTA_ROWLEN + rj)` with the current row length |
| `_bsk_gosub_push` | x0 code address | — | depth 1024 → error 39 |
| `_bsk_gosub_pop` | — | x0 code address | empty → error 33 |
| `_bsk_end` | — | noreturn | pending-line newline, flush stdout, `exit(0)`; `exit(1)` instead if a stdout write failed earlier (`_bsk_rt_broken`) |
| `_bsk_err` | w0 code | noreturn | precondition: code is a run-time error code (ERR_* 32..41); any other code exits 1 with no message. Pending-line newline, flush stdout, write `<MESSAGE> IN <_bsk_curline>` + LF to fd 2, `exit(1)` (code 34 exits 0, unless a stdout write failed earlier, then 1) |

The MAT entry points (`_bsk_mat_*`) are specified in §6.5, the matrix kernels and their dispatch
(`_bsk_kern_*`) in §6.6.

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

### 6.4 Runtime ABI on x86_64-linux (implementer RX)

`src/runtime_x86_64_linux/` implements **the same entry points with exactly the §6.1–6.3
semantics** — same state, same initial values, same PRINT column logic, same number format
algorithm, same RND arithmetic, same error texts, exit statuses and broken-stdout rule
(LANGUAGE.md §10) — for x86_64 Linux (glibc), under ELF names and the System V AMD64 ABI. Every
test in `tests/programs` and every run-phase test in `tests/errors` must produce byte-identical
stdout/stderr and the same exit status on both targets.

#### 6.4.1 Calling convention

System V AMD64 for every global function: integer/pointer arguments `%rdi %rsi %rdx %rcx %r8
%r9`, doubles `%xmm0–%xmm7`, results `%rax` / `%xmm0`; callee-saved `%rbx %rbp %r12–%r15`;
everything else (incl. all `%xmm`) caller-saved; `%rsp` ≡ 0 (mod 16) at every `call` (≡ 8 at
function entry); direction flag clear on entry and exit; MXCSR and the x87 control word never
changed. Runtime functions may clobber every caller-saved register (generated code keeps nothing
in registers across calls, §5.4.4).

#### 6.4.2 Symbols and register mapping

Names are the §6.2 names without the leading underscore. Register mapping from the arm64 ABI:
`d0`→`%xmm0`, `d1`→`%xmm1`, pointer/integer argument `x0`→`%rdi`, `x1`→`%rsi`, `w0` (error
code) → `%edi`, pointer result `x0`→`%rax`, double result `d0`→`%xmm0`.

| Symbol | In | Out |
|--------|----|-----|
| `main` | (argc, argv ignored) | never returns: `call bsk_program`, then `call bsk_end` |
| `bsk_curline` | — | u32 data, `.bss`, `.globl`, 4-byte aligned, initially 0 |
| `bsk_print_num` | `%xmm0` | — |
| `bsk_print_str` | `%rdi` ptr, `%rsi` len | — |
| `bsk_print_comma` `bsk_print_semi` `bsk_print_nl` | — | — |
| `bsk_read` | — | `%xmm0` |
| `bsk_div` `bsk_pow` | `%xmm0` a, `%xmm1` b | `%xmm0` |
| `bsk_chk` | `%xmm0` | `%xmm0` |
| `bsk_sin bsk_cos bsk_tan bsk_atn bsk_exp bsk_abs bsk_log bsk_sqr bsk_int` | `%xmm0` | `%xmm0` |
| `bsk_rnd` | — | `%xmm0` |
| `bsk_aref1` | `%rdi` desc, `%xmm0` i | `%rax` element address |
| `bsk_aref2` | `%rdi` desc, `%xmm0` i, `%xmm1` j | `%rax` element address |
| `bsk_gosub_push` | `%rdi` code address | — |
| `bsk_gosub_pop` | — | `%rax` code address |
| `bsk_end` | — | noreturn |
| `bsk_err` | `%edi` ERR_* code | noreturn |
| `bsk_mat_redim1` | `%rdi` desc, `%xmm0` r | — |
| `bsk_mat_redim2` | `%rdi` desc, `%xmm0` r, `%xmm1` c | — |
| `bsk_mat_read` `bsk_mat_zer` `bsk_mat_con` `bsk_mat_idn` | `%rdi` desc | — |
| `bsk_mat_print` | `%rdi` desc, `%esi` mode | — |
| `bsk_mat_copy` `bsk_mat_trn` `bsk_mat_inv` | `%rdi` dst, `%rsi` src | — |
| `bsk_mat_add` `bsk_mat_sub` `bsk_mat_mul` | `%rdi` dst, `%rsi` a, `%rdx` b | — |
| `bsk_mat_scale` | `%rdi` dst, `%rsi` src, `%xmm0` k | — |
| `bsk_kern_init` | — | — |
| `bsk_kern_use` | `%rdi` name | `%rax` 0 / −1 |
| `bsk_kern_name` `bsk_kern_variants` | — | `%rax` pointer |
| `bsk_kern_features` | — | `%rax` `KF_*` bits |
| `bsk_kern_gemm` `bsk_kern_add` `bsk_kern_sub` | `%rdi` C, `%rsi` A, `%rdx` B | `%rax` `KS_*` |
| `bsk_kern_scale` | `%rdi` C, `%rsi` A, `%xmm0` k | `%rax` `KS_*` |
| `bsk_kern_trn` `bsk_kern_copy` | `%rdi` C, `%rsi` A | — |
| `bsk_kern_fill` | `%rdi` C, `%xmm0` v | — |
| `bsk_kern_inv` | `%rdi` X, `%rsi` A | `%rax` `KS_*` |

Defined by every compiled program (§5.4.3): `bsk_program` (code, System V, no arguments),
`bsk_data` (8-byte aligned doubles), `bsk_data_count` (u64). The `RTA_*` descriptor layout is
unchanged (`runtime.inc`). `main` is entered from glibc's start code with `%rsp` ≡ 8 (mod 16), so
it pushes `%rbp` before its first `call`.

#### 6.4.3 System interface

Only glibc and libm, always called through the PLT (`call write@PLT`):

| Need | Function |
|------|----------|
| output | `write(fd, buf, len)`; errno via `__errno_location()` (returns `int*`); `EINTR` = 4 on Linux |
| termination | `exit(status)` (the C function, as `_exit` symbol is on Mach-O) |
| number format | `snprintf(buf, n, "%.5e", fabs(x))`: variadic, so **`%al` = number of vector registers used** — `movl $1, %eax` (one double in `%xmm0`) immediately before `call snprintf@PLT` |
| builtins | `sin cos tan atan exp log pow` (libm) and `trunc` for `bsk_int`; `bsk_sqr` uses `sqrtsd` of `fabs(x)`; `bsk_abs` clears the sign bit |
| kernel selection | `getenv("BAYSICK_KERNELS")`; CPU features with the `cpuid` and `xgetbv` instructions (§6.6.2) |

Integers below 10⁹ are converted with `cvttsd2si` (the `fcvtzu` analogue); everything else in
`rt_numfmt` follows §6.2. Instruction set: the x86-64 baseline (SSE2) only — no SSE4.1
(`roundsd`), AVX or BMI — so the runtime runs on any x86_64 machine. The single exception is a
kernel variant file (`rt_k<variant>_*.s`, §6.6), which may use exactly the instructions its
`KV_REQUIRES` bits guarantee; it is only ever reached through the variant table after detection. No stdio, no `signal`
calls: a closed pipe raises `SIGPIPE` exactly as on macOS.

#### 6.4.4 Assembly style for the x86_64 runtime

* GNU `as` 2.38 or newer, AT&T syntax (§5.4.2), assembled with `as --64 --fatal-warnings -I
  include` (no C preprocessor); `#` comments (anywhere on a line); 4-space indent.
* Every file begins with `.include "baysick.inc"` and uses the include constants by name
  (`ERR_*`, `RTA_*`, `PRINT_*`, `RNG_*`, `LIM_GOSUB_DEPTH`, `RT_OUTBUF_SIZE`, `EXIT_RUN_*`); every
  file ends with `.section .note.GNU-stack,"",@progbits`.
* Global entry points `.globl` + `.type name, @function`; runtime-private cross-file symbols are
  named `bsk_rt_*` and declared `.globl` + `.hidden` (the ELF counterpart of
  `.private_extern`); file-local labels `.Lrt_<file>_<function>_<what>`; numeric labels only for
  jumps of a few instructions.
* Sections: code `.text` (`.p2align 4` per function); constants `.section .rodata`; tables of
  pointers (e.g. `BSK_EMIT_ERRMSG_TABLE .Lrt_errmsg` for `bsk_err`) in
  `.section .data.rel.ro,"aw",@progbits`; mutable data `.data`; zero-initialised state `.bss`
  with `.p2align` + label + `.zero <n>`.
* The function header block of §3.4 (purpose, inputs, outputs, clobbers, callee-saved registers
  used and their role, frame size), in System V terms; a comment at least every few
  instructions.

### 6.5 MAT layer (`rt_mat.s`, both targets)

The `_bsk_mat_*` entry points implement LANGUAGE.md §7.14 on whole arrays named by their `RTA_*`
descriptors (writable, emitted by the backend with `RTA_CAP` = `(b1+1)·(b2+1)`). They own every
BASIC rule — shapes, conformability, redimensioning, aliasing, OVERFLOW, `DIMENSION ERROR`,
`SINGULAR MATRIX`, the DATA cursor and the PRINT column — and delegate the arithmetic to the
kernels (§6.6). arm64 names below; x86_64 drops the underscore (§6.4.2).

| Function | In | Semantics (LANGUAGE.md) |
|----------|----|-------------------------|
| `_bsk_mat_redim1` | x0 desc, d0 r | redimension to `r × 1` (§7.14.3); error 40 |
| `_bsk_mat_redim2` | x0 desc, d0 r, d1 c | redimension to `r × c`; error 40 |
| `_bsk_mat_read` | x0 desc | MAT READ with the current shape, row by row via the DATA cursor; OUT OF DATA exactly as `_bsk_read` |
| `_bsk_mat_print` | x0 desc, w1 mode | §7.14.5 steps 2–3 (the empty line between items is the `prnl` the compiler emits) |
| `_bsk_mat_zer` `_bsk_mat_con` | x0 desc | fill the current matrix with 0 / 1 |
| `_bsk_mat_idn` | x0 desc | square check (error 40), identity |
| `_bsk_mat_copy` `_bsk_mat_trn` `_bsk_mat_inv` | x0 dst, x1 src | §7.14.4 steps 2–6; INV per §7.14.6 (errors 40, 41, 38) |
| `_bsk_mat_add` `_bsk_mat_sub` `_bsk_mat_mul` | x0 dst, x1 a, x2 b | §7.14.4 steps 2–6 (errors 40, 38) |
| `_bsk_mat_scale` | x0 dst, x1 src, d0 k | dst = (k)·src; steps 2–6 |

Rules every implementation follows:

* **Dimension arguments** (`redim1/2`): compared as doubles before any conversion, like
  `_bsk_aref*`: `x < 0.5` (or NaN, impossible here) → error 40; `x >= 2³¹` → error 40 (no shape that
  large fits any storage); otherwise `d = ⌊x + ½⌋` exactly. Then the §7.14.3 storage test with
  64-bit products. Effect: list → `RTA_B1 = r`; table → `RTA_B1 = r`, `RTA_B2 = c`,
  `RTA_ROWLEN = c + 1`.
* **Shape of an operand**: table `(RTA_B1, RTA_B2)`, list `(RTA_B1, 1)`; a zero → error 40.
  **View** (`MV_*`, runtime.inc): table `MV_DATA = RTA_DATA + 8·(ROWLEN + 1)`,
  `MV_LD = ROWLEN`; list `MV_DATA = RTA_DATA + 8`, `MV_LD = 1`.
* **Order** (§7.14.4): operand shapes and conformability → the target-fits test (the §7.14.3
  test against the target's `RTA_CAP`, without changing it yet) → compute → kernel status
  (`KS_NONFINITE` → error 38, `KS_SINGULAR` → error 41) → set the target's shape → store.
* **Aliasing** ("as if into a temporary"): when the destination descriptor is the same as an
  operand's (pointer equality — two descriptors never share storage):
  * `+`, `-`, `(K)*`: the shape does not change, so the destination view equals the operand
    view; the element-wise kernels are called in place (allowed, §6.6.1);
  * `MAT A = A`: nothing to do (after the checks);
  * `*`, TRN, INV: compute into the static result temporary (`RT_MAT_SCRATCH_ELEMS` doubles,
    view `MV_LD = cols`), then set the shape and `_bsk_kern_copy` into the destination.
  When the destination is not an operand, the destination's shape is set first and the kernel
  writes straight into it (a later error stops the program, so partial results are never seen).
* **MAT PRINT** uses the runtime's own §8 printer (the column state is runtime-private, shared by
  `rt_print.s` and `rt_mat.s`): `col ≠ 0` → newline; per element `_bsk_print_num`; between
  elements of a row the comma or semicolon rule; newline after each row; a list is one row.
* `_bsk_mat_read` stores each value as it is read (an OUT OF DATA in the middle leaves the earlier
  elements stored; the program ends anyway).
* Error codes come from `errors.inc` by name; `_bsk_err` is called with `_bsk_curline` already set
  by the statement's `line`.

### 6.6 Matrix kernels and CPU-feature dispatch (`rt_kinit.s`, `rt_k*.s`, both targets)

The heavy arithmetic lives in **kernels**: plain routines on matrix views with no BASIC
semantics, reached through one dispatch point chosen once at startup from the CPU's features. A
**variant** is a set of kernels for one instruction-set level. Required now: **`neon`**
(arm64-macos baseline, Advanced SIMD) and **`sse2`** (x86_64-linux baseline). Documented future
examples: **`sme`** (Apple M4 and later: SME with FEAT_SME_F64F64) and **`avx2`** (x86_64 with
AVX2 and FMA3). Adding a variant touches only the runtime directory of its target (§6.6.7).

#### 6.6.1 Kernel interface

All views are `MV_*` records (runtime.inc). Preconditions: `MV_ROWS, MV_COLS ≥ 1`,
`MV_LD ≥ MV_COLS` (any `MV_LD` when `MV_COLS = 1`), any 8-byte-aligned `MV_DATA` (results must
not depend on alignment), every input element finite.

| Kernel (exported trampoline) | Arguments | Result | Shapes / overlap |
|-----------------------------|-----------|--------|------------------|
| `_bsk_kern_gemm` | x0 C, x1 A, x2 B | x0 `KS_*` | A `m×k`, B `k×n`, C `m×n`; C must not overlap A or B |
| `_bsk_kern_add` `_bsk_kern_sub` | x0 C, x1 A, x2 B | x0 `KS_*` | all `m×n`; C may be A or B exactly (same `MV_DATA`, `MV_LD`), no other overlap |
| `_bsk_kern_scale` | x0 C, x1 A, d0 k | x0 `KS_*` | `m×n`; C may be A exactly |
| `_bsk_kern_trn` | x0 C, x1 A | — | A `m×n`, C `n×m`; no overlap |
| `_bsk_kern_copy` | x0 C, x1 A | — | `m×n`; no overlap |
| `_bsk_kern_fill` | x0 C, d0 v | — | every element of C := v |
| `_bsk_kern_inv` | x0 X, x1 A | x0 `KS_*` | A, X `n×n`, `n ≤ RT_KERN_INV_MAXN`; no overlap; LANGUAGE.md §7.14.6 exactly (incl. `KS_SINGULAR`, and `KS_NONFINITE` for a non-finite pivot or result) |

`KS_NONFINITE` is returned when any stored result element is ±infinity or NaN (fused into the
kernel or as a separate vectorised pass). Kernels never print, never call `_bsk_err`, never
allocate, never change FPCR/MXCSR (round-to-nearest, no flush-to-zero, no default-NaN changes),
and use only the static buffers of §6.6.6 (not reentrant: programs are single-threaded). They
follow the target ABI (AAPCS64: `d8–d15` low halves callee-saved, `v16–v31` free; System V: all
`%xmm` caller-saved). **Link isolation:** the kernel files (`rt_kinit.s`, `rt_k*.s`) reference no
symbol defined in any other runtime file (only each other and libc), so the benchmark harness can
link `libbaysickrt.a` with its own `main` (BENCH.md).

#### 6.6.2 Feature detection

`_bsk_kern_init()` (idempotent; `_main` calls it before `_bsk_program`, the bench harness calls it
first) fills the runtime-private feature mask returned by `_bsk_kern_features()` (`KF_*`,
runtime.inc):

| Bit | Target | Detection key |
|-----|--------|---------------|
| `KF_A64_SME` | arm64-macos | `sysctlbyname("hw.optional.arm.FEAT_SME", &v, &len, NULL, 0) == 0 && v == 1` (32-bit `v`) |
| `KF_A64_SME2` | arm64-macos | same with `"hw.optional.arm.FEAT_SME2"` |
| `KF_A64_SME_F64F64` | arm64-macos | same with `"hw.optional.arm.FEAT_SME_F64F64"` |
| `KF_X64_AVX2` | x86_64-linux | `CPUID.(EAX=7,ECX=0):EBX[5]`, and OS support: `CPUID.1:ECX[27]` (OSXSAVE) and `XGETBV(ECX=0)` bits 1 and 2 both set |
| `KF_X64_FMA` | x86_64-linux | `CPUID.1:ECX[12]`, with the same OS-support test |

A missing sysctl key or a failing call means "absent". (The development Mac, an M2 Pro, reports
`FEAT_SME = 0`, `FEAT_SME_F64F64 = 0`; Apple M4 and later report SME with F64F64.) A new
feature bit is a contract change (`runtime.inc` + this table).

#### 6.6.3 Variant table and selection

Each runtime has one read-only table of `KV_*` records (runtime.inc), **best variant first,
baseline last** (`KV_REQUIRES = 0`). A record names the variant and holds one function pointer
per kernel; a variant that does not specialise a kernel points that slot at the baseline
function. The table is the only registration point. Selection in `_bsk_kern_init`:

1. Detect the features (§6.6.2). A record is **usable** when all its `KV_REQUIRES` bits are
   detected.
2. Read the environment variable `BAYSICK_KERNELS` (`getenv`): unset, empty or `auto` → the
   first usable record; `baseline` → the last record; the name of a usable record → that
   record; anything else → as `auto` (silently: programs never print diagnostics of their own).
3. Store the chosen record's address in the runtime-private current-variant pointer.

The exported `_bsk_kern_gemm` … `_bsk_kern_inv` are trampolines: load the current record, load
the slot, branch to it (arm64 `ldr x16, [x16, #KV_GEMM]` / `br x16`; x86_64 `jmp *KV_GEMM(%rax)`),
arguments untouched. `_bsk_kern_use(name)` re-selects by name (only the names of usable variants and `baseline` are
accepted; `auto` is not a name here, it returns −1 like any unknown name; 0 on success, −1 and no
change if the name is unknown or not usable); `_bsk_kern_name()` returns the current
`KV_NAME`; `_bsk_kern_variants()` returns a static NULL-terminated array of the usable names, in
table order. The MAT layer calls only the trampolines (or reads the current record directly).

| Variant | Target | `KV_REQUIRES` | Status | Specialises |
|---------|--------|---------------|--------|-------------|
| `neon` | arm64-macos | 0 | **required now** (baseline) | all |
| `sme` | arm64-macos | `KF_A64_SME \| KF_A64_SME_F64F64` | future | GEMM (FMOPA outer products into ZA tiles) |
| `sse2` | x86_64-linux | 0 | **required now** (baseline) | all |
| `avx2` | x86_64-linux | `KF_X64_AVX2 \| KF_X64_FMA` | future | GEMM (FMA), optionally the class-E kernels |

#### 6.6.4 Determinism rules (all variants)

* **Class R — GEMM only.** Any summation order, blocking and fused multiply-add are allowed
  (LANGUAGE.md §7.14.7); the result must be a deterministic function of the variant, the shapes
  and the values (no dependence on addresses, alignment, timing, earlier calls; no threads).
* **Class E — everything else** (add, sub, scale, trn, copy, fill, inv): the result must be
  **bit-identical to the baseline variant** — one IEEE operation per element for add/sub/scale,
  exact copies for trn/copy/fill, and LANGUAGE.md §7.14.6 exactly for inv (no FMA, true division;
  only the sign of zero elements may differ). A variant may vectorise wider, never reassociate.
* The status result (`KS_*`) is part of the result: class-E kernels report the same status as the
  baseline; GEMM reports `KS_NONFINITE` exactly when an element it stored is not finite.
* The test corpus is target- and variant-independent because its products are exact
  (LANGUAGE.md §7.14.7) and everything else is class E. Run it per variant with
  `BAYSICK_KERNELS=<name> sh tests/run.sh` (and the same variable in the environment of
  `tests/cross_run.sh` on Linux).

#### 6.6.5 Performance contract (baseline variants, required now)

* **GEMM** — the Goto/BLIS structure: loop over column blocks of width NC, inner-dimension
  blocks of depth KC (pack the `KC × NC` block of B into NR-wide micro-panels), row blocks of
  height MC (pack the `MC × KC` block of A into MR-high micro-panels), then a **register-blocked
  micro-kernel** that keeps an `MR × NR` block of C in registers for the whole KC loop, streaming
  the packed panels. Partial tiles at the edges come from zero-padded packing and partial stores
  (padding contributes exact zeros). Packing buffers are static and 64-byte aligned.
  * `neon`: at least 32 accumulator doubles (16 `v` registers; recommended `MR × NR = 8 × 6`, 24
    accumulators), `fmla` (by-element form allowed). Starting points to tune on the M2 Pro
    P-core (128 KiB L1D, 16 MiB L2): KC = 256, MC = 128, NC = 2048.
  * `sse2`: at least 8 accumulator registers (`MR × NR = 4 × 4`; 4 × 6 if the registers allow),
    `mulpd` + `addpd` (no FMA in SSE2). Starting points (Haswell, 32 KiB L1D, 256 KiB L2):
    KC = 256, MC = 96, NC = 2048.
  * For tiny products (`m·n·k ≤ 32768`) an unpacked, still vectorised path is allowed.
* **add, sub, scale, copy, fill** — row loop × contiguous inner loop of 2-wide vectors, unrolled
  to at least 4 vectors per iteration, scalar tail; the finite check fused into the same pass.
* **trn** — cache-blocked (e.g. 32 × 32 element blocks) with in-register tile transposes
  (`neon`: `zip1`/`zip2` on `.2d` building 2 × 2 or 4 × 4 tiles; `sse2`: `unpcklpd`/`unpckhpd`).
* **inv** — the §7.14.6 algorithm with the pivot-row division and the row updates vectorised
  2-wide over `j` (`fdiv`/`divpd`; `fmul` then `fsub` / `mulpd` then `subpd`; never `fmla`).
  The row updates may use a delayed or blocked schedule (the x86_64 runtime updates in panels of
  16 pivot columns with a register-blocked micro-kernel), provided every element receives exactly
  the pinned operations in the pinned order (one rounded product, one rounded subtraction, true
  divisions). Updates whose product is zero may be skipped as LANGUAGE.md §7.14.6 allows (the
  arm64 runtime skips the products with the untouched, exactly zero columns of X).
* Benchmarks and initial goals: BENCH.md.

#### 6.6.6 Static buffers

All in zero-initialised data (`.zerofill __DATA,__bss,…,6` / `.bss` with `.p2align 6`); untouched
pages cost nothing:

| Buffer | Size | Owner |
|--------|------|-------|
| MAT result temporary | `RT_MAT_SCRATCH_ELEMS` doubles (8 MiB) | `rt_mat.s` (aliasing, §6.5) |
| INV workspace W | `RT_KERN_INV_MAXN²` doubles (8 MiB) | inv kernel |
| INV index buffer `_bsk_rt_kinv_idx` (arm64) | 3 × `RT_KERN_INV_MAXN` u32 (12 KiB): row-of, unit-position and column-of bookkeeping for the column order of X | `rt_kneon_inv.s` |
| GEMM packing buffers | runtime-private, at most 8 MiB in total | gemm kernel |

#### 6.6.7 Adding a kernel

To add a variant (for example `sme` or `avx2`) or to specialise one kernel of an existing one:

1. **Detection key.** Use an existing `KF_*` bit, or add one: a new bit in `runtime.inc`, its key
   in the §6.6.2 table, and its detection code in that target's `rt_kinit.s` (contract change:
   include + this document together).
2. **Code.** New files `rt_k<variant>_*.s` in the target's runtime directory, exporting nothing
   global except runtime-private symbols (`.private_extern` / `.hidden`), obeying §6.6.1 and the
   link-isolation rule. SME kernels enter streaming mode and enable ZA themselves (`smstart`), do
   not call any function while in streaming mode, use only instructions legal in streaming mode
   (Advanced SIMD is not, unless FEAT_SME_FA64), and leave with `smstop` (PSTATE.SM = 0,
   PSTATE.ZA = 0) on every path. AVX2 kernels end with `vzeroupper`.
3. **Registration.** One `KV_*` record in the variant table, ahead of the baseline (order =
   preference), `KV_REQUIRES` = the bits it needs, unspecialised slots pointing at the baseline
   functions.
4. **Determinism.** GEMM: class R; everything else: bit-identical to the baseline (§6.6.4).
   Verify with `BAYSICK_KERNELS=<variant> sh tests/run.sh` (and on Linux through
   `tests/cross_run.sh`), plus the harness's own validation (BENCH.md), which compares every
   kernel against the baseline and the vendor library.
5. **Benchmark.** `make bench` / `make bench-cross` measure every usable variant
   (`_bsk_kern_variants`); report the new rows as BENCH.md describes. A variant that is slower
   than the one below it in the table on its target hardware is not registered.

## 7. Targets and porting

The design keeps every target-specific decision behind the descriptor and the runtime ABI. Two
targets exist:

| Target | Backend (in the compiler) | Emits | Runtime | Built / linked where |
|--------|---------------------------|-------|---------|----------------------|
| `arm64-macos` | `src/backend/arm64_macos/` (§5.2–5.3) | Apple `as` arm64 Mach-O | `src/runtime/` (§6.1–6.3) | the Mac, by the driver |
| `x86_64-linux` | `src/backend/x86_64_linux/` (§5.4) | GNU `as` AT&T x86_64 ELF | `src/runtime_x86_64_linux/` (§6.4) | the `.s` on the Mac; runtime, `as` and `gcc -no-pie … -lm` on Linux (§8) |

On a Linux machine with a built runtime (`make -f Makefile.linux`), a program compiled on the
Mac with `build/baysick --target x86_64-linux prog.bas` becomes an executable with:

```
as --64 -o prog.o prog.s
gcc -no-pie -o prog prog.o build-x86_64-linux/libbaysickrt.a -lm
```

Nothing in the frontend, IR, verifier, dumper, `tests/` corpus (outputs are target-independent by
construction) or LANGUAGE.md depends on the target. A further target needs: a backend directory
exporting a descriptor (§5.1) listed in `_drv_targets`, a runtime implementing §6.2's semantics
under that platform's ABI, and its own section here.

## 8. Build and test

### 8.1 macOS (`Makefile`)

* `make` builds `build/baysick` from `src/frontend/*.s src/ir/*.s src/driver/*.s
  src/backend/*/*.s` (both backends: they are compiler code) and `build/libbaysickrt.a` from
  `src/runtime/*.s`, using only `as`, `ld`, `ar` and `xcrun`. The compiler is linked with the same
  `ld` options as user programs (§5.2), without the runtime. The macOS `Makefile` never touches
  `src/runtime_x86_64_linux/` (x86_64 sources cannot be assembled by Apple `as`).
* `make test` runs `tests/run.sh` (it builds nothing; it requires `build/baysick` and
  `build/libbaysickrt.a`). It tests the default target only.
* `make check-includes`: §3.4 (trailing-comment grep + `tests/include_check.s`).
* `make cross-pack` (depends on `all`): `sh tests/cross_pack.sh -o build/x86_64-linux-bundle`.
* `make cross` (depends on `all`): `sh tests/cross.sh` (default host `desktop`).
* `make bench` / `make bench-cross`: BENCH.md (owned by BENCH).
* Kernel variants: `BAYSICK_KERNELS=<variant> sh tests/run.sh` runs the corpus with a chosen
  variant (§6.6.4); expected outputs are the same for every variant.
* `COMPILER_DIRS` (the "not implemented yet" check) lists `src/backend/x86_64_linux` too.
* Test sidecar formats are documented at the top of `tests/run.sh`.

### 8.2 Linux runtime build (`Makefile.linux`)

Run on x86_64 Linux with GNU make, GNU `as` ≥ 2.38 and `ar` (no compiler is needed to build the
runtime; `gcc` only links test programs):

```
make -f Makefile.linux                  build-x86_64-linux/libbaysickrt.a
make -f Makefile.linux check-includes   assemble tests/include_check_x86_64.s
make -f Makefile.linux clean            rm -rf build-x86_64-linux
```

* Variables (overridable on the command line or from the environment): `AS ?= as`, `AR ?= ar`;
  fixed `ASFLAGS := --64 --fatal-warnings -I include`; build directory `build-x86_64-linux`.
* Objects: `src/runtime_x86_64_linux/<name>.s` → `build-x86_64-linux/obj/<name>.o` (depend on
  every `include/*.inc`); archive `build-x86_64-linux/libbaysickrt.a` via `rm -f $@` +
  `$(AR) rcs $@ <objs>`; `.DEFAULT_GOAL := all`; `all clean check-includes` are `.PHONY`.
* `check-includes`: `$(AS) $(ASFLAGS) -I tests -o build-x86_64-linux/include_check.o
  tests/include_check_x86_64.s`, then prints `include files assemble and layout assertions hold`.
* If `src/runtime_x86_64_linux/` has no `*.s` files, `all` fails with
  `make: no assembly sources in: src/runtime_x86_64_linux` (like the macOS `check-sources`).
* If `uname -sm` is not `Linux x86_64`, every target fails at once with
  `Makefile.linux: build the x86_64 runtime on x86_64 Linux (uname -sm is '<value>')`.

### 8.3 Cross testing x86_64-linux

The run half executes on Linux; compiling happens only on the Mac (the compiler is a macOS arm64
binary). `tests/programs/*.bas` and the **run-phase** cases of `tests/errors/` are tested;
compile-phase errors and `tests/ir/` are target-independent (they never reach a backend) and are
covered by `make test`.

**Bundle.** A self-contained directory, produced on the Mac, consumed on Linux:

```
<bundle>/BUNDLE                          one line: "baysick-x86_64-linux-bundle 1"
<bundle>/Makefile.linux                  copies of the repository files
<bundle>/include/*.inc
<bundle>/src/runtime_x86_64_linux/*.s
<bundle>/tests/cross_run.sh
<bundle>/tests/include_check_x86_64.s
<bundle>/tests/include_asserts.inc
<bundle>/cases/programs/NAME.s NAME.out [NAME.err]           from tests/programs/NAME.*
<bundle>/cases/errors/NAME.s NAME.meta NAME.err [NAME.out]   run-phase tests/errors/NAME.*
<bundle>/cases/<kind>/NAME.packfail      instead of NAME.s when compiling on the Mac failed:
                                         "status <n>" line, then the compiler's stderr
```

**`tests/cross_pack.sh`** (macOS, POSIX sh):

```
sh tests/cross_pack.sh -o BUNDLE_DIR [PATTERN...]
```

* `-o BUNDLE_DIR` is required; the directory must not exist or must be empty (else exit 2).
  PATTERN selects tests whose name (`programs/NAME`, `errors/NAME`) contains a pattern, as in
  `tests/run.sh`.
* Environment: `BAYSICK` (compiler, default `build/baysick`).
* For each selected case: `"$BAYSICK" --target x86_64-linux -S NAME.bas -o
  BUNDLE_DIR/cases/<kind>/NAME.s`. It must exit 0 with empty stdout and stderr; otherwise the
  `.s` is removed and `NAME.packfail` written. Sidecars are copied unchanged. A `tests/errors`
  case with `phase=compile` is skipped silently.
* Exit: 0 = bundle complete (even if some `.packfail` exist — the run half reports them as
  failures); 2 = setup error (compiler missing, bad `-o`, copy failure). Prints
  `packed: <n> cases (<m> failed to compile)`.

**`tests/cross_run.sh`** (Linux, POSIX sh):

```
sh tests/cross_run.sh [-v] [BUNDLE_DIR]
```

* `BUNDLE_DIR` defaults to the directory above the script's own directory. `-v` shows diffs as
  in `tests/run.sh`.
* Environment: `BAYSICK_TEST_TIMEOUT` (seconds per program, default 10), `AS` (default `as`),
  `CC` (default `gcc`).
* Setup (any failure → message on stderr, exit 2): `BUNDLE` marker present and equal to the line
  above; `make -C BUNDLE_DIR -f Makefile.linux check-includes all AS="$AS"`.
* Per case, in a `mktemp -d` work directory removed on exit: `NAME.packfail` → FAIL
  `compile (on the Mac) failed: …`; else `$AS --64 -o prog.o NAME.s` then
  `$CC -no-pie -o prog prog.o BUNDLE_DIR/build-x86_64-linux/libbaysickrt.a -lm` (the §5.4.1
  templates); each must exit 0 **with empty stderr** (a warning such as a missing
  `.note.GNU-stack` is a failure) → else FAIL `assemble failed` / `link failed`. Then run with
  stdin `/dev/null` and the timeout, and compare exactly like `tests/run.sh`: programs: exit 0,
  stdout = `.out`, stderr = `.err` or empty; run-phase errors: exit = `exit=` of `.meta`,
  stderr = `.err`, stdout = `.out` or empty.
* Output format and exit status identical to `tests/run.sh` (`FAIL <name>: <reason>` lines, then
  `----` and `passed: P  failed: F`, `failed tests: …`); exit 0 all passed, 1 any failed,
  2 setup error.

**`tests/cross.sh`** (macOS; one command for the developer):

```
sh tests/cross.sh [-v] [-H HOST] [PATTERN...]
```

* Host: `-H HOST`, else `$BAYSICK_CROSS_HOST`, else `desktop` (an `ssh` destination with key
  authentication; `ssh -o BatchMode=yes -- HOST` is used, so a password prompt is an error and a host starting with `-` cannot be read as an option).
* Steps: `cross_pack.sh` into a local `mktemp -d` directory (removed on exit); stream it as
  `tar -C <bundle> -cf - .` into **one** `ssh` call whose remote command is
  `sh -c '<script>' sh [-v]`, where `<script>` contains no single quote (so it works under any
  login shell) and does: `d=$(mktemp -d "${TMPDIR:-/tmp}/baysick-cross.XXXXXX")`,
  `trap "rm -rf \"\$d\"" EXIT` plus `trap "rm -rf \"\$d\"; exit 2" HUP INT TERM PIPE` (double quotes inside the script; the signal trap removes the directory itself because dash/busybox `sh` do not run the EXIT trap on a fatal signal, e.g. when the ssh connection drops),
  `tar -C "$d" -xf -`, `BAYSICK_TEST_TIMEOUT=<value> sh "$d/tests/cross_run.sh" [-v] "$d"`, and
  exits with its status. Nothing is left on the remote machine.
* Environment: `BAYSICK` (passed to `cross_pack.sh`), `BAYSICK_TEST_TIMEOUT` (forwarded),
  `BAYSICK_KERNELS` (forwarded when set, so the remote runs use that kernel variant, §6.6.4; it must
  consist of letters, digits and underscores, else exit 2, which keeps the remote script free of
  single quotes: the remote command becomes `BAYSICK_TEST_TIMEOUT=<value> BAYSICK_KERNELS=<value> sh
  "$d/tests/cross_run.sh" …`), `BAYSICK_CROSS_HOST`.
* Exit: the status of `cross_run.sh` (0/1/2); 2 if packing fails, `ssh` itself fails
  (status 255) or the remote status is anything else (e.g. 127 no `sh`, 137 killed).
* `make cross-pack` removes `build/x86_64-linux-bundle` first, so it can be run repeatedly
  (`cross_pack.sh` itself still refuses a non-empty `-o` directory).
* All three scripts (and `cross_pack.sh`/`run.sh` PATTERNs) treat signals HUP/INT/TERM/PIPE by
  removing their temp directory and exiting 2; patterns are matched literally (globbing is off
  while they are split).

### 8.4 CI (`.github/workflows/ci.yml`)

* Job `macos-arm64` (unchanged steps, then): step `Pack x86_64-linux test bundle` runs
  `make cross-pack`; step `Upload x86_64-linux test bundle` uses `actions/upload-artifact@v4`
  with `name: x86_64-linux-bundle`, `path: build/x86_64-linux-bundle/`,
  `if-no-files-found: error`, `retention-days: 7`.
* Job `x86_64-linux`: `needs: macos-arm64`, `runs-on: ubuntu-latest`, `timeout-minutes: 15`, no
  checkout (the bundle is self-contained, so Linux tests exactly what the Mac packed). Steps:
  `actions/download-artifact@v4` (`name: x86_64-linux-bundle`, `path: bundle`); `Toolchain info`
  (`uname -m`, `as --version | head -1`, `gcc --version | head -1`); `Cross tests`:
  `sh bundle/tests/cross_run.sh bundle`; on failure, upload `bundle/build-x86_64-linux/` as
  artifact `build-x86_64-linux` (`if-no-files-found: ignore`).
