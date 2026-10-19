// =====================================================================
// src/runtime/rt_kneon_elem.s -- `neon` element-wise matrix kernels
// (DESIGN.md 6.6.1, 6.6.5; determinism class E, 6.6.4).
//
// Defines (runtime-private, .private_extern; reached through the KV_*
// table in rt_kinit.s, or called directly by the other neon kernels):
//   _bsk_kneon_add     (x0 C, x1 A, x2 B) -> x0 KS_*     C = A + B
//   _bsk_kneon_sub     (x0 C, x1 A, x2 B) -> x0 KS_*     C = A - B
//   _bsk_kneon_scale   (x0 C, x1 A, d0 k) -> x0 KS_*     C = k * A
//   _bsk_kneon_copy    (x0 C, x1 A)                      C = A
//   _bsk_kneon_fill    (x0 C, d0 v)                      C(i,j) = v
//   _bsk_kneon_chkview (x0 C) -> x0 KS_*                 finite test of C
//
// Every argument is an MV_* view (runtime.inc). Results are one IEEE
// operation per element (add/sub/scale) or exact copies (copy/fill), so
// the vector width never changes a bit of the result. C may be exactly A
// (or B) for add/sub/scale: each vector is loaded before it is stored.
//
// Structure: a row loop around a contiguous inner loop of 8 vectors
// (16 doubles) per iteration, then one block of 4 vectors, then single
// vectors, then one scalar. When every view is contiguous (MV_LD =
// MV_COLS, or a single row) the matrix is processed as one row of
// rows*cols elements.
//
// Finite check (fused): for each result vector r, acc := acc + r*0 with
// fmla. r*0 is +-0 for a finite r and NaN for +-inf or NaN, and NaN
// propagates through the sum, so acc is NaN exactly when some stored
// element is not finite. Eight vector accumulators (v16..v23) plus a
// scalar one (d25) keep every fmla chain at one link per 16 doubles, so
// the check never limits the loop. The fmla only feeds the check; it
// never touches a stored result. v24 holds the zero multiplier.
//
// Link isolation (DESIGN.md 6.6.1): references no other runtime file.
// =====================================================================
.include "baysick.inc"

    .section __TEXT,__text,regular,pure_instructions

// RT_KE_INIT: check accumulators v16..v23, d25 := 0; v24 := 0.
.macro RT_KE_INIT
    movi v16.2d, #0
    movi v17.2d, #0
    movi v18.2d, #0
    movi v19.2d, #0
    movi v20.2d, #0
    movi v21.2d, #0
    movi v22.2d, #0
    movi v23.2d, #0
    movi v24.2d, #0
    movi v25.2d, #0
.endm

// RT_KE_FOLD: x0 := KS_OK if every accumulator is finite (zero), else
// KS_NONFINITE. Clobbers v16, v18, v20, v22, d16.
.macro RT_KE_FOLD
    fadd v16.2d, v16.2d, v17.2d
    fadd v18.2d, v18.2d, v19.2d
    fadd v20.2d, v20.2d, v21.2d
    fadd v22.2d, v22.2d, v23.2d
    fadd v16.2d, v16.2d, v18.2d
    fadd v20.2d, v20.2d, v22.2d
    fadd v16.2d, v16.2d, v20.2d
    faddp d16, v16.2d               // both lanes
    fadd d16, d16, d25              // plus the scalar tail accumulator
    fcmp d16, d16                   // unordered iff NaN
    cset x0, vs                     // 1 = KS_NONFINITE, 0 = KS_OK
.endm

// RT_KE_CHK4 a0, a1, a2, a3: fold result vectors v0..v3 into the four
// given check accumulators.
.macro RT_KE_CHK4 a0, a1, a2, a3
    fmla v\a0\().2d, v0.2d, v24.2d
    fmla v\a1\().2d, v1.2d, v24.2d
    fmla v\a2\().2d, v2.2d, v24.2d
    fmla v\a3\().2d, v3.2d, v24.2d
.endm

// RT_KE_CONTIG3 / RT_KE_CONTIG2 / RT_KE_CONTIG1: collapse to one long
// row (x3 = 1, x4 = rows*cols) when the views with strides in the named
// registers are all contiguous (stride = cols) or there is one row.
.macro RT_KE_CONTIG3 s0, s1, s2
    cmp x3, #1
    b.eq 1f
    cmp \s0, x4
    ccmp \s1, x4, #0, eq
    ccmp \s2, x4, #0, eq
    b.ne 1f
    mul x4, x4, x3
    mov x3, #1
