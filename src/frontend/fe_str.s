// =====================================================================
// src/frontend/fe_str.s -- string references and CHANGE (LANGUAGE.md
// 4.3-4.5, 7.19; IR.md 4.2-4.3).
//
//   _fe_add_label(x0=bytes, w1=len) -> w0 string id   (TOO MANY LABELS)
//   _fe_sarray_use(w0=letter)                         string list used
//   _fe_ssubscript(w0=letter) -> w0 subscript temp    after "L$("
//   _fe_sref_try() -> w0 sref temp or -1              a string reference?
//   _fe_sref_need() -> w0 sref temp                   one is required
//   _fe_sref_end()                                    no arithmetic after it
//   _fe_change()                                      the CHANGE statement
//
// A string reference is a string constant ("..." -> `slit sK`), a string
// variable (V$ -> `svar V$`) or a string list element (L$(i) -> i, then
// `sald1 L$, ti`). There are no string expressions: wherever a statement
// needs a string, exactly one reference is parsed; a number there, or an
// arithmetic operator after it, is MISMATCHED STRING OPERATION (4.5).
// =====================================================================
.include "baysick.inc"

.equ FE_PEEK_EOL,       0x100       // _fe_peek result beyond the line end
.equ FE_ARR_ENTRY,      16          // array-state entry (_fe_sarrays), see fe_compile.s

// FE_NONE: set the optional _fe_emit / _fe_emit_new operands to "unused".
.macro FE_NONE
    mov w1, #IR_NONE
    mov w2, #IR_NONE
    mov w3, #IR_NONE
    mov w4, #IR_NONE
    mov x5, #0
    mov w6, #REL_NONE
