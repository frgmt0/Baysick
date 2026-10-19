// =====================================================================
// src/frontend/fe_expr.s -- expression parser and lowering
// (LANGUAGE.md section 5, IR.md section 4.2).
//
//   _fe_expr() -> w0 = temp holding the value
//   _fe_subscripts(w0=letter) -> w0 = i, w1 = j or IR_NONE, w2 = dims
//   _fe_array_use(w0=letter, w1=dims)       fix / check dimensionality
//   _fe_paren_open(), _fe_paren_close()     '(' depth limit, ')' required
//   _fe_note_fn_ref(w0=letter)                   record an FN reference
//
// Fourth Edition operands (LANGUAGE.md 5.2): FNx(e0, ..., ek) with any
// number of arguments, FNx without '(' (a call without arguments, or the
// value variable `ldfv` inside FNx's own multi-line body), SGN, COT, NUM,
// DET; a parameter of the enclosing DEF is `param k`. A string reference
// ("...", A$, A$( ) in operand position is MISMATCHED STRING OPERATION.
//
// Grammar (left-associative at every level, sign only at the start):
//   expression := [+|-] term { (+|-) term }
//   term       := factor { (*|/) factor }
//   factor     := primary { ^ primary }
// Lowering is post-order, left operand first, one instruction per node,
// emitted into _fe_curfn (main, or the function of a DEF being lowered).
// =====================================================================
.include "baysick.inc"

// FE_NONE: set the optional _fe_emit / _fe_emit_new operands to "unused"
// (w1-w4 = IR_NONE, x5 = 0, w6 = REL_NONE).
.macro FE_NONE
    mov w1, #IR_NONE
    mov w2, #IR_NONE
    mov w3, #IR_NONE
    mov w4, #IR_NONE
    mov x5, #0
    mov w6, #REL_NONE
.endm

// expression levels for Lfe_expr_level
.equ FE_LVL_SUM,        0           // + -   (and the leading sign)
.equ FE_LVL_PRODUCT,    1           // * /
.equ FE_LVL_POWER,      2           // ^
.equ FE_LVL_PRIMARY,    3

.equ FE_CTX_ML,         2           // _fe_ctx_kind of a multi-line body (fe_def.s)

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _fe_expr -- parse and lower one expression.
//   in:  scanner at the expression start
//   out: w0 = temp with its value; scanner just after the expression
//        (the first token that cannot continue it is left unconsumed)
//   clobbers: x0-x17, d0-d7
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .globl _fe_expr
    .p2align 2
_fe_expr:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov w0, #FE_LVL_SUM
    bl Lfe_expr_level
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Lfe_expr_level -- one binary-operator precedence level.
//   in:  w0 = FE_LVL_* level
//   out: w0 = temp with the value of this level's construct
//   clobbers: x0-x17, d0-d7
//   callee-saved: w19 = level, w20 = accumulated left temp,
//        w21 = pending opcode / leading-minus flag, x22 = saved position
//   frame: 96 bytes (frame record, x19-x22, 40-byte token at sp+48)
// ---------------------------------------------------------------------
    .p2align 2
Lfe_expr_level:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov w19, w0
    cmp w19, #FE_LVL_PRIMARY
    b.ne 1f
    bl Lfe_expr_primary                 // innermost level: an operand
    b Lfe_expr_level_ret
1:
    mov w21, #0                         // no leading minus
    cmp w19, #FE_LVL_SUM
    b.ne Lfe_expr_level_first
    // a sign is allowed only at the very start of an expression
    bl _fe_getpos
    mov x22, x0
    mov w0, #SCAN_OPERAND
    add x1, sp, #48
    bl _fe_scan
    cmp w0, #TK_PLUS
    b.eq Lfe_expr_level_first           // unary plus: no effect
    cmp w0, #TK_MINUS
    b.ne 2f
    mov w21, #1
    b Lfe_expr_level_first
2:
    mov x0, x22                         // not a sign: un-read it
    bl _fe_setpos
Lfe_expr_level_first:
    // first operand of this level
    add w0, w19, #1
    bl Lfe_expr_level
    mov w20, w0
    cbz w21, Lfe_expr_level_loop
    // leading minus applies to the first term only
    mov w1, w20
    mov w2, #IR_NONE
    mov w3, #IR_NONE
    mov w4, #IR_NONE
    mov x5, #0
    mov w6, #REL_NONE
    mov w0, #OP_NEG
    bl _fe_emit_new
    mov w20, w0