1:
.endm
.macro RT_KE_CONTIG2 s0, s1
    cmp x3, #1
    b.eq 1f
    cmp \s0, x4
    ccmp \s1, x4, #0, eq
    b.ne 1f
    mul x4, x4, x3
    mov x3, #1
1:
.endm
.macro RT_KE_CONTIG1 s0
    cmp x3, #1
    b.eq 1f
    cmp \s0, x4
    b.ne 1f
    mul x4, x4, x3
    mov x3, #1
1:
.endm

// ---------------------------------------------------------------------
// RT_KE_BINOP name, op -- generate C = A op B (op = fadd or fsub).
//   Inputs  : x0 = C view, x1 = A view, x2 = B view
//   Outputs : x0 = KS_OK or KS_NONFINITE
//   Clobbers: x1-x15, v0-v7, v16-v25
//   Callee-saved used: none
//   Frame   : none (leaf)
// Registers: x3 rows, x4 cols, x5/x6/x7 row strides of C/A/B (bytes),
// x8/x9/x10 row starts of C/A/B, x11/x15 counts, x12/x13/x14 cursors.
// ---------------------------------------------------------------------
.macro RT_KE_BODY4 op
    ldp q0, q1, [x13], #32          // A
    ldp q4, q5, [x14], #32          // B
    ldp q2, q3, [x13], #32
    ldp q6, q7, [x14], #32
    \op v0.2d, v0.2d, v4.2d         // one IEEE operation per element
    \op v1.2d, v1.2d, v5.2d
    \op v2.2d, v2.2d, v6.2d
    \op v3.2d, v3.2d, v7.2d
    stp q0, q1, [x12], #32
    stp q2, q3, [x12], #32
.endm

.macro RT_KE_BINOP name, op
    .private_extern \name
    .p2align 2
