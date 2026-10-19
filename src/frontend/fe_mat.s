// =====================================================================
// src/frontend/fe_mat.s -- MAT statement parser and lowering
// (LANGUAGE.md section 7.14.2, IR.md sections 3.1 and 4.3).
//
//   _fe_mat()          parse the text after "MAT" and lower it into the
//                      current function
//   _fe_mat_finish()   after all lines: every letter named by a MAT
//                      statement whose dimensionality is still unknown
//                      becomes a 10 x 10 table (LANGUAGE.md 7.11)
//
// Grammar (compacted text, LANGUAGE.md 7.14.2):
//   mat-statement := "MAT" ( mat-read | mat-print | mat-input | mat-assign )
//   mat-read      := "READ" mat-target { "," mat-target }
//   mat-target    := name [ "(" expression [ "," expression ] ")" ]
//                  | sname [ "(" expression ")" ]
//   mat-print     := "PRINT" pname { sep pname } [ sep ]   sep := "," | ";"
//   pname         := name | sname
//   mat-input     := "INPUT" ( name | sname )
//   mat-assign    := name "=" rhs
//   rhs           := name | name ( "+" | "-" | "*" ) name
//                  | "(" expression ")" "*" name
//                  | ( "ZER" | "CON" ) [ "(" expression [ "," expression ] ")" ]
//                  | "IDN" [ "(" expression ")" ]
//                  | ( "TRN" | "INV" ) "(" name ")"
//   name          := letter                    not followed by a digit or "$"
//   sname         := letter "$"                a string list (LANGUAGE.md 4.4)
//
// String lists are only allowed in MAT READ, MAT PRINT and MAT INPUT; in
// an assignment they are MISMATCHED STRING OPERATION.
//
// Every name used by a MAT statement is recorded in the bit mask
// _fe_mat_names (fe_compile.s); a subscripted MAT READ target also fixes
// the letter's dimensionality through _fe_array_use (fe_expr.s). Errors
// leave through _fe_err (fe_compile.s).
// =====================================================================
.include "baysick.inc"

.equ FE_PEEK_EOL,       0x100       // _fe_peek result beyond the line end
.equ FE_ARR_SHIFT,      4           // log2 of the _fe_arrays entry size (16)

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _fe_mat -- MAT statement: choose READ, PRINT, INPUT or an assignment
//   (text starting with READ is MAT READ, else text starting with PRINT
//   is MAT PRINT, else text starting with INPUT is MAT INPUT, else it is
//   an assignment) and run its parser.
//   in:  scanner after "MAT"
//   out: none (code emitted into main)
//   clobbers: x0-x17, d0-d7
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .globl _fe_mat
    .p2align 2
_fe_mat:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    // "READ" ?
    adrp x0, Lfe_mat_s_read@PAGE
    add x0, x0, Lfe_mat_s_read@PAGEOFF
    mov w1, #4
    bl Lfe_mat_prefix
    cbz w0, 1f
    mov w0, #4
    bl _fe_advance
    bl Lfe_mat_read
    b Lfe_mat_ret
1:
    // "PRINT" ?
    adrp x0, Lfe_mat_s_print@PAGE
    add x0, x0, Lfe_mat_s_print@PAGEOFF
    mov w1, #5
    bl Lfe_mat_prefix
    cbz w0, 2f
    mov w0, #5
    bl _fe_advance
    bl Lfe_mat_print
    b Lfe_mat_ret
2:
    // "INPUT" ?
    adrp x0, Lfe_mat_s_input@PAGE
    add x0, x0, Lfe_mat_s_input@PAGEOFF
    mov w1, #5
    bl Lfe_mat_prefix
    cbz w0, 3f
    mov w0, #5
    bl _fe_advance
    bl Lfe_mat_input
    b Lfe_mat_ret
3:
    // anything else is an assignment (MAT R = ..., MAT P = ...)
    bl Lfe_mat_assign