.endm

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _fe_add_label -- add a string constant outside DATA (PRINT, LET, IF,
//   CHANGE) to the module's string table. Their total size is limited:
//   TOO MANY LABELS at the line whose constant crosses LIM_LABEL_BYTES.
//   in:  x0 = bytes, w1 = length
//   out: w0 = string id
//   clobbers: x0-x17
//   callee-saved: x19 = bytes, w20 = length
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .globl _fe_add_label
    .p2align 2
_fe_add_label:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    mov w20, w1
    adrp x9, _fe_strbytes@PAGE
    ldr w10, [x9, _fe_strbytes@PAGEOFF]
    add w10, w10, w20
    str w10, [x9, _fe_strbytes@PAGEOFF]
    mov w11, #LIM_LABEL_BYTES
    cmp w10, w11
    b.ls 1f
    mov w0, #ERR_TOO_MANY_LABELS
    bl _fe_err
1:
    adrp x9, _fe_module@PAGE
    ldr x0, [x9, _fe_module@PAGEOFF]
    mov x1, x19
    mov w2, w20
    bl _ir_add_string
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _fe_sarray_use -- string list `letter` is used: it exists, with the
//   default bound LIM_DEFAULT_BOUND unless a DIM sets one.
//   in:  w0 = letter
//   out: none
//   clobbers: x9-x11   leaf, no frame
// ---------------------------------------------------------------------
    .globl _fe_sarray_use
    .p2align 2
_fe_sarray_use:
    adrp x9, _fe_sarrays@PAGE
    add x9, x9, _fe_sarrays@PAGEOFF
.if (FE_ARR_ENTRY != 16)
    .error "fe_str.s shifts the letter by 4: FE_ARR_ENTRY must be 16"
.endif
    add x9, x9, w0, uxtw #4             // &sarrays[letter] (16 bytes each)
    ldr w10, [x9]
    cbnz w10, 1f
    mov w10, #1                         // a list
    str w10, [x9]
    mov w11, #LIM_DEFAULT_BOUND
    str w11, [x9, #4]
    str wzr, [x9, #8]
1:
    ret

// ---------------------------------------------------------------------
// _fe_ssubscript -- the subscript of a string list element "i )" after
//   "L$(" (already consumed). One '(' level; a second subscript is
//   ILLEGAL VARIABLE (no string tables, 4.4), anything else before ')'
//   ILLEGAL FORMULA. Marks the list used.
//   in:  w0 = letter
//   out: w0 = temp of i
//   clobbers: x0-x17, d0-d7
//   callee-saved: w19 = letter, w20 = i
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .globl _fe_ssubscript
    .p2align 2
_fe_ssubscript:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov w19, w0
    bl _fe_paren_open
    bl _fe_expr
    mov w20, w0
    bl _fe_next_op
    cmp w0, #TK_RPAREN
    b.eq 2f
    cmp w0, #TK_COMMA
    b.ne 1f
    mov w0, #ERR_ILLEGAL_VARIABLE       // L$(1,2)
    bl _fe_err
1:
    mov w0, #ERR_ILLEGAL_FORMULA
    bl _fe_err
2:
    // ')' consumed: leave the nesting level
    adrp x9, _fe_depth@PAGE
    ldr w10, [x9, _fe_depth@PAGEOFF]
    sub w10, w10, #1
    str w10, [x9, _fe_depth@PAGEOFF]
    mov w0, w19
    bl _fe_sarray_use
    mov w0, w20
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _fe_sref_try -- if a string reference starts here, parse and lower it.
//   An unterminated string constant is INCORRECT FORMAT.
//   in:  scanner at operand position
//   out: w0 = sref temp, or -1 with the scanner unchanged
//   clobbers: x0-x17, d0-d7
//   callee-saved: x19 = start position, w20 = letter / subscript temp
//   frame: 80 bytes (frame record, x19-x20, 40-byte token at sp+32)
// ---------------------------------------------------------------------
    .globl _fe_sref_try
    .p2align 2
_fe_sref_try:
    stp x29, x30, [sp, #-80]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    bl _fe_getpos
    mov x19, x0
    mov w0, #SCAN_OPERAND
    add x1, sp, #32
    bl _fe_scan
    cmp w0, #TK_STRING
    b.eq Lfe_sref_try_const
    cmp w0, #TK_SVAR
    b.eq Lfe_sref_try_svar
    cmp w0, #TK_SARRAY
    b.eq Lfe_sref_try_sarray
    cmp w0, #TK_BAD
    b.ne Lfe_sref_try_none
    ldr x9, [sp, #(32 + TOK_PTR)]
    ldrb w9, [x9]
    cmp w9, #'"'
    b.ne Lfe_sref_try_none
    mov w0, #ERR_INCORRECT_FORMAT       // unterminated string constant
    bl _fe_err
Lfe_sref_try_none:
    mov x0, x19
    bl _fe_setpos
    mov w0, #-1
    b Lfe_sref_try_ret
Lfe_sref_try_const:
    // tN = slit sK
    ldr x0, [sp, #(32 + TOK_PTR)]
    ldr w1, [sp, #(32 + TOK_LEN)]
    bl _fe_add_label
    mov w9, w0
    FE_NONE
    mov w4, w9
    mov w0, #OP_SLIT
    bl _fe_emit_new
    b Lfe_sref_try_ret
Lfe_sref_try_svar:
    // tN = svar V$
    FE_NONE
    ldr w4, [sp, #(32 + TOK_SLOT)]
    mov w0, #OP_SVAR
    bl _fe_emit_new
    b Lfe_sref_try_ret
Lfe_sref_try_sarray:
    // i; tN = sald1 L$, ti
    ldr w20, [sp, #(32 + TOK_INDEX)]
    mov w0, w20
    bl _fe_ssubscript
    mov w9, w0
    FE_NONE
    mov w1, w9
    mov w4, w20
    mov w0, #OP_SALD1
    bl _fe_emit_new
Lfe_sref_try_ret:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #80
    ret

// ---------------------------------------------------------------------
// _fe_sref_need -- a string reference is required here: a number (or
//   anything else) is MISMATCHED STRING OPERATION; nothing at all (end
//   of the line) is ILLEGAL FORMULA, as for a missing operand.
//   in:  scanner at operand position
//   out: w0 = sref temp
//   clobbers: x0-x17, d0-d7
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .globl _fe_sref_need
    .p2align 2
_fe_sref_need:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl _fe_sref_try
    tbz w0, #31, 2f
    bl _fe_at_eol
    mov w9, w0
    mov w0, #ERR_MISMATCHED_STRING
    cbz w9, 1f
    mov w0, #ERR_ILLEGAL_FORMULA
1:
    bl _fe_err
2:
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// _fe_sref_end -- after a string reference outside PRINT, an arithmetic
//   operator (+ - * / ^) is MISMATCHED STRING OPERATION (4.5). Nothing
//   is consumed.
//   in: none   out: returns only if no arithmetic operator follows
//   clobbers: x0-x17
//   callee-saved: x19 = position
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .globl _fe_sref_end
    .p2align 2
_fe_sref_end:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    bl _fe_getpos
    mov x19, x0
    bl _fe_next_op
    sub w9, w0, #TK_PLUS
    cmp w9, #(TK_POW - TK_PLUS)
    b.hi 1f
    mov w0, #ERR_MISMATCHED_STRING
    bl _fe_err
1:
    mov x0, x19
    bl _fe_setpos
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _fe_change -- CHANGE (LANGUAGE.md 7.19, IR.md 4.3):
//     CHANGE string-reference TO letter     r; `chgs2n L, tr`
//     CHANGE letter TO string-target        a string variable: `ts = svar
//       V$`, `chgn2s L, ts`; a list element L$(i): i, then the element
//       form `chgn2s L, L$, ti` (A = IR_NONE, B = ti, IMM = the string
//       list letter), whose subscript is checked at the store
//   A string reference after CHANGE starts the first form, else the
//   second. The list is a numeric list (fixes the letter as a list); a
//   digit or '(' after its letter -> ILLEGAL VARIABLE, a '$' -> MISMATCHED
//   STRING OPERATION. The string target is a string variable or list
//   element: a numeric one -> MISMATCHED STRING OPERATION, a constant or
//   nothing -> ILLEGAL VARIABLE. TO missing / text left over -> INCORRECT
//   FORMAT.
//   in:  scanner after "CHANGE"
//   out: none
//   clobbers: x0-x17, d0-d7
//   callee-saved: w19 = string temp (or subscript temp), w20 = list
//        letter, w21 = opcode, w22 = letter of a string list target
//   frame: 96 bytes (frame record, x19-x22, 40-byte token at sp+48)
// ---------------------------------------------------------------------
    .globl _fe_change
    .p2align 2
_fe_change:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    bl _fe_sref_try
    tbnz w0, #31, Lfe_change_n2s
    // ---- string to list --------------------------------------------
    mov w19, w0
    mov w21, #OP_CHGS2N
    bl _fe_sref_end
    mov w0, #TK_TO
    mov w1, #ERR_INCORRECT_FORMAT
    bl _fe_expect_op
    bl Lfe_change_list
    mov w20, w0
    bl _fe_expect_eol
    b Lfe_change_emit

Lfe_change_n2s:
    // ---- list to string --------------------------------------------
    mov w21, #OP_CHGN2S
    bl Lfe_change_list
    mov w20, w0
    mov w0, #TK_TO
    mov w1, #ERR_INCORRECT_FORMAT
    bl _fe_expect_op
    // the string target
    mov w0, #SCAN_OPERAND
    add x1, sp, #48
    bl _fe_scan
    cmp w0, #TK_SVAR
    b.eq Lfe_change_svar
    cmp w0, #TK_SARRAY
    b.eq Lfe_change_sarray
    cmp w0, #TK_BAD
    b.ne 1f
    ldr w0, [sp, #(48 + TOK_ERR)]       // e.g. X1$( or an open quote
    bl _fe_err
1:
    cmp w0, #TK_STRING
    b.eq Lfe_change_var
    cmp w0, #TK_EOL
    b.eq Lfe_change_var
    mov w0, #ERR_MISMATCHED_STRING      // a numeric target
    bl _fe_err
Lfe_change_svar:
    // ts = svar V$
    FE_NONE
    ldr w4, [sp, #(48 + TOK_SLOT)]
    mov w0, #OP_SVAR
    bl _fe_emit_new
    mov w19, w0
    b 2f
Lfe_change_sarray:
    // i now; then `chgn2s L, L$, ti`: the runtime converts the list
    // first and checks the subscript at the store (LANGUAGE.md 7.19)
    ldr w22, [sp, #(48 + TOK_INDEX)]
    mov w0, w22
    bl _fe_ssubscript
    mov w19, w0
    bl _fe_expect_eol
    FE_NONE
    mov w2, w19                         // B = subscript temp
    mov w4, w20                         // X = numeric list
    mov w5, w22                         // IMM = string list letter
    mov w0, #OP_CHGN2S                  // (A = IR_NONE: element form)
    bl _fe_emit
    b Lfe_change_ret
2:
    bl _fe_expect_eol
Lfe_change_emit:
    // chgs2n / chgn2s L, tstring
    FE_NONE
    mov w1, w19
    mov w4, w20
    mov w0, w21
    bl _fe_emit
Lfe_change_ret:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret
Lfe_change_var:
    mov w0, #ERR_ILLEGAL_VARIABLE
    bl _fe_err

// ---------------------------------------------------------------------
// Lfe_change_list -- the numeric list of CHANGE: a letter alone (not
//   followed by a digit or '(': ILLEGAL VARIABLE; by '$': MISMATCHED
//   STRING OPERATION). It is a use of the letter as a list.
//   in:  none
//   out: w0 = letter (one byte consumed)
//   clobbers: x0-x17
//   callee-saved: w19 = letter
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_change_list:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov w0, #0
    bl _fe_peek
    sub w19, w0, #'A'
    cmp w19, #25
    b.hi Lfe_change_list_var
    mov w0, #1
    bl _fe_peek
    cmp w0, #'$'
    b.eq Lfe_change_list_str
    cmp w0, #'('
    b.eq Lfe_change_list_var
    sub w9, w0, #'0'
    cmp w9, #9
    b.ls Lfe_change_list_var
    mov w0, #1
    bl _fe_advance
    // CHANGE fixes the letter as a list (a table -> ILLEGAL VARIABLE)
    mov w0, w19
    mov w1, #1
    bl _fe_array_use
    mov w0, w19
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
Lfe_change_list_str:
    mov w0, #ERR_MISMATCHED_STRING
    bl _fe_err
Lfe_change_list_var:
    mov w0, #ERR_ILLEGAL_VARIABLE
    bl _fe_err
