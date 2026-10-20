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
src/runtime_x86_64_linux/rt_kavx2_gemm.s AVX2+FMA GEMM: packing, 6x8 micro-kernel with 12 ymm accumulators
src/runtime_x86_64_linux/rt_kavx2_elem.s AVX2 copy/fill and the finite-check helper (add/sub/scale: sse2 kernels, §6.6.3)
src/runtime_x86_64_linux/rt_kavx2_trn.s  AVX2 blocked transpose, 4x4 in-register tiles
src/runtime_x86_64_linux/rt_kavx2_inv.s  pinned Gauss-Jordan inverse, AVX2 4-wide row updates (4x12 micro-kernel)
bench/                                   BENCH: harness, peak loops, programs, scripts (BENCH.md)
```

Future kernel variants add files named `rt_k<variant>_*.s` in the runtime directory
(`rt_ksme_gemm.s`, …) and one record in the variant table (§6.6.7).

Files added for the Third and Fourth Edition features (§2.3; owners may refine the split inside
their directory):

```
src/frontend/fe_str.s       string references, string LET/IF/PRINT items, TAB, CHANGE, the
                            MISMATCHED STRING OPERATION checks (LANGUAGE.md 4.4-4.5, 7.19)
src/frontend/fe_input.s     INPUT, RESTORE, ON, RANDOMIZE, MAT INPUT (LANGUAGE.md 7.14.8, 7.15-7.18)
src/frontend/fe_def.s       DEF with 0..8 parameters, the multi-line body pre-scan, FNEND,
                            ILLEGAL TRANSFER, argument counts (LANGUAGE.md 7.10)
src/runtime/rt_str.s        _bsk_str_set _bsk_str_cmp _bsk_print_sv
                            _bsk_change_s2n _bsk_change_n2s _bsk_change_n2s_el (OUT OF ROOM), §6.7
src/runtime/rt_input.s      _bsk_input_* (incl. _bsk_input_str_el) _bsk_mat_input _bsk_smat_input, the input line reader,
                            BSK_EMIT_INPUT_MSGS, §6.7
src/runtime/rt_ed4.s        _bsk_on _bsk_randomize _bsk_sgn _bsk_cot _bsk_num _bsk_det
                            _bsk_print_tab, the NUM cell _bsk_rt_num (private_extern), §6.7
src/runtime_x86_64_linux/rt_str.s     bsk_str_set bsk_str_cmp (§6.4)
src/runtime_x86_64_linux/rt_input.s   bsk_input_* bsk_mat_input bsk_smat_input bsk_num, the input
                                      line reader and the NUM cell (local symbol)
src/runtime_x86_64_linux/rt_ed4.s     bsk_change_s2n bsk_change_n2s bsk_change_n2s_el bsk_on bsk_sgn bsk_cot bsk_det
```

`_bsk_saref1` / `bsk_saref1` lives in `rt_array.s` of each runtime, next to `_bsk_aref1`. On x86_64,
`bsk_print_sv` and `bsk_print_tab` are in `rt_print.s` and `bsk_randomize` in `rt_rnd.s`. The NUM
cell is private to each runtime: written by MAT INPUT, read by NUM, never part of the ABI.

Existing runtime files gain: `rt_data.s` `_bsk_sread`, `_bsk_sread_el`, `_bsk_restore`, `_bsk_smat_read` and the
string DATA cursor; `rt_mat.s` `_bsk_smat_print`; `rt_error.s` exit status 0 for code 43;
`rt_kinit.s` the DET cell `_bsk_rt_kinv_det` (written by every inv kernel, §6.6.1) — in both
runtimes.

Files added for the Fifth Edition features (§2.4; owners may refine the split inside their
directory):

```
src/frontend/fe_files.s     FILES, SCRATCH, RESTORE #, PRINT #, INPUT #, IF END # (LANGUAGE.md
                            7.21-7.26), TOO MANY FILES, the fsel lowering (IR.md 4.3)
src/frontend/fe_sexpr.s     string expressions: STR$, LEN/ASC/VAL, string FN calls and string
                            arguments with their temp cells, string tables (LANGUAGE.md 4.4-4.6,
                            6.1, 7.10.1), the phase-3 kind check
src/runtime/rt_files.s      _bsk_fsel _bsk_feof _bsk_scratch _bsk_frestore, the file table and
                            per-file state, _bsk_rt_files_finish (termination), DESIGN.md 6.8
src/runtime/rt_ed5.s        _bsk_len _bsk_asc _bsk_val _bsk_str _bsk_str_clear
src/runtime_x86_64_linux/rt_files.s   bsk_fsel bsk_feof bsk_scratch bsk_frestore, file state,
                                      bsk_rt_files_finish
src/runtime_x86_64_linux/rt_ed5.s     bsk_len bsk_asc bsk_val bsk_str bsk_str_clear
```

`_bsk_saref2` / `bsk_saref2` lives in `rt_array.s` of each runtime. `bsk_str_clear` is in the
x86_64 `rt_str.s`, but `_bsk_str_clear` is in the arm64 `rt_ed5.s` (the tables above list it with
the Fifth Edition string routines on both). Existing runtime files gain:
`rt_print.s` and `rt_input.s` the pending-file selection (§6.8); `rt_mat.s` string tables in
`_bsk_smat_print`; `rt_data.s` string tables in `_bsk_smat_read`; `rt_main.s` (`_bsk_end`) and
`rt_error.s` (`_bsk_err`) the file finishing and codes 48–55 — in both runtimes.

Files added for the Sixth Edition features (§2.5; owners may refine the split inside their
directory):

```
src/frontend/fe_sub.s       SUB, SUBEND, CALL (LANGUAGE.md 7.27): the program-unit partition
                            (pre-scan), per-unit symbol state, CALL arguments and their
                            lowering (IR.md 4.3), the phase-3 CALL checks
                            (An END line met inside a SUB block is compiled in that unit, not
                            in the main program; unobservable, as it always ends in
                            UNFINISHED SUB, LANGUAGE.md 7.3.)