Lfe_mat_ret:
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Lfe_mat_read -- MAT READ target {, target}  (IR.md 4.3): per target,
//   [r; [c;] matredim X, tr [, tc];] matread X, or for a string list
//   [r; smatredim X$, tr;] smatread X$. A subscripted numeric target is a
//   use of X as a list (one dimension) or a table (two); a string list
//   takes one dimension only (a second -> ILLEGAL VARIABLE).
//   in:  scanner after "READ"
//   out: none
//   clobbers: x0-x17, d0-d7
//   callee-saved: w19 = target letter, w20 = r temp, w21 = c temp
//        (or IR_NONE), w22 = 1 for a string list
//   frame: 48 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_mat_read:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
Lfe_mat_read_loop:
    mov w0, #1                          // string lists allowed
    bl Lfe_mat_name                     // ILLEGAL VARIABLE if no name
    mov w19, w0
    mov w22, w1
    // a MAT READ needs DATA values of its kind (phase-3 NO [STRING] DATA)
    adrp x9, _fe_has_read@PAGE
    add x9, x9, _fe_has_read@PAGEOFF
    adrp x10, _fe_has_sread@PAGE
    add x10, x10, _fe_has_sread@PAGEOFF
    cmp w22, #0
    csel x9, x9, x10, eq
    mov w10, #1
    str w10, [x9]
    mov w0, #0
    bl _fe_peek
    cmp w0, #'('
    b.ne Lfe_mat_read_elems
    mov w0, #1
    bl _fe_advance
    cbnz w22, Lfe_mat_read_sdim
    // dimension list: evaluated, then the target is redimensioned
    mov w0, #2                          // one or two dimensions
    bl Lfe_mat_dims
    mov w20, w0
    mov w21, w1
    // the number of dimensions fixes / must agree with list or table
    mov w1, w2
    mov w0, w19
    bl _fe_array_use
    // matredim X, tr [, tc]
    mov w0, #OP_MATREDIM
    mov w1, w20
    mov w2, w21
    mov w4, w19
    mov x5, #0
    bl Lfe_mat_emit
    b Lfe_mat_read_elems
Lfe_mat_read_sdim:
    // X$(r): r; smatredim X$, tr (a second dimension is ILLEGAL VARIABLE)
    mov w0, w19
    bl _fe_ssubscript
    mov w1, w0
    mov w0, #OP_SMATREDIM
    mov w2, #IR_NONE
    mov w4, w19
    mov x5, #0
    bl Lfe_mat_emit
Lfe_mat_read_elems:
    // matread X / smatread X$
    mov w0, #OP_MATREAD
    cbz w22, 1f
    mov w0, #OP_SMATREAD
1:
    mov w1, #IR_NONE
    mov w2, #IR_NONE
    mov w4, w19
    mov x5, #0
    bl Lfe_mat_emit
    // ',' -> next target, end of line -> done, anything else is wrong
    mov w0, #0
    bl _fe_peek
    cmp w0, #FE_PEEK_EOL
    b.eq Lfe_mat_read_done
    cmp w0, #','
    b.ne Lfe_mat_read_format
    mov w0, #1
    bl _fe_advance
    b Lfe_mat_read_loop
Lfe_mat_read_done:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
Lfe_mat_read_format:
    mov w0, #ERR_INCORRECT_FORMAT
    bl _fe_err

// ---------------------------------------------------------------------
// Lfe_mat_input -- MAT INPUT V / MAT INPUT V$ (LANGUAGE.md 7.14.8,
//   IR.md 4.3): `matinput V` / `smatinput V$`. A numeric name is a use as
//   a list (a table -> ILLEGAL VARIABLE); dimensions -> INCORRECT FORMAT.
//   in:  scanner after "INPUT"
//   out: none
//   clobbers: x0-x17
//   callee-saved: w19 = letter, w20 = 1 for a string list
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_mat_input:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov w0, #1                          // string lists allowed
    bl Lfe_mat_name
    mov w19, w0
    mov w20, w1
    cbnz w20, 1f
    mov w0, w19
    mov w1, #1                          // MAT INPUT fixes a list
    bl _fe_array_use
1:
    bl _fe_expect_eol                   // MAT INPUT V(5): INCORRECT FORMAT
    mov w0, #OP_MATINPUT
    cbz w20, 2f
    mov w0, #OP_SMATINPUT
2:
    mov w1, #IR_NONE
    mov w2, #IR_NONE
    mov w4, w19
    mov x5, #0
    bl Lfe_mat_emit
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lfe_mat_print -- MAT PRINT name { sep name } [ sep ]  (IR.md 4.3): per
//   item, `prnl` unless it is the first, then `matprint X, packed` if the
//   separator after it is ';', else `matprint X, zoned` (a string list:
//   `smatprint X$, packed|zoned`).
//   in:  scanner after "PRINT"
//   out: none
//   clobbers: x0-x17
//   callee-saved: w19 = item letter, w20 = 1 while at the first item,
//        w21 = MATPR_* mode, w22 = 1 if the item ended the line,
//        w23 = 1 for a string list
//   frame: 64 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_mat_print:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]
    mov w20, #1
