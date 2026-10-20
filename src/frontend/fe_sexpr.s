// =====================================================================
// src/frontend/fe_sexpr.s -- Fifth Edition string expressions
// (LANGUAGE.md 4.4-4.6, 5.2, 6.1, 7.10.1; IR.md 3.3, 4.1-4.4).
//
//   _fe_sexpr_try() -> w0 sref temp or -1, w1 = 1 if a private cell
//   _fe_sexpr_need() -> w0 sref temp                 one is required
//   _fe_sexpr_starts() -> w0 1 if a string expression starts here
//   _fe_call(w0=letter, w1=1 for FNx$) -> w0 result  "FNx(" / "FNx$(" args
//   _fe_sarr_subscripts(w0=letter) -> w0 i, w1 j or IR_NONE, w2 dims
//   _fe_sarray_use2(w0=letter, w1=dims)              string list / table use
//   _fe_sparam_index(w0=string slot) -> w0 k or -1   a string parameter?
//   _fe_new_scell() -> w0 sref temp                  `tC = scell %sK`
//   _fe_record_kind(w0=letter, w1=FNK_* signature)   log a call
//   _fe_kinds_line() -> w0 line or 0                 phase-3 kind check
//
// A string expression is a string reference ("..." -> `slit`, V$ ->
// `svar` or `sparam k`, L$(i) -> `sald1`, T$(i, j) -> `sald2`), STR$(e)
// (a new temp cell: `scell`, `sstr`), the value variable FNx$ inside the
// multi-line body of FNx$ (`sfv`), or a call of a string function FNx$
// (a new temp cell, `scallfn`). The results of STR$ and of string calls
// are private cells: a string argument that is one of them is passed as
// it is, any other string argument is copied into a new cell first
// (IR.md 4.2). Every FN call is logged with its kind signature (FNK_STRING
// for a call of FNx$, bit k for a string argument k) for the phase-3
// MISMATCHED STRING OPERATION check of LANGUAGE.md 7.10.1 / 10.1.
// Sixth Edition (LANGUAGE.md 4.6, 6.2; IR.md 4.2): SEG$(s, m, n) is a
// string primary (a new cell: `sseg`), and a string expression is a chain
// of primaries joined by '&': the first primary's cell (a result
// expression) or a new cell holding its copy, then `scat` per operand.
// Cells are allocated in the current program unit (_fe_unit).
// =====================================================================
.include "baysick.inc"

.equ FE_CTX_ML,         2           // _fe_ctx_kind of a multi-line body (fe_def.s)
.equ FE_KIND_ENTRY,     8           // call log entry: u32 line, u16 sig, u16 letter
.equ FE_KIND_INITIAL,   256         // first capacity of the call log
// token classes (Lfe_sexpr_tkclass)
.equ FE_TKC_OTHER,      0           // ends nothing / cannot start a value
.equ FE_TKC_NUMERIC,    1           // starts a numeric operand
.equ FE_TKC_STRING,     2           // starts a string expression

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

// FE_UNITMOD reg: reg = the Module* of the current program unit (Sixth
// Edition: _fe_unit, the main module or a SUB unit; else _fe_module).
.macro FE_UNITMOD reg
    adrp \reg, _fe_unit@PAGE
    ldr \reg, [\reg, _fe_unit@PAGEOFF]
.endm

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _fe_sexpr_try -- if a string expression starts here, parse and lower
//   it (LANGUAGE.md 4.6, 5.2 last paragraph). An unterminated string
//   constant is INCORRECT FORMAT.
//   in:  scanner at operand position
//   out: w0 = sref temp ("its string reference"), or -1 with the scanner
//        unchanged; w1 = 1 if the reference is a fresh private temp cell
//        (the result of STR$ or of a string function call), else 0
//   clobbers: x0-x17, d0-d7
//   callee-saved: x19 = start position, w20 = letter / slot, w21 = temp,
//        w22 = second temp
//   frame: 96 bytes (frame record, x19-x22, 40-byte token at sp+48)
// ---------------------------------------------------------------------
    .globl _fe_sexpr_try
    .p2align 2
