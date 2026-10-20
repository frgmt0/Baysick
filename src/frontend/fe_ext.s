// =====================================================================
// src/frontend/fe_ext.s -- the Baysick extensions (LANGUAGE.md 15,
// IR.md 3.5, 4.3): LINPUT and the status of END e / STOP e.
//
//   _fe_linput()       LINPUT target / LINPUT #e, target  (statement)
//   _fe_exit_status()  the status expression of END e / STOP e: `exit`
//
// PRINT #-1 (LANGUAGE.md 15.3) needs nothing here: any designator is
// lowered by the PRINT # path (fe_files.s), and only the runtime tells -1
// from a file number.
// =====================================================================
.include "baysick.inc"

.include "fe_targets.inc"

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
// _fe_linput -- LINPUT target, LINPUT #e, target (LANGUAGE.md 15.2).
//   The designator and its ',' exactly as for INPUT # (_fe_input_file:
//   a missing ',' -> INCORRECT FORMAT, `LINPUT #` alone -> ILLEGAL
//   FORMULA, a string designator -> MISMATCHED STRING OPERATION); then
//   exactly one target as for INPUT (no FN target; none, or a text that
//   is not a target -> ILLEGAL VARIABLE); a numeric target -> MISMATCHED
//   STRING OPERATION; anything after the target -> INCORRECT FORMAT.
//   Lowering (IR.md 4.3): [e (-> tF);] the target's `svar` / `sparam` or
//   subscripts; [`fsel tF`;] `linput tS` (a list element: the element
//   form `linput L$, ti`; a table element: the cell form) -- the same
//   placement as `insv` in INPUT #, by _fe_sstore.
//   in:  scanner after "LINPUT"
//   out: none
//   clobbers: x0-x17, d0-d7
//   callee-saved: none used
//   frame: 32 bytes (frame record, 16-byte target descriptor at sp+16)
// ---------------------------------------------------------------------
    .globl _fe_linput
    .p2align 2
_fe_linput:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    // '#': the designator and its ',' (selects the file for _fe_fsel)
    mov w0, #0
    bl _fe_peek
    cmp w0, #'#'
    b.ne 1f
    bl _fe_input_file
1:
    // the one target: its subscripts / svar / sparam are lowered now
    mov w0, #0                          // no FN target
    add x1, sp, #16
    bl _fe_target
    ldr w9, [sp, #16]
    cmp w9, #FE_TGT_STRING
    b.eq 2f
    mov w0, #ERR_MISMATCHED_STRING      // LINPUT A, LINPUT #1, X(2)
    bl _fe_err
2:
    // nothing may follow the target (LINPUT A$, B$: INCORRECT FORMAT)
    bl _fe_expect_eol
    // [fsel tF;] linput (plain, element or cell form)
    add x0, sp, #16
    mov w1, #OP_LINPUT
    bl _fe_sstore
    bl _fe_clear_file                   // the LINPUT # selection ends here
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _fe_exit_status -- the status expression of END e / STOP e
//   (LANGUAGE.md 15.4): a numeric expression (a string ->
//   MISMATCHED STRING OPERATION, an expression error -> that error, by
//   _fe_expr), then the end of the text (else INCORRECT FORMAT).
//   Lowering: e; `exit te` (END adds its `end` itself, IR.md 4.3).
//   in:  scanner after the keyword, not at the end of the text
//   out: none
//   clobbers: x0-x17, d0-d7
//   callee-saved: w19 = status temp
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .globl _fe_exit_status
    .p2align 2
_fe_exit_status:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    bl _fe_expr                         // the status value
    mov w19, w0
    bl _fe_expect_eol                   // STOP 1, 2: INCORRECT FORMAT
    // exit te
    FE_NONE
    mov w1, w19
    mov w0, #OP_EXIT
    bl _fe_emit
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