src/runtime/rt_sub.s        _bsk_sub_enter _bsk_sub_leave, the call stack (§6.9)
src/runtime/rt_ed6.s        _bsk_str_cat _bsk_seg _bsk_pos
src/runtime_x86_64_linux/rt_sub.s     bsk_sub_enter bsk_sub_leave, the call stack
src/runtime_x86_64_linux/rt_ed6.s     bsk_str_cat bsk_seg bsk_pos
```

Existing files gain: `fe_sexpr.s` (`&`, `SEG$`, `POS`), `fe_scan.s` (`SEG$(`, `POS(`, `&`),
`fe_stmt.s` (the keywords), `fe_compile.s` (per-unit phases, the §10.1 order); `rt_gosub.s` the
GOSUB base of the current activation; `rt_main.s` the runtime-owned program stack (§6.9); `rt_error.s`
code 56 and the `ERR_END_RUNTIME` range — in both runtimes.

Files added for the Baysick extensions (§2.6; owners may refine the split inside their directory):

```
src/frontend/fe_ext.s       LINPUT (LANGUAGE.md 15.2) and the status expression of END/STOP
                            (15.4): parsing, errors, lowering (IR.md 4.3)
src/runtime/rt_ext.s        _bsk_linput _bsk_linput_el _bsk_exit, the standard-error output
                            record (6.10)
src/runtime_x86_64_linux/rt_ext.s     bsk_linput bsk_linput_el bsk_exit, the standard-error record
```

Existing files gain: `fe_stmt.s` (the keyword `LINPUT`, its handler, END/STOP calling
`fe_ext.s`); `rt_files.s` (`_bsk_fsel` accepting −1, the input entry points rejecting it);
`rt_print.s` (the print entry points on the standard-error record); `rt_input.s` (the INPUT
diagnostics ending a pending standard-error line; the line reader called by `_bsk_linput`);
`rt_main.s` (`_bsk_end` sharing `_bsk_exit`'s termination, the standard-error newline);
`rt_error.s` (code 62, the standard-error newline before the message) — in both runtimes.

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

### 2.2 Contract counts and the staging switches

The MAT contract raised `OP_COUNT` from 42 to 55 and `KW_COUNT` from 15 to 16; the Third and
Fourth Edition contract and then the Fifth Edition contract raised the counts and record sizes
again. Modules size tables by these counts (dumper, verifier, both backends, the keyword loop, the
builtin table, the frontend's token-class table) and walk the `IRF`/`IRM` records by their
sizes, so each contract change was staged behind a temporary assembler switch while the modules
were implemented, and the switch was removed at integration in one commit. The integrated
values:

| Constant | Second Edition (MAT) | Fourth Edition | Fifth Edition | Sixth Edition (current) | Baysick extensions (staged, switch 1) |
|----------|----------------------|----------------|-----------------------------------|--------------------------|--------------------------|
| `OP_COUNT` | 55 | 85 (`OP_STFV + 1`) | 99 (`OP_FRESTORE + 1`) | 111 (`OP_SUBRET + 1`) | 113 (`OP_EXIT + 1`) |
| `KW_COUNT` | 16 | 22 (`KW_FNEND + 1`) | 24 (`KW_SCRATCH + 1`) | 27 (`KW_SUB + 1`) | 28 (`KW_LINPUT + 1`) |
| `TK_COUNT` | 26 | 30 (`TK_FN0 + 1`) | 32 (`TK_SFN0 + 1`) | 33 (`TK_AMP + 1`) | 33 (unchanged) |
| `BI_COUNT` | 10 | 14 (`BI_DET + 1`) | 18 (`BI_STR + 1`) | 20 (`BI_POS + 1`) | 20 (unchanged) |
| `IRF_SIZE` | 64 (`IRF_RESERVED` at 56) | 96 (`IRF_NPARAMS` 56, `IRF_ENDLINE` 60, `IRF_PARAMS` 64) | 96 (unchanged) | 96 (unchanged) | 96 (unchanged) |
| `IRM_SIZE` | 2192 | 3488 (`IRM_SARRAYS` 3056, `IRM_NSDATA` 3472, `IRM_CAPSDATA` 3476, `IRM_SDATA` 3480) | 3624 (`IRM_NSTEMPS` 3488, `IRM_NFILES` 3492, `IRM_FILES` 3496, `IRM_CAPFILES` 3504, `IRM_RESERVED5` 3508, `IRM_FNKINDS` 3512) | 3760 (`IRM_NSUBS` 3624 … `IRM_SUBPKINDS` 3744, ir.inc) | 3760 (unchanged) |

`IRF_SIZE` did not change for the Fifth Edition: its per-function data, `IRM_FNKINDS`, lives in
the module after the existing fields, so no existing offset moved. Each integration also changed
`--version` (§4.1).

**How the Fifth Edition was staged** (history). The switch, defined in `include/ir.inc` and
`include/tokens.inc` with default 0, selected only the counts above and `IRM_SIZE`; the rest of
the Fifth Edition contract (the new opcode, token, builtin and keyword values, the new `IRM_*`
offset names, `FNK_*`, `ERR_TABLE_SIZE` 56 and the texts of codes 31 and 48–55, `LIM_FILES`,
`LIM_FILE_NAME`, `RT_FILEBUF_SIZE`, the runtime names in `runtime.inc`) was unconditional from
the design commit. A `make` variable assembled every compiler and runtime file with the switch 1,
and `make check-includes` assembled the include check with both values. While the packages
(§2.4) were implemented, plain `make test` kept passing every earlier test (260 on the Mac, 159
cross): each module kept its Fifth Edition code out of the switch-0 build with `.if` blocks; the
arm64 runtime referenced `_bsk_files`/`_bsk_files_count` only with the switch 1, because
switch-0 programs did not define them; the x86_64 runtime, built without any switch, declared
`bsk_files` and `bsk_files_count` `.weak` and counted an undefined `bsk_files_count` as 0 files,
so it linked with the programs of either compiler. The Fifth Edition corpus failed by design
until its features were in, and the design and implementation commits stayed local until the
integration commit, so CI on the pushed branch stayed green.

Integration (§2.4 step 2) deleted the switch, its `.if` blocks and Makefile lines, and the code
only the switch-0 build used; the x86_64 runtime lost its `.weak` declarations and addresses
`bsk_files`/`bsk_files_count` RIP-relative like `bsk_data`, since every program now defines them;
`tests/include_asserts.inc` kept the Fifth Edition assertions; `--version` changed (§4.1); and
the two Fourth Edition error tests whose text became legal were rewritten as LANGUAGE.md §14.1
specifies (`tests/errors/c_ed4_string_table_dim`, `tests/errors/c_ed4_string_two_subscripts`:
new `.bas` and `.err`, the same names).

**How the Sixth Edition was staged** (history). Exactly as the Fifth Edition was: the switch,
defined in `include/ir.inc` and `include/tokens.inc` with default 0, selected only the counts of
the last column above and `IRM_SIZE`; the rest of the Sixth Edition contract (the opcode values
99–110, `TK_AMP`, `BI_SEG`, `BI_POS`, `KW_CALL`, `KW_SUBEND`, `KW_SUB`, `FUNC_KIND_SUB`, `SUBP_*`,
`IRA_FLAG_PARAM`, `IRA_DIMS_ANY`, the `IRM_*` unit offsets, the error codes 56–61 with
`ERR_END_RUNTIME` 57 and `ERR_TABLE_SIZE` 62, `LIM_SUB_PARAMS`, `LIM_CALL_DEPTH`,
`LIM_CALL_WORDS`, the `SUBL_*`/`SUBD_*` layout, `RT_FRAME_EXTRA_WORDS`, `RT_STACK_RESERVE_BYTES`,
`RT_PROGRAM_STACK_BYTES` and the runtime names in `runtime.inc`) was unconditional from the
design commit. A `make` variable assembled every compiler and runtime file with the switch 1, and
`make check-includes` assembled the include check with both values. While the packages (§2.5)
were implemented, plain `make test` (switch 0) kept passing every earlier test (329 on the Mac,
192 cross): each **compiler** module (F, D, B, BX) kept its Sixth Edition code out of the
switch-0 build with `.if` blocks. The **runtime** code (R, RX) was never under the switch:
neither runtime has a table sized by a contract count, and `Makefile.linux` never set the
switch, so the new entry points, the call stack, the call budget and the runtime-owned program
stack (§6.9) were in every runtime build from the start, and switch-0 programs linked and behaved
exactly as before (they never called the new entry points; the program stack only gave them a
larger, fixed stack). Neither runtime references a symbol that only Sixth Edition programs
define (`_bsk_sub_enter` is called *by* programs, the `SUBL` records are passed to it), so no
`.weak` declaration was needed. The switch-1 compiler was cross-tested by building the bundle
with the switch on (the Linux runtime built as always), and the switch-1 include check was run
on Linux with GNU `as` by hand. The Sixth Edition corpus failed by design until its features
were in, and the design and implementation commits stayed local until the integration commit,
so CI on the pushed branch stayed green.

Integration (§2.5 step 2) deleted the switch, its `.if` blocks and Makefile lines, and the code
only the switch-0 build used (the switch-0 phase-3 sequence in `fe_compile.s` and the
single-unit FN check `_fe_check_fns` it called, now done per unit by `_fe_sub_check_fns`);
`tests/include_asserts.inc` kept the Sixth Edition assertions; `--version` changed (§4.1).
No earlier test's text became legal (LANGUAGE.md §14.1), so no earlier test was rewritten.

**How the Baysick extensions are staged** (current; LANGUAGE.md §15, §2.6). Exactly as the Sixth
Edition was: the switch `BSK_EXT_CONTRACT`, defined in `include/ir.inc` and `include/tokens.inc`
with default 0, selects only `OP_COUNT` (111 → 113) and `KW_COUNT` (27 → 28); `TK_COUNT`,
`BI_COUNT`, `IRF_SIZE` and `IRM_SIZE` do not change (the extensions add no token, builtin or
record field). The rest of the extension contract is unconditional from the design commit: the
opcode values `OP_LINPUT` 111 and `OP_EXIT` 112, `KW_LINPUT` 27, the error code
`ERR_EXIT_RANGE` 62 with `ERR_EXT_FIRST`, `ERR_EXT_FIRST_RUNTIME` 62, `ERR_EXT_END_RUNTIME` 63 and
`ERR_TABLE_SIZE` 63 (its message text in `BSK_EMIT_ERRMSG_TABLE`), `FILE_NUM_STDERR` −1,
`LIM_EXIT_STATUS` 255, and the runtime names in `runtime.inc`. `make BSK_EXT=1` assembles every
compiler and runtime file with the switch 1, `make check-includes` assembles the include check
with both values, and the GNU `as` include check is run with both values by hand on Linux
(`as --64 -I include -I tests --defsym BSK_EXT_CONTRACT=1 tests/include_check_x86_64.s`;
`Makefile.linux` never sets the switch). While the packages (§2.6) are implemented, plain `make
test` (switch 0) keeps passing every earlier test (384 on the Mac, 210 cross) and the extension
corpus fails by design (the expected-failure set of §2.6): each **compiler** module (F, D, B, BX)
keeps its extension code out of the switch-0 build with `.if BSK_EXT_CONTRACT` blocks. The
**runtime** code (R, RX) is never under the switch: neither runtime has a table sized by
`OP_COUNT` or `KW_COUNT`, the new entry points are called only by programs of the switch-1
compiler, and the changed behaviour of existing entry points (`_bsk_fsel` accepting −1, the
standard-error newline at termination, code 62 in `_bsk_err`) is invisible to every earlier test
(none prints to designator −1: `tests/errors/r_ed5_invalid_negative` uses `INPUT #-1`, which
stays `INVALID FILE NUMBER`). Because the switch-0 compiler already accepts `PRINT #-1` (any formula is a
designator), the 12 extension tests whose only extension is `PRINT #-1` leave the expected-failure
set at switch 0 as soon as R (Mac) or RX (cross) is in, the 3 `streams=merged` ones among them once
T is in too (the list and counts are in §2.6). The switch-1 compiler is cross-tested by building the bundle with
the switch on (`make clean; make BSK_EXT=1 cross`; the Linux runtime is built as always). The
design and implementation commits stay local until the integration commit, so CI on the pushed
branch stays green.

### 2.3 Third and Fourth Edition work packages

LANGUAGE.md §3–§14 (strings, INPUT, RESTORE, ON, TAB, RANDOMIZE, CHANGE, multiple and multi-line
DEF, MAT INPUT, NUM, DET, SGN, COT, multiple LET, `'`, IF … GO TO) touch every module; each
implementer changes only its own files:

| Owner | Work |
|-------|------|
| F | compaction: `'` ends the line outside strings (LANGUAGE.md §2.1, §1.5); keywords 16–21 and `RANDOM` (§3.1); scanner tokens `TK_SVAR TK_SARRAY TK_GOTO TK_FN0`, builtins SGN COT NUM DET (§5.2); string references and every `MISMATCHED STRING OPERATION` rule (§4.5); multiple LET (§7.1); PRINT string items and TAB (§7.2); string READ/DATA, two data blocks, `NO STRING DATA` (§7.4–7.5); IF strings and IF … GOTO (§7.7); FOR rules (§7.8); DEF/FNEND with the pre-scan of multi-line bodies, per-body FOR stacks, `UNFINISHED DEF`, `NESTED DEF`, `ILLEGAL TRANSFER`, `INCORRECT NUMBER OF ARGUMENTS` (§7.10); string DIM (§7.11); MAT with string lists and MAT INPUT (§7.14); INPUT, RESTORE, ON, RANDOMIZE, CHANGE (§7.15–7.19); the phase-3 order (§10.1); canonical lowering (IR.md §4) |
| D | builder: `_ir_add_sdata`, `_ir_set_sarray`, `_ir_func_set`, per-function labels (ir.inc); dumper: the `sarray`/`sdata` lines, the three func-head forms, every §3.2 text form, `param k`, `callfn` without argument (IR.md §5); verifier: temp kinds, per-function labels, placement table, `fnarg` rule, function records (IR.md §6); driver: `--version` (§4.1) |
| B | §5.3: string data and descriptors in the skeleton, `_bsk_svars`, string-list descriptors, frames with local cells, multi-line function labels and prologue/`ret`, every new row of the per-opcode table |
| BX | §5.4: the same for x86_64 (five global symbols) |
| R | §6.7 entry points (`rt_str.s`, `rt_input.s`, `rt_ed4.s`), `_bsk_sread`/`_bsk_restore`/`_bsk_smat_read` (`rt_data.s`), `_bsk_smat_print` (`rt_mat.s`), `_bsk_err` exit 0 for code 43, the DET cell written by `rt_kneon_inv.s` (§6.6.1) |
| RX | the x86_64 counterparts (§6.4), including the DET cell in `rt_ksse2_inv.s` and `rt_kavx2_inv.s` |
| T | nothing new beyond the `.in` stdin sidecar, already implemented in `tests/run.sh`, `tests/cross_pack.sh` and `tests/cross_run.sh` (§8.3) |
| BENCH | nothing: the inv kernel signature is unchanged (the DET cell is a side output) |

Order: D and R/RX could start at once (their contracts were complete); F needed D's builder
functions to link, B/BX needed D's new records to read. The packages are implemented and
integrated (§2.2). "Per-function labels" needed no builder change: `_ir_new_label` already
allocated labels in the function it is given.

### 2.4 Fifth Edition work packages

LANGUAGE.md "The Fifth Edition", §4.4–§4.6, §6.1, §7.10.1, §7.11, §7.14, §7.21–§7.26, §8, §10–§14
(files, `LEN ASC STR$ VAL`, string DEF, string tables) touched every module; each implementer
changed only its own files, and everything was built and tested with the staging switch on until
integration (§2.2).

| Owner | Files | Work |
|-------|-------|------|
| F | `src/frontend/` (new `fe_files.s`, `fe_sexpr.s`; changes in `fe_scan.s`, `fe_expr.s`, `fe_str.s`, `fe_def.s`, `fe_stmt.s`, `fe_mat.s`, `fe_input.s`, `fe_compile.s`) | keywords `FILES SCRATCH` (`KW_FILES`, `KW_SCRATCH`); scanner: `LEN( ASC( VAL( STR$(` (`BI_LEN…BI_STR`), `TK_SFN`/`TK_SFN0` (LANGUAGE.md §5.2); string expressions everywhere a string reference was allowed and every new `MISMATCHED STRING OPERATION` rule (§4.5, §4.6); string tables: DIM, element references and targets, the list/table conflict, the "bare MAT name stays a list" rule (§4.4, §7.11), MAT READ/PRINT with tables, MAT INPUT tables rejected (§7.14); string DEF and string parameters, `FNx`/`FNx$` sharing a letter (`DUPLICATE FUNCTION`), the phase-3 kind check after `INCORRECT NUMBER OF ARGUMENTS` (§7.10.1, §10.1), `_ir_set_fnkind`; FILES (names, quoting, `TOO MANY FILES`, `_ir_add_file`), SCRATCH, RESTORE #, PRINT #, INPUT #, IF END # (§7.21–§7.26; `IF END#` recognised before the comparison); canonical lowering IR.md §4 (temp cells via `_ir_new_stemp`, string-argument copies, `fsel` placement); assembly-time `.error` asserts that the keyword table (`fe_stmt.s`), the token table — the frontend's token-class table `Lfe_sexpr_tkclass` in `fe_sexpr.s`, one entry per `TK_*` — and the builtin table (`fe_scan.s`) have exactly `KW_COUNT`, `TK_COUNT` and `BI_COUNT` entries (as `ir_dump.s` does for `OP_COUNT`), so no table can be silently short |
| D | `src/ir/`, `src/driver/` | builder: `_ir_new_stemp`, `_ir_add_file`, `_ir_set_sarray2`, `_ir_set_fnkind` (ir.inc); dumper: the `dims=2` sarray line, `stemps` and `file` lines, `FNx$` and `X$` in function heads, every IR.md §3.3 text form and `smatredim` with B; verifier: IR.md §6 rule 8 and the new kinds, groups and placement (§3), `jeof` labels; driver: `--version` at integration (§4.1) |
| B | `src/backend/arm64_macos/` | §5.3: the Fifth Edition skeleton items (`Lfile_<k>`, `_bsk_files`, `_bsk_files_count`, `_bsk_scells`, string-table descriptors and storage), string parameters and string results in frames (prologue, `sret`), every new row of the per-opcode table |
| BX | `src/backend/x86_64_linux/` | §5.4: the same for x86_64 (seven global symbols) |
| R | `src/runtime/` (new `rt_files.s`, `rt_ed5.s`; changes in `rt_print.s`, `rt_input.s`, `rt_mat.s`, `rt_data.s`, `rt_array.s`, `rt_main.s`, `rt_error.s`) | §6.8: every new entry point; the pending file selection in the print and input entry points; string tables in `_bsk_smat_read`/`_bsk_smat_print`; file finishing in `_bsk_end`/`_bsk_err` and exit status 1 after a failed file flush |
| RX | `src/runtime_x86_64_linux/` | the x86_64 counterparts (§6.4, §6.8); before integration its file-table references were `.weak` (§2.2, now plain RIP-relative references) |
| T | `tests/run.sh`, `tests/cross_pack.sh`, `tests/cross_run.sh`, `.github/workflows/ci.yml` | §8.5: the per-test work directory, `NAME.files/` fixtures and `NAME.expect/` checks in all three scripts; nothing in CI beyond what the scripts do (the bundle carries the directories) |
| BENCH | `bench/` | nothing |

Order (history; the packages are implemented and integrated, §2.2):

0. **Step 0 — switch-1 build skeleton (D, B, BX, before any feature work).** With the switch 1
   the build first stopped at the `OP_COUNT` table asserts of `src/ir/ir_dump.s`,
   `src/ir/ir_verify.s`, `src/backend/arm64_macos/a64_insn.s` (two asserts) and
   `src/backend/x86_64_linux/x64_insn.s`. D, B and BX each first landed a minimal change that
   made their module assemble with the switch 1: every table indexed by opcode was extended to
   `OP_COUNT` entries, and opcodes 85–98 mapped to an internal-error entry until their real
   handlers replaced it. After step 0 the switch-1 build passed the Fourth Edition tests (except
   the two `c_ed4_*` tests of §2.2).
1. **Feature work.** D, R, RX and T started at once (their contracts were complete and
   independent: T's harness change kept every old test passing because old programs never touch
   files). F needed D's builder functions to link. B and BX needed D's records and, for
   end-to-end tests, F's Fifth Edition IR; once D and F were in, `tests/ir/ed5_*` showed the
   expected IR, so B and BX worked from real IR before the runtimes were complete.
2. **Integration commit** (after every package had passed its tests with the switch 1; done by
   the coordinator, not by a package): the switch removed as §2.2 describes, the two `c_ed4_*`
   tests of LANGUAGE.md §14.1 rewritten, `--version` set (§4.1), and the docs updated (this
   section and §2.2 became history, CLAUDE.md and README.md say "implemented",
   SEA_BOOTSTRAP.md marks the rows covered).

The Fifth Edition tests are `tests/programs/ed5_*`, `tests/programs/manual5_*`,
`tests/errors/c_ed5_*`, `tests/errors/r_ed5_*` and `tests/ir/ed5_*`.

### 2.5 Sixth Edition work packages

LANGUAGE.md "The Sixth Edition", §3, §4.4–§4.6, §5, §6.2, §7.3, §7.6–§7.10, §7.27, §10–§14
(`SEG$`, `POS`, `&`, `CALL`/`SUB`/`SUBEND`) touched every compiler and runtime module; each
implementer changed only its own files, and everything was built and tested with the staging
switch on until integration (§2.2). The contracts were complete in `include/*.inc`, IR.md §2.2,
§3.4, §4, §5, §6 rule 9 and this document (§5.3, §5.3.1, §5.4, §5.4.6, §6.9), so the six packages
needed no other agreement.

| Owner | Files | Work |
|-------|-------|------|
| F | `src/frontend/` (new `fe_sub.s`; changes in `fe_scan.s`, `fe_expr.s`, `fe_sexpr.s`, `fe_str.s`, `fe_stmt.s`, `fe_def.s`, `fe_mat.s`, `fe_input.s`, `fe_files.s`, `fe_compile.s`) | keywords `CALL SUBEND SUB` (SUBEND before SUB, LANGUAGE.md §3.1); scanner: `SEG$(` and `POS(` (`BI_SEG`, `BI_POS`), `&` as `TK_AMP` in operator position after a string operand; string expressions with `&` and `SEG$`, `POS` with 2 or 3 arguments, every new `MISMATCHED STRING OPERATION` / `ILLEGAL FORMULA` rule (§4.5, §4.6, §5.2, §6.2) and their lowering (IR.md §4.2: result expressions, `scat`, `sseg`, `pos`); the program-unit partition and its errors (`NESTED SUB`, `UNFINISHED SUB`, `UNFINISHED DEF` at SUBEND, SUBEND outside a block, END only in the main program, LANGUAGE.md §7.3, §7.27); SUB and CALL syntax, `DUPLICATE SUBPROGRAM`; per-unit symbol state (arrays and string arrays with DIM, FOR stacks and FOR numbering, FN functions and their checks, string cells, transfer checks); parameter arrays (dimensionality from use, DIM of a parameter → `ILLEGAL VARIABLE`); CALL arguments by reference / by value and their lowering (IR.md §4.3); unit creation and numbering (`_ir_new_sub`, `_ir_sub_set`, `_ir_set_param_array`, IR.md §4.1, §4.4); the §10.1 phase-3 additions (`UNFINISHED SUB`, `UNDEFINED SUBPROGRAM`, CALL argument counts and kinds, per-unit RECURSIVE FUNCTION order); pad the keyword, handler, token-class and builtin tables to `KW_COUNT`, `TK_COUNT`, `BI_COUNT` at switch 1 (step 0) |
| D | `src/ir/`, `src/driver/` | builder: `_ir_new_sub`, `_ir_sub_set`, `_ir_set_param_array`, `IRM_SIZE` 3760 at switch 1 (ir.inc); dumper: the unit sections, `param` array lines, `func SUB`, every §3.4 text form (IR.md §5); verifier: rule 9 and the new kinds, groups and placement (IR.md §3, §6); driver: `--version` and the help line at integration (§4.1); pad the dumper's and verifier's opcode tables at switch 1 (step 0) |
| B | `src/backend/arm64_macos/` | §5.3: frames with the argument vector, every new row, SUB units (§5.3.1: labels, block layout, `Lsubl_`/`Lsubt_` records, the unit cost `SUBL_COST`, SUB prologue, FN functions of a unit keep `x19`, parameter and block addressing in every variable/array/cell row); pad the dispatch table and adjust the Fifth Edition table assert in `a64_insn.s` at switch 1 (step 0) |
| BX | `src/backend/x86_64_linux/` | §5.4: the same for x86_64 (§5.4.4 frames, §5.4.5 rows, §5.4.6 SUB units, the same `SUBL_COST` as B, computed by the §5.3.1 formula); pad the dispatch table at switch 1 (step 0) |
| R | `src/runtime/` (new `rt_sub.s`, `rt_ed6.s`; changes in `rt_gosub.s`, `rt_main.s`, `rt_error.s`) | §6.9: `_bsk_str_cat`, `_bsk_seg`, `_bsk_pos`, `_bsk_sub_enter`, `_bsk_sub_leave`, the call stack, the call budget (`SUBL_COST` against `LIM_CALL_WORDS`), the GOSUB base, the program stack (mmap'd `RT_PROGRAM_STACK_BYTES` + guard page, `_bsk_program` run on it), `_bsk_err` accepting exactly 32…56. All of it was unconditional (never under the switch, §2.2) |
| RX | `src/runtime_x86_64_linux/` | the x86_64 counterparts (§6.4, §6.9), including the program stack in `main`; unconditional, like R |
| T | — | nothing: the Sixth Edition corpus uses only existing harness features (`.in`, `.files/`, `.expect/`) |
| BENCH | `bench/` | nothing |

Order (history; the packages are implemented and integrated, §2.2):

0. **Step 0 — switch-1 build skeleton (F, D, B, BX, before any feature work).** With the switch
   1 the build first stopped at nine table asserts (verified at the design commit): `fe_scan.s` (builtin
   names ≠ `BI_COUNT`), `fe_sexpr.s` (token classes ≠ `TK_COUNT`), `fe_stmt.s` (keyword table and
   handler table ≠ `KW_COUNT`), `ir_dump.s` and `ir_verify.s` (≠ `OP_COUNT`), `a64_insn.s`
   (dispatch table ≠ `OP_COUNT`, and its assert `OP_COUNT == OP_FRESTORE + 1`), `x64_insn.s`
   (dispatch table ≠ `OP_COUNT`). Each owner first landed a minimal change that made its module
   assemble with the switch 1: tables extended to the counts, new opcodes 99–110 mapped to an
   internal-error entry, the new keywords to a handler that reported `ILLEGAL INSTRUCTION`, the
   new builtins and `TK_AMP` to entries that kept the Fifth Edition error behaviour, the
   `a64_insn.s` assert rewritten to hold at both values. After step 0 the switch-1 build passed
   every test that the switch-0 build passed.
1. **Feature work.** D, R and RX started at once (their contracts were complete and
   independent). F needed D's builder functions to link (it started on scanning, parsing and the
   partition at once). B and BX needed D's records and, end to end, F's IR; `tests/ir/ed6_*`
   showed the expected IR. There is no IR text reader, so B and BX tested end to end once F
   lowered SUB, CALL and the string operators.
2. **Integration commit** (done by the coordinator after every package had passed its tests
   with the switch 1): the switch removed as §2.2 describes (the `.if` blocks, the Makefile lines
   and the switch-0 code deleted, `tests/include_asserts.inc` keeping the Sixth Edition
   assertions), `--version` set (§4.1), and the docs updated (§2.2 and this section became
   history, CLAUDE.md and README.md say "implemented", SEA_BOOTSTRAP.md marks the rows covered).
   No earlier test changed (LANGUAGE.md §14.1).

The Sixth Edition tests are `tests/programs/ed6_*`, `tests/programs/manual6_*`,
`tests/errors/c_ed6_*`, `tests/errors/r_ed6_*` and `tests/ir/ed6_*`.

### 2.6 Baysick extensions work packages

LANGUAGE.md §15 (with §3, §7.3, §7.13, §7.15, §7.21, §7.24, §7.26, §8, §10–§14: `LINPUT`,
`PRINT #-1`, `END e` / `STOP e`) touches every compiler and runtime module and the harness; each
implementer changes only its own files, and everything is built and tested with the staging
switch on until integration (§2.2). The contracts are complete in `include/*.inc`, IR.md §3.5,
§4.3, §5, §6 rule 10, and this document (§5.3, §5.3.1, §5.4.5, §5.4.6, §6.2, §6.4.2, §6.10,
§8.6), so the packages need no other agreement.

| Owner | Files | Work |
|-------|-------|------|
| F | `src/frontend/` (new `fe_ext.s`; changes in `fe_stmt.s`, and wherever INPUT's target parser lives if it is reused) | keyword `LINPUT` (`KW_LINPUT`, tested last, LANGUAGE.md §3.1) and its handler; the LINPUT grammar: `#` designator and `,` as INPUT #, exactly one string target of INPUT (string variable, string list or table element, a string parameter of the enclosing multi-line DEF or SUB), the errors of LANGUAGE.md §15.2 (`ILLEGAL VARIABLE`, `MISMATCHED STRING OPERATION` for a numeric target, `INCORRECT FORMAT` after the target); lowering IR.md §4.3 (`linput`, element form, cell form for tables, `fsel` placement); END and STOP with an optional expression: after the §7.3 END checks, end of text → `end`/`stop` as before, otherwise a numeric expression (string → `MISMATCHED STRING OPERATION`), end of text after it (else `INCORRECT FORMAT`), lowering `exit` (+ `end` for END); pad the keyword and handler tables to `KW_COUNT` at switch 1 (step 0) |
| D | `src/ir/`, `src/driver/` | dumper: the text forms `linput tA`, `linput L$, tB`, `exit tA` (IR.md §3.5, §5); verifier: rule 10 (field kinds, element form, `fsel` + `linput`, `exit` in group T as an unconditional transfer); driver: `--version` and the help line at integration (§4.1); pad the dumper's and verifier's opcode tables to `OP_COUNT` at switch 1 (step 0) |
| B | `src/backend/arm64_macos/` | §5.3: the rows of `linput` (plain and element form; in SUB units with the §5.3.1 `Lsdesc` addressing) and `exit`; pad the dispatch table at switch 1 and rewrite the Sixth Edition order assert of `a64_insn.s` (`OP_COUNT != OP_SUBRET + 1`) so that it holds at both switch values (step 0) |
| BX | `src/backend/x86_64_linux/` | §5.4.5 and §5.4.6: the same rows for x86_64; pad the dispatch table at switch 1 (step 0) |
| R | `src/runtime/` (new `rt_ext.s`; changes in `rt_files.s`, `rt_print.s`, `rt_input.s`, `rt_main.s`, `rt_error.s`) | §6.10: `_bsk_linput`, `_bsk_linput_el`, `_bsk_exit`; `_bsk_fsel` accepting −1; the standard-error output record and the print entry points on it (stdout flushed first, written at once); −1 rejected by every input entry point and by `_bsk_linput*` (error 49); termination (§6.10): the standard-error newline in `_bsk_end`, `_bsk_exit`, `_bsk_err` and before the INPUT diagnostics; `_bsk_err` accepting code 62. All unconditional (never under the switch, §2.2) |
| RX | `src/runtime_x86_64_linux/` (new `rt_ext.s`; the same files) | the x86_64 counterparts (§6.4, §6.10); unconditional, like R |
| T | `tests/run.sh`, `tests/cross_run.sh` | §8.6: the `streams=` key of a run-phase `.meta` (`merged`, `no-stdout`); `tests/cross_pack.sh` and CI need nothing (the bundle already carries `.meta`) |
| BENCH | `bench/` | nothing |

**Expected-failure set** (until the packages are in; every other test must keep passing with
plain `make test` and `make cross`): every test named `ext_*`, `c_ext_*`, `r_ext_*` and
`tests/ir/ext_*` — on the Mac all of them (`tests/programs/ext_*`, `tests/errors/c_ext_*`,
`tests/errors/r_ext_*`, `tests/ir/ext_*`), in the cross run the program and run-phase ones
(compile-phase and IR tests are not cross-run). They fail cleanly today: the switch-0 compiler
rejects `LINPUT` (`ILLEGAL INSTRUCTION`) and `END e` / `STOP e` (`INCORRECT FORMAT`), so most
cases fail at their compile step (on the Mac "compile failed", in the cross bundle a
`.packfail`); the 15 `c_ext_*` cases fail on the compiler's message, the 2 `tests/ir/ext_*` on
`--emit-ir`, and the 12 cases whose only extension is `PRINT #-1` compile and fail at run time
with `INVALID FILE NUMBER`. Of these 12, 9 need only the runtime and pass with plain `make test`
(switch 0) as soon as R (Mac) or RX (cross) is in: `ext_stderr_print`, `ext_stderr_input_diag`,
`ext_stderr_wrap`, `ext_stderr_in_file_print`, `r_ext_ifend_stderr`, `r_ext_print_minus2`,
`r_ext_scratch_stderr`, `r_ext_stderr_error_newline`, `r_ext_restore_stderr`; the other 3
(`r_ext_stderr_merged`, `r_ext_stderr_error_merged`, `r_ext_stderr_long_merged`, all
`streams=merged`) pass at switch 0 once R or RX and T are in. Counts at the design commit: on the
Mac 384 passed and 60 failed (12 `tests/programs/ext_*`, 15 `c_ext_*`, 31 `r_ext_*`, 2
`tests/ir/ext_*`), cross 210 passed and 43 failed (the 12 programs and the 31 run-phase cases).
After R and RX the switch-0 failures are 51 on the Mac and 34 cross, after T as well 48 and 31.
The 5 `streams=` cases (`r_ext_exit_stdout_closed`, `r_ext_end_stdout_closed`: `no-stdout`; the 3
`merged` ones above) fail until T is in, even with every other package in.

Order:

0. **Step 0 — switch-1 build skeleton (F, D, B, BX, before any feature work).** With the switch 1
   the build stops at exactly seven table asserts (verified at the design commit with
   `make -k BSK_EXT=1`): `src/frontend/fe_stmt.s` line 2230 ("the keyword table does not have
   KW_COUNT entries") and line 2266 ("the statement handler table does not have KW_COUNT
   entries"); `src/ir/ir_dump.s` line 1305 ("template table does not match OP_COUNT");
   `src/ir/ir_verify.s` line 1627 ("spec table does not match OP_COUNT");
   `src/backend/arm64_macos/a64_insn.s` line 1523 ("dispatch table does not cover OP_COUNT
   opcodes") and line 1532 ("Sixth Edition tables assume opcodes 99..110 in contract order", its
   `OP_COUNT != OP_SUBRET + 1` half); `src/backend/x86_64_linux/x64_insn.s` line 1481 ("dispatch
   table does not cover OP_COUNT opcodes"). Every runtime file assembles at both values. Each
   owner first lands a minimal change that makes its module assemble with the switch 1: tables
   extended to the counts, opcodes 111–112 mapped to an internal-error entry, `KW_LINPUT` to a
   handler that reports `ILLEGAL INSTRUCTION` (the switch-0 behaviour), the `a64_insn.s` assert
   rewritten to hold at both values. After step 0 the switch-1 build passes every test that the
   switch-0 build passes.
1. **Feature work.** D, R, RX and T start at once (their contracts are complete and
   independent; T's change keeps every old test passing because no old `.meta` has a `streams=`
   line). F needs nothing new from D's builder (the extensions use only existing builder
   functions), so F starts at once too; B and BX need F's IR end to end (`tests/ir/ext_*` show it)
   and R's/RX's entry points to link.
2. **Integration commit** (done by the coordinator after every package has passed its tests with
   the switch 1): the switch removed as §2.2 describes (the `.if` blocks, the Makefile lines and
   the switch-0 code deleted; `tests/include_asserts.inc` keeps only the switch-1 assertions),
   `--version` and the help line set (§4.1), and the docs updated: §2.2 and this section become
   history, LANGUAGE.md "specified, being implemented" becomes "implemented", CLAUDE.md and
   README.md say "implemented", SEA_BOOTSTRAP.md marks rows 2 and 17 covered. No earlier test
   changes (LANGUAGE.md §14.1). Integration also checks by hand what the corpus cannot: `LINPUT`
   and `LINPUT #0` on a terminal (prompt, `col` reset), and `PRINT #-1` order on a terminal.

The extension tests are `tests/programs/ext_*`, `tests/errors/c_ext_*`, `tests/errors/r_ext_*` and
`tests/ir/ext_*`.

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
* only arch-neutral directives: `.equ`, `.ifndef`/`.if`/`.else`/`.endif`, `.macro`/`.endm`,
  `.quad`, `.byte`, `.ascii`, `.asciz`, `.p2align`, `.error`; no instructions, no section directives (the instantiating file
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
baysick --version            "baysick 0.5.0 (Dartmouth BASIC, Sixth Edition 1971)" + LF, exit 0
```

* The Fourth Edition integration (§2.2) changed the version text from
  `baysick 0.2.0 (Dartmouth BASIC, Second Edition 1964)`.
* The Fifth Edition integration (§2.2, §2.4) changed it from
  `baysick 0.3.0 (Dartmouth BASIC, Fourth Edition 1968)`, and the edition the help text names
  (its line "Compile a Dartmouth BASIC (…) program to a native executable.") from
  `Fourth Edition, 1968` to `Fifth Edition, 1970`. Nothing else in the usage or help text
  changed.
* The Sixth Edition integration (§2.2, §2.5) changed it from
  `baysick 0.4.0 (Dartmouth BASIC, Fifth Edition 1970)` to
  `baysick 0.5.0 (Dartmouth BASIC, Sixth Edition 1971)`, and the edition the help text names from
  `Fifth Edition, 1970` to `Sixth Edition, 1971`. Nothing else in the usage or help text changed.
* The Baysick extensions integration (§2.2, §2.6) changes it from
  `baysick 0.5.0 (Dartmouth BASIC, Sixth Edition 1971)` to
  `baysick 0.6.0 (Dartmouth BASIC, Sixth Edition 1971, with Baysick extensions)`, and the help
  line from `Compile a Dartmouth BASIC (Sixth Edition, 1971) program to a native executable.` to
  `Compile a Dartmouth BASIC (Sixth Edition, 1971, with Baysick extensions) program to a native
  executable.` Nothing else in the usage or help text changes. (The edition stays the Sixth: the
  extensions belong to no edition, LANGUAGE.md §15, and the minor version records the language
  change.)
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
Lsub_<u>:            Sixth Edition: per SUB unit u = 0 … NSUBS-1, its SUB body, followed by
Lsub_<u>_fn_<L>:     the unit's present FN functions, letter order (§5.3.1)
    .section __TEXT,__const
Lstr_0: .byte …      each string literal as decimal .byte list (Lstr_<id>), may be empty
Lsdb_0: .byte …      each string DATA value as decimal .byte list (Lsdb_<k>), may be empty
    .section __DATA,__const
    .globl _bsk_data
    .p2align 3
_bsk_data:           .quad <bits> per DATA value (none if NDATA = 0; label still emitted)
    .globl _bsk_data_count
_bsk_data_count:     .quad NDATA
Lsd_<id>:            per string id: SD record ".quad Lstr_<id>" / ".long <len>, 0"
    .globl _bsk_sdata
_bsk_sdata:          per string DATA value k: ".quad Lsdb_<k>" / ".long <len>, 0"
                     (none if NSDATA = 0; label still emitted)
    .globl _bsk_sdata_count
_bsk_sdata_count:    .quad NSDATA
                     Fifth Edition (every program):
Lfile_<k>:           in __TEXT,__const after the Lsdb_ lists: each FILES name k = 1 … NFILES
                     as a decimal .byte list
    .globl _bsk_files
_bsk_files:          in __DATA,__const after _bsk_sdata_count: per file k = 1 … NFILES
                     ".quad Lfile_<k>" / ".long <len>, 0" (none if NFILES = 0; label still emitted)
    .globl _bsk_files_count
_bsk_files_count:    .quad NFILES
Lsubl_<u>:           Sixth Edition: per SUB unit, in __DATA,__const after _bsk_files_count:
                     its SUBL_* record, then (label Lsubt_<u>) its descriptor templates (§5.3.1)
    .section __DATA,__data
    .p2align 3
Ldesc_<L>:           32-byte RTA descriptor per used array (.quad _bsk_arr_<L>, .long dims,
                     .long b1, .long b2, .long rowlen, .long letter, .long cap),
                     cap = (b1+1)*(b2+1)
Lsdesc_<L>:          per used string array, letter order: a list: .quad _bsk_sarr_<L>,
                     .long 1, b1, 0, 1, letter, b1+1; a table (Fifth Edition): .quad
                     _bsk_sarr_<L>, .long 2, b1, b2, b2+1, letter, (b1+1)*(b2+1)
    .zerofill __DATA,__bss,_bsk_vars,<8*NSLOTS>,3
    .zerofill __DATA,__bss,_bsk_svars,4576,3                  286 SD records (always)
    .zerofill __DATA,__bss,_bsk_arr_<L>,<8*(b1+1)*(b2+1)>,3   per used array
    .zerofill __DATA,__bss,_bsk_sarr_<L>,<16*cap>,3           per used string array (cap as in Lsdesc_)
    .zerofill __DATA,__bss,_bsk_scells,<16*NSTEMPS>,3         Fifth Edition, only if NSTEMPS > 0
```

`_bsk_vars`, `_bsk_svars`, `_bsk_arr_<L>`, `_bsk_sarr_<L>` and `_bsk_scells` are file-local (no
`.globl`).
Labels of `main`: `Lbsk_L<id>` for every label id (line and internal labels alike); labels of a
multi-line function FN*L*: `Lfn_<L>_L<id>`. (Every `Lstr_<id>` gets its `Lsd_<id>` and every
program defines the four data symbols, because the runtime references `_bsk_sdata` and
`_bsk_sdata_count` unconditionally; it defines six, adding `_bsk_files` and `_bsk_files_count`,
which the runtime also references unconditionally.)

**Frames and temps.** Temps live in 8-byte stack slots. Because a temp is never read after the
next `line` (IR.md §1), slots are reused per line: slot(t) = t − *base*, where *base* is the
number of the first temp defined after the most recent `line` instruction (0 in a single-line FN
function, which has no `line`). The temp area is `8 × W` bytes, W = the largest number of temps
defined between two consecutive `line` instructions (or in the whole single-line function).
After the temps come L **local cells** of 8 bytes, cell k at `[sp, #8*(W+k)]`:
L = max(1, NP) for `main` (NP = 0) and single-line functions, L = NP + 2 for multi-line functions
(NP = `NPARAMS`): cell k < NP is parameter k, cell NP the function value, cell NP+1 the saved
run-time line. Frame of every generated function:

```
    stp x29, x30, [sp, #-32]!        // frame record
    mov x29, sp
    stp x19, x20, [sp, #16]          // x19 = &_bsk_vars, x20 = spare
    sub sp, sp, #<align16(8*(W+L) + 8)>  // temps at [sp, #8*slot]; cell k at [sp, #8*(W+k)]
    adrp x19, _bsk_vars@PAGE
    add  x19, x19, _bsk_vars@PAGEOFF
    str d<k>, [sp, #8*(W+k)]         // FN functions: for k = 0 … NP-1, the arguments
    str xzr, [sp, #8*(W+NP)]         // multi-line only: function value := 0
    adrp x16, _bsk_curline@PAGE      // multi-line only: save the caller's run-time line
    ldr w17, [x16, _bsk_curline@PAGEOFF]
    str x17, [sp, #8*(W+NP+1)]
    … body …
    mov sp, x29                      // epilogue (FN functions only; main never returns)
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
```

With L = 1 the frame is the earlier one (`align16(8*W + 16)`). Offsets that do not fit an
instruction's immediate are materialised in `x16` (`mov`/`movk`) and used as a register offset.
FN functions receive argument k in `d<k>` (k < 8) and return the result in `d0`.
`_bsk_program` never returns normally (main ends with `end`); `Lfn_*` return with `ret`.

**Fifth Edition frames** (string parameters, string functions; IR.md §3.3.1). A **string**
parameter k arrives as an SD pointer in `x<k>` (k < 8) and its local cell k holds that pointer:
the prologue stores `str x<k>, [sp, #8*(W+k)]` instead of `str d<k>` for every k whose
`IRM_FNKINDS` bit is set. A **string function** (`FNK_STRING`) receives the address of its result
descriptor in `x8` (the AAPCS64 indirect-result register) and keeps it in cell NP:
L = NP + 1 for a single-line string function (L = NP + 2 for multi-line functions as before;
cell NP then holds the result pointer instead of the numeric value), and the prologue stores
`str x8, [sp, #8*(W+NP)]` instead of `str xzr, …`. A multi-line string function then, after
saving the caller's run-time line, clears its value: `ldr x0, [sp, #8*(W+NP)]` / `bl
_bsk_str_clear` (every argument register has been stored by then). String functions return no
value in a register.

**Sixth Edition frames** (IR.md §3.4.1). After the L local cells every generated function has V
**argument-vector** slots of 8 bytes, slot k at `[sp, #8*(W+L+k)]`: V = the largest `SUBNPARAMS`
of the units its `callsub` instructions call (V = 0 without `callsub`, which leaves every earlier
frame unchanged). The `sub sp` amount becomes `align16(8*(W+L+V) + 8)`. A SUB body has the frame
of `main` (L = 1, the cell unused) with its own W and V and its own prologue (§5.3.1). A
`callsub` with arguments (A ≠ `IR_NONE`) in a function with V = 0 cannot occur in valid IR and is
an internal error; a `callsub` without arguments may have V = 0, and then x0 (`%rdi` on x86_64)
points at the frame's spare word at `8*(W+L)` (the `+ 8` of the `sub sp` amount), which the
callee never reads.

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
| `callfn` | `ldr d0` ← A (nothing if A = `IR_NONE`: no argument is loaded), `bl Lfn_<L>`, store `d0` |
| `param` k | `ldr d0, [sp, #8*(W+k)]`, store |
| `ret` | load A into `d0`; multi-line functions then `ldr x17, [sp, #8*(W+NP+1)]` / `adrp x16, _bsk_curline@PAGE` / `str w17, [x16, _bsk_curline@PAGEOFF]`; epilogue |
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
| `slit` | `adrp x0, Lsd_<id>@PAGE` / `add x0, x0, Lsd_<id>@PAGEOFF` / `str x0` → DST |
| `svar` | `adrp x0, _bsk_svars@PAGE` / `add x0, x0, _bsk_svars@PAGEOFF` / `add x0, x0, #<16*slot>` (via `x16` when above 4095) / `str x0` → DST |
| `sald1` | `adrp/add x0, Lsdesc_<L>`, `ldr d0` ← A, `bl _bsk_saref1`, `str x0` → DST |
| `sset` | `ldr x0` ← A, `ldr x1` ← B, `bl _bsk_str_set` |
| `sjcmp` | `ldr x0` ← A, `ldr x1` ← B, `bl _bsk_str_cmp`, `cmp w0, #0`, `b.<inverse> 1f`, `b <label>`, `1:` (eq/ne/lt/le/gt/ge → inverse ne/eq/ge/gt/le/lt, signed conditions) |
| `prsv` `sread` `insv` | `ldr x0` ← A, `bl _bsk_print_sv` / `_bsk_sread` / `_bsk_input_str` |
| `sread` `insv` element form (A = `IR_NONE`) | `adrp/add x0, Lsdesc_<X>`, `ldr d0` ← B, `bl _bsk_sread_el` / `_bsk_input_str_el` |
| `prtab` | `ldr d0` ← A, `bl _bsk_print_tab` |
| `inbeg` `inend` `randomize` | `bl _bsk_input_begin` / `_bsk_input_end` / `_bsk_randomize` |
| `innum` `num` `det` | `bl _bsk_input_num` / `_bsk_num` / `_bsk_det`, store `d0` |
| `sgn` `cot` | as the builtins: `ldr d0` ← A, `bl _bsk_sgn` / `_bsk_cot`, store |
| `matinput` | `adrp/add x0, Ldesc_<X>`, `bl _bsk_mat_input` |
| `smatinput` `smatread` | `adrp/add x0, Lsdesc_<X>`, `bl _bsk_smat_input` / `_bsk_smat_read` |
| `smatredim` | `adrp/add x0, Lsdesc_<X>`, `ldr d0` ← A, `bl _bsk_mat_redim1` |
| `smatprint` | `adrp/add x0, Lsdesc_<X>`, `mov w1, #<IMM>`, `bl _bsk_smat_print` |
| `chgs2n` | `adrp/add x0, Ldesc_<X>`, `ldr x1` ← A, `bl _bsk_change_s2n` |
| `chgn2s` | `ldr x0` ← A, `adrp/add x1, Ldesc_<X>`, `bl _bsk_change_n2s` |
| `chgn2s` element form (A = `IR_NONE`) | `adrp/add x0, Lsdesc_<IMM>`, `ldr d0` ← B, `adrp/add x1, Ldesc_<X>`, `bl _bsk_change_n2s_el` |
| `onsel` | `ldr d0` ← A, `mov w0, #<N>` (`movz`/`movk` as needed), `bl _bsk_on`, store `d0` |
| `restore` | `mov w0, #<IMM>`, `bl _bsk_restore` |
| `fnarg` k | `ldr d<k>` ← A (the `callfn` follows immediately and loads only `d0`) |
| `stparam` k | `ldr d0` ← A, `str d0, [sp, #8*(W+k)]` |
| `ldfv` / `stfv` | `ldr d0, [sp, #8*(W+NP)]`, store / `ldr d0` ← A, `str d0, [sp, #8*(W+NP)]` |
| `scell` (Fifth Edition) | `adrp x0, _bsk_scells@PAGE` / `add x0, x0, _bsk_scells@PAGEOFF` / `add x0, x0, #<16*X>` (via `x16` when above 4095) / `str x0` → DST |
| `sstr` | `ldr x0` ← A, `ldr d0` ← B, `bl _bsk_str` |
| `len` `asc` `val` | `ldr x0` ← A, `bl _bsk_len` / `_bsk_asc` / `_bsk_val`, store `d0` |
| `sald2` | `adrp/add x0, Lsdesc_<X>`, `ldr d0` ← A, `ldr d1` ← B, `bl _bsk_saref2`, `str x0` → DST |
| `sparam` k | `ldr x0, [sp, #8*(W+k)]`, `str x0` → DST |
| `sfv` | `ldr x0, [sp, #8*(W+NP)]`, `str x0` → DST |
| `fnarg` k, string parameter | `ldr x<k>` ← A. The kind of argument k is bit k of the `IRM_FNKINDS` word of the callee named by the `callfn`/`scallfn` that ends this run of `fnarg`s: the backend looks ahead to that call |
| `callfn` / `scallfn`, string parameter 0 | `ldr x0` ← A (instead of `ldr d0`). A is argument 0 and takes parameter 0's kind, bit 0 of the callee's `IRM_FNKINDS` word |
| `scallfn` | `ldr d0` or `ldr x0` ← A by the callee's parameter 0 kind (nothing if A = `IR_NONE`), `ldr x8` ← B, `bl Lfn_<L>` (nothing is stored) |
| `sret` | `ldr x0, [sp, #8*(W+NP)]`, `ldr x1` ← A, `bl _bsk_str_set`; multi-line functions then restore the caller's run-time line as `ret` does; epilogue |
| `fsel` | `ldr d0` ← A, `bl _bsk_fsel` |
| `jeof` | `ldr d0` ← A, `bl _bsk_feof`, `cbz w0, 1f`, `b <label>`, `1:` |
| `scratch` `frestore` | `ldr d0` ← A, `bl _bsk_scratch` / `_bsk_frestore` |
| `smatredim` with B (string table) | `adrp/add x0, Lsdesc_<X>`, `ldr d0` ← A, `ldr d1` ← B, `bl _bsk_mat_redim2` |
| `scat` (Sixth Edition) | `ldr x0` ← A, `ldr x1` ← B, `bl _bsk_str_cat` |
| `sseg` | the address of cell X in `x0` as `scell` forms it, `str x0` → DST, `ldr x1` ← A, `ldr d0` ← B, `ldr d1` ← C, `bl _bsk_seg` |
| `pos` | `ldr x0` ← A, `ldr x1` ← B, `ldr d0` ← C, `bl _bsk_pos`, store `d0` |
| `vaddr` | `add x0, x19, #<8*X>`, `str x0` → DST |
| `aaddr1` / `aaddr2` | as `ald1` / `ald2` up to and including `bl _bsk_aref1` / `_bsk_aref2`, then `str x0` → DST |
| `taddr` | `add x0, sp, #<8*slot(A)>`, `str x0` → DST |
| `aref` / `saref` | `adrp/add x0, Ldesc_<X>` / `Lsdesc_<X>`, `str x0` → DST |
| `subarg` k | `ldr x0` ← A, `str x0, [sp, #8*(W+L+k)]` |
| `callsub` | unless A = `IR_NONE`: `ldr x0` ← A, `str x0, [sp, #8*(W+L)]`; then `add x0, sp, #<8*(W+L)>`, `bl Lsub_<X>` (nothing is stored) |
| `subret` | `bl _bsk_sub_leave`, then the epilogue (`mov sp, x29` / `ldp x19, x20, [sp, #16]` / `ldp x29, x30, [sp], #32` / `ret`) |
| `linput` (Baysick extension) | `ldr x0` ← A, `bl _bsk_linput` |
| `linput` element form (A = `IR_NONE`) | `adrp/add x0, Lsdesc_<X>`, `ldr d0` ← B, `bl _bsk_linput_el` |
| `exit` | `ldr d0` ← A, `bl _bsk_exit` (never returns; inside a multi-line function or a SUB unit exactly the same) |

`line`, `label`, `jmp`, `jcmp`, `sjcmp`, `jfor` and `jeof` inside a multi-line function use its
labels `Lfn_<L>_L<id>`; inside a SUB unit, these and `gosub` (its target and its return label)
use the labels of §5.3.1 (`Lsub_<u>_L<id>` in the SUB body) instead of `Lbsk_L<id>`.

The rows that pass `Lsdesc_<X>` (`sald1`, `smatredim`, `smatread`, `smatprint`, and the element
forms) take the descriptor of whatever string array X names, so for `smatredim`, `smatread` and
`smatprint` it may be a string table's `Lsdesc_` (DIMS 2), as IR.md §3.3 allows; the backend's
descriptor lookup accepts DIMS 1 and 2 for all of them (for `sald1` the verifier admits only a
list, IR.md §6 rule 8). A `stop` inside a multi-line function is `bl _bsk_end` as in `main`.

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

#### 5.3.1 SUB units (Sixth Edition)

A SUB unit u (IR.md §2.2) is emitted after `main`'s functions: its SUB body at `Lsub_<u>`, then
each present FN function L of the unit at `Lsub_<u>_fn_<L>`, letter order. Labels: `Lsub_<u>_L<id>`
in the SUB body, `Lsub_<u>_fn_<L>_L<id>` in a multi-line function of the unit (`<u>` decimal).
A `callfn`/`scallfn` in the unit calls `Lsub_<u>_fn_<L>`.

**Activation block.** Every activation of unit u is a zero-filled block allocated by
`_bsk_sub_enter` (§6.9); in the unit's code `x19` holds its address instead of `&_bsk_vars`.
Both backends compute the same layout from the unit's Module (all offsets in bytes):

| Part | Offset | Contents |
|------|--------|----------|
| numeric slots | 0 | `8 × NSLOTS`: the 286 scalars and the unit's FOR cells, exactly as `_bsk_vars` |
| parameter pointers | PARAMOFF = `8 × NSLOTS` | `8 × SUBNPARAMS`: pointer k = argument k (a double, an SD record, or an `RTA_*` descriptor) |
| SD records | SDOFF = align16(PARAMOFF + 8·SUBNPARAMS) | NSD = 286 + `NSTEMPS` + Σ cap records: the 286 string variables (string slot s at SDOFF + 16s), the unit's string temp cells (cell X at SDOFF + 4576 + 16X), then the elements of each non-parameter string array in letter order (cap as for `Lsdesc_`) |
| descriptors | DESCOFF = SDOFF + 16·NSD | `32 × NDESC`: one `RTA_*` descriptor per used non-parameter numeric array (letter order), then per used non-parameter string array (letter order); d(L) = the index of array L's descriptor in this order |
| numeric storage | after the descriptors | `8 × cap` per used non-parameter numeric array, letter order (cap = (b1+1)(b2+1)) |

SIZE = align16(end). "Used" arrays are chosen exactly as for `main`'s `Ldesc_`/`Lsdesc_`.

**Records** (in `__DATA,__const` after `_bsk_files_count`, each `Lsubl_<u>` preceded by its own
`.p2align 3`):

```
Lsubl_<u>:  .long SIZE, SUBNPARAMS, PARAMOFF, SDOFF, NSD, DESCOFF, NDESC, COST
            .quad Lsubt_<u>              (.quad 0 when NDESC = 0)
            .byte p0, p1, …, p15         SUBL_PDIMS: SUBD_* per parameter, 0 when unused
Lsubt_<u>:  per descriptor, in d(L) order: .quad <block offset of its elements>,
            .long dims, b1, b2, rowlen, letter, cap      (as Ldesc_ / Lsdesc_)
```

The `Lsubt_<u>:` label and its templates are emitted only when NDESC > 0 (otherwise nothing
follows the PDIMS bytes and the record's template pointer is 0).

`SUBL_PDIMS[k]`: `SUBD_SCALAR` for `SUBP_NUM`/`SUBP_STR`; for an array parameter `SUBD_LIST`,
`SUBD_TABLE` or `SUBD_ANY` from its `DIMS` 1, 2 or `IRA_DIMS_ANY`.

**Unit cost** (`SUBL_COST`, in 8-byte words; LANGUAGE.md §7.27 "call budget"). Both backends
compute it from the IR alone, with W, L and V exactly as defined in §5.3 (the definitions are
target-independent; §5.4.4 uses the same ones), so the number is the same on every target:

```
frame(f)  = W(f) + L(f) + V(f) + RT_FRAME_EXTRA_WORDS          (RT_FRAME_EXTRA_WORDS = 6)
fchain(g) = frame(g) + max(0, max over the functions h named by a callfn/scallfn of g: fchain(h))
chain(u)  = max(0, max over the present FN functions g of unit u: fchain(g))
COST(u)   = SIZE(u)/8 + frame(SUB body of u) + chain(u)
```

`fchain` is well defined because FN calls never recurse (`RECURSIVE FUNCTION`), and a unit's FN
functions call only functions of the same unit. COST fits a u32: SIZE is at most about 26 × 10⁶
× 24 bytes. **Why it bounds the machine stack.** A generated function's frame is at most
`8·frame(f)` bytes on both targets: arm64 uses 32 + align16(8n + 8) ≤ 8n + 48 bytes (n = W+L+V);
x86_64 uses 8 (return address) + 8 (`%rbp`) + 8 (`%rbx`) + align16(8n + 8) − 8 ≤ 8n + 32 bytes. The
stack between the SUB body frame of one activation and that of the next activation it calls is
that body frame plus at most one chain of the unit's FN frames (a CALL inside a multi-line FN
body), so it is at most `8·(frame(body) + chain(u)) ≤ 8·COST(u)` bytes. The runtime keeps
Σ COST of the active activations ≤ `LIM_CALL_WORDS` (§6.9), so all activations together use at
most `8·LIM_CALL_WORDS` = 16 MiB of stack (blocks are on the heap; counting them too makes the
budget also bound the activations' heap storage). Example: `SUB "BIG": N` with `DIM A(199999)`,
`PRINT N`, `CALL "BIG": N + 1` has SIZE = 1 606 912 (NSLOTS 286 → PARAMOFF 2288, SDOFF 2304,
DESCOFF 6880, storage at 6912 … 1 606 912), W = 4, L = 1, V = 1, so COST = 200 864 + 12 = 200 876
words, and the eleventh activation exceeds 2 097 152 (`tests/errors/r_ed6_call_budget`).

**SUB body prologue** (x0 = the address of the argument vector, from `callsub`):

```
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    sub sp, sp, #<align16(8*(W+L+V) + 8)>      L = 1
    mov x1, x0                                 argument vector
    adrp x0, Lsubl_<u>@PAGE
    add  x0, x0, Lsubl_<u>@PAGEOFF
    bl _bsk_sub_enter                          errors report the CALL line (still current)
    mov x19, x0                                x19 = activation block
    … body (its first instruction is the SUB line's `line`) …
```

`subret` ends it (the row above). An **FN function of a unit** has the frame of §5.3 except
that its prologue omits `adrp/add x19, _bsk_vars`: it runs only when called from the unit's
code and keeps the caller's `x19`, the current activation block (saved and restored as before).

**Addressing in a unit.** Every row of §5.3 applies inside a unit with these replacements
(P(k) = PARAMOFF + 8k for parameter k; offsets above an instruction's immediate are
materialised in `x16`, as everywhere):

| Operand | In a SUB unit |
|---------|---------------|
| numeric slot X, not a parameter (`ldv`, `stv`, `vaddr`) | `[x19, #8*X]` / `add x0, x19, #8*X` — the main-program text, x19 being the block |
| numeric slot X = parameter k | `ldv`: `ldr x16, [x19, #P(k)]`, `ldr d0, [x16]`, store; `stv`: `ldr d0` ← A, `ldr x16, [x19, #P(k)]`, `str d0, [x16]`; `vaddr`: `ldr x0, [x19, #P(k)]`, `str x0` → DST |
| string slot s (`svar`), not a parameter | `add x0, x19, #<SDOFF + 16*s>`, `str x0` → DST |
| string slot s = parameter k | `ldr x0, [x19, #P(k)]`, `str x0` → DST |
| cell X (`scell`, `sseg`) | `add x0, x19, #<SDOFF + 4576 + 16*X>` |
| `Ldesc_<L>` / `Lsdesc_<L>` in any row (`ald*`, `ast*`, `sald*`, the MAT rows, `sread`/`insv`/`chgn2s`/`linput` element forms, `chg*`, `aaddr*`, `aref`, `saref`), into register xN | not a parameter: `add xN, x19, #<DESCOFF + 32*d(L)>`; parameter k: `ldr xN, [x19, #P(k)]` |

Everything else — temps, local cells, string constants `Lsd_<id>` (program-wide), `_bsk_curline`,
runtime calls — is as in `main`.

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
* **Symbols:** ELF, no leading underscore. The output defines exactly five global symbols:
  `bsk_program`, `bsk_data`, `bsk_data_count`, `bsk_sdata`, `bsk_sdata_count` — seven with the
  Fifth Edition contract, which adds `bsk_files` and `bsk_files_count`. Everything else is
  an assembler-local `.L` name (not in the object's symbol table):

  | Name | Meaning |
  |------|---------|
  | `.Lbsk_L<id>` | label id `<id>` of `main` (line and internal labels alike) |
  | `.Lfn_<L>` | FN function `<L>` (`A`…`Z`) |
  | `.Lstr_<id>` | PRINT string literal `<id>` |
  | `.Ldesc_<L>` | 32-byte `RTA_*` descriptor of array `<L>` |
  | `.Lbsk_vars` | the `NSLOTS` global cells |
  | `.Lbsk_arr_<L>` | element storage of array `<L>` |
  | `.Lfn_<L>_L<id>` | label id `<id>` of multi-line function `<L>` |
  | `.Lsd_<id>` | 16-byte `SD_*` record of string constant `<id>` |
  | `.Lsdb_<k>` | bytes of string DATA value `<k>` |
  | `.Lsdesc_<L>` | 32-byte `RTA_*` descriptor of string list `<L>` |
  | `.Lbsk_svars` | the 286 string variables (`SD_*` records) |
  | `.Lbsk_sarr_<L>` | element storage (`SD_*` records) of string list or table `<L>` |
  | `.Lfile_<k>` | bytes of FILES name `<k>` (Fifth Edition) |
  | `.Lbsk_scells` | the `NSTEMPS` string temp cells (`SD_*` records; Fifth Edition) |
  | `.Lsub_<u>` | SUB body of unit `<u>` (decimal; Sixth Edition, §5.4.6) |
  | `.Lsub_<u>_L<id>` | label id `<id>` of the SUB body of unit `<u>` |
  | `.Lsub_<u>_fn_<L>` | FN function `<L>` of unit `<u>` |
  | `.Lsub_<u>_fn_<L>_L<id>` | label id `<id>` of multi-line function `<L>` of unit `<u>` |
  | `.Lsubl_<u>` | the `SUBL_*` record of unit `<u>` |
  | `.Lsubt_<u>` | the descriptor templates of unit `<u>` |

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
.Lsub_0:                Sixth Edition: per SUB unit u, its SUB body, then .Lsub_<u>_fn_<L> per
                        present FN function of the unit, letter order, each preceded by .p2align 4
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
.Lsdb_0:                each string DATA value as ".byte" lines like .Lstr_ (may be empty)
.Lfile_1:               Fifth Edition: each FILES name k = 1 … NFILES as ".byte" lines
    .section .data.rel.ro,"aw",@progbits
    .p2align 3
.Lsd_<id>:              per string id: "    .quad .Lstr_<id>" / "    .long <len>, 0"
    .globl bsk_sdata
    .type bsk_sdata, @object
bsk_sdata:              per string DATA value k: "    .quad .Lsdb_<k>" / "    .long <len>, 0"
    .globl bsk_sdata_count
    .type bsk_sdata_count, @object
bsk_sdata_count:
    .quad <NSDATA>
    .globl bsk_files        Fifth Edition (every program):
    .type bsk_files, @object
bsk_files:              per file k: "    .quad .Lfile_<k>" / "    .long <len>, 0" (none if NFILES = 0)
    .globl bsk_files_count
    .type bsk_files_count, @object
bsk_files_count:
    .quad <NFILES>
    .p2align 3
.Lsubl_<u>:             Sixth Edition: per SUB unit, the SUBL_* record and .Lsubt_<u> templates
                        exactly as §5.3.1 ("    .long …" / "    .quad …" / "    .byte …" lines);
                        each unit's .Lsubl_<u> is preceded by its own "    .p2align 3"
    .data
    .p2align 3
.Ldesc_<L>:             per used array, letter order:
    .quad .Lbsk_arr_<L>
    .long <dims>, <b1>, <b2>, <rowlen>, <letter>, <cap>      cap = (b1+1)*(b2+1)
.Lsdesc_<L>:            per used string array, letter order:
    .quad .Lbsk_sarr_<L>
    .long 1, <b1>, 0, 1, <letter>, <b1+1>                    a list
    .long 2, <b1>, <b2>, <b2+1>, <letter>, <(b1+1)*(b2+1)>   a table (Fifth Edition)
    .bss
    .p2align 3
.Lbsk_vars:
    .zero <8*NSLOTS>
    .p2align 3
.Lbsk_svars:
    .zero 4576
    .p2align 3          per used array, letter order:
.Lbsk_arr_<L>:
    .zero <8*(b1+1)*(b2+1)>
    .p2align 3          per used string array, letter order:
.Lbsk_sarr_<L>:
    .zero <16*cap>                                   cap as in .Lsdesc_<L>
    .p2align 3          Fifth Edition, only if NSTEMPS > 0:
.Lbsk_scells:
    .zero <16*NSTEMPS>
    .section .note.GNU-stack,"",@progbits
```

`.section .rodata`, `.section .data.rel.ro`, `.data` and `.bss` headers are emitted even when no
item follows them. The
final `.note.GNU-stack` line marks the stack non-executable (without it GNU `ld` warns and makes
the stack executable). `rowlen` = `b2+1` for tables, `1` for lists; `b2` = 0 for lists (as §5.3).

#### 5.4.4 Frames and temps

Temps live in 8-byte stack slots; slot(t) = t − *base*, the temp-area width W and the L local
cells (parameters, function value, saved run-time line) are defined exactly as in §5.3. Every
generated function:

```
    pushq %rbp
    movq  %rsp, %rbp
    pushq %rbx                       # rbx = &.Lbsk_vars for the whole function
    subq  $<F>, %rsp                 # F = align16(8*(W+L) + 8) - 8
    leaq  .Lbsk_vars(%rip), %rbx
    movsd %xmm<k>, <8*(W+k)>(%rsp)   # FN functions: for k = 0 … NP-1, the arguments
    movq  $0, <8*(W+NP)>(%rsp)       # multi-line only: function value := 0
    movl  bsk_curline(%rip), %eax    # multi-line only: save the caller's run-time line
    movq  %rax, <8*(W+NP+1)>(%rsp)
    … body …
    movq  -8(%rbp), %rbx             # epilogue, FN functions only (emitted by `ret`)
    leave
    ret
```

* Temp slot *s* is `<8*s>(%rsp)`; local cell k is `<8*(W+k)>(%rsp)`. `%rsp` never moves
  inside the body. Alignment: at entry `%rsp` ≡ 8 (mod 16); after the two pushes it is still ≡ 8;
  F ≡ 8 (mod 16), so `%rsp` ≡ 0 at every `call` in the body, as the System V ABI requires.
  F ≥ 8(W + L), so the temps and the cells fit. With L = 1 this is the earlier frame
  (F = align16(8*W + 16) − 8).
* Global cell *x* is `<8*x>(%rbx)`. `%rbx` is callee-saved in the System V ABI, so it survives
  every runtime call; it is saved/restored because the caller (`main` in the runtime, or the
  calling BASIC function) relies on it.
* All displacements fit a signed 32-bit displacement (largest global offset
  8 × (286 + 2·1000 − 1) = 18288); the assembler chooses the encoding.
* Registers used by generated code: `%rax %rcx %rdi %rsi %xmm0 %xmm1 %xmm2` as scratch (and
  `%xmm1`–`%xmm7` as argument registers between `fnarg` and its `callfn`), `%rbx` globals base,
  `%rbp` frame pointer. No value is kept in a register across a `call`.
* `bsk_program` never returns (main ends with `end`); FN functions return through the epilogue,
  result in `%xmm0`.
* **Fifth Edition** (IR.md §3.3.1): string parameter k arrives as an SD pointer in R(k) =
  `%rdi %rsi %rdx %rcx %r8 %r9 %r10 %r11` (k = 0 … 7; these are calls between generated
  functions, so the System V limit of six integer argument registers does not apply) and the
  prologue stores `movq R(k), <8*(W+k)>(%rsp)` instead of the `movsd`. A string function receives
  the address of its result descriptor in `%rax` and stores `movq %rax, <8*(W+NP)>(%rsp)` in
  place of `movq $0, …` (before the multi-line line save, which overwrites `%eax`); L = NP + 1 for
  a single-line string function. A multi-line string function then clears its value:
  `movq <8*(W+NP)>(%rsp), %rdi` / `call bsk_str_clear`. String functions return nothing in a
  register.
* **Sixth Edition** (IR.md §3.4.1): after the L cells come the V argument-vector slots of §5.3,
  slot k at `<8*(W+L+k)>(%rsp)`, and F = align16(8*(W+L+V) + 8) − 8 (V = 0 leaves every earlier
  frame unchanged). The backend rejects a function with W above `BK_X64_MAX_W` (0x0FFFFFE0,
  `x64_insn.s`) with an internal error, so with L ≤ 10 and V ≤ 16 the largest frame offset
  `8*(W+L+V) + 8` always fits a signed 32-bit displacement.

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
| `callfn` | `movsd S(A), %xmm0` (nothing if A = `IR_NONE`: no argument is loaded) / `call .Lfn_<L>` / store |
| `param` k | `movsd <8*(W+k)>(%rsp), %xmm0` / store |
| `ret` | `movsd S(A), %xmm0` / multi-line functions: `movq <8*(W+NP+1)>(%rsp), %rax` / `movl %eax, bsk_curline(%rip)` / epilogue (`movq -8(%rbp), %rbx` / `leave` / `ret`) |
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
| `slit` | `leaq .Lsd_<id>(%rip), %rax` / `movq %rax, S(DST)` |
| `svar` | `leaq .Lbsk_svars+<16*slot>(%rip), %rax` / `movq %rax, S(DST)` |
| `sald1` | `leaq .Lsdesc_<L>(%rip), %rdi` / `movsd S(A), %xmm0` / `call bsk_saref1` / `movq %rax, S(DST)` |
| `sset` | `movq S(A), %rdi` / `movq S(B), %rsi` / `call bsk_str_set` |
| `sjcmp` | `movq S(A), %rdi` / `movq S(B), %rsi` / `call bsk_str_cmp` / `cmpl $0, %eax` / `j<cc> <label>` with eq→`je`, ne→`jne`, lt→`jl`, le→`jle`, gt→`jg`, ge→`jge` (signed: the result is −1/0/+1) |
| `prsv` `sread` `insv` | `movq S(A), %rdi` / `call bsk_print_sv` \| `bsk_sread` \| `bsk_input_str` |
| `sread` `insv` element form (A = `IR_NONE`) | `leaq .Lsdesc_<X>(%rip), %rdi` / `movsd S(B), %xmm0` / `call bsk_sread_el` \| `bsk_input_str_el` |
| `prtab` | `movsd S(A), %xmm0` / `call bsk_print_tab` |
| `inbeg` `inend` `randomize` | `call bsk_input_begin` \| `bsk_input_end` \| `bsk_randomize` |
| `innum` `num` `det` | `call bsk_input_num` \| `bsk_num` \| `bsk_det` / store |
| `sgn` `cot` | `movsd S(A), %xmm0` / `call bsk_sgn` \| `bsk_cot` / store |
| `matinput` | `leaq .Ldesc_<X>(%rip), %rdi` / `call bsk_mat_input` |
| `smatinput` `smatread` | `leaq .Lsdesc_<X>(%rip), %rdi` / `call bsk_smat_input` \| `bsk_smat_read` |
| `smatredim` | `leaq .Lsdesc_<X>(%rip), %rdi` / `movsd S(A), %xmm0` / `call bsk_mat_redim1` |
| `smatprint` | `leaq .Lsdesc_<X>(%rip), %rdi` / `movl $<IMM>, %esi` / `call bsk_smat_print` |
| `chgs2n` | `leaq .Ldesc_<X>(%rip), %rdi` / `movq S(A), %rsi` / `call bsk_change_s2n` |
| `chgn2s` | `movq S(A), %rdi` / `leaq .Ldesc_<X>(%rip), %rsi` / `call bsk_change_n2s` |
| `chgn2s` element form (A = `IR_NONE`) | `leaq .Lsdesc_<IMM>(%rip), %rdi` / `movsd S(B), %xmm0` / `leaq .Ldesc_<X>(%rip), %rsi` / `call bsk_change_n2s_el` |
| `onsel` | `movsd S(A), %xmm0` / `movl $<N>, %edi` / `call bsk_on` / store |
| `restore` | `movl $<IMM>, %edi` / `call bsk_restore` |
| `fnarg` k | `movsd S(A), %xmm<k>` |
| `stparam` k | `movsd S(A), %xmm0` / `movsd %xmm0, <8*(W+k)>(%rsp)` |
| `ldfv` / `stfv` | `movsd <8*(W+NP)>(%rsp), %xmm0` / store; `movsd S(A), %xmm0` / `movsd %xmm0, <8*(W+NP)>(%rsp)` |
| `scell` (Fifth Edition) | `leaq .Lbsk_scells+<16*X>(%rip), %rax` / `movq %rax, S(DST)` |
| `sstr` | `movq S(A), %rdi` / `movsd S(B), %xmm0` / `call bsk_str` |
| `len` `asc` `val` | `movq S(A), %rdi` / `call bsk_len` \| `bsk_asc` \| `bsk_val` / store |
| `sald2` | `leaq .Lsdesc_<X>(%rip), %rdi` / `movsd S(A), %xmm0` / `movsd S(B), %xmm1` / `call bsk_saref2` / `movq %rax, S(DST)` |
| `sparam` k | `movq <8*(W+k)>(%rsp), %rax` / `movq %rax, S(DST)` |
| `sfv` | `movq <8*(W+NP)>(%rsp), %rax` / `movq %rax, S(DST)` |
| `fnarg` k, string parameter | `movq S(A), R(k)`. The kind of argument k is bit k of the `IRM_FNKINDS` word of the callee named by the `callfn`/`scallfn` that ends this run of `fnarg`s: the backend looks ahead to that call |
| `callfn` / `scallfn`, string parameter 0 | `movq S(A), %rdi` (instead of `movsd S(A), %xmm0`). A is argument 0 and takes parameter 0's kind, bit 0 of the callee's `IRM_FNKINDS` word |
| `scallfn` | `movsd S(A), %xmm0` or `movq S(A), %rdi` by the callee's parameter 0 kind (nothing if A = `IR_NONE`) / `movq S(B), %rax` / `call .Lfn_<L>` (nothing is stored) |
| `sret` | `movq <8*(W+NP)>(%rsp), %rdi` / `movq S(A), %rsi` / `call bsk_str_set` / multi-line functions: restore the caller's run-time line as `ret` does / epilogue |
| `fsel` | `movsd S(A), %xmm0` / `call bsk_fsel` |
| `jeof` | `movsd S(A), %xmm0` / `call bsk_feof` / `testl %eax, %eax` / `jne <label>` |
| `scratch` `frestore` | `movsd S(A), %xmm0` / `call bsk_scratch` \| `bsk_frestore` |
| `smatredim` with B (string table) | `leaq .Lsdesc_<X>(%rip), %rdi` / `movsd S(A), %xmm0` / `movsd S(B), %xmm1` / `call bsk_mat_redim2` |
| `scat` (Sixth Edition) | `movq S(A), %rdi` / `movq S(B), %rsi` / `call bsk_str_cat` |
| `sseg` | `leaq .Lbsk_scells+<16*X>(%rip), %rdi` / `movq %rdi, S(DST)` / `movq S(A), %rsi` / `movsd S(B), %xmm0` / `movsd S(C), %xmm1` / `call bsk_seg` |
| `pos` | `movq S(A), %rdi` / `movq S(B), %rsi` / `movsd S(C), %xmm0` / `call bsk_pos` / store |
| `vaddr` | `leaq V(X), %rax` / `movq %rax, S(DST)` |
| `aaddr1` / `aaddr2` | as `ald1` / `ald2` up to and including `call bsk_aref1` / `bsk_aref2`, then `movq %rax, S(DST)` |
| `taddr` | `leaq S(A), %rax` / `movq %rax, S(DST)` |
| `aref` / `saref` | `leaq .Ldesc_<X>(%rip), %rax` / `.Lsdesc_<X>` / `movq %rax, S(DST)` |
| `subarg` k | `movq S(A), %rax` / `movq %rax, <8*(W+L+k)>(%rsp)` |
| `callsub` | unless A = `IR_NONE`: `movq S(A), %rax` / `movq %rax, <8*(W+L)>(%rsp)`; then `leaq <8*(W+L)>(%rsp), %rdi` / `call .Lsub_<X>` (nothing is stored) |
| `subret` | `call bsk_sub_leave` / `movq -8(%rbp), %rbx` / `leave` / `ret` |
| `linput` (Baysick extension) | `movq S(A), %rdi` / `call bsk_linput` |
| `linput` element form (A = `IR_NONE`) | `leaq .Lsdesc_<X>(%rip), %rdi` / `movsd S(B), %xmm0` / `call bsk_linput_el` |
| `exit` | `movsd S(A), %xmm0` / `call bsk_exit` (never returns; the same in a multi-line function or a SUB unit) |

Inside a multi-line function `line`, `label`, `jmp`, `jcmp`, `sjcmp`, `jfor` and `jeof` use its
labels `.Lfn_<L>_L<id>`; inside a SUB unit, these and `gosub` (its target and its return label)
use the labels of §5.4.6 (`.Lsub_<u>_L<id>` in the SUB body) instead of `.Lbsk_L<id>`.

As in §5.3, the `.Lsdesc_<X>` rows (`sald1`, `smatredim`, `smatread`, `smatprint`, the element
forms) take the descriptor of whatever string array X names: for `smatredim`, `smatread` and
`smatprint` it may be a string table's (DIMS 2), as IR.md §3.3 allows.

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

#### 5.4.6 SUB units (Sixth Edition)

Exactly §5.3.1 with x86_64 text: the same order, block layout, `SUBL_*` record and templates
(`.Lsubl_<u>` / `.Lsubt_<u>` in `.data.rel.ro`), PDIMS and labels (with the `.L` prefix);
`%rbx` holds the activation block in the unit's code. SUB body prologue (`%rdi` = the argument
vector):

```
    pushq %rbp
    movq  %rsp, %rbp
    pushq %rbx
    subq  $<F>, %rsp                 # F = align16(8*(W+L+V) + 8) - 8, L = 1
    movq  %rdi, %rsi                 # argument vector
    leaq  .Lsubl_<u>(%rip), %rdi
    call  bsk_sub_enter              # errors report the CALL line
    movq  %rax, %rbx                 # rbx = activation block
```

An FN function of a unit omits `leaq .Lbsk_vars(%rip), %rbx` and keeps the caller's `%rbx`.
Replacements in every §5.4.5 row inside a unit (P(k) = PARAMOFF + 8k):

| Operand | In a SUB unit |
|---------|---------------|
| numeric slot X, not a parameter | `V(X)` = `<8*X>(%rbx)`, as in `main` |
| numeric slot X = parameter k | `ldv`: `movq <P(k)>(%rbx), %rax` / `movsd (%rax), %xmm0` / store; `stv`: `movsd S(A), %xmm0` / `movq <P(k)>(%rbx), %rax` / `movsd %xmm0, (%rax)`; `vaddr`: `movq <P(k)>(%rbx), %rax` / `movq %rax, S(DST)` |
| string slot s (`svar`), not a parameter | `leaq <SDOFF+16*s>(%rbx), %rax` / `movq %rax, S(DST)` |
| string slot s = parameter k | `movq <P(k)>(%rbx), %rax` / `movq %rax, S(DST)` |
| cell X (`scell`, `sseg`) | `leaq <SDOFF+4576+16*X>(%rbx), %rax` (`%rdi` in `sseg`) |
| `.Ldesc_<L>` / `.Lsdesc_<L>` loaded into register R by any row | not a parameter: `leaq <DESCOFF+32*d(L)>(%rbx), R`; parameter k: `movq <P(k)>(%rbx), R` |

Block offsets fit a signed 32-bit displacement (§3: a unit's block is at most the size of a
program's static data).

## 6. Runtime ABI

### 6.1 Program startup and state

The runtime provides `_main`. It initialises its state, calls `_bsk_kern_init` (§6.6), calls
`_bsk_program` (provided by the compiled program, AAPCS64, no arguments), and if that ever returns
calls `_bsk_end`. Sixth Edition: `_bsk_program` runs on the runtime-owned program stack (§6.9).

Runtime-private state (in `src/runtime`, not visible to programs): print `col` and `out`
counters, a 4096-byte stdout buffer and its fill count, the RND state (initial value 1964), the
DATA cursor (initial 0), the string DATA cursor (initial 0), the GOSUB stack (1024 × 8 bytes) and
its depth, the selected kernel variant and detected features (§6.6), the static matrix buffers
(§6.6.6), the DET cell `_bsk_rt_kinv_det` (double, initially 0, §6.6.1), the NUM value (double,
initially 0), and the input state of §6.7 (terminal flag, read buffer, current line and field
cursor). Fifth Edition: the pending file selection and the file table of §6.8 (one record per
FILES name, `LIM_FILES` at most). Sixth Edition (§6.9): the call stack (`LIM_CALL_DEPTH`
records of 32 bytes: block, `SUBL` record, saved GOSUB base, saved run-time line) and its
depth, the GOSUB base (initially 0), the summed `SUBL_COST` of the active activations (initially
0), and the program stack (§6.9). Baysick extensions (§6.10): the standard-error output record
(`col`, `out` initially 0, its buffer and fill count).

Data shared with compiled code:

| Symbol | Defined by | Type | Meaning |
|--------|-----------|------|---------|
| `_bsk_curline` | runtime | u32, initially 0 | BASIC line of the statement being executed |
| `_bsk_program` | program | code | main BASIC function |
| `_bsk_data` | program | double[] | DATA block in program order |
| `_bsk_data_count` | program | u64 | number of DATA values |
| `_bsk_sdata` | program | SD[] | string DATA block in program order (`SD_CAP` 0) |
| `_bsk_sdata_count` | program | u64 | number of string DATA values |
| `_bsk_files` | program | SD[] | Fifth Edition: FILES names, entry k − 1 = file #k (`SD_CAP` 0) |
| `_bsk_files_count` | program | u64 | Fifth Edition: number of FILES names, 0 … `LIM_FILES` |

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
| `_bsk_gosub_pop` | — | x0 code address | empty → error 33. Sixth Edition: depth = the GOSUB base of the current activation (§6.9) → error 33 |
| `_bsk_end` | — | noreturn | Fifth Edition: finish the files in write mode first (§6.8; a failure → `_bsk_err(ERR_CANT_WRITE_FILE)` after the remaining files are finished); pending-line newline, flush stdout, Baysick extensions: then a LF to fd 2 if standard error's `col ≠ 0` (§6.10); `exit(0)`; `exit(1)` instead if a stdout write failed at any time, the termination flush included (`_bsk_rt_broken`). Exactly `_bsk_exit` with status 0 |
| `_bsk_err` | w0 code | noreturn | precondition: code is a run-time error code, `ERR_FIRST_RUNTIME` … `ERR_END_RUNTIME` − 1 = 32..56 or (Baysick extensions) `ERR_EXT_FIRST_RUNTIME` … `ERR_EXT_END_RUNTIME` − 1 = 62; any other code exits 1 with no message. Fifth Edition: finish the files in write mode not yet finished (§6.8; a failure only forces exit status 1). Pending-line newline, flush stdout, (Baysick extensions) a LF to fd 2 if standard error's `col ≠ 0`, then write `<MESSAGE> IN <_bsk_curline>` + LF to fd 2, `exit(1)` (codes 34 OUT OF DATA and 43 END OF INPUT exit 0, unless a stdout write or a file write failed earlier, then 1; 51 END OF FILE exits 1) |

The MAT entry points (`_bsk_mat_*`) are specified in §6.5, the matrix kernels and their dispatch
(`_bsk_kern_*`) in §6.6, the string, input and other Third/Fourth Edition entry points in §6.7,
the Fifth Edition entry points and the file layer in §6.8, the Sixth Edition entry points in §6.9,
the Baysick extension entry points and standard error in §6.10.

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
| `main` | (argc, argv ignored) | never returns: `call bsk_program`, then `call bsk_end` (Sixth Edition: on the program stack, §6.9) |
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
| `bsk_saref1` | `%rdi` slist, `%xmm0` i | `%rax` SD address |
| `bsk_str_set` | `%rdi` dst, `%rsi` src | — |
| `bsk_str_cmp` | `%rdi` a, `%rsi` b | `%eax` −1 / 0 / +1 |
| `bsk_print_sv` `bsk_sread` `bsk_input_str` | `%rdi` SD | — |
| `bsk_sread_el` `bsk_input_str_el` | `%rdi` slist, `%xmm0` i | — |
| `bsk_print_tab` | `%xmm0` | — |
| `bsk_restore` | `%edi` `RESTORE_*` | — |
| `bsk_input_begin` `bsk_input_end` `bsk_randomize` | — | — |
| `bsk_input_num` `bsk_num` `bsk_det` | — | `%xmm0` |
| `bsk_mat_input` `bsk_smat_input` `bsk_smat_read` | `%rdi` desc | — |
| `bsk_smat_print` | `%rdi` desc, `%esi` mode | — |
| `bsk_change_s2n` | `%rdi` list, `%rsi` source SD | — |
| `bsk_change_n2s` | `%rdi` destination SD, `%rsi` list | — |
| `bsk_change_n2s_el` | `%rdi` slist, `%xmm0` i, `%rsi` list | — |
| `bsk_on` | `%xmm0` x, `%edi` n | `%xmm0` |
| `bsk_sgn` `bsk_cot` | `%xmm0` | `%xmm0` |
| `bsk_saref2` (Fifth Edition, §6.8) | `%rdi` sdesc, `%xmm0` i, `%xmm1` j | `%rax` SD address |
| `bsk_str_clear` | `%rdi` SD | — |
| `bsk_str` | `%rdi` destination SD, `%xmm0` x | — |
| `bsk_len` `bsk_asc` `bsk_val` | `%rdi` SD | `%xmm0` |
| `bsk_fsel` `bsk_scratch` `bsk_frestore` | `%xmm0` file number | — |
| `bsk_feof` | `%xmm0` file number | `%eax` 1 / 0 |
| `bsk_str_cat` (Sixth Edition, §6.9) | `%rdi` dst, `%rsi` src | — |
| `bsk_seg` | `%rdi` dst, `%rsi` src, `%xmm0` first, `%xmm1` last | — |
| `bsk_pos` | `%rdi` a, `%rsi` b, `%xmm0` start | `%xmm0` |
| `bsk_sub_enter` | `%rdi` SUBL record, `%rsi` argument vector | `%rax` activation block |
| `bsk_sub_leave` | — | — |
| `bsk_linput` (Baysick extensions, §6.10) | `%rdi` SD | — |
| `bsk_linput_el` | `%rdi` slist, `%xmm0` i | — |
| `bsk_exit` | `%xmm0` status | noreturn |

Defined by every compiled program (§5.4.3): `bsk_program` (code, System V, no arguments),
`bsk_data` (8-byte aligned doubles), `bsk_data_count` (u64), `bsk_sdata` (8-byte aligned `SD_*`
records), `bsk_sdata_count` (u64), and with the Fifth Edition `bsk_files` (8-byte aligned `SD_*`
records) and `bsk_files_count` (u64). The DET cell is `bsk_rt_kinv_det` (`.globl` + `.hidden`,
defined in `rt_kinit.s`). The `RTA_*` descriptor layout is
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
| input (§6.7) | `read(0, buf, n)`, `isatty(0)`, `strtod` |
| strings (§6.7) | `malloc`, `realloc`, `memcpy`/`memmove` (or explicit loops) |
| RANDOMIZE, TAB, COT | `getentropy(buf, 8)` (glibc ≥ 2.25), `time(NULL)`; `fmod`; `tan` |
| files (§6.8) | `open(path, flags, mode)` (variadic: `movl $0, %eax` before the call; `O_RDONLY` 0, `O_WRONLY` 01, `O_CREAT` 0100, `O_TRUNC` 01000), `close`, `fstat(fd, buf)` (`struct stat` 144 bytes, `st_mode` u32 at offset 24), `read`, `write` |
| STR$ (§6.8) | the `rt_numfmt` field routine (no new libc call) |
| program stack (§6.9) | `sysconf(30)` (`_SC_PAGESIZE`), `mmap(NULL, n, 3, 0x22, -1, 0)` (`PROT_READ\|PROT_WRITE`, `MAP_PRIVATE\|MAP_ANONYMOUS`), `mprotect(base, G, 0)`, `madvise(base, n, 15)` (`MADV_NOHUGEPAGE`, result ignored) |

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
* `_bsk_mat_redim1` also redimensions string lists (MAT READ `X$(n)`): the test only uses
  `RTA_DIMS` 1 and `RTA_CAP`, which a string-list descriptor carries (`CAP = b1 + 1`).
* `_bsk_smat_read` (in `rt_data.s`) and `_bsk_smat_print` (in `rt_mat.s`) handle string lists
  (LANGUAGE.md §7.14.4–7.14.5): current bound 0 → error 40; elements 1 … B1 read with the string
  DATA cursor (`_bsk_str_set` semantics, OUT OF DATA as `_bsk_sread`) / printed with the §8 string
  item and, between elements, the comma rule (zoned) or nothing (packed).
* **DET**: `_bsk_mat_inv` needs no change; the inv kernel writes the determinant (§6.6.1) and
  `_bsk_det` reads it.
* Error codes come from `errors.inc` by name; `_bsk_err` is called with `_bsk_curline` already set
  by the statement's `line`.

### 6.6 Matrix kernels and CPU-feature dispatch (`rt_kinit.s`, `rt_k*.s`, both targets)

The heavy arithmetic lives in **kernels**: plain routines on matrix views with no BASIC
semantics, reached through one dispatch point chosen once at startup from the CPU's features. A
**variant** is a set of kernels for one instruction-set level. Required now: **`neon`**
(arm64-macos baseline, Advanced SIMD) and **`sse2`** (x86_64-linux baseline). Implemented beyond the baselines:
**`avx2`** (x86_64 with AVX2 and FMA3). Documented future example: **`sme`** (Apple M4 and later:
SME with FEAT_SME_F64F64). Adding a variant touches only the runtime directory of its target (§6.6.7).

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
| `_bsk_kern_inv` | x0 X, x1 A | x0 `KS_*` | A, X `n×n`, `n ≤ RT_KERN_INV_MAXN`; no overlap; LANGUAGE.md §7.14.6 exactly (incl. `KS_SINGULAR`, and `KS_NONFINITE` for a non-finite pivot or result); also stores the determinant of §7.14.6 (DET) into the runtime-private double `_bsk_rt_kinv_det` (ELF `bsk_rt_kinv_det`, defined in `rt_kinit.s`, so link isolation holds) — after a `KS_OK` or `KS_NONFINITE` return it holds the pinned product of the pivots (class E: bit-identical across variants) |

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
| `KF_X64_AVX2` | x86_64-linux | `CPUID.(EAX=7,ECX=0):EBX[5]`, and `CPUID.1:ECX[28]` (AVX), and OS support: `CPUID.1:ECX[27]` (OSXSAVE) and `XGETBV(ECX=0)` bits 1 and 2 both set |
| `KF_X64_FMA` | x86_64-linux | `CPUID.1:ECX[12]` and `CPUID.1:ECX[28]` (AVX), with the same OS-support test |

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
| `avx2` | x86_64-linux | `KF_X64_AVX2 \| KF_X64_FMA` | implemented | GEMM (FMA, class R); copy, fill, trn (256-bit, class E); inv (4-wide, class E). add, sub, scale use the `sse2` kernels: Haswell lowers the core clock while 256-bit FP arithmetic runs, which costs the memory-bound 256-bit versions more than the width gains |
| `neon` | arm64-macos | 0 | **required now** (baseline) | all |
| `sme` | arm64-macos | `KF_A64_SME \| KF_A64_SME_F64F64` | future | GEMM (FMOPA outer products into ZA tiles) |
| `sse2` | x86_64-linux | 0 | **required now** (baseline) | all |

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
  * `avx2`: `MR × NR = 6 × 8` with 12 `ymm` accumulators, B packed 8 wide (two `ymm` per row of the
    micro-panel), A values broadcast with `vbroadcastsd`, `vfmadd231pd` (FMA, class R);
    KC = 256, MC = 72, NC = 2048.
  * For tiny products (`m·n·k ≤ 32768`) an unpacked, still vectorised path is allowed.
* **add, sub, scale, copy, fill** — row loop × contiguous inner loop of 2-wide vectors, unrolled
  to at least 4 vectors per iteration, scalar tail; the finite check fused into the same pass.
* **trn** — cache-blocked (e.g. 32 × 32 element blocks) with in-register tile transposes
  (`neon`: `zip1`/`zip2` on `.2d` building 2 × 2 or 4 × 4 tiles; `sse2`: `unpcklpd`/`unpckhpd`).
  The `avx2` transpose uses 4 × 4 register tiles in 32 × 32 blocks (`vinsertf128` loads, then
  `vunpcklpd`/`vunpckhpd`).
* **inv** — the §7.14.6 algorithm with the pivot-row division and the row updates vectorised
  2-wide over `j` (`fdiv`/`divpd`; `fmul` then `fsub` / `mulpd` then `subpd`; never `fmla`).
  The row updates may use a delayed or blocked schedule (the x86_64 runtime updates in panels of
  16 pivot columns with a register-blocked micro-kernel), provided every element receives exactly
  the pinned operations in the pinned order (one rounded product, one rounded subtraction, true
  divisions). Updates may be skipped when that cannot change the status or any finite result element (LANGUAGE.md §7.14.6; e.g. products with an exact zero factor on untouched columns of X). The
  arm64 runtime uses the same panel schedule (16 pivot columns, `RT_KI_NB`) with a 4 × 8
  register-tiled delayed update (16 accumulators, multipliers used by element), and skips only the
  products with the untouched, exactly zero columns of X (kept in a private column order; a non-finite multiplier still reaches the result through the later update of that column).
  The `avx2` runtime uses the `sse2` panel schedule (NB = 16) with a 4 × 12 delayed-update
  micro-kernel (12 `ymm` accumulators); products are `vmulpd` then `vsubpd`, never FMA.
* Benchmarks and initial goals: BENCH.md.

#### 6.6.6 Static buffers

All in zero-initialised data (`.zerofill __DATA,__bss,…,6` / `.bss` with `.p2align 6`); untouched
pages cost nothing:

| Buffer | Size | Owner |
|--------|------|-------|
| MAT result temporary | `RT_MAT_SCRATCH_ELEMS` doubles (8 MiB) | `rt_mat.s` (aliasing, §6.5) |
| INV workspace W | `RT_KERN_INV_MAXN²` doubles (8 MiB) | inv kernel |
| `avx2` INV workspace W | `RT_KERN_INV_MAXN²` doubles (8 MiB), separate from the `sse2` one; only touched by an `avx2` INV | `rt_kavx2_inv.s` |
| `avx2` INV multiplier buffer | `NB` × 128 bytes = 2 KiB (the packed multipliers of one 4-row block) | `rt_kavx2_inv.s` |
| INV index buffer `_bsk_rt_kinv_idx` (arm64) | 3 × `RT_KERN_INV_MAXN` u32 (12 KiB): row-of, unit-position and column-of bookkeeping for the column order of X | `rt_kneon_inv.s` |
| `sse2` / `neon` GEMM packing buffers | runtime-private, at most 8 MiB per variant | the baseline gemm kernel |
| `avx2` GEMM packing (separate from the `sse2` buffers; at most 8 MiB per variant, about 4.14 MiB here) | Ap: `MC·KC` doubles (144 KiB); Bp: `KC·NC` doubles (4 MiB); 6 × 8 staging tile for partial C tiles (384 bytes) | `rt_kavx2_gemm.s` |

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
   PSTATE.ZA = 0) on every path. AVX2 kernels end with `vzeroupper`. Haswell lowers the core clock while 256-bit FP arithmetic runs, so a memory-bound 256-bit kernel can be slower than the 128-bit one (and the lower clock lingers into the surrounding scalar code): measure before specialising (BENCH.md §6.1). Copy and fill are pure moves (no floating-point arithmetic, so no clock reduction) and are not separately benchmarked; `avx2` specialises them without a measurement.
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

### 6.7 Strings, input and the other Third/Fourth Edition entry points (both targets)

arm64 names; x86_64 drops the underscore and maps registers as in §6.4.2. "SD" is a pointer to
a 16-byte string descriptor (`SD_*`, runtime.inc); "list"/"slist" a numeric/string-list `RTA_*`
descriptor. Errors are raised with `_bsk_err` by name (`errors.inc`).

| Function | In | Out | Semantics (LANGUAGE.md) |
|----------|----|-----|-------------------------|
| `_bsk_saref1` | x0 slist, d0 i | x0 SD | subscript rule of `_bsk_aref1` (§7.11, error 32) against `RTA_B1`; address `RTA_DATA + 16·r` |
| `_bsk_str_set` | x0 dst, x1 src | — | §7.1 copy; dst = src → nothing; else n = src LEN; if n > dst CAP: `realloc(dst PTR or NULL, cap')` with cap' = n rounded up to a multiple of 16 (at least 16), NULL → error 47 OUT OF ROOM, CAP := cap'; copy n bytes (`memmove` semantics not needed: two descriptors never share a buffer); LEN := n |
| `_bsk_str_cmp` | x0 a, x1 b | w0 | §7.7: strip trailing `0x20` from both lengths, compare `min` bytes unsigned, then lengths; −1 / 0 / +1 |
| `_bsk_print_sv` | x0 SD | — | §8 string item: emit each byte through the column logic (lazy spaces) |
| `_bsk_print_tab` | d0 x | — | §8 TAB: `m = fmod(trunc(x), 75)` (trunc: `frintz` on arm64, libm `trunc` on x86_64; both exact), `m += 75` if `m < 0`; if `col < m` then `col = m` (as an integer column) |
| `_bsk_sread` | x0 dst | — | next string DATA value (`_bsk_sdata`, own cursor) copied as by `_bsk_str_set`; none left → error 34 (exit 0) |
| `_bsk_sread_el` | x0 slist, d0 i | — | the element form (IR.md §3.2): the next string DATA value is taken (none left → error 34, exit 0), then element i is addressed by `_bsk_saref1` (error 32: the subscript is checked at the store, §7.1, §7.4), then the value is copied into it as by `_bsk_sread` |
| `_bsk_restore` | w0 | — | `RESTORE_ALL`: both cursors := 0; `RESTORE_NUM`: numeric cursor; `RESTORE_STR`: string cursor |
| `_bsk_input_begin` | — | — | §7.15: read the first line (prompt rule, END OF INPUT, INPUT LINE TOO LONG); field cursor at its start |
| `_bsk_input_num` | — | d0 | next field as a number: no field → `NOT ENOUGH INPUT -- ADD MORE`, new line; invalid → `INPUT DATA NOT IN CORRECT FORMAT -- RETYPE IT`, new line; repeat; value by `strtod` on the blank-free field text |
| `_bsk_input_str` | x0 dst | — | the same for a string field; the value is stored with `_bsk_str_set` semantics |
| `_bsk_input_str_el` | x0 slist, d0 i | — | the element form: the field is taken exactly as by `_bsk_input_str` (every NOT ENOUGH INPUT / RETYPE diagnostic and new line first), then element i is addressed by `_bsk_saref1` (error 32 at the store, §7.15), then the value is stored into it |
| `_bsk_input_end` | — | — | fields left → `TOO MUCH INPUT -- EXCESS IGNORED` |
| `_bsk_mat_input` `_bsk_smat_input` | x0 list / slist | — | §7.14.8, transactional; NUM := n |
| `_bsk_change_s2n` | x0 list, x1 SD | — | §7.19 string → list (error 32) |
| `_bsk_change_n2s` | x0 SD, x1 list | — | §7.19 list → string (errors 32, 44, 45, 47) |
| `_bsk_change_n2s_el` | x0 slist, d0 i, x1 list | — | the element form: the conversion with all its checks as `_bsk_change_n2s` (errors 32 for the length, 44, 45), then element i is addressed by `_bsk_saref1` (error 32 at the store, §7.19), then assigned (47) |
| `_bsk_on` | d0 x, w0 n | d0 | `k = trunc(x)`; `1 ≤ k ≤ n` (compared as doubles, so huge x cannot wrap) → k, else error 42 |
| `_bsk_randomize` | — | — | §7.18: `getentropy(&v, 8)`; on failure `v = time(NULL)`; RND state := `1 + (v mod 2147483646)` (unsigned 64-bit `v`) |
| `_bsk_sgn` | d0 | d0 | 1, 0 (either zero), −1 |
| `_bsk_cot` | d0 | d0 | `t = tan(x)`; `t == ±0` → error 35; `1/t`; not finite → error 38 |
| `_bsk_num` | — | d0 | the NUM value |
| `_bsk_det` | — | d0 | `_bsk_rt_kinv_det`; not finite → error 38 |

**Input reader.** Standard input is read with `read(0, buf, RT_INBUF_SIZE)` into a static buffer
(`EINTR` retried; any other error or 0 bytes = end of input **for that request only**). A reader
never remembers end of input, standard input included: every request that needs a byte while
none is held does a fresh `read`, so a terminal user can type more after an end-of-file. A line is assembled from it into a
static line buffer: the bytes up to LF; one CR immediately before the LF removed (an
unterminated last line keeps a trailing CR, LANGUAGE.md §7.15); a non-empty unterminated last
line counts. A line that is still longer than `LIM_INPUT_LINE` bytes after the CR removal →
error 46; as soon as more than `LIM_INPUT_LINE + 1` bytes precede the LF (or the end of input)
the line can never become legal, so error 46 is raised then and nothing beyond
`LIM_INPUT_LINE + 1` bytes is ever stored. The buffer therefore needs `LIM_INPUT_LINE + 1`
bytes, a maximal line plus the CR that is still to be removed: the x86_64 runtime allocates
exactly that, the arm64 runtime `LIM_INPUT_LINE + 16` (the same plus 15 bytes of slack, so the
16-byte-aligned `__bss` object is a multiple of 16 bytes; the slack is never written).
`isatty(0)` is called once, at the first line request, and remembered. On a terminal, before
each line request: write the pending lazy spaces and `"? "` through the print buffer, set
`out = col = col + 2`, flush stdout; after the line, `col = out = 0`. End of input at a line
request: `_bsk_err(ERR_END_OF_INPUT)` (pending newline, flush, `END OF INPUT IN n`, exit 0).

**Fields.** The current line is scanned lazily from a cursor: a field ends at the next comma
outside quotes; an all-blank (or empty) line has no field. A numeric field is valid when, after
removing every `0x20`, it matches `[+|-] mantissa [E [+|-] digits]` with LANGUAGE.md §4.1 limits
(`e` accepted); the runtime copies the blank-free text into a scratch buffer and calls `strtod`.
A quoted field must be `"bytes"` followed only by blanks before the comma or end of line. An
unquoted string field must not contain `"` (nor, in MAT INPUT, `&`); its value starts after its
leading blanks. The three diagnostics come from `BSK_EMIT_INPUT_MSGS` (errors.inc): flush stdout,
then `write(2, msg, len)` (failures ignored).

**MAT INPUT** (LANGUAGE.md §7.14.8) is transactional in both runtimes: every field of every
line the statement reads is validated before anything is stored. A line whose last non-blank
byte outside quotes is `&` continues on the next line; the line's text ends before the `&`, or
before one comma that precedes it with only blanks between. The growable buffers are `malloc`
memory reused by every MAT INPUT of the run (grown with `realloc` to max(needed, 2 × capacity,
4096 bytes); failure → error 47). Any invalid field → `INPUT DATA NOT IN CORRECT FORMAT -- RETYPE
IT`, everything this statement read is discarded and it starts again with a new line. With n
fields: n = 0 → NUM := 0, the list unchanged; n + 1 > `RTA_CAP` → error 40; else `RTA_B1` := n,
elements 1…n stored (strings with `_bsk_str_set` semantics), NUM := n. The two runtimes reach
this differently:

* arm64 (`src/runtime/rt_input.s`, `Lrt_in_matin`): the text of all the statement's lines
  (each shortened at its continuation `&`) is first collected into one text buffer, one
  LF-terminated record per line, for numeric and string lists alike. Then pass 1 scans that
  text, validating and counting every field (the first invalid one → RETYPE); pass 2, after
  the bound has been set, scans the same text again and stores field k into element k.
* x86_64 (`src/runtime_x86_64_linux/rt_input.s`, `.Lrt_in_mat`): each line's fields are
  validated as the line is read and collected: numbers as doubles into a values buffer,
  strings as (offset, length) pairs (in the values buffer) into the text of the lines (kept, for
  a string list only, in a text buffer). An invalid field is remembered and the rest of the
  input is still read up to the last line; then RETYPE. If every field is good, the store loop
  copies the collected values into elements 1…n.

**String storage** grows with `realloc` and is never freed (a program's strings live until it
exits); string constants and string DATA (`SD_CAP` = 0) are never written. The runtime still
never uses stdio.

### 6.8 Fifth Edition entry points and the file layer (both targets)

arm64 names; x86_64 drops the underscore and maps registers as in §6.4.2. "sdesc" is the `RTA_*`
descriptor of a string list or string table; a "file number" is a double (the designator value,
LANGUAGE.md §7.21). Files: `src/runtime/rt_files.s` and `rt_ed5.s` (arm64),
`src/runtime_x86_64_linux/rt_files.s` and `rt_ed5.s` (x86_64), plus the changes listed in §2.

| Function | In | Out | Semantics (LANGUAGE.md) |
|----------|----|-----|-------------------------|
| `_bsk_saref2` | x0 sdesc, d0 i, d1 j | x0 SD | subscript rule of `_bsk_aref2` (§7.11, error 32) against the current `RTA_B1`/`RTA_B2`; address `RTA_DATA + 16·(ri·RTA_ROWLEN + rj)` |
| `_bsk_str_clear` | x0 SD | — | LEN := 0 (PTR and CAP kept) |
| `_bsk_str` | x0 dst, d0 x | — | §6.1 STR$: the §9 field of x from the `rt_numfmt` routine without its leading blank (x ≥ 0, `-0` included) and without its trailing blank; stored into dst with `_bsk_str_set` semantics (error 47) |
| `_bsk_len` | x0 SD | d0 | `SD_LEN` as a double (`ucvtf` / `cvtsi2sdq` of the zero-extended u32) |
| `_bsk_asc` | x0 SD | d0 | LEN = 0 → error 55; else the first byte (unsigned) as a double |
| `_bsk_val` | x0 SD | d0 | §6.1: the numeric-field check of §6.7 ("Fields") on the whole value (every `0x20` removed, then `[+|-] mantissa [E [+|-] digits]` with the §4.1 limits); invalid or empty → error 54; else `strtod` on the blank-free text (the scratch buffer of the input reader may be reused: a VAL argument has at most `LIM_STRING_LEN` bytes, and a valid one at most 15 after blank removal, so longer blank-free text is rejected before copying). Implementation: the arm64 `_bsk_val` calls `_bsk_rt_parsenum`, which has a 48-byte stack frame (frame record plus the 32-byte `RT_IN_NUMBUF` text buffer) and rejects blank-free text longer than 31 bytes; the x86_64 `bsk_val` calls `bsk_rt_numtext`, which copies at most 16 non-blank bytes. The behaviour is the same on both, since a valid constant is at most 15 bytes |
| `_bsk_fsel` | d0 x | — | `k = trunc(x)` compared as a double: `0 ≤ k ≤ _bsk_files_count` else error 49; the pending selection := k |
| `_bsk_feof` | d0 x | w0 | LANGUAGE.md §7.26: number check as `_bsk_fsel` (error 49); k ≥ 1 in write mode → 0; k ≥ 1 in read mode → open if needed (error 48), then 1 if the reader has no unread byte (a refill `read` returns 0), else 0; k = 0 → the same on the standard-input reader (on a terminal stdout is flushed before the refill `read`; `col` and `out` are not reset — only a line read by INPUT or INPUT #0 resets them) |
| `_bsk_scratch` | d0 x | — | §7.22, in this order: number check (error 49; k = 0 → error 49); close the file if open (write mode: buffered output discarded, not written); empty file k's reader (buffer, current line, cursor); `open(path, O_WRONLY|O_CREAT|O_TRUNC, 0666)` (failure → error 48); only then, if the file has no output buffer yet, `malloc(RT_FILEBUF_SIZE)` (failure → error 47); write mode, `col = out = 0`, buffer empty |
| `_bsk_frestore` | d0 x | — | §7.23: number check (error 49); k = 0 → error 49; write mode: `col ≠ 0` → LF into the buffer, flush (failure → error 53), `close`; read mode, open: `close`; the file becomes "read, not open" and its reader state (buffer, current line, cursor) is emptied |

**Pending selection.** `_bsk_fsel` stores k in a runtime-private word ("none" otherwise). Every
print and input entry point — `_bsk_print_num _bsk_print_str _bsk_print_sv _bsk_print_comma
_bsk_print_semi _bsk_print_tab _bsk_print_nl _bsk_input_begin _bsk_input_num _bsk_input_str
_bsk_input_str_el _bsk_input_end` — reads the pending selection **and resets it to none on
entry**, before anything else (so a function the entry point could not call anyway never sees a
stale selection). With none, or with k = 0 for a print entry point, it does exactly what §6.2 and
§6.7 specify. Otherwise:

* **print, k ≥ 1:** file k must be in write mode, else error 50 ILLEGAL FILE COMMAND; then the
  §8 column logic runs with file k's own `col`, `out` and output buffer instead of stdout's. The
  column code is one routine parameterised by a pointer to an output-state record (stdout's or a
  file's), so the rules cannot drift apart.
* **input, k ≥ 1 or k = 0:** the INPUT # rules (LANGUAGE.md §7.25) on the selected reader (file
  k's, or for k = 0 the standard-input reader of §6.7): no prompt, no diagnostics. Every input
  request (`_bsk_input_begin`, `_bsk_input_num`, `_bsk_input_str`, `_bsk_input_str_el`,
  `_bsk_input_end`) rechecks the mode of file k ≥ 1 — read mode, else error 50 — and opens it if
  needed (error 48). So a function in a target subscript that executes RESTORE #k or SCRATCH #k
  in the middle of the statement makes the next field reopen the file (from its start) or raise
  error 50. `_bsk_input_begin` reads the next
  line of the reader (none → error 51 END OF FILE); `_bsk_input_num` / `_bsk_input_str` /
  `_bsk_input_str_el` take the next field, reading further lines silently while the current one
  has no field left (none → error 51); an invalid field → error 52 INCORRECT FORMAT IN FILE (the
  element form takes the field first, then addresses the element, error 32 at the store);
  `_bsk_input_end` discards the rest of the current line without a message. For k = 0 on a
  terminal: stdout is flushed before each line is read and `col = out = 0` after it (no `"? "` is
  written); IF END #0 (`_bsk_feof`) flushes stdout before its `read` but does not reset `col` or
  `out`. An over-long line → error 46 as in §6.7.

**Readers.** The standard-input reader of §6.7 and each file's reader have the same state: an
input chunk buffer, its start/end positions, a line buffer, the current line's length and the
field cursor. They share one line-assembly and field-scanning routine parameterised by a pointer
to the reader (the INPUT dialogue's prompt and diagnostics are the only differences, selected by
a flag). A file reader's buffers are `malloc`ed when the file is first opened for reading
(`RT_INBUF_SIZE` chunk, `LIM_INPUT_LINE + 16` line bytes; failure → error 47) and reused after
RESTORE #. **Chunk rule** (LANGUAGE.md §7.21 "Readers", observable, so both runtimes do exactly
this): a reader calls `read(fd, chunk, RT_INBUF_SIZE)` only when it needs a byte and holds no
unread byte; it never discards unread bytes except at RESTORE # / SCRATCH # of its file; it
never reads ahead otherwise. A reader's current line belongs to the reader, not to a statement: INPUT, MAT INPUT,
INPUT #0 and IF END #0 all advance the one standard-input reader (LANGUAGE.md §7.21), and each
`_bsk_input_begin` starts with the reader's next line. `read` is retried on `EINTR`; any other
error or 0 bytes is end of input **for that request only**: a reader never remembers end of
input (standard input included), so every request that needs a byte while the reader holds none
does a fresh `read`.

**File table.** Runtime-private, zero-initialised (state "read, not open"). The arm64 runtime
indexes the file-mode table and the fd table by k, entry 0 unused (`RT_FILES_N` entries); the
x86_64 runtime indexes its state and fd arrays (`LIM_FILES` entries) by k − 1. In both runtimes
the output records and the reader records are indexed by k, entry 0 being stdout / stdin (the
`_bsk_files` entry k − 1 is the name of file #k). Per file: state (read-not-open /
read-open / write), `fd`, output `col` and `out`, the
output buffer pointer and fill count (`RT_FILEBUF_SIZE` bytes, `malloc`ed at the first SCRATCH
of the file after its `open` succeeded, failure → close the new fd, then error 47; the buffer is then reused), the reader, and a
"write failed" flag. The flag is per file and lives in the file's output record (with `col`,
`out` and the buffer); a later SCRATCH of the file clears it. Records
beyond `_bsk_files_count` are never touched.

**Opening.** The path is the file's `_bsk_files` entry copied into a NUL-terminated
runtime-private buffer of `LIM_FILE_NAME + 1` bytes (a FILES name never contains a 0 byte,
LANGUAGE.md §7.21). Read: `open(path, O_RDONLY)`; then `fstat(fd, &st)` and if
`(st_mode & S_IFMT) == S_IFDIR` the fd is closed and the open fails (on Unix `open` succeeds on a
directory); any failure → error 48 CAN'T OPEN FILE. Write: `open(path, O_WRONLY|O_CREAT|O_TRUNC,
0666)` (fails on a directory by itself). `open` is variadic: on arm64-macos the mode goes **on
the stack** (§3.1), on x86_64-linux in `%edx` with `%eax` = 0. The flag values differ between
the hosts and are runtime-private constants of each runtime: macOS `O_RDONLY` 0, `O_WRONLY` 1,
`O_CREAT` 0x200, `O_TRUNC` 0x400, `struct stat` 144 bytes with `st_mode` (u16) at offset 4;
Linux §6.4.3. `S_IFMT` 0o170000, `S_IFDIR` 0o040000 on both. `close` results are ignored.

**Writing.** Output bytes of file k go into its buffer through one byte-append routine, and
that routine is the only place that writes a full buffer: immediately after it stores a byte
that makes the fill count equal to `RT_FILEBUF_SIZE`, it writes all 4096 bytes with `write`
(retried on `EINTR` and after a partial write until done) and sets the fill count to 0. A full
buffer is never kept until the next byte, and a partially filled buffer is written only by
RESTORE # and at termination (LANGUAGE.md §7.21). A failure (any other error, or a write
of 0 bytes) sets the file's "write failed" flag, empties its buffer and raises error 53
CAN'T WRITE FILE; the flagged file is skipped by every later flush (it stays in write mode; a
later SCRATCH clears the flag). The column logic never writes a trailing blank (lazy spaces,
§8), so a file never contains one.

**Finishing at termination.** `_bsk_end` and `_bsk_err` finish the files once (a runtime-private
"finished" flag makes the second call a no-op, so `_bsk_err` called from `_bsk_end` does not
repeat it): for k = 1 … `_bsk_files_count` in ascending order, every file in write mode whose
"write failed" flag is clear gets a LF in its buffer if its `col ≠ 0` and is flushed. Any failure
is remembered and the loop continues. The result of the finish (both runtimes) is the OR of the
"write failed" flags of files 1 … min(`_bsk_files_count`, `LIM_FILES`), read from the per-file
output records, so a second call returns the same result and a later SCRATCH clears it; there is
no separate "output lost" global. Then: in `_bsk_end`, a failure → `_bsk_err(ERR_CANT_WRITE_FILE)`
with `_bsk_curline` still the END/STOP line; in `_bsk_err`, a failure (or an earlier "write
failed" flag of any file) makes the exit status 1 whatever the code (LANGUAGE.md §10): once set
(and not cleared by a later SCRATCH), a file's flag forces exit status 1 at termination even if
the file is no longer in write mode (after RESTORE #). Only then
stdout's pending-line newline and flush, then the message. Files in read mode need nothing, and
no file is closed (exit closes them).

**String tables.** `_bsk_smat_read` and `_bsk_smat_print` accept a string table descriptor
(`RTA_DIMS` 2) and process its current r × c shape row by row exactly like `_bsk_mat_read` /
`_bsk_mat_print` for a numeric table (§6.5; LANGUAGE.md §7.14.5: string elements are printed as
string items); `_bsk_mat_redim2` redimensions a string table descriptor exactly as a numeric table (§6.5: only
the `RTA_*` shape fields change; the test uses `RTA_CAP` in elements, so the element size does not
matter, and no element is moved or freed). MAT INPUT stays list-only (§7.14.8).

### 6.9 Sixth Edition entry points and the call stack (both targets)

arm64 names; x86_64 drops the underscore and maps registers as in §6.4.2. Files:
`src/runtime/rt_ed6.s` and `rt_sub.s` (arm64), `src/runtime_x86_64_linux/rt_ed6.s` and
`rt_sub.s` (x86_64), plus the changes listed in §2. "Rounded" means ⌊x + ½⌋ evaluated exactly as
in `_bsk_aref1`, compared as a double (so huge or negative values never wrap).

| Function | In | Out | Semantics (LANGUAGE.md) |
|----------|----|-----|-------------------------|
| `_bsk_str_cat` | x0 dst, x1 src | — | §4.6 `&`: Ld = dst LEN, Ls = src LEN (read before anything changes; src may be dst); n = Ld + Ls; n > `LIM_STRING_LEN` → error 44 STRING TOO LONG (dst unchanged); if n > dst CAP: cap' = max(n, 2·CAP) rounded up to a multiple of 16; CAP > 0: `realloc(PTR, cap')`; CAP = 0 (PTR not owned): `malloc(cap')` and copy the Ld bytes of the old PTR; NULL → error 47 OUT OF ROOM; CAP := cap'; then copy the Ls source bytes (from the new PTR when src = dst) to PTR + Ld; LEN := n |
| `_bsk_seg` | x0 dst, x1 src, d0 m, d1 n | — | §6.2: m', n' = rounded m, n; L = src LEN; first = max(m', 1), last = min(n', L); first > last → dst := the empty string (LEN := 0); else dst := bytes first … last of src (1-based) with `_bsk_str_set` semantics (error 47). dst is a string temp cell, never src. A NaN m or n means "no bound" (`fmaxnm`/`fminnm` semantics: first = 1, last = L; x86_64 handles it with explicit branches); no BASIC expression produces a NaN |
| `_bsk_pos` | x0 a, x1 b, d0 start | d0 | §6.2: s' = rounded start, p0 = max(s', 1); L = a LEN, K = b LEN; the smallest p with p0 ≤ p ≤ L − K + 1 whose K bytes at p equal b's (byte for byte; K = 0 matches at every p) as a double, else 0. No error. A NaN start means "no bound" (p0 = 1, `fmaxnm` semantics; x86_64 handles it with an explicit branch); no BASIC expression produces a NaN |
| `_bsk_sub_enter` | x0 SUBL record, x1 argument vector | x0 block | §7.27 step 2, in this order: call depth = `LIM_CALL_DEPTH` → error 56 TOO MANY CALLS; summed cost + `SUBL_COST` > `LIM_CALL_WORDS` → error 56; for k = 0 … NPARAMS−1 with `SUBL_PDIMS[k]` = `SUBD_LIST` / `SUBD_TABLE`: argument k's `RTA_DIMS` ≠ 1 / 2 → error 40 DIMENSION ERROR; `calloc(1, SUBL_BLOCKSIZE)` NULL → error 47; summed cost += `SUBL_COST`; copy the NPARAMS argument pointers to block + `SUBL_PARAMOFF`; copy the `SUBL_NDESC` templates to block + `SUBL_DESCOFF` and add the block address to each copy's `RTA_DATA`; push the call record {block, SUBL, GOSUB base, `_bsk_curline`}; GOSUB base := GOSUB depth; return the block. All errors report the CALL line (`_bsk_curline` is unchanged) |
| `_bsk_sub_leave` | — | — | §7.27 step 5: pop the newest call record; summed cost −= its `SUBL_COST`; free the buffer of every SD record with `SD_CAP` > 0 among the `SUBL_NSD` records at block + `SUBL_SDOFF`; free the block; GOSUB depth := the current GOSUB base (the activation's pending GOSUBs are dropped); GOSUB base := the saved base; `_bsk_curline` := the saved line |

**Program stack** (both runtimes, unconditional). `_main` (x86_64: `main`), after its existing
initialisation, maps `RT_PROGRAM_STACK_BYTES` (24 MiB) plus one guard page G (the host page size:
`sysconf(_SC_PAGESIZE)`, 16 KiB on arm64 macOS, 4 KiB on x86_64 Linux) with
`mmap(NULL, size + G, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANON, -1, 0)`, makes the lowest G
bytes inaccessible with `mprotect(base, G, PROT_NONE)`, sets the stack pointer to
base + G + `RT_PROGRAM_STACK_BYTES` (16-byte aligned, as both ABIs require at a call) and calls
`_bsk_program` there, then `_bsk_end` if it returns. A failure of `mmap` or `mprotect` →
`_bsk_err(ERR_OUT_OF_ROOM)` before any line runs (`OUT OF ROOM IN 0`, exit 1; host-dependent, like
every OUT OF ROOM). The x86_64 runtime also calls `madvise(base, size + G, MADV_NOHUGEPAGE)` right
after the `mmap` (`MADV_NOHUGEPAGE` = 15): on a host whose transparent huge pages are set to
`always` the 24 MiB mapping would otherwise get a 2 MiB huge page, about 2 MiB of resident memory
and about 0.1 ms on every run. The call is advisory and its result is ignored (an old kernel may
return `EINVAL`). macOS has no equivalent and needs none. The stack is used for nothing else and
never freed.

**Why 24 MiB is enough, on both targets, whatever `ulimit -s` is.** The stack holds (a) the
activations: at most `8·LIM_CALL_WORDS` = 16 MiB (§5.3.1); (b) the main program's frames: `main`
and at most one chain of its FN functions (≤ 26, non-recursive), each at most `8·frame(f)` bytes;
L ≤ 10, V ≤ 16, and W — the temps defined between two `line`s — is bounded by the statement
text: no lowering rule of IR.md §4 defines more than two temps per byte of a ≤ 255-byte line
(the densest cases are a copied string argument `A$`, `svar` + `scell` for 2 bytes, and a CALL
string constant, `slit` + `scell` for the 3 bytes `"",`), so W ≤ 510 and (b) ≤ 27 × 8 × 542 bytes
≈ 114 KiB; (c) the runtime routine active in the deepest frame and the libc it calls (`snprintf`,
`malloc`/`realloc`/`calloc`/`free`, `write`, libm): a few KiB on both hosts. (b) + (c) are far below
`RT_STACK_RESERVE_BYTES` (8 MiB), which is the margin for per-target frame differences and libc
stack use. So the guard page can only be reached by a defect, never by a BASIC program (the
call budget prevents it); such a defect ends the program with SIGBUS on macOS and SIGSEGV on
Linux, not with a BASIC error message. `TOO MANY CALLS` (1024 activations or the budget, whichever comes first) is decided by the
program text alone.

**GOSUB base.** `_bsk_gosub_push` is unchanged (1024 pending GOSUBs over all activations, error
39); `_bsk_gosub_pop` raises error 33 when the depth equals the base, so RETURN never pops a
GOSUB of another activation (§7.9, §7.27). Without SUB units the base stays 0 and both behave
as before.

**String storage** (amends §6.7 "String storage … never freed"): buffers owned by SD records of
an activation block are freed at `_bsk_sub_leave`; references to them cannot survive the
activation (a by-reference argument names a variable of a *calling* activation, which lives
longer). Every other buffer is still never freed.

### 6.10 Baysick extension entry points and standard error (both targets)

arm64 names; x86_64 drops the underscore and maps registers as in §6.4.2 (`bsk_linput`,
`bsk_linput_el`, `bsk_exit`). Files: `src/runtime/rt_ext.s` (arm64),
`src/runtime_x86_64_linux/rt_ext.s` (x86_64), plus the changes listed in §2. Everything here is
unconditional (§2.2). LANGUAGE.md §15 is normative; this section fixes how.

| Function | In | Out | Semantics (LANGUAGE.md) |
|----------|----|-----|-------------------------|
| `_bsk_linput` | x0 SD | — | §15.2. An input entry point: it reads the pending selection and resets it to none on entry (§6.8). **None:** the standard-input reader with the INPUT dialogue's line request of §6.7 (prompt on a terminal, `col = out = 0` after the line; none → error 43 END OF INPUT, exit 0). **k = −1** → error 49. **k = 0 or k ≥ 1:** the INPUT # line request of §6.8 on the selected reader (k ≥ 1: read mode else error 50, open if needed, error 48; k = 0 on a terminal: stdout flushed before the read, `col = out = 0` after; none → error 51 END OF FILE). Over-long line → error 46. Then the **whole** line (the line buffer's bytes after the CR removal, no field scan) is stored into the SD with `_bsk_str_set` semantics (error 47), and the reader has no current line left (the next line request reads the following line, exactly as after `_bsk_input_end`). The line read is always the reader's next unread line: if the reader holds a partly scanned current line (an INPUT or INPUT # in progress called a function from a target subscript), its rest is discarded first; the enclosing `_bsk_input_num` / `_bsk_input_str` / `_bsk_input_str_el` then finds no field left and proceeds exactly as for an exhausted line (INPUT: `NOT ENOUGH INPUT` and a new line; INPUT #: the next line silently) |
| `_bsk_linput_el` | x0 slist, d0 i | — | the element form: the line is read exactly as by `_bsk_linput` (every error of that first), then element i is addressed by `_bsk_saref1` (error 32 at the store), then the line is stored into it |
| `_bsk_exit` | d0 x | noreturn | §15.4: k = trunc(x) (`frintz` / libm `trunc`), compared as a double: k < 0 or k > `LIM_EXIT_STATUS` → `_bsk_err(ERR_EXIT_RANGE)`; else exactly the `_bsk_end` sequence (§6.2: files finished, a failure → `_bsk_err(ERR_CANT_WRITE_FILE)`; stdout's pending newline and flush; standard error's pending newline) and `exit(k)`, or `exit(1)` if a stdout write failed at any time, the termination flush included (`_bsk_rt_broken` read after that flush). `_bsk_end` is `_bsk_exit` with status 0 (one shared termination routine taking the status as an integer) |

**Changed entry points.**

* `_bsk_fsel`: `k = trunc(x)` compared as a double: `FILE_NUM_STDERR` (−1) ≤ k ≤
  `_bsk_files_count`, else error 49; the pending selection := k. `_bsk_feof`, `_bsk_scratch` and
  `_bsk_frestore` keep their own check, 0 ≤ k (−1 → error 49, LANGUAGE.md §15.3).
* The print entry points (`_bsk_print_num _bsk_print_str _bsk_print_sv _bsk_print_comma
  _bsk_print_semi _bsk_print_tab _bsk_print_nl`) with the pending selection −1 run the
  §8 column logic on the **standard-error output record** — a runtime-private output record like
  a file's (§6.8: `col`, `out`, a buffer of `RT_OUTBUF_SIZE` bytes and its fill count), `col =
  out = 0` at startup — and before returning, **if** the call put at least one byte into that buffer, first flush
  stdout's buffer (as at termination; a failure sets `_bsk_rt_broken` as always) and then write
  every byte of the stderr buffer to fd 2 (`write(2, …)`, `EINTR` retried, partial writes continued; any other failure or a write of
  0 bytes drops the rest of the bytes and is otherwise ignored: no flag, no error, no status
  change). A full buffer is written as soon as it fills, like a file's (stdout
  flushed before its first byte goes to fd 2), so a string item of up to
  65 536 bytes needs no larger buffer; the record never holds a byte between two entry-point
  calls. No mode check: standard error is always writable. The column code is the one routine of
  §6.8 parameterised by the output record, so the rules cannot drift apart. A call that writes no byte (a `,` or TAB that only
  moves `col`, lazy blanks) touches neither fd 1 nor fd 2.
* The input entry points (`_bsk_input_begin _bsk_input_num _bsk_input_str _bsk_input_str_el
  _bsk_input_end`) with the pending selection −1 → error 49 (on entry, after resetting the
  selection), as do `_bsk_linput` and `_bsk_linput_el`.
* **Standard error's pending line.** Wherever the runtime writes a BASIC message to fd 2 — the
  three INPUT diagnostics and MAT INPUT's RETYPE diagnostic (§7.14.8, after flushing stdout) and
  `_bsk_err`'s message — it first writes a LF
  to fd 2 if the standard-error record's `col ≠ 0`, and sets its `col = out = 0`. `_bsk_end` and
  `_bsk_exit` do the same after stdout's flush (LANGUAGE.md §15.5 step 3). The LF is written
  with the same ignore-failures rule.
* `_bsk_err` accepts `ERR_EXT_FIRST_RUNTIME` … `ERR_EXT_END_RUNTIME` − 1 (62) besides 32 … 56:
  message from `BSK_EMIT_ERRMSG_TABLE`, exit 1 (the error range check of §6.2).

**SIGPIPE.** Neither runtime installs a signal handler or changes the `SIGPIPE` action it
inherits (as today for stdout; LANGUAGE.md §10, §15.3): with the default action a write to a pipe
without a reader, on fd 1 or fd 2, ends the process by the signal; with `SIGPIPE` ignored by the
parent, `write` returns `EPIPE`, which on fd 2 is ignored like every other failure and on fd 1 sets
`_bsk_rt_broken`. R and RX add no code for it.

**Termination order** (both runtimes, every path: `_bsk_end`, `_bsk_exit`, `_bsk_err`): files
(§6.8 finishing, once) → stdout's pending newline and flush → standard error's pending newline →
the message (`_bsk_err` only) → `exit`. This is LANGUAGE.md §15.5.

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
* Test sidecar formats are documented at the top of `tests/run.sh`. A program or run-phase
  error test may have a `NAME.in` file: its bytes are the program's standard input (INPUT, MAT
  INPUT); without it stdin is `/dev/null`, exactly as before. Fifth Edition: every such case
  runs in a fresh empty working directory, and the optional `NAME.files/` (fixtures) and
  `NAME.expect/` (expected files) directories are handled as in §8.5. Baysick extensions: a run-phase
  error case's `.meta` may select a stream mode (`streams=merged`, `streams=no-stdout`, §8.6).

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
<bundle>/cases/programs/NAME.s NAME.out [NAME.err] [NAME.in]            from tests/programs/NAME.*
<bundle>/cases/errors/NAME.s NAME.meta NAME.err [NAME.out] [NAME.in]    run-phase tests/errors/NAME.*
<bundle>/cases/<kind>/NAME.files/ NAME.expect/  copies of the §8.5 directories, when present
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
  `.s` is removed and `NAME.packfail` written. Sidecars (`.out`, `.err`, `.meta` and the
  optional `.in`) are copied unchanged. A `tests/errors`
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
  stdin from `NAME.in` if it exists, else `/dev/null`, and the timeout, and compare exactly like
  `tests/run.sh`: programs: exit 0,
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

### 8.5 File tests (Fifth Edition; implementer T)

Programs that use files (LANGUAGE.md §7.21–§7.26) need a known working directory, input files
that exist before the run, and a check of the files the run leaves behind. Two optional sidecar
**directories** do this, next to the `NAME.bas` of a `tests/programs` case or a run-phase
`tests/errors` case:

* `NAME.files/` — **fixtures**: its contents (files and subdirectories, recursively) are copied
  into the run's working directory before the program starts.
* `NAME.expect/` — **expected files**: after the run, every regular file under it must exist at
  the same relative path in the working directory with byte-identical contents.

**Every** program and run-phase case — with or without these directories — runs with its working
directory set to a **fresh, empty directory** made for that case (`mktemp -d` below the runner's
own temp directory), into which `NAME.files/` (if present) is copied with `cp -R NAME.files/.
WORKDIR/`. The compiled program is not in that directory (it is invoked by absolute path) and
neither are its standard input, output and error capture files; so the working directory holds
exactly the fixtures and whatever the program creates. The directory is removed after the case.

**Checks, in this order, after the existing exit-status / stdout / stderr checks** (each failure
is one `FAIL <name>: <reason>` line, and the first failing check ends the case, as today):

1. For each regular file `R` under `NAME.expect/` (relative path): `WORKDIR/R` missing →
   `FAIL <name>: missing file R`; contents differ (`cmp -s`) → `FAIL <name>: file R differs`
   (with `-v`: `diff` of the two, as for stdout).
2. Every regular file `R` in `WORKDIR` (recursively) must be either listed in `NAME.expect/` or
   be a fixture from `NAME.files/` with unchanged contents; else
   `FAIL <name>: unexpected file R` (created by the program and not expected) or
   `FAIL <name>: fixture R changed` (a fixture overwritten but not listed in `NAME.expect/`).
   So a program that writes a file the test does not expect fails, and a test that expects a
   fixture to be rewritten says so by listing it in `NAME.expect/`.

Directories themselves are not compared: both checks consider regular files only (`find
WORKDIR -type f`), so an empty directory or a symbolic link that a program leaves behind is
ignored. A fixture or expected-file name is
ASCII without blanks, `*`, `?`, `[`, newline or a leading `-`, and two names never differ only in
letter case (the corpus must behave identically on macOS's case-insensitive default file system
and on Linux). A case without the two directories gets checks 1–2 for free: its working
directory must be empty after the run, so a program writing a stray file fails.

**Where each script does it:**

* `tests/run.sh` (Mac): as above; the compiled executable stays in the runner's temp directory,
  the program runs as `(cd "$WORKDIR" && exec "$EXE" <"$IN" >"$OUT" 2>"$ERR")` under the
  existing timeout — the `exec` makes the subshell *become* the program, so the timeout's kill
  reaches the program itself and not only a waiting shell. Compile-phase `tests/errors` cases and `tests/ir` cases are unaffected (the compiler
  never runs in the work directory; the driver's own temp files are elsewhere).
* `tests/cross_pack.sh`: copies `NAME.files/` and `NAME.expect/` (when present) unchanged to
  `cases/<kind>/NAME.files/` and `cases/<kind>/NAME.expect/` with `cp -R` (§8.3 bundle layout).
* `tests/cross_run.sh` (Linux): the same per-case work directory, copy and checks as `run.sh`;
  only POSIX `sh`, `find`, `cmp`, `cp -R`, `mktemp -d` and `diff` (for `-v`) are used, so it
  runs on the CI image and on `desktop` alike.
* CI (§8.4): no change in its steps — the bundle carries the directories; `run.sh` on macOS and
  `cross_run.sh` on Linux apply the checks.
* `.gitattributes`: `tests/**/*.files/** -text` and `tests/**/*.expect/** -text`, so fixture and
  expected-file bytes (CR, missing final LF) are never normalised.

**Misplaced directories are a harness error.** A compile-phase `tests/errors` case or a
`tests/ir` case that has `NAME.files/` or `NAME.expect/` is a corpus mistake (those tests never
run a program): `run.sh` and `cross_pack.sh` report `<script>: NAME: .files/.expect only for
program and run-phase tests` on stderr and exit 2 (setup error) before running anything. NAME
is written with its directory, `errors/NAME` or `ir/NAME`. This pre-scan covers the whole corpus
and ignores PATTERN: a misplaced directory fails every run, filtered or not.

The checks never look outside `WORKDIR`; a test must not use absolute paths that escape it
(`FILES /tmp/x` is tested only through its error behaviour, never by writing). Error tests
whose program fails to open a file (`CAN'T OPEN FILE`) use a name that does not exist in the work
directory or a fixture directory as the path (a fixture subdirectory is created by copying a
`NAME.files/DIR/` that contains a file, since git does not store empty directories).

### 8.6 Stream modes of run-phase tests (Baysick extensions; implementer T)

The harness compares a run-phase case's standard output and standard error as two separate
captures, so it cannot see their relative order, and it cannot make a write fail. The Baysick
extensions specify both (LANGUAGE.md §15.3: standard output is written before every
standard-error write; §15.4: a failed write forces exit status 1 whatever `END e` / `STOP e`
chose). An optional third line of a run-phase `tests/errors/NAME.meta` selects how the program's
output streams are connected:

```
phase=run
exit=<status>
streams=merged | no-stdout
```

* No `streams=` line (every existing case): unchanged — `>"$OUT" 2>"$ERR"`.
* `streams=merged`: the program runs with standard error on the same open file as standard
  output, `>"$OUT" 2>&1` (one file description, so the bytes land in write order). `NAME.out` (absent
  = empty) is compared with that file. The separate stderr capture `$TMP/r.err` is reused across
  cases by both scripts, so the harness truncates it (`: >"$TMP/r.err"`) before a merged run; it
  then stays empty, and the required `NAME.err` must be empty (a non-empty one fails as "stderr
  differs").
* `streams=no-stdout`: the program runs with standard output **closed**, `>&-` (stderr captured as
  usual); every write to fd 1 fails with `EBADF`, deterministically on both hosts. The harness
  truncates the stdout capture before the run (`: >"$TMP/r.out"`), so it stays empty, and
  `NAME.out` must be absent (or empty). A case with
  this mode must not open files (no `FILES` used), because a file opened while fd 1 is closed
  would receive descriptor 1.
* Any other value → `FAIL NAME: bad streams '<value>' in NAME.meta`. A `streams=` line in a
  compile-phase case is ignored (it never runs a program), as are `streams=` lines in
  `tests/programs` (they have no `.meta`).

**Where:** `tests/run.sh` and `tests/cross_run.sh` read the key with their `meta_get` and choose
the redirection in their run-phase branch (the `run_limited` call is unchanged; only the
caller's redirections differ; before the run the harness truncates the capture that the mode
leaves unwritten — `r.err` for `merged`, `r.out` for `no-stdout` — so the existing comparisons
apply). `tests/cross_pack.sh` already copies `NAME.meta`
unchanged; CI needs nothing. The header comment of `tests/run.sh` documents the key with the
other sidecar formats.
