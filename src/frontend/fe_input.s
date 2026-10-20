// =====================================================================
// src/frontend/fe_input.s -- INPUT, RESTORE, ON ... GO TO and RANDOMIZE
// (LANGUAGE.md 7.15-7.18, IR.md 4.3). MAT INPUT is in fe_mat.s.
//
//   _fe_input()       INPUT target {, target}
//   _fe_restore()     RESTORE / RESTORE* / RESTORE$
//   _fe_on()          ON expression (GOTO | THEN) n {, n}
//   _fe_randomize()   RANDOMIZE / RANDOM
//
// Each is a statement handler (fe_stmt.s keyword table): entered with the
// scanner after the keyword; errors leave through _fe_err.
// Fifth Edition: INPUT #e, targets (LANGUAGE.md 7.25)
// and RESTORE #e (7.23); the file selection is fe_files.s.
// =====================================================================
.include "baysick.inc"

.equ FE_PEEK_EOL,       0x100       // _fe_peek result beyond the line end
.equ FE_TGT_STRING,     4           // target descriptor kind (fe_stmt.s)
.equ FE_ON_MAX,         128         // line numbers per ON (a 255-byte line has < 128)

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
// _fe_input -- INPUT target {, target} (LANGUAGE.md 7.15). Targets as in
//   READ (no target at all -> ILLEGAL VARIABLE). Lowering: `inbeg`; per
//   target: numeric: [subscripts]; `tN = innum`; its store; string: its
//   `svar` or subscript, then `insv` (plain or element form,
//   _fe_sstore); finally `inend`.
//   INPUT #e, targets (Fifth Edition): e (-> tF), then a ',' is required
//   (else INCORRECT FORMAT); `fsel tF` precedes `inbeg`, every `innum` /
//   `insv` and `inend` (IR.md 4.3, _fe_fsel).
//   in:  scanner after "INPUT"
//   out: none
//   clobbers: x0-x17, d0-d7
//   callee-saved: none used
//   frame: 32 bytes (frame record, 16-byte target descriptor at sp+16)
// ---------------------------------------------------------------------
    .globl _fe_input
    .p2align 2
_fe_input:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    mov w0, #0
    bl _fe_peek
    cmp w0, #'#'
    b.ne 4f
    bl _fe_input_file                   // the designator and its ','
4:
    bl _fe_fsel
    FE_NONE
    mov w0, #OP_INBEG
    bl _fe_emit
