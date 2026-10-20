// =====================================================================
// src/frontend/fe_files.s -- Fifth Edition files (LANGUAGE.md 7.21-7.26,
// IR.md 3.3, 4.3): FILES, SCRATCH #, RESTORE # (fe_input.s), PRINT #,
// INPUT #, IF END #, TOO MANY FILES and the `fsel` placement.
//
//   _fe_fsel()           emit `fsel tF` if a PRINT # / INPUT # is lowered
//   _fe_clear_file()     end of that statement: no file selected
//   _fe_files()          FILES name { ; name }            (statement)
//   _fe_scratch()        SCRATCH #e                       (statement)
//   _fe_print_file()     "#e" [","] after PRINT
//   _fe_input_file()     "#e" "," after INPUT
//   _fe_if_end()         "#e" (THEN | GOTO) n after IF END
//
// The designator of PRINT # / INPUT # is kept in _fe_cur_file (1 + its
// temp, 0 = none; fe_compile.s) while the statement is lowered; every
// print and input opcode is emitted after a call of _fe_fsel, which adds
// `fsel tF` right before it (IR.md 3.3.2: nothing may come between).
// =====================================================================
.include "baysick.inc"


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
// _fe_fsel -- inside PRINT # / INPUT #: emit `fsel tF` (the next emitted
//   instruction must be the print or input opcode it selects for).
//   in:  none
//   out: none
//   clobbers: x0-x17
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .globl _fe_fsel
    .p2align 2
_fe_fsel:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x9, _fe_cur_file@PAGE
    ldr w10, [x9, _fe_cur_file@PAGEOFF]
    cbz w10, 1f                         // no file selected: plain PRINT / INPUT
    FE_NONE
    sub w1, w10, #1                     // A = the designator temp
    mov w0, #OP_FSEL
    bl _fe_emit
1:
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// _fe_clear_file -- the PRINT # / INPUT # statement is lowered.
//   in: none   out: none   clobbers: x9   leaf, no frame
// ---------------------------------------------------------------------
    .globl _fe_clear_file
    .p2align 2
_fe_clear_file:
    adrp x9, _fe_cur_file@PAGE
    str wzr, [x9, _fe_cur_file@PAGEOFF]
    ret

// ---------------------------------------------------------------------
// Lfe_files_designator -- "#" expression: the '#' at the scanner position
//   is consumed and the expression lowered (a string there is MISMATCHED
//   STRING OPERATION, nothing there ILLEGAL FORMULA, by _fe_expr).
//   in:  scanner at the '#'
//   out: w0 = temp of the designator value
//   clobbers: x0-x17, d0-d7
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_files_designator:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov w0, #1
    bl _fe_advance
    bl _fe_expr
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Lfe_files_select -- select the designator temp for the statement's
//   print / input opcodes (_fe_cur_file = 1 + temp).
//   in: w0 = temp   out: none   clobbers: x9, x10   leaf, no frame
// ---------------------------------------------------------------------
    .p2align 2
Lfe_files_select:
    add w10, w0, #1
    adrp x9, _fe_cur_file@PAGE
    str w10, [x9, _fe_cur_file@PAGEOFF]
    ret

// ---------------------------------------------------------------------
// _fe_print_file -- PRINT #e (LANGUAGE.md 7.24): the designator, then
//   only ',' (consumed; the item list follows) or the end of the line
//   may follow, else INCORRECT FORMAT (PRINT #1 X). Selects the file.
//   in:  scanner at the '#' after PRINT
//   out: none
//   clobbers: x0-x17, d0-d7
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .globl _fe_print_file
    .p2align 2
_fe_print_file:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl Lfe_files_designator
    bl Lfe_files_select
    bl _fe_at_eol
    cbnz w0, 1f                         // PRINT #e alone: an empty line
    bl _fe_next_op
    cmp w0, #TK_COMMA
    b.eq 1f
    mov w0, #ERR_INCORRECT_FORMAT
    bl _fe_err
1:
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// _fe_input_file -- INPUT #e, (LANGUAGE.md 7.25): the designator, then a
//   ',' is required (INPUT #1 A, INPUT #1 alone: INCORRECT FORMAT).
//   Selects the file.
//   in:  scanner at the '#' after INPUT
//   out: none
//   clobbers: x0-x17, d0-d7
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .globl _fe_input_file
    .p2align 2
_fe_input_file:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl Lfe_files_designator
    bl Lfe_files_select
    mov w0, #TK_COMMA
    mov w1, #ERR_INCORRECT_FORMAT
    bl _fe_expect_op
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// _fe_if_end -- IF END #e (THEN | GOTO) n (LANGUAGE.md 7.26): e; `jeof
//   te, @n`. THEN/GOTO missing -> INCORRECT FORMAT; the line number as in
//   GOTO (a missing line or a jump across a body boundary is recorded for
//   phase 3 and nothing is emitted).
//   in:  scanner at the '#' after IF END
//   out: none
//   clobbers: x0-x17, d0-d7
//   callee-saved: w19 = designator temp, w20 = target label
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .globl _fe_if_end
    .p2align 2
