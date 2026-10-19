// =====================================================================
// src/frontend/fe_stmt.s -- statement recognition, parsing and lowering
// (LANGUAGE.md sections 3 and 7, IR.md sections 4.3-4.4).
//
//   _fe_stmt()     parse the statement text of the current line (the
//                  scanner window) and lower it into main / an FN function
//
// Every statement must consume its whole text; leftover text is
// INCORRECT FORMAT. Errors leave through _fe_err (fe_compile.s).
//
// FOR stack entry (_fe_forstack, FE_FOR_ENTRY = 16 bytes, see
// fe_compile.s): +0 u32 loop variable slot, +4 u32 FOR index k,
// +8 u32 label B (loop body), +12 u32 label X (after the NEXT).
// Array state entry (_fe_arrays, 16 bytes): +0 dims, +4 b1, +8 b2,
// +12 flags (IRA_FLAG_DIMMED).
// =====================================================================
.include "baysick.inc"

.equ FE_FOR_ENTRY,      16          // see fe_compile.s
.equ FE_KW_ENTRY,       8           // keyword table: length byte + 7 chars
.equ FE_PEEK_EOL,       0x100       // _fe_peek result beyond the line end
.equ FE_BITS_ONE,       0x3FF0000000000000  // IEEE-754 bits of 1.0

// target kinds returned by Lfe_stmt_target
.equ FE_TGT_SCALAR,     0
.equ FE_TGT_ARRAY,      1

// FE_NONE: set the optional _fe_emit / _fe_emit_new operands to "unused".
.macro FE_NONE
    mov w1, #IR_NONE
    mov w2, #IR_NONE
    mov w3, #IR_NONE
    mov w4, #IR_NONE
    mov x5, #0
    mov w6, #REL_NONE
.endm

// FE_EMIT0 op: emit an instruction without operands.
.macro FE_EMIT0 op
    FE_NONE
    mov w0, #\op
    bl _fe_emit