Lfe_mat_print_loop:
    mov w0, #1                          // string lists allowed
    bl Lfe_mat_name                     // ILLEGAL VARIABLE if no name
    mov w19, w0
    mov w23, w1
    // what follows the name selects the format of this item
    mov w0, #0
    bl _fe_peek
    mov w21, #MATPR_ZONED
    mov w22, #1
    cmp w0, #FE_PEEK_EOL
    b.eq Lfe_mat_print_emit             // last item, no separator: zoned
    mov w22, #0
    cmp w0, #','
    b.eq Lfe_mat_print_sep
    mov w21, #MATPR_PACKED
    cmp w0, #';'
    b.eq Lfe_mat_print_sep
    mov w0, #ERR_INCORRECT_FORMAT       // e.g. MAT PRINT A(1)
    bl _fe_err
Lfe_mat_print_sep:
    mov w0, #1
    bl _fe_advance
Lfe_mat_print_emit:
    // matrices of one statement are separated by a newline
    cbnz w20, 1f
    mov w0, #OP_PRNL
    mov w1, #IR_NONE
    mov w2, #IR_NONE
    mov w4, #IR_NONE
    mov x5, #0
    bl Lfe_mat_emit
1:
    mov w20, #0
    // matprint X, zoned|packed (smatprint for a string list)
    mov w0, #OP_MATPRINT
    cbz w23, 2f
    mov w0, #OP_SMATPRINT
2:
    mov w1, #IR_NONE
    mov w2, #IR_NONE
    mov w4, w19
    mov w5, w21                         // IMM = MATPR_* (zero-extended)
    bl Lfe_mat_emit
    cbnz w22, Lfe_mat_print_done
    // a trailing separator ends the statement; otherwise a name follows
    mov w0, #0
    bl _fe_peek
    cmp w0, #FE_PEEK_EOL
    b.ne Lfe_mat_print_loop
Lfe_mat_print_done:
    ldr x23, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

// ---------------------------------------------------------------------
// Lfe_mat_assign -- MAT name = rhs (LANGUAGE.md 7.14.2, IR.md 4.3).
//   The rhs forms are recognised in the order ZER, CON, IDN, then TRN( and
//   INV(, then '(' (scalar multiple), then a name; anything else is
//   INCORRECT FORMAT.
//   in:  scanner after "MAT"
//   out: none
//   clobbers: x0-x17, d0-d7
//   callee-saved: w19 = target letter, w20 = first operand letter /
//        scalar temp / r temp, w21 = second operand letter / c temp,
//        w22 = opcode
//   frame: 48 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_mat_assign:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov w0, #0                          // no string lists in assignments
    bl Lfe_mat_name                     // MAT = A -> ILLEGAL VARIABLE
    mov w19, w0
    mov w0, #0
    bl _fe_peek
    cmp w0, #'='
    b.ne Lfe_mat_assign_format          // MAT C A + B, MATRIX = 1
    mov w0, #1
    bl _fe_advance
    // ---- ZER / CON / IDN (recognised first) -------------------------
    mov w22, #OP_MATZER
    adrp x0, Lfe_mat_s_zer@PAGE
    add x0, x0, Lfe_mat_s_zer@PAGEOFF
    mov w1, #3
    bl Lfe_mat_prefix
    cbnz w0, Lfe_mat_assign_fill
    mov w22, #OP_MATCON
    adrp x0, Lfe_mat_s_con@PAGE
    add x0, x0, Lfe_mat_s_con@PAGEOFF
    mov w1, #3
    bl Lfe_mat_prefix
    cbnz w0, Lfe_mat_assign_fill
    adrp x0, Lfe_mat_s_idn@PAGE
    add x0, x0, Lfe_mat_s_idn@PAGEOFF
    mov w1, #3
    bl Lfe_mat_prefix
    cbnz w0, Lfe_mat_assign_idn
    // ---- TRN( / INV( ------------------------------------------------
    mov w22, #OP_MATTRN
    adrp x0, Lfe_mat_s_trn@PAGE
    add x0, x0, Lfe_mat_s_trn@PAGEOFF
    mov w1, #4
    bl Lfe_mat_prefix
    cbnz w0, Lfe_mat_assign_func
    mov w22, #OP_MATINV
    adrp x0, Lfe_mat_s_inv@PAGE
    add x0, x0, Lfe_mat_s_inv@PAGEOFF
    mov w1, #4
    bl Lfe_mat_prefix
    cbnz w0, Lfe_mat_assign_func
    // ---- '(' scalar multiple, or a name ---------------------------------
    mov w0, #0
    bl _fe_peek
    cmp w0, #'('
    b.eq Lfe_mat_assign_scale
    sub w9, w0, #'A'
    cmp w9, #25
    b.ls Lfe_mat_assign_operand
    b Lfe_mat_assign_format             // MAT C = 2*A, MAT C = (empty)

