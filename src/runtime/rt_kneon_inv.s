// =====================================================================
// src/runtime/rt_kneon_inv.s -- `neon` matrix inverse: the pinned
// Gauss-Jordan elimination of LANGUAGE.md 7.14.6 (DESIGN.md 6.6.1,
// 6.6.5; determinism class E: bit-identical on every target/variant).
//
// Defines (runtime-private, .private_extern):
//   _bsk_kneon_inv (x0 X, x1 A) -> x0 KS_*     X = inverse of A (n x n)
//
// The pinned algorithm (0-based; W = working copy of A in the static
// workspace, row stride n; X starts as the identity):
//   m   := max |A(i,j)|;  tol := (n * 2^-52) * m
//   for p: pivot r = first row i >= p with the largest |W(i,p)|
//          (strict >, so ties go to the smallest row);
//          best <= tol -> KS_SINGULAR; swap rows p, r of W and X;
//          d := W(p,p), not finite -> KS_NONFINITE;
//          W(p,j) /= d (j > p); X(p,j) /= d (all j);
//          for i != p: f := W(i,p); W(i,j) -= f*W(p,j) (j > p);
//                                   X(i,j) -= f*X(p,j) (all j)
//   then the finite test of X (_bsk_kneon_chkview).
// Every operation is a single IEEE double operation: true division
// (fdiv), and fmul then fsub (never fmla/fmls); the vector and
// by-element forms (.2d, .d[k]) compute each lane exactly as the scalar
// form would.
//
// Schedule: delayed updates in panels of RT_KI_NB pivot columns
// (p0 <= p < pe), the schedule of the x86_64 runtime (rt_ksse2_inv.s).
// Every element still receives exactly the pinned operations in the
// pinned order (one rounded product, then one rounded subtraction; true
// divisions); only the order in which DIFFERENT elements are processed
// changes:
//   * the panel columns p0 .. pe-1 of W are updated eagerly at every
//     step, so the pivot search and the multipliers f = W(i,p) are
//     always current; a multiplier stays stored at W(i,p) (column p is
//     never written after step p);
//   * the trailing part of a row (W columns pe .. n-1, and X) is updated
//     late: the pivot row p is brought up to date (steps p0 .. p-1, its
//     multipliers W(p,q)) just before its division; after the panel
//     every non-pivot row applies steps p0 .. pe-1 (Lrt_ki_upd: 4 x 8
//     register tiles, 16 accumulators, the step loop innermost), then
//     each panel pivot row i applies the steps after its own
//     (i+1 .. pe-1), in increasing i, so every step reads its pivot
//     row's values as of that step;
//   * a row exchange moves the whole row (W columns p0 .. n-1 with the
//     stored multipliers, all of X), so pending updates travel with it.
//
// Skipped zero updates (allowed by LANGUAGE.md 7.14.6: an update may be
// skipped when that cannot change the status or any finite element): a column of X is
// "untouched" until the row holding its 1.0 becomes a pivot row; before
// that every other entry of it is exactly zero and row operations only
// subtract multiples of zero from it. X is kept with its columns in a
// private storage order in which the touched columns are 0..p at step p:
// when row p becomes the pivot row, its unit column is exchanged with
// storage column p (only the two 1.0 entries move, both columns being
// untouched). Step p then divides storage columns 0..p of the pivot row,
// and the delayed X updates of a panel cover storage columns 0..pe-1
// (each step q < pe touches at most columns 0..q; the extra products
// with columns q+1..pe-1 are pinned operations on exact zeros, so
// performing them is the plain algorithm itself). Only products
// f * (exact zero of an untouched column) are skipped. When f is finite
// they are zero, as required. A non-finite f (W overflowed) would make
// the skipped product NaN, but the column is later touched (every
// column of X is a pivot column at some step) with the same non-finite
// multiplier f, and X(i,q) = X(i,q) - f*X(q,q) (X(q,q) = 1/d non-zero)
// is then non-finite in both forms; a non-finite element never becomes
// finite again and the pivots depend on W only, so the status and
// every finite element are the same either way, and the values are
// those of the full algorithm up to the sign of zeros. At the
// end each row of X is permuted back to the original column order.
// Columns 0..p0-1 of W are never read after their panel, so the row
// exchange and the W updates only touch columns p0..n-1.
//
// Comparisons: "|W(i,p)| > best" uses b.gt and "best <= tol" uses b.ls,
// both false when an operand is NaN, as the pseudo-code reads; the pivot
// test "d is +-inf or NaN" is "not (|d| < inf)" (b.mi = ordered less).
//
// RT_KI_NB (panel width) can be overridden at assembly time
// (`as -Wa,-defsym,RT_KI_NB=<k>`, any k >= 1): the result does not depend
// on it.
//
// Link isolation (DESIGN.md 6.6.1): references only rt_kneon_elem.s.
// =====================================================================
.include "baysick.inc"

.equ RT_KI_TWO_M52, (1023 - RT_INV_TOL_SHIFT) << 52 // 2^-52 as IEEE double bits
.equ RT_KI_INF,     0x7FF0000000000000 // +infinity
.equ RT_KI_ROWOF,   RT_KERN_INV_MAXN * 4     // offsets in _bsk_rt_kinv_idx
.equ RT_KI_COLOF,   RT_KERN_INV_MAXN * 8
.ifndef RT_KI_NB
.equ RT_KI_NB,      16              // panel width (measured best 8-32 on the M2 Pro)
.endif
.equ RT_KI_JB,      128             // column chunk of Lrt_ki_upd (multiple of 8)
.equ RT_KI_TOL,     160             // frame offset of tol in _bsk_kneon_inv
.equ RT_KI_FRAME,   176             // frame size of _bsk_kneon_inv

    .section __TEXT,__text,regular,pure_instructions

