// =====================================================================
// src/runtime/rt_kneon_trn.s -- `neon` blocked transpose
// (DESIGN.md 6.6.1, 6.6.5; determinism class E: exact copies).
//
// Defines (runtime-private, .private_extern):
//   _bsk_kneon_trn (x0 C, x1 A)       C (n x m) = transpose of A (m x n)
//
// Method: the largest 4-aligned part of A (m4 = m & ~3 rows, n4 = n & ~3
// columns) is walked in RT_KT_BLK x RT_KT_BLK cache blocks; inside a
// block, 4 x 4 tiles are loaded as four rows of two q registers and
// transposed in registers with zip1/zip2 on .2d (2 x 2 sub-tiles), then
// stored as four rows of C. The remaining strips (rows m4..m-1 of A, and
// columns n4..n-1 of rows 0..m4-1) are copied element by element.
// Only whole doubles are moved, so every value is copied exactly.
//
// Link isolation (DESIGN.md 6.6.1): references no other runtime file.
// =====================================================================
.include "baysick.inc"

.equ RT_KT_BLK, 32                  // block edge in elements (multiple of 4)

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _bsk_kneon_trn -- C = transpose of A.
//   Inputs  : x0 = C view (n x m), x1 = A view (m x n); no overlap
//   Outputs : none
//   Clobbers: x0-x17, v0-v7, v16-v23
//   Callee-saved used: none
//   Frame   : none (leaf)
// Registers:
//   x2 = m, x3 = n, x4 = lda (bytes), x5 = ldc (bytes), x6 = A data,
//   x7 = C data, x8 = m4, x9 = n4, x10 = ib (block row), x11 = jb (block
//   column), x12 = i, x13 = j, x14 = block row end, x15 = block col end,
//   x16/x17 = addresses (no calls are made, so they are safe here).
// ---------------------------------------------------------------------
    .private_extern _bsk_kneon_trn
    .p2align 2
_bsk_kneon_trn:
    ldr x2, [x1, #MV_ROWS]          // m
    ldr x3, [x1, #MV_COLS]          // n
    ldr x4, [x1, #MV_LD]
    ldr x5, [x0, #MV_LD]
    ldr x6, [x1, #MV_DATA]
    ldr x7, [x0, #MV_DATA]
    lsl x4, x4, #3                  // strides in bytes
    lsl x5, x5, #3
    and x8, x2, #~3                 // m4
    and x9, x3, #~3                 // n4

    // ---- blocked 4 x 4 tiles over [0, m4) x [0, n4) ----
    mov x10, #0                     // ib
Lrt_kt_ib:
    cmp x10, x8
    b.hs Lrt_kt_edges
    add x14, x10, #RT_KT_BLK
    cmp x14, x8
    csel x14, x14, x8, lo           // block row end = min(ib + BLK, m4)
    mov x11, #0                     // jb
Lrt_kt_jb:
    cmp x11, x9
    b.hs Lrt_kt_ib_next
    add x15, x11, #RT_KT_BLK
    cmp x15, x9
    csel x15, x15, x9, lo           // block column end = min(jb + BLK, n4)
    mov x12, x10                    // i
Lrt_kt_i:
    cmp x12, x14
    b.hs Lrt_kt_jb_next
    mov x13, x11                    // j
Lrt_kt_j:
    cmp x13, x15
    b.hs Lrt_kt_i_next
    // A tile rows: x16 = &A(i, j)
    madd x16, x12, x4, x6
    add x16, x16, x13, lsl #3
    ldp q0, q1, [x16]               // A(i,   j..j+3)
    add x16, x16, x4
    ldp q2, q3, [x16]               // A(i+1, j..j+3)
    add x16, x16, x4
    ldp q4, q5, [x16]               // A(i+2, j..j+3)
    add x16, x16, x4
    ldp q6, q7, [x16]               // A(i+3, j..j+3)
    // Transpose: C(j+c, i..i+3) = A(i..i+3, j+c).
    zip1 v16.2d, v0.2d, v2.2d       // A(i,j)   A(i+1,j)
    zip1 v17.2d, v4.2d, v6.2d       // A(i+2,j) A(i+3,j)
    zip2 v18.2d, v0.2d, v2.2d       // column j+1
    zip2 v19.2d, v4.2d, v6.2d
    zip1 v20.2d, v1.2d, v3.2d       // column j+2
    zip1 v21.2d, v5.2d, v7.2d
    zip2 v22.2d, v1.2d, v3.2d       // column j+3
    zip2 v23.2d, v5.2d, v7.2d
    // C rows: x17 = &C(j, i)
    madd x17, x13, x5, x7
    add x17, x17, x12, lsl #3
    stp q16, q17, [x17]
    add x17, x17, x5
    stp q18, q19, [x17]
    add x17, x17, x5
    stp q20, q21, [x17]
    add x17, x17, x5
    stp q22, q23, [x17]
    add x13, x13, #4
    b Lrt_kt_j
Lrt_kt_i_next:
    add x12, x12, #4
    b Lrt_kt_i
Lrt_kt_jb_next:
    mov x11, x15
    b Lrt_kt_jb
Lrt_kt_ib_next:
    mov x10, x14
    b Lrt_kt_ib

    // ---- edge strips, element by element ----
Lrt_kt_edges:
    // Columns n4..n-1 of rows 0..m4-1.
    mov x12, #0
Lrt_kt_ec_i:
    cmp x12, x8
    b.hs Lrt_kt_er
    mov x13, x9
Lrt_kt_ec_j:
    cmp x13, x3
    b.hs Lrt_kt_ec_i_next
    madd x16, x12, x4, x6
    ldr x15, [x16, x13, lsl #3]     // A(i, j) as raw bits
    madd x17, x13, x5, x7
    str x15, [x17, x12, lsl #3]     // C(j, i)
    add x13, x13, #1
    b Lrt_kt_ec_j
Lrt_kt_ec_i_next:
    add x12, x12, #1
    b Lrt_kt_ec_i
    // Rows m4..m-1, every column.
Lrt_kt_er:
    mov x12, x8
Lrt_kt_er_i:
    cmp x12, x2
    b.hs Lrt_kt_done
    madd x16, x12, x4, x6           // &A(i, 0)
    add x17, x7, x12, lsl #3        // &C(0, i)
    mov x13, #0
Lrt_kt_er_j:
    cmp x13, x3
    b.hs Lrt_kt_er_i_next
    ldr x15, [x16, x13, lsl #3]
    str x15, [x17]
    add x17, x17, x5                // next row of C
    add x13, x13, #1
    b Lrt_kt_er_j
Lrt_kt_er_i_next:
    add x12, x12, #1
    b Lrt_kt_er_i
Lrt_kt_done:
    ret