Lfe_mat_assign_fill:
    // ZER / CON [ (r [, c]) ]: r; [c;] matredim X, tr [, tc]; matzer|matcon X
    mov w0, #3
    bl _fe_advance
    mov w0, #0
    bl _fe_peek
    cmp w0, #'('
    b.ne 1f
    mov w0, #1
    bl _fe_advance
    mov w0, #2                          // one or two dimensions
    bl Lfe_mat_dims
    mov w20, w0
    mov w21, w1
    bl _fe_expect_eol
    mov w0, #OP_MATREDIM
    mov w1, w20
    mov w2, w21
    mov w4, w19
    mov x5, #0
    bl Lfe_mat_emit
    b 2f
1:
    bl _fe_expect_eol
2:
    mov w0, w22
    mov w1, #IR_NONE
    mov w2, #IR_NONE
    mov w4, w19
    mov x5, #0
    bl Lfe_mat_emit
    b Lfe_mat_assign_ret

Lfe_mat_assign_idn:
    // IDN [ (n) ]: n; matredim X, tn, tn; matidn X
    mov w0, #3
    bl _fe_advance
    mov w0, #0
    bl _fe_peek
    cmp w0, #'('
    b.ne 1f
    mov w0, #1
    bl _fe_advance
    mov w0, #1                          // exactly one argument
    bl Lfe_mat_dims
    mov w20, w0
    bl _fe_expect_eol
    mov w0, #OP_MATREDIM
    mov w1, w20                         // n x n
    mov w2, w20
    mov w4, w19
    mov x5, #0
    bl Lfe_mat_emit
    b 2f
1:
    bl _fe_expect_eol
2:
    mov w0, #OP_MATIDN
    mov w1, #IR_NONE
    mov w2, #IR_NONE
    mov w4, w19
    mov x5, #0
    bl Lfe_mat_emit
    b Lfe_mat_assign_ret

Lfe_mat_assign_func:
    // TRN(Y) / INV(Y): mattrn|matinv X, Y
    mov w0, #4                          // the name and its '('
    bl _fe_advance
    mov w0, #0
    bl Lfe_mat_name
    mov w20, w0
    mov w0, #0
    bl _fe_peek
    cmp w0, #')'
    b.ne Lfe_mat_assign_format
    mov w0, #1
    bl _fe_advance
    bl _fe_expect_eol
    mov w0, w22
    mov w1, w20
    mov w2, #IR_NONE
    mov w4, w19
    mov x5, #0
    bl Lfe_mat_emit
    b Lfe_mat_assign_ret

Lfe_mat_assign_scale:
    // (e) * Y: e; matscale X, te, Y. The parentheses work exactly like a
    // parenthesised expression (depth limit, ')' required).
    mov w0, #1
    bl _fe_advance
    bl _fe_paren_open
    bl _fe_expr
    mov w20, w0
    bl _fe_paren_close
    mov w0, #0
    bl _fe_peek
    cmp w0, #'*'
    b.ne Lfe_mat_assign_format          // MAT C = (2)A
    mov w0, #1
    bl _fe_advance
    mov w0, #0
    bl Lfe_mat_name
    mov w21, w0
    bl _fe_expect_eol
    mov w0, #OP_MATSCALE
    mov w1, w20                         // A = scalar temp
    mov w2, w21                         // B = array letter
    mov w4, w19
    mov x5, #0
    bl Lfe_mat_emit
    b Lfe_mat_assign_ret

Lfe_mat_assign_operand:
    // Y alone (copy), or Y op Z with op one of + - *
    mov w0, #0
    bl Lfe_mat_name                     // MAT C = A1 + B -> ILLEGAL VARIABLE
    mov w20, w0
    mov w0, #0
    bl _fe_peek
    cmp w0, #FE_PEEK_EOL
    b.ne 1f
    // matcopy X, Y
    mov w0, #OP_MATCOPY
    mov w1, w20
    mov w2, #IR_NONE
    mov w4, w19
    mov x5, #0
    bl Lfe_mat_emit
    b Lfe_mat_assign_ret