Lfe_expr_level_loop:
    // operator position: does an operator of this level follow?
    bl _fe_getpos
    mov x22, x0
    bl _fe_next_op
    cmp w19, #FE_LVL_SUM
    b.ne 1f
    mov w21, #OP_ADD
    cmp w0, #TK_PLUS
    b.eq Lfe_expr_level_rhs
    mov w21, #OP_SUB
    cmp w0, #TK_MINUS
    b.eq Lfe_expr_level_rhs
    b Lfe_expr_level_end
1:
    cmp w19, #FE_LVL_PRODUCT
    b.ne 2f
    mov w21, #OP_MUL
    cmp w0, #TK_STAR
    b.eq Lfe_expr_level_rhs
    mov w21, #OP_DIV
    cmp w0, #TK_SLASH
    b.eq Lfe_expr_level_rhs
    b Lfe_expr_level_end
2:
    mov w21, #OP_POW
    cmp w0, #TK_POW
    b.eq Lfe_expr_level_rhs
Lfe_expr_level_end:
    // not ours: hand the token back to the enclosing grammar
    mov x0, x22
    bl _fe_setpos
    mov w0, w20
    b Lfe_expr_level_ret
Lfe_expr_level_rhs:
    // right operand, then the operation (left first, post-order)
    add w0, w19, #1
    bl Lfe_expr_level
    mov w2, w0
    mov w1, w20
    mov w3, #IR_NONE
    mov w4, #IR_NONE
    mov x5, #0
    mov w6, #REL_NONE
    mov w0, w21
    bl _fe_emit_new
    mov w20, w0
    b Lfe_expr_level_loop
Lfe_expr_level_ret:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret

// ---------------------------------------------------------------------
// Lfe_expr_primary -- one operand (LANGUAGE.md 5.2).
//   in:  scanner at operand position
//   out: w0 = temp with the operand's value
//   clobbers: x0-x17, d0-d7
//   callee-saved: w19 = letter / builtin index, w20 = argument temp,
//        w21 = second subscript temp, w22 = dimensionality
//   frame: 96 bytes (frame record, x19-x22, 40-byte token at sp+48)
// ---------------------------------------------------------------------
    .p2align 2
Lfe_expr_primary:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov w0, #SCAN_OPERAND
    add x1, sp, #48
    bl _fe_scan
    cmp w0, #TK_NUMBER
    b.eq Lfe_expr_primary_number
    cmp w0, #TK_VAR
    b.eq Lfe_expr_primary_var
    cmp w0, #TK_ARRAY
    b.eq Lfe_expr_primary_array
    cmp w0, #TK_FN
    b.eq Lfe_expr_primary_fn
    cmp w0, #TK_FN0
    b.eq Lfe_expr_primary_fn0
    cmp w0, #TK_BUILTIN
    b.eq Lfe_expr_primary_builtin
    cmp w0, #TK_LPAREN
    b.eq Lfe_expr_primary_paren
    cmp w0, #TK_STRING
    b.eq Lfe_expr_primary_string
    cmp w0, #TK_SVAR
    b.eq Lfe_expr_primary_string
    cmp w0, #TK_SARRAY
    b.eq Lfe_expr_primary_string
    cmp w0, #TK_BAD
    b.eq Lfe_expr_primary_bad
    // operator, ')', ',', end of line ...: no operand here
    mov w0, #ERR_ILLEGAL_FORMULA
    bl _fe_err

