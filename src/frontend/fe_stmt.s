// =====================================================================
// src/frontend/fe_stmt.s -- statement recognition, parsing and lowering
// (LANGUAGE.md sections 3 and 7, IR.md sections 4.3-4.4).
//
//   _fe_stmt()     parse the statement text of the current line (the
//                  scanner window) and lower it into the current function
//   _fe_keyword(x0=text, w1=len) -> w0 KW_* or -1, w1 keyword length
//   _fe_target(w0=allow FN, x1=descriptor)   a LET/READ/INPUT target
//   _fe_store(x0=descriptor, w1=value temp)  store into a numeric target
//   _fe_starget_ref(x0=descriptor) -> w0 sref  a LET string target, at its store
//   _fe_sstore(x0=descriptor, w1=opcode)     `sread`/`insv` into a string target
//   _fe_jump_target() -> w0 label or -1      a line-number operand
//
// Every statement must consume its whole text; leftover text is
// INCORRECT FORMAT. Errors leave through _fe_err (fe_compile.s). This file
// has LET, PRINT, END, READ, DATA, GOTO, IF, FOR, NEXT, GOSUB, RETURN,
// DIM, REM, STOP; DEF/FNEND are in fe_def.s, MAT in fe_mat.s, INPUT,
// RESTORE, ON, RANDOMIZE in fe_input.s, CHANGE in fe_str.s.
//
// FOR stack entry (_fe_forstack, FE_FOR_ENTRY = 16 bytes, see
// fe_compile.s): +0 u32 loop variable slot, +4 u32 FOR index k,
// +8 u32 label B (loop body), +12 u32 label X (after the NEXT).
// Array state entry (_fe_arrays / _fe_sarrays, 16 bytes): +0 dims,
// +4 b1, +8 b2, +12 flags (IRA_FLAG_DIMMED).
//
// Target descriptor (FE_TGT_SIZE = 16 bytes, filled by _fe_target):
//   +0 u32 kind FE_TGT_*, +4 u32 scalar slot / array letter / FN letter,
//   +8 u32 first subscript temp (a string target: the subscript temp of a
//   list element, the `svar` sref temp of a string variable), +12 u32
//   second subscript temp (or IR_NONE). A string target has +4 = the
//   list letter, or IR_NONE for a string variable.
// =====================================================================
.include "baysick.inc"

.equ FE_FOR_ENTRY,      16          // see fe_compile.s
.equ FE_KW_ENTRY,       16          // keyword table: length, id, 14 chars
.equ FE_PEEK_EOL,       0x100       // _fe_peek result beyond the line end
.equ FE_BITS_ONE,       0x3FF0000000000000  // IEEE-754 bits of 1.0
.equ FE_CTX_ML,         2           // _fe_ctx_kind of a multi-line body (fe_def.s)

// target descriptor kinds (numeric kinds = number of subscripts)
.equ FE_TGT_SCALAR,     0
.equ FE_TGT_LIST,       1
.equ FE_TGT_TABLE,      2
.equ FE_TGT_FN,         3           // LET FNx = ... inside FNx's body
.equ FE_TGT_STRING,     4           // A$ (+8 = sref) or A$(i) (+8 = subscript)
.equ FE_TGT_SIZE,       16
.equ FE_LET_MAX,        128         // targets per LET (a 255-byte line has < 128)

// raw names returned by Lfe_stmt_name
.equ FE_RAW_SCALAR,     0           // w1 = scalar slot
.equ FE_RAW_ARRAY,      1           // w1 = letter, '(' consumed
.equ FE_RAW_SVAR,       2           // w1 = string slot
.equ FE_RAW_SARRAY,     3           // w1 = letter, '(' consumed
.equ FE_RAW_FN,         4           // w1 = letter

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

// FE_ADR reg, sym: reg = address of sym
.macro FE_ADR reg, sym
    adrp \reg, \sym@PAGE
    add \reg, \reg, \sym@PAGEOFF
.endm

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _fe_keyword -- which statement keyword starts a statement text
//   (LANGUAGE.md 3.1: tested in table order as a prefix; RANDOMIZE before
//   its short form RANDOM).
//   in:  x0 = statement text, w1 = its length
//   out: w0 = KW_* id or -1 if none matches, w1 = keyword length
//   clobbers: x0-x1, x9-x15   leaf, no frame
// ---------------------------------------------------------------------
    .globl _fe_keyword
    .p2align 2
_fe_keyword:
    FE_ADR x9, Lfe_stmt_keywords