1:
    mov w22, #OP_MATADD
    cmp w0, #'+'
    b.eq 2f
    mov w22, #OP_MATSUB
    cmp w0, #'-'
    b.eq 2f
    mov w22, #OP_MATMUL
    cmp w0, #'*'
    b.ne Lfe_mat_assign_format          // MAT C = SIN(A), MAT C = A(1)
2:
    mov w0, #1
    bl _fe_advance
    mov w0, #0
    bl Lfe_mat_name
    mov w21, w0
    bl _fe_expect_eol                   // one operation only: A + B - C
    mov w0, w22
    mov w1, w20
    mov w2, w21
    mov w4, w19
    mov x5, #0
    bl Lfe_mat_emit
Lfe_mat_assign_ret:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
Lfe_mat_assign_format:
    mov w0, #ERR_INCORRECT_FORMAT
    bl _fe_err

// ---------------------------------------------------------------------
// Lfe_mat_name -- a MAT name: a letter not followed by a digit, or (a
//   string list) a letter followed by '$'. Not a letter, or letter+digit
//   (also A1$) -> ILLEGAL VARIABLE; a string list where none is allowed
//   (assignments) -> MISMATCHED STRING OPERATION. A numeric letter is
//   recorded in _fe_mat_names (it fixes no dimensionality); a string list
//   is marked used.
//   in:  w0 = 1 if a string list is allowed, else 0
//   out: w0 = letter 0..25 (letter and '$' consumed), w1 = 1 for a string
//        list, else 0
//   clobbers: x0-x17
//   callee-saved: w19 = letter, w20 = string allowed
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_mat_name:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov w20, w0
    mov w0, #0
    bl _fe_peek
    sub w19, w0, #'A'
    cmp w19, #25
    b.hi Lfe_mat_name_bad               // not a letter (or end of line)
    mov w0, #1
    bl _fe_peek
    sub w9, w0, #'0'
    cmp w9, #9
    b.ls Lfe_mat_name_bad               // letter + digit
    cmp w0, #'$'
    b.eq Lfe_mat_name_string
    mov w0, #1
    bl _fe_advance
    // _fe_mat_names |= 1 << letter
    adrp x9, _fe_mat_names@PAGE
    ldr w10, [x9, _fe_mat_names@PAGEOFF]
    mov w11, #1
    lsl w11, w11, w19
    orr w10, w10, w11
    str w10, [x9, _fe_mat_names@PAGEOFF]
    mov w0, w19
    mov w1, #0
    b Lfe_mat_name_ret
Lfe_mat_name_string:
    // X$: only MAT READ, MAT PRINT and MAT INPUT handle string lists
    cbnz w20, 1f
    mov w0, #ERR_MISMATCHED_STRING
    bl _fe_err
1:
    mov w0, #2
    bl _fe_advance
    mov w0, w19
    bl _fe_sarray_use
    mov w0, w19
    mov w1, #1
Lfe_mat_name_ret:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
Lfe_mat_name_bad:
    mov w0, #ERR_ILLEGAL_VARIABLE
    bl _fe_err

// ---------------------------------------------------------------------
// Lfe_mat_dims -- a dimension / IDN argument list "e [, e] )" whose '('
//   was already consumed; it is one '(' level for the depth limit and
//   behaves like a subscript list (missing ')', or more arguments than
//   allowed -> ILLEGAL FORMULA). Lowering: the expressions in order.
//   in:  w0 = maximum number of expressions (1 or 2)
//   out: w0 = first temp, w1 = second temp or IR_NONE, w2 = count (1/2)
//   clobbers: x0-x17, d0-d7
//   callee-saved: w19 = maximum, w20 = first temp, w21 = second temp,
//        w22 = count
//   frame: 48 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_mat_dims:
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
    b.eq Lfe_mat_dims_closed
    cmp w0, #TK_COMMA
    b.ne Lfe_mat_dims_formula           // anything else before ')'
    cmp w19, #2
    b.lo Lfe_mat_dims_formula           // IDN(2,3): one argument only
    bl _fe_expr
    mov w21, w0
    mov w22, #2
    mov w0, #TK_RPAREN                  // a third dimension or no ')'
    mov w1, #ERR_ILLEGAL_FORMULA
    bl _fe_expect_op
