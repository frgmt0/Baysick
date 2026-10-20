// =====================================================================
// src/frontend/fe_def.s -- user functions (LANGUAGE.md 7.10, IR.md 4.1,
// 4.4): single-line and multi-line DEF with 0..8 parameters, FNEND, the
// pre-scan of multi-line bodies, the per-line function context, and the
// phase-3 function checks.
//
//   _fe_prescan()                 bodies, line labels, multi-line functions
//   _fe_enter_line(w0=i) -> w0    make line i's function current; its label
//   _fe_def_header(w0=mode, x1=u32[8]) -> w0 err, w1 letter, w2 kind, w3 k
//   _fe_def(), _fe_fnend()        DEF / FNEND statement handlers
//   _fe_param_index(w0=slot) -> w0 parameter index k or -1
//   _fe_record_call(w0=letter, w1=argument count)
//   _fe_check_fns()               UNDEFINED FUNCTION, INCORRECT NUMBER OF
//                                 ARGUMENTS, RECURSIVE FUNCTION
//
// The pre-scan decides, before any line is lowered, which lines belong to
// a multi-line body: a DEF line in main whose header parses as a
// multi-line header (no '=') opens a body; every following line up to and
// including the next FNEND line belongs to it (a DEF inside a body is a
// NESTED DEF error later and opens nothing). A header that does not parse,
// or names a letter already DEFined on an earlier main line, opens nothing:
// phase 2 reaches that line first and reports its error, so the
// classification of the lines after it never becomes observable.
//
// Owners (_fe_linefn[i]): 0 = main, 1 + letter = the multi-line function
// FN letter. _fe_linelab[i] = the line's label id inside its owner.
//
// DEF context (_fe_ctx_*, fe_compile.s): FE_CTX_NONE in main, FE_CTX_SL
// while a single-line DEF expression is lowered, FE_CTX_ML for every line
// of a multi-line body; _fe_ctx_letter, _fe_ctx_nparams, _fe_ctx_params
// describe the function. Inside either, a parameter name denotes the
// function's own copy (`param k` / `stparam k`).
//
// Fifth Edition (LANGUAGE.md 7.10.1): DEF FNx$ defines
// a string function and a parameter may be a string parameter X$. Their
// FNK_* bits (FNK_STRING, FNK_SPARAM0 << k) are kept per multi-line
// function (_fe_ml_kinds), per DEFined letter (_fe_fn_kinds) and for the
// DEF context (_fe_ctx_skinds), and published with _ir_set_fnkind. A
// string parameter is read with `sparam k` (fe_sexpr.s); a string
// function's single-line body is a string expression returned by
// `sret`, its FNEND is `tN = sfv; sret tN`.
// =====================================================================
.include "baysick.inc"

.equ FE_LINE_ENTRY,     16          // see fe_compile.s
.equ FE_FOR_ENTRY,      16          // see fe_compile.s
.equ FE_ARGC_SLOTS,     10          // see fe_compile.s
.equ FE_PEEK_EOL,       0x100       // _fe_peek result beyond the line end

// DEF context kinds (_fe_ctx_kind)
.equ FE_CTX_NONE,       0
.equ FE_CTX_SL,         1
.equ FE_CTX_ML,         2

// header kinds returned by _fe_def_header
.equ FE_DEF_SINGLE,     1           // "=" expression follows
.equ FE_DEF_MULTI,      2           // end of line: a multi-line body follows

// _fe_def_header modes
.equ FE_HDR_PRESCAN,    0           // duplicates checked against _fe_pre_seen
.equ FE_HDR_COMPILE,    1           // duplicates checked against _fe_fn_defline

// FE_ADR reg, sym: reg = address of sym
.macro FE_ADR reg, sym
    adrp \reg, \sym@PAGE
    add \reg, \reg, \sym@PAGEOFF
.endm

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _fe_prescan -- classify the program lines (main or a multi-line body),
//   allocate the line labels of main (ascending), then create every
//   multi-line function in ascending DEF-line order (_ir_func_begin,
//   _ir_func_set) with the line labels of its body (IR.md 4.1).
//   in:  _fe_lines / _fe_nlines (phase 1), _fe_module, _fe_main
//   out: _fe_linefn, _fe_linelab, _fe_ml_*, _fe_pre_seen filled
//   clobbers: x0-x17
//   callee-saved: x19 = line table, w20 = line count, w21 = line index,
//        x22 = owner array, x23 = label array, w24 = 1 + letter of the
//        open body (0 = in main), w25 = letter / order index,
//        x26 = Function* being labelled, w27 = last body line index
//   frame: 128 bytes (frame record, x19-x28, 32-byte parameter buffer at
//        sp+96)
// ---------------------------------------------------------------------
    .globl _fe_prescan
    .p2align 2
