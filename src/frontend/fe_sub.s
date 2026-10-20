// =====================================================================
// src/frontend/fe_sub.s -- Sixth Edition subprograms: SUB, SUBEND, CALL
// (LANGUAGE.md 7.27, 10.1; IR.md 2.2, 3.4, 4.1, 4.3, 4.4).
//
//   _fe_unit_init()                    unit table, line->unit map, main save area
//   _fe_unit_new(w0=SUB line index) -> w0 = 1 + u   a new SUB block (pre-scan)
//   _fe_unit_switch(w0=0 main / 1+u)   make that program unit's state current
//   _fe_unit_rec(w0=1+u) -> x0         its unit record
//   _fe_sub(), _fe_subend(), _fe_callstmt()          statement handlers
//   _fe_sub_check_fns()                phase-3 FN checks over every unit
//   _fe_sub_check_calls()              UNDEFINED SUBPROGRAM, argument counts
//                                      and kinds (phase 3)
//   _fe_sub_publish_all()              arrays, string arrays, parameter
//                                      arrays and FOR counts of every unit
//
// Program units. The pre-scan (_fe_prescan, fe_def.s) partitions the lines
// into the main program and the SUB blocks (unit u = the u-th SUB block in
// ascending line order); _fe_lineunit[i] is 0 for a main-program line and
// 1 + u for a line of block u. Every program unit owns a copy of the
// per-unit frontend state (Lfe_sub_state_tab: arrays, string arrays, FN
// functions with their records and call log, multi-line functions, FOR
// count, MAT name masks, its Module (_fe_unit) and body Function
// (_fe_main), the depth of the FOR stack at its start). Exactly one copy
// is live in the state variables at a time; _fe_unit_switch saves it into
// the current unit's save area and loads another one. The program-wide
// state (strings, DATA, files, line labels' owners, the FOR stack, the
// error records) is never swapped.
//
// Unit record (FE_U_SIZE bytes, _fe_units[u]):
//   +0  ptr save area (FE_USTATE_SIZE bytes)   +8  ptr Module* (pre-scan)
//   +16 ptr name bytes (the pre-scan's reading)  +24 u32 name length
//   +28 u32 SUB line index   +32 u32 last line index of the block
//   +36 u32 flags (FE_UF_SUBEND: closed by its SUBEND line)
//   +40 u32 parameter count (set when the SUB line is compiled)
//   +44 u32 SUB line number  +48 u8[16] SUBP_* kind per parameter
// CALL log entry (FE_CL_SIZE bytes, _fe_sublog[n], ascending lines):
//   +0 u32 line, +4 u32 argument count, +8 ptr name, +16 u32 name length,
//   +24 u8[16] SUBP_* kind per argument.
// =====================================================================
.include "baysick.inc"


.equ FE_PEEK_EOL,       0x100       // _fe_peek result beyond the line end
.equ FE_LINE_ENTRY,     16          // see fe_compile.s
.equ FE_ARR_ENTRY,      16          // see fe_compile.s
.equ FE_ARGC_SLOTS,     10          // see fe_compile.s
.equ FE_CTX_ML,         2           // _fe_ctx_kind of a multi-line body (fe_def.s)
.equ FE_KW_SUB_LEN,     3           // length of the keyword "SUB"

// unit record
.equ FE_U_SAVE,         0
.equ FE_U_MODULE,       8
.equ FE_U_NAME,         16
.equ FE_U_NAMELEN,      24
.equ FE_U_SUBIDX,       28
.equ FE_U_ENDIDX,       32
.equ FE_U_FLAGS,        36
.equ FE_U_NPARAMS,      40
.equ FE_U_SUBLINE,      44
.equ FE_U_KINDS,        48
.equ FE_U_SIZE,         64
.equ FE_U_SHIFT,        6           // log2(FE_U_SIZE)
.equ FE_UF_SUBEND,      1

// CALL log entry
.equ FE_CL_LINE,        0
.equ FE_CL_NARGS,       4
.equ FE_CL_NAME,        8
.equ FE_CL_NAMELEN,     16
.equ FE_CL_KINDS,       24
.equ FE_CL_SIZE,        40
.equ FE_CL_INITIAL,     64          // first capacity of the CALL log

// FE_NONE: set the optional _fe_emit / _fe_emit_new operands to "unused".
.macro FE_NONE
    mov w1, #IR_NONE
    mov w2, #IR_NONE
    mov w3, #IR_NONE
    mov w4, #IR_NONE
    mov x5, #0
    mov w6, #REL_NONE
.endm

// FE_ADR reg, sym: reg = address of sym
.macro FE_ADR reg, sym
    adrp \reg, \sym@PAGE
    add \reg, \reg, \sym@PAGEOFF
.endm

// ---------------------------------------------------------------------
// Per-unit state: (address, size) pairs; FE_USTATE_SIZE is their sum.
// ---------------------------------------------------------------------
.set FE_USTATE_SIZE, 0
.macro FE_SW sym, size
    .quad \sym, \size
    .set FE_USTATE_SIZE, FE_USTATE_SIZE + (\size)
.endm
    .section __DATA,__const
    .p2align 3
Lfe_sub_state_tab:
    FE_SW _fe_unit, 8
    FE_SW _fe_main, 8
    FE_SW _fe_unitforbase, 8
    FE_SW _fe_arrays, NUM_LETTERS * FE_ARR_ENTRY
    FE_SW _fe_sarrays, NUM_LETTERS * FE_ARR_ENTRY
    FE_SW _fe_fn_defline, NUM_LETTERS * 4
    FE_SW _fe_fn_ref, NUM_LETTERS * 4
    FE_SW _fe_fn_calls, NUM_LETTERS * 4
    FE_SW _fe_fn_nparams, NUM_LETTERS * 4
    FE_SW _fe_fn_argline, NUM_LETTERS * FE_ARGC_SLOTS * 4
    FE_SW _fe_fn_kinds, NUM_LETTERS * 4
    FE_SW _fe_ml_fn, NUM_LETTERS * 8
    FE_SW _fe_ml_defline, NUM_LETTERS * 4
    FE_SW _fe_ml_defidx, NUM_LETTERS * 4
    FE_SW _fe_ml_endidx, NUM_LETTERS * 4
    FE_SW _fe_ml_nparams, NUM_LETTERS * 4
    FE_SW _fe_ml_params, NUM_LETTERS * LIM_FN_PARAMS * 4
    FE_SW _fe_ml_order, NUM_LETTERS * 4
    FE_SW _fe_ml_kinds, NUM_LETTERS * 4
    FE_SW _fe_ml_count, 8
    FE_SW _fe_ml_open, 8
    FE_SW _fe_pre_seen, 8
    FE_SW _fe_nfors, 8
    FE_SW _fe_mat_names, 8
    FE_SW _fe_smat_names, 8
    FE_SW _fe_calllog, 8
    FE_SW _fe_ncalls, 8
    FE_SW _fe_capcalls, 8
Lfe_sub_state_tab_end:

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _fe_unit_init -- allocate the unit table (room for one unit per line),
//   the line -> unit map and the main program's save area; the main
//   program is the current unit.
//   in:  _fe_nlines   out: _fe_units, _fe_lineunit, _fe_mainsave set
//   clobbers: x0-x17
//   callee-saved: x19 = line count
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .globl _fe_unit_init
    .p2align 2
_fe_unit_init:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    adrp x9, _fe_nlines@PAGE
    ldr w19, [x9, _fe_nlines@PAGEOFF]
    // unit records (never a zero-size request)
    lsl x0, x19, #FE_U_SHIFT
    add x0, x0, #FE_U_SIZE
    bl _drv_alloc
    adrp x9, _fe_units@PAGE
    str x0, [x9, _fe_units@PAGEOFF]
    // one u32 unit number per line
    lsl x0, x19, #2
    add x0, x0, #16
    bl _drv_alloc
    adrp x9, _fe_lineunit@PAGE
    str x0, [x9, _fe_lineunit@PAGEOFF]
    // the main program's save area
    mov x0, #FE_USTATE_SIZE
    bl _drv_alloc
    adrp x9, _fe_mainsave@PAGE
    str x0, [x9, _fe_mainsave@PAGEOFF]
    adrp x9, _fe_nunits@PAGE
    str wzr, [x9, _fe_nunits@PAGEOFF]
    adrp x9, _fe_curunit@PAGE
    str wzr, [x9, _fe_curunit@PAGEOFF]
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _fe_unit_rec -- the record of unit 1 + u.
//   in:  w0 = 1 + u   out: x0 = &_fe_units[u]
//   clobbers: x0, x9   leaf, no frame
// ---------------------------------------------------------------------
    .globl _fe_unit_rec
    .p2align 2
_fe_unit_rec:
    adrp x9, _fe_units@PAGE
    ldr x9, [x9, _fe_units@PAGEOFF]
    sub w0, w0, #1
    add x0, x9, x0, lsl #FE_U_SHIFT
    ret

// ---------------------------------------------------------------------
// _fe_unit_subline -- the SUB line number of unit 1 + u.
//   in:  w0 = 1 + u   out: w0 = its SUB line number
//   clobbers: x0, x9   leaf, no frame
// ---------------------------------------------------------------------
    .globl _fe_unit_subline
    .p2align 2
