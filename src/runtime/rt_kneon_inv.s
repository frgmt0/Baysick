// =====================================================================
// src/runtime/rt_kneon_inv.s -- `neon` matrix inverse: the pinned
// Gauss-Jordan elimination of LANGUAGE.md 7.14.6 (DESIGN.md 6.6.1,
// 6.6.5; determinism class E: bit-identical on every target/variant).
//
// Defines (runtime-private, .private_extern):
//   _bsk_kneon_inv (x0 X, x1 A) -> x0 KS_*     X = inverse of A (n x n)
//
// Algorithm (W = working copy of A in the static workspace, LD = n;
// X starts as the identity):
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
// (fdiv), and fmul then fsub (never fmla/fmls); the vector forms (.2d)
// compute each lane exactly as the scalar form would.
//
// Skipped zero updates (allowed by LANGUAGE.md 7.14.6: "an implementation
// may skip any update whose product f*y is zero"): a column of X is
// "untouched" until the row holding its 1.0 becomes a pivot row; before
// that every other entry of it is exactly +0 and row operations only add
// multiples of +0 to it. X is kept with its columns in a private storage
// order in which the touched columns are 0..p at step p: when row p
// becomes the pivot row, its unit column is exchanged with storage column
// p (only the two 1.0 entries move, both columns being untouched). Step p
// then divides and updates only storage columns 0..p of X, skipping
// exactly the products f * (+0) (when f is finite; a non-finite f makes
// some touched element of X non-finite in both forms, so the status is
// KS_NONFINITE either way). At the end each row of X is permuted back
// to the original column order (colof). This halves the X work; the
// values are those of the full algorithm up to the sign of zeros.
// Comparisons: "|W(i,p)| > best" uses b.gt and "best <= tol" uses b.ls,
// both false when an operand is NaN, as the pseudo-code reads; the pivot
// test "d is +-inf or NaN" is "not (|d| < inf)" (b.mi = ordered less).
//
// Columns 0..p of W are never read after step p, so the row exchange
// and the W updates only touch columns p..n-1 / p+1..n-1.
//
// Link isolation (DESIGN.md 6.6.1): references only rt_kneon_elem.s.
// =====================================================================
.include "baysick.inc"

.equ RT_KI_TWO_M52, 0x3CB0000000000000 // 2^-52 as IEEE double bits
.equ RT_KI_INF,     0x7FF0000000000000 // +infinity
.equ RT_KI_ROWOF,   RT_KERN_INV_MAXN * 4     // offsets in _bsk_rt_kinv_idx
.equ RT_KI_COLOF,   RT_KERN_INV_MAXN * 8

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
// Uses x12-x15, v0-v3.
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

// ---------------------------------------------------------------------
// _bsk_kneon_inv -- X = inverse of A, LANGUAGE.md 7.14.6 exactly.
//   Inputs  : x0 = X view (n x n), x1 = A view (n x n, finite elements),
//             n <= RT_KERN_INV_MAXN; X and A do not overlap
//   Outputs : x0 = KS_OK, KS_SINGULAR (a pivot <= tol) or KS_NONFINITE
//             (a non-finite pivot or result element); X is only
//             meaningful for KS_OK
//   Clobbers: x1-x17, v0-v7, v16-v25
//   Callee-saved used: none
//   Frame   : none (leaf; ends with a tail call to _bsk_kneon_chkview)
// Registers:
//   x0 = X view, x2 = n, x3 = W base, x4 = W row stride (bytes),
//   x5 = X data, x6 = X row stride (bytes), x7 = p, x8 = &W(p,p),
//   x9 = &X(p,0), x10 = i, x11 = r / &X(i,0), x16 = &W(i,p),
//   x17 = n-1-p (W columns right of p), x1 = p+1 (X storage columns in
//   use); x12-x15 scratch; column bookkeeping in _bsk_rt_kinv_idx.
//   d16 = tol, d18 = best, d19/v19 = d, d21/v21 = f, d22 = +inf.
// ---------------------------------------------------------------------
    .private_extern _bsk_kneon_inv
    .p2align 2