_fe_prescan:
    stp x29, x30, [sp, #-128]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    adrp x9, _fe_lines@PAGE
    ldr x19, [x9, _fe_lines@PAGEOFF]
    adrp x9, _fe_nlines@PAGE
    ldr w20, [x9, _fe_nlines@PAGEOFF]
    // owner and label arrays, one u32 per line (never a zero-size request)
    lsl x0, x20, #2
    add x0, x0, #16
    bl _drv_alloc
    mov x22, x0
    adrp x9, _fe_linefn@PAGE
    str x22, [x9, _fe_linefn@PAGEOFF]
    lsl x0, x20, #2
    add x0, x0, #16
    bl _drv_alloc
    mov x23, x0
    adrp x9, _fe_linelab@PAGE
    str x23, [x9, _fe_linelab@PAGEOFF]

    // ---- pass A: which lines are multi-line bodies ---------------------
    mov w21, #0
    mov w24, #0
Lfe_prescan_a_loop:
    cmp w21, w20
    b.hs Lfe_prescan_a_done
    add x10, x19, x21, lsl #4           // &lines[i]
    ldr w11, [x10]
    adrp x9, _fe_line@PAGE
    str w11, [x9, _fe_line@PAGEOFF]
    ldr w1, [x10, #4]                   // text length
    ldr x0, [x10, #8]                   // text
    // scanner window = this line (the header parser reads through it)
    adrp x9, _fe_pos@PAGE
    str x0, [x9, _fe_pos@PAGEOFF]
    add x12, x0, x1
    adrp x9, _fe_end@PAGE
    str x12, [x9, _fe_end@PAGEOFF]
    bl _fe_keyword                      // w0 = KW_* or -1, w1 = its length
    str w24, [x22, x21, lsl #2]         // owner: the open body, or main
    cbz w24, Lfe_prescan_a_main
    // inside a body: FNEND closes it (FNEND belongs to the body)
    cmp w0, #KW_FNEND
    b.ne Lfe_prescan_a_next
    sub w9, w24, #1
    FE_ADR x10, _fe_ml_endidx
    str w21, [x10, x9, lsl #2]
    mov w24, #0
    b Lfe_prescan_a_next
Lfe_prescan_a_main:
    cmp w0, #KW_DEF
    b.ne Lfe_prescan_a_next
    // a DEF in main: parse its header without reporting errors
    mov w0, w1
    bl _fe_advance
    mov w0, #FE_HDR_PRESCAN
    add x1, sp, #96
    bl _fe_def_header
    cbnz w0, Lfe_prescan_a_next         // malformed or duplicate: opens nothing
    cmp w2, #FE_DEF_MULTI
    b.ne Lfe_prescan_a_next             // single-line DEF
    // a multi-line header: record the function and open its body
    mov w25, w1                         // letter
    mov w26, w3                         // parameter count
    FE_ADR x10, _fe_ml_defline
    adrp x9, _fe_line@PAGE
    ldr w11, [x9, _fe_line@PAGEOFF]
    str w11, [x10, x25, lsl #2]
    FE_ADR x10, _fe_ml_defidx
    str w21, [x10, x25, lsl #2]
    FE_ADR x10, _fe_ml_nparams
    str w26, [x10, x25, lsl #2]
    FE_ADR x10, _fe_ml_kinds
    str w4, [x10, x25, lsl #2]          // FNK_* bits (0: all numeric)
    // parameters: _fe_ml_params[letter][0..7], unused entries IR_NONE
    FE_ADR x10, _fe_ml_params
    add x10, x10, x25, lsl #5           // 8 u32 per letter
    mov x11, #0
1:
    mov w12, #IR_NONE
    cmp w11, w26
    b.hs 2f
    add x13, sp, #96
    ldr w12, [x13, x11, lsl #2]
2:
    str w12, [x10, x11, lsl #2]
    add x11, x11, #1
    cmp x11, #LIM_FN_PARAMS
    b.lo 1b
    // DEF order list
    adrp x9, _fe_ml_count@PAGE
    ldr w11, [x9, _fe_ml_count@PAGEOFF]
    FE_ADR x10, _fe_ml_order
    str w25, [x10, x11, lsl #2]
    add w11, w11, #1
    str w11, [x9, _fe_ml_count@PAGEOFF]
    add w24, w25, #1                    // the following lines are its body
Lfe_prescan_a_next:
    add w21, w21, #1
    b Lfe_prescan_a_loop
Lfe_prescan_a_done:
    // a body still open at the end: UNFINISHED DEF in phase 3 (or at END);
    // its lines run to the last line
    adrp x9, _fe_ml_open@PAGE
    str w24, [x9, _fe_ml_open@PAGEOFF]
    cbz w24, 1f
    sub w9, w24, #1
    sub w10, w20, #1
    FE_ADR x11, _fe_ml_endidx
    str w10, [x11, x9, lsl #2]
1:

    // ---- pass B: line labels of main, ascending ------------------------
    mov w21, #0
Lfe_prescan_b_loop:
    cmp w21, w20
    b.hs Lfe_prescan_b_done
    ldr w9, [x22, x21, lsl #2]
    cbnz w9, 1f                         // a body line
    adrp x9, _fe_main@PAGE
    ldr x0, [x9, _fe_main@PAGEOFF]
    add x10, x19, x21, lsl #4
    ldr w1, [x10]                       // its BASIC line number
    bl _ir_new_label
    str w0, [x23, x21, lsl #2]
1:
    add w21, w21, #1
    b Lfe_prescan_b_loop
Lfe_prescan_b_done:

    // ---- pass C: the multi-line functions, in DEF line order ----------
    mov w28, #0                         // order index
Lfe_prescan_c_loop:
    adrp x9, _fe_ml_count@PAGE
    ldr w9, [x9, _fe_ml_count@PAGEOFF]
    cmp w28, w9
    b.hs Lfe_prescan_c_done
    FE_ADR x10, _fe_ml_order
    ldr w25, [x10, x28, lsl #2]         // letter
    // _ir_func_begin(module, 1+letter, first parameter or IR_NONE, DEF line)
    adrp x9, _fe_module@PAGE
    ldr x0, [x9, _fe_module@PAGEOFF]
    add w1, w25, #FUNC_FN_BASE
    FE_ADR x10, _fe_ml_params
    add x10, x10, x25, lsl #5
    ldr w2, [x10]                       // PARAMS[0] (IR_NONE if none)
    FE_ADR x10, _fe_ml_defline
    ldr w3, [x10, x25, lsl #2]
    bl _ir_func_begin
    mov x26, x0
    FE_ADR x10, _fe_ml_fn
    str x26, [x10, x25, lsl #3]
    // _ir_func_set(fn, FNML, k, params, FNEND line or 0 if never closed)
    mov w4, #0
    adrp x9, _fe_ml_open@PAGE
    ldr w9, [x9, _fe_ml_open@PAGEOFF]
    sub w9, w9, #1
    cmp w9, w25
    b.eq 1f
    FE_ADR x10, _fe_ml_endidx
    ldr w11, [x10, x25, lsl #2]
    add x11, x19, x11, lsl #4
    ldr w4, [x11]                       // the FNEND line number
1:
    mov x0, x26
    mov w1, #FUNC_KIND_FNML
    FE_ADR x10, _fe_ml_nparams
    ldr w2, [x10, x25, lsl #2]
    FE_ADR x3, _fe_ml_params
    add x3, x3, x25, lsl #5
    bl _ir_func_set
    // a string function or string parameters: _ir_set_fnkind (IR.md 4.4)
    FE_ADR x10, _fe_ml_kinds
    ldr w2, [x10, x25, lsl #2]
    cbz w2, 2f
    adrp x9, _fe_module@PAGE
    ldr x0, [x9, _fe_module@PAGEOFF]
    add w1, w25, #FUNC_FN_BASE
    bl _ir_set_fnkind
2:
    // line labels of the body: DEF line + 1 .. FNEND line
    FE_ADR x10, _fe_ml_endidx
    ldr w27, [x10, x25, lsl #2]
    FE_ADR x10, _fe_ml_defidx
    ldr w21, [x10, x25, lsl #2]
    add w21, w21, #1
Lfe_prescan_c_lab:
    cmp w21, w27
    b.hi Lfe_prescan_c_next
    mov x0, x26
    add x10, x19, x21, lsl #4
    ldr w1, [x10]
    bl _ir_new_label
    str w0, [x23, x21, lsl #2]
    add w21, w21, #1
    b Lfe_prescan_c_lab
Lfe_prescan_c_next:
    add w28, w28, #1
    b Lfe_prescan_c_loop
Lfe_prescan_c_done:
    ldp x27, x28, [sp, #80]
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #128
    ret

// ---------------------------------------------------------------------
// _fe_enter_line -- make the function that owns line i current: main, or
//   a multi-line function (whose DEF context then applies). Entering a
//   body starts a new FOR-stack region (a NEXT in a body only closes FORs
//   of that body, LANGUAGE.md 7.8); back in main the region is the whole
//   stack again.
//   in:  w0 = line index i
//   out: w0 = the line's label id in its function
//   clobbers: x0, x9-x15   leaf, no frame
// ---------------------------------------------------------------------
    .globl _fe_enter_line
    .p2align 2
_fe_enter_line:
    adrp x9, _fe_linefn@PAGE
    ldr x9, [x9, _fe_linefn@PAGEOFF]
    ldr w10, [x9, w0, uxtw #2]          // owner
    adrp x9, _fe_linelab@PAGE
    ldr x9, [x9, _fe_linelab@PAGEOFF]
    ldr w0, [x9, w0, uxtw #2]           // label id
    adrp x9, _fe_curowner@PAGE
    ldr w11, [x9, _fe_curowner@PAGEOFF] // previous owner
    str w10, [x9, _fe_curowner@PAGEOFF]
    adrp x12, _fe_ctx_kind@PAGE
    cbnz w10, Lfe_enter_line_body
    // main: no DEF context, the FOR region is the whole stack
    adrp x9, _fe_main@PAGE
    ldr x13, [x9, _fe_main@PAGEOFF]
    adrp x9, _fe_curfn@PAGE
    str x13, [x9, _fe_curfn@PAGEOFF]
    str wzr, [x12, _fe_ctx_kind@PAGEOFF]
    adrp x9, _fe_ctx_skinds@PAGE
    str wzr, [x9, _fe_ctx_skinds@PAGEOFF]
    adrp x9, _fe_forbase@PAGE
    str wzr, [x9, _fe_forbase@PAGEOFF]
    ret
Lfe_enter_line_body:
    sub w13, w10, #1                    // letter
    FE_ADR x9, _fe_ml_fn
    ldr x14, [x9, x13, lsl #3]
    adrp x9, _fe_curfn@PAGE
    str x14, [x9, _fe_curfn@PAGEOFF]
    mov w14, #FE_CTX_ML
    str w14, [x12, _fe_ctx_kind@PAGEOFF]
    adrp x9, _fe_ctx_letter@PAGE
    str w13, [x9, _fe_ctx_letter@PAGEOFF]
    FE_ADR x9, _fe_ml_nparams
    ldr w14, [x9, x13, lsl #2]
    adrp x9, _fe_ctx_nparams@PAGE
    str w14, [x9, _fe_ctx_nparams@PAGEOFF]
    FE_ADR x9, _fe_ml_kinds
    ldr w14, [x9, x13, lsl #2]
    adrp x9, _fe_ctx_skinds@PAGE
    str w14, [x9, _fe_ctx_skinds@PAGEOFF]
    // copy the eight parameter slots
    FE_ADR x9, _fe_ml_params
    add x9, x9, x13, lsl #5
    FE_ADR x15, _fe_ctx_params
    ldp x13, x14, [x9]
    stp x13, x14, [x15]
    ldp x13, x14, [x9, #16]
    stp x13, x14, [x15, #16]
    // the first line of a body starts its FOR region
    cmp w11, w10
    b.eq 1f
    adrp x9, _fe_forsp@PAGE
    ldr w13, [x9, _fe_forsp@PAGEOFF]
    adrp x9, _fe_forbase@PAGE
    str w13, [x9, _fe_forbase@PAGEOFF]
1:
    ret

// ---------------------------------------------------------------------
// _fe_def_header -- parse a DEF header after the keyword, without
//   reporting errors (the pre-scan uses it silently, phase 2 reports the
//   code it returns):
//     "FN" letter [ "$" ] [ "(" parameter { "," parameter } ")" ] ( "=" | EOL )
//   ("$" after the letter makes a string function, X$ a string parameter,
//   LANGUAGE.md 7.10; parameters are distinct as (name, kind) pairs)
//   Errors, left to right: no FN letter -> INCORRECT FORMAT; the letter
//   already DEFined -> DUPLICATE FUNCTION; a parameter that is missing,
//   not a simple variable (string, array) or repeated -> ILLEGAL VARIABLE;
//   a ninth parameter -> INCORRECT FORMAT; no ',' or ')' after a
//   parameter -> INCORRECT FORMAT; anything but '=' or the end of the
//   line after the header -> INCORRECT FORMAT.
//   On success the scanner is after the '=' (single-line) or at the end
//   of the line (multi-line).
//   in:  w0 = FE_HDR_PRESCAN (duplicates: letters seen by the pre-scan,
//        which this call marks) or FE_HDR_COMPILE (duplicates: letters
//        with a DEF line already compiled), x1 = u32[LIM_FN_PARAMS] for
//        the parameter slots
//   out: w0 = ERR_* or 0, w1 = letter or -1 if none was parsed,
//        w2 = FE_DEF_SINGLE / FE_DEF_MULTI, w3 = parameter count,
//        w4 = FNK_* bits (FNK_STRING, string parameters)
//   clobbers: x0-x17
//   callee-saved: x19 = parameter buffer, w20 = mode, w21 = letter,
//        w22 = parameter count, w23 = slot, w24 = name length / kind,
//        w25 = FNK_* bits, w26 = 1 for a string parameter
//   frame: 80 bytes
// ---------------------------------------------------------------------
    .globl _fe_def_header
    .p2align 2
_fe_def_header:
    stp x29, x30, [sp, #-80]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    mov x19, x1
    mov w20, w0
    mov w21, #-1
    mov w22, #0
    mov w25, #0
    // "FN" letter
    mov w0, #0
    bl _fe_peek
    cmp w0, #'F'
    b.ne Lfe_def_header_format
    mov w0, #1
    bl _fe_peek
    cmp w0, #'N'
    b.ne Lfe_def_header_format
    mov w0, #2
    bl _fe_peek
    sub w9, w0, #'A'
    cmp w9, #25
    b.hi Lfe_def_header_format
    mov w21, w9
    mov w0, #3
    bl _fe_advance
    // FNx$: a string function
    mov w0, #0
    bl _fe_peek
    cmp w0, #'$'
    b.ne 1f
    mov w25, #FNK_STRING
    mov w0, #1
    bl _fe_advance
1:
    // a second DEF of the same letter
    cmp w20, #FE_HDR_PRESCAN
    b.ne 1f
    adrp x9, _fe_pre_seen@PAGE
    ldr w10, [x9, _fe_pre_seen@PAGEOFF]
    mov w11, #1
    lsl w11, w11, w21
    orr w12, w10, w11
    str w12, [x9, _fe_pre_seen@PAGEOFF]
    tst w10, w11
    b.ne Lfe_def_header_dup
    b 2f
1:
    FE_ADR x9, _fe_fn_defline
    ldr w10, [x9, x21, lsl #2]
    cbnz w10, Lfe_def_header_dup
2:
    // optional parameter list
    mov w0, #0
    bl _fe_peek
    cmp w0, #'('
    b.ne Lfe_def_header_tail
    mov w0, #1
    bl _fe_advance
Lfe_def_header_param:
    // at most LIM_FN_PARAMS parameters
    cmp w22, #LIM_FN_PARAMS
    b.hs Lfe_def_header_format
    // a simple variable: letter [digit]
    mov w0, #0
    bl _fe_peek
    sub w9, w0, #'A'
    cmp w9, #25
    b.hi Lfe_def_header_var             // missing (DEF FNA()) or not a letter
    mov w10, #SLOT_PER_LETTER
    mul w23, w9, w10
    mov w24, #1
    mov w0, #1
    bl _fe_peek
    sub w9, w0, #'0'
    cmp w9, #9
    b.hi 3f
    add w23, w23, w9
    add w23, w23, #1                    // letter*11 + digit + 1
    mov w24, #2
3:
    mov w26, #0                         // numeric parameter
    mov w0, w24
    bl _fe_peek
    // X$: a string parameter (X$( is not a parameter)
    cmp w0, #'$'
    b.ne 7f
    add w0, w24, #1
    bl _fe_peek
    cmp w0, #'('
    b.eq Lfe_def_header_var
    add w24, w24, #1                    // the '$' belongs to the name
    mov w26, #1
    b 8f
7:
    // not followed by '$' (string) or '(' (array)
    cmp w0, #'$'
    b.eq Lfe_def_header_var
    cmp w0, #'('
    b.eq Lfe_def_header_var
8:
    // parameters must be distinct (X and X$ are distinct)
    mov x9, #0
4:
    cmp w9, w22
    b.hs 5f
    ldr w10, [x19, x9, lsl #2]
    cmp w10, w23
    b.ne 9f
    lsr w11, w25, w9
    and w11, w11, #1                    // kind of parameter i
    cmp w11, w26
    b.eq Lfe_def_header_var
9:
    add x9, x9, #1
    b 4b
5:
    str w23, [x19, x22, lsl #2]
    lsl w9, w26, w22
    orr w25, w25, w9                    // FNK_SPARAM0 << k for X$
    add w22, w22, #1
    mov w0, w24
    bl _fe_advance
    // ',' -> next parameter, ')' -> end of the list
    mov w0, #0
    bl _fe_peek
    cmp w0, #','
    b.ne 6f
    mov w0, #1
    bl _fe_advance
    b Lfe_def_header_param
6:
    cmp w0, #')'
    b.ne Lfe_def_header_format
    mov w0, #1
    bl _fe_advance
Lfe_def_header_tail:
    // '=' -> single-line, end of line -> multi-line
    mov w0, #0
    bl _fe_peek
    mov w24, #FE_DEF_MULTI
    cmp w0, #FE_PEEK_EOL
    b.eq Lfe_def_header_ok
    cmp w0, #'='
    b.ne Lfe_def_header_format
    mov w0, #1
    bl _fe_advance
    mov w24, #FE_DEF_SINGLE
Lfe_def_header_ok:
    mov w0, #ERR_NONE
    b Lfe_def_header_ret
Lfe_def_header_dup:
    mov w0, #ERR_DUPLICATE_FUNCTION
    b Lfe_def_header_ret
Lfe_def_header_var:
    mov w0, #ERR_ILLEGAL_VARIABLE
    b Lfe_def_header_ret
Lfe_def_header_format:
    mov w0, #ERR_INCORRECT_FORMAT
Lfe_def_header_ret:
    mov w1, w21
    mov w2, w24
    mov w3, w22
    mov w4, w25
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #80
    ret

// ---------------------------------------------------------------------
// _fe_def -- the DEF statement (phase 2).
//   Inside a multi-line body: NESTED DEF. Otherwise the header is parsed
//   (errors reported) and the letter recorded as DEFined with its
//   parameter count. A single-line DEF creates function 1+x
//   (_ir_func_begin, _ir_func_set FUNC_KIND_FN) and lowers its expression
//   into it, followed by `ret`. A multi-line header (its function was
//   created by the pre-scan) lowers to `jmp @m` in main, m = the first line
//   after its FNEND (IR.md 4.4).
//   in:  scanner after "DEF"
//   out: none
//   clobbers: x0-x17, d0-d7
//   Fifth Edition: the FNK_* bits are recorded (_fe_fn_kinds) and, for a
//   single-line function, published (_ir_set_fnkind); a string function's
//   body is a string expression (a number there is MISMATCHED STRING
//   OPERATION), lowered followed by `sret tS`.
//   callee-saved: w19 = letter, w20 = header kind, w21 = parameter count,
//        x22 = Function* / line index, w23 = FNK_* bits
//   frame: 96 bytes (frame record, x19-x24, 32-byte parameter buffer at
//        sp+48)
// ---------------------------------------------------------------------
    .globl _fe_def
    .p2align 2
_fe_def:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #80]
    // no DEF inside a multi-line body
    adrp x9, _fe_ctx_kind@PAGE
    ldr w9, [x9, _fe_ctx_kind@PAGEOFF]
    cmp w9, #FE_CTX_ML
    b.ne 1f
    mov w0, #ERR_NESTED_DEF
    bl _fe_err
1:
    mov w0, #FE_HDR_COMPILE
    add x1, sp, #48
    bl _fe_def_header
    cbz w0, 2f
    bl _fe_err                          // the header's first error
2:
    mov w19, w1
    mov w20, w2
    mov w21, w3
    mov w23, w4
    FE_ADR x9, _fe_fn_kinds
    str w23, [x9, x19, lsl #2]
    // the letter is DEFined here, with this many parameters
    adrp x9, _fe_line@PAGE
    ldr w10, [x9, _fe_line@PAGEOFF]
    FE_ADR x9, _fe_fn_defline
    str w10, [x9, x19, lsl #2]
    FE_ADR x9, _fe_fn_nparams
    str w21, [x9, x19, lsl #2]
    cmp w20, #FE_DEF_SINGLE
    b.ne Lfe_def_multi

    // ---- single-line: function 1+x with the expression as its body ----
    mov w9, #IR_NONE
    cbz w21, 3f
    ldr w9, [sp, #48]                   // first parameter slot
3:
    adrp x10, _fe_module@PAGE
    ldr x0, [x10, _fe_module@PAGEOFF]
    add w1, w19, #FUNC_FN_BASE
    mov w2, w9
    adrp x10, _fe_line@PAGE
    ldr w3, [x10, _fe_line@PAGEOFF]
    bl _ir_func_begin
    mov x22, x0
    mov x0, x22
    mov w1, #FUNC_KIND_FN
    mov w2, w21
    add x3, sp, #48
    mov w4, #0
    bl _ir_func_set
    adrp x9, _fe_curfn@PAGE
    str x22, [x9, _fe_curfn@PAGEOFF]
    cbz w23, 5f
    adrp x9, _fe_module@PAGE
    ldr x0, [x9, _fe_module@PAGEOFF]
    add w1, w19, #FUNC_FN_BASE
    mov w2, w23
    bl _ir_set_fnkind
5:
    adrp x9, _fe_ctx_skinds@PAGE
    str w23, [x9, _fe_ctx_skinds@PAGEOFF]
    // the expression sees the parameters as `param k` / `sparam k`
    adrp x9, _fe_ctx_letter@PAGE
    str w19, [x9, _fe_ctx_letter@PAGEOFF]
    adrp x9, _fe_ctx_nparams@PAGE
    str w21, [x9, _fe_ctx_nparams@PAGEOFF]
    FE_ADR x9, _fe_ctx_params
    ldp x10, x11, [sp, #48]
    stp x10, x11, [x9]
    ldp x10, x11, [sp, #64]
    stp x10, x11, [x9, #16]
    adrp x9, _fe_ctx_kind@PAGE
    mov w10, #FE_CTX_SL
    str w10, [x9, _fe_ctx_kind@PAGEOFF]
    mov w24, #OP_RET
    tst w23, #FNK_STRING
    b.eq 6f
    // a string function: s; sret tS
    bl _fe_sexpr_need
    mov w22, w0
    bl _fe_sref_end
    mov w24, #OP_SRET
    b 7f
6:
    bl _fe_expr
    mov w22, w0
7:
    bl _fe_expect_eol
    // ret te / sret tS
    mov w1, w22
    mov w2, #IR_NONE
    mov w3, #IR_NONE
    mov w4, #IR_NONE
    mov x5, #0
    mov w6, #REL_NONE
    mov w0, w24
    bl _fe_emit
    // back to main
    adrp x9, _fe_ctx_kind@PAGE
    str wzr, [x9, _fe_ctx_kind@PAGEOFF]
    adrp x9, _fe_ctx_skinds@PAGE
    str wzr, [x9, _fe_ctx_skinds@PAGEOFF]
    adrp x9, _fe_main@PAGE
    ldr x10, [x9, _fe_main@PAGEOFF]
    adrp x9, _fe_curfn@PAGE
    str x10, [x9, _fe_curfn@PAGEOFF]
    b Lfe_def_ret

Lfe_def_multi:
    // ---- multi-line header: main skips the body -----------------------
    FE_ADR x9, _fe_ml_fn
    ldr x10, [x9, x19, lsl #3]
    cbnz x10, 4f
    // the pre-scan classifies headers with the same parser: unreachable
    FE_ADR x0, Lfe_def_m_prescan
    bl _drv_fatal
4:
    FE_ADR x9, _fe_ml_endidx
    ldr w22, [x9, x19, lsl #2]
    add w22, w22, #1                    // the first line after its FNEND
    adrp x9, _fe_nlines@PAGE
    ldr w9, [x9, _fe_nlines@PAGEOFF]
    cmp w22, w9
    b.hs Lfe_def_ret                    // never closed: UNFINISHED DEF follows
    adrp x9, _fe_linelab@PAGE
    ldr x9, [x9, _fe_linelab@PAGEOFF]
    ldr w4, [x9, x22, lsl #2]           // its label in main
    mov w0, #OP_JMP
    mov w1, #IR_NONE
    mov w2, #IR_NONE
    mov w3, #IR_NONE
    mov x5, #0
    mov w6, #REL_NONE
    bl _fe_emit
Lfe_def_ret:
    ldp x23, x24, [sp, #80]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret

// ---------------------------------------------------------------------
// _fe_fnend -- FNEND (LANGUAGE.md 7.10): only as the last line of a
//   multi-line body (else ILLEGAL INSTRUCTION); nothing may follow; a FOR
//   of the body still open -> UNFINISHED DEF at this line. Lowering:
//   `tN = ldfv; ret tN`; for a string function `tN = sfv; sret tN`.
//   in:  scanner after "FNEND"
//   out: none
//   clobbers: x0-x17
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .globl _fe_fnend
    .p2align 2
_fe_fnend:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x9, _fe_ctx_kind@PAGE
    ldr w9, [x9, _fe_ctx_kind@PAGEOFF]
    cmp w9, #FE_CTX_ML
    b.eq 1f
    mov w0, #ERR_ILLEGAL_INSTRUCTION
    bl _fe_err
1:
    bl _fe_expect_eol
    // every FOR of the body must be closed
    adrp x9, _fe_forsp@PAGE
    ldr w9, [x9, _fe_forsp@PAGEOFF]
    adrp x10, _fe_forbase@PAGE
    ldr w10, [x10, _fe_forbase@PAGEOFF]
    cmp w9, w10
    b.ls 2f
    mov w0, #ERR_UNFINISHED_DEF
    bl _fe_err
2:
    adrp x9, _fe_ctx_skinds@PAGE
    ldr w9, [x9, _fe_ctx_skinds@PAGEOFF]
    tst w9, #FNK_STRING
    b.eq 3f
    // tN = sfv ; sret tN
    mov w0, #OP_SFV
    mov w1, #IR_NONE
    mov w2, #IR_NONE
    mov w3, #IR_NONE
    mov w4, #IR_NONE
    mov x5, #0
    mov w6, #REL_NONE
    bl _fe_emit_new
    mov w1, w0
    mov w0, #OP_SRET
    b 4f
3:
    // tN = ldfv ; ret tN
    mov w0, #OP_LDFV
    mov w1, #IR_NONE
    mov w2, #IR_NONE
    mov w3, #IR_NONE
    mov w4, #IR_NONE
    mov x5, #0
    mov w6, #REL_NONE
    bl _fe_emit_new
    mov w1, w0
    mov w0, #OP_RET
4:
    mov w2, #IR_NONE
    mov w3, #IR_NONE
    mov w4, #IR_NONE
    mov x5, #0
    mov w6, #REL_NONE
    bl _fe_emit
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// _fe_param_index -- is a scalar slot a parameter of the function whose
//   expression or body is being lowered?
//   in:  w0 = scalar slot
//   out: w0 = parameter index k, or -1 (not in a DEF, or not a numeric
//        parameter: a string parameter X$ has the same slot number as X)
//   clobbers: x0, x9-x13   leaf, no frame
// ---------------------------------------------------------------------
    .globl _fe_param_index
    .p2align 2
_fe_param_index:
    adrp x9, _fe_ctx_kind@PAGE
    ldr w9, [x9, _fe_ctx_kind@PAGEOFF]
    cbz w9, Lfe_param_index_none
    adrp x9, _fe_ctx_nparams@PAGE
    ldr w10, [x9, _fe_ctx_nparams@PAGEOFF]
    adrp x9, _fe_ctx_skinds@PAGE
    ldr w13, [x9, _fe_ctx_skinds@PAGEOFF]
    FE_ADR x11, _fe_ctx_params
    mov w9, #0
1:
    cmp w9, w10
    b.hs Lfe_param_index_none
    lsr w12, w13, w9
    tbnz w12, #0, 3f                    // a string parameter
    ldr w12, [x11, x9, lsl #2]
    cmp w12, w0
    b.eq 2f
3:
    add w9, w9, #1
    b 1b
2:
    mov w0, w9
    ret
Lfe_param_index_none:
    mov w0, #-1
    ret

// ---------------------------------------------------------------------
// _fe_record_call -- remember the first line with a call of FN letter
//   with this many arguments (more than eight share one record), for the
//   phase-3 INCORRECT NUMBER OF ARGUMENTS check.
//   in:  w0 = letter, w1 = argument count
//   out: none
//   clobbers: x9-x12   leaf, no frame
// ---------------------------------------------------------------------
    .globl _fe_record_call
    .p2align 2
_fe_record_call:
    cmp w1, #(FE_ARGC_SLOTS - 1)
    mov w9, #(FE_ARGC_SLOTS - 1)
    csel w9, w1, w9, lo                 // min(count, 9)
    mov w10, #FE_ARGC_SLOTS
    madd w9, w0, w10, w9                // letter * 10 + slot
    FE_ADR x10, _fe_fn_argline
    ldr w11, [x10, x9, lsl #2]
    cbnz w11, 1f                        // keep the first (lowest) line
    adrp x12, _fe_line@PAGE
    ldr w12, [x12, _fe_line@PAGEOFF]
    str w12, [x10, x9, lsl #2]
1:
    ret

// ---------------------------------------------------------------------
// _fe_check_fns -- phase-3 function checks (LANGUAGE.md 10.1).
//   UNDEFINED FUNCTION: among letters referenced but never DEFined, the
//   one whose first reference has the lowest line (references are
//   recorded in ascending line order, so the first one is the minimum).
//   INCORRECT NUMBER OF ARGUMENTS: the lowest line of a call whose
//   argument count differs from its DEF's parameter count.
//   MISMATCHED STRING OPERATION (Fifth Edition): _fe_check_kinds.
//   RECURSIVE FUNCTION: lowest letter A..Z that can reach itself through
//   the call graph (bit masks in _fe_fn_calls), reported at its DEF line.
//   in: none   out: returns only if all checks pass
//   clobbers: x0-x17
//   callee-saved: x19 = &_fe_fn_defline, x20 = &_fe_fn_ref,
//        x21 = &_fe_fn_calls, x22 = letter
//   frame: 48 bytes
// ---------------------------------------------------------------------
    .globl _fe_check_fns
    .p2align 2
_fe_check_fns:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    FE_ADR x19, _fe_fn_defline
    FE_ADR x20, _fe_fn_ref
    FE_ADR x21, _fe_fn_calls
    // --- undefined functions: minimum first-reference line -----------
    mov w1, #0                          // best line so far (0 = none)
    mov w22, #0
Lfe_check_fns_undef_loop:
    cmp w22, #NUM_LETTERS
    b.hs Lfe_check_fns_undef_done
    ldr w9, [x19, x22, lsl #2]          // DEF line (0 = never defined)
    cbnz w9, 1f
    ldr w10, [x20, x22, lsl #2]         // first reference line (0 = none)
    cbz w10, 1f
    // keep the smallest reference line
    cbz w1, 2f
    cmp w10, w1
    b.hs 1f
2:
    mov w1, w10
1:
    add w22, w22, #1
    b Lfe_check_fns_undef_loop
Lfe_check_fns_undef_done:
    cbz w1, Lfe_check_fns_args
    mov w0, #ERR_UNDEFINED_FUNCTION
    bl _fe_fail
Lfe_check_fns_args:
    // --- argument counts: minimum line of a mismatching call ---------
    mov w1, #0
    FE_ADR x11, _fe_fn_nparams
    FE_ADR x12, _fe_fn_argline
    mov w22, #0
Lfe_check_fns_args_letter:
    cmp w22, #NUM_LETTERS
    b.hs Lfe_check_fns_args_done
    ldr w9, [x19, x22, lsl #2]
    cbz w9, Lfe_check_fns_args_next     // not defined: never called (checked above)
    ldr w13, [x11, x22, lsl #2]         // its parameter count
    mov w14, #FE_ARGC_SLOTS
    mul w14, w22, w14                   // first record of this letter
    mov w15, #0                         // argument count slot
Lfe_check_fns_args_slot:
    cmp w15, w13
    b.eq 3f                             // the right count
    add w16, w14, w15
    ldr w10, [x12, x16, lsl #2]
    cbz w10, 3f                         // no such call
    cbz w1, 4f
    cmp w10, w1
    b.hs 3f
4:
    mov w1, w10
3:
    add w15, w15, #1
    cmp w15, #FE_ARGC_SLOTS
    b.lo Lfe_check_fns_args_slot
Lfe_check_fns_args_next:
    add w22, w22, #1
    b Lfe_check_fns_args_letter
Lfe_check_fns_args_done:
    cbz w1, Lfe_check_fns_kinds
    mov w0, #ERR_WRONG_NUM_ARGS
    bl _fe_fail
Lfe_check_fns_kinds:
    // MISMATCHED STRING OPERATION: a call of the wrong kind (fe_sexpr.s)
    bl _fe_check_kinds
Lfe_check_fns_rec_start:
    // --- recursion: transitive closure of each letter's callee set ---
    mov w22, #0
Lfe_check_fns_rec_loop:
    cmp w22, #NUM_LETTERS
    b.hs Lfe_check_fns_rec_done
    ldr w9, [x19, x22, lsl #2]
    cbz w9, Lfe_check_fns_rec_next      // not defined: nothing to check
    ldr w10, [x21, x22, lsl #2]         // reach set = direct callees
Lfe_check_fns_rec_grow:
    // one expansion step: union of callees of every letter in the set
    mov w11, w10
    mov w12, #0                         // letter b
Lfe_check_fns_rec_union:
    lsr w13, w10, w12
    tbz w13, #0, 1f
    ldr w14, [x21, x12, lsl #2]
    orr w11, w11, w14
1:
    add w12, w12, #1
    cmp w12, #NUM_LETTERS
    b.lo Lfe_check_fns_rec_union
    cmp w11, w10
    mov w10, w11
    b.ne Lfe_check_fns_rec_grow         // repeat until the set is stable
    // can the letter reach itself?
    lsr w13, w10, w22
    tbz w13, #0, Lfe_check_fns_rec_next
    mov w0, #ERR_RECURSIVE_FUNCTION
    ldr w1, [x19, x22, lsl #2]          // reported at its DEF line
    bl _fe_fail
Lfe_check_fns_rec_next:
    add w22, w22, #1
    b Lfe_check_fns_rec_loop
Lfe_check_fns_rec_done:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

    .section __TEXT,__cstring,cstring_literals
Lfe_def_m_prescan:
    .asciz "frontend: multi-line DEF header without a pre-scanned function"