Lfe_input_loop:
    mov w0, #0                          // no FN target
    add x1, sp, #16
    bl _fe_target
    ldr w9, [sp, #16]
    cmp w9, #FE_TGT_STRING
    b.ne 1f
    // `insv tS` / `insv L$, ti` (element form: subscript checked at the
    // store, after the field is taken)
    add x0, sp, #16
    mov w1, #OP_INSV
    bl _fe_sstore
    b 2f
1:
    // tN = innum; store it
    bl _fe_fsel
    FE_NONE
    mov w0, #OP_INNUM
    bl _fe_emit_new
    mov w1, w0
    add x0, sp, #16
    bl _fe_store
2:
    // ',' continues the list, end of line finishes it
    bl _fe_next_op
    cmp w0, #TK_COMMA
    b.eq Lfe_input_loop
    cmp w0, #TK_EOL
    b.eq 3f
    mov w0, #ERR_INCORRECT_FORMAT
    bl _fe_err
3:
    bl _fe_fsel
    FE_NONE
    mov w0, #OP_INEND
    bl _fe_emit
    bl _fe_clear_file                   // the INPUT # selection ends here
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _fe_restore -- RESTORE (both blocks), RESTORE* (numeric), RESTORE$
//   (string); anything else after the keyword -> INCORRECT FORMAT.
//   Lowering: `restore all|num|str`. Fifth Edition: RESTORE #e (7.23):
//   e; `frestore te`.
//   in:  scanner after "RESTORE"
//   out: none
//   clobbers: x0-x17
//   callee-saved: w19 = RESTORE_* variant
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .globl _fe_restore
    .p2align 2
_fe_restore:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov w19, #RESTORE_ALL
    mov w0, #0
    bl _fe_peek
    cmp w0, #'*'
    b.ne 1f
    mov w19, #RESTORE_NUM
    b 2f
1:
    cmp w0, #'$'
    b.ne 4f
    mov w19, #RESTORE_STR
    b 2f
4:
    cmp w0, #'#'
    b.ne 3f
    // RESTORE #e: e; frestore te
    mov w0, #1
    bl _fe_advance
    bl _fe_expr
    mov w19, w0
    bl _fe_expect_eol
    FE_NONE
    mov w1, w19
    mov w0, #OP_FRESTORE
    bl _fe_emit
    b 5f
2:
    mov w0, #1
    bl _fe_advance
3:
    bl _fe_expect_eol
    FE_NONE
    mov w5, w19                         // IMM = variant (zero-extended)
    mov w0, #OP_RESTORE
    bl _fe_emit
5:
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _fe_randomize -- RANDOMIZE (or RANDOM) with nothing after it.
//   Lowering: `randomize`.
//   in:  scanner after the keyword
//   out: none
//   clobbers: x0-x17
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .globl _fe_randomize
    .p2align 2
_fe_randomize:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl _fe_expect_eol
    FE_NONE
    mov w0, #OP_RANDOMIZE
    bl _fe_emit
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// _fe_on -- ON e (GOTO | THEN) n1, ..., nN (LANGUAGE.md 7.17). GOTO/THEN
//   missing -> INCORRECT FORMAT (also ON ... GOSUB); each line number as
//   in GOTO; a missing one (trailing ',') or text left over -> INCORRECT
//   FORMAT. Lowering: e; `tk = onsel te, N`; for i = 1 .. N-1:
//   `tc = const i`, `jcmp eq, tk, tc, @ni`; then `jmp @nN`. A jump to a
//   missing line or across a body boundary is not emitted (the program is
//   rejected in phase 3).
//   in:  scanner after "ON"
//   out: none
//   clobbers: x0-x17, d0-d7
//   callee-saved: w19 = selector temp, w20 = line count N, w21 = index i,
//        w22 = onsel temp, x23 = label array
//   frame: 64 bytes + FE_ON_MAX labels (512 bytes) below it
// ---------------------------------------------------------------------
    .globl _fe_on
    .p2align 2
_fe_on:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]
    sub sp, sp, #(FE_ON_MAX * 4)
    mov x23, sp
    bl _fe_expr
    mov w19, w0
    // GOTO or THEN
    bl _fe_next_op
    cmp w0, #TK_GOTO
    b.eq 1f
    cmp w0, #TK_THEN
    b.eq 1f
    mov w0, #ERR_INCORRECT_FORMAT
    bl _fe_err
1:
    mov w20, #0
Lfe_on_line:
    cmp w20, #FE_ON_MAX
    b.lo 2f
    mov w0, #ERR_INCORRECT_FORMAT
    bl _fe_err
2:
    bl _fe_jump_target
    str w0, [x23, x20, lsl #2]
    add w20, w20, #1
    // ',' -> another line number; end of line -> done
    mov w0, #0
    bl _fe_peek
    cmp w0, #FE_PEEK_EOL
    b.eq Lfe_on_lower
    cmp w0, #','
    b.eq 3f
    mov w0, #ERR_INCORRECT_FORMAT
    bl _fe_err
3:
    mov w0, #1
    bl _fe_advance
    b Lfe_on_line
Lfe_on_lower:
    // tk = onsel te, N
    FE_NONE
    mov w1, w19
    mov w5, w20                         // IMM = N
    mov w0, #OP_ONSEL
    bl _fe_emit_new
    mov w22, w0
    // for i = 1 .. N-1: tc = const i; jcmp eq, tk, tc, @ni
    mov w21, #1
Lfe_on_case:
    cmp w21, w20
    b.hs Lfe_on_last
    scvtf d0, w21
    FE_NONE
    fmov x5, d0                         // IMM = bits of the double i
    mov w0, #OP_CONST
    bl _fe_emit_new
    sub w9, w21, #1
    ldr w4, [x23, x9, lsl #2]           // X = label of n_i
    tbnz w4, #31, 4f                    // a bad target: nothing emitted
    mov w2, w0
    mov w1, w22
    mov w3, #IR_NONE
    mov x5, #0
    mov w6, #REL_EQ
    mov w0, #OP_JCMP
    bl _fe_emit
4:
    add w21, w21, #1
    b Lfe_on_case
Lfe_on_last:
    // jmp @nN
    sub w9, w20, #1
    ldr w9, [x23, x9, lsl #2]
    tbnz w9, #31, 5f
    FE_NONE
    mov w4, w9
    mov w0, #OP_JMP
    bl _fe_emit
5:
    add sp, sp, #(FE_ON_MAX * 4)
    ldr x23, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret
