// =====================================================================
// src/runtime/rt_mat.s -- the MAT layer (DESIGN.md 6.5, LANGUAGE.md 7.14).
//
// Defines (global, runtime.inc):
//   _bsk_mat_redim1 _bsk_mat_redim2 _bsk_mat_read _bsk_mat_print
//   _bsk_mat_zer _bsk_mat_con _bsk_mat_idn
//   _bsk_mat_copy _bsk_mat_trn _bsk_mat_inv
//   _bsk_mat_add _bsk_mat_sub _bsk_mat_mul _bsk_mat_scale
//   _bsk_smat_print (MAT PRINT of a string list or table, DESIGN.md 6.5,
//   6.8)
//
// Owns every BASIC rule of the MAT statements -- shapes, conformability,
// redimensioning, aliasing, DIMENSION ERROR / OVERFLOW / SINGULAR MATRIX,
// the DATA cursor (via _bsk_read) and the PRINT column (via the
// _bsk_print_* entry points) -- and delegates arithmetic to the kernel
// trampolines _bsk_kern_* (rt_kinit.s).
//
// Shapes: a table's current shape is (RTA_B1, RTA_B2), a list's is
// (RTA_B1, 1). Its view (MV_*): table MV_DATA = RTA_DATA + 8*(ROWLEN+1)
// (element (1,1)), MV_LD = ROWLEN; list MV_DATA = RTA_DATA + 8, MV_LD = 1.
//
// Order of every assignment (LANGUAGE.md 7.14.4): operand shapes and
// conformability -> the target-fits test -> compute -> kernel status ->
// set the target's shape -> store. When the target is not an operand its
// shape is set first and the kernel writes straight into it (an error
// stops the program, so a partial result is never observed). When the
// target is an operand ("as if into a temporary", pointer equality of
// descriptors): +, -, (K)* keep the shape and run in place; MAT A = A is
// a no-op; *, TRN, INV compute into the static temporary
// _bsk_rt_mat_tmp (view MV_LD = cols) and are then copied.
// =====================================================================
.include "baysick.inc"

.equ RT_MAT_TWO31, 0x41E0000000000000  // 2^31 as IEEE double bits

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// Lrt_mat_dimerr -- DIMENSION ERROR (no return). Reached by branches.
// ---------------------------------------------------------------------
    .p2align 2
Lrt_mat_dimerr:
    mov w0, #ERR_DIMENSION_ERROR
    b _bsk_err

// ---------------------------------------------------------------------
// Lrt_mat_dimarg -- convert a dimension argument (LANGUAGE.md 7.14.3).
//   Purpose : x < 0.5 (or NaN) -> DIMENSION ERROR; x >= 2^31 -> DIMENSION
//             ERROR; else d = floor(x + 0.5) evaluated exactly: floor(x),
//             plus 1 when x - floor(x) >= 0.5 (the difference is exact
//             for 0.5 <= x < 2^31).
//   Inputs  : d0 = x
//   Outputs : x0 = d (1 <= d <= 2^31)
//   Clobbers: x9, d0, d16, d17 (every other register is preserved)
//   Callee-saved used: none
//   Frame   : none (leaf; the error exit is a branch)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_mat_dimarg:
    fmov d16, #0.5
    fcmp d0, d16
    b.lt Lrt_mat_dimerr             // x < 0.5, or unordered (NaN)
    mov x9, #RT_MAT_TWO31
    fmov d17, x9
    fcmp d0, d17
    b.ge Lrt_mat_dimerr             // x >= 2^31: no storage that large
    frintm d17, d0                  // floor(x)
    fsub d0, d0, d17                // fractional part, exact
    fcmp d0, d16
    b.lt 1f
    fmov d16, #1.0
    fadd d17, d17, d16              // round half up
1:
    fcvtzu x0, d17
    ret