Lfe_expr_primary_bad:
    // an unterminated string constant still starts a string reference
    ldr x9, [sp, #(48 + TOK_PTR)]
    ldrb w9, [x9]
    cmp w9, #'"'
    b.eq Lfe_expr_primary_string
    ldr w0, [sp, #(48 + TOK_ERR)]
    bl _fe_err

Lfe_expr_primary_string:
    // a string where a number is required (LANGUAGE.md 4.5)
    mov w0, #ERR_MISMATCHED_STRING
    bl _fe_err

Lfe_expr_primary_number:
    // tN = const BITS
    FE_NONE
    ldr x5, [sp, #(48 + TOK_VALUE)]
    mov w0, #OP_CONST
    bl _fe_emit_new
    b Lfe_expr_primary_ret

Lfe_expr_primary_var:
    ldr w19, [sp, #(48 + TOK_SLOT)]
    // inside a DEF a parameter name denotes the function's own copy
    mov w0, w19
    bl _fe_param_index
    tbnz w0, #31, 1f
    mov w9, w0
    FE_NONE
    mov x5, x9                          // IMM = parameter index k
    mov w0, #OP_PARAM
    bl _fe_emit_new
    b Lfe_expr_primary_ret
1:
    // global variable: tN = ldv v
    FE_NONE
    mov w4, w19
    mov w0, #OP_LDV
    bl _fe_emit_new
    b Lfe_expr_primary_ret

Lfe_expr_primary_array:
    // subscripts first, then the element load
    ldr w19, [sp, #(48 + TOK_INDEX)]
    mov w0, w19
    bl _fe_subscripts
    mov w20, w0
    mov w21, w1
    mov w22, w2
    FE_NONE
    mov w4, w19
    mov w1, w20
    mov w0, #OP_ALD1
    cmp w22, #1
    b.eq 1f
    mov w2, w21
    mov w0, #OP_ALD2
1:
    bl _fe_emit_new
    b Lfe_expr_primary_ret

Lfe_expr_primary_fn:
    // FNx(e0, ..., ek)
    ldr w0, [sp, #(48 + TOK_INDEX)]
    bl Lfe_expr_call
    b Lfe_expr_primary_ret

Lfe_expr_primary_fn0:
    ldr w19, [sp, #(48 + TOK_INDEX)]
    // inside FNx's own multi-line body, FNx is its value variable
    adrp x9, _fe_ctx_kind@PAGE
    ldr w9, [x9, _fe_ctx_kind@PAGEOFF]
    cmp w9, #FE_CTX_ML
    b.ne 1f
    adrp x9, _fe_ctx_letter@PAGE
    ldr w9, [x9, _fe_ctx_letter@PAGEOFF]
    cmp w9, w19
    b.ne 1f
    FE_NONE
    mov w0, #OP_LDFV
    bl _fe_emit_new
    b Lfe_expr_primary_ret
1:
    // a call without arguments: tN = callfn FNx
    mov w0, w19
    bl _fe_note_fn_ref
    mov w0, w19
    mov w1, #0
    bl _fe_record_call
    FE_NONE
    mov w4, w19
    mov w0, #OP_CALLFN
    bl _fe_emit_new
    b Lfe_expr_primary_ret

Lfe_expr_primary_builtin:
    ldr w19, [sp, #(48 + TOK_INDEX)]
    ldr w9, [sp, #(48 + TOK_LEN)]
    cmp w9, #4
    b.eq Lfe_expr_primary_call          // with '(' consumed
    // bare RND, NUM, DET
    mov w0, #OP_RND
    cmp w19, #BI_NUM
    b.ne 1f
    mov w0, #OP_NUM
1:
    cmp w19, #BI_DET
    b.ne 2f
    mov w0, #OP_DET
2:
    FE_NONE
    bl _fe_emit_new
    b Lfe_expr_primary_ret
Lfe_expr_primary_call:
    // F(e): the argument is evaluated even for RND (value discarded)
    bl _fe_paren_open
    bl _fe_expr
    mov w20, w0
    bl _fe_paren_close
    cmp w19, #BI_RND
    b.eq Lfe_expr_primary_rnd
    add w0, w19, #OP_SIN                // SIN..INT: BI_* order = opcode order
    cmp w19, #BI_SGN
    b.ne 3f
    mov w0, #OP_SGN
3:
    cmp w19, #BI_COT
    b.ne 4f
    mov w0, #OP_COT
4:
    FE_NONE
    mov w1, w20
    bl _fe_emit_new
    b Lfe_expr_primary_ret
Lfe_expr_primary_rnd:
    FE_NONE
    mov w0, #OP_RND
    bl _fe_emit_new
    b Lfe_expr_primary_ret

Lfe_expr_primary_paren:
    // ( e ): nothing extra is emitted
    bl _fe_paren_open
    bl _fe_expr
    mov w20, w0
    bl _fe_paren_close
    mov w0, w20

Lfe_expr_primary_ret:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret

// ---------------------------------------------------------------------
// Lfe_expr_call -- a user function call "FNx(" e0 {, ek} ")" whose "FNx("
//   the scanner already consumed (LANGUAGE.md 7.10, IR.md 4.2): the
//   arguments left to right, then `fnarg 1, te1` ... `fnarg k, tek`, then
//   `tN = callfn FNx, te0`. The argument count is recorded for the
//   phase-3 INCORRECT NUMBER OF ARGUMENTS check (more than eight never
//   match a DEF, so only the first eight temps are kept).
//   in:  w0 = letter
//   out: w0 = temp with the result
//   clobbers: x0-x17, d0-d7
//   callee-saved: w19 = letter, w20 = argument count, w21 = index
//   frame: 80 bytes (frame record, x19-x22, 8 u32 argument temps at sp+48)
// ---------------------------------------------------------------------
    .p2align 2
Lfe_expr_call:
    stp x29, x30, [sp, #-80]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov w19, w0
    bl _fe_note_fn_ref
    bl _fe_paren_open
    mov w20, #0
Lfe_expr_call_arg:
    bl _fe_expr
    cmp w20, #LIM_FN_PARAMS
    b.hs 1f
    add x9, sp, #48
    str w0, [x9, x20, lsl #2]
1:
    add w20, w20, #1
    bl _fe_next_op
    cmp w0, #TK_COMMA
    b.eq Lfe_expr_call_arg
    cmp w0, #TK_RPAREN
    b.eq 2f
    mov w0, #ERR_ILLEGAL_FORMULA        // anything else before ')'
    bl _fe_err
2:
    // ')' consumed: leave the nesting level
    adrp x9, _fe_depth@PAGE
    ldr w10, [x9, _fe_depth@PAGEOFF]
    sub w10, w10, #1
    str w10, [x9, _fe_depth@PAGEOFF]
    mov w0, w19
    mov w1, w20
    bl _fe_record_call
    // fnarg k, tek for k = 1 .. min(count, 8) - 1
    mov w22, w20
    cmp w22, #LIM_FN_PARAMS
    b.ls 3f
    mov w22, #LIM_FN_PARAMS
3:
    mov w21, #1
4:
    cmp w21, w22
    b.hs 5f
    add x9, sp, #48
    ldr w1, [x9, x21, lsl #2]
    mov w2, #IR_NONE
    mov w3, #IR_NONE
    mov w4, #IR_NONE
    mov w5, w21                         // IMM = argument index k
    mov w6, #REL_NONE
    mov w0, #OP_FNARG
    bl _fe_emit
    add w21, w21, #1
    b 4b
5:
    // tN = callfn FNx, te0
    ldr w1, [sp, #48]
    mov w2, #IR_NONE
    mov w3, #IR_NONE
    mov w4, w19
    mov x5, #0
    mov w6, #REL_NONE
    mov w0, #OP_CALLFN
    bl _fe_emit_new
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #80
    ret

// ---------------------------------------------------------------------
// _fe_subscripts -- parse "i [, j] )" after an array name whose '(' the
//   scanner already consumed, and fix/check the letter's dimensionality.
//   in:  w0 = array letter 0..25
//   out: w0 = temp of i, w1 = temp of j or IR_NONE, w2 = dims (1 or 2)
//   clobbers: x0-x17, d0-d7
//   callee-saved: w19 = letter, w20 = i, w21 = j, w22 = dims
//   frame: 48 bytes
// ---------------------------------------------------------------------
    .globl _fe_subscripts
    .p2align 2
_fe_subscripts:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov w19, w0
    bl _fe_paren_open                   // a subscript list is a '(' level
    bl _fe_expr
    mov w20, w0
    mov w21, #IR_NONE
    mov w22, #1
    bl _fe_next_op
    cmp w0, #TK_RPAREN
    b.eq Lfe_subscripts_closed
    cmp w0, #TK_COMMA
    b.eq 1f
    mov w0, #ERR_ILLEGAL_FORMULA        // anything else before ')'
    bl _fe_err
1:
    // second subscript: a table
    bl _fe_expr
    mov w21, w0
    mov w22, #2
    mov w0, #TK_RPAREN
    mov w1, #ERR_ILLEGAL_FORMULA
    bl _fe_expect_op
Lfe_subscripts_closed:
    // ')' consumed: leave the nesting level
    adrp x9, _fe_depth@PAGE
    ldr w10, [x9, _fe_depth@PAGEOFF]
    sub w10, w10, #1
    str w10, [x9, _fe_depth@PAGEOFF]
    mov w0, w19
    mov w1, w22
    bl _fe_array_use
    mov w0, w20
    mov w1, w21
    mov w2, w22
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// _fe_array_use -- a use of array `letter` with `dims` subscripts. The
//   first appearance (ascending lines) fixes the dimensionality (default
//   bounds 10, or 10 x 10); a later conflicting use is ILLEGAL VARIABLE.
//   in:  w0 = letter, w1 = dims (1 or 2)
//   out: none
//   clobbers: x0-x17
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .globl _fe_array_use
    .p2align 2
_fe_array_use:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x9, _fe_arrays@PAGE
    add x9, x9, _fe_arrays@PAGEOFF
    add x9, x9, w0, uxtw #4             // &arrays[letter] (16 bytes each)
    ldr w10, [x9]                       // current dims
    cbnz w10, 1f
    // first appearance: default bounds
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
// _fe_paren_open -- enter one '(' level (grouping, subscripts, argument).
//   in: none   out: none; FORMULA TOO COMPLEX beyond LIM_EXPR_DEPTH
//   clobbers: x0-x17
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .globl _fe_paren_open
    .p2align 2
_fe_paren_open:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x9, _fe_depth@PAGE
    ldr w10, [x9, _fe_depth@PAGEOFF]
    add w10, w10, #1
    str w10, [x9, _fe_depth@PAGEOFF]
    cmp w10, #LIM_EXPR_DEPTH
    b.ls 1f
    mov w0, #ERR_FORMULA_TOO_COMPLEX
    bl _fe_err
1:
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// _fe_paren_close -- require ')' (else ILLEGAL FORMULA) and leave the level.
//   in: none   out: none
//   clobbers: x0-x17, d0-d7
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .globl _fe_paren_close
    .p2align 2
_fe_paren_close:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov w0, #TK_RPAREN
    mov w1, #ERR_ILLEGAL_FORMULA
    bl _fe_expect_op
    adrp x9, _fe_depth@PAGE
    ldr w10, [x9, _fe_depth@PAGEOFF]
    sub w10, w10, #1
    str w10, [x9, _fe_depth@PAGEOFF]
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// _fe_note_fn_ref -- record a reference to FN letter: its first referencing
//   line (for UNDEFINED FUNCTION) and, inside a DEF (single-line
//   expression or multi-line body), the call-graph edge DEF letter ->
//   letter (for RECURSIVE FUNCTION).
//   in:  w0 = letter
//   out: none
//   clobbers: x9-x13   leaf, no frame
// ---------------------------------------------------------------------
    .globl _fe_note_fn_ref
    .p2align 2
_fe_note_fn_ref:
    adrp x9, _fe_fn_ref@PAGE
    add x9, x9, _fe_fn_ref@PAGEOFF
    ldr w10, [x9, w0, uxtw #2]
    cbnz w10, 1f                        // keep the first (lowest) line
    adrp x11, _fe_line@PAGE
    ldr w11, [x11, _fe_line@PAGEOFF]
    str w11, [x9, w0, uxtw #2]
1:
    adrp x9, _fe_ctx_kind@PAGE
    ldr w9, [x9, _fe_ctx_kind@PAGEOFF]
    cbz w9, 2f
    // calls[def letter] |= 1 << letter
    adrp x9, _fe_ctx_letter@PAGE
    ldr w10, [x9, _fe_ctx_letter@PAGEOFF]
    adrp x11, _fe_fn_calls@PAGE
    add x11, x11, _fe_fn_calls@PAGEOFF
    ldr w12, [x11, w10, uxtw #2]
    mov w13, #1
    lsl w13, w13, w0
    orr w12, w12, w13
    str w12, [x11, w10, uxtw #2]
2:
    ret