.endm

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _fe_stmt -- recognise the keyword (LANGUAGE.md 3.1, tested in order as
//   a prefix of the statement text) and run that statement's parser.
//   in:  scanner window = statement text of the current line
//   out: none (code emitted); ILLEGAL INSTRUCTION if no keyword matches
//   clobbers: x0-x17, d0-d7
//   callee-saved: x19 = keyword index, x20 = keyword entry,
//        x21 = scanner position, x22 = bytes left in the line
//   frame: 48 bytes
// ---------------------------------------------------------------------
    .globl _fe_stmt
    .p2align 2
_fe_stmt:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    adrp x9, _fe_pos@PAGE
    ldr x21, [x9, _fe_pos@PAGEOFF]
    adrp x9, _fe_end@PAGE
    ldr x22, [x9, _fe_end@PAGEOFF]
    sub x22, x22, x21
    mov x19, #0
Lfe_stmt_kw_loop:
    cmp x19, #KW_COUNT
    b.hs Lfe_stmt_kw_none
    adrp x20, Lfe_stmt_keywords@PAGE
    add x20, x20, Lfe_stmt_keywords@PAGEOFF
    add x20, x20, x19, lsl #3           // FE_KW_ENTRY bytes per keyword
    ldrb w10, [x20]                     // keyword length
    cmp x22, x10
    b.lo Lfe_stmt_kw_next               // text too short
    // compare the keyword with the start of the text
    mov x11, #0
1:
    cmp x11, x10
    b.hs Lfe_stmt_kw_match
    add x12, x20, #1
    ldrb w13, [x12, x11]
    ldrb w14, [x21, x11]
    cmp w13, w14
    b.ne Lfe_stmt_kw_next
    add x11, x11, #1
    b 1b
Lfe_stmt_kw_next:
    add x19, x19, #1
    b Lfe_stmt_kw_loop
Lfe_stmt_kw_match:
    // skip the keyword and dispatch through the handler table
    add x0, x21, x10
    bl _fe_setpos
    adrp x9, Lfe_stmt_handlers@PAGE
    add x9, x9, Lfe_stmt_handlers@PAGEOFF
    ldr x9, [x9, x19, lsl #3]
    blr x9
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
Lfe_stmt_kw_none:
    mov w0, #ERR_ILLEGAL_INSTRUCTION
    bl _fe_err

// ---------------------------------------------------------------------
// Lfe_stmt_target -- a LET/READ target or a FOR/NEXT/DEF variable:
//   letter [digit] (scalar) or letter '(' (array, '(' consumed).
//   Not a letter, or letter+digit+'(' -> ILLEGAL VARIABLE.
//   in:  none
//   out: w0 = FE_TGT_SCALAR / FE_TGT_ARRAY, w1 = slot / letter
//   clobbers: x0-x17
//   callee-saved: w19 = letter, w20 = second byte, w21 = third byte
//   frame: 48 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_target:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov w0, #0
    bl _fe_peek
    sub w19, w0, #'A'
    cmp w19, #25
    b.hi Lfe_stmt_target_bad            // not a letter
    mov w0, #1
    bl _fe_peek
    mov w20, w0
    mov w0, #2
    bl _fe_peek
    mov w21, w0
    sub w9, w20, #'0'
    cmp w9, #9
    b.hi Lfe_stmt_target_nodigit
    // letter + digit (an array name cannot have a digit)
    cmp w21, #'('
    b.eq Lfe_stmt_target_bad
    mov w0, #2
    bl _fe_advance
    mov w9, #SLOT_PER_LETTER
    mul w1, w19, w9
    sub w9, w20, #'0'
    add w1, w1, w9
    add w1, w1, #1                      // letter*11 + digit + 1
    mov w0, #FE_TGT_SCALAR
    b Lfe_stmt_target_ret
Lfe_stmt_target_nodigit:
    cmp w20, #'('
    b.ne 1f
    mov w0, #2                          // array: consume letter and '('
    bl _fe_advance
    mov w1, w19
    mov w0, #FE_TGT_ARRAY
    b Lfe_stmt_target_ret
1:
    mov w0, #1                          // bare letter
    bl _fe_advance
    mov w9, #SLOT_PER_LETTER
    mul w1, w19, w9
    mov w0, #FE_TGT_SCALAR
Lfe_stmt_target_ret:
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
Lfe_stmt_target_bad:
    mov w0, #ERR_ILLEGAL_VARIABLE
    bl _fe_err

// ---------------------------------------------------------------------
// Lfe_stmt_simplevar -- a simple variable (FOR, NEXT, DEF parameter);
//   an array element is ILLEGAL VARIABLE.
//   in: none   out: w0 = scalar slot
//   clobbers: x0-x17
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_simplevar:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl Lfe_stmt_target
    cmp w0, #FE_TGT_SCALAR
    b.eq 1f
    mov w0, #ERR_ILLEGAL_VARIABLE
    bl _fe_err
1:
    mov w0, w1
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Lfe_stmt_store -- emit the store of a value into a target.
//   in:  w0 = dims (0 scalar, 1 list, 2 table), w1 = slot / letter,
//        w2 = i temp, w3 = j temp, w4 = value temp
//   out: none
//   clobbers: x0-x17
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_store:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov w9, w0
    mov w10, w1
    mov w11, w2
    mov w12, w3
    mov w13, w4
    FE_NONE
    mov w4, w10                         // X = slot or array letter
    cbnz w9, 1f
    // stv v, te
    mov w1, w13
    mov w0, #OP_STV
    b 3f
1:
    cmp w9, #1
    b.ne 2f
    // ast1 L, ti, te
    mov w1, w11
    mov w2, w13
    mov w0, #OP_AST1
    b 3f
2:
    // ast2 L, ti, tj, te
    mov w1, w11
    mov w2, w12
    mov w3, w13
    mov w0, #OP_AST2
3:
    bl _fe_emit
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Lfe_stmt_lineref -- the line-number operand of GOTO / GOSUB / IF THEN,
//   which ends the statement. Missing -> INCORRECT FORMAT, more than 5
//   digits -> ILLEGAL LINE NUMBER, trailing text -> INCORRECT FORMAT.
//   A line that does not exist is remembered (first one only) for the
//   phase-3 UNDEFINED NUMBER error.
//   in:  none
//   out: w0 = label id of the target line, or -1 if it does not exist
//   clobbers: x0-x17
//   callee-saved: w19 = line value
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_lineref:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    bl _fe_scan_digits
    mov w19, w0
    cbnz w1, 1f
    mov w0, #ERR_INCORRECT_FORMAT
    bl _fe_err
1:
    cmp w1, #LIM_LINE_DIGITS
    b.ls 2f
    mov w0, #ERR_ILLEGAL_LINE_NUMBER
    bl _fe_err
2:
    bl _fe_expect_eol
    mov w0, w19
    bl _fe_line_lookup
    tbz w0, #31, 3f
    // missing target: keep the first such line for UNDEFINED NUMBER
    adrp x9, _fe_undef_line@PAGE
    ldr w10, [x9, _fe_undef_line@PAGEOFF]
    cbnz w10, 3f
    adrp x11, _fe_line@PAGE
    ldr w11, [x11, _fe_line@PAGEOFF]
    str w11, [x9, _fe_undef_line@PAGEOFF]
3:
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lfe_stmt_let -- LET target = expression (LANGUAGE.md 7.1).
//   Lowering: subscripts, expression, store.
//   in: scanner after "LET"   out: none
//   clobbers: x0-x17, d0-d7
//   callee-saved: w19 = dims (0 scalar), w20 = slot / letter,
//        w21 = i, w22 = j
//   frame: 48 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_let:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    bl Lfe_stmt_target
    mov w20, w1
    mov w19, #0
    mov w21, #IR_NONE
    mov w22, #IR_NONE
    cmp w0, #FE_TGT_ARRAY
    b.ne 1f
    // target subscripts come first
    mov w0, w20
    bl _fe_subscripts
    mov w21, w0
    mov w22, w1
    mov w19, w2
1:
    mov w0, #TK_EQ
    mov w1, #ERR_INCORRECT_FORMAT
    bl _fe_expect_op
    bl _fe_expr
    mov w4, w0
    bl Lfe_stmt_eol_keep_w4
    mov w0, w19
    mov w1, w20
    mov w2, w21
    mov w3, w22
    bl Lfe_stmt_store
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// Lfe_stmt_eol_keep_w4 -- _fe_expect_eol that preserves w4 (a temp
//   number the caller still needs).
//   in: w4 = value to keep   out: w4 unchanged
//   clobbers: x0-x3, x5-x17
//   callee-saved: x19 = saved w4
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_eol_keep_w4:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov w19, w4
    bl _fe_expect_eol
    mov w4, w19
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lfe_stmt_print -- PRINT [item-list] (LANGUAGE.md 7.2, IR.md 4.3).
//   in: scanner after "PRINT"   out: none
//   clobbers: x0-x17, d0-d7
//   callee-saved: w19 = previous element (0 none, 1 string,
//        2 expression, 3 separator), x20 = saved position,
//        w21 = string length / temp
//   frame: 96 bytes (frame record, x19-x22, 40-byte token at sp+48)
// ---------------------------------------------------------------------
.equ FE_PR_NONE,        0
.equ FE_PR_STRING,      1
.equ FE_PR_EXPR,        2
.equ FE_PR_SEP,         3
    .p2align 2
Lfe_stmt_print:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov w19, #FE_PR_NONE
Lfe_stmt_print_loop:
    bl _fe_getpos
    mov x20, x0
    mov w0, #SCAN_OPERAND
    add x1, sp, #48
    bl _fe_scan
    cmp w0, #TK_EOL
    b.eq Lfe_stmt_print_end
    cmp w0, #TK_STRING
    b.eq Lfe_stmt_print_string
    cmp w0, #TK_COMMA
    b.eq Lfe_stmt_print_comma
    cmp w0, #TK_SEMI
    b.eq Lfe_stmt_print_semi
    cmp w0, #TK_BAD
    b.ne Lfe_stmt_print_expr
    // an unterminated string is INCORRECT FORMAT
    ldr x9, [sp, #(48 + TOK_PTR)]
    ldrb w9, [x9]
    cmp w9, #'"'
    b.ne Lfe_stmt_print_expr
    mov w0, #ERR_INCORRECT_FORMAT
    bl _fe_err

Lfe_stmt_print_string:
    // total literal bytes are limited (TOO MANY LABELS at this line)
    ldr w21, [sp, #(48 + TOK_LEN)]
    adrp x9, _fe_strbytes@PAGE
    ldr w10, [x9, _fe_strbytes@PAGEOFF]
    add w10, w10, w21
    str w10, [x9, _fe_strbytes@PAGEOFF]
    mov w11, #LIM_LABEL_BYTES
    cmp w10, w11
    b.ls 1f
    mov w0, #ERR_TOO_MANY_LABELS
    bl _fe_err
1:
    adrp x9, _fe_module@PAGE
    ldr x0, [x9, _fe_module@PAGEOFF]
    ldr x1, [sp, #(48 + TOK_PTR)]
    mov w2, w21
    bl _ir_add_string
    mov w9, w0
    FE_NONE
    mov w4, w9                          // prstr sK
    mov w0, #OP_PRSTR
    bl _fe_emit
    mov w19, #FE_PR_STRING
    b Lfe_stmt_print_loop

Lfe_stmt_print_comma:
    FE_EMIT0 OP_PRCOMMA
    mov w19, #FE_PR_SEP
    b Lfe_stmt_print_loop

Lfe_stmt_print_semi:
    // ';' only moves after a number
    cmp w19, #FE_PR_EXPR
    b.ne 1f
    FE_EMIT0 OP_PRSEMI
1:
    mov w19, #FE_PR_SEP
    b Lfe_stmt_print_loop

Lfe_stmt_print_expr:
    // an expression: re-read from its start
    mov x0, x20
    bl _fe_setpos
    bl _fe_expr
    mov w9, w0
    FE_NONE
    mov w1, w9
    mov w0, #OP_PRNUM
    bl _fe_emit
    mov w19, #FE_PR_EXPR
    // it must be followed by ',', ';' or the end of the line
    bl _fe_getpos
    mov x20, x0
    bl _fe_next_op
    cmp w0, #TK_COMMA
    b.eq 1f
    cmp w0, #TK_SEMI
    b.eq 1f
    cmp w0, #TK_EOL
    b.eq 1f
    mov w0, #ERR_INCORRECT_FORMAT
    bl _fe_err
1:
    mov x0, x20                         // let the loop handle the separator
    bl _fe_setpos
    b Lfe_stmt_print_loop

Lfe_stmt_print_end:
    // newline unless the list ended with ',' or ';'
    cmp w19, #FE_PR_SEP
    b.eq 1f
    FE_EMIT0 OP_PRNL
1:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret

// ---------------------------------------------------------------------
// Lfe_stmt_end -- END: nothing may follow; must be the last line.
//   in: scanner after "END"   out: none
//   clobbers: x0-x17
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_end:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x9, _fe_lineidx@PAGE
    ldr w9, [x9, _fe_lineidx@PAGEOFF]
    adrp x10, _fe_nlines@PAGE
    ldr w10, [x10, _fe_nlines@PAGEOFF]
    add w9, w9, #1
    cmp w9, w10
    b.eq 1f
    mov w0, #ERR_END_NOT_LAST
    bl _fe_err
1:
    bl _fe_expect_eol
    adrp x9, _fe_has_end@PAGE
    mov w10, #1
    str w10, [x9, _fe_has_end@PAGEOFF]
    FE_EMIT0 OP_END
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Lfe_stmt_stop -- STOP (nothing may follow).
// Lfe_stmt_return -- RETURN (nothing may follow).
// Lfe_stmt_rem -- REM: everything after it is ignored.
//   in: scanner after the keyword   out: none
//   clobbers: x0-x17
//   callee-saved: none used
//   frame: 16 bytes (REM: none)
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_stop:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl _fe_expect_eol
    FE_EMIT0 OP_STOP
    ldp x29, x30, [sp], #16
    ret

    .p2align 2
Lfe_stmt_return:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl _fe_expect_eol
    FE_EMIT0 OP_RETURN
    ldp x29, x30, [sp], #16
    ret

    .p2align 2
Lfe_stmt_rem:
    ret

// ---------------------------------------------------------------------
// Lfe_stmt_read -- READ target {, target} (LANGUAGE.md 7.4).
//   Per target: subscripts, `read`, store.
//   in: scanner after "READ"   out: none
//   clobbers: x0-x17, d0-d7
//   callee-saved: w19 = dims, w20 = slot / letter, w21 = i, w22 = j
//   frame: 48 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_read:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    adrp x9, _fe_has_read@PAGE
    mov w10, #1
    str w10, [x9, _fe_has_read@PAGEOFF]
Lfe_stmt_read_loop:
    bl Lfe_stmt_target
    mov w20, w1
    mov w19, #0
    mov w21, #IR_NONE
    mov w22, #IR_NONE
    cmp w0, #FE_TGT_ARRAY
    b.ne 1f
    mov w0, w20
    bl _fe_subscripts
    mov w21, w0
    mov w22, w1
    mov w19, w2
1:
    // tN = read; store it
    FE_NONE
    mov w0, #OP_READ
    bl _fe_emit_new
    mov w4, w0
    mov w0, w19
    mov w1, w20
    mov w2, w21
    mov w3, w22
    bl Lfe_stmt_store
    // ',' continues the list, end of line finishes it
    bl _fe_next_op
    cmp w0, #TK_COMMA
    b.eq Lfe_stmt_read_loop
    cmp w0, #TK_EOL
    b.eq 2f
    mov w0, #ERR_INCORRECT_FORMAT
    bl _fe_err
2:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// Lfe_stmt_data -- DATA datum {, datum}, datum := [+|-] constant
//   (LANGUAGE.md 7.5). Values go to the module's data block.
//   in: scanner after "DATA"   out: none
//   clobbers: x0-x17, d0-d7
//   callee-saved: w19 = negative flag
//   frame: 80 bytes (frame record, x19-x20, 40-byte token at sp+32)
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_data:
    stp x29, x30, [sp, #-80]!
    mov x29, sp
    stp x19, x20, [sp, #16]
Lfe_stmt_data_loop:
    // optional sign, part of the datum
    mov w19, #0
    mov w0, #0
    bl _fe_peek
    cmp w0, #'+'
    b.eq 1f
    cmp w0, #'-'
    b.ne 2f
    mov w19, #1
1:
    mov w0, #1
    bl _fe_advance
2:
    // a datum must start like a constant
    mov w0, #0
    bl _fe_peek
    cmp w0, #'.'
    b.eq 3f
    sub w9, w0, #'0'
    cmp w9, #9
    b.ls 3f
    mov w0, #ERR_INCORRECT_FORMAT       // empty datum, variable, ...
    bl _fe_err
3:
    mov w0, #SCAN_OPERAND
    add x1, sp, #32
    bl _fe_scan
    cmp w0, #TK_NUMBER
    b.eq 4f
    ldr w0, [sp, #(32 + TOK_ERR)]       // ILLEGAL CONSTANT
    bl _fe_err
4:
    // count it (TOO MUCH DATA beyond the limit)
    adrp x9, _fe_ndata@PAGE
    ldr w10, [x9, _fe_ndata@PAGEOFF]
    add w10, w10, #1
    str w10, [x9, _fe_ndata@PAGEOFF]
    movz w11, #(LIM_DATA_VALUES & 0xFFFF)
    movk w11, #(LIM_DATA_VALUES >> 16), lsl #16
    cmp w10, w11
    b.ls 5f
    mov w0, #ERR_TOO_MUCH_DATA
    bl _fe_err
5:
    // a leading '-' flips the sign bit of the value
    ldr x1, [sp, #(32 + TOK_VALUE)]
    lsl x9, x19, #63
    eor x1, x1, x9
    adrp x9, _fe_module@PAGE
    ldr x0, [x9, _fe_module@PAGEOFF]
    bl _ir_add_data
    // ',' -> next datum; end of line -> done
    mov w0, #0
    bl _fe_peek
    cmp w0, #FE_PEEK_EOL
    b.eq Lfe_stmt_data_done
    cmp w0, #','
    b.eq 6f
    mov w0, #ERR_INCORRECT_FORMAT
    bl _fe_err
6:
    mov w0, #1
    bl _fe_advance
    b Lfe_stmt_data_loop
Lfe_stmt_data_done:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #80
    ret

// ---------------------------------------------------------------------
// Lfe_stmt_goto -- GOTO line-number: `jmp @n`.
//   in: scanner after "GOTO"   out: none
//   clobbers: x0-x17
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_goto:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl Lfe_stmt_lineref
    tbnz w0, #31, 1f                    // undefined target: nothing emitted
    mov w9, w0
    FE_NONE
    mov w4, w9
    mov w0, #OP_JMP
    bl _fe_emit
1:
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Lfe_stmt_if -- IF a REL b THEN n (LANGUAGE.md 7.7):
//   a; b; `jcmp REL, ta, tb, @n`.
//   in: scanner after "IF"   out: none
//   clobbers: x0-x17, d0-d7
//   callee-saved: w19 = ta, w20 = REL, w21 = tb
//   frame: 48 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_if:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    bl _fe_expr
    mov w19, w0
    // relation (the scanner matches <= <> >= before < > =)
    bl _fe_next_op
    sub w20, w0, #TK_EQ
    cmp w20, #(TK_GE - TK_EQ)
    b.ls 1f
    mov w0, #ERR_ILLEGAL_RELATION
    bl _fe_err
1:
    add w20, w20, #REL_EQ               // TK_EQ..TK_GE -> REL_EQ..REL_GE
    bl _fe_expr
    mov w21, w0
    mov w0, #TK_THEN
    mov w1, #ERR_INCORRECT_FORMAT
    bl _fe_expect_op
    bl Lfe_stmt_lineref
    tbnz w0, #31, 2f
    mov w4, w0                          // X = target label
    mov w1, w19
    mov w2, w21
    mov w3, #IR_NONE
    mov x5, #0
    mov w6, w20
    mov w0, #OP_JCMP
    bl _fe_emit
2:
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// Lfe_stmt_for -- FOR v = a TO b [STEP c] (LANGUAGE.md 7.8, IR.md 4.3).
//   in: scanner after "FOR"   out: none
//   clobbers: x0-x17, d0-d7
//   callee-saved: w19 = v slot, w20 = ta, w21 = tb, w22 = tc,
//        w23 = FOR index k, w24 = label Z, w25 = label B, w26 = label X
//   frame: 80 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_for:
    stp x29, x30, [sp, #-80]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    // at most LIM_FORS FOR statements
    adrp x9, _fe_nfors@PAGE
    ldr w23, [x9, _fe_nfors@PAGEOFF]
    cmp w23, #LIM_FORS
    b.lo 1f
    mov w0, #ERR_TOO_MANY_LOOPS
    bl _fe_err
1:
    bl Lfe_stmt_simplevar
    mov w19, w0
    mov w0, #TK_EQ
    mov w1, #ERR_INCORRECT_FORMAT
    bl _fe_expect_op
    bl _fe_expr                         // initial value
    mov w20, w0
    mov w0, #TK_TO
    mov w1, #ERR_INCORRECT_FORMAT
    bl _fe_expect_op
    bl _fe_expr                         // limit
    mov w21, w0
    bl _fe_next_op
    cmp w0, #TK_STEP
    b.eq Lfe_stmt_for_step
    cmp w0, #TK_EOL
    b.eq 2f
    mov w0, #ERR_INCORRECT_FORMAT
    bl _fe_err
2:
    // no STEP: tc = const 1
    FE_NONE
    mov x5, #FE_BITS_ONE
    mov w0, #OP_CONST
    bl _fe_emit_new
    mov w22, w0
    b Lfe_stmt_for_lower
Lfe_stmt_for_step:
    bl _fe_expr
    mov w22, w0
    bl _fe_expect_eol
Lfe_stmt_for_lower:
    // FOR index k and its labels Z, B, X (allocated in that order)
    add w9, w23, #1
    adrp x10, _fe_nfors@PAGE
    str w9, [x10, _fe_nfors@PAGEOFF]
    bl _fe_new_label
    mov w24, w0
    bl _fe_new_label
    mov w25, w0
    bl _fe_new_label
    mov w26, w0
    // stv %limk, tb
    FE_NONE
    mov w1, w21
    mov w4, #SLOT_FOR_BASE
    add w4, w4, w23, lsl #1
    mov w0, #OP_STV
    bl _fe_emit
    // stv %stepk, tc
    FE_NONE
    mov w1, w22
    mov w4, #(SLOT_FOR_BASE + 1)
    add w4, w4, w23, lsl #1
    mov w0, #OP_STV
    bl _fe_emit
    // jfor ta, tb, tc, LZ
    FE_NONE
    mov w1, w20
    mov w2, w21
    mov w3, w22
    mov w4, w24
    mov w0, #OP_JFOR
    bl _fe_emit
    // stv v, ta
    FE_NONE
    mov w1, w20
    mov w4, w19
    mov w0, #OP_STV
    bl _fe_emit
    // jmp LB
    FE_NONE
    mov w4, w25
    mov w0, #OP_JMP
    bl _fe_emit
    // label LZ
    FE_NONE
    mov w4, w24
    mov w0, #OP_LABEL
    bl _fe_emit
    // td = sub ta, tc ; stv v, td  (loop not performed: v = a - c)
    FE_NONE
    mov w1, w20
    mov w2, w22
    mov w0, #OP_SUB
    bl _fe_emit_new
    mov w9, w0
    FE_NONE
    mov w1, w9
    mov w4, w19
    mov w0, #OP_STV
    bl _fe_emit
    // jmp LX
    FE_NONE
    mov w4, w26
    mov w0, #OP_JMP
    bl _fe_emit
    // label LB (the loop body follows)
    FE_NONE
    mov w4, w25
    mov w0, #OP_LABEL
    bl _fe_emit
    // push { v, k, B, X } for the matching NEXT
    adrp x9, _fe_forsp@PAGE
    ldr w10, [x9, _fe_forsp@PAGEOFF]
    adrp x11, _fe_forstack@PAGE
    add x11, x11, _fe_forstack@PAGEOFF
    add x11, x11, x10, lsl #4           // FE_FOR_ENTRY bytes per entry
    str w19, [x11]
    str w23, [x11, #4]
    str w25, [x11, #8]
    str w26, [x11, #12]
    add w10, w10, #1
    str w10, [x9, _fe_forsp@PAGEOFF]
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #80
    ret

// ---------------------------------------------------------------------
// Lfe_stmt_next -- NEXT v, closing the innermost open FOR (which must use
//   the same variable, else NOT MATCH WITH FOR). IR.md 4.3.
//   in: scanner after "NEXT"   out: none
//   clobbers: x0-x17
//   callee-saved: w19 = v slot, w20 = FOR index k, w21 = label B,
//        w22 = label X, w23 = te, w24 = ts, w25 = tg
//   frame: 80 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_next:
    stp x29, x30, [sp, #-80]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    str x25, [sp, #64]
    bl Lfe_stmt_simplevar
    mov w19, w0
    // the innermost open FOR must exist and use the same variable
    adrp x9, _fe_forsp@PAGE
    ldr w10, [x9, _fe_forsp@PAGEOFF]
    cbz w10, Lfe_stmt_next_nomatch
    sub w10, w10, #1
    adrp x11, _fe_forstack@PAGE
    add x11, x11, _fe_forstack@PAGEOFF
    add x11, x11, x10, lsl #4
    ldr w12, [x11]
    cmp w12, w19
    b.ne Lfe_stmt_next_nomatch
    ldr w20, [x11, #4]
    ldr w21, [x11, #8]
    ldr w22, [x11, #12]
    str w10, [x9, _fe_forsp@PAGEOFF]    // pop
    bl _fe_expect_eol
    // te = ldv v
    FE_NONE
    mov w4, w19
    mov w0, #OP_LDV
    bl _fe_emit_new
    mov w23, w0
    // ts = ldv %stepk
    FE_NONE
    mov w4, #(SLOT_FOR_BASE + 1)
    add w4, w4, w20, lsl #1
    mov w0, #OP_LDV
    bl _fe_emit_new
    mov w24, w0
    // tg = add te, ts
    FE_NONE
    mov w1, w23
    mov w2, w24
    mov w0, #OP_ADD
    bl _fe_emit_new
    mov w25, w0
    // tl = ldv %limk
    FE_NONE
    mov w4, #SLOT_FOR_BASE
    add w4, w4, w20, lsl #1
    mov w0, #OP_LDV
    bl _fe_emit_new
    // jfor tg, tl, ts, LX
    mov w2, w0
    mov w1, w25
    mov w3, w24
    mov w4, w22
    mov x5, #0
    mov w6, #REL_NONE
    mov w0, #OP_JFOR
    bl _fe_emit
    // stv v, tg
    FE_NONE
    mov w1, w25
    mov w4, w19
    mov w0, #OP_STV
    bl _fe_emit
    // jmp LB
    FE_NONE
    mov w4, w21
    mov w0, #OP_JMP
    bl _fe_emit
    // label LX
    FE_NONE
    mov w4, w22
    mov w0, #OP_LABEL
    bl _fe_emit
    ldr x25, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #80
    ret
Lfe_stmt_next_nomatch:
    mov w0, #ERR_NOT_MATCH_WITH_FOR
    bl _fe_err

// ---------------------------------------------------------------------
// Lfe_stmt_gosub -- GOSUB n: allocate LR; `gosub @n, LR`; `label LR`.
//   in: scanner after "GOSUB"   out: none
//   clobbers: x0-x17
//   callee-saved: w19 = target label (or -1), w20 = return label
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_gosub:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    bl Lfe_stmt_lineref
    mov w19, w0
    bl _fe_new_label
    mov w20, w0
    tbnz w19, #31, 1f                   // undefined target: nothing emitted
    FE_NONE
    mov w4, w19
    mov w5, w20                         // IMM = return label id
    mov w0, #OP_GOSUB
    bl _fe_emit
    FE_NONE
    mov w4, w20
    mov w0, #OP_LABEL
    bl _fe_emit
1:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lfe_stmt_def -- DEF FNx(p) = e (LANGUAGE.md 7.10, IR.md 4.4): creates
//   function 1+x and lowers e into it, followed by `ret`.
//   in: scanner after "DEF"   out: none
//   clobbers: x0-x17, d0-d7
//   callee-saved: w19 = letter x, w20 = parameter slot, w21 = DEF line
//   frame: 48 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_def:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    // "FN" letter
    mov w0, #0
    bl _fe_peek
    cmp w0, #'F'
    b.ne Lfe_stmt_def_format
    mov w0, #1
    bl _fe_peek
    cmp w0, #'N'
    b.ne Lfe_stmt_def_format
    mov w0, #2
    bl _fe_peek
    sub w19, w0, #'A'
    cmp w19, #25
    b.hi Lfe_stmt_def_format
    mov w0, #3
    bl _fe_advance
    // a second DEF of the same letter
    adrp x9, _fe_fn_defline@PAGE
    add x9, x9, _fe_fn_defline@PAGEOFF
    ldr w10, [x9, w19, uxtw #2]
    cbz w10, 1f
    mov w0, #ERR_DUPLICATE_FUNCTION
    bl _fe_err
1:
    // "(" parameter ")" "="
    mov w0, #0
    bl _fe_peek
    cmp w0, #'('
    b.ne Lfe_stmt_def_format
    mov w0, #1
    bl _fe_advance
    bl Lfe_stmt_simplevar
    mov w20, w0
    mov w0, #0
    bl _fe_peek
    cmp w0, #')'
    b.ne Lfe_stmt_def_format
    mov w0, #1
    bl _fe_advance
    mov w0, #0
    bl _fe_peek
    cmp w0, #'='
    b.ne Lfe_stmt_def_format
    mov w0, #1
    bl _fe_advance
    // record the definition and open function 1+x
    adrp x9, _fe_line@PAGE
    ldr w21, [x9, _fe_line@PAGEOFF]
    adrp x9, _fe_fn_defline@PAGE
    add x9, x9, _fe_fn_defline@PAGEOFF
    str w21, [x9, w19, uxtw #2]
    adrp x9, _fe_module@PAGE
    ldr x0, [x9, _fe_module@PAGEOFF]
    add w1, w19, #FUNC_FN_BASE
    mov w2, w20
    mov w3, w21
    bl _ir_func_begin
    adrp x9, _fe_curfn@PAGE
    str x0, [x9, _fe_curfn@PAGEOFF]
    // the body sees the parameter as `param`
    adrp x9, _fe_def_param@PAGE
    str w20, [x9, _fe_def_param@PAGEOFF]
    adrp x9, _fe_def_letter@PAGE
    str w19, [x9, _fe_def_letter@PAGEOFF]
    adrp x9, _fe_in_def@PAGE
    mov w10, #1
    str w10, [x9, _fe_in_def@PAGEOFF]
    bl _fe_expr
    mov w4, w0
    bl Lfe_stmt_eol_keep_w4
    // ret te
    mov w1, w4
    mov w2, #IR_NONE
    mov w3, #IR_NONE
    mov w4, #IR_NONE
    mov x5, #0
    mov w6, #REL_NONE
    mov w0, #OP_RET
    bl _fe_emit
    // back to main
    adrp x9, _fe_in_def@PAGE
    str wzr, [x9, _fe_in_def@PAGEOFF]
    adrp x9, _fe_main@PAGE
    ldr x10, [x9, _fe_main@PAGEOFF]
    adrp x9, _fe_curfn@PAGE
    str x10, [x9, _fe_curfn@PAGEOFF]
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
Lfe_stmt_def_format:
    mov w0, #ERR_INCORRECT_FORMAT
    bl _fe_err

// ---------------------------------------------------------------------
// Lfe_stmt_dim -- DIM decl {, decl}, decl := letter ( int [, int] )
//   (LANGUAGE.md 7.11). Bounds go to the array table; no code.
//   in: scanner after "DIM"   out: none
//   clobbers: x0-x17
//   callee-saved: w19 = letter, x20 = &array state, w21 = b1, w22 = b2,
//        w23 = dims
//   frame: 64 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_dim:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]
Lfe_stmt_dim_loop:
    // a single letter ...
    mov w0, #0
    bl _fe_peek
    sub w19, w0, #'A'
    cmp w19, #25
    b.hi Lfe_stmt_dim_var
    mov w0, #1
    bl _fe_peek
    sub w9, w0, #'0'
    cmp w9, #9
    b.ls Lfe_stmt_dim_var               // letter + digit
    // ... followed by '('
    cmp w0, #'('
    b.ne Lfe_stmt_dim_format
    mov w0, #2
    bl _fe_advance
    adrp x20, _fe_arrays@PAGE
    add x20, x20, _fe_arrays@PAGEOFF
    add x20, x20, w19, uxtw #4
    ldr w9, [x20, #12]
    tst w9, #IRA_FLAG_DIMMED            // already set by a DIM?
    b.eq 1f
    mov w0, #ERR_DUPLICATE_DIMENSION
    bl _fe_err
1:
    // first bound
    bl Lfe_stmt_dim_bound
    mov w21, w0
    mov w22, #0
    mov w23, #1
    mov w0, #0
    bl _fe_peek
    cmp w0, #','
    b.ne 2f
    // second bound: a table
    mov w0, #1
    bl _fe_advance
    bl Lfe_stmt_dim_bound
    mov w22, w0
    mov w23, #2
    mov w0, #0
    bl _fe_peek
2:
    cmp w0, #')'
    b.ne Lfe_stmt_dim_format
    mov w0, #1
    bl _fe_advance
    // dimensionality fixed by an earlier line must agree
    ldr w9, [x20]
    cbz w9, 3f
    cmp w9, w23
    b.eq 3f
    mov w0, #ERR_ILLEGAL_VARIABLE
    bl _fe_err
3:
    // element count (b1+1)*(b2+1) <= LIM_ARRAY_ELEMS
    add x9, x21, #1
    add x10, x22, #1
    mul x9, x9, x10
    movz x10, #(LIM_ARRAY_ELEMS & 0xFFFF)
    movk x10, #(LIM_ARRAY_ELEMS >> 16), lsl #16
    cmp x9, x10
    b.ls 4f
    mov w0, #ERR_DIMENSION_TOO_LARGE
    bl _fe_err
4:
    str w23, [x20]
    str w21, [x20, #4]
    str w22, [x20, #8]
    mov w9, #IRA_FLAG_DIMMED
    str w9, [x20, #12]
    // ',' -> next declaration; end of line -> done
    mov w0, #0
    bl _fe_peek
    cmp w0, #FE_PEEK_EOL
    b.eq Lfe_stmt_dim_done
    cmp w0, #','
    b.ne Lfe_stmt_dim_format
    mov w0, #1
    bl _fe_advance
    b Lfe_stmt_dim_loop
Lfe_stmt_dim_done:
    ldr x23, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret
Lfe_stmt_dim_var:
    mov w0, #ERR_ILLEGAL_VARIABLE
    bl _fe_err
Lfe_stmt_dim_format:
    mov w0, #ERR_INCORRECT_FORMAT
    bl _fe_err

// ---------------------------------------------------------------------
// Lfe_stmt_dim_bound -- one DIM bound: digits only (none -> INCORRECT
//   FORMAT), more than LIM_DIM_DIGITS -> DIMENSION TOO LARGE.
//   in: none   out: w0 = bound value
//   clobbers: x0-x17
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_dim_bound:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl _fe_scan_digits
    cbnz w1, 1f
    mov w0, #ERR_INCORRECT_FORMAT
    bl _fe_err
1:
    cmp w1, #LIM_DIM_DIGITS
    b.ls 2f
    mov w0, #ERR_DIMENSION_TOO_LARGE
    bl _fe_err
2:
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Keyword table (LANGUAGE.md 3.1 order = KW_* order): length byte, then
// the letters, FE_KW_ENTRY bytes per entry.
// ---------------------------------------------------------------------
    .section __TEXT,__const
    .p2align 3
Lfe_stmt_keywords:
    .byte 3
    .ascii "LET\0\0\0\0"
    .byte 5
    .ascii "PRINT\0\0"
    .byte 3
    .ascii "END\0\0\0\0"
    .byte 4
    .ascii "READ\0\0\0"
    .byte 4
    .ascii "DATA\0\0\0"
    .byte 4
    .ascii "GOTO\0\0\0"
    .byte 2
    .ascii "IF\0\0\0\0\0"
    .byte 3
    .ascii "FOR\0\0\0\0"
    .byte 4
    .ascii "NEXT\0\0\0"
    .byte 5
    .ascii "GOSUB\0\0"
    .byte 6
    .ascii "RETURN\0"
    .byte 3
    .ascii "DEF\0\0\0\0"
    .byte 3
    .ascii "DIM\0\0\0\0"
    .byte 3
    .ascii "REM\0\0\0\0"
    .byte 4
    .ascii "STOP\0\0\0"
    .byte 3
    .ascii "MAT\0\0\0\0"

// Statement handlers in KW_* order.
    .section __DATA,__const
    .p2align 3
Lfe_stmt_handlers:
    .quad Lfe_stmt_let
    .quad Lfe_stmt_print
    .quad Lfe_stmt_end
    .quad Lfe_stmt_read
    .quad Lfe_stmt_data
    .quad Lfe_stmt_goto
    .quad Lfe_stmt_if
    .quad Lfe_stmt_for
    .quad Lfe_stmt_next
    .quad Lfe_stmt_gosub
    .quad Lfe_stmt_return
    .quad Lfe_stmt_def
    .quad Lfe_stmt_dim
    .quad Lfe_stmt_rem
    .quad Lfe_stmt_stop
    .quad _fe_mat                       // fe_mat.s (counted when KW_COUNT = 16)