_fe_unit_subline:
    adrp x9, _fe_units@PAGE
    ldr x9, [x9, _fe_units@PAGEOFF]
    sub w0, w0, #1
    add x9, x9, x0, lsl #FE_U_SHIFT
    ldr w0, [x9, #FE_U_SUBLINE]
    ret

// ---------------------------------------------------------------------
// _fe_unit_new -- record a new SUB block starting at line index i (pre-
//   scan): a zeroed save area (a unit starts with no arrays, functions or
//   FOR loops), the SUB line, and its name as the pre-scan reads it (the
//   bytes after `SUB"` up to the next '"' or the end of the line; empty
//   when no '"' follows the keyword -- such a SUB line is reported in
//   phase 2, so this reading never reaches a successful compilation
//   unless it is the name itself).
//   in:  w0 = line index i
//   out: w0 = 1 + u (the new unit's number)
//   clobbers: x0-x17
//   callee-saved: w19 = line index, x20 = record, x21 = text cursor,
//        x22 = text end
//   frame: 48 bytes
// ---------------------------------------------------------------------
    .globl _fe_unit_new
    .p2align 2
_fe_unit_new:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov w19, w0
    // record u = _fe_nunits
    adrp x9, _fe_nunits@PAGE
    ldr w10, [x9, _fe_nunits@PAGEOFF]
    adrp x11, _fe_units@PAGE
    ldr x11, [x11, _fe_units@PAGEOFF]
    add x20, x11, x10, lsl #FE_U_SHIFT
    // a zeroed save area
    mov x0, #FE_USTATE_SIZE
    bl _drv_alloc
    str x0, [x20, #FE_U_SAVE]
    mov x1, #FE_USTATE_SIZE
    bl _bzero
    str xzr, [x20, #FE_U_MODULE]
    str w19, [x20, #FE_U_SUBIDX]
    str w19, [x20, #FE_U_ENDIDX]
    str wzr, [x20, #FE_U_FLAGS]
    str wzr, [x20, #FE_U_NPARAMS]
    stp xzr, xzr, [x20, #FE_U_KINDS]
    // the SUB line number and the name after the keyword
    adrp x9, _fe_lines@PAGE
    ldr x9, [x9, _fe_lines@PAGEOFF]
    add x9, x9, x19, lsl #4             // &lines[i]
    ldr w10, [x9]
    str w10, [x20, #FE_U_SUBLINE]
    ldr w11, [x9, #4]                   // text length
    ldr x12, [x9, #8]                   // text
    add x22, x12, x11                   // text end
    add x21, x12, #FE_KW_SUB_LEN        // after "SUB"
    str x21, [x20, #FE_U_NAME]
    str wzr, [x20, #FE_U_NAMELEN]
    cmp x21, x22
    b.hs 3f
    ldrb w9, [x21]
    cmp w9, #'"'
    b.ne 3f
    add x21, x21, #1                    // the name's first byte
    str x21, [x20, #FE_U_NAME]
    mov x10, x21
1:
    cmp x10, x22
    b.hs 2f
    ldrb w9, [x10]
    cmp w9, #'"'
    b.eq 2f
    add x10, x10, #1
    b 1b
2:
    sub x10, x10, x21
    str w10, [x20, #FE_U_NAMELEN]
3:
    adrp x9, _fe_nunits@PAGE
    ldr w10, [x9, _fe_nunits@PAGEOFF]
    add w10, w10, #1
    str w10, [x9, _fe_nunits@PAGEOFF]
    mov w0, w10                         // 1 + u
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// _fe_unit_close -- the current SUB block ends at line index i (pre-scan):
//   at its SUBEND line, or -- in an erroneous program -- at an END line
//   or the last line. The main program becomes the current unit again.
//   in:  w0 = line index i, w1 = 1 if line i is the block's SUBEND line
//   out: none
//   clobbers: x0-x17
//   callee-saved: w19 = line index, w20 = SUBEND flag
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .globl _fe_unit_close
    .p2align 2
_fe_unit_close:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov w19, w0
    mov w20, w1
    adrp x9, _fe_curunit@PAGE
    ldr w0, [x9, _fe_curunit@PAGEOFF]
    bl _fe_unit_rec
    str w19, [x0, #FE_U_ENDIDX]
    str w20, [x0, #FE_U_FLAGS]          // FE_UF_SUBEND or 0
    mov w0, #0
    bl _fe_unit_switch
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _fe_unit_eof -- the current SUB block is still open after the last
//   line: its SUB line is remembered for phase 3 (UNFINISHED SUB,
//   _fe_eof_sub_line) and the block ends at the last line.
//   in:  w0 = index of the last line
//   out: none (the main program is current)
//   clobbers: x0-x17
//   callee-saved: w19 = line index
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .globl _fe_unit_eof
    .p2align 2
_fe_unit_eof:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov w19, w0
    adrp x9, _fe_curunit@PAGE
    ldr w0, [x9, _fe_curunit@PAGEOFF]
    bl _fe_unit_rec
    ldr w9, [x0, #FE_U_SUBLINE]
    adrp x10, _fe_eof_sub_line@PAGE
    str w9, [x10, _fe_eof_sub_line@PAGEOFF]
    mov w0, w19
    mov w1, #0
    bl _fe_unit_close
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _fe_sub_create_units -- the last step of the pre-scan (IR.md 4.1):
//   each SUB unit, in ascending order of its SUB line, is created
//   (_ir_new_sub on the main module), its SUB body begins
//   (_ir_func_begin(unit, 0, IR_NONE, SUB line), _ir_func_set(fn,
//   FUNC_KIND_SUB, 0, 0, SUBEND line or 0 when the block has none) and
//   gets the line labels of the block's lines outside its multi-line DEF
//   bodies (the SUB line first), then the unit's multi-line functions are
//   created (_fe_prescan_mlfuncs, fe_def.s).
//   in:  pre-scan results (_fe_units, _fe_lineunit, _fe_linefn)
//   out: every unit's Module and body Function recorded (_fe_unit,
//        _fe_main of its state; the record's Module*); the main program's
//        state is current again
//   clobbers: x0-x17
//   callee-saved: w19 = unit (1 + u), w20 = unit count, x21 = record,
//        x22 = body Function*, w23 = line index, w24 = last line index
//   frame: 64 bytes
// ---------------------------------------------------------------------
    .globl _fe_sub_create_units
    .p2align 2
_fe_sub_create_units:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    adrp x9, _fe_nunits@PAGE
    ldr w20, [x9, _fe_nunits@PAGEOFF]
    mov w19, #1
Lfe_sub_create_loop:
    cmp w19, w20
    b.hi Lfe_sub_create_done
    mov w0, w19
    bl _fe_unit_switch
    mov w0, w19
    bl _fe_unit_rec
    mov x21, x0
    // _ir_new_sub(main, name, length, SUB line)
    adrp x9, _fe_module@PAGE
    ldr x0, [x9, _fe_module@PAGEOFF]
    ldr x1, [x21, #FE_U_NAME]
    ldr w2, [x21, #FE_U_NAMELEN]
    ldr w3, [x21, #FE_U_SUBLINE]
    bl _ir_new_sub
    str x0, [x21, #FE_U_MODULE]
    adrp x9, _fe_unit@PAGE
    str x0, [x9, _fe_unit@PAGEOFF]
    // the SUB body: function 0 of the unit
    mov w1, #FUNC_MAIN
    mov w2, #IR_NONE
    ldr w3, [x21, #FE_U_SUBLINE]
    bl _ir_func_begin
    mov x22, x0
    adrp x9, _fe_main@PAGE
    str x22, [x9, _fe_main@PAGEOFF]
    // its SUBEND line (0 if the block was not closed by one)
    mov w4, #0
    ldr w9, [x21, #FE_U_FLAGS]
    tbz w9, #0, 1f                      // FE_UF_SUBEND
    ldr w9, [x21, #FE_U_ENDIDX]
    adrp x10, _fe_lines@PAGE
    ldr x10, [x10, _fe_lines@PAGEOFF]
    add x10, x10, x9, lsl #4
    ldr w4, [x10]
1:
    mov x0, x22
    mov w1, #FUNC_KIND_SUB
    mov w2, #0
    mov x3, #0
    bl _ir_func_set
    // line labels of the block's body lines, ascending
    ldr w23, [x21, #FE_U_SUBIDX]
    ldr w24, [x21, #FE_U_ENDIDX]
2:
    cmp w23, w24
    b.hi 3f
    adrp x9, _fe_lineunit@PAGE
    ldr x9, [x9, _fe_lineunit@PAGEOFF]
    ldr w10, [x9, x23, lsl #2]
    cmp w10, w19
    b.ne 4f                             // (never: a block is contiguous)
    adrp x9, _fe_linefn@PAGE
    ldr x9, [x9, _fe_linefn@PAGEOFF]
    ldr w10, [x9, x23, lsl #2]
    cbnz w10, 4f                        // a line of a multi-line DEF body
    adrp x9, _fe_lines@PAGE
    ldr x9, [x9, _fe_lines@PAGEOFF]
    add x9, x9, x23, lsl #4
    ldr w1, [x9]                        // its BASIC line number
    mov x0, x22
    bl _ir_new_label
    adrp x9, _fe_linelab@PAGE
    ldr x9, [x9, _fe_linelab@PAGEOFF]
    str w0, [x9, x23, lsl #2]
4:
    add w23, w23, #1
    b 2b
3:
    // the unit's multi-line functions, in DEF line order
    bl _fe_prescan_mlfuncs
    add w19, w19, #1
    b Lfe_sub_create_loop
Lfe_sub_create_done:
    mov w0, #0
    bl _fe_unit_switch
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

// ---------------------------------------------------------------------
// _fe_unit_switch -- make program unit `target` current: the live state
//   is copied into the current unit's save area, the target's is copied
//   into the state variables (Lfe_sub_state_tab order).
//   in:  w0 = 0 (main program) or 1 + u
//   out: none (_fe_curunit = target)
//   clobbers: x0-x17
//   callee-saved: w19 = target, x20 = table cursor, x21 = area cursor,
//        x22 = table end
//   frame: 48 bytes
// ---------------------------------------------------------------------
    .globl _fe_unit_switch
    .p2align 2
_fe_unit_switch:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov w19, w0
    adrp x9, _fe_curunit@PAGE
    ldr w0, [x9, _fe_curunit@PAGEOFF]
    cmp w0, w19
    b.eq Lfe_unit_switch_ret            // already current
    // save: state variables -> current area
    bl Lfe_unit_area
    mov x21, x0
    FE_ADR x20, Lfe_sub_state_tab
    FE_ADR x22, Lfe_sub_state_tab_end
1:
    cmp x20, x22
    b.hs 2f
    ldp x1, x2, [x20], #16              // address, size
    mov x0, x21
    add x21, x21, x2
    bl _memcpy
    b 1b
2:
    // load: target area -> state variables
    mov w0, w19
    bl Lfe_unit_area
    mov x21, x0
    FE_ADR x20, Lfe_sub_state_tab
3:
    cmp x20, x22
    b.hs 4f
    ldp x0, x2, [x20], #16              // address, size
    mov x1, x21
    add x21, x21, x2
    bl _memcpy
    b 3b
4:
    adrp x9, _fe_curunit@PAGE
    str w19, [x9, _fe_curunit@PAGEOFF]
Lfe_unit_switch_ret:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// Lfe_unit_area -- the save area of unit `n` (0: the main program).
//   in:  w0 = 0 or 1 + u   out: x0 = save area
//   clobbers: x0, x9   leaf, no frame
// ---------------------------------------------------------------------
    .p2align 2
Lfe_unit_area:
    cbnz w0, 1f
    adrp x9, _fe_mainsave@PAGE
    ldr x0, [x9, _fe_mainsave@PAGEOFF]
    ret
1:
    adrp x9, _fe_units@PAGE
    ldr x9, [x9, _fe_units@PAGEOFF]
    sub w0, w0, #1
    add x9, x9, x0, lsl #FE_U_SHIFT
    ldr x0, [x9, #FE_U_SAVE]
    ret

// ---------------------------------------------------------------------
// Lfe_sub_name -- a subprogram name after SUB or CALL: '"', at least one
//   byte other than '"', '"' (LANGUAGE.md 7.27); anything else (no quote,
//   an unterminated or empty name) -> INCORRECT FORMAT. The quotes are
//   consumed.
//   in:  scanner after the keyword
//   out: x0 = the name's first byte, w1 = its length (>= 1)
//   clobbers: x0-x17
//   callee-saved: x19 = name start, x20 = cursor
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_sub_name:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov w0, #0
    bl _fe_peek
    cmp w0, #'"'
    b.ne Lfe_sub_name_bad
    bl _fe_getpos
    add x19, x0, #1                     // first byte of the name
    adrp x9, _fe_end@PAGE
    ldr x10, [x9, _fe_end@PAGEOFF]
    mov x20, x19
1:
    cmp x20, x10
    b.hs Lfe_sub_name_bad               // unterminated
    ldrb w9, [x20]
    cmp w9, #'"'
    b.eq 2f
    add x20, x20, #1
    b 1b
2:
    cmp x20, x19
    b.eq Lfe_sub_name_bad               // the empty name ""
    add x0, x20, #1                     // after the closing quote
    bl _fe_setpos
    mov x0, x19
    sub x1, x20, x19
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
Lfe_sub_name_bad:
    mov w0, #ERR_INCORRECT_FORMAT
    bl _fe_err

// ---------------------------------------------------------------------
// Lfe_sub_lookup -- the SUB block whose (pre-scan) name equals the given
//   bytes, compared exactly; the first such block.
//   in:  x0 = name bytes, w1 = length, w2 = number of units to search
//        (the first w2 units)
//   out: w0 = unit index u, or -1 if none
//   clobbers: x0-x17
//   callee-saved: x19 = name, w20 = length, w21 = units to search,
//        w22 = u, x23 = record
//   frame: 64 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_sub_lookup:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]
    mov x19, x0
    mov w20, w1
    mov w21, w2
    mov w22, #0
1:
    cmp w22, w21
    b.hs 3f
    adrp x9, _fe_units@PAGE
    ldr x9, [x9, _fe_units@PAGEOFF]
    add x23, x9, x22, lsl #FE_U_SHIFT
    ldr w9, [x23, #FE_U_NAMELEN]
    cmp w9, w20
    b.ne 2f
    // same length: compare the bytes
    ldr x0, [x23, #FE_U_NAME]
    mov x1, x19
    mov x2, x20
    bl _memcmp
    cbz w0, 4f
2:
    add w22, w22, #1
    b 1b
3:
    mov w22, #-1
4:
    mov w0, w22
    ldr x23, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

// ---------------------------------------------------------------------
// _fe_sub -- the SUB statement (LANGUAGE.md 7.27):
//     SUB name [ ":" parameter { "," parameter } ]
//   A SUB line inside a multi-line DEF body, or one that is not the first
//   line of the current block (a SUB inside a SUB block) -> NESTED SUB.
//   Then: the name (INCORRECT FORMAT), a name used by an earlier SUB ->
//   DUPLICATE SUBPROGRAM, then end of line or ':' and the parameters:
//   X, X1 (SUBP_NUM), X$, X1$ (SUBP_STR), L() (SUBP_ARR), L$() (SUBP_SARR);
//   a missing, malformed or repeated parameter -> ILLEGAL VARIABLE; a
//   seventeenth parameter -> INCORRECT FORMAT as soon as it starts;
//   anything but ',' or the end after a parameter -> INCORRECT FORMAT.
//   Lowering: nothing (IR.md 4.3); array parameters are marked
//   IRA_FLAG_PARAM in the unit's tables, and _ir_sub_set records the
//   parameters and the SUBEND line (0 if the block has none: an error
//   follows).
//   in:  scanner after "SUB"
//   out: none
//   clobbers: x0-x17
//   callee-saved: x19 = unit record, w20 = parameter count, w21 = slot /
//        letter, w22 = kind, x23 = name, w24 = name length
//   frame: 160 bytes (frame record, x19-x24, u32[16] slots at sp+64,
//        u8[16] kinds at sp+128)
// ---------------------------------------------------------------------
.equ FE_SUBF_SLOTS,     64
.equ FE_SUBF_KINDS,     128
    .globl _fe_sub
    .p2align 2
_fe_sub:
    stp x29, x30, [sp, #-160]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    // NESTED SUB: inside a DEF body, or not the line that opened the block
    adrp x9, _fe_ctx_kind@PAGE
    ldr w9, [x9, _fe_ctx_kind@PAGEOFF]
    cmp w9, #FE_CTX_ML
    b.eq Lfe_sub_nested
    adrp x9, _fe_curunit@PAGE
    ldr w0, [x9, _fe_curunit@PAGEOFF]
    cbz w0, Lfe_sub_nested              // (every other SUB line opens a block)
    bl _fe_unit_rec
    mov x19, x0
    ldr w9, [x19, #FE_U_SUBIDX]
    adrp x10, _fe_lineidx@PAGE
    ldr w10, [x10, _fe_lineidx@PAGEOFF]
    cmp w9, w10
    b.ne Lfe_sub_nested
    // the name, and no earlier SUB of that name
    bl Lfe_sub_name
    mov x23, x0
    mov w24, w1
    adrp x9, _fe_curunit@PAGE
    ldr w2, [x9, _fe_curunit@PAGEOFF]
    sub w2, w2, #1                      // the earlier blocks 0 .. u-1
    bl Lfe_sub_lookup
    tbnz w0, #31, 1f
    mov w0, #ERR_DUPLICATE_SUB
    bl _fe_err
1:
    // end of line, or ':' and the parameters
    mov w20, #0
    stp xzr, xzr, [sp, #FE_SUBF_KINDS]
    mov w0, #0
    bl _fe_peek
    cmp w0, #FE_PEEK_EOL
    b.eq Lfe_sub_done
    cmp w0, #':'
    b.ne Lfe_sub_format
    mov w0, #1
    bl _fe_advance
Lfe_sub_param:
    cmp w20, #LIM_SUB_PARAMS
    b.hs Lfe_sub_format                 // a seventeenth parameter
    bl Lfe_sub_parse_param
    mov w21, w0
    mov w22, w1
    // the same parameter twice (same kind and name)
    mov w9, #0
2:
    cmp w9, w20
    b.hs 3f
    add x10, sp, #FE_SUBF_SLOTS
    ldr w11, [x10, x9, lsl #2]
    add x10, sp, #FE_SUBF_KINDS
    ldrb w12, [x10, x9]
    cmp w11, w21
    ccmp w12, w22, #0, eq
    b.eq Lfe_sub_var
    add w9, w9, #1
    b 2b
3:
    add x10, sp, #FE_SUBF_SLOTS
    str w21, [x10, x20, lsl #2]
    add x10, sp, #FE_SUBF_KINDS
    strb w22, [x10, x20]
    add w20, w20, #1
    // ',' -> next parameter, end of line -> done
    mov w0, #0
    bl _fe_peek
    cmp w0, #FE_PEEK_EOL
    b.eq Lfe_sub_done
    cmp w0, #','
    b.ne Lfe_sub_format
    mov w0, #1
    bl _fe_advance
    b Lfe_sub_param
Lfe_sub_done:
    // record the parameters (phase-3 matching) and mark array parameters
    str w20, [x19, #FE_U_NPARAMS]
    ldp x9, x10, [sp, #FE_SUBF_KINDS]
    stp x9, x10, [x19, #FE_U_KINDS]
    mov w21, #0
4:
    cmp w21, w20
    b.hs 6f
    add x10, sp, #FE_SUBF_KINDS
    ldrb w22, [x10, x21]
    add x10, sp, #FE_SUBF_SLOTS
    ldr w11, [x10, x21, lsl #2]         // letter of an array parameter
    FE_ADR x12, _fe_arrays
    cmp w22, #SUBP_ARR
    b.eq 5f
    FE_ADR x12, _fe_sarrays
    cmp w22, #SUBP_SARR
    b.ne 7f
5:
    // an array parameter: no storage, dimensionality fixed by its uses
    add x12, x12, x11, lsl #4           // FE_ARR_ENTRY bytes per letter
    str wzr, [x12]
    str wzr, [x12, #4]
    str wzr, [x12, #8]
    mov w9, #IRA_FLAG_PARAM
    str w9, [x12, #12]
7:
    add w21, w21, #1
    b 4b
6:
    // _ir_sub_set(unit, n, slots, kinds, SUBEND line or 0)
    mov w4, #0
    ldr w9, [x19, #FE_U_FLAGS]
    tbz w9, #0, 8f                      // FE_UF_SUBEND: closed by its SUBEND
    ldr w9, [x19, #FE_U_ENDIDX]
    adrp x10, _fe_lines@PAGE
    ldr x10, [x10, _fe_lines@PAGEOFF]
    add x10, x10, x9, lsl #4
    ldr w4, [x10]
8:
    adrp x9, _fe_unit@PAGE
    ldr x0, [x9, _fe_unit@PAGEOFF]
    mov w1, w20
    add x2, sp, #FE_SUBF_SLOTS
    add x3, sp, #FE_SUBF_KINDS
    bl _ir_sub_set
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #160
    ret
Lfe_sub_nested:
    mov w0, #ERR_NESTED_SUB
    bl _fe_err
Lfe_sub_var:
    mov w0, #ERR_ILLEGAL_VARIABLE
    bl _fe_err
Lfe_sub_format:
    mov w0, #ERR_INCORRECT_FORMAT
    bl _fe_err

// ---------------------------------------------------------------------
// Lfe_sub_parse_param -- one SUB parameter, consumed:
//     letter [digit]          SUBP_NUM, the scalar slot
//     letter [digit] "$"      SUBP_STR, the string slot
//     letter "(" ")"          SUBP_ARR, the letter
//     letter "$" "(" ")"      SUBP_SARR, the letter
//   Anything else (not a letter, letter + digit + '(' or + "$(", a '('
//   not followed by ')') -> ILLEGAL VARIABLE.
//   in:  none
//   out: w0 = slot or letter, w1 = SUBP_* kind
//   clobbers: x0-x17
//   callee-saved: w19 = letter, w20 = slot, w21 = second byte
//   frame: 48 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_sub_parse_param:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov w0, #0
    bl _fe_peek
    sub w19, w0, #'A'
    cmp w19, #25
    b.hi Lfe_sub_parse_bad              // not a letter (or nothing)
    mov w9, #SLOT_PER_LETTER
    mul w20, w19, w9                    // slot of the bare letter
    mov w0, #1
    bl _fe_peek
    mov w21, w0
    sub w9, w21, #'0'
    cmp w9, #9
    b.hi Lfe_sub_parse_nodigit
    // letter + digit: a simple or string variable only
    add w20, w20, w9
    add w20, w20, #1                    // letter*11 + digit + 1
    mov w0, #2
    bl _fe_peek
    cmp w0, #'('
    b.eq Lfe_sub_parse_bad              // X1(
    cmp w0, #'$'
    b.ne 1f
    mov w0, #3
    bl _fe_peek
    cmp w0, #'('
    b.eq Lfe_sub_parse_bad              // X1$(
    mov w0, #3
    bl _fe_advance
    mov w0, w20
    mov w1, #SUBP_STR
    b Lfe_sub_parse_ret
1:
    mov w0, #2
    bl _fe_advance
    mov w0, w20
    mov w1, #SUBP_NUM
    b Lfe_sub_parse_ret
Lfe_sub_parse_nodigit:
    cmp w21, #'$'
    b.ne 3f
    mov w0, #2
    bl _fe_peek
    cmp w0, #'('
    b.eq 2f
    // X$: a string variable
    mov w0, #2
    bl _fe_advance
    mov w0, w20
    mov w1, #SUBP_STR
    b Lfe_sub_parse_ret
2:
    // L$( must be L$()
    mov w0, #3
    bl _fe_peek
    cmp w0, #')'
    b.ne Lfe_sub_parse_bad
    mov w0, #4
    bl _fe_advance
    mov w0, w19
    mov w1, #SUBP_SARR
    b Lfe_sub_parse_ret
3:
    cmp w21, #'('
    b.ne 4f
    // L( must be L()
    mov w0, #2
    bl _fe_peek
    cmp w0, #')'
    b.ne Lfe_sub_parse_bad
    mov w0, #3
    bl _fe_advance
    mov w0, w19
    mov w1, #SUBP_ARR
    b Lfe_sub_parse_ret
4:
    // a bare letter: a simple variable
    mov w0, #1
    bl _fe_advance
    mov w0, w20
    mov w1, #SUBP_NUM
Lfe_sub_parse_ret:
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
Lfe_sub_parse_bad:
    mov w0, #ERR_ILLEGAL_VARIABLE
    bl _fe_err

// ---------------------------------------------------------------------
// _fe_subend -- SUBEND (LANGUAGE.md 7.27): outside every SUB block ->
//   ILLEGAL INSTRUCTION; text after it -> INCORRECT FORMAT; a multi-line
//   DEF of the block still open (this line ends its body) -> UNFINISHED
//   DEF at that DEF's line; a FOR of the subprogram still open ->
//   UNFINISHED SUB at this line. Lowering: `subret`.
//   in:  scanner after "SUBEND"
//   out: none
//   clobbers: x0-x17
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .globl _fe_subend
    .p2align 2
_fe_subend:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x9, _fe_curunit@PAGE
    ldr w9, [x9, _fe_curunit@PAGEOFF]
    cbnz w9, 1f
    mov w0, #ERR_ILLEGAL_INSTRUCTION
    bl _fe_err
1:
    bl _fe_expect_eol
    // a DEF body of the block left open
    adrp x9, _fe_ctx_kind@PAGE
    ldr w9, [x9, _fe_ctx_kind@PAGEOFF]
    cmp w9, #FE_CTX_ML
    b.ne 2f
    adrp x9, _fe_ctx_letter@PAGE
    ldr w9, [x9, _fe_ctx_letter@PAGEOFF]
    FE_ADR x10, _fe_ml_defline
    ldr w1, [x10, x9, lsl #2]
    mov w0, #ERR_UNFINISHED_DEF
    bl _fe_fail
2:
    // every FOR of the subprogram must be closed
    adrp x9, _fe_forsp@PAGE
    ldr w9, [x9, _fe_forsp@PAGEOFF]
    adrp x10, _fe_unitforbase@PAGE
    ldr w10, [x10, _fe_unitforbase@PAGEOFF]
    cmp w9, w10
    b.ls 3f
    mov w0, #ERR_UNFINISHED_SUB
    bl _fe_err
3:
    FE_NONE
    mov w0, #OP_SUBRET
    bl _fe_emit
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// _fe_callstmt -- CALL name [ ":" argument { "," argument } ]
//   (LANGUAGE.md 7.27, IR.md 4.3). Each argument is lowered to its
//   reference (Lfe_call_arg); a seventeenth argument -> INCORRECT FORMAT
//   as soon as it starts; anything but ',' or the end after an argument
//   -> INCORRECT FORMAT. The call is logged for phase 3 (name, count,
//   kinds). Lowering: the arguments left to right, then `subarg 1, tR1`
//   ... `subarg k, tRk`, `callsub "s", tR0` (A = IR_NONE without
//   arguments). A name no SUB block has emits no `callsub` (UNDEFINED
//   SUBPROGRAM follows in phase 3).
//   in:  scanner after "CALL"
//   out: none
//   clobbers: x0-x17, d0-d7
//   callee-saved: x19 = name, w20 = name length, w21 = argument count,
//        w22 = unit index or -1, w23 = subarg index
//   frame: 160 bytes (frame record, x19-x24, u32[16] reference temps at
//        sp+64, u8[16] kinds at sp+128)
// ---------------------------------------------------------------------
.equ FE_CALLF_TEMPS,    64
.equ FE_CALLF_KINDS,    128
    .globl _fe_callstmt
    .p2align 2
_fe_callstmt:
    stp x29, x30, [sp, #-160]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    bl Lfe_sub_name
    mov x19, x0
    mov w20, w1
    // the unit of that name (the pre-scan's names)
    adrp x9, _fe_nunits@PAGE
    ldr w2, [x9, _fe_nunits@PAGEOFF]
    bl Lfe_sub_lookup
    mov w22, w0
    mov w21, #0
    stp xzr, xzr, [sp, #FE_CALLF_KINDS]
    // end of line, or ':' and the arguments
    mov w0, #0
    bl _fe_peek
    cmp w0, #FE_PEEK_EOL
    b.eq Lfe_callstmt_done
    cmp w0, #':'
    b.ne Lfe_callstmt_format
    mov w0, #1
    bl _fe_advance
Lfe_callstmt_arg:
    cmp w21, #LIM_SUB_PARAMS
    b.hs Lfe_callstmt_format            // a seventeenth argument
    bl Lfe_call_arg
    add x9, sp, #FE_CALLF_TEMPS
    str w0, [x9, x21, lsl #2]
    add x9, sp, #FE_CALLF_KINDS
    strb w1, [x9, x21]
    add w21, w21, #1
    bl _fe_next_op
    cmp w0, #TK_COMMA
    b.eq Lfe_callstmt_arg
    cmp w0, #TK_EOL
    b.ne Lfe_callstmt_format
Lfe_callstmt_done:
    // log the call for phase 3
    mov x0, x19
    mov w1, w20
    mov w2, w21
    add x3, sp, #FE_CALLF_KINDS
    bl Lfe_call_log
    tbnz w22, #31, Lfe_callstmt_ret     // no such SUB: UNDEFINED SUBPROGRAM later
    // subarg k, tRk for k = 1 .. count-1
    mov w23, #1
1:
    cmp w23, w21
    b.hs 2f
    FE_NONE
    add x9, sp, #FE_CALLF_TEMPS
    ldr w1, [x9, x23, lsl #2]
    mov w5, w23                         // IMM = argument index k
    mov w0, #OP_SUBARG
    bl _fe_emit
    add w23, w23, #1
    b 1b
2:
    // callsub "s", tR0
    FE_NONE
    cbz w21, 3f
    ldr w1, [sp, #FE_CALLF_TEMPS]       // A = argument 0
3:
    mov w4, w22                         // X = unit index
    mov w0, #OP_CALLSUB
    bl _fe_emit
Lfe_callstmt_ret:
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #160
    ret
Lfe_callstmt_format:
    mov w0, #ERR_INCORRECT_FORMAT
    bl _fe_err

// ---------------------------------------------------------------------
// Lfe_call_arg -- one CALL argument and its reference (LANGUAGE.md 7.27,
//   IR.md 4.3 "CALL arguments"), decided by its text in this order:
//     L()        `tR = aref L`       SUBP_ARR  (a whole-array use: fixes
//                                              nothing, _fe_mat_names)
//     L$()       `tR = saref L$`     SUBP_SARR (_fe_smat_names)
//     exactly a simple variable (not a parameter of the enclosing DEF)
//                `tR = vaddr V`      SUBP_NUM
//     exactly a list / table element  i (, j), `tR = aaddr1/aaddr2`
//     exactly a string variable (not a DEF parameter)
//                `tR = svar V$`      SUBP_STR
//     exactly a string list / table element  i (, j), `tR = sald1/sald2`
//     a string expression: a result expression is its own cell, any
//                other is copied into a new cell (`scell`, `sset`); an
//                arithmetic operator after it -> MISMATCHED STRING
//                OPERATION                                 SUBP_STR
//     any other text: a numeric expression e, `tR = taddr te`  SUBP_NUM
//   "Exactly" means that ',' or the end of the line follows the
//   variable or the element's closing ')'.
//   in:  scanner at the argument
//   out: w0 = reference temp, w1 = SUBP_* kind
//   clobbers: x0-x17, d0-d7
//   callee-saved: x19 = start position, w20 = letter / slot, w21 = temp,
//        w22 = kind
//   frame: 96 bytes (frame record, x19-x22, 40-byte token at sp+48)
// ---------------------------------------------------------------------
    .p2align 2
Lfe_call_arg:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    bl _fe_getpos
    mov x19, x0
    // ---- whole arrays: letter "()" or letter "$()" ----------------------
    mov w0, #0
    bl _fe_peek
    sub w20, w0, #'A'
    cmp w20, #25
    b.hi Lfe_call_arg_token
    mov w0, #1
    bl _fe_peek
    cmp w0, #'('
    b.ne 1f
    mov w0, #2
    bl _fe_peek
    cmp w0, #')'
    b.ne Lfe_call_arg_token
    mov w0, #3
    bl _fe_advance
    // _fe_mat_names |= 1 << letter: an unknown shape becomes a table
    adrp x9, _fe_mat_names@PAGE
    ldr w10, [x9, _fe_mat_names@PAGEOFF]
    mov w11, #1
    lsl w11, w11, w20
    orr w10, w10, w11
    str w10, [x9, _fe_mat_names@PAGEOFF]
    FE_NONE
    mov w4, w20
    mov w0, #OP_AREF
    bl _fe_emit_new
    mov w1, #SUBP_ARR
    b Lfe_call_arg_ret
1:
    cmp w0, #'$'
    b.ne Lfe_call_arg_token
    mov w0, #2
    bl _fe_peek
    cmp w0, #'('
    b.ne Lfe_call_arg_token
    mov w0, #3
    bl _fe_peek
    cmp w0, #')'
    b.ne Lfe_call_arg_token
    mov w0, #4
    bl _fe_advance
    // _fe_smat_names |= 1 << letter: an unknown shape becomes a list
    adrp x9, _fe_smat_names@PAGE
    ldr w10, [x9, _fe_smat_names@PAGEOFF]
    mov w11, #1
    lsl w11, w11, w20
    orr w10, w10, w11
    str w10, [x9, _fe_smat_names@PAGEOFF]
    FE_NONE
    mov w4, w20
    mov w0, #OP_SAREF
    bl _fe_emit_new
    mov w1, #SUBP_SARR
    b Lfe_call_arg_ret

Lfe_call_arg_token:
    // ---- exactly a variable or an element? ------------------------------
    mov w0, #SCAN_OPERAND
    add x1, sp, #48
    bl _fe_scan
    cmp w0, #TK_VAR
    b.eq Lfe_call_arg_var
    cmp w0, #TK_SVAR
    b.eq Lfe_call_arg_svar
    cmp w0, #TK_ARRAY
    b.eq Lfe_call_arg_elem
    cmp w0, #TK_SARRAY
    b.eq Lfe_call_arg_selem
    b Lfe_call_arg_general

Lfe_call_arg_var:
    bl Lfe_call_at_end
    cbz w0, Lfe_call_arg_general
    ldr w20, [sp, #(48 + TOK_SLOT)]
    mov w0, w20
    bl _fe_param_index                  // a DEF parameter: passed by value
    tbz w0, #31, Lfe_call_arg_general
    FE_NONE
    mov w4, w20
    mov w0, #OP_VADDR
    bl _fe_emit_new
    mov w1, #SUBP_NUM
    b Lfe_call_arg_ret

Lfe_call_arg_svar:
    bl Lfe_call_at_end
    cbz w0, Lfe_call_arg_general
    ldr w20, [sp, #(48 + TOK_SLOT)]
    mov w0, w20
    bl _fe_sparam_index                 // a DEF string parameter: by value
    tbz w0, #31, Lfe_call_arg_general
    FE_NONE
    mov w4, w20
    mov w0, #OP_SVAR
    bl _fe_emit_new
    mov w1, #SUBP_STR
    b Lfe_call_arg_ret

Lfe_call_arg_elem:
    // L(i) / L(i, j) followed by ',' or the end: by reference
    bl Lfe_call_elem_at_end
    cbz w0, Lfe_call_arg_general
    ldr w20, [sp, #(48 + TOK_INDEX)]
    mov w0, w20
    bl _fe_subscripts
    mov w21, w0
    mov w22, w1
    mov w9, w2
    FE_NONE
    mov w4, w20
    mov w1, w21
    mov w0, #OP_AADDR1
    cmp w9, #1
    b.eq 2f
    mov w2, w22
    mov w0, #OP_AADDR2
2:
    bl _fe_emit_new
    mov w1, #SUBP_NUM
    b Lfe_call_arg_ret

Lfe_call_arg_selem:
    // L$(i) / L$(i, j) followed by ',' or the end: by reference
    bl Lfe_call_elem_at_end
    cbz w0, Lfe_call_arg_general
    ldr w20, [sp, #(48 + TOK_INDEX)]
    mov w0, w20
    bl _fe_sarr_subscripts
    mov w21, w0
    mov w22, w1
    mov w9, w2
    FE_NONE
    mov w4, w20
    mov w1, w21
    mov w0, #OP_SALD1
    cmp w9, #1
    b.eq 3f
    mov w2, w22
    mov w0, #OP_SALD2
3:
    bl _fe_emit_new
    mov w1, #SUBP_STR
    b Lfe_call_arg_ret

Lfe_call_arg_general:
    // ---- by value: a string expression or a numeric expression ----------
    mov x0, x19
    bl _fe_setpos
    bl _fe_sexpr_try
    tbnz w0, #31, Lfe_call_arg_number
    mov w21, w0
    mov w22, w1                         // a private cell?
    bl _fe_sref_end
    mov w0, w21
    cbnz w22, 4f
    // a shared reference: its value goes into a new cell
    bl _fe_new_scell
    mov w22, w0
    FE_NONE
    mov w1, w22
    mov w2, w21
    mov w0, #OP_SSET
    bl _fe_emit
    mov w0, w22
4:
    mov w1, #SUBP_STR
    b Lfe_call_arg_ret
Lfe_call_arg_number:
    bl _fe_expr
    mov w9, w0
    FE_NONE
    mov w1, w9
    mov w0, #OP_TADDR
    bl _fe_emit_new
    mov w1, #SUBP_NUM
Lfe_call_arg_ret:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret

// ---------------------------------------------------------------------
// Lfe_call_at_end -- does an argument end at the scanner position (','
//   or the end of the line)? Nothing is consumed.
//   in: none   out: w0 = 1 if so, else 0
//   clobbers: x0, x9-x11   leaf, no frame
// ---------------------------------------------------------------------
    .p2align 2
Lfe_call_at_end:
    adrp x9, _fe_pos@PAGE
    ldr x10, [x9, _fe_pos@PAGEOFF]
    adrp x9, _fe_end@PAGE
    ldr x11, [x9, _fe_end@PAGEOFF]
    mov w0, #1
    cmp x10, x11
    b.hs 1f
    ldrb w9, [x10]
    cmp w9, #','
    cset w0, eq
1:
    ret

// ---------------------------------------------------------------------
// Lfe_call_elem_at_end -- after an element's "L(" or "L$(" (consumed),
//   does the matching ')' exist and is it followed by ',' or the end of
//   the line? The parentheses are balanced by text, quotes respected;
//   nothing is consumed.
//   in: none   out: w0 = 1 if so, else 0
//   clobbers: x0, x9-x14   leaf, no frame
// ---------------------------------------------------------------------
    .p2align 2
Lfe_call_elem_at_end:
    adrp x9, _fe_pos@PAGE
    ldr x10, [x9, _fe_pos@PAGEOFF]      // cursor
    adrp x9, _fe_end@PAGE
    ldr x11, [x9, _fe_end@PAGEOFF]      // line end
    mov w12, #1                         // open parentheses
    mov w13, #0                         // inside a string constant
1:
    cmp x10, x11
    b.hs Lfe_call_elem_no               // no matching ')'
    ldrb w14, [x10], #1
    cmp w14, #'"'
    b.ne 2f
    eor w13, w13, #1
    b 1b
2:
    cbnz w13, 1b
    cmp w14, #'('
    b.ne 3f
    add w12, w12, #1
    b 1b
3:
    cmp w14, #')'
    b.ne 1b
    subs w12, w12, #1
    b.ne 1b
    // the matching ')': ',' or the end must follow
    mov w0, #1
    cmp x10, x11
    b.hs 4f
    ldrb w14, [x10]
    cmp w14, #','
    cset w0, eq
4:
    ret
Lfe_call_elem_no:
    mov w0, #0
    ret

// ---------------------------------------------------------------------
// Lfe_call_log -- append a CALL to the CALL log (grown by doubling; the
//   arena never frees, the old block is simply abandoned).
//   in:  x0 = name, w1 = name length, w2 = argument count, x3 = u8[16]
//        argument kinds
//   out: none
//   clobbers: x0-x17
//   callee-saved: x19 = name, w20 = length, w21 = count, x22 = kinds,
//        x23 = new block, w24 = new capacity
//   frame: 64 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_call_log:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    mov x19, x0
    mov w20, w1
    mov w21, w2
    mov x22, x3
    adrp x9, _fe_nsublog@PAGE
    ldr w10, [x9, _fe_nsublog@PAGEOFF]
    adrp x9, _fe_capsublog@PAGE
    ldr w11, [x9, _fe_capsublog@PAGEOFF]
    cmp w10, w11
    b.lo Lfe_call_log_store
    // full: a block of twice the capacity (FE_CL_INITIAL at first)
    lsl w24, w11, #1
    cbnz w24, 1f
    mov w24, #FE_CL_INITIAL
1:
    mov w9, #FE_CL_SIZE
    umull x0, w24, w9
    bl _drv_alloc
    mov x23, x0
    // copy the old entries
    adrp x9, _fe_sublog@PAGE
    ldr x1, [x9, _fe_sublog@PAGEOFF]
    adrp x9, _fe_nsublog@PAGE
    ldr w10, [x9, _fe_nsublog@PAGEOFF]
    mov w9, #FE_CL_SIZE
    umull x2, w10, w9
    cbz x2, 2f
    mov x0, x23
    bl _memcpy
2:
    adrp x9, _fe_sublog@PAGE
    str x23, [x9, _fe_sublog@PAGEOFF]
    adrp x9, _fe_capsublog@PAGE
    str w24, [x9, _fe_capsublog@PAGEOFF]
Lfe_call_log_store:
    adrp x9, _fe_sublog@PAGE
    ldr x12, [x9, _fe_sublog@PAGEOFF]
    adrp x9, _fe_nsublog@PAGE
    ldr w10, [x9, _fe_nsublog@PAGEOFF]
    mov w11, #FE_CL_SIZE
    umaddl x12, w10, w11, x12           // &log[n]
    adrp x11, _fe_line@PAGE
    ldr w11, [x11, _fe_line@PAGEOFF]
    str w11, [x12, #FE_CL_LINE]
    str w21, [x12, #FE_CL_NARGS]
    str x19, [x12, #FE_CL_NAME]
    str w20, [x12, #FE_CL_NAMELEN]
    ldp x13, x14, [x22]
    stp x13, x14, [x12, #FE_CL_KINDS]
    add w10, w10, #1
    str w10, [x9, _fe_nsublog@PAGEOFF]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

// ---------------------------------------------------------------------
// _fe_sub_check_fns -- the phase-3 FN checks of LANGUAGE.md 10.1 over
//   every program unit: UNDEFINED FUNCTION, INCORRECT NUMBER OF ARGUMENTS
//   and the kind check each report the smallest offending line of all
//   units together; RECURSIVE FUNCTION is checked unit by unit, the main
//   program first, then the SUB units in ascending order of their SUB
//   lines (lowest letter first within a unit).
//   in: none   out: returns only if every check passes (the main
//        program's state is current again)
//   clobbers: x0-x17
//   callee-saved: x19 = check table cursor, w20 = unit, w21 = best line,
//        w22 = unit count
//   frame: 48 bytes
// ---------------------------------------------------------------------
    .globl _fe_sub_check_fns
    .p2align 2
_fe_sub_check_fns:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    adrp x9, _fe_nunits@PAGE
    ldr w22, [x9, _fe_nunits@PAGEOFF]
    FE_ADR x19, Lfe_sub_minchecks
Lfe_sub_check_fns_next:
    ldr x9, [x19]                       // helper (0 = end of table)
    cbz x9, Lfe_sub_check_fns_rec
    mov w21, #0
    mov w20, #0
1:
    // the helper's line in unit w20; keep the smallest
    mov w0, w20
    bl _fe_unit_switch
    ldr x9, [x19]
    blr x9
    cbz w0, 2f
    cbz w21, 3f
    cmp w0, w21
    b.hs 2f
3:
    mov w21, w0
2:
    add w20, w20, #1
    cmp w20, w22
    b.ls 1b
    cbz w21, 4f
    ldr w0, [x19, #8]                   // its error code
    mov w1, w21
    bl _fe_fail
4:
    add x19, x19, #16
    b Lfe_sub_check_fns_next
Lfe_sub_check_fns_rec:
    // RECURSIVE FUNCTION, unit by unit
    mov w20, #0
5:
    mov w0, w20
    bl _fe_unit_switch
    bl _fe_fn_rec_line
    cbz w0, 6f
    mov w1, w0
    mov w0, #ERR_RECURSIVE_FUNCTION
    bl _fe_fail
6:
    add w20, w20, #1
    cmp w20, w22
    b.ls 5b
    mov w0, #0
    bl _fe_unit_switch
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// _fe_sub_check_calls -- the Sixth Edition phase-3 checks (LANGUAGE.md
//   10.1), each over the CALL log in ascending line order: UNDEFINED
//   SUBPROGRAM (a name no SUB has); INCORRECT NUMBER OF ARGUMENTS (count
//   differs from the SUB's parameter count); then the first argument
//   whose kind differs from its parameter's: an array for a scalar or a
//   scalar for an array -> ARGUMENT MISMATCH, else (string for number or
//   number for string) MISMATCHED STRING OPERATION.
//   in: none   out: returns only if every CALL matches its SUB
//   clobbers: x0-x17
//   callee-saved: x19 = log entry, w20 = entries left, w21 = pass,
//        x22 = unit record, w23 = argument index
//   frame: 64 bytes
// ---------------------------------------------------------------------
    .globl _fe_sub_check_calls
    .p2align 2
_fe_sub_check_calls:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]
    mov w21, #0                         // pass 0: names, 1: counts, 2: kinds
Lfe_sub_calls_pass:
    adrp x9, _fe_sublog@PAGE
    ldr x19, [x9, _fe_sublog@PAGEOFF]
    adrp x9, _fe_nsublog@PAGE
    ldr w20, [x9, _fe_nsublog@PAGEOFF]
Lfe_sub_calls_entry:
    cbz w20, Lfe_sub_calls_next_pass
    ldr x0, [x19, #FE_CL_NAME]
    ldr w1, [x19, #FE_CL_NAMELEN]
    adrp x9, _fe_nunits@PAGE
    ldr w2, [x9, _fe_nunits@PAGEOFF]
    bl Lfe_sub_lookup
    tbz w0, #31, 1f
    mov w0, #ERR_UNDEFINED_SUB          // (only pass 0 can get here)
    b Lfe_sub_calls_fail
1:
    cbz w21, Lfe_sub_calls_advance
    add w0, w0, #1
    bl _fe_unit_rec
    mov x22, x0
    ldr w9, [x19, #FE_CL_NARGS]
    ldr w10, [x22, #FE_U_NPARAMS]
    cmp w21, #1
    b.ne 2f
    cmp w9, w10
    b.eq Lfe_sub_calls_advance
    mov w0, #ERR_WRONG_NUM_ARGS
    b Lfe_sub_calls_fail
2:
    // pass 2: kinds, left to right (the counts are equal)
    mov w23, #0
3:
    cmp w23, w9
    b.hs Lfe_sub_calls_advance
    add x11, x19, #FE_CL_KINDS
    ldrb w12, [x11, x23]                // the argument's kind
    add x11, x22, #FE_U_KINDS
    ldrb w13, [x11, x23]                // the parameter's kind
    cmp w12, w13
    b.eq 4f
    // array vs scalar (SUBP_ARR, SUBP_SARR are >= 2) -> ARGUMENT MISMATCH
    cmp w12, #SUBP_ARR
    cset w14, hs
    cmp w13, #SUBP_ARR
    cset w15, hs
    mov w0, #ERR_MISMATCHED_STRING
    cmp w14, w15
    b.eq Lfe_sub_calls_fail
    mov w0, #ERR_ARG_MISMATCH
    b Lfe_sub_calls_fail
4:
    add w23, w23, #1
    b 3b
Lfe_sub_calls_advance:
    add x19, x19, #FE_CL_SIZE
    sub w20, w20, #1
    b Lfe_sub_calls_entry
Lfe_sub_calls_next_pass:
    add w21, w21, #1
    cmp w21, #3
    b.lo Lfe_sub_calls_pass
    ldr x23, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret
Lfe_sub_calls_fail:
    ldr w1, [x19, #FE_CL_LINE]          // at the CALL's line
    bl _fe_fail

// ---------------------------------------------------------------------
// _fe_sub_publish_all -- after the phase-3 checks, for every program unit
//   (the main program, then the SUB units): letters named only by MAT
//   statements or whole-array CALL arguments get their default shapes
//   (_fe_mat_finish), then the unit's FOR count, arrays and string arrays
//   go to its Module; an array parameter goes through
//   _ir_set_param_array with its dimensionality, IRA_DIMS_ANY when no use
//   fixed it (IR.md 2.2, 4.4).
//   in: none   out: none (the main program's state is current again)
//   clobbers: x0-x17
//   callee-saved: w19 = unit, w20 = unit count, w21 = letter,
//        x22 = array table, w23 = 0 numeric / 1 string arrays
//   frame: 64 bytes
// ---------------------------------------------------------------------
    .globl _fe_sub_publish_all
    .p2align 2
_fe_sub_publish_all:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]
    adrp x9, _fe_nunits@PAGE
    ldr w20, [x9, _fe_nunits@PAGEOFF]
    mov w19, #0
Lfe_sub_publish_unit:
    mov w0, w19
    bl _fe_unit_switch
    bl _fe_mat_finish
    adrp x9, _fe_unit@PAGE
    ldr x0, [x9, _fe_unit@PAGEOFF]
    adrp x9, _fe_nfors@PAGE
    ldr w1, [x9, _fe_nfors@PAGEOFF]
    bl _ir_set_fors
    // numeric arrays, then string arrays
    mov w23, #0
    FE_ADR x22, _fe_arrays
Lfe_sub_publish_table:
    mov w21, #0
Lfe_sub_publish_letter:
    cmp w21, #NUM_LETTERS
    b.hs Lfe_sub_publish_table_done
    add x10, x22, x21, lsl #4           // FE_ARR_ENTRY bytes per letter
    ldr w2, [x10]                       // dims (0 = unused / unknown)
    ldr w9, [x10, #12]                  // flags
    tbz w9, #1, 2f                      // IRA_FLAG_PARAM is bit 1
    // an array parameter: its dimensionality, or any
    mov w11, #IRA_DIMS_ANY
    cmp w2, #0
    csel w2, w11, w2, eq
    adrp x9, _fe_unit@PAGE
    ldr x0, [x9, _fe_unit@PAGEOFF]
    mov w1, w21
    mov w3, w23
    bl _ir_set_param_array
    b 1f
2:
    cbz w2, 1f
    adrp x9, _fe_unit@PAGE
    ldr x0, [x9, _fe_unit@PAGEOFF]
    mov w1, w21
    cbnz w23, 3f
    // a numeric list or table
    ldr w3, [x10, #4]                   // b1
    ldr w4, [x10, #8]                   // b2
    ldr w5, [x10, #12]                  // flags
    bl _ir_set_array
    b 1f
3:
    cmp w2, #2
    b.ne 4f
    // a string table: b1, b2, flags
    ldr w2, [x10, #4]
    ldr w3, [x10, #8]
    ldr w4, [x10, #12]
    bl _ir_set_sarray2
    b 1f
4:
    // a string list: b1, flags
    ldr w2, [x10, #4]
    ldr w3, [x10, #12]
    bl _ir_set_sarray
1:
    add w21, w21, #1
    b Lfe_sub_publish_letter
Lfe_sub_publish_table_done:
    cbnz w23, 5f
    mov w23, #1
    FE_ADR x22, _fe_sarrays
    b Lfe_sub_publish_table
5:
    add w19, w19, #1
    cmp w19, w20
    b.ls Lfe_sub_publish_unit
    mov w0, #0
    bl _fe_unit_switch
    ldr x23, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

// ---------------------------------------------------------------------
// The per-unit minimum checks of _fe_sub_check_fns, in LANGUAGE.md 10.1
// order: helper, error code.
// ---------------------------------------------------------------------
    .section __DATA,__const
    .p2align 3
Lfe_sub_minchecks:
    .quad _fe_fn_undef_line, ERR_UNDEFINED_FUNCTION
    .quad _fe_fn_args_line, ERR_WRONG_NUM_ARGS
    .quad _fe_kinds_line, ERR_MISMATCHED_STRING
    .quad 0, 0