_fe_if_end:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    bl Lfe_files_designator
    mov w19, w0
    bl _fe_next_op
    cmp w0, #TK_THEN
    b.eq 1f
    cmp w0, #TK_GOTO
    b.eq 1f
    mov w0, #ERR_INCORRECT_FORMAT
    bl _fe_err
1:
    bl _fe_jump_target
    mov w20, w0
    bl _fe_expect_eol
    tbnz w20, #31, 2f                   // bad target: nothing emitted
    FE_NONE
    mov w1, w19
    mov w4, w20                         // X = target label
    mov w0, #OP_JEOF
    bl _fe_emit
2:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _fe_scratch -- SCRATCH #e (LANGUAGE.md 7.22): e; `scratch te`. A
//   missing '#' or text after the expression -> INCORRECT FORMAT.
//   in:  scanner after "SCRATCH"
//   out: none
//   clobbers: x0-x17, d0-d7
//   callee-saved: w19 = designator temp
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .globl _fe_scratch
    .p2align 2
_fe_scratch:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov w0, #0
    bl _fe_peek
    cmp w0, #'#'
    b.eq 1f
    mov w0, #ERR_INCORRECT_FORMAT
    bl _fe_err
1:
    bl Lfe_files_designator
    mov w19, w0
    bl _fe_expect_eol
    FE_NONE
    mov w1, w19
    mov w0, #OP_SCRATCH
    bl _fe_emit
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _fe_files -- FILES name { ; name } (LANGUAGE.md 7.21). Not executable:
//   each name is added to the module (_ir_add_file, file numbers 1, 2, ...
//   in ascending line order) and nothing is emitted. A name is quoted
//   ('"' bytes '"', exactly the bytes between the quotes) or unquoted (the
//   compacted bytes up to the next ';', '"' or the end of the line).
//   Errors, left to right: a ninth name starting anywhere in the program
//   (at a position where a name is expected, whatever follows) -> TOO
//   MANY FILES; an empty name, a byte 0 in a name, an unterminated quote,
//   or anything but ';' or the end of the line after a name -> INCORRECT
//   FORMAT.
//   in:  scanner after "FILES"
//   out: none
//   clobbers: x0-x17
//   callee-saved: x19 = cursor, x20 = line end, x21 = name start,
//        w22 = name length, w23 = 1 after the last name
//   frame: 64 bytes
// ---------------------------------------------------------------------
    .globl _fe_files
    .p2align 2
_fe_files:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]
Lfe_files_name:
    // a name starts here: at most LIM_FILES in the whole program
    adrp x9, _fe_nfiles@PAGE
    ldr w10, [x9, _fe_nfiles@PAGEOFF]
    cmp w10, #LIM_FILES
    b.lo 1f
    mov w0, #ERR_TOO_MANY_FILES
    bl _fe_err
1:
    bl _fe_getpos
    mov x19, x0
    adrp x9, _fe_end@PAGE
    ldr x20, [x9, _fe_end@PAGEOFF]
    cmp x19, x20
    b.hs Lfe_files_format               // FILES, FILES A;  : an empty name
    ldrb w9, [x19]
    cmp w9, #'"'
    b.eq Lfe_files_quoted
    // unquoted: up to ';', '"' or the end of the line
    mov x21, x19
2:
    cmp x19, x20
    b.hs 3f
    ldrb w9, [x19]
    cmp w9, #';'
    b.eq 3f
    cmp w9, #'"'
    b.eq 3f
    cbz w9, Lfe_files_format            // a byte 0 in the name
    add x19, x19, #1
    b 2b
3:
    sub x22, x19, x21
    cbz x22, Lfe_files_format           // FILES ;A : an empty name
    b Lfe_files_after
Lfe_files_quoted:
    // quoted: the bytes between the quotes
    add x19, x19, #1
    mov x21, x19
4:
    cmp x19, x20
    b.hs Lfe_files_format               // unterminated
    ldrb w9, [x19]
    cmp w9, #'"'
    b.eq 5f
    cbz w9, Lfe_files_format            // a byte 0 in the name
    add x19, x19, #1
    b 4b
5:
    sub x22, x19, x21
    cbz x22, Lfe_files_format           // FILES "" : an empty name
    add x19, x19, #1                    // after the closing quote
Lfe_files_after:
    // only ';' (another name follows) or the end of the line
    mov w23, #1
    cmp x19, x20
    b.hs 6f
    ldrb w9, [x19]
    cmp w9, #';'
    b.ne Lfe_files_format               // FILES "A"B, FILES A"B"
    add x19, x19, #1
    mov w23, #0
6:
    mov x0, x19
    bl _fe_setpos
    // file number nfiles + 1
    adrp x9, _fe_module@PAGE
    ldr x0, [x9, _fe_module@PAGEOFF]
    mov x1, x21
    mov w2, w22
    bl _ir_add_file
    adrp x9, _fe_nfiles@PAGE
    ldr w10, [x9, _fe_nfiles@PAGEOFF]
    add w10, w10, #1
    str w10, [x9, _fe_nfiles@PAGEOFF]
    cbz w23, Lfe_files_name
    ldr x23, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret
Lfe_files_format:
    mov w0, #ERR_INCORRECT_FORMAT
    bl _fe_err