Lfe_keyword_loop:
    ldrb w10, [x9]                      // keyword length (0 = end of table)
    cbz w10, Lfe_keyword_none
    ldrb w11, [x9, #1]                  // its id
    cmp w1, w10
    b.lo Lfe_keyword_next               // text too short
    // compare the keyword with the start of the text
    mov x12, #0
1:
    cmp x12, x10
    b.hs Lfe_keyword_match
    add x13, x9, #2
    ldrb w14, [x13, x12]
    ldrb w15, [x0, x12]
    cmp w14, w15
    b.ne Lfe_keyword_next
    add x12, x12, #1
    b 1b
Lfe_keyword_next:
    add x9, x9, #FE_KW_ENTRY
    b Lfe_keyword_loop
Lfe_keyword_match:
    mov w0, w11
    mov w1, w10
    ret
Lfe_keyword_none:
    mov w0, #-1
    mov w1, #0
    ret

// ---------------------------------------------------------------------
// _fe_stmt -- recognise the keyword and run that statement's parser.
//   in:  scanner window = statement text of the current line
//   out: none (code emitted); ILLEGAL INSTRUCTION if no keyword matches
//   clobbers: x0-x17, d0-d7
//   callee-saved: x19 = keyword id
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .globl _fe_stmt
    .p2align 2
_fe_stmt:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    adrp x9, _fe_pos@PAGE
    ldr x0, [x9, _fe_pos@PAGEOFF]
    adrp x9, _fe_end@PAGE
    ldr x1, [x9, _fe_end@PAGEOFF]
    sub x1, x1, x0
    bl _fe_keyword
    tbnz w0, #31, Lfe_stmt_none
    mov w19, w0
    // skip the keyword and dispatch through the handler table
    mov w0, w1
    bl _fe_advance
    FE_ADR x9, Lfe_stmt_handlers
    ldr x9, [x9, x19, lsl #3]
    blr x9
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
Lfe_stmt_none:
    mov w0, #ERR_ILLEGAL_INSTRUCTION
    bl _fe_err

// ---------------------------------------------------------------------
// Lfe_stmt_name -- the name of a LET/READ/INPUT target or a FOR/NEXT
//   variable, consumed:
//     "FN" letter            (only if allowed: LET)       FE_RAW_FN
//     letter [digit]                                       FE_RAW_SCALAR
//     letter "("             ('(' consumed)                FE_RAW_ARRAY
//     letter [digit] "$"                                   FE_RAW_SVAR
//     letter "$" "("         ('(' consumed)                FE_RAW_SARRAY
//   Not a letter, letter+digit+'(' or letter+digit+'$(' -> ILLEGAL VARIABLE.
//   in:  w0 = 1 if an FN name is allowed, else 0
//   out: w0 = FE_RAW_* kind, w1 = slot / letter
//   clobbers: x0-x17
//   callee-saved: w19 = letter, w20 = second byte, w21 = third byte,
//        w22 = FN allowed
//   frame: 48 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_name:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov w22, w0
    mov w0, #0
    bl _fe_peek
    sub w19, w0, #'A'
    cmp w19, #25
    b.hi Lfe_stmt_name_bad              // not a letter
    mov w0, #1
    bl _fe_peek
    mov w20, w0
    mov w0, #2
    bl _fe_peek
    mov w21, w0
    // FN letter (the value variable of a multi-line function)
    cbz w22, Lfe_stmt_name_var
    cmp w19, #('F' - 'A')
    b.ne Lfe_stmt_name_var
    cmp w20, #'N'
    b.ne Lfe_stmt_name_var
    sub w9, w21, #'A'
    cmp w9, #25
    b.hi Lfe_stmt_name_var
    mov w19, w9
    mov w0, #3
    bl _fe_advance
    mov w1, w19
    mov w0, #FE_RAW_FN
    b Lfe_stmt_name_ret
Lfe_stmt_name_var:
    mov w9, #SLOT_PER_LETTER
    mul w22, w19, w9                    // slot of the bare letter
    sub w9, w20, #'0'
    cmp w9, #9
    b.hi Lfe_stmt_name_nodigit
    // letter + digit (an array name cannot have a digit)
    add w22, w22, w9
    add w22, w22, #1                    // letter*11 + digit + 1
    cmp w21, #'('
    b.eq Lfe_stmt_name_bad
    cmp w21, #'$'
    b.ne 1f
    // C7$: a string variable (C7$( is not a name)
    mov w0, #3
    bl _fe_peek
    cmp w0, #'('
    b.eq Lfe_stmt_name_bad
    mov w0, #3
    bl _fe_advance
    mov w1, w22
    mov w0, #FE_RAW_SVAR
    b Lfe_stmt_name_ret
1:
    mov w0, #2
    bl _fe_advance
    mov w1, w22
    mov w0, #FE_RAW_SCALAR
    b Lfe_stmt_name_ret
Lfe_stmt_name_nodigit:
    cmp w20, #'$'
    b.ne 2f
    // A$ or A$(
    cmp w21, #'('
    b.eq 3f
    mov w0, #2
    bl _fe_advance
    mov w1, w22
    mov w0, #FE_RAW_SVAR
    b Lfe_stmt_name_ret
3:
    mov w0, #3
    bl _fe_advance
    mov w1, w19
    mov w0, #FE_RAW_SARRAY
    b Lfe_stmt_name_ret
2:
    cmp w20, #'('
    b.ne 4f
    mov w0, #2                          // array: consume letter and '('
    bl _fe_advance
    mov w1, w19
    mov w0, #FE_RAW_ARRAY
    b Lfe_stmt_name_ret
4:
    mov w0, #1                          // bare letter
    bl _fe_advance
    mov w1, w22
    mov w0, #FE_RAW_SCALAR
Lfe_stmt_name_ret:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
Lfe_stmt_name_bad:
    mov w0, #ERR_ILLEGAL_VARIABLE
    bl _fe_err

// ---------------------------------------------------------------------
// _fe_target -- parse one LET/READ/INPUT target and lower what is
//   evaluated before its value: the subscripts of an array element, the
//   `svar` of a string variable, the subscript of a string list element
//   (LET: its `sald1` is emitted at the store, _fe_starget_ref; READ and
//   INPUT: the element form of `sread` / `insv`, _fe_sstore; IR.md 4.3).
//   An FN target is only legal inside the multi-line body of that
//   function (else ILLEGAL VARIABLE, LANGUAGE.md 7.1).
//   in:  w0 = 1 if an FN target is allowed (LET), x1 = descriptor to fill
//   out: descriptor filled (see the file header)
//   clobbers: x0-x17, d0-d7
//   callee-saved: x19 = descriptor, w20 = raw kind, w21 = slot / letter
//   frame: 48 bytes
// ---------------------------------------------------------------------
    .globl _fe_target
    .p2align 2
_fe_target:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov x19, x1
    bl Lfe_stmt_name
    mov w20, w0
    mov w21, w1
    // defaults: no subscripts
    str w21, [x19, #4]
    mov w9, #IR_NONE
    str w9, [x19, #8]
    str w9, [x19, #12]
    cmp w20, #FE_RAW_ARRAY
    b.eq Lfe_target_array
    cmp w20, #FE_RAW_SVAR
    b.eq Lfe_target_svar
    cmp w20, #FE_RAW_SARRAY
    b.eq Lfe_target_sarray
    cmp w20, #FE_RAW_FN
    b.eq Lfe_target_fn
    // simple variable
    mov w9, #FE_TGT_SCALAR
    str w9, [x19]
    b Lfe_target_ret
Lfe_target_array:
    // subscripts now; their number is the descriptor kind (1 or 2)
    mov w0, w21
    bl _fe_subscripts
    str w0, [x19, #8]
    str w1, [x19, #12]
    str w2, [x19]
    b Lfe_target_ret
Lfe_target_svar:
    // tN = svar V$ (+4 = IR_NONE: no list element)
    FE_NONE
    mov w4, w21
    mov w0, #OP_SVAR
    bl _fe_emit_new
    mov w9, #IR_NONE
    str w9, [x19, #4]
    b Lfe_target_string
Lfe_target_sarray:
    // only i here; the subscript is checked at the store (`sald1` right
    // before `sset`, or the element form of sread / insv; LANGUAGE.md 7.1)
    mov w0, w21
    bl _fe_ssubscript
Lfe_target_string:
    str w0, [x19, #8]
    mov w9, #FE_TGT_STRING
    str w9, [x19]
    b Lfe_target_ret
Lfe_target_fn:
    // LET FNx = ... only in the multi-line body of FNx
    adrp x9, _fe_ctx_kind@PAGE
    ldr w9, [x9, _fe_ctx_kind@PAGEOFF]
    cmp w9, #FE_CTX_ML
    b.ne 1f
    adrp x9, _fe_ctx_letter@PAGE
    ldr w9, [x9, _fe_ctx_letter@PAGEOFF]
    cmp w9, w21
    b.eq 2f
1:
    mov w0, #ERR_ILLEGAL_VARIABLE
    bl _fe_err
2:
    mov w9, #FE_TGT_FN
    str w9, [x19]
Lfe_target_ret:
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// _fe_starget_ref -- the string reference of a LET string target,
//   emitted immediately before the `sset` that stores into it: a string
//   variable's `svar` temp (lowered with the target), or
//   `tN = sald1 L$, ti` for a list element, whose subscript is checked
//   here, at its store (LANGUAGE.md 7.1, IR.md 4.3).
//   in:  x0 = string target descriptor (kind FE_TGT_STRING)
//   out: w0 = sref temp
//   clobbers: x0-x17
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .globl _fe_starget_ref
    .p2align 2
_fe_starget_ref:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    ldr w9, [x0, #4]                    // list letter, or IR_NONE
    ldr w10, [x0, #8]                   // subscript temp / sref temp
    mov w0, w10
    mov w11, #IR_NONE
    cmp w9, w11                         // IR_NONE: a string variable
    b.eq 1f
    // tN = sald1 L$, ti
    FE_NONE
    mov w1, w10
    mov w4, w9
    mov w0, #OP_SALD1
    bl _fe_emit_new
1:
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// _fe_sstore -- emit `sread` or `insv` into a string target (IR.md 3.2,
//   4.3): a string variable: the plain form `op tS` (A = its `svar`
//   temp); a list element L$(i): the element form `op L$, ti` (A =
//   IR_NONE, B = the subscript temp, X = the letter), whose runtime call
//   takes the value first and checks the subscript at the store
//   (LANGUAGE.md 7.1, 7.4, 7.15).
//   in:  x0 = string target descriptor (kind FE_TGT_STRING),
//        w1 = OP_SREAD or OP_INSV
//   out: none
//   clobbers: x0-x17
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .globl _fe_sstore
    .p2align 2
_fe_sstore:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov w7, w1                          // opcode
    ldr w9, [x0, #4]                    // list letter, or IR_NONE
    ldr w10, [x0, #8]                   // subscript temp / sref temp
    FE_NONE
    mov w11, #IR_NONE
    cmp w9, w11                         // IR_NONE: a string variable
    b.eq 1f
    mov w2, w10                         // element form: B = subscript,
    mov w4, w9                          // X = list letter, A = IR_NONE
    b 2f
1:
    mov w1, w10                         // plain form: A = the svar sref
2:
    mov w0, w7
    bl _fe_emit
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// _fe_store -- emit the store of a value into a numeric target: `stv`
//   (or `stparam k` for a parameter of the enclosing multi-line DEF),
//   `ast1`, `ast2`, or `stfv` for the FN value variable.
//   in:  x0 = target descriptor, w1 = value temp
//   out: none
//   clobbers: x0-x17
//   callee-saved: x19 = descriptor, w20 = value
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .globl _fe_store
    .p2align 2
_fe_store:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    mov w20, w1
    ldr w9, [x19]
    cmp w9, #FE_TGT_LIST
    b.eq Lfe_store_list
    cmp w9, #FE_TGT_TABLE
    b.eq Lfe_store_table
    cmp w9, #FE_TGT_FN
    b.eq Lfe_store_fn
    // simple variable: a parameter of the DEF, or a global cell
    ldr w0, [x19, #4]
    mov w1, w20
    bl Lfe_stmt_stvar
    b Lfe_store_ret
Lfe_store_list:
    // ast1 L, ti, te
    FE_NONE
    ldr w4, [x19, #4]
    ldr w1, [x19, #8]
    mov w2, w20
    mov w0, #OP_AST1
    bl _fe_emit
    b Lfe_store_ret
Lfe_store_table:
    // ast2 L, ti, tj, te
    FE_NONE
    ldr w4, [x19, #4]
    ldr w1, [x19, #8]
    ldr w2, [x19, #12]
    mov w3, w20
    mov w0, #OP_AST2
    bl _fe_emit
    b Lfe_store_ret
Lfe_store_fn:
    // stfv te
    FE_NONE
    mov w1, w20
    mov w0, #OP_STFV
    bl _fe_emit
Lfe_store_ret:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lfe_stmt_stvar -- store into a simple variable: `stparam k, te` if it
//   is parameter k of the enclosing DEF, else `stv v, te`.
//   in:  w0 = scalar slot, w1 = value temp
//   out: none
//   clobbers: x0-x17
//   callee-saved: w19 = slot, w20 = value
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_stvar:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov w19, w0
    mov w20, w1
    bl _fe_param_index
    tbnz w0, #31, 1f
    mov w9, w0
    FE_NONE
    mov w1, w20
    mov x5, x9                          // IMM = parameter index
    mov w0, #OP_STPARAM
    bl _fe_emit
    b 2f
1:
    FE_NONE
    mov w1, w20
    mov w4, w19
    mov w0, #OP_STV
    bl _fe_emit
2:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lfe_stmt_ldvar -- load a simple variable: `tN = param k` if it is
//   parameter k of the enclosing DEF, else `tN = ldv v`.
//   in:  w0 = scalar slot
//   out: w0 = the new temp
//   clobbers: x0-x17
//   callee-saved: w19 = slot
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_ldvar:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov w19, w0
    bl _fe_param_index
    tbnz w0, #31, 1f
    mov w9, w0
    FE_NONE
    mov x5, x9                          // IMM = parameter index
    mov w0, #OP_PARAM
    bl _fe_emit_new
    b 2f
1:
    FE_NONE
    mov w4, w19
    mov w0, #OP_LDV
    bl _fe_emit_new
2:
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lfe_stmt_loopvar -- the variable of FOR / NEXT: a simple variable; an
//   array element is ILLEGAL VARIABLE, a string variable MISMATCHED
//   STRING OPERATION (LANGUAGE.md 7.8).
//   in: none   out: w0 = scalar slot
//   clobbers: x0-x17
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_loopvar:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov w0, #0
    bl Lfe_stmt_name
    cmp w0, #FE_RAW_SCALAR
    b.eq 2f
    cmp w0, #FE_RAW_SVAR
    b.eq 1f
    cmp w0, #FE_RAW_SARRAY
    b.eq 1f
    mov w0, #ERR_ILLEGAL_VARIABLE
    bl _fe_err
1:
    mov w0, #ERR_MISMATCHED_STRING
    bl _fe_err
2:
    mov w0, w1
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// _fe_jump_target -- a line-number operand (GOTO, GOSUB, IF, ON): digits
//   (none -> INCORRECT FORMAT, more than 5 -> ILLEGAL LINE NUMBER). A line
//   that does not exist, or one on the other side of a multi-line body
//   boundary, is remembered (first one only) for the phase-3 UNDEFINED
//   NUMBER / ILLEGAL TRANSFER errors and gives -1.
//   in:  none
//   out: w0 = label id of the target line in the current function, or -1
//   clobbers: x0-x17
//   callee-saved: w19 = line value
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .globl _fe_jump_target
    .p2align 2
_fe_jump_target:
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
    mov w0, w19
    bl _fe_line_lookup
    tbz w0, #31, 3f
    // missing target: keep the first such line for UNDEFINED NUMBER
    adrp x9, _fe_undef_line@PAGE
    ldr w10, [x9, _fe_undef_line@PAGEOFF]
    cbnz w10, 4f
    adrp x11, _fe_line@PAGE
    ldr w11, [x11, _fe_line@PAGEOFF]
    str w11, [x9, _fe_undef_line@PAGEOFF]
    b 4f
3:
    // the target must belong to the same function as this line
    adrp x9, _fe_linefn@PAGE
    ldr x9, [x9, _fe_linefn@PAGEOFF]
    ldr w10, [x9, w0, uxtw #2]
    adrp x9, _fe_curowner@PAGE
    ldr w11, [x9, _fe_curowner@PAGEOFF]
    cmp w10, w11
    b.eq 5f
    adrp x9, _fe_xfer_line@PAGE
    ldr w10, [x9, _fe_xfer_line@PAGEOFF]
    cbnz w10, 4f
    adrp x11, _fe_line@PAGE
    ldr w11, [x11, _fe_line@PAGEOFF]
    str w11, [x9, _fe_xfer_line@PAGEOFF]
4:
    mov w0, #-1
    b 6f
5:
    adrp x9, _fe_linelab@PAGE
    ldr x9, [x9, _fe_linelab@PAGEOFF]
    ldr w0, [x9, w0, uxtw #2]
6:
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lfe_stmt_lineref -- a line-number operand that ends the statement
//   (GOTO, GOSUB, IF): _fe_jump_target, then end of line.
//   in:  none
//   out: w0 = label id, or -1 (nothing is to be emitted)
//   clobbers: x0-x17
//   callee-saved: w19 = label
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_lineref:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    bl _fe_jump_target
    mov w19, w0
    bl _fe_expect_eol
    mov w0, w19
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lfe_stmt_let -- LET target { = target } = value (LANGUAGE.md 7.1).
//   After the first target (and after each '='), a target immediately
//   followed by '=' is another target; otherwise the rest is the value.
//   All targets are numeric (FN included) or all are strings.
//   Lowering (IR.md 4.3): each target's subscripts (a string variable:
//   its `svar`), left to right; the value; the stores left to right (a
//   string list element: `sald1` just before its `sset`).
//   in: scanner after "LET"   out: none
//   clobbers: x0-x17, d0-d7
//   callee-saved: x19 = descriptor array, w20 = target count,
//        w21 = 1 for string targets, w22 = value temp, w23 = index
//   frame: 64 bytes + FE_LET_MAX descriptors (2048 bytes) below it
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_let:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]
    sub sp, sp, #(FE_LET_MAX * FE_TGT_SIZE)
    mov x19, sp
    // first target (FN allowed), which fixes the kind
    mov w0, #1
    mov x1, x19
    bl _fe_target
    mov w20, #1
    ldr w9, [x19]
    cmp w9, #FE_TGT_STRING
    cset w21, eq
    mov w0, #TK_EQ
    mov w1, #ERR_INCORRECT_FORMAT
    bl _fe_expect_op
Lfe_stmt_let_more:
    // another "target =" ?
    bl Lfe_stmt_let_is_target
    cbz w0, Lfe_stmt_let_value
    cmp w20, #FE_LET_MAX
    b.lo 1f
    mov w0, #ERR_INCORRECT_FORMAT
    bl _fe_err
1:
    mov w0, #1
    add x1, x19, x20, lsl #4
    bl _fe_target
    // every target of one kind
    add x9, x19, x20, lsl #4
    ldr w9, [x9]
    cmp w9, #FE_TGT_STRING
    cset w9, eq
    cmp w9, w21
    b.eq 2f
    mov w0, #ERR_MISMATCHED_STRING
    bl _fe_err
2:
    add w20, w20, #1
    mov w0, #TK_EQ
    mov w1, #ERR_INCORRECT_FORMAT
    bl _fe_expect_op
    b Lfe_stmt_let_more
Lfe_stmt_let_value:
    cbnz w21, Lfe_stmt_let_string
    // numeric value; then the stores, left to right
    bl _fe_expr
    mov w22, w0
    bl _fe_expect_eol
    mov w23, #0
3:
    cmp w23, w20
    b.hs Lfe_stmt_let_ret
    add x0, x19, x23, lsl #4
    mov w1, w22
    bl _fe_store
    add w23, w23, #1
    b 3b
Lfe_stmt_let_string:
    // a string reference; then for each target its sref (`sald1` for a
    // list element) and `sset ts, tr`
    bl _fe_sref_need
    mov w22, w0
    bl _fe_sref_end
    bl _fe_expect_eol
    mov w23, #0
4:
    cmp w23, w20
    b.hs Lfe_stmt_let_ret
    add x0, x19, x23, lsl #4
    bl _fe_starget_ref                  // the target's sref, at its store
    mov w9, w0
    FE_NONE
    mov w1, w9                          // A = the target's sref
    mov w2, w22                         // B = the value's sref
    mov w0, #OP_SSET
    bl _fe_emit
    add w23, w23, #1
    b 4b
Lfe_stmt_let_ret:
    add sp, sp, #(FE_LET_MAX * FE_TGT_SIZE)
    ldr x23, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

// ---------------------------------------------------------------------
// Lfe_stmt_let_is_target -- does the text at the scanner position start
//   with a LET target immediately followed by '='? Looks ahead only
//   (nothing is consumed or emitted): "FN" letter "=", or letter [digit]
//   ["$"] [ "(" ... ")" ] "=" with the parentheses balanced (quotes
//   respected).
//   in:  none
//   out: w0 = 1 if so, else 0
//   clobbers: x0, x9-x15   leaf, no frame
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_let_is_target:
    adrp x9, _fe_pos@PAGE
    ldr x10, [x9, _fe_pos@PAGEOFF]      // cursor
    adrp x9, _fe_end@PAGE
    ldr x11, [x9, _fe_end@PAGEOFF]      // line end
    // a letter is required
    cmp x10, x11
    b.hs Lfe_let_is_no
    ldrb w12, [x10]
    sub w13, w12, #'A'
    cmp w13, #25
    b.hi Lfe_let_is_no
    // "FN" letter "=" (the value variable of a multi-line function)
    cmp w12, #'F'
    b.ne 1f
    add x14, x10, #3
    cmp x14, x11
    b.hs 1f
    ldrb w13, [x10, #1]
    cmp w13, #'N'
    b.ne 1f
    ldrb w13, [x10, #2]
    sub w13, w13, #'A'
    cmp w13, #25
    b.hi 1f
    ldrb w13, [x10, #3]
    cmp w13, #'='
    b.eq Lfe_let_is_yes
1:
    add x10, x10, #1
    // optional digit
    cmp x10, x11
    b.hs Lfe_let_is_no
    ldrb w12, [x10]
    sub w13, w12, #'0'
    cmp w13, #9
    b.hi 2f
    add x10, x10, #1
    cmp x10, x11
    b.hs Lfe_let_is_no
    ldrb w12, [x10]
2:
    // optional '$'
    cmp w12, #'$'
    b.ne 3f
    add x10, x10, #1
    cmp x10, x11
    b.hs Lfe_let_is_no
    ldrb w12, [x10]
3:
    // optional balanced subscript list
    cmp w12, #'('
    b.ne Lfe_let_is_eq
    add x10, x10, #1
    mov w14, #1                         // open parentheses
    mov w15, #0                         // inside a string
4:
    cmp x10, x11
    b.hs Lfe_let_is_no
    ldrb w12, [x10], #1
    cmp w12, #'"'
    b.ne 5f
    eor w15, w15, #1
    b 4b
5:
    cbnz w15, 4b
    cmp w12, #'('
    b.ne 6f
    add w14, w14, #1
    b 4b
6:
    cmp w12, #')'
    b.ne 4b
    subs w14, w14, #1
    b.ne 4b
    cmp x10, x11
    b.hs Lfe_let_is_no
    ldrb w12, [x10]
Lfe_let_is_eq:
    cmp w12, #'='
    b.ne Lfe_let_is_no
Lfe_let_is_yes:
    mov w0, #1
    ret
Lfe_let_is_no:
    mov w0, #0
    ret

// ---------------------------------------------------------------------
// Lfe_stmt_print -- PRINT [item-list] (LANGUAGE.md 7.2, IR.md 4.3).
//   Elements: string constant (prstr), string variable / list element
//   (prsv), TAB(e) (prtab), expression (prnum), ',' (prcomma), ';'
//   (prsemi only right after an expression). An expression must be
//   followed by ',', ';' or the end of the line; a string or TAB item may
//   be followed directly by another item.
//   in: scanner after "PRINT"   out: none
//   clobbers: x0-x17, d0-d7
//   callee-saved: w19 = previous element (FE_PR_*), x20 = saved
//        position, w21 = string length / temp
//   frame: 96 bytes (frame record, x19-x22, 40-byte token at sp+48)
// ---------------------------------------------------------------------
.equ FE_PR_NONE,        0
.equ FE_PR_STRING,      1           // string or TAB item
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
    // TAB( is recognised only at the start of an element
    adrp x9, _fe_end@PAGE
    ldr x9, [x9, _fe_end@PAGEOFF]
    sub x9, x9, x20
    cmp x9, #4
    b.lo 1f
    ldr w9, [x20]                       // the next four bytes
    movz w10, #0x4154                   // "TA"
    movk w10, #0x2842, lsl #16          // "B("
    cmp w9, w10
    b.eq Lfe_stmt_print_tab
1:
    mov w0, #SCAN_OPERAND
    add x1, sp, #48
    bl _fe_scan
    cmp w0, #TK_EOL
    b.eq Lfe_stmt_print_end
    cmp w0, #TK_STRING
    b.eq Lfe_stmt_print_string
    cmp w0, #TK_SVAR
    b.eq Lfe_stmt_print_sref
    cmp w0, #TK_SARRAY
    b.eq Lfe_stmt_print_sref
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
    // prstr sK (the constant counts toward TOO MANY LABELS)
    ldr x0, [sp, #(48 + TOK_PTR)]
    ldr w1, [sp, #(48 + TOK_LEN)]
    bl _fe_add_label
    mov w9, w0
    FE_NONE
    mov w4, w9
    mov w0, #OP_PRSTR
    bl _fe_emit
    mov w19, #FE_PR_STRING
    b Lfe_stmt_print_loop

Lfe_stmt_print_sref:
    // string variable or list element: its reference, then prsv
    mov x0, x20
    bl _fe_setpos
    bl _fe_sref_need
    mov w9, w0
    FE_NONE
    mov w1, w9
    mov w0, #OP_PRSV
    bl _fe_emit
    mov w19, #FE_PR_STRING
    b Lfe_stmt_print_loop

Lfe_stmt_print_tab:
    // TAB(e): e; prtab te
    mov w0, #4
    bl _fe_advance
    bl _fe_paren_open
    bl _fe_expr
    mov w21, w0
    bl _fe_paren_close
    FE_NONE
    mov w1, w21
    mov w0, #OP_PRTAB
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
// Lfe_stmt_end -- END: must be the last line; a multi-line DEF still open
//   there -> UNFINISHED DEF at that DEF's line (LANGUAGE.md 7.3); nothing
//   may follow.
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
    // END inside a body: that DEF was never closed
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
    bl _fe_expect_eol
    adrp x9, _fe_has_end@PAGE
    mov w10, #1
    str w10, [x9, _fe_has_end@PAGEOFF]
    FE_EMIT0 OP_END
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Lfe_stmt_stop -- STOP (nothing may follow).
// Lfe_stmt_return -- RETURN (nothing may follow; not in a multi-line body).
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
    bl Lfe_stmt_no_transfer
    bl _fe_expect_eol
    FE_EMIT0 OP_RETURN
    ldp x29, x30, [sp], #16
    ret

    .p2align 2
Lfe_stmt_rem:
    ret

// ---------------------------------------------------------------------
// Lfe_stmt_no_transfer -- GOSUB and RETURN are not allowed in a
//   multi-line DEF body: ILLEGAL TRANSFER (LANGUAGE.md 7.9, 7.10).
//   in: none   out: returns only outside a body
//   clobbers: x0-x17
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_no_transfer:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x9, _fe_ctx_kind@PAGE
    ldr w9, [x9, _fe_ctx_kind@PAGEOFF]
    cmp w9, #FE_CTX_ML
    b.ne 1f
    mov w0, #ERR_ILLEGAL_TRANSFER
    bl _fe_err
1:
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Lfe_stmt_read -- READ target {, target} (LANGUAGE.md 7.4).
//   Per target: numeric: subscripts, `read`, store; string: its `svar`
//   or subscript, then `sread` (plain or element form, _fe_sstore).
//   in: scanner after "READ"   out: none
//   clobbers: x0-x17, d0-d7
//   callee-saved: none used
//   frame: 32 bytes (frame record, 16-byte target descriptor at sp+16)
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_read:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
Lfe_stmt_read_loop:
    mov w0, #0
    add x1, sp, #16
    bl _fe_target
    ldr w9, [sp, #16]
    cmp w9, #FE_TGT_STRING
    b.ne 1f
    // string target: `sread tS` / `sread L$, ti` (needs string DATA,
    // phase 3)
    adrp x9, _fe_has_sread@PAGE
    mov w10, #1
    str w10, [x9, _fe_has_sread@PAGEOFF]
    add x0, sp, #16
    mov w1, #OP_SREAD
    bl _fe_sstore
    b 2f
1:
    // numeric target: tN = read; store it (needs numeric DATA, phase 3)
    adrp x9, _fe_has_read@PAGE
    mov w10, #1
    str w10, [x9, _fe_has_read@PAGEOFF]
    FE_NONE
    mov w0, #OP_READ
    bl _fe_emit_new
    mov w1, w0
    add x0, sp, #16
    bl _fe_store
2:
    // ',' continues the list, end of line finishes it
    bl _fe_next_op
    cmp w0, #TK_COMMA
    b.eq Lfe_stmt_read_loop
    cmp w0, #TK_EOL
    b.eq 3f
    mov w0, #ERR_INCORRECT_FORMAT
    bl _fe_err
3:
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lfe_stmt_data -- DATA datum {, datum} (LANGUAGE.md 7.5):
//   [+|-] constant -> the numeric block; '"' bytes '"' or an unquoted
//   string starting with a letter (up to the next ',' or the end of the
//   line, no '"') -> the string block. Bad constant -> ILLEGAL CONSTANT;
//   anything else malformed -> INCORRECT FORMAT; more than 100 000 values
//   of one kind -> TOO MUCH DATA.
//   in: scanner after "DATA"   out: none
//   clobbers: x0-x17, d0-d7
//   callee-saved: w19 = negative flag, x20 = string start, w21 = length
//   frame: 80 bytes (frame record, x19-x22, 40-byte token at sp+40)
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_data:
    stp x29, x30, [sp, #-80]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
Lfe_stmt_data_loop:
    mov w0, #0
    bl _fe_peek
    cmp w0, #'"'
    b.eq Lfe_stmt_data_quoted
    sub w9, w0, #'A'
    cmp w9, #25
    b.ls Lfe_stmt_data_unquoted
    // optional sign, part of the datum
    mov w19, #0
    cmp w0, #'+'
    b.eq 1f
    cmp w0, #'-'
    b.ne 2f
    mov w19, #1
1:
    mov w0, #1
    bl _fe_advance
2:
    // a numeric datum must start like a constant
    mov w0, #0
    bl _fe_peek
    cmp w0, #'.'
    b.eq 3f
    sub w9, w0, #'0'
    cmp w9, #9
    b.ls 3f
    mov w0, #ERR_INCORRECT_FORMAT       // empty datum, sign alone, ...
    bl _fe_err
3:
    mov w0, #SCAN_OPERAND
    add x1, sp, #40
    bl _fe_scan
    cmp w0, #TK_NUMBER
    b.eq 4f
    ldr w0, [sp, #(40 + TOK_ERR)]       // ILLEGAL CONSTANT
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
    ldr x1, [sp, #(40 + TOK_VALUE)]
    lsl x9, x19, #63
    eor x1, x1, x9
    adrp x9, _fe_module@PAGE
    ldr x0, [x9, _fe_module@PAGEOFF]
    bl _ir_add_data
    b Lfe_stmt_data_sep

Lfe_stmt_data_quoted:
    // '"' bytes '"': the bytes between the quotes, kept exactly
    bl _fe_getpos
    add x20, x0, #1
    adrp x9, _fe_end@PAGE
    ldr x9, [x9, _fe_end@PAGEOFF]
    mov x10, x20
6:
    cmp x10, x9
    b.hs Lfe_stmt_data_format           // unterminated
    ldrb w11, [x10]
    cmp w11, #'"'
    b.eq 7f
    add x10, x10, #1
    b 6b
7:
    sub x21, x10, x20
    add x0, x10, #1                     // after the closing quote
    bl _fe_setpos
    b Lfe_stmt_data_string
Lfe_stmt_data_unquoted:
    // letter { byte except ',' and '"' } (compacted text)
    bl _fe_getpos
    mov x20, x0
    adrp x9, _fe_end@PAGE
    ldr x9, [x9, _fe_end@PAGEOFF]
    mov x10, x20
8:
    cmp x10, x9
    b.hs 9f
    ldrb w11, [x10]
    cmp w11, #','
    b.eq 9f
    cmp w11, #'"'
    b.eq Lfe_stmt_data_format           // a quote inside an unquoted datum
    add x10, x10, #1
    b 8b
9:
    sub x21, x10, x20
    mov x0, x10
    bl _fe_setpos
Lfe_stmt_data_string:
    // count it, then add it to the string DATA block
    adrp x9, _fe_nsdata@PAGE
    ldr w10, [x9, _fe_nsdata@PAGEOFF]
    add w10, w10, #1
    str w10, [x9, _fe_nsdata@PAGEOFF]
    movz w11, #(LIM_SDATA_VALUES & 0xFFFF)
    movk w11, #(LIM_SDATA_VALUES >> 16), lsl #16
    cmp w10, w11
    b.ls 1f
    mov w0, #ERR_TOO_MUCH_DATA
    bl _fe_err
1:
    adrp x9, _fe_module@PAGE
    ldr x0, [x9, _fe_module@PAGEOFF]
    mov x1, x20
    mov w2, w21
    bl _ir_add_sdata
Lfe_stmt_data_sep:
    // ',' -> next datum; end of line -> done; text after a datum is wrong
    mov w0, #0
    bl _fe_peek
    cmp w0, #FE_PEEK_EOL
    b.eq Lfe_stmt_data_done
    cmp w0, #','
    b.ne Lfe_stmt_data_format
    mov w0, #1
    bl _fe_advance
    b Lfe_stmt_data_loop
Lfe_stmt_data_done:
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #80
    ret
Lfe_stmt_data_format:
    mov w0, #ERR_INCORRECT_FORMAT
    bl _fe_err

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
    tbnz w0, #31, 1f                    // bad target: nothing emitted
    mov w9, w0
    FE_NONE
    mov w4, w9
    mov w0, #OP_JMP
    bl _fe_emit
1:
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Lfe_stmt_if -- IF a REL b (THEN | GOTO) n (LANGUAGE.md 7.7). A string
//   comparison when the text after IF starts with a string reference:
//   r1; r2; `sjcmp REL, tr1, tr2, @n`; else a; b; `jcmp REL, ta, tb, @n`.
//   in: scanner after "IF"   out: none
//   clobbers: x0-x17, d0-d7
//   callee-saved: w19 = left temp, w20 = REL, w21 = right temp,
//        w22 = opcode (OP_JCMP / OP_SJCMP)
//   frame: 96 bytes (frame record, x19-x22, 40-byte token at sp+48)
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_if:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    // which kind of comparison? (peek at the first operand token)
    bl _fe_getpos
    mov x19, x0
    mov w0, #SCAN_OPERAND
    add x1, sp, #48
    bl _fe_scan
    mov w20, w0
    mov x0, x19
    bl _fe_setpos
    cmp w20, #TK_STRING
    b.eq Lfe_stmt_if_string
    cmp w20, #TK_SVAR
    b.eq Lfe_stmt_if_string
    cmp w20, #TK_SARRAY
    b.eq Lfe_stmt_if_string
    cmp w20, #TK_BAD
    b.ne Lfe_stmt_if_number
    ldr x9, [sp, #(48 + TOK_PTR)]
    ldrb w9, [x9]
    cmp w9, #'"'                        // an unterminated string constant
    b.eq Lfe_stmt_if_string
Lfe_stmt_if_number:
    mov w22, #OP_JCMP
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
    bl _fe_next_op
    b Lfe_stmt_if_then
Lfe_stmt_if_string:
    mov w22, #OP_SJCMP
    bl _fe_sref_need
    mov w19, w0
    bl _fe_next_op
    sub w20, w0, #TK_EQ
    cmp w20, #(TK_GE - TK_EQ)
    b.ls 2f
    // a string followed by an arithmetic operator is a string error
    sub w9, w0, #TK_PLUS
    cmp w9, #(TK_POW - TK_PLUS)
    b.ls Lfe_stmt_if_mismatch
    mov w0, #ERR_ILLEGAL_RELATION
    bl _fe_err
2:
    add w20, w20, #REL_EQ
    bl _fe_sref_need                    // a number here: MISMATCHED
    mov w21, w0
    bl _fe_next_op
    sub w9, w0, #TK_PLUS
    cmp w9, #(TK_POW - TK_PLUS)
    b.ls Lfe_stmt_if_mismatch
Lfe_stmt_if_then:
    // THEN or GOTO, then the line number
    cmp w0, #TK_THEN
    b.eq 3f
    cmp w0, #TK_GOTO
    b.eq 3f
    mov w0, #ERR_INCORRECT_FORMAT
    bl _fe_err
3:
    bl Lfe_stmt_lineref
    tbnz w0, #31, 4f
    mov w4, w0                          // X = target label
    mov w1, w19
    mov w2, w21
    mov w3, #IR_NONE
    mov x5, #0
    mov w6, w20
    mov w0, w22
    bl _fe_emit
4:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret
Lfe_stmt_if_mismatch:
    mov w0, #ERR_MISMATCHED_STRING
    bl _fe_err

// ---------------------------------------------------------------------
// Lfe_stmt_for -- FOR v = a TO b [STEP c] (LANGUAGE.md 7.8, IR.md 4.3).
//   Labels Z, B, X are allocated in the current function; a parameter
//   of the enclosing multi-line DEF as v is stored with `stparam`.
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
    bl Lfe_stmt_loopvar
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
    // v := ta
    mov w0, w19
    mov w1, w20
    bl Lfe_stmt_stvar
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
    // td = sub ta, tc ; v := td  (loop not performed: v = a - c)
    FE_NONE
    mov w1, w20
    mov w2, w22
    mov w0, #OP_SUB
    bl _fe_emit_new
    mov w1, w0
    mov w0, w19
    bl Lfe_stmt_stvar
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
    FE_ADR x11, _fe_forstack
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
// Lfe_stmt_next -- NEXT v, closing the innermost open FOR of the same
//   function (main or this multi-line body), which must use the same
//   variable, else NOT MATCH WITH FOR. IR.md 4.3.
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
    bl Lfe_stmt_loopvar
    mov w19, w0
    // the innermost open FOR of this function must use the same variable
    adrp x9, _fe_forsp@PAGE
    ldr w10, [x9, _fe_forsp@PAGEOFF]
    adrp x11, _fe_forbase@PAGE
    ldr w11, [x11, _fe_forbase@PAGEOFF]
    cmp w10, w11
    b.ls Lfe_stmt_next_nomatch
    sub w10, w10, #1
    FE_ADR x11, _fe_forstack
    add x11, x11, x10, lsl #4
    ldr w12, [x11]
    cmp w12, w19
    b.ne Lfe_stmt_next_nomatch
    ldr w20, [x11, #4]
    ldr w21, [x11, #8]
    ldr w22, [x11, #12]
    str w10, [x9, _fe_forsp@PAGEOFF]    // pop
    bl _fe_expect_eol
    // te = v
    mov w0, w19
    bl Lfe_stmt_ldvar
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
    // v := tg
    mov w0, w19
    mov w1, w25
    bl Lfe_stmt_stvar
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
//   Not in a multi-line body (ILLEGAL TRANSFER).
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
    bl Lfe_stmt_no_transfer
    bl Lfe_stmt_lineref
    mov w19, w0
    bl _fe_new_label
    mov w20, w0
    tbnz w19, #31, 1f                   // bad target: nothing emitted
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
// Lfe_stmt_dim -- DIM decl {, decl} (LANGUAGE.md 7.11):
//   decl := letter ( int [, int] ) | letter $ ( int )
//   Bounds go to the array / string-list tables; no code.
//   in: scanner after "DIM"   out: none
//   clobbers: x0-x17
//   callee-saved: w19 = letter, x20 = &array state, w21 = b1, w22 = b2,
//        w23 = dims, w24 = 1 for a string list
//   frame: 64 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_stmt_dim:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
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
    // ... optionally '$' (a string list) ...
    mov w24, #0
    FE_ADR x20, _fe_arrays
    cmp w0, #'$'
    b.ne 1f
    mov w24, #1
    FE_ADR x20, _fe_sarrays
    mov w0, #1
    bl _fe_advance
    mov w0, #1
    bl _fe_peek
1:
    // ... followed by '('
    cmp w0, #'('
    b.ne Lfe_stmt_dim_format
    mov w0, #2
    bl _fe_advance
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
    // second bound: a table (never a string list)
    cbz w24, 3f
    mov w0, #ERR_ILLEGAL_VARIABLE
    bl _fe_err
3:
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
    ldp x23, x24, [sp, #48]
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
// Keyword table (LANGUAGE.md 3.1 order): length byte, KW_* id byte, then
// the letters, FE_KW_ENTRY bytes per entry; RANDOM (the short spelling
// of RANDOMIZE) right after RANDOMIZE; a zero length ends the table.
// ---------------------------------------------------------------------
.macro FE_KW name, id
    .byte (9f - 8f), \id
8:
    .ascii "\name"
9:
    .space (FE_KW_ENTRY - 2 - (9b - 8b))
.endm
    .section __TEXT,__const
    .p2align 3
Lfe_stmt_keywords:
    FE_KW "LET", KW_LET
    FE_KW "PRINT", KW_PRINT
    FE_KW "END", KW_END
    FE_KW "READ", KW_READ
    FE_KW "DATA", KW_DATA
    FE_KW "GOTO", KW_GOTO
    FE_KW "IF", KW_IF
    FE_KW "FOR", KW_FOR
    FE_KW "NEXT", KW_NEXT
    FE_KW "GOSUB", KW_GOSUB
    FE_KW "RETURN", KW_RETURN
    FE_KW "DEF", KW_DEF
    FE_KW "DIM", KW_DIM
    FE_KW "REM", KW_REM
    FE_KW "STOP", KW_STOP
    FE_KW "MAT", KW_MAT
    FE_KW "INPUT", KW_INPUT
    FE_KW "RESTORE", KW_RESTORE
    FE_KW "ON", KW_ON
    FE_KW "RANDOMIZE", KW_RANDOMIZE
    FE_KW "RANDOM", KW_RANDOMIZE
    FE_KW "CHANGE", KW_CHANGE
    FE_KW "FNEND", KW_FNEND
    .byte 0, 0
    .space (FE_KW_ENTRY - 2)

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
    .quad _fe_def                       // fe_def.s
    .quad Lfe_stmt_dim
    .quad Lfe_stmt_rem
    .quad Lfe_stmt_stop
    .quad _fe_mat                       // fe_mat.s
    .quad _fe_input                     // fe_input.s
    .quad _fe_restore                   // fe_input.s
    .quad _fe_on                        // fe_input.s
    .quad _fe_randomize                 // fe_input.s
    .quad _fe_change                    // fe_str.s
    .quad _fe_fnend                     // fe_def.s