// ---------------------------------------------------------------------
// Lrt_mat_shape -- current shape of an operand; a zero dimension (only
//   possible through DIM X(0...) ) is a DIMENSION ERROR.
//   Inputs  : x0 = descriptor
//   Outputs : x1 = rows, x2 = columns (both >= 1); x0 preserved
//   Clobbers: x9
//   Callee-saved used: none
//   Frame   : none (leaf; the error exit is a branch)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_mat_shape:
    ldr w1, [x0, #RTA_B1]
    ldr w9, [x0, #RTA_DIMS]
    mov x2, #1                      // list: one column
    cmp w9, #1
    b.eq 1f
    ldr w2, [x0, #RTA_B2]           // table: B2 columns
1:
    cbz x1, Lrt_mat_dimerr
    cbz x2, Lrt_mat_dimerr
    ret

// ---------------------------------------------------------------------
// Lrt_mat_fits -- the storage test of LANGUAGE.md 7.14.3 for a shape
//   r x c against the descriptor's RTA_CAP (64-bit products; r, c < 2^31
//   for every caller, so nothing overflows): list: c = 1 and r + 1 <= CAP;
//   table: (r + 1) * (c + 1) <= CAP. Otherwise DIMENSION ERROR.
//   Inputs  : x0 = descriptor, x1 = r, x2 = c (>= 1)
//   Outputs : none; x0-x2 preserved
//   Clobbers: x9-x11
//   Callee-saved used: none
//   Frame   : none (leaf; the error exit is a branch)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_mat_fits:
    ldr w11, [x0, #RTA_CAP]
    ldr w9, [x0, #RTA_DIMS]
    add x10, x1, #1                 // r + 1
    cmp w9, #1
    b.ne 1f
    cmp x2, #1                      // a list holds one column only
    b.ne Lrt_mat_dimerr
    b 2f
1:
    add x9, x2, #1
    mul x10, x10, x9                // (r + 1) * (c + 1)
2:
    cmp x10, x11
    b.hi Lrt_mat_dimerr
    ret

// ---------------------------------------------------------------------
// Lrt_mat_setshape -- make r x c the descriptor's current shape (the
//   caller has already applied Lrt_mat_fits). List: B1 = r. Table:
//   B1 = r, B2 = c, ROWLEN = c + 1. No element is moved.
//   Inputs  : x0 = descriptor, x1 = r, x2 = c
//   Outputs : none; x0-x2 preserved
//   Clobbers: x9
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_mat_setshape:
    str w1, [x0, #RTA_B1]
    ldr w9, [x0, #RTA_DIMS]
    cmp w9, #1
    b.eq 1f
    str w2, [x0, #RTA_B2]
    add w9, w2, #1
    str w9, [x0, #RTA_ROWLEN]
1:
    ret

// ---------------------------------------------------------------------
// Lrt_mat_view -- build the MV_* view of a descriptor's current shape.
//   Inputs  : x0 = descriptor, x1 = view to fill (MV_SIZE bytes)
//   Outputs : none; x0, x1 preserved
//   Clobbers: x9-x12
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_mat_view:
    ldr x9, [x0, #RTA_DATA]
    ldr w10, [x0, #RTA_B1]
    str x10, [x1, #MV_ROWS]
    ldr w11, [x0, #RTA_DIMS]
    cmp w11, #1
    b.ne 1f
    add x9, x9, #8                  // list: element 1
    mov x12, #1
    str x12, [x1, #MV_COLS]
    str x12, [x1, #MV_LD]
    str x9, [x1, #MV_DATA]
    ret
1:
    ldr w11, [x0, #RTA_B2]
    str x11, [x1, #MV_COLS]
    ldr w12, [x0, #RTA_ROWLEN]
    str x12, [x1, #MV_LD]
    add x10, x12, #1
    add x9, x9, x10, lsl #3         // table: element (1,1)
    str x9, [x1, #MV_DATA]
    ret

// ---------------------------------------------------------------------
// Lrt_mat_tmpview -- view of the static result temporary: r x c with
//   MV_LD = c.
//   Inputs  : x1 = r, x2 = c, x3 = view to fill
//   Outputs : none; x1-x3 preserved
//   Clobbers: x9
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_mat_tmpview:
    adrp x9, _bsk_rt_mat_tmp@PAGE
    add x9, x9, _bsk_rt_mat_tmp@PAGEOFF
    str x9, [x3, #MV_DATA]
    str x1, [x3, #MV_ROWS]
    str x2, [x3, #MV_COLS]
    str x2, [x3, #MV_LD]
    ret

// ---------------------------------------------------------------------
// Lrt_mat_status -- turn a kernel status into the BASIC error.
//   Inputs  : x0 = KS_*
//   Outputs : returns only for KS_OK
//   Errors  : KS_NONFINITE -> OVERFLOW; KS_SINGULAR -> SINGULAR MATRIX
//   Clobbers: w0
//   Callee-saved used: none
//   Frame   : none (leaf; the error exits are branches)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_mat_status:
    cbnz x0, 1f
    ret
1:
    cmp x0, #KS_SINGULAR
    b.eq 2f
    mov w0, #ERR_OVERFLOW
    b _bsk_err
2:
    mov w0, #ERR_SINGULAR_MATRIX
    b _bsk_err

// ---------------------------------------------------------------------
// _bsk_mat_redim1 -- redimension to r x 1 (LANGUAGE.md 7.14.3).
//   Inputs  : x0 = descriptor, d0 = r (unrounded)
//   Outputs : none
//   Errors  : DIMENSION ERROR (r < 0.5, too large, does not fit)
//   Clobbers: x0-x2, x9-x11, d0, d16, d17
//   Callee-saved used: x19 = descriptor
//   Frame   : 32 bytes (frame record + x19)
// ---------------------------------------------------------------------
    .globl _bsk_mat_redim1
    .p2align 2
_bsk_mat_redim1:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov x19, x0
    bl Lrt_mat_dimarg               // x0 = r
    mov x1, x0
    mov x2, #1
    mov x0, x19
    bl Lrt_mat_fits
    bl Lrt_mat_setshape
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _bsk_mat_redim2 -- redimension to r x c (LANGUAGE.md 7.14.3).
//   Inputs  : x0 = descriptor, d0 = r, d1 = c (unrounded)
//   Outputs : none
//   Errors  : DIMENSION ERROR
//   Clobbers: x0-x2, x9-x11, d0, d1, d16, d17
//   Callee-saved used: x19 = descriptor, x20 = r
//   Frame   : 32 bytes (frame record + x19, x20)
// ---------------------------------------------------------------------
    .globl _bsk_mat_redim2
    .p2align 2
_bsk_mat_redim2:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    bl Lrt_mat_dimarg               // r (d1 is preserved by dimarg)
    mov x20, x0
    fmov d0, d1
    bl Lrt_mat_dimarg               // c
    mov x2, x0
    mov x1, x20
    mov x0, x19
    bl Lrt_mat_fits
    bl Lrt_mat_setshape
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _bsk_mat_read -- MAT READ with the current shape: elements (1,1) ...
//   (1,c), (2,1) ... from the DATA block, each stored as it is read (an
//   OUT OF DATA in the middle ends the program after the earlier ones).
//   Inputs  : x0 = descriptor
//   Outputs : none
//   Errors  : DIMENSION ERROR (zero dimension); OUT OF DATA (_bsk_read)
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = row address, x20 = rows left, x21 = columns,
//             x22 = row stride (bytes), x23 = column index
//   Frame   : 96 bytes (frame record + x19..x23 + view at [sp,#64])
// ---------------------------------------------------------------------
    .globl _bsk_mat_read
    .p2align 2
_bsk_mat_read:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]
    bl Lrt_mat_shape
    add x1, sp, #64
    bl Lrt_mat_view
    ldr x19, [sp, #64 + MV_DATA]
    ldr x20, [sp, #64 + MV_ROWS]
    ldr x21, [sp, #64 + MV_COLS]
    ldr x22, [sp, #64 + MV_LD]
    lsl x22, x22, #3
Lrt_mat_read_row:
    mov x23, #0
Lrt_mat_read_col:
    bl _bsk_read                    // d0 = next DATA value
    str d0, [x19, x23, lsl #3]
    add x23, x23, #1
    cmp x23, x21
    b.lo Lrt_mat_read_col
    add x19, x19, x22
    subs x20, x20, #1
    b.ne Lrt_mat_read_row
    ldr x23, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret

// ---------------------------------------------------------------------
// _bsk_mat_print -- one MAT PRINT item (LANGUAGE.md 7.14.5 steps 2-3).
//   Purpose : newline if col != 0; then each row: the elements as PRINT
//             number items separated by the ',' rule (zoned) or the
//             ';'-after-a-number rule (packed), and a newline after the
//             row. A list is printed as one row of its n elements.
//   Inputs  : x0 = descriptor, w1 = MATPR_ZONED or MATPR_PACKED
//   Outputs : none
//   Errors  : DIMENSION ERROR (zero dimension)
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = row address, x20 = rows left, x21 = columns,
//             x22 = row stride (bytes), x23 = column index, x24 = mode
//   Frame   : 96 bytes (frame record + x19..x24 + view at [sp,#64])
// ---------------------------------------------------------------------
    .globl _bsk_mat_print
    .p2align 2
_bsk_mat_print:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    mov w24, w1
    bl Lrt_mat_shape
    add x1, sp, #64
    bl Lrt_mat_view
    ldr x19, [sp, #64 + MV_DATA]
    ldr x20, [sp, #64 + MV_ROWS]
    ldr x21, [sp, #64 + MV_COLS]
    ldr x22, [sp, #64 + MV_LD]
    lsl x22, x22, #3
    ldr w9, [x0, #RTA_DIMS]
    cmp w9, #1
    b.ne 1f
    mov x21, x20                    // a list: one row of n elements
    mov x20, #1
1:
    bl _bsk_rt_print_bol            // a matrix starts on a new line
Lrt_mat_print_row:
    mov x23, #0
Lrt_mat_print_col:
    ldr d0, [x19, x23, lsl #3]
    bl _bsk_print_num
    add x23, x23, #1
    cmp x23, x21
    b.hs Lrt_mat_print_eol          // last element of the row
    cmp w24, #MATPR_PACKED
    b.eq 2f
    bl _bsk_print_comma             // zoned
    b Lrt_mat_print_col
2:
    bl _bsk_print_semi              // packed
    b Lrt_mat_print_col
Lrt_mat_print_eol:
    bl _bsk_print_nl                // newline after each row
    add x19, x19, x22
    subs x20, x20, #1
    b.ne Lrt_mat_print_row
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret

// ---------------------------------------------------------------------
// _bsk_smat_print -- one MAT PRINT item that is a string list or (Fifth
//   Edition) a string table (LANGUAGE.md 7.14.5 steps 2-3).
//   Purpose : a zero dimension (list bound 0, table r or c 0) ->
//             DIMENSION ERROR; newline if col != 0; then each row -- a
//             list is one row X$(1) .. X$(n), a table r rows X$(i,1) ..
//             X$(i,c) -- as §8 string items, each but the last of its
//             row followed by the ',' rule (zoned) or nothing (packed),
//             and a newline after each row.
//   Inputs  : x0 = string-list or string-table descriptor,
//             w1 = MATPR_ZONED or MATPR_PACKED
//   Outputs : none
//   Errors  : DIMENSION ERROR (zero dimension)
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = address of the current row's first element,
//             x20 = rows left, x21 = columns, x22 = row stride (bytes),
//             x23 = column index, x24 = mode
//   Frame   : 64 bytes (frame record + x19..x24)
// ---------------------------------------------------------------------
    .globl _bsk_smat_print
    .p2align 2
_bsk_smat_print:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    mov w24, w1                     // mode
    ldr w9, [x0, #RTA_DIMS]
    ldr x19, [x0, #RTA_DATA]
    cmp w9, #1
    b.ne 1f
    ldr w21, [x0, #RTA_B1]          // a list: one row of its n elements
    cbz w21, Lrt_mat_dimerr         // an empty list is no vector
    mov w20, #1
    add x19, x19, #SD_SIZE          // element 1
    mov x22, #0                     // (one row: no stride needed)
    b 2f
1:
    ldr w20, [x0, #RTA_B1]          // a table: r rows ...
    cbz w20, Lrt_mat_dimerr
    ldr w21, [x0, #RTA_B2]          // ... of c columns
    cbz w21, Lrt_mat_dimerr
    ldr w22, [x0, #RTA_ROWLEN]
    lsl x22, x22, #4                // row stride: ROWLEN SD records
    add x19, x19, x22
    add x19, x19, #SD_SIZE          // element (1,1)
2:
    bl _bsk_rt_print_bol            // the item starts on a new line
Lrt_mat_sprint_row:
    mov x23, #0
Lrt_mat_sprint_elem:
    add x0, x19, x23, lsl #4        // element of column x23 + 1
    bl _bsk_print_sv                // string item
    add x23, x23, #1
    cmp x23, x21
    b.hs Lrt_mat_sprint_eol         // that was the last of the row
    cmp w24, #MATPR_PACKED
    b.eq Lrt_mat_sprint_elem        // packed: nothing between strings
    bl _bsk_print_comma             // zoned: next zone
    b Lrt_mat_sprint_elem
Lrt_mat_sprint_eol:
    bl _bsk_print_nl                // newline after the row
    add x19, x19, x22               // next row
    subs x20, x20, #1
    b.ne Lrt_mat_sprint_row
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

// ---------------------------------------------------------------------
// Lrt_mat_fillv -- fill the current matrix of a descriptor with v.
//   Inputs  : x0 = descriptor, d0 = v
//   Outputs : none
//   Errors  : DIMENSION ERROR (zero dimension)
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : 48 bytes (frame record + view at [sp,#16])
// ---------------------------------------------------------------------
    .p2align 2
Lrt_mat_fillv:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    bl Lrt_mat_shape
    add x1, sp, #16
    bl Lrt_mat_view
    add x0, sp, #16
    bl _bsk_kern_fill               // d0 = v is untouched so far
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// _bsk_mat_zer / _bsk_mat_con -- every element of the current matrix
//   := 0 / 1.
//   Inputs  : x0 = descriptor
//   Outputs : none
//   Errors  : DIMENSION ERROR (zero dimension)
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : none (tail call)
// ---------------------------------------------------------------------
    .globl _bsk_mat_zer
    .p2align 2
_bsk_mat_zer:
    movi d0, #0
    b Lrt_mat_fillv

    .globl _bsk_mat_con
    .p2align 2
_bsk_mat_con:
    fmov d0, #1.0
    b Lrt_mat_fillv

// ---------------------------------------------------------------------
// _bsk_mat_idn -- identity of the current (square) shape.
//   Inputs  : x0 = descriptor
//   Outputs : none
//   Errors  : DIMENSION ERROR (zero dimension, not square)
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : 48 bytes (frame record + view at [sp,#16])
// ---------------------------------------------------------------------
    .globl _bsk_mat_idn
    .p2align 2
_bsk_mat_idn:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    bl Lrt_mat_shape
    cmp x1, x2
    b.ne Lrt_mat_dimerr             // IDN needs a square shape
    add x1, sp, #16
    bl Lrt_mat_view
    add x0, sp, #16
    movi d0, #0
    bl _bsk_kern_fill               // all zeros ...
    ldr x9, [sp, #16 + MV_DATA]
    ldr x10, [sp, #16 + MV_ROWS]
    ldr x11, [sp, #16 + MV_LD]
    add x11, x11, #1
    lsl x11, x11, #3                // step along the diagonal (bytes)
    fmov d0, #1.0
1:
    str d0, [x9]                    // ... then ones on the diagonal
    add x9, x9, x11
    subs x10, x10, #1
    b.ne 1b
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// _bsk_mat_copy -- MAT B = A.
//   Inputs  : x0 = destination descriptor, x1 = source descriptor
//   Outputs : none
//   Errors  : DIMENSION ERROR
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = destination, x20 = source
//   Frame   : 96 bytes (frame record + x19, x20 + views at [sp,#32]
//             (destination) and [sp,#64] (source))
// ---------------------------------------------------------------------
    .globl _bsk_mat_copy
    .p2align 2
_bsk_mat_copy:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    mov x20, x1
    mov x0, x20
    bl Lrt_mat_shape                // x1 x x2 = the source's shape
    mov x0, x19
    bl Lrt_mat_fits
    cmp x19, x20
    b.eq Lrt_mat_copy_done          // MAT A = A: nothing to do
    bl Lrt_mat_setshape
    add x1, sp, #32
    bl Lrt_mat_view                 // destination view
    mov x0, x20
    add x1, sp, #64
    bl Lrt_mat_view                 // source view
    add x0, sp, #32
    add x1, sp, #64
    bl _bsk_kern_copy
Lrt_mat_copy_done:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret

// ---------------------------------------------------------------------
// _bsk_mat_trn -- MAT C = TRN(A): the c x r transpose of an r x c A.
//   Inputs  : x0 = destination descriptor, x1 = source descriptor
//   Outputs : none
//   Errors  : DIMENSION ERROR
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = destination, x20 = source, x21 = result
//             rows (c), x22 = result columns (r)
//   Frame   : 144 bytes (frame record + x19..x22 + views at [sp,#48]
//             (destination), [sp,#80] (source), [sp,#112] (temporary))
// ---------------------------------------------------------------------
    .globl _bsk_mat_trn
    .p2align 2
_bsk_mat_trn:
    stp x29, x30, [sp, #-144]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov x19, x0
    mov x20, x1
    mov x0, x20
    bl Lrt_mat_shape                // source r x c
    mov x21, x2                     // result rows = c
    mov x22, x1                     // result columns = r
    mov x0, x19
    mov x1, x21
    mov x2, x22
    bl Lrt_mat_fits
    mov x0, x20
    add x1, sp, #80
    bl Lrt_mat_view                 // source view
    cmp x19, x20
    b.eq Lrt_mat_trn_alias
    mov x0, x19
    mov x1, x21
    mov x2, x22
    bl Lrt_mat_setshape             // target shape first, then straight in
    add x1, sp, #48
    bl Lrt_mat_view
    add x0, sp, #48
    add x1, sp, #80
    bl _bsk_kern_trn
    b Lrt_mat_trn_done
Lrt_mat_trn_alias:
    // MAT A = TRN(A): transpose into the temporary, then copy.
    mov x1, x21
    mov x2, x22
    add x3, sp, #112
    bl Lrt_mat_tmpview
    add x0, sp, #112
    add x1, sp, #80
    bl _bsk_kern_trn
    mov x0, x19
    mov x1, x21
    mov x2, x22
    bl Lrt_mat_setshape
    add x1, sp, #48
    bl Lrt_mat_view
    add x0, sp, #48
    add x1, sp, #112
    bl _bsk_kern_copy
Lrt_mat_trn_done:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #144
    ret

// ---------------------------------------------------------------------
// _bsk_mat_inv -- MAT C = INV(A) (LANGUAGE.md 7.14.6, kernel
//   _bsk_kern_inv).
//   Inputs  : x0 = destination descriptor, x1 = source descriptor
//   Outputs : none
//   Errors  : DIMENSION ERROR (A not square, result does not fit);
//             SINGULAR MATRIX; OVERFLOW
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = destination, x20 = source, x21 = n
//   Frame   : 144 bytes (frame record + x19..x21 + views at [sp,#48]
//             (destination), [sp,#80] (source), [sp,#112] (temporary))
// ---------------------------------------------------------------------
    .globl _bsk_mat_inv
    .p2align 2
_bsk_mat_inv:
    stp x29, x30, [sp, #-144]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov x19, x0
    mov x20, x1
    mov x0, x20
    bl Lrt_mat_shape
    cmp x1, x2
    b.ne Lrt_mat_dimerr             // INV needs a square matrix
    mov x21, x1                     // n
    mov x0, x19
    bl Lrt_mat_fits
    // The kernel's static workspace bounds n. Storage limits keep every
    // BASIC matrix far below it (n <= 999, LANGUAGE.md 12); the test only
    // guards the kernel's precondition.
    cmp x21, #RT_KERN_INV_MAXN
    b.hi Lrt_mat_dimerr
    mov x0, x20
    add x1, sp, #80
    bl Lrt_mat_view                 // source view
    cmp x19, x20
    b.eq Lrt_mat_inv_alias
    mov x0, x19
    mov x1, x21
    mov x2, x21
    bl Lrt_mat_setshape
    add x1, sp, #48
    bl Lrt_mat_view
    add x0, sp, #48
    add x1, sp, #80
    bl _bsk_kern_inv
    bl Lrt_mat_status
    b Lrt_mat_inv_done
Lrt_mat_inv_alias:
    // MAT B = INV(B): invert into the temporary, check, then copy.
    mov x1, x21
    mov x2, x21
    add x3, sp, #112
    bl Lrt_mat_tmpview
    add x0, sp, #112
    add x1, sp, #80
    bl _bsk_kern_inv
    bl Lrt_mat_status
    mov x0, x19
    mov x1, x21
    mov x2, x21
    bl Lrt_mat_setshape
    add x1, sp, #48
    bl Lrt_mat_view
    add x0, sp, #48
    add x1, sp, #112
    bl _bsk_kern_copy
Lrt_mat_inv_done:
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #144
    ret

// ---------------------------------------------------------------------
// Lrt_mat_elem -- shared body of MAT C = A + B, A - B and (K)*A.
//   Purpose : shapes of A and (for + and -) B must be equal; the target
//             must fit; the shape does not change when the target is an
//             operand, so the kernel runs in place then, and otherwise
//             the target's shape is set first. Kernel status OVERFLOW.
//   Inputs  : x0 = destination, x1 = A, x2 = B descriptor or 0 for (K)*,
//             x3 = kernel trampoline, d0 = K (for (K)*)
//   Outputs : none
//   Errors  : DIMENSION ERROR; OVERFLOW
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = destination, x20 = A, x21 = B or 0,
//             x22 = kernel, d8 = K
//   Frame   : 160 bytes (frame record + x19..x22 + d8 + views at
//             [sp,#64] (C), [sp,#96] (A), [sp,#128] (B))
// ---------------------------------------------------------------------
    .p2align 2
Lrt_mat_elem:
    stp x29, x30, [sp, #-160]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str d8, [sp, #48]
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    fmov d8, d0
    // Operand shapes and conformability.
    cbz x21, 1f
    mov x0, x21
    bl Lrt_mat_shape
    mov x10, x1                     // B's shape
    mov x11, x2
    mov x0, x20
    bl Lrt_mat_shape
    cmp x1, x10
    ccmp x2, x11, #0, eq
    b.ne Lrt_mat_dimerr             // A and B differ in shape
    b 2f
1:
    mov x0, x20
    bl Lrt_mat_shape
2:
    // Target fits, then set its shape (unchanged if it is an operand).
    mov x0, x19
    bl Lrt_mat_fits
    bl Lrt_mat_setshape
    add x1, sp, #64
    bl Lrt_mat_view                 // C view
    mov x0, x20
    add x1, sp, #96
    bl Lrt_mat_view                 // A view
    cbz x21, 3f
    mov x0, x21
    add x1, sp, #128
    bl Lrt_mat_view                 // B view
3:
    add x0, sp, #64
    add x1, sp, #96
    add x2, sp, #128                // ignored by the scale kernel
    fmov d0, d8                     // ignored by add / sub
    blr x22
    bl Lrt_mat_status
    ldr d8, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #160
    ret

// ---------------------------------------------------------------------
// _bsk_mat_add / _bsk_mat_sub -- MAT C = A + B / A - B.
//   Inputs  : x0 = destination, x1 = A, x2 = B (descriptors)
//   Outputs : none
//   Errors  : DIMENSION ERROR; OVERFLOW
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none (see Lrt_mat_elem)
//   Frame   : none (tail call)
// ---------------------------------------------------------------------
    .globl _bsk_mat_add
    .p2align 2
_bsk_mat_add:
    adrp x3, _bsk_kern_add@PAGE
    add x3, x3, _bsk_kern_add@PAGEOFF
    b Lrt_mat_elem

    .globl _bsk_mat_sub
    .p2align 2
_bsk_mat_sub:
    adrp x3, _bsk_kern_sub@PAGE
    add x3, x3, _bsk_kern_sub@PAGEOFF
    b Lrt_mat_elem

// ---------------------------------------------------------------------
// _bsk_mat_scale -- MAT C = (K)*A.
//   Inputs  : x0 = destination, x1 = A (descriptors), d0 = K
//   Outputs : none
//   Errors  : DIMENSION ERROR; OVERFLOW
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none (see Lrt_mat_elem)
//   Frame   : none (tail call)
// ---------------------------------------------------------------------
    .globl _bsk_mat_scale
    .p2align 2
_bsk_mat_scale:
    mov x2, #0                      // no second operand
    adrp x3, _bsk_kern_scale@PAGE
    add x3, x3, _bsk_kern_scale@PAGEOFF
    b Lrt_mat_elem

// ---------------------------------------------------------------------
// _bsk_mat_mul -- MAT C = A * B (LANGUAGE.md 7.14.7, kernel
//   _bsk_kern_gemm).
//   Inputs  : x0 = destination, x1 = A, x2 = B (descriptors)
//   Outputs : none
//   Errors  : DIMENSION ERROR (columns of A != rows of B, result does not
//             fit); OVERFLOW
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = destination, x20 = A, x21 = B, x22 = result
//             rows m, x23 = result columns n
//   Frame   : 192 bytes (frame record + x19..x23 + views at [sp,#64] (C),
//             [sp,#96] (A), [sp,#128] (B), [sp,#160] (temporary))
// ---------------------------------------------------------------------
    .globl _bsk_mat_mul
    .p2align 2
_bsk_mat_mul:
    stp x29, x30, [sp, #-192]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x0, x21
    bl Lrt_mat_shape                // B: k2 x n
    mov x23, x2                     // n
    mov x10, x1                     // k2
    mov x0, x20
    bl Lrt_mat_shape                // A: m x k
    cmp x2, x10
    b.ne Lrt_mat_dimerr             // columns of A != rows of B
    mov x22, x1                     // m
    mov x0, x19
    mov x2, x23
    bl Lrt_mat_fits                 // m x n into the target
    mov x0, x20
    add x1, sp, #96
    bl Lrt_mat_view                 // A view
    mov x0, x21
    add x1, sp, #128
    bl Lrt_mat_view                 // B view
    cmp x19, x20
    b.eq Lrt_mat_mul_alias
    cmp x19, x21
    b.eq Lrt_mat_mul_alias
    mov x0, x19
    mov x1, x22
    mov x2, x23
    bl Lrt_mat_setshape             // target shape first, then straight in
    add x1, sp, #64
    bl Lrt_mat_view
    add x0, sp, #64
    add x1, sp, #96
    add x2, sp, #128
    bl _bsk_kern_gemm
    bl Lrt_mat_status
    b Lrt_mat_mul_done
Lrt_mat_mul_alias:
    // The target is an operand: multiply into the temporary, check,
    // then set the shape and copy.
    mov x1, x22
    mov x2, x23
    add x3, sp, #160
    bl Lrt_mat_tmpview
    add x0, sp, #160
    add x1, sp, #96
    add x2, sp, #128
    bl _bsk_kern_gemm
    bl Lrt_mat_status
    mov x0, x19
    mov x1, x22
    mov x2, x23
    bl Lrt_mat_setshape
    add x1, sp, #64
    bl Lrt_mat_view
    add x0, sp, #64
    add x1, sp, #160
    bl _bsk_kern_copy
Lrt_mat_mul_done:
    ldr x23, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #192
    ret

// The static MAT result temporary (DESIGN.md 6.6.6): RT_MAT_SCRATCH_ELEMS
// doubles (8 MiB, >= LIM_ARRAY_ELEMS, so any result that fits a target
// fits here), 64-byte aligned.
.if RT_MAT_SCRATCH_ELEMS < LIM_ARRAY_ELEMS
    .error "rt_mat: the result temporary is smaller than the largest array"
.endif
.zerofill __DATA,__bss,_bsk_rt_mat_tmp,RT_MAT_SCRATCH_ELEMS*8,6
