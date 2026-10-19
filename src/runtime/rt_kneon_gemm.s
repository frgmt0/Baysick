// =====================================================================
// src/runtime/rt_kneon_gemm.s -- `neon` matrix product C = A * B
// (DESIGN.md 6.6.1, 6.6.5; determinism class R, 6.6.4).
//
// Defines (runtime-private, .private_extern):
//   _bsk_kneon_gemm (x0 C, x1 A, x2 B) -> x0 KS_*
//
// Goto/BLIS structure:
//   for jc in steps of NC over the columns of C:
//     for pc in steps of KC over the inner dimension:
//       pack B(pc:pc+kc, jc:jc+nc) into NR-wide micro-panels (zero-padded)
//       for ic in steps of MC over the rows of C:
//         pack A(ic:ic+mc, pc:pc+kc) into MR-high micro-panels (zero-padded)
//         macro-kernel: for each NR-wide B panel, for each MR-high A panel:
//           micro-kernel: an MR x NR = 8 x 6 block of C (24 q registers,
//           48 doubles) stays in registers for the whole kc loop; each k
//           step loads 8 A values (4 q) and 6 B values (3 q) and issues 24
//           fmla (by element). The block starts at 0 for pc = 0 and is
//           loaded from C for later pc blocks (C += A*B).
// Edge tiles (fewer than 8 rows or 6 columns left) run the same
// micro-kernel on a static 8 x 6 tile, copying the valid part of C in
// (pc > 0) and out; padding contributes exact zeros.
// Tiny products (m*n*k <= RT_KG_SMALL) use an unpacked row-axpy loop.
// Finally _bsk_kneon_chkview reports KS_NONFINITE exactly when a stored
// element is +-inf or NaN.
//
// Class R: the summation order and the use of fused multiply-add depend
// only on the shapes (block sizes are constants), never on addresses,
// alignment or earlier calls, so the result is a deterministic function
// of the shapes and values.
//
// Static buffers (DESIGN.md 6.6.6): packed A (MC*KC doubles), packed B
// (KC*(NC+NR) doubles), a zero row (KC doubles) used to pad short A
// panels, and the 8 x 6 edge tile: about 4.5 MiB, 64-byte aligned.
//
// Link isolation (DESIGN.md 6.6.1): references only rt_kneon_elem.s.
// =====================================================================
.include "baysick.inc"

.equ RT_KG_MR,    8                 // micro-tile rows
.equ RT_KG_NR,    6                 // micro-tile columns
.equ RT_KG_KC,    256               // inner-dimension block depth
.equ RT_KG_MC,    128               // row block height (multiple of MR)
.equ RT_KG_NC,    2046              // column block width (multiple of NR)
.equ RT_KG_SMALL, 32768             // m*n*k at or below this: unpacked path

.if (RT_KG_MC % RT_KG_MR) != 0
    .error "rt_kneon_gemm: MC must be a multiple of MR"
.endif
.if (RT_KG_NC % RT_KG_NR) != 0
    .error "rt_kneon_gemm: NC must be a multiple of NR"
.endif

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// Micro-kernel accumulator layout: row i (0..7) of the 8 x 6 tile lives in
// v(8+3i), v(9+3i), v(10+3i) (columns 0-1, 2-3, 4-5). A values: v0 =
// rows 0-1, v1 = rows 2-3, v2 = rows 4-5, v3 = rows 6-7. B values:
// v4 = columns 0-1, v5 = 2-3, v6 = 4-5.
// ---------------------------------------------------------------------

// RT_KG_ROW a, lane, c0, c1, c2: row (2*a + lane) += A value * B row.
.macro RT_KG_ROW a, lane, c0, c1, c2
    fmla v\c0\().2d, v4.2d, v\a\().d[\lane]
    fmla v\c1\().2d, v5.2d, v\a\().d[\lane]
    fmla v\c2\().2d, v6.2d, v\a\().d[\lane]
.endm