_bsk_kneon_inv:
    ldr x2, [x1, #MV_ROWS]          // n
    adrp x3, _bsk_rt_kinv_w@PAGE
    add x3, x3, _bsk_rt_kinv_w@PAGEOFF
    lsl x4, x2, #3                  // W stride: n doubles
    ldr x5, [x0, #MV_DATA]
    ldr x6, [x0, #MV_LD]
    lsl x6, x6, #3
    ldr x7, [x1, #MV_DATA]          // A data (first phase only)
    ldr x8, [x1, #MV_LD]
    lsl x8, x8, #3

    // ---- W := A, m := max |A(i,j)| (scalar; O(n^2)) ----
    movi d17, #0                    // m
    mov x10, #0                     // i
Lrt_ki_copy_row:
    madd x12, x10, x8, x7           // &A(i,0)
    madd x13, x10, x4, x3           // &W(i,0)
    mov x14, x2
Lrt_ki_copy_col:
    ldr d0, [x12], #8
    str d0, [x13], #8
    fabs d0, d0
    fmax d17, d17, d0               // inputs are finite: plain max
    subs x14, x14, #1
    b.ne Lrt_ki_copy_col
    add x10, x10, #1
    cmp x10, x2
    b.lo Lrt_ki_copy_row

    // ---- tol := (n * 2^-52) * m: the first product is exact ----
    ucvtf d16, x2
    mov x12, #RT_KI_TWO_M52
    fmov d0, x12
    fmul d16, d16, d0               // n * 2^-52 (exact)
    fmul d16, d16, d17              // one rounding
    mov x12, #RT_KI_INF
    fmov d22, x12

    // ---- X := identity; column bookkeeping := identity ----
    adrp x15, _bsk_rt_kinv_idx@PAGE
    add x15, x15, _bsk_rt_kinv_idx@PAGEOFF
    mov x10, #0
Lrt_ki_idn_row:
    madd x12, x10, x6, x5           // &X(i,0)
    mov x14, x2
Lrt_ki_idn_col:
    str xzr, [x12], #8              // +0.0
    subs x14, x14, #1
    b.ne Lrt_ki_idn_col
    madd x12, x10, x6, x5
    fmov d0, #1.0
    str d0, [x12, x10, lsl #3]      // X(i,i) = 1
    str w10, [x15, x10, lsl #2]                     // unitpos[i] = i
    add x13, x15, #RT_KI_ROWOF
    str w10, [x13, x10, lsl #2]                     // rowof[i] = i
    add x13, x15, #RT_KI_COLOF
    str w10, [x13, x10, lsl #2]                     // colof[i] = i
    add x10, x10, #1
    cmp x10, x2
    b.lo Lrt_ki_idn_row

    // ---- elimination ----
    mov x7, #0                      // p
Lrt_ki_step:
    madd x8, x7, x4, x3
    add x8, x8, x7, lsl #3          // &W(p,p)
    // Pivot search over rows p..n-1 of column p.
    ldr d18, [x8]
    fabs d18, d18                   // best = |W(p,p)|
    mov x11, x7                     // r = p
    add x10, x7, #1                 // i
    add x16, x8, x4                 // &W(i,p)
Lrt_ki_piv:
    cmp x10, x2
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
    add x16, x16, x4
    b Lrt_ki_piv
Lrt_ki_piv_done:
    fcmp d18, d16
    b.ls Lrt_ki_singular            // best <= tol (false for NaN)
    sub x17, x2, x7                 // n - p
    madd x9, x7, x6, x5             // &X(p,0)
    cmp x11, x7
    b.eq Lrt_ki_noswap
    // Exchange rows p and r: W columns p..n-1, X all columns, and the
    // two rows' unit-column records.
    madd x10, x11, x4, x3
    add x10, x10, x7, lsl #3        // &W(r,p)
    RT_KI_SWAP x8, x10, x17
    madd x10, x11, x6, x5           // &X(r,0)
    RT_KI_SWAP x9, x10, x2
    adrp x12, _bsk_rt_kinv_idx@PAGE
    add x12, x12, _bsk_rt_kinv_idx@PAGEOFF
    ldr w13, [x12, x7, lsl #2]      // a = unitpos[p]
    ldr w14, [x12, x11, lsl #2]     // b = unitpos[r]
    str w14, [x12, x7, lsl #2]      // unitpos[p] = b
    str w13, [x12, x11, lsl #2]     // unitpos[r] = a
    add x15, x12, #RT_KI_ROWOF
    str w7, [x15, x14, lsl #2]      // rowof[b] = p
    str w11, [x15, x13, lsl #2]     // rowof[a] = r
Lrt_ki_noswap:
    sub x17, x17, #1                // n-1-p columns right of p
    // Pivot d must be finite.
    ldr d19, [x8]
    fabs d0, d19
    fcmp d0, d22
    b.mi 1f                         // |d| < inf (ordered)
    b Lrt_ki_nonfinite
1:
    // Move row p's unit column to storage column p (see the header):
    // s = unitpos[p] >= p; the row q whose unit sits in storage column p
    // gets storage column s instead. Both columns are untouched, so only
    // the two 1.0 entries move; colof records the exchange.
    adrp x12, _bsk_rt_kinv_idx@PAGE
    add x12, x12, _bsk_rt_kinv_idx@PAGEOFF
    ldr w13, [x12, x7, lsl #2]      // s
    cmp x13, x7
    b.eq Lrt_ki_placed
    add x15, x12, #RT_KI_ROWOF
    ldr w14, [x15, x7, lsl #2]      // q = rowof[p]
    madd x10, x14, x6, x5           // &X(q,0)
    fmov d0, #1.0
    str xzr, [x10, x7, lsl #3]      // X(q,p) = 0
    str d0, [x10, x13, lsl #3]      // X(q,s) = 1
    str xzr, [x9, x13, lsl #3]      // X(p,s) = 0
    str d0, [x9, x7, lsl #3]        // X(p,p) = 1
    str w13, [x12, x14, lsl #2]     // unitpos[q] = s
    str w7, [x12, x7, lsl #2]       // unitpos[p] = p
    str w14, [x15, x13, lsl #2]     // rowof[s] = q
    str w7, [x15, x7, lsl #2]       // rowof[p] = p
    add x15, x12, #RT_KI_COLOF
    ldr w10, [x15, x7, lsl #2]
    ldr w14, [x15, x13, lsl #2]
    str w14, [x15, x7, lsl #2]      // exchange colof[p], colof[s]
    str w10, [x15, x13, lsl #2]
Lrt_ki_placed:
    add x1, x7, #1                  // X storage columns in use: 0..p
    dup v19.2d, v19.d[0]
    // Row p: W(p, p+1..n-1) /= d, X(p, 0..p) /= d.
    add x10, x8, #8
    RT_KI_DIV x10, x17
    RT_KI_DIV x9, x1
    // Every other row i: subtract f times row p.
    mov x10, #0                     // i
    add x16, x3, x7, lsl #3         // &W(0,p)
    mov x11, x5                     // &X(0,0)
Lrt_ki_row:
    cmp x10, x7
    b.eq Lrt_ki_row_next            // skip the pivot row
    ldr d21, [x16]                  // f = W(i,p)
    dup v21.2d, v21.d[0]
    add x13, x8, #8                 // &W(p,p+1)
    add x12, x16, #8                // &W(i,p+1)
    RT_KI_AXPY x12, x13, x17
    RT_KI_AXPY x11, x9, x1
Lrt_ki_row_next:
    add x10, x10, #1
    add x16, x16, x4
    add x11, x11, x6
    cmp x10, x2
    b.lo Lrt_ki_row
    add x7, x7, #1
    cmp x7, x2
    b.lo Lrt_ki_step

    // ---- undo the column order: X(i, colof[s]) := stored X(i, s) ----
    // Each row is first copied to W's row 0 (W is no longer needed).
    adrp x15, _bsk_rt_kinv_idx@PAGE
    add x15, x15, _bsk_rt_kinv_idx@PAGEOFF
    add x15, x15, #RT_KI_COLOF
    mov x10, #0
Lrt_ki_perm_row:
    madd x11, x10, x6, x5           // &X(i,0)
    mov x12, #0
1:
    ldr x13, [x11, x12, lsl #3]     // exact bits
    str x13, [x3, x12, lsl #3]
    add x12, x12, #1
    cmp x12, x2
    b.lo 1b
    mov x12, #0
2:
    ldr x13, [x3, x12, lsl #3]
    ldr w14, [x15, x12, lsl #2]     // original column of storage column s
    str x13, [x11, x14, lsl #3]
    add x12, x12, #1
    cmp x12, x2
    b.lo 2b
    add x10, x10, #1
    cmp x10, x2
    b.lo Lrt_ki_perm_row

    // ---- result: finite test of X (x0 still holds the X view) ----
    b _bsk_kneon_chkview

Lrt_ki_singular:
    mov x0, #KS_SINGULAR
    ret
Lrt_ki_nonfinite:
    mov x0, #KS_NONFINITE
    ret

// Workspace W: RT_KERN_INV_MAXN^2 doubles (8 MiB), 64-byte aligned
// (DESIGN.md 6.6.6); pages never touched cost nothing.
.zerofill __DATA,__bss,_bsk_rt_kinv_w,RT_KERN_INV_MAXN*RT_KERN_INV_MAXN*8,6
// Column bookkeeping, three u32 arrays of RT_KERN_INV_MAXN entries:
// unitpos (row -> storage column of its unit), rowof (storage column ->
// row whose unit is there), colof (storage column -> original column).
.zerofill __DATA,__bss,_bsk_rt_kinv_idx,RT_KERN_INV_MAXN*4*3,6