_fe_sexpr_try:
// Sixth Edition: string-expression := string-primary { "&" string-primary }
//   (LANGUAGE.md 4.6, IR.md 4.2). The first primary's reference is the
//   result cell if it is a private cell (a result expression), else it is
//   copied into a new cell (`tC = scell %sK`, `sset tC, t1`); every
//   further primary is appended with `scat tC, ti`. After '&' a primary
//   is required (Lfe_sexpr_primary_need).
//   in/out/clobbers: as above
//   callee-saved: w19 = result reference, w20 = 1 if it is a private cell,
//        x21 = position before the operator token, w22 = primary temp
//   frame: 48 bytes
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    bl Lfe_sexpr_primary
    tbnz w0, #31, Lfe_sexpr_cat_ret     // no string expression here
    mov w19, w0
    mov w20, w1
Lfe_sexpr_cat_loop:
    // operator position after a string primary: '&' continues it
    bl _fe_getpos
    mov x21, x0
    bl _fe_next_op
    cmp w0, #TK_AMP
    b.ne Lfe_sexpr_cat_done
    cbnz w20, 1f
    // a shared first operand: its value goes into a new result cell
    bl _fe_new_scell
    mov w22, w0
    FE_NONE
    mov w1, w22
    mov w2, w19
    mov w0, #OP_SSET
    bl _fe_emit
    mov w19, w22
    mov w20, #1
1:
    // the next primary, appended to the result cell
    bl Lfe_sexpr_primary_need
    mov w22, w0
    FE_NONE
    mov w1, w19
    mov w2, w22
    mov w0, #OP_SCAT
    bl _fe_emit
    b Lfe_sexpr_cat_loop
Lfe_sexpr_cat_done:
    // not '&': hand the token back
    mov x0, x21
    bl _fe_setpos
    mov w0, w19
    mov w1, w20
Lfe_sexpr_cat_ret:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// Lfe_sexpr_primary_need -- a string primary is required after '&'
//   (LANGUAGE.md 4.5): a numeric operand there is MISMATCHED STRING
//   OPERATION, anything else ILLEGAL FORMULA (Lfe_sexpr_classify).
//   in:  scanner at operand position
//   out: w0 = sref temp of the primary
//   clobbers: x0-x17, d0-d7
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_sexpr_primary_need:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl Lfe_sexpr_primary
    tbz w0, #31, 1f
    bl Lfe_sexpr_classify               // does not return