// RT_KG_STEP: one k step: load 8 A and 6 B values, 24 fmla.
.macro RT_KG_STEP
    ldp q0, q1, [x1], #32           // A(0..3, k)
    ldp q4, q5, [x2], #32           // B(k, 0..3)
    ldr q6, [x2], #16               // B(k, 4..5)
    ldp q2, q3, [x1], #32           // A(4..7, k)
    RT_KG_ROW 0, 0,  8,  9, 10
    RT_KG_ROW 0, 1, 11, 12, 13
    RT_KG_ROW 1, 0, 14, 15, 16
    RT_KG_ROW 1, 1, 17, 18, 19
    RT_KG_ROW 2, 0, 20, 21, 22
    RT_KG_ROW 2, 1, 23, 24, 25
    RT_KG_ROW 3, 0, 26, 27, 28
    RT_KG_ROW 3, 1, 29, 30, 31
.endm

// RT_KG_LDROW c0, c1, c2: load one tile row from [x6], advance by x4.
.macro RT_KG_LDROW c0, c1, c2
    ldp q\c0, q\c1, [x6]
    ldr q\c2, [x6, #32]
    add x6, x6, x4
.endm

// RT_KG_STROW c0, c1, c2: store one tile row to [x6], advance by x4.
.macro RT_KG_STROW c0, c1, c2
    stp q\c0, q\c1, [x6]
    str q\c2, [x6, #32]
    add x6, x6, x4
.endm

// ---------------------------------------------------------------------
// Lrt_kg_micro -- 8 x 6 micro-kernel (private convention).
//   Inputs  : x0 = kc (>= 1), x1 = packed A micro-panel (kc x 8 doubles),
//             x2 = packed B micro-panel (kc x 6 doubles), x3 = C tile
//             (element (0,0)), x4 = C row stride in bytes, w5 = 0: the
//             tile starts at zero; 1: the tile is loaded from C first
//   Outputs : the 8 x 6 tile of C (stored)
//   Clobbers: x0-x2, x6, v0-v31 (v8-v15 included: the caller,
//             _bsk_kneon_gemm, saved d8-d15 on entry)
//   Callee-saved used: none (see above)
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .p2align 4
Lrt_kg_micro:
    mov x6, x3
    cbz w5, Lrt_kg_micro_zero
    RT_KG_LDROW  8,  9, 10          // C += A*B: start from C
    RT_KG_LDROW 11, 12, 13
    RT_KG_LDROW 14, 15, 16
    RT_KG_LDROW 17, 18, 19
    RT_KG_LDROW 20, 21, 22
    RT_KG_LDROW 23, 24, 25
    RT_KG_LDROW 26, 27, 28
    RT_KG_LDROW 29, 30, 31
    b Lrt_kg_micro_k
Lrt_kg_micro_zero:
    movi v8.2d, #0                  // C = A*B: start from zero
    movi v9.2d, #0
    movi v10.2d, #0
    movi v11.2d, #0
    movi v12.2d, #0
    movi v13.2d, #0
    movi v14.2d, #0
    movi v15.2d, #0
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
    movi v26.2d, #0
    movi v27.2d, #0
    movi v28.2d, #0
    movi v29.2d, #0
    movi v30.2d, #0
    movi v31.2d, #0
Lrt_kg_micro_k:
    // Four k steps per iteration, then single steps.
    lsr x6, x0, #2
    cbz x6, Lrt_kg_micro_k1
Lrt_kg_micro_k4:
    RT_KG_STEP
    RT_KG_STEP
    RT_KG_STEP
    RT_KG_STEP
    subs x6, x6, #1
    b.ne Lrt_kg_micro_k4
Lrt_kg_micro_k1:
    ands x0, x0, #3
    b.eq Lrt_kg_micro_store
Lrt_kg_micro_k1loop:
    RT_KG_STEP
    subs x0, x0, #1
    b.ne Lrt_kg_micro_k1loop
Lrt_kg_micro_store:
    mov x6, x3
    RT_KG_STROW  8,  9, 10
    RT_KG_STROW 11, 12, 13
    RT_KG_STROW 14, 15, 16
    RT_KG_STROW 17, 18, 19
    RT_KG_STROW 20, 21, 22
    RT_KG_STROW 23, 24, 25
    RT_KG_STROW 26, 27, 28
    RT_KG_STROW 29, 30, 31
    ret

// ---------------------------------------------------------------------
// Lrt_kg_packa -- pack an mc x kc block of A into MR-high micro-panels.
//   Purpose : panel q holds, for k = 0..kc-1, the 8 doubles
//             A(8q+0..8q+7, k) contiguously; rows past mc read the zero
//             row, so they are packed as exact zeros.
//   Inputs  : x0 = &A(ic, pc), x1 = A row stride (bytes), x2 = mc,
//             x3 = kc (<= RT_KG_KC), x4 = destination (packed A buffer)
//   Outputs : none
//   Clobbers: x0, x2, x4-x17, v16-v31
//   Callee-saved used: none
//   Frame   : none (leaf; x16/x17 are used as plain scratch: no calls)
// Registers: x5-x12 = the 8 row cursors, x13 = k pairs left,
// x14 = rows in this panel, x15 = zero row, x16 = row address, x17 = r.
// ---------------------------------------------------------------------
    .p2align 2
Lrt_kg_packa:
    adrp x15, _bsk_rt_kg_zero@PAGE
    add x15, x15, _bsk_rt_kg_zero@PAGEOFF
Lrt_kg_packa_panel:
    cmp x2, #0
    b.le Lrt_kg_packa_done
    // Row cursors: real rows while r < min(8, mc left), else the zero row.
    mov x14, #RT_KG_MR
    cmp x2, x14
    csel x14, x2, x14, lt           // rows in this panel
    mov x16, x0
    mov x17, #0
.irp R, 5, 6, 7, 8, 9, 10, 11, 12
    cmp x17, x14
    csel x\R, x16, x15, lt          // row r, or the zero row
    add x16, x16, x1
    add x17, x17, #1
.endr
    lsr x13, x3, #1                 // pairs of k
    cbz x13, Lrt_kg_packa_odd
Lrt_kg_packa_pair:
    ldr q16, [x5], #16              // A(r, k..k+1) for r = 0..7
    ldr q17, [x6], #16
    ldr q18, [x7], #16
    ldr q19, [x8], #16
    ldr q20, [x9], #16
    ldr q21, [x10], #16
    ldr q22, [x11], #16
    ldr q23, [x12], #16
    zip1 v24.2d, v16.2d, v17.2d     // column k: rows 0-1
    zip1 v25.2d, v18.2d, v19.2d     // rows 2-3
    zip1 v26.2d, v20.2d, v21.2d     // rows 4-5
    zip1 v27.2d, v22.2d, v23.2d     // rows 6-7
    zip2 v28.2d, v16.2d, v17.2d     // column k+1
    zip2 v29.2d, v18.2d, v19.2d
    zip2 v30.2d, v20.2d, v21.2d
    zip2 v31.2d, v22.2d, v23.2d
    stp q24, q25, [x4], #32
    stp q26, q27, [x4], #32
    stp q28, q29, [x4], #32
    stp q30, q31, [x4], #32
    subs x13, x13, #1
    b.ne Lrt_kg_packa_pair
Lrt_kg_packa_odd:
    tbz x3, #0, Lrt_kg_packa_next   // even kc: done
    ldr d16, [x5]                   // last column: one double per row
    ldr d17, [x6]
    ldr d18, [x7]
    ldr d19, [x8]
    ldr d20, [x9]
    ldr d21, [x10]
    ldr d22, [x11]
    ldr d23, [x12]
    stp d16, d17, [x4], #16
    stp d18, d19, [x4], #16
    stp d20, d21, [x4], #16
    stp d22, d23, [x4], #16
Lrt_kg_packa_next:
    add x0, x0, x1, lsl #3          // 8 rows further down
    sub x2, x2, #RT_KG_MR
    b Lrt_kg_packa_panel
Lrt_kg_packa_done:
    ret

// ---------------------------------------------------------------------
// Lrt_kg_packb -- pack a kc x nc block of B into NR-wide micro-panels.
//   Purpose : panel q holds, for k = 0..kc-1, the 6 doubles
//             B(k, 6q+0..6q+5) contiguously; columns past nc are packed
//             as exact zeros.
//   Inputs  : x0 = &B(pc, jc), x1 = B row stride (bytes), x2 = kc,
//             x3 = nc, x4 = destination (packed B buffer)
//   Outputs : none
//   Clobbers: x0, x3-x15, v16-v19
//   Callee-saved used: none
//   Frame   : none (leaf)
// Registers: x5 = cursor down the panel's column strip, x6 = k left,
// x7 = columns in this panel, x8 = c, x9 = scratch.
// ---------------------------------------------------------------------
    .p2align 2
Lrt_kg_packb:
Lrt_kg_packb_panel:
    cmp x3, #0
    b.le Lrt_kg_packb_done
    mov x5, x0
    mov x6, x2
    cmp x3, #RT_KG_NR
    b.lt Lrt_kg_packb_part
    // Full panel: 6 contiguous doubles per k.
    lsr x10, x6, #1
    cbz x10, Lrt_kg_packb_full1
Lrt_kg_packb_full2:
    ldp q16, q17, [x5]
    ldr q18, [x5, #32]
    add x5, x5, x1
    ldp q19, q20, [x5]
    ldr q21, [x5, #32]
    add x5, x5, x1
    stp q16, q17, [x4], #32
    stp q18, q19, [x4], #32
    stp q20, q21, [x4], #32
    subs x10, x10, #1
    b.ne Lrt_kg_packb_full2
Lrt_kg_packb_full1:
    tbz x6, #0, Lrt_kg_packb_next
    ldp q16, q17, [x5]
    ldr q18, [x5, #32]
    stp q16, q17, [x4], #32
    str q18, [x4], #16
    b Lrt_kg_packb_next
Lrt_kg_packb_part:
    // Last, partial panel: nc-left (1..5) doubles, then zeros.
    mov x7, x3
Lrt_kg_packb_pk:
    mov x8, #0
Lrt_kg_packb_pc:
    cmp x8, x7
    b.hs 1f
    ldr x9, [x5, x8, lsl #3]        // real column: exact bits
    b 2f
1:
    mov x9, #0                      // padding: +0.0
2:
    str x9, [x4], #8
    add x8, x8, #1
    cmp x8, #RT_KG_NR
    b.lo Lrt_kg_packb_pc
    add x5, x5, x1
    subs x6, x6, #1
    b.ne Lrt_kg_packb_pk
Lrt_kg_packb_next:
    add x0, x0, #(RT_KG_NR * 8)     // next 6 columns
    sub x3, x3, #RT_KG_NR
    b Lrt_kg_packb_panel
Lrt_kg_packb_done:
    ret

// ---------------------------------------------------------------------
// Lrt_kg_macro -- macro-kernel over one packed A block and B block.
//   Inputs  : x0 = mc, x1 = nc, x2 = kc, x3 = &C(ic, jc), x4 = C row
//             stride (bytes), w5 = load flag (pc > 0), x6 = packed A,
//             x7 = packed B
//   Outputs : C(ic.., jc..) updated
//   Clobbers: x0-x17, v0-v31 (d8-d15 saved by _bsk_kneon_gemm)
//   Callee-saved used: x19 = mc, x20 = nc, x21 = kc, x22 = C block,
//             x23 = C stride, x24 = load flag
//   Frame   : 64 bytes (frame record + x19..x24)
// Registers: x8 = packed A base, x9 = current B panel, x10 = B panel
// bytes (kc*48), x11 = A panel bytes (kc*64), x12 = jr, x13 = nr,
// x14 = ir, x15 = current A panel, x16 = mr, x17 = C tile address
// (x16/x17: only local branches, no external calls, between uses).
// ---------------------------------------------------------------------
    .p2align 2
Lrt_kg_macro:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x23, x4
    mov w24, w5
    mov x8, x6
    mov x9, x7
    mov x10, #(RT_KG_NR * 8)
    mul x10, x10, x21               // bytes per B micro-panel
    lsl x11, x21, #6                // bytes per A micro-panel (kc * 64)
    mov x12, #0                     // jr
Lrt_kg_macro_jr:
    cmp x12, x20
    b.hs Lrt_kg_macro_done
    sub x13, x20, x12
    cmp x13, #RT_KG_NR
    mov x0, #RT_KG_NR
    csel x13, x13, x0, lt           // nr = min(6, nc - jr)
    mov x14, #0                     // ir
    mov x15, x8                     // first A panel
Lrt_kg_macro_ir:
    cmp x14, x19
    b.hs Lrt_kg_macro_jr_next
    sub x16, x19, x14
    cmp x16, #RT_KG_MR
    mov x0, #RT_KG_MR
    csel x16, x16, x0, lt           // mr = min(8, mc - ir)
    madd x17, x14, x23, x22
    add x17, x17, x12, lsl #3       // &C(ic+ir, jc+jr)
    cmp x16, #RT_KG_MR
    ccmp x13, #RT_KG_NR, #0, eq
    b.ne Lrt_kg_macro_edge
    // Full tile: straight into C.
    mov x0, x21
    mov x1, x15
    mov x2, x9
    mov x3, x17
    mov x4, x23
    mov w5, w24
    bl Lrt_kg_micro
    b Lrt_kg_macro_ir_next
Lrt_kg_macro_edge:
    // Partial tile: through the static 8 x 6 tile (row stride 48).
    adrp x7, _bsk_rt_kg_tile@PAGE
    add x7, x7, _bsk_rt_kg_tile@PAGEOFF
    cbz w24, Lrt_kg_macro_edge_run
    // C += A*B: copy the valid mr x nr part of C into the tile.
    mov x0, #0                      // r
1:
    madd x1, x0, x23, x17           // &C(r, 0)
    mov x2, #(RT_KG_NR * 8)
    madd x2, x0, x2, x7             // &tile(r, 0)
    mov x3, #0                      // c
2:
    ldr x6, [x1, x3, lsl #3]
    str x6, [x2, x3, lsl #3]
    add x3, x3, #1
    cmp x3, x13
    b.lo 2b
    add x0, x0, #1
    cmp x0, x16
    b.lo 1b
Lrt_kg_macro_edge_run:
    mov x0, x21
    mov x1, x15
    mov x2, x9
    mov x3, x7
    mov x4, #(RT_KG_NR * 8)
    mov w5, w24
    bl Lrt_kg_micro
    // Copy the valid part of the tile back to C.
    adrp x7, _bsk_rt_kg_tile@PAGE
    add x7, x7, _bsk_rt_kg_tile@PAGEOFF
    mov x0, #0
1:
    madd x1, x0, x23, x17
    mov x2, #(RT_KG_NR * 8)
    madd x2, x0, x2, x7
    mov x3, #0
2:
    ldr x6, [x2, x3, lsl #3]
    str x6, [x1, x3, lsl #3]
    add x3, x3, #1
    cmp x3, x13
    b.lo 2b
    add x0, x0, #1
    cmp x0, x16
    b.lo 1b
Lrt_kg_macro_ir_next:
    add x14, x14, #RT_KG_MR
    add x15, x15, x11               // next A panel
    b Lrt_kg_macro_ir
Lrt_kg_macro_jr_next:
    add x12, x12, #RT_KG_NR
    add x9, x9, x10                 // next B panel
    b Lrt_kg_macro_jr
Lrt_kg_macro_done:
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

// ---------------------------------------------------------------------
// _bsk_kneon_gemm -- C = A * B.
//   Inputs  : x0 = C view (m x n), x1 = A view (m x k), x2 = B view
//             (k x n); C overlaps neither A nor B; inputs finite
//   Outputs : x0 = KS_OK, or KS_NONFINITE if a stored element of C is
//             +-inf or NaN
//   Clobbers: x0-x17, v0-v7, v16-v31
//   Callee-saved used: x19 = C view, x20 = m, x21 = n, x22 = k,
//             x23 = C data, x24 = C stride (bytes), x25 = A data,
//             x26 = A stride, x27 = B data, x28 = B stride; d8-d15 are
//             saved because the micro-kernel uses v8-v15 as accumulators
//   Frame   : 208 bytes: frame record, x19-x28, d8-d15, and the loop
//             variables jc [sp,#160], pc [sp,#168], ic [sp,#176],
//             nc [sp,#184], kc [sp,#192]
// ---------------------------------------------------------------------
    .private_extern _bsk_kneon_gemm
    .p2align 2
_bsk_kneon_gemm:
    stp x29, x30, [sp, #-208]!
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
    mov x19, x0
    ldr x20, [x1, #MV_ROWS]         // m
    ldr x22, [x1, #MV_COLS]         // k
    ldr x21, [x2, #MV_COLS]         // n
    ldr x23, [x0, #MV_DATA]
    ldr x24, [x0, #MV_LD]
    lsl x24, x24, #3
    ldr x25, [x1, #MV_DATA]
    ldr x26, [x1, #MV_LD]
    lsl x26, x26, #3
    ldr x27, [x2, #MV_DATA]
    ldr x28, [x2, #MV_LD]
    lsl x28, x28, #3
    mul x9, x20, x21
    mul x9, x9, x22                 // m*n*k (each < 2^31: no overflow
    cmp x9, #RT_KG_SMALL            //  for any view the MAT layer builds)
    b.ls Lrt_kg_small

    // ---------------- packed path ----------------
    str xzr, [sp, #160]             // jc = 0
Lrt_kg_jc:
    ldr x9, [sp, #160]
    cmp x9, x21
    b.hs Lrt_kg_check
    sub x10, x21, x9
    mov x11, #RT_KG_NC
    cmp x10, x11
    csel x10, x10, x11, lo          // nc = min(NC, n - jc)
    str x10, [sp, #184]
    str xzr, [sp, #168]             // pc = 0
Lrt_kg_pc:
    ldr x9, [sp, #168]
    cmp x9, x22
    b.hs Lrt_kg_jc_next
    sub x10, x22, x9
    mov x11, #RT_KG_KC
    cmp x10, x11
    csel x10, x10, x11, lo          // kc = min(KC, k - pc)
    str x10, [sp, #192]
    // Pack B(pc.., jc..).
    ldr x11, [sp, #160]             // jc
    madd x0, x9, x28, x27           // &B(pc, 0)
    add x0, x0, x11, lsl #3         // &B(pc, jc)
    mov x1, x28
    mov x2, x10                     // kc
    ldr x3, [sp, #184]              // nc
    adrp x4, _bsk_rt_kg_bpack@PAGE
    add x4, x4, _bsk_rt_kg_bpack@PAGEOFF
    bl Lrt_kg_packb
    str xzr, [sp, #176]             // ic = 0
Lrt_kg_ic:
    ldr x9, [sp, #176]
    cmp x9, x20
    b.hs Lrt_kg_pc_next
    // Pack A(ic.., pc..).
    sub x2, x20, x9
    mov x11, #RT_KG_MC
    cmp x2, x11
    csel x2, x2, x11, lo            // mc = min(MC, m - ic)
    ldr x10, [sp, #168]             // pc
    madd x0, x9, x26, x25           // &A(ic, 0)
    add x0, x0, x10, lsl #3         // &A(ic, pc)
    mov x1, x26
    ldr x3, [sp, #192]              // kc
    adrp x4, _bsk_rt_kg_apack@PAGE
    add x4, x4, _bsk_rt_kg_apack@PAGEOFF
    bl Lrt_kg_packa
    // Macro-kernel on C(ic.., jc..).
    ldr x9, [sp, #176]              // ic
    ldr x10, [sp, #160]             // jc
    madd x3, x9, x24, x23
    add x3, x3, x10, lsl #3         // &C(ic, jc)
    sub x0, x20, x9
    mov x11, #RT_KG_MC
    cmp x0, x11
    csel x0, x0, x11, lo            // mc
    ldr x1, [sp, #184]              // nc
    ldr x2, [sp, #192]              // kc
    mov x4, x24
    ldr x5, [sp, #168]
    cmp x5, #0
    cset w5, ne                     // load C unless this is the first pc block
    adrp x6, _bsk_rt_kg_apack@PAGE
    add x6, x6, _bsk_rt_kg_apack@PAGEOFF
    adrp x7, _bsk_rt_kg_bpack@PAGE
    add x7, x7, _bsk_rt_kg_bpack@PAGEOFF
    bl Lrt_kg_macro
    ldr x9, [sp, #176]
    add x9, x9, #RT_KG_MC
    str x9, [sp, #176]
    b Lrt_kg_ic
Lrt_kg_pc_next:
    ldr x9, [sp, #168]
    add x9, x9, #RT_KG_KC
    str x9, [sp, #168]
    b Lrt_kg_pc
Lrt_kg_jc_next:
    ldr x9, [sp, #160]
    add x9, x9, #RT_KG_NC
    str x9, [sp, #160]
    b Lrt_kg_jc

    // ---------------- tiny products: row axpy ----------------
    // For each row i of C: C(i,:) := 0, then for each k:
    // C(i,:) += A(i,k) * B(k,:) (fmla, 2-wide, scalar tail).
    // Registers: x9 = i, x10 = &C(i,0), x11 = &A(i,k), x12 = k left,
    // x13 = &B(k,0), x14/x15 = cursors in C/B, x16 = count.
Lrt_kg_small:
    mov x9, #0
Lrt_kg_small_row:
    cmp x9, x20
    b.hs Lrt_kg_check
    madd x10, x9, x24, x23          // &C(i,0)
    madd x11, x9, x26, x25          // &A(i,0)
    mov x14, x10                    // C(i,:) := 0
    mov x16, x21
1:
    str xzr, [x14], #8
    subs x16, x16, #1
    b.ne 1b
    mov x12, x22
    mov x13, x27
Lrt_kg_small_k:
    ld1r {v0.2d}, [x11], #8         // a = A(i,k) in both lanes
    mov x14, x10
    mov x15, x13
    lsr x16, x21, #1
    cbz x16, 2f
1:
    ldr q1, [x15], #16              // B(k, j..j+1)
    ldr q2, [x14]                   // C(i, j..j+1)
    fmla v2.2d, v1.2d, v0.2d
    str q2, [x14], #16
    subs x16, x16, #1
    b.ne 1b
2:
    tbz x21, #0, 3f
    ldr d1, [x15]
    ldr d2, [x14]
    fmadd d2, d1, d0, d2
    str d2, [x14]
3:
    add x13, x13, x28               // next row of B
    subs x12, x12, #1
    b.ne Lrt_kg_small_k
    add x9, x9, #1
    b Lrt_kg_small_row

    // ---------------- finite test of C ----------------
Lrt_kg_check:
    mov x0, x19
    bl _bsk_kneon_chkview           // x0 = KS_OK / KS_NONFINITE
    ldp d14, d15, [sp, #144]
    ldp d12, d13, [sp, #128]
    ldp d10, d11, [sp, #112]
    ldp d8, d9, [sp, #96]
    ldp x27, x28, [sp, #80]
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #208
    ret

// ---------------------------------------------------------------------
// Static buffers (zero-initialised, 64-byte aligned).
//   _bsk_rt_kg_apack  packed A block: MC * KC doubles
//   _bsk_rt_kg_bpack  packed B block: KC * (NC + NR) doubles
//   _bsk_rt_kg_zero   KC zero doubles (padding rows of A panels; never
//                     written)
//   _bsk_rt_kg_tile   the 8 x 6 edge tile
// ---------------------------------------------------------------------
.zerofill __DATA,__bss,_bsk_rt_kg_apack,RT_KG_MC*RT_KG_KC*8,6
.zerofill __DATA,__bss,_bsk_rt_kg_bpack,RT_KG_KC*(RT_KG_NC+RT_KG_NR)*8,6
.zerofill __DATA,__bss,_bsk_rt_kg_zero,RT_KG_KC*8,6
.zerofill __DATA,__bss,_bsk_rt_kg_tile,RT_KG_MR*RT_KG_NR*8,6