\name:
    ldr x3, [x1, #MV_ROWS]
    ldr x4, [x1, #MV_COLS]
    ldr x8, [x0, #MV_DATA]
    ldr x9, [x1, #MV_DATA]
    ldr x10, [x2, #MV_DATA]
    ldr x5, [x0, #MV_LD]
    ldr x6, [x1, #MV_LD]
    ldr x7, [x2, #MV_LD]
    RT_KE_INIT
    RT_KE_CONTIG3 x5, x6, x7
    lsl x5, x5, #3                  // strides in bytes
    lsl x6, x6, #3
    lsl x7, x7, #3
L\name\()_row:
    mov x12, x8                     // cursors at the row starts
    mov x13, x9
    mov x14, x10
    lsr x11, x4, #4                 // blocks of 16 doubles
    cbz x11, L\name\()_eight
L\name\()_sixteen:
    RT_KE_BODY4 \op
    RT_KE_CHK4 16, 17, 18, 19
    RT_KE_BODY4 \op
    RT_KE_CHK4 20, 21, 22, 23
    subs x11, x11, #1
    b.ne L\name\()_sixteen
L\name\()_eight:
    tbz x4, #3, L\name\()_two       // a block of 8 left?
    RT_KE_BODY4 \op
    RT_KE_CHK4 16, 17, 18, 19
L\name\()_two:
    ubfx x15, x4, #1, #2            // pairs left (0..3)
    cbz x15, L\name\()_one
L\name\()_twoloop:
    ldr q0, [x13], #16
    ldr q4, [x14], #16
    \op v0.2d, v0.2d, v4.2d
    str q0, [x12], #16
    fmla v16.2d, v0.2d, v24.2d
    subs x15, x15, #1
    b.ne L\name\()_twoloop
L\name\()_one:
    tbz x4, #0, L\name\()_next      // even row length: no scalar
    ldr d0, [x13]
    ldr d4, [x14]
    \op d0, d0, d4
    str d0, [x12]
    fmadd d25, d0, d24, d25         // scalar check accumulator
L\name\()_next:
    add x8, x8, x5                  // next row of each view
    add x9, x9, x6
    add x10, x10, x7
    subs x3, x3, #1
    b.ne L\name\()_row
    RT_KE_FOLD
    ret
.endm

    RT_KE_BINOP _bsk_kneon_add, fadd
    RT_KE_BINOP _bsk_kneon_sub, fsub

// ---------------------------------------------------------------------
// _bsk_kneon_scale -- C = k * A, one multiplication per element.
//   Inputs  : x0 = C view, x1 = A view, d0 = k
//   Outputs : x0 = KS_OK or KS_NONFINITE
//   Clobbers: x2-x15, v0-v3, v16-v26
//   Callee-saved used: none
//   Frame   : none (leaf)
// Registers: x3 rows, x4 cols, x5/x6 strides of C/A (bytes), x8/x9 row
// starts, x11/x15 counts, x12/x13 cursors, v26 = (k, k).
// ---------------------------------------------------------------------
.macro RT_KE_SBODY4
    ldp q0, q1, [x13], #32
    ldp q2, q3, [x13], #32
    fmul v0.2d, v0.2d, v26.2d       // a*k (IEEE multiplication commutes)
    fmul v1.2d, v1.2d, v26.2d
    fmul v2.2d, v2.2d, v26.2d
    fmul v3.2d, v3.2d, v26.2d
    stp q0, q1, [x12], #32
    stp q2, q3, [x12], #32
.endm

    .private_extern _bsk_kneon_scale
    .p2align 2
_bsk_kneon_scale:
    dup v26.2d, v0.d[0]             // k in both lanes
    ldr x3, [x1, #MV_ROWS]
    ldr x4, [x1, #MV_COLS]
    ldr x8, [x0, #MV_DATA]
    ldr x9, [x1, #MV_DATA]
    ldr x5, [x0, #MV_LD]
    ldr x6, [x1, #MV_LD]
    RT_KE_INIT
    RT_KE_CONTIG2 x5, x6
    lsl x5, x5, #3
    lsl x6, x6, #3
Lrt_kne_scale_row:
    mov x12, x8
    mov x13, x9
    lsr x11, x4, #4
    cbz x11, Lrt_kne_scale_eight
Lrt_kne_scale_sixteen:
    RT_KE_SBODY4
    RT_KE_CHK4 16, 17, 18, 19
    RT_KE_SBODY4
    RT_KE_CHK4 20, 21, 22, 23
    subs x11, x11, #1
    b.ne Lrt_kne_scale_sixteen
Lrt_kne_scale_eight:
    tbz x4, #3, Lrt_kne_scale_two
    RT_KE_SBODY4
    RT_KE_CHK4 16, 17, 18, 19
Lrt_kne_scale_two:
    ubfx x15, x4, #1, #2
    cbz x15, Lrt_kne_scale_one
Lrt_kne_scale_twoloop:
    ldr q0, [x13], #16
    fmul v0.2d, v0.2d, v26.2d
    str q0, [x12], #16
    fmla v16.2d, v0.2d, v24.2d
    subs x15, x15, #1
    b.ne Lrt_kne_scale_twoloop
Lrt_kne_scale_one:
    tbz x4, #0, Lrt_kne_scale_next
    ldr d0, [x13]
    fmul d0, d0, d26
    str d0, [x12]
    fmadd d25, d0, d24, d25
Lrt_kne_scale_next:
    add x8, x8, x5
    add x9, x9, x6
    subs x3, x3, #1
    b.ne Lrt_kne_scale_row
    RT_KE_FOLD
    ret

// ---------------------------------------------------------------------
// _bsk_kneon_copy -- C = A, exact bit copies.
//   Inputs  : x0 = C view, x1 = A view (same shape, no overlap)
//   Outputs : none
//   Clobbers: x3-x15, v0-v3
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .private_extern _bsk_kneon_copy
    .p2align 2
_bsk_kneon_copy:
    ldr x3, [x1, #MV_ROWS]
    ldr x4, [x1, #MV_COLS]
    ldr x8, [x0, #MV_DATA]
    ldr x9, [x1, #MV_DATA]
    ldr x5, [x0, #MV_LD]
    ldr x6, [x1, #MV_LD]
    RT_KE_CONTIG2 x5, x6
    lsl x5, x5, #3
    lsl x6, x6, #3
Lrt_kne_copy_row:
    mov x12, x8
    mov x13, x9
    lsr x11, x4, #3
    cbz x11, Lrt_kne_copy_two
Lrt_kne_copy_eight:
    ldp q0, q1, [x13], #32          // 64 bytes per iteration
    ldp q2, q3, [x13], #32
    stp q0, q1, [x12], #32
    stp q2, q3, [x12], #32
    subs x11, x11, #1
    b.ne Lrt_kne_copy_eight
Lrt_kne_copy_two:
    ubfx x15, x4, #1, #2
    cbz x15, Lrt_kne_copy_one
Lrt_kne_copy_twoloop:
    ldr q0, [x13], #16
    str q0, [x12], #16
    subs x15, x15, #1
    b.ne Lrt_kne_copy_twoloop
Lrt_kne_copy_one:
    tbz x4, #0, Lrt_kne_copy_next
    ldr x15, [x13]                  // integer move: exact bits
    str x15, [x12]
Lrt_kne_copy_next:
    add x8, x8, x5
    add x9, x9, x6
    subs x3, x3, #1
    b.ne Lrt_kne_copy_row
    ret

// ---------------------------------------------------------------------
// _bsk_kneon_fill -- every element of C := v.
//   Inputs  : x0 = C view, d0 = v
//   Outputs : none
//   Clobbers: x3-x15, v0
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .private_extern _bsk_kneon_fill
    .p2align 2
_bsk_kneon_fill:
    dup v0.2d, v0.d[0]              // v in both lanes
    ldr x3, [x0, #MV_ROWS]
    ldr x4, [x0, #MV_COLS]
    ldr x8, [x0, #MV_DATA]
    ldr x5, [x0, #MV_LD]
    RT_KE_CONTIG1 x5
    lsl x5, x5, #3
Lrt_kne_fill_row:
    mov x12, x8
    lsr x11, x4, #3
    cbz x11, Lrt_kne_fill_two
Lrt_kne_fill_eight:
    stp q0, q0, [x12], #32
    stp q0, q0, [x12], #32
    subs x11, x11, #1
    b.ne Lrt_kne_fill_eight
Lrt_kne_fill_two:
    ubfx x15, x4, #1, #2
    cbz x15, Lrt_kne_fill_one
Lrt_kne_fill_twoloop:
    str q0, [x12], #16
    subs x15, x15, #1
    b.ne Lrt_kne_fill_twoloop
Lrt_kne_fill_one:
    tbz x4, #0, Lrt_kne_fill_next
    str d0, [x12]
Lrt_kne_fill_next:
    add x8, x8, x5
    subs x3, x3, #1
    b.ne Lrt_kne_fill_row
    ret

// ---------------------------------------------------------------------
// _bsk_kneon_chkview -- are all elements of C finite?
//   Purpose : the separate vectorised finite pass used by the GEMM and
//             INV kernels (DESIGN.md 6.6.1).
//   Inputs  : x0 = C view
//   Outputs : x0 = KS_OK if every element is finite, else KS_NONFINITE
//   Clobbers: x3-x15, v0-v3, v16-v25
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .private_extern _bsk_kneon_chkview
    .p2align 2
_bsk_kneon_chkview:
    ldr x3, [x0, #MV_ROWS]
    ldr x4, [x0, #MV_COLS]
    ldr x8, [x0, #MV_DATA]
    ldr x5, [x0, #MV_LD]
    RT_KE_INIT
    RT_KE_CONTIG1 x5
    lsl x5, x5, #3
Lrt_kne_chk_row:
    mov x12, x8
    lsr x11, x4, #4
    cbz x11, Lrt_kne_chk_eight
Lrt_kne_chk_sixteen:
    ldp q0, q1, [x12], #32
    ldp q2, q3, [x12], #32
    RT_KE_CHK4 16, 17, 18, 19
    ldp q0, q1, [x12], #32
    ldp q2, q3, [x12], #32
    RT_KE_CHK4 20, 21, 22, 23
    subs x11, x11, #1
    b.ne Lrt_kne_chk_sixteen
Lrt_kne_chk_eight:
    tbz x4, #3, Lrt_kne_chk_two
    ldp q0, q1, [x12], #32
    ldp q2, q3, [x12], #32
    RT_KE_CHK4 16, 17, 18, 19
Lrt_kne_chk_two:
    ubfx x15, x4, #1, #2
    cbz x15, Lrt_kne_chk_one
Lrt_kne_chk_twoloop:
    ldr q0, [x12], #16
    fmla v16.2d, v0.2d, v24.2d
    subs x15, x15, #1
    b.ne Lrt_kne_chk_twoloop
Lrt_kne_chk_one:
    tbz x4, #0, Lrt_kne_chk_next
    ldr d0, [x12]
    fmadd d25, d0, d24, d25
Lrt_kne_chk_next:
    add x8, x8, x5
    subs x3, x3, #1
    b.ne Lrt_kne_chk_row
    RT_KE_FOLD
    ret