1:
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Lfe_sexpr_primary -- one string primary (the Fifth Edition string
//   expression, plus SEG$): see _fe_sexpr_try above for in/out.
//   clobbers: x0-x17, d0-d7
//   callee-saved: x19 = start position, w20 = letter / slot, w21 = temp,
//        w22 = second temp
//   frame: 96 bytes (frame record, x19-x22, 40-byte token at sp+48)
// ---------------------------------------------------------------------
    .p2align 2
Lfe_sexpr_primary:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    bl _fe_getpos
    mov x19, x0
    mov w0, #SCAN_OPERAND
    add x1, sp, #48
    bl _fe_scan
    cmp w0, #TK_STRING
    b.eq Lfe_sexpr_try_const
    cmp w0, #TK_SVAR
    b.eq Lfe_sexpr_try_svar
    cmp w0, #TK_SARRAY
    b.eq Lfe_sexpr_try_sarray
    cmp w0, #TK_BUILTIN
    b.eq Lfe_sexpr_try_builtin
    cmp w0, #TK_SFN0
    b.eq Lfe_sexpr_try_sfn0
    cmp w0, #TK_SFN
    b.eq Lfe_sexpr_try_sfn
    cmp w0, #TK_BAD
    b.ne Lfe_sexpr_try_none
    ldr x9, [sp, #(48 + TOK_PTR)]
    ldrb w9, [x9]
    cmp w9, #'"'
    b.ne Lfe_sexpr_try_none
    mov w0, #ERR_INCORRECT_FORMAT       // unterminated string constant
    bl _fe_err
Lfe_sexpr_try_none:
    mov x0, x19
    bl _fe_setpos
    mov w0, #-1
    mov w1, #0
    b Lfe_sexpr_try_ret

Lfe_sexpr_try_const:
    // tN = slit sK (the constant counts toward TOO MANY LABELS)
    ldr x0, [sp, #(48 + TOK_PTR)]
    ldr w1, [sp, #(48 + TOK_LEN)]
    bl _fe_add_label
    mov w9, w0
    FE_NONE
    mov w4, w9
    mov w0, #OP_SLIT
    bl _fe_emit_new
    b Lfe_sexpr_try_shared

Lfe_sexpr_try_svar:
    // a string parameter of the enclosing DEF: tN = sparam k; else svar
    ldr w20, [sp, #(48 + TOK_SLOT)]
    mov w0, w20
    bl _fe_sparam_index
    tbnz w0, #31, 1f
    mov w9, w0
    FE_NONE
    mov x5, x9                          // IMM = parameter index k
    mov w0, #OP_SPARAM
    bl _fe_emit_new
    b Lfe_sexpr_try_shared
1:
    FE_NONE
    mov w4, w20
    mov w0, #OP_SVAR
    bl _fe_emit_new
    b Lfe_sexpr_try_shared

Lfe_sexpr_try_sarray:
    // L$(i): i; sald1 L$, ti -- T$(i, j): i; j; sald2 T$, ti, tj
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
    b.eq 2f
    mov w2, w22
    mov w0, #OP_SALD2
2:
    bl _fe_emit_new
    b Lfe_sexpr_try_shared

Lfe_sexpr_try_builtin:
    // only STR$( is a string expression (LEN, ASC, VAL ... are numbers)
    ldr w9, [sp, #(48 + TOK_INDEX)]
    cmp w9, #BI_STR
    b.eq 1f
    cmp w9, #BI_SEG                     // Sixth Edition: SEG$(
    b.eq Lfe_sexpr_try_seg
    b Lfe_sexpr_try_none
1:
    b.ne Lfe_sexpr_try_none
    ldr w9, [sp, #(48 + TOK_LEN)]
    cmp w9, #5
    b.ne Lfe_sexpr_try_none
    // e; tC = scell %sK; sstr tC, te
    bl _fe_paren_open
    bl _fe_expr
    mov w21, w0
    bl _fe_paren_close
    bl _fe_new_scell
    mov w22, w0
    FE_NONE
    mov w1, w22
    mov w2, w21
    mov w0, #OP_SSTR
    bl _fe_emit
    mov w0, w22
    b Lfe_sexpr_try_private

Lfe_sexpr_try_seg:
    // SEG$(s, m, n) (LANGUAGE.md 6.2, IR.md 4.2): s's string reference, m,
    // n, then `tC = sseg %sK, tS, tm, tn` (a new cell). A number for s or
    // an arithmetic operator after it is MISMATCHED STRING OPERATION; a
    // missing ',' or ')' ILLEGAL FORMULA.
    bl _fe_paren_open
    bl _fe_sexpr_need
    mov w21, w0                         // tS
    bl _fe_sref_end
    mov w0, #TK_COMMA
    mov w1, #ERR_ILLEGAL_FORMULA
    bl _fe_expect_op
    bl _fe_expr
    mov w22, w0                         // tm
    mov w0, #TK_COMMA
    mov w1, #ERR_ILLEGAL_FORMULA
    bl _fe_expect_op
    bl _fe_expr
    mov w20, w0                         // tn
    bl _fe_paren_close
    // a new cell of the current program unit
    FE_UNITMOD x0
    bl _ir_new_stemp
    mov w9, w0
    FE_NONE
    mov w4, w9                          // X = the new cell
    mov w1, w21
    mov w2, w22
    mov w3, w20
    mov w0, #OP_SSEG
    bl _fe_emit_new
    b Lfe_sexpr_try_private

Lfe_sexpr_try_sfn0:
    // FNx$ without '(': the value variable inside FNx$'s own multi-line
    // body, else a call without arguments
    ldr w20, [sp, #(48 + TOK_INDEX)]
    adrp x9, _fe_ctx_kind@PAGE
    ldr w9, [x9, _fe_ctx_kind@PAGEOFF]
    cmp w9, #FE_CTX_ML
    b.ne 3f
    adrp x9, _fe_ctx_letter@PAGE
    ldr w9, [x9, _fe_ctx_letter@PAGEOFF]
    cmp w9, w20
    b.ne 3f
    adrp x9, _fe_ctx_skinds@PAGE
    ldr w9, [x9, _fe_ctx_skinds@PAGEOFF]
    tst w9, #FNK_STRING
    b.eq 3f
    FE_NONE
    mov w0, #OP_SFV
    bl _fe_emit_new
    b Lfe_sexpr_try_shared
3:
    // tC = scell %sK; scallfn tC, FNx
    mov w0, w20
    bl _fe_note_fn_ref
    mov w0, w20
    mov w1, #0
    bl _fe_record_call
    mov w0, w20
    mov w1, #FNK_STRING
    bl _fe_record_kind
    bl _fe_new_scell
    mov w22, w0
    FE_NONE
    mov w2, w22                         // B = the result cell
    mov w4, w20                         // X = function letter
    mov w0, #OP_SCALLFN                 // A = IR_NONE: no arguments
    bl _fe_emit
    mov w0, w22
    b Lfe_sexpr_try_private

Lfe_sexpr_try_sfn:
    // FNx$( a0, ... ): the call with its arguments
    ldr w0, [sp, #(48 + TOK_INDEX)]
    mov w1, #1
    bl _fe_call
    b Lfe_sexpr_try_private

Lfe_sexpr_try_shared:
    mov w1, #0                          // a reference others may change
    b Lfe_sexpr_try_ret
Lfe_sexpr_try_private:
    mov w1, #1                          // a fresh cell nobody else uses
Lfe_sexpr_try_ret:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret

// ---------------------------------------------------------------------
// _fe_sexpr_need -- a string expression is required here (LANGUAGE.md
//   5.2 last paragraph): anything else is MISMATCHED STRING OPERATION if
//   it starts a numeric operand, else ILLEGAL FORMULA (also at the end of
//   the line, as for a missing value, 7.1).
//   in:  scanner at operand position
//   out: w0 = sref temp
//   clobbers: x0-x17, d0-d7
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .globl _fe_sexpr_need
    .p2align 2
_fe_sexpr_need:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl _fe_sexpr_try
    tbz w0, #31, 1f
    bl Lfe_sexpr_classify               // does not return
1:
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Lfe_sexpr_classify -- no string expression where one is required:
//   report what is there instead (LANGUAGE.md 5.2): MISMATCHED STRING
//   OPERATION if it starts a numeric operand, ILLEGAL VARIABLE for a
//   letter+digit+"$(" name, else ILLEGAL FORMULA.
//   in:  scanner at operand position   out: does not return
//   clobbers: x0-x17, d0-d7
//   callee-saved: none used
//   frame: 64 bytes (frame record, 40-byte token at sp+16)
// ---------------------------------------------------------------------
    .p2align 2
Lfe_sexpr_classify:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    mov w0, #SCAN_OPERAND
    add x1, sp, #16
    bl _fe_scan
    cmp w0, #TK_BAD
    b.eq 2f
    FE_ADR x9, Lfe_sexpr_tkclass
    ldrb w9, [x9, w0, uxtw]
    mov w0, #ERR_ILLEGAL_FORMULA
    cmp w9, #FE_TKC_NUMERIC
    b.ne 1f
    mov w0, #ERR_MISMATCHED_STRING
1:
    bl _fe_err
2:
    // a malformed operand: a letter+digit+"$(" name is ILLEGAL VARIABLE
    // (4.4); else numeric if it starts with a digit, '.' or a letter (bad
    // constant, X1(, NUM( ...), else not an operand at all
    ldr w9, [sp, #(16 + TOK_ERR)]
    cmp w9, #ERR_ILLEGAL_VARIABLE
    b.ne 3f
    mov w0, #ERR_ILLEGAL_VARIABLE
    b 1b
3:
    ldr x9, [sp, #(16 + TOK_PTR)]
    ldrb w9, [x9]
    mov w0, #ERR_MISMATCHED_STRING
    sub w10, w9, #'0'
    cmp w10, #9
    b.ls 1b
    cmp w9, #'.'
    b.eq 1b
    sub w10, w9, #'A'
    cmp w10, #25
    b.ls 1b
    mov w0, #ERR_ILLEGAL_FORMULA
    b 1b

// ---------------------------------------------------------------------
// _fe_sexpr_starts -- does a string expression start at the scanner
//   position (LANGUAGE.md 5.2: '"', STR$(, FN letter $, letter [digit] $;
//   an unterminated '"' counts)? Nothing is consumed or emitted.
//   in:  none
//   out: w0 = 1 if so, else 0
//   clobbers: x0-x17, d0-d7
//   callee-saved: x19 = position
//   frame: 64 bytes (frame record, x19, 40-byte token at sp+24)
// ---------------------------------------------------------------------
    .globl _fe_sexpr_starts
    .p2align 2
_fe_sexpr_starts:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    str x19, [sp, #16]
    bl _fe_getpos
    mov x19, x0
    mov w0, #SCAN_OPERAND
    add x1, sp, #24
    bl _fe_scan
    mov w10, w0
    mov x0, x19
    bl _fe_setpos
    mov w0, #1
    cmp w10, #TK_BUILTIN
    b.eq 2f
    cmp w10, #TK_BAD
    b.eq 3f
    // by token class
    FE_ADR x9, Lfe_sexpr_tkclass
    ldrb w9, [x9, w10, uxtw]
    cmp w9, #FE_TKC_STRING
    cset w0, eq
    b 1f
2:
    // STR$( only
    ldr w9, [sp, #(24 + TOK_INDEX)]
    cmp w9, #BI_STR
    b.eq 4f
    cmp w9, #BI_SEG                     // Sixth Edition: SEG$( too
4:
    cset w0, eq
    b 1f
3:
    // an unterminated string constant
    ldr x9, [sp, #(24 + TOK_PTR)]
    ldrb w9, [x9]
    cmp w9, #'"'
    cset w0, eq
1:
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

// ---------------------------------------------------------------------
// _fe_call -- a user function call whose "FNx(" or "FNx$(" the scanner
//   already consumed (LANGUAGE.md 7.10, 7.10.1; IR.md 4.2). Each argument
//   is a string expression if its text starts like one, else a numeric
//   expression; a string argument followed by an arithmetic operator is
//   MISMATCHED STRING OPERATION; anything but ',' or ')' after an
//   argument is ILLEGAL FORMULA. A string argument that is not a private
//   cell is copied into a new one (`tC = scell %sK`, `sset tC, tR`).
//   Then: numeric call: `fnarg 1, t1` ... `fnarg k, tk`, `tN = callfn FNx,
//   t0`; string call: `tC = scell %sK`, the fnargs, `scallfn tC, FNx, t0`.
//   The count (INCORRECT NUMBER OF ARGUMENTS) and the kind signature
//   (FNK_STRING for FNx$, bit k for a string argument k) are logged for
//   phase 3; more than eight arguments never match a DEF, so only the
//   first eight temps are kept.
//   in:  w0 = letter, w1 = 1 for a string function FNx$, else 0
//   out: w0 = the result temp (numeric) or the result cell's sref
//   clobbers: x0-x17, d0-d7
//   callee-saved: w19 = letter, w20 = argument count, w21 = kind bits,
//        w22 = 1 for a string call, w23 = result cell / fnarg index,
//        w24 = argument temp
//   frame: 96 bytes (frame record, x19-x24, 8 u32 argument temps at sp+64)
// ---------------------------------------------------------------------
    .globl _fe_call
    .p2align 2
_fe_call:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    mov w19, w0
    mov w22, w1
    bl _fe_note_fn_ref
    bl _fe_paren_open
    mov w20, #0
    mov w21, #0
Lfe_call_arg:
    bl _fe_sexpr_try
    tbnz w0, #31, Lfe_call_numeric
    mov w24, w0
    mov w23, w1                         // private cell?
    bl _fe_sref_end                     // FNA(A$ + 1): MISMATCHED
    cbnz w23, 1f
    // a shared reference: copy it into a new cell right away
    bl _fe_new_scell
    mov w23, w0
    FE_NONE
    mov w1, w23
    mov w2, w24
    mov w0, #OP_SSET
    bl _fe_emit
    mov w24, w23
1:
    // argument k is a string argument
    cmp w20, #LIM_FN_PARAMS
    b.hs Lfe_call_keep
    mov w9, #FNK_SPARAM0
    lsl w9, w9, w20
    orr w21, w21, w9
    b Lfe_call_keep
Lfe_call_numeric:
    bl _fe_expr
    mov w24, w0
Lfe_call_keep:
    cmp w20, #LIM_FN_PARAMS
    b.hs 2f
    add x9, sp, #64
    str w24, [x9, x20, lsl #2]
2:
    add w20, w20, #1
    bl _fe_next_op
    cmp w0, #TK_COMMA
    b.eq Lfe_call_arg
    cmp w0, #TK_RPAREN
    b.eq 3f
    mov w0, #ERR_ILLEGAL_FORMULA        // anything else before ')'
    bl _fe_err
3:
    // ')' consumed: leave the nesting level
    adrp x9, _fe_depth@PAGE
    ldr w10, [x9, _fe_depth@PAGEOFF]
    sub w10, w10, #1
    str w10, [x9, _fe_depth@PAGEOFF]
    // phase-3 records: argument count and kind signature
    mov w0, w19
    mov w1, w20
    bl _fe_record_call
    mov w1, w21
    cbz w22, 4f
    orr w1, w1, #FNK_STRING
4:
    mov w0, w19
    bl _fe_record_kind
    // a string call's result cell comes before the fnargs
    cbz w22, 5f
    bl _fe_new_scell
    mov w23, w0
5:
    // fnarg k, tk for k = 1 .. min(count, 8) - 1
    cmp w20, #LIM_FN_PARAMS
    mov w9, #LIM_FN_PARAMS
    csel w20, w20, w9, ls
    cbz w22, 6f
    // keep the result cell in w24 (the argument temps are on the stack)
    mov w24, w23
6:
    mov w23, #1
7:
    cmp w23, w20
    b.hs 8f
    add x9, sp, #64
    ldr w1, [x9, x23, lsl #2]
    mov w2, #IR_NONE
    mov w3, #IR_NONE
    mov w4, #IR_NONE
    mov w5, w23                         // IMM = argument index k
    mov w6, #REL_NONE
    mov w0, #OP_FNARG
    bl _fe_emit
    add w23, w23, #1
    b 7b
8:
    ldr w1, [sp, #64]                   // A = argument 0
    mov w3, #IR_NONE
    mov w4, w19                         // X = function letter
    mov x5, #0
    mov w6, #REL_NONE
    cbz w22, 9f
    // scallfn tC, FNx, t0
    mov w2, w24                         // B = the result cell
    mov w0, #OP_SCALLFN
    bl _fe_emit
    mov w0, w24
    b Lfe_call_ret
9:
    // tN = callfn FNx, t0
    mov w2, #IR_NONE
    mov w0, #OP_CALLFN
    bl _fe_emit_new
Lfe_call_ret:
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret

// ---------------------------------------------------------------------
// _fe_sarr_subscripts -- the subscripts "i [, j] )" of a string array
//   element after "L$(" (consumed): one '(' level; a third subscript or
//   anything else before ')' is ILLEGAL FORMULA. The letter's string
//   array is then used as a list (one subscript) or a table (two).
//   in:  w0 = letter
//   out: w0 = temp of i, w1 = temp of j or IR_NONE, w2 = dims (1 or 2)
//   clobbers: x0-x17, d0-d7
//   callee-saved: w19 = letter, w20 = i, w21 = j, w22 = dims
//   frame: 48 bytes
// ---------------------------------------------------------------------
    .globl _fe_sarr_subscripts
    .p2align 2
_fe_sarr_subscripts:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov w19, w0
    bl _fe_paren_open
    bl _fe_expr
    mov w20, w0
    mov w21, #IR_NONE
    mov w22, #1
    bl _fe_next_op
    cmp w0, #TK_RPAREN
    b.eq Lfe_sarr_subscripts_closed
    cmp w0, #TK_COMMA
    b.eq 1f
    mov w0, #ERR_ILLEGAL_FORMULA        // anything else before ')'
    bl _fe_err
1:
    // second subscript: a string table element
    bl _fe_expr
    mov w21, w0
    mov w22, #2
    mov w0, #TK_RPAREN
    mov w1, #ERR_ILLEGAL_FORMULA
    bl _fe_expect_op
Lfe_sarr_subscripts_closed:
    adrp x9, _fe_depth@PAGE
    ldr w10, [x9, _fe_depth@PAGEOFF]
    sub w10, w10, #1
    str w10, [x9, _fe_depth@PAGEOFF]
    mov w0, w19
    mov w1, w22
    bl _fe_sarray_use2
    mov w0, w20
    mov w1, w21
    mov w2, w22
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// _fe_sarray_use2 -- a use of string array `letter` as a list (dims 1) or
//   table (dims 2). The first use or DIM, in ascending line order, fixes
//   the dimensionality (default bounds 10, or 10 x 10); a conflicting
//   later one is ILLEGAL VARIABLE (LANGUAGE.md 4.4).
//   in:  w0 = letter, w1 = dims
//   out: none
//   clobbers: x0-x17
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .globl _fe_sarray_use2
    .p2align 2
_fe_sarray_use2:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    FE_ADR x9, _fe_sarrays
    add x9, x9, w0, uxtw #4             // &sarrays[letter] (16 bytes each)
    ldr w10, [x9]
    cbnz w10, 1f
    str w1, [x9]
    mov w11, #LIM_DEFAULT_BOUND
    str w11, [x9, #4]
    cmp w1, #2
    csel w11, w11, wzr, eq              // b2 = 10 for a table, 0 for a list
    str w11, [x9, #8]
    b 2f
1:
    cmp w10, w1
    b.eq 2f
    mov w0, #ERR_ILLEGAL_VARIABLE       // list/table conflict
    bl _fe_err
2:
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// _fe_sparam_index -- is a string slot a string parameter of the
//   function whose expression or body is being lowered?
//   in:  w0 = string slot
//   out: w0 = parameter index k, or -1
//   clobbers: x0, x9-x13   leaf, no frame
// ---------------------------------------------------------------------
    .globl _fe_sparam_index
    .p2align 2
_fe_sparam_index:
    adrp x9, _fe_ctx_kind@PAGE
    ldr w9, [x9, _fe_ctx_kind@PAGEOFF]
    cbz w9, Lfe_sparam_index_none
    adrp x9, _fe_ctx_nparams@PAGE
    ldr w10, [x9, _fe_ctx_nparams@PAGEOFF]
    adrp x9, _fe_ctx_skinds@PAGE
    ldr w13, [x9, _fe_ctx_skinds@PAGEOFF]
    FE_ADR x11, _fe_ctx_params
    mov w9, #0
1:
    cmp w9, w10
    b.hs Lfe_sparam_index_none
    lsr w12, w13, w9
    tbz w12, #0, 2f                     // a numeric parameter
    ldr w12, [x11, x9, lsl #2]
    cmp w12, w0
    b.eq 3f
2:
    add w9, w9, #1
    b 1b
3:
    mov w0, w9
    ret
Lfe_sparam_index_none:
    mov w0, #-1
    ret

// ---------------------------------------------------------------------
// _fe_new_scell -- allocate a new string temp cell of the module
//   (_ir_new_stemp, IR.md 4.1) and emit `tC = scell %sK`.
//   in:  none
//   out: w0 = the sref temp tC
//   clobbers: x0-x17
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .globl _fe_new_scell
    .p2align 2
_fe_new_scell:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    FE_UNITMOD x0                       // the current program unit's cells
    bl _ir_new_stemp
    mov w9, w0
    FE_NONE
    mov w4, w9                          // X = cell number
    mov w0, #OP_SCELL
    bl _fe_emit_new
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// _fe_record_kind -- append a call of FN letter with kind signature `sig`
//   at the current line to the call log (grown by doubling; the arena
//   never frees, the old block is simply abandoned).
//   in:  w0 = letter, w1 = signature (FNK_STRING | string-argument bits)
//   out: none
//   clobbers: x0-x17
//   callee-saved: w19 = letter, w20 = signature, x21 = new block,
//        w22 = new capacity
//   frame: 48 bytes
// ---------------------------------------------------------------------
    .globl _fe_record_kind
    .p2align 2
_fe_record_kind:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov w19, w0
    mov w20, w1
    adrp x9, _fe_ncalls@PAGE
    ldr w10, [x9, _fe_ncalls@PAGEOFF]
    adrp x9, _fe_capcalls@PAGE
    ldr w11, [x9, _fe_capcalls@PAGEOFF]
    cmp w10, w11
    b.lo Lfe_record_kind_store
    // full: a block of twice the capacity (FE_KIND_INITIAL at first)
    lsl w22, w11, #1
    cbnz w22, 1f
    mov w22, #FE_KIND_INITIAL
1:
    mov w0, w22
    lsl x0, x0, #3                      // FE_KIND_ENTRY bytes each
    bl _drv_alloc
    mov x21, x0
    // copy the old entries
    adrp x9, _fe_calllog@PAGE
    ldr x12, [x9, _fe_calllog@PAGEOFF]
    adrp x9, _fe_ncalls@PAGE
    ldr w10, [x9, _fe_ncalls@PAGEOFF]
    mov x13, #0
2:
    cmp x13, x10
    b.hs 3f
    ldr x14, [x12, x13, lsl #3]
    str x14, [x21, x13, lsl #3]
    add x13, x13, #1
    b 2b
3:
    adrp x9, _fe_calllog@PAGE
    str x21, [x9, _fe_calllog@PAGEOFF]
    adrp x9, _fe_capcalls@PAGE
    str w22, [x9, _fe_capcalls@PAGEOFF]
Lfe_record_kind_store:
    adrp x9, _fe_calllog@PAGE
    ldr x12, [x9, _fe_calllog@PAGEOFF]
    adrp x9, _fe_ncalls@PAGE
    ldr w10, [x9, _fe_ncalls@PAGEOFF]
    add x12, x12, x10, lsl #3           // &log[n]
    adrp x11, _fe_line@PAGE
    ldr w11, [x11, _fe_line@PAGEOFF]
    str w11, [x12]                      // +0 line
    strh w20, [x12, #4]                 // +4 signature
    strh w19, [x12, #6]                 // +6 letter
    add w10, w10, #1
    str w10, [x9, _fe_ncalls@PAGEOFF]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// _fe_kinds_line -- the phase-3 kind check (LANGUAGE.md 7.10.1, 10.1), run
//   after INCORRECT NUMBER OF ARGUMENTS (so every logged call has its
//   DEF's argument count): the first logged call of the current program
//   unit (ascending lines, a line's calls in parse order) whose signature
//   differs from its DEF's FNK_* word is MISMATCHED STRING OPERATION at
//   the call's line.
//   in: none   out: w0 = that line, or 0 if every call matches
//   clobbers: x0, x9-x17   leaf, no frame
// ---------------------------------------------------------------------
    .globl _fe_kinds_line
    .p2align 2
_fe_kinds_line:
    adrp x9, _fe_calllog@PAGE
    ldr x12, [x9, _fe_calllog@PAGEOFF]
    adrp x9, _fe_ncalls@PAGE
    ldr w10, [x9, _fe_ncalls@PAGEOFF]
    FE_ADR x13, _fe_fn_kinds
    FE_ADR x14, _fe_fn_defline
    mov x11, #0
1:
    cmp x11, x10
    b.hs 3f
    add x15, x12, x11, lsl #3
    ldrh w16, [x15, #6]                 // letter
    ldr w9, [x14, x16, lsl #2]
    cbz w9, 2f                          // never DEFined (reported before)
    ldrh w17, [x15, #4]                 // the call's signature
    ldr w9, [x13, x16, lsl #2]          // the DEF's kind word
    cmp w9, w17
    b.eq 2f
    ldr w0, [x15]                       // the call's line
    ret
2:
    add x11, x11, #1
    b 1b
3:
    mov w0, #0
    ret

// ---------------------------------------------------------------------
// Token classes, one byte per TK_* kind (TK_COUNT entries): which tokens
// start a numeric operand and which a string expression (a TK_BUILTIN is
// numeric except STR$(, which _fe_sexpr_starts checks itself).
// ---------------------------------------------------------------------
    .section __TEXT,__const
Lfe_sexpr_tkclass:
    .byte FE_TKC_OTHER                  // TK_EOL
    .byte FE_TKC_NUMERIC                // TK_NUMBER
    .byte FE_TKC_STRING                 // TK_STRING
    .byte FE_TKC_NUMERIC                // TK_VAR
    .byte FE_TKC_NUMERIC                // TK_ARRAY
    .byte FE_TKC_NUMERIC                // TK_FN
    .byte FE_TKC_NUMERIC                // TK_BUILTIN
    .byte FE_TKC_NUMERIC                // TK_LPAREN
    .byte FE_TKC_OTHER                  // TK_RPAREN
    .byte FE_TKC_OTHER                  // TK_COMMA
    .byte FE_TKC_OTHER                  // TK_SEMI
    .byte FE_TKC_NUMERIC                // TK_PLUS (a leading sign)
    .byte FE_TKC_NUMERIC                // TK_MINUS
    .byte FE_TKC_OTHER                  // TK_STAR
    .byte FE_TKC_OTHER                  // TK_SLASH
    .byte FE_TKC_OTHER                  // TK_POW
    .byte FE_TKC_OTHER                  // TK_EQ
    .byte FE_TKC_OTHER                  // TK_NE
    .byte FE_TKC_OTHER                  // TK_LT
    .byte FE_TKC_OTHER                  // TK_LE
    .byte FE_TKC_OTHER                  // TK_GT
    .byte FE_TKC_OTHER                  // TK_GE
    .byte FE_TKC_OTHER                  // TK_THEN
    .byte FE_TKC_OTHER                  // TK_TO
    .byte FE_TKC_OTHER                  // TK_STEP
    .byte FE_TKC_OTHER                  // TK_BAD (classified by its text)
    .byte FE_TKC_STRING                 // TK_SVAR
    .byte FE_TKC_STRING                 // TK_SARRAY
    .byte FE_TKC_OTHER                  // TK_GOTO
    .byte FE_TKC_NUMERIC                // TK_FN0
    .byte FE_TKC_STRING                 // TK_SFN
    .byte FE_TKC_STRING                 // TK_SFN0
    .byte FE_TKC_OTHER                  // TK_AMP
Lfe_sexpr_tkclass_end:
// the table must have exactly TK_COUNT entries (DESIGN.md 2.4)
.if ((Lfe_sexpr_tkclass_end - Lfe_sexpr_tkclass) != TK_COUNT)
    .error "fe_sexpr.s: the token class table does not have TK_COUNT entries"
.endif
