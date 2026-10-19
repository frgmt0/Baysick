// peak_arm64.s -- peak floating-point rate of the NEON f64 FMA pipes (BENCH.md section 3.4).
//
// double peak_neon_fma(uint64_t iterations)       (AAPCS64, Apple as)
//
// Runs `iterations` times a block of 24 independent `fmla v.2d` chains (v0..v23 are the
// accumulators; v24 and v25 hold 1.0), no memory traffic. 24 chains cover the FMA latency
// (about 4 cycles) on all four pipes of an Apple P-core. Each fmla is 2 lanes x (multiply +
// add) = 4 flops, so a call performs 96 * iterations flops.
//
// In:  x0 = iterations (>= 1)
// Out: d0 = accumulator v0, lane 0 = 1.0 + iterations (exact below 2^53): the caller checks
//           it, which also keeps the work observable
// Clobbers: x0, v0-v7, v16-v25 and, saved and restored here, d8-d15 (callee-saved low halves,
//           used as accumulators v8-v15). Leaf function, frame 64 bytes.
    .text
    .globl _peak_neon_fma
    .p2align 4
_peak_neon_fma:
    stp     d8, d9, [sp, #-64]!     // save callee-saved halves of v8-v15
    stp     d10, d11, [sp, #16]
    stp     d12, d13, [sp, #32]
    stp     d14, d15, [sp, #48]
    fmov    v24.2d, #1.0            // multiplicands: every fmla adds exactly 1.0 per lane
    fmov    v25.2d, #1.0
    fmov    v0.2d, #1.0             // accumulators start at 1.0
    fmov    v1.2d, #1.0
    fmov    v2.2d, #1.0
    fmov    v3.2d, #1.0
    fmov    v4.2d, #1.0
    fmov    v5.2d, #1.0
    fmov    v6.2d, #1.0
    fmov    v7.2d, #1.0
    fmov    v8.2d, #1.0
    fmov    v9.2d, #1.0
    fmov    v10.2d, #1.0
    fmov    v11.2d, #1.0
    fmov    v12.2d, #1.0
    fmov    v13.2d, #1.0
    fmov    v14.2d, #1.0
    fmov    v15.2d, #1.0
    fmov    v16.2d, #1.0
    fmov    v17.2d, #1.0
    fmov    v18.2d, #1.0
    fmov    v19.2d, #1.0
    fmov    v20.2d, #1.0
    fmov    v21.2d, #1.0
    fmov    v22.2d, #1.0
    fmov    v23.2d, #1.0
1:  // one iteration: 24 independent accumulate chains
    fmla    v0.2d, v24.2d, v25.2d
    fmla    v1.2d, v24.2d, v25.2d
    fmla    v2.2d, v24.2d, v25.2d
    fmla    v3.2d, v24.2d, v25.2d
    fmla    v4.2d, v24.2d, v25.2d
    fmla    v5.2d, v24.2d, v25.2d
    fmla    v6.2d, v24.2d, v25.2d
    fmla    v7.2d, v24.2d, v25.2d
    fmla    v8.2d, v24.2d, v25.2d
    fmla    v9.2d, v24.2d, v25.2d
    fmla    v10.2d, v24.2d, v25.2d
    fmla    v11.2d, v24.2d, v25.2d
    fmla    v12.2d, v24.2d, v25.2d
    fmla    v13.2d, v24.2d, v25.2d
    fmla    v14.2d, v24.2d, v25.2d
    fmla    v15.2d, v24.2d, v25.2d
    fmla    v16.2d, v24.2d, v25.2d
    fmla    v17.2d, v24.2d, v25.2d
    fmla    v18.2d, v24.2d, v25.2d
    fmla    v19.2d, v24.2d, v25.2d
    fmla    v20.2d, v24.2d, v25.2d
    fmla    v21.2d, v24.2d, v25.2d
    fmla    v22.2d, v24.2d, v25.2d
    fmla    v23.2d, v24.2d, v25.2d
    subs    x0, x0, #1              // loop counter on the integer pipe
    b.ne    1b
    ldp     d14, d15, [sp, #48]     // restore callee-saved halves; d0 (= v0 lane 0) is the result
    ldp     d12, d13, [sp, #32]
    ldp     d10, d11, [sp, #16]
    ldp     d8, d9, [sp], #64
    ret