Lfe_mat_dims_closed:
    // ')' consumed: leave the nesting level
    adrp x9, _fe_depth@PAGE
    ldr w10, [x9, _fe_depth@PAGEOFF]
    sub w10, w10, #1
    str w10, [x9, _fe_depth@PAGEOFF]
    mov w0, w20
    mov w1, w21
    mov w2, w22
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
Lfe_mat_dims_formula:
    mov w0, #ERR_ILLEGAL_FORMULA
    bl _fe_err

// ---------------------------------------------------------------------
// Lfe_mat_prefix -- does the text at the scanner position start with the
//   given bytes? (Nothing is consumed.)
//   in:  x0 = bytes, w1 = their count
//   out: w0 = 1 if they match, else 0
//   clobbers: x9-x15   leaf, no frame
// ---------------------------------------------------------------------
    .p2align 2
Lfe_mat_prefix:
    adrp x9, _fe_pos@PAGE
    ldr x10, [x9, _fe_pos@PAGEOFF]
    adrp x9, _fe_end@PAGE
    ldr x11, [x9, _fe_end@PAGEOFF]
    sub x12, x11, x10                   // bytes left in the line
    mov w1, w1                          // zero-extend the count
    cmp x12, x1
    b.lo Lfe_mat_prefix_no
    mov x13, #0
Lfe_mat_prefix_loop:
    cmp x13, x1
    b.hs Lfe_mat_prefix_yes
    ldrb w14, [x0, x13]
    ldrb w15, [x10, x13]
    cmp w14, w15
    b.ne Lfe_mat_prefix_no
    add x13, x13, #1
    b Lfe_mat_prefix_loop
Lfe_mat_prefix_yes:
    mov w0, #1
    ret
Lfe_mat_prefix_no:
    mov w0, #0
    ret

// ---------------------------------------------------------------------
// Lfe_mat_emit -- append a MAT instruction (no destination temp) to the
//   current function; C and REL are unused.
//   in:  w0 = opcode, w1 = A, w2 = B, w4 = X, x5 = IMM
//   out: none
//   clobbers: x0-x17 (tail call into _fe_emit)
//   callee-saved: none used
//   frame: none (tail call)
// ---------------------------------------------------------------------
    .p2align 2
Lfe_mat_emit:
    mov w3, #IR_NONE
    mov w6, #REL_NONE
    b _fe_emit

// ---------------------------------------------------------------------
// _fe_mat_finish -- give every letter that a MAT statement named but
//   whose dimensionality is still unknown after all lines the default
//   table shape LIM_DEFAULT_BOUND x LIM_DEFAULT_BOUND (LANGUAGE.md 7.11,
//   IR.md 3.1). Called once, after the phase-3 checks.
//   in:  none
//   out: none (_fe_arrays updated)
//   clobbers: x9-x15   leaf, no frame
// ---------------------------------------------------------------------
    .globl _fe_mat_finish
    .p2align 2
_fe_mat_finish:
    adrp x9, _fe_mat_names@PAGE
    ldr w10, [x9, _fe_mat_names@PAGEOFF]
    adrp x11, _fe_arrays@PAGE
    add x11, x11, _fe_arrays@PAGEOFF
    mov w12, #0                         // letter
Lfe_mat_finish_loop:
    cmp w12, #NUM_LETTERS
    b.hs Lfe_mat_finish_done
    lsr w13, w10, w12
    tbz w13, #0, Lfe_mat_finish_next    // not named by a MAT statement
    add x14, x11, x12, lsl #FE_ARR_SHIFT
    ldr w15, [x14]                      // dims (0 = still unknown)
    cbnz w15, Lfe_mat_finish_next
    // a table with the default bounds, not set by a DIM
    mov w15, #2
    str w15, [x14]
    mov w15, #LIM_DEFAULT_BOUND
    str w15, [x14, #4]
    str w15, [x14, #8]
    str wzr, [x14, #12]
Lfe_mat_finish_next:
    add w12, w12, #1
    b Lfe_mat_finish_loop
Lfe_mat_finish_done:
    ret

// ---------------------------------------------------------------------
// Words recognised after "MAT" and on the right-hand side.
// ---------------------------------------------------------------------
    .section __TEXT,__const
Lfe_mat_s_read:
    .ascii "READ"
Lfe_mat_s_print:
    .ascii "PRINT"
Lfe_mat_s_input:
    .ascii "INPUT"
Lfe_mat_s_zer:
    .ascii "ZER"
Lfe_mat_s_con:
    .ascii "CON"
Lfe_mat_s_idn:
    .ascii "IDN"
Lfe_mat_s_trn:
    .ascii "TRN("
Lfe_mat_s_inv:
    .ascii "INV("