// RT_KI_AXPY dst, src, cnt: dst[j] := dst[j] - f*src[j], j = 0..cnt-1,
// with f in both lanes of v21 (scalar d21). fmul then fsub per element.
// Uses x12-x15, v0-v7.
.macro RT_KI_AXPY dst, src, cnt
    mov x12, \dst
    mov x13, \src
    lsr x15, \cnt, #3               // blocks of 8
    cbz x15, 2f
1:
    ldp q0, q1, [x13], #32          // src
    ldp q2, q3, [x13], #32
    ldp q4, q5, [x12]               // dst
    ldp q6, q7, [x12, #32]
    fmul v0.2d, v0.2d, v21.2d       // f*src, rounded
    fmul v1.2d, v1.2d, v21.2d
    fmul v2.2d, v2.2d, v21.2d
    fmul v3.2d, v3.2d, v21.2d
    fsub v4.2d, v4.2d, v0.2d        // dst - f*src, rounded
    fsub v5.2d, v5.2d, v1.2d
    fsub v6.2d, v6.2d, v2.2d
    fsub v7.2d, v7.2d, v3.2d
    stp q4, q5, [x12], #32
    stp q6, q7, [x12], #32
    subs x15, x15, #1
    b.ne 1b
2:
    and x14, \cnt, #7
    lsr x15, x14, #1                // pairs left
    cbz x15, 4f
3:
    ldr q0, [x13], #16
    ldr q4, [x12]
    fmul v0.2d, v0.2d, v21.2d
    fsub v4.2d, v4.2d, v0.2d
    str q4, [x12], #16
    subs x15, x15, #1
    b.ne 3b
4:
    tbz x14, #0, 5f                 // odd count: one scalar
    ldr d0, [x13]
    ldr d4, [x12]
    fmul d0, d0, d21
    fsub d4, d4, d0
    str d4, [x12]
5:
.endm

// RT_KI_DIV ptr, cnt: ptr[j] := ptr[j] / d, j = 0..cnt-1, with d in both
// lanes of v19 (scalar d19). True division. Uses x12, x14, x15, v0-v3.
.macro RT_KI_DIV ptr, cnt
    mov x12, \ptr
    lsr x15, \cnt, #2               // blocks of 4
    cbz x15, 2f
1:
    ldp q0, q1, [x12]
    fdiv v0.2d, v0.2d, v19.2d
    fdiv v1.2d, v1.2d, v19.2d
    stp q0, q1, [x12], #32
    subs x15, x15, #1
    b.ne 1b
2:
    and x14, \cnt, #3
    lsr x15, x14, #1
    cbz x15, 3f
    ldr q0, [x12]                   // one pair
    fdiv v0.2d, v0.2d, v19.2d
    str q0, [x12], #16
3:
    tbz x14, #0, 4f
    ldr d0, [x12]
    fdiv d0, d0, d19
    str d0, [x12]
4:
.endm

// RT_KI_SWAP pa, pb, cnt: exchange cnt doubles at pa and pb (exact).
// Uses x12-x16, v0-v3.
.macro RT_KI_SWAP pa, pb, cnt
    mov x12, \pa
    mov x13, \pb
    lsr x15, \cnt, #2
    cbz x15, 2f
1:
    ldp q0, q1, [x12]
    ldp q2, q3, [x13]
    stp q2, q3, [x12], #32
    stp q0, q1, [x13], #32
    subs x15, x15, #1
    b.ne 1b
2:
    ands x14, \cnt, #3
    b.eq 4f
3:
    ldr x15, [x12]
    ldr x16, [x13]
    str x16, [x12], #8
    str x15, [x13], #8
    subs x14, x14, #1
    b.ne 3b
4:
.endm

// RT_KI_EPILOGUE: restore the registers saved by _bsk_kneon_inv and pop
// its frame (x0 untouched).
.macro RT_KI_EPILOGUE
    ldp d14, d15, [sp, #144]
    ldp d12, d13, [sp, #128]
    ldp d10, d11, [sp, #112]
    ldp d8, d9, [sp, #96]
    ldp x27, x28, [sp, #80]
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #RT_KI_FRAME
.endm

// RT_KI_ROW4 a0..a3, y0..y3, f: one tile row, one step:
// a_k := a_k - (y_k * f), the product rounded (into v28-v31), then the
// subtraction rounded. f is a by-element operand (vN.d[lane]).
.macro RT_KI_ROW4 a0, a1, a2, a3, y0, y1, y2, y3, f
    fmul v28.2d, \y0, \f
    fmul v29.2d, \y1, \f
    fmul v30.2d, \y2, \f
    fmul v31.2d, \y3, \f
    fsub \a0, \a0, v28.2d
    fsub \a1, \a1, v29.2d
    fsub \a2, \a2, v30.2d
    fsub \a3, \a3, v31.2d
.endm

// RT_KI_COL4 a0..a3, y, lane, t0..t3: one step of a 4-row tile one
// vector (or one scalar) wide: a_r := a_r - (y * v(24+r).d[lane]), the
// product rounded into t_r, then the subtraction rounded. The operands
// are all .2d vectors or all d scalars (by-element multiply either way).
.macro RT_KI_COL4 a0, a1, a2, a3, y, lane, t0, t1, t2, t3
    fmul \t0, \y, v24.d[\lane]
    fmul \t1, \y, v25.d[\lane]
    fmul \t2, \y, v26.d[\lane]
    fmul \t3, \y, v27.d[\lane]
    fsub \a0, \a0, \t0
    fsub \a1, \a1, \t1
    fsub \a2, \a2, \t2
    fsub \a3, \a3, \t3
.endm

// RT_KI_STEP4 y0..y3, lane: one step of the 4 x 8 tile (accumulators
// v0-v15, row r in v(4r)..v(4r+3)); the multiplier of row r is lane
// `lane` of v(24+r), the pivot row's 8 columns are y0..y3.
.macro RT_KI_STEP4 y0, y1, y2, y3, lane
    RT_KI_ROW4 v0.2d, v1.2d, v2.2d, v3.2d, \y0, \y1, \y2, \y3, v24.d[\lane]
    RT_KI_ROW4 v4.2d, v5.2d, v6.2d, v7.2d, \y0, \y1, \y2, \y3, v25.d[\lane]
    RT_KI_ROW4 v8.2d, v9.2d, v10.2d, v11.2d, \y0, \y1, \y2, \y3, v26.d[\lane]
    RT_KI_ROW4 v12.2d, v13.2d, v14.2d, v15.2d, \y0, \y1, \y2, \y3, v27.d[\lane]
.endm

// ---------------------------------------------------------------------
// Lrt_ki_upd -- delayed row updates (Lrt_ki_* private convention):
//   for r = 0 .. nrows-1, q = 0 .. nq-1 (per element in this order):
//     T(r, c) := T(r, c) - M(r, q) * P(q, c),   c = 0 .. ncols-1
//   with T(r, .) = dst + r*ld, P(q, .) = src + q*ld (pivot rows of the
//   same matrix), M(r, q) = mult[r*ms + 8q] (stored multipliers).
//   Columns go in chunks of RT_KI_JB; per chunk, blocks of 4 rows go
//   through 4 x 8 register tiles (v0-v15 hold the tile for the whole q
//   loop, two steps per iteration: the multipliers of steps q, q+1 of a
//   row are one 16-byte load, used by element), their last chunk % 8
//   columns through 4 x 2 tiles and one 4 x 1 tile; the last 0..3 rows
//   through 1 x 16 tiles, then one 1 x 8 tile, then their last
//   columns step by step (Lrt_ki_tail: 2-wide, then one scalar).
//   Inputs  : x0 = dst, x1 = src, x2 = ncols, x3 = ld (bytes), x4 =
//             mult, x5 = ms (bytes), x6 = nq, x7 = nrows; ncols, nq or
//             nrows = 0 does nothing. T and P rows are disjoint.
//   Outputs : none
//   Clobbers: x8-x17, v0-v31 (all of them: the caller must have saved
//             d8-d15)
//   Callee-saved used: x19 = 2*ms, x20 = 3*ms, x21 = nq / 2 (step
//             pairs), x22 = nq & 1, x23 = scratch row pointer, x24 =
//             tail dst cursor, x25 = columns left for the tails, x27 =
//             tail pair counter (x26, x28 are saved only to keep the save
//             area in pairs)
//   Frame   : 96 bytes: frame record, x19-x28 (calls Lrt_ki_tail)
//   Registers: x8 = chunk column c, x9 = chunk width, x10 = &T(r, c),
//             x11 = &M(r, 0), x12 = rows left, x13 = column j in the
//             chunk, x14 = pivot-row pointer, x15 = multiplier pointer,
//             x16 = step counter, x17 = tile pointer.
// ---------------------------------------------------------------------
    .p2align 4
Lrt_ki_upd:
    cbz x2, Lrt_ki_upd_ret          // nothing to do
    cbz x6, Lrt_ki_upd_ret
    cbz x7, Lrt_ki_upd_ret
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    add x19, x5, x5                 // 2*ms
    add x20, x19, x5                // 3*ms
    lsr x21, x6, #1                 // step pairs
    and x22, x6, #1                 // one single step left?
    mov x8, #0                      // c = 0
Lrt_ki_upd_chunk:
    sub x9, x2, x8                  // columns left
    mov x10, #RT_KI_JB
    cmp x9, x10
    csel x9, x9, x10, lo            // chunk width = min(left, JB)
    add x10, x0, x8, lsl #3         // &T(0, c)
    mov x11, x4                     // &M(0, 0)
    mov x12, x7                     // rows left
Lrt_ki_upd_rb4:
    cmp x12, #4
    b.lo Lrt_ki_upd_r1
    mov x13, #0                     // j
Lrt_ki_upd_s4:
    add x14, x13, #8
    cmp x14, x9
    b.hi Lrt_ki_upd_t4              // fewer than 8 columns left
    // ---- 4 x 8 tile at T(r .. r+3, c+j .. c+j+7) ----
    add x17, x10, x13, lsl #3       // &T(r, c+j)
    add x14, x8, x13
    add x14, x1, x14, lsl #3        // &P(0, c+j)
    mov x15, x11                    // &M(r, 0)
    mov x23, x17
    ldp q0, q1, [x23]               // load the tile, row by row
    ldp q2, q3, [x23, #32]
    add x23, x23, x3
    ldp q4, q5, [x23]
    ldp q6, q7, [x23, #32]
    add x23, x23, x3
    ldp q8, q9, [x23]
    ldp q10, q11, [x23, #32]
    add x23, x23, x3
    ldp q12, q13, [x23]
    ldp q14, q15, [x23, #32]
    mov x16, x21
    cbz x16, 2f
1:
    ldr q24, [x15]                  // M(r+k, q), M(r+k, q+1)
    ldr q25, [x15, x5]
    ldr q26, [x15, x19]
    ldr q27, [x15, x20]
    add x15, x15, #16
    ldp q16, q17, [x14]             // P(q, 8 columns)
    ldp q18, q19, [x14, #32]
    add x14, x14, x3
    ldp q20, q21, [x14]             // P(q+1, 8 columns)
    ldp q22, q23, [x14, #32]
    add x14, x14, x3
    RT_KI_STEP4 v16.2d, v17.2d, v18.2d, v19.2d, 0     // step q
    RT_KI_STEP4 v20.2d, v21.2d, v22.2d, v23.2d, 1     // step q+1
    subs x16, x16, #1
    b.ne 1b
2:
    cbz x22, 3f                     // odd nq: the last step alone
    ldr d24, [x15]
    ldr d25, [x15, x5]
    ldr d26, [x15, x19]
    ldr d27, [x15, x20]
    ldp q16, q17, [x14]
    ldp q18, q19, [x14, #32]
    RT_KI_STEP4 v16.2d, v17.2d, v18.2d, v19.2d, 0
3:
    mov x23, x17                    // store the tile
    stp q0, q1, [x23]
    stp q2, q3, [x23, #32]
    add x23, x23, x3
    stp q4, q5, [x23]
    stp q6, q7, [x23, #32]
    add x23, x23, x3
    stp q8, q9, [x23]
    stp q10, q11, [x23, #32]
    add x23, x23, x3
    stp q12, q13, [x23]
    stp q14, q15, [x23, #32]
    add x13, x13, #8
    b Lrt_ki_upd_s4
Lrt_ki_upd_t4:
    // ---- the last chunk-width % 8 columns of the 4 rows: 4 x 2 tiles,
    // then one 4 x 1 tile (scalar by-element products) ----
    sub x25, x9, x13                // columns left (0..7)
    cbz x25, 5f
    add x17, x10, x13, lsl #3       // &T(r, c+j)
    add x14, x8, x13
    add x14, x1, x14, lsl #3        // &P(0, c+j)
    mov x15, x11                    // &M(r, 0)
    cmp x25, #2
    b.lo 6f
    mov x23, x17                    // load the 4 x 2 tile
    ldr q0, [x23]
    add x23, x23, x3
    ldr q4, [x23]
    add x23, x23, x3
    ldr q8, [x23]
    add x23, x23, x3
    ldr q12, [x23]
    mov x16, x21
    cbz x16, 2f
1:
    ldr q24, [x15]                  // M(r+k, q), M(r+k, q+1)
    ldr q25, [x15, x5]
    ldr q26, [x15, x19]
    ldr q27, [x15, x20]
    add x15, x15, #16
    ldr q16, [x14]                  // P(q, 2 columns)
    add x14, x14, x3
    ldr q20, [x14]                  // P(q+1, 2 columns)
    add x14, x14, x3
    RT_KI_COL4 v0.2d, v4.2d, v8.2d, v12.2d, v16.2d, 0, v28.2d, v29.2d, v30.2d, v31.2d
    RT_KI_COL4 v0.2d, v4.2d, v8.2d, v12.2d, v20.2d, 1, v28.2d, v29.2d, v30.2d, v31.2d
    subs x16, x16, #1
    b.ne 1b
2:
    cbz x22, 3f
    ldr d24, [x15]
    ldr d25, [x15, x5]
    ldr d26, [x15, x19]
    ldr d27, [x15, x20]
    ldr q16, [x14]
    RT_KI_COL4 v0.2d, v4.2d, v8.2d, v12.2d, v16.2d, 0, v28.2d, v29.2d, v30.2d, v31.2d
3:
    mov x23, x17                    // store the 4 x 2 tile
    str q0, [x23]
    add x23, x23, x3
    str q4, [x23]
    add x23, x23, x3
    str q8, [x23]
    add x23, x23, x3
    str q12, [x23]
    add x13, x13, #2
    b Lrt_ki_upd_t4
6:
    mov x23, x17                    // the 4 x 1 tile (one column left)
    ldr d0, [x23]
    add x23, x23, x3
    ldr d4, [x23]
    add x23, x23, x3
    ldr d8, [x23]
    add x23, x23, x3
    ldr d12, [x23]
    mov x16, x21
    cbz x16, 2f
1:
    ldr q24, [x15]
    ldr q25, [x15, x5]
    ldr q26, [x15, x19]
    ldr q27, [x15, x20]
    add x15, x15, #16
    ldr d16, [x14]                  // P(q, 1 column)
    add x14, x14, x3
    ldr d20, [x14]                  // P(q+1, 1 column)
    add x14, x14, x3
    RT_KI_COL4 d0, d4, d8, d12, d16, 0, d28, d29, d30, d31
    RT_KI_COL4 d0, d4, d8, d12, d20, 1, d28, d29, d30, d31
    subs x16, x16, #1
    b.ne 1b
2:
    cbz x22, 3f
    ldr d24, [x15]
    ldr d25, [x15, x5]
    ldr d26, [x15, x19]
    ldr d27, [x15, x20]
    ldr d16, [x14]
    RT_KI_COL4 d0, d4, d8, d12, d16, 0, d28, d29, d30, d31
3:
    mov x23, x17
    str d0, [x23]
    add x23, x23, x3
    str d4, [x23]
    add x23, x23, x3
    str d8, [x23]
    add x23, x23, x3
    str d12, [x23]
5:
    add x10, x10, x3, lsl #2        // next 4 rows
    add x11, x11, x5, lsl #2
    sub x12, x12, #4
    b Lrt_ki_upd_rb4

Lrt_ki_upd_r1:
    cbz x12, Lrt_ki_upd_next
    mov x13, #0                     // j
Lrt_ki_upd_s16:
    add x14, x13, #16
    cmp x14, x9
    b.hi Lrt_ki_upd_s1              // fewer than 16 columns left
    // ---- 1 x 16 tile at T(r, c+j .. c+j+15): 8 accumulator chains,
    // enough to cover the fsub latency of a single row ----
    add x17, x10, x13, lsl #3       // &T(r, c+j)
    add x14, x8, x13
    add x14, x1, x14, lsl #3        // &P(0, c+j)
    mov x15, x11                    // &M(r, 0)
    ldp q0, q1, [x17]
    ldp q2, q3, [x17, #32]
    ldp q4, q5, [x17, #64]
    ldp q6, q7, [x17, #96]
    mov x16, x21
    cbz x16, 2f
1:
    ldr q24, [x15], #16             // M(r, q), M(r, q+1)
    ldp q16, q17, [x14]             // P(q, 16 columns)
    ldp q18, q19, [x14, #32]
    ldp q20, q21, [x14, #64]
    ldp q22, q23, [x14, #96]
    add x14, x14, x3
    ldp q8, q9, [x14]               // P(q+1, 16 columns)
    ldp q10, q11, [x14, #32]
    ldp q12, q13, [x14, #64]
    ldp q14, q15, [x14, #96]
    add x14, x14, x3
    RT_KI_ROW4 v0.2d, v1.2d, v2.2d, v3.2d, v16.2d, v17.2d, v18.2d, v19.2d, v24.d[0]
    RT_KI_ROW4 v4.2d, v5.2d, v6.2d, v7.2d, v20.2d, v21.2d, v22.2d, v23.2d, v24.d[0]
    RT_KI_ROW4 v0.2d, v1.2d, v2.2d, v3.2d, v8.2d, v9.2d, v10.2d, v11.2d, v24.d[1]
    RT_KI_ROW4 v4.2d, v5.2d, v6.2d, v7.2d, v12.2d, v13.2d, v14.2d, v15.2d, v24.d[1]
    subs x16, x16, #1
    b.ne 1b
2:
    cbz x22, 3f                     // odd nq: the last step alone
    ldr d24, [x15]
    ldp q16, q17, [x14]
    ldp q18, q19, [x14, #32]
    ldp q20, q21, [x14, #64]
    ldp q22, q23, [x14, #96]
    RT_KI_ROW4 v0.2d, v1.2d, v2.2d, v3.2d, v16.2d, v17.2d, v18.2d, v19.2d, v24.d[0]
    RT_KI_ROW4 v4.2d, v5.2d, v6.2d, v7.2d, v20.2d, v21.2d, v22.2d, v23.2d, v24.d[0]
3:
    stp q0, q1, [x17]
    stp q2, q3, [x17, #32]
    stp q4, q5, [x17, #64]
    stp q6, q7, [x17, #96]
    add x13, x13, #16
    b Lrt_ki_upd_s16
Lrt_ki_upd_s1:
    add x14, x13, #8
    cmp x14, x9
    b.hi Lrt_ki_upd_t1
    // ---- 1 x 8 tile at T(r, c+j .. c+j+7) ----
    add x17, x10, x13, lsl #3       // &T(r, c+j)
    add x14, x8, x13
    add x14, x1, x14, lsl #3        // &P(0, c+j)
    mov x15, x11                    // &M(r, 0)
    ldp q0, q1, [x17]
    ldp q2, q3, [x17, #32]
    mov x16, x21
    cbz x16, 2f
1:
    ldr q24, [x15], #16             // M(r, q), M(r, q+1)
    ldp q16, q17, [x14]
    ldp q18, q19, [x14, #32]
    add x14, x14, x3
    ldp q20, q21, [x14]
    ldp q22, q23, [x14, #32]
    add x14, x14, x3
    RT_KI_ROW4 v0.2d, v1.2d, v2.2d, v3.2d, v16.2d, v17.2d, v18.2d, v19.2d, v24.d[0]
    RT_KI_ROW4 v0.2d, v1.2d, v2.2d, v3.2d, v20.2d, v21.2d, v22.2d, v23.2d, v24.d[1]
    subs x16, x16, #1
    b.ne 1b
2:
    cbz x22, 3f
    ldr d24, [x15]
    ldp q16, q17, [x14]
    ldp q18, q19, [x14, #32]
    RT_KI_ROW4 v0.2d, v1.2d, v2.2d, v3.2d, v16.2d, v17.2d, v18.2d, v19.2d, v24.d[0]
3:
    stp q0, q1, [x17]
    stp q2, q3, [x17, #32]
    add x13, x13, #8
    b Lrt_ki_upd_s1
Lrt_ki_upd_t1:
    subs x25, x9, x13
    b.eq 5f
    add x17, x10, x13, lsl #3       // &T(r, c+j)
    mov x15, x11                    // &M(r, 0)
    add x14, x8, x13
    add x14, x1, x14, lsl #3        // &P(0, c+j)
    bl Lrt_ki_tail
5:
    add x10, x10, x3                // next row
    add x11, x11, x5
    sub x12, x12, #1
    b Lrt_ki_upd_r1

Lrt_ki_upd_next:
    add x8, x8, x9                  // next chunk
    cmp x8, x2
    b.lo Lrt_ki_upd_chunk
    ldp x27, x28, [sp, #80]
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
Lrt_ki_upd_ret:
    ret

// ---------------------------------------------------------------------
// Lrt_ki_tail -- one row, few columns, step by step (helper of
//   Lrt_ki_upd, called with its registers live; private convention):
//   for q = 0 .. nq-1: T(c) := T(c) - M(q) * P(q, c), c = 0 .. cnt-1
//   Inputs  : x17 = &T(0), x14 = &P(0, 0), x15 = &M(0), x25 = cnt
//             (>= 1), x6 = nq (>= 1), x3 = ld (bytes)
//   Outputs : none
//   Clobbers: x14-x16, x23, x24, x27, v16, v17, v24 (x23, x24, x27 are
//             scratch registers that Lrt_ki_upd saved for itself)
//   Callee-saved used: none beyond those
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .p2align 4
Lrt_ki_tail:
    mov x16, x6                     // steps
1:
    ldr d24, [x15], #8              // f = M(q)
    dup v24.2d, v24.d[0]
    mov x23, x14                    // P(q, 0)
    mov x24, x17                    // T(0)
    lsr x27, x25, #1                // pairs
    cbz x27, 3f
2:
    ldr q16, [x23], #16
    ldr q17, [x24]
    fmul v16.2d, v16.2d, v24.2d     // P*f, rounded
    fsub v17.2d, v17.2d, v16.2d     // T - P*f, rounded
    str q17, [x24], #16
    subs x27, x27, #1
    b.ne 2b
3:
    tbz x25, #0, 4f                 // odd count: one scalar
    ldr d16, [x23]
    ldr d17, [x24]
    fmul d16, d16, d24
    fsub d17, d17, d16
    str d17, [x24]
4:
    add x14, x14, x3                // next pivot row
    subs x16, x16, #1
    b.ne 1b
    ret

// ---------------------------------------------------------------------
// _bsk_kneon_inv -- X = inverse of A, LANGUAGE.md 7.14.6 exactly.
//   Inputs  : x0 = X view (n x n), x1 = A view (n x n, finite elements),
//             1 <= n <= RT_KERN_INV_MAXN; X and A do not overlap
//   Outputs : x0 = KS_OK, KS_SINGULAR (a pivot <= tol) or KS_NONFINITE
//             (a non-finite pivot or result element); X is only
//             meaningful for KS_OK
//   Clobbers: x1-x17, v0-v31 (d8-d15 restored)
//   Callee-saved used: x19 = X view, x20 = n, x21 = W base, x22 = W row
//             stride (bytes, 8n), x23 = X data, x24 = X row stride
//             (bytes), x25 = p0 (first pivot column of the panel), x26 =
//             pe (end of the panel), x27 = p (step / pivot row), x28 =
//             _bsk_rt_kinv_idx; d8-d15 saved because Lrt_ki_upd uses
//             all vector registers
//   Frame   : RT_KI_FRAME = 176 bytes: frame record, x19-x28, d8-d15,
//             tol at RT_KI_TOL; ends with a tail call to
//             _bsk_kneon_chkview after the epilogue
// Step registers: x8 = &W(p,p), x9 = &X(p,0), x10 = i, x11 = r,
//   x16 = &W(i,p); d16 = tol, d18 = best, d19/v19 = d, d21/v21 = f,
//   d22 = +inf; x0-x7 are the arguments of Lrt_ki_upd.
// ---------------------------------------------------------------------
    .private_extern _bsk_kneon_inv
    .p2align 2
_bsk_kneon_inv:
    stp x29, x30, [sp, #-RT_KI_FRAME]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    stp d8, d9, [sp, #96]
    stp d10, d11, [sp, #112]
    stp d12, d13, [sp, #128]
    stp d14, d15, [sp, #144]
    mov x19, x0                     // X view
    ldr x20, [x1, #MV_ROWS]         // n
    adrp x21, _bsk_rt_kinv_w@PAGE
    add x21, x21, _bsk_rt_kinv_w@PAGEOFF
    lsl x22, x20, #3                // W stride: n doubles
    ldr x23, [x0, #MV_DATA]
    ldr x24, [x0, #MV_LD]
    lsl x24, x24, #3
    adrp x28, _bsk_rt_kinv_idx@PAGE
    add x28, x28, _bsk_rt_kinv_idx@PAGEOFF
    ldr x7, [x1, #MV_DATA]          // A data
    ldr x8, [x1, #MV_LD]
    lsl x8, x8, #3                  // A stride (bytes)

    // ---- W := A, m := max |A(i,j)| (scalar; O(n^2)) ----
    movi d17, #0                    // m
    mov x10, #0                     // i
Lrt_ki_copy_row:
    madd x12, x10, x8, x7           // &A(i,0)
    madd x13, x10, x22, x21         // &W(i,0)
    mov x14, x20
Lrt_ki_copy_col:
    ldr d0, [x12], #8
    str d0, [x13], #8
    fabs d0, d0
    fmax d17, d17, d0               // inputs are finite: plain max
    subs x14, x14, #1
    b.ne Lrt_ki_copy_col
    add x10, x10, #1
    cmp x10, x20
    b.lo Lrt_ki_copy_row

    // ---- tol := (n * 2^-52) * m: the first product is exact ----
    ucvtf d16, x20
    mov x12, #RT_KI_TWO_M52
    fmov d0, x12
    fmul d16, d16, d0               // n * 2^-52 (exact)
    fmul d16, d16, d17              // one rounding
    str d16, [sp, #RT_KI_TOL]

    // ---- X := identity; column bookkeeping := identity ----
    mov x10, #0
Lrt_ki_idn_row:
    madd x12, x10, x24, x23         // &X(i,0)
    mov x14, x20
Lrt_ki_idn_col:
    str xzr, [x12], #8              // +0.0
    subs x14, x14, #1
    b.ne Lrt_ki_idn_col
    madd x12, x10, x24, x23
    fmov d0, #1.0
    str d0, [x12, x10, lsl #3]      // X(i,i) = 1
    str w10, [x28, x10, lsl #2]                     // unitpos[i] = i
    add x13, x28, #RT_KI_ROWOF
    str w10, [x13, x10, lsl #2]                     // rowof[i] = i
    add x13, x28, #RT_KI_COLOF
    str w10, [x13, x10, lsl #2]                     // colof[i] = i
    add x10, x10, #1
    cmp x10, x20
    b.lo Lrt_ki_idn_row

    // ---- elimination, panel by panel ----
    mov x25, #0                     // p0
Lrt_ki_panel:
    add x26, x25, #RT_KI_NB
    cmp x26, x20
    csel x26, x26, x20, lo          // pe = min(p0 + NB, n)
    mov x27, x25                    // p = p0
Lrt_ki_step:
    madd x8, x27, x22, x21
    add x8, x8, x27, lsl #3         // &W(p,p)
    // Pivot search over rows p..n-1 of column p (current: eager).
    ldr d18, [x8]
    fabs d18, d18                   // best = |W(p,p)|
    mov x11, x27                    // r = p
    add x10, x27, #1                // i
    add x16, x8, x22                // &W(i,p)
Lrt_ki_piv:
    cmp x10, x20
    b.hs Lrt_ki_piv_done
    ldr d0, [x16]
    fabs d0, d0
    fcmp d0, d18
    b.gt 1f                         // strictly larger (false for NaN)
    b 2f
1:
    fmov d18, d0                    // new best
    mov x11, x10                    // r = i
2:
    add x10, x10, #1
    add x16, x16, x22
    b Lrt_ki_piv
Lrt_ki_piv_done:
    ldr d16, [sp, #RT_KI_TOL]
    fcmp d18, d16
    b.ls Lrt_ki_singular            // best <= tol (false for NaN)
    madd x9, x27, x24, x23          // &X(p,0)
    cmp x11, x27
    b.eq Lrt_ki_noswap
    // Exchange rows p and r: W columns p0..n-1 (multipliers, panel,
    // trailing part with its pending updates), all of X, and the two
    // rows' unit-column records.
    madd x10, x27, x22, x21
    add x10, x10, x25, lsl #3       // &W(p,p0)
    madd x17, x11, x22, x21
    add x17, x17, x25, lsl #3       // &W(r,p0)
    sub x7, x20, x25                // n - p0 columns
    RT_KI_SWAP x10, x17, x7
    madd x17, x11, x24, x23         // &X(r,0)
    RT_KI_SWAP x9, x17, x20
    ldr w13, [x28, x27, lsl #2]     // a = unitpos[p]
    ldr w14, [x28, x11, lsl #2]     // b = unitpos[r]
    str w14, [x28, x27, lsl #2]     // unitpos[p] = b
    str w13, [x28, x11, lsl #2]     // unitpos[r] = a
    add x15, x28, #RT_KI_ROWOF
    str w27, [x15, x14, lsl #2]     // rowof[b] = p
    str w11, [x15, x13, lsl #2]     // rowof[a] = r
Lrt_ki_noswap:
    // Move row p's unit column to storage column p (see the header):
    // s = unitpos[p] >= p; the row q whose unit sits in storage column p
    // gets storage column s instead. Both columns are untouched (no
    // update of this panel has written storage columns >= p yet), so
    // only the two 1.0 entries move; colof records the exchange.
    ldr w13, [x28, x27, lsl #2]     // s
    cmp x13, x27
    b.eq Lrt_ki_placed
    add x15, x28, #RT_KI_ROWOF
    ldr w14, [x15, x27, lsl #2]     // q = rowof[p]
    madd x10, x14, x24, x23         // &X(q,0)
    fmov d0, #1.0
    str xzr, [x10, x27, lsl #3]     // X(q,p) = 0
    str d0, [x10, x13, lsl #3]      // X(q,s) = 1
    str xzr, [x9, x13, lsl #3]      // X(p,s) = 0
    str d0, [x9, x27, lsl #3]       // X(p,p) = 1
    str w13, [x28, x14, lsl #2]     // unitpos[q] = s
    str w27, [x28, x27, lsl #2]     // unitpos[p] = p
    str w14, [x15, x13, lsl #2]     // rowof[s] = q
    str w27, [x15, x27, lsl #2]     // rowof[p] = p
    add x15, x28, #RT_KI_COLOF
    ldr w10, [x15, x27, lsl #2]
    ldr w14, [x15, x13, lsl #2]
    str w14, [x15, x27, lsl #2]     // exchange colof[p], colof[s]
    str w10, [x15, x13, lsl #2]
Lrt_ki_placed:
    // Bring the pivot row's trailing part up to date: steps p0..p-1
    // (multipliers W(p, p0..p-1), pivot rows p0..p-1 as of their step).
    subs x6, x27, x25               // nq = p - p0
    b.eq Lrt_ki_caught
    madd x4, x27, x22, x21
    add x0, x4, x26, lsl #3         // &W(p,pe)
    add x4, x4, x25, lsl #3         // &W(p,p0)
    madd x1, x25, x22, x21
    add x1, x1, x26, lsl #3         // &W(p0,pe)
    sub x2, x20, x26                // n - pe columns
    mov x3, x22
    mov x5, x22
    mov x7, #1
    bl Lrt_ki_upd
    madd x0, x27, x24, x23          // &X(p,0)
    madd x1, x25, x24, x23          // &X(p0,0)
    mov x2, x27                     // storage columns 0..p-1
    mov x3, x24
    madd x4, x27, x22, x21
    add x4, x4, x25, lsl #3         // &W(p,p0)
    mov x5, x22
    sub x6, x27, x25
    mov x7, #1
    bl Lrt_ki_upd
Lrt_ki_caught:
    madd x8, x27, x22, x21
    add x8, x8, x27, lsl #3         // &W(p,p)
    madd x9, x27, x24, x23          // &X(p,0)
    // Pivot d must be finite.
    ldr d19, [x8]
    mov x12, #RT_KI_INF
    fmov d22, x12
    fabs d0, d19
    fcmp d0, d22
    b.mi 1f                         // |d| < inf (ordered)
    b Lrt_ki_nonfinite
1:
    dup v19.2d, v19.d[0]
    // Row p: W(p, p+1..n-1) /= d, X(p, 0..p) /= d.
    add x10, x8, #8
    sub x17, x20, x27
    sub x17, x17, #1                // n-1-p
    RT_KI_DIV x10, x17
    add x7, x27, #1                 // storage columns 0..p
    RT_KI_DIV x9, x7
    // Eager update of the panel columns p+1..pe-1 of every row i != p.
    sub x17, x26, x27
    subs x17, x17, #1               // pe-1-p columns
    b.eq Lrt_ki_step_next
    add x7, x8, #8                  // &W(p,p+1)
    mov x10, #0                     // i
    add x16, x21, x27, lsl #3       // &W(0,p)
Lrt_ki_elim:
    cmp x10, x27
    b.eq Lrt_ki_elim_next           // skip the pivot row
    ldr d21, [x16]                  // f = W(i,p)
    dup v21.2d, v21.d[0]
    add x11, x16, #8                // &W(i,p+1)
    RT_KI_AXPY x11, x7, x17
Lrt_ki_elim_next:
    add x10, x10, #1
    add x16, x16, x22
    cmp x10, x20
    b.lo Lrt_ki_elim
Lrt_ki_step_next:
    add x27, x27, #1
    cmp x27, x26
    b.lo Lrt_ki_step

    // ---- delayed update of the non-pivot rows: [0, p0), then [pe, n);
    // W columns pe..n-1 and X storage columns 0..pe-1, steps p0..pe-1 ----
    cbz x25, Lrt_ki_lower
    add x0, x21, x26, lsl #3        // &W(0,pe)
    madd x1, x25, x22, x21
    add x1, x1, x26, lsl #3         // &W(p0,pe)
    sub x2, x20, x26
    mov x3, x22
    add x4, x21, x25, lsl #3        // &W(0,p0)
    mov x5, x22
    sub x6, x26, x25                // nq = pe - p0
    mov x7, x25                     // rows 0..p0-1
    bl Lrt_ki_upd
    mov x0, x23                     // &X(0,0)
    madd x1, x25, x24, x23          // &X(p0,0)
    mov x2, x26                     // storage columns 0..pe-1
    mov x3, x24
    add x4, x21, x25, lsl #3        // &W(0,p0)
    mov x5, x22
    sub x6, x26, x25
    mov x7, x25
    bl Lrt_ki_upd
Lrt_ki_lower:
    subs x7, x20, x26               // rows pe..n-1
    b.eq Lrt_ki_post
    madd x4, x26, x22, x21          // &W(pe,0)
    add x0, x4, x26, lsl #3         // &W(pe,pe)
    add x4, x4, x25, lsl #3         // &W(pe,p0)
    madd x1, x25, x22, x21
    add x1, x1, x26, lsl #3         // &W(p0,pe)
    sub x2, x20, x26
    mov x3, x22
    mov x5, x22
    sub x6, x26, x25
    bl Lrt_ki_upd
    madd x0, x26, x24, x23          // &X(pe,0)
    madd x1, x25, x24, x23          // &X(p0,0)
    mov x2, x26
    mov x3, x24
    madd x4, x26, x22, x21
    add x4, x4, x25, lsl #3         // &W(pe,p0)
    mov x5, x22
    sub x6, x26, x25
    sub x7, x20, x26
    bl Lrt_ki_upd
Lrt_ki_post:
    // ---- the panel's pivot rows, increasing i: steps i+1..pe-1 ----
    mov x27, x25                    // i = p0
Lrt_ki_prow:
    sub x6, x26, x27
    subs x6, x6, #1                 // nq = pe-1-i
    b.eq Lrt_ki_panel_next          // i = pe-1: nothing left
    madd x4, x27, x22, x21          // &W(i,0)
    add x0, x4, x26, lsl #3         // &W(i,pe)
    add x1, x0, x22                 // &W(i+1,pe)
    add x4, x4, x27, lsl #3
    add x4, x4, #8                  // &W(i,i+1)
    sub x2, x20, x26
    mov x3, x22
    mov x5, x22
    mov x7, #1
    bl Lrt_ki_upd
    madd x0, x27, x24, x23          // &X(i,0)
    add x1, x0, x24                 // &X(i+1,0)
    mov x2, x26
    mov x3, x24
    madd x4, x27, x22, x21
    add x4, x4, x27, lsl #3
    add x4, x4, #8                  // &W(i,i+1)
    mov x5, x22
    sub x6, x26, x27
    sub x6, x6, #1
    mov x7, #1
    bl Lrt_ki_upd
    add x27, x27, #1
    b Lrt_ki_prow
Lrt_ki_panel_next:
    mov x25, x26                    // next panel
    cmp x25, x20
    b.lo Lrt_ki_panel

    // ---- undo the column order: X(i, colof[s]) := stored X(i, s) ----
    // Each row is first copied to W's row 0 (W is no longer needed).
    add x15, x28, #RT_KI_COLOF
    mov x10, #0
Lrt_ki_perm_row:
    madd x11, x10, x24, x23         // &X(i,0)
    mov x12, #0
1:
    ldr x13, [x11, x12, lsl #3]     // exact bits
    str x13, [x21, x12, lsl #3]
    add x12, x12, #1
    cmp x12, x20
    b.lo 1b
    mov x12, #0
2:
    ldr x13, [x21, x12, lsl #3]
    ldr w14, [x15, x12, lsl #2]     // original column of storage column s
    str x13, [x11, x14, lsl #3]
    add x12, x12, #1
    cmp x12, x20
    b.lo 2b
    add x10, x10, #1
    cmp x10, x20
    b.lo Lrt_ki_perm_row

    // ---- result: finite test of X, tail call after the epilogue ----
    mov x0, x19
    RT_KI_EPILOGUE
    b _bsk_kneon_chkview

Lrt_ki_singular:
    mov x0, #KS_SINGULAR
    b Lrt_ki_ret
Lrt_ki_nonfinite:
    mov x0, #KS_NONFINITE
Lrt_ki_ret:
    RT_KI_EPILOGUE
    ret

// Workspace W: RT_KERN_INV_MAXN^2 doubles (8 MiB), 64-byte aligned
// (DESIGN.md 6.6.6); pages never touched cost nothing.
.zerofill __DATA,__bss,_bsk_rt_kinv_w,RT_KERN_INV_MAXN*RT_KERN_INV_MAXN*8,6
// Column bookkeeping, three u32 arrays of RT_KERN_INV_MAXN entries:
// unitpos (row -> storage column of its unit), rowof (storage column ->
// row whose unit is there), colof (storage column -> original column).
.zerofill __DATA,__bss,_bsk_rt_kinv_idx,RT_KERN_INV_MAXN*4*3,6
