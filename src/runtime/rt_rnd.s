// =====================================================================
// src/runtime/rt_rnd.s -- RND generator (LANGUAGE.md section 6).
//
// Defines: _bsk_rnd
// Park-Miller "minimal standard" Lehmer generator:
//   s := (RNG_MULT * s) mod RNG_MOD      (exact 64-bit integers)
//   RND := s / RNG_MOD                    (one IEEE division)
// with s = RNG_SEED at program start. s stays in 1..RNG_MOD-1, so the
// result is strictly between 0 and 1.
// =====================================================================
.include "baysick.inc"

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _bsk_rnd -- next pseudo-random number.
//   Inputs  : none
//   Outputs : d0 = value in (0, 1)
//   Clobbers: x9-x12, d1
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .globl _bsk_rnd
    .p2align 2
_bsk_rnd:
    adrp x9, _bsk_rt_rnd_state@PAGE
    ldr x10, [x9, _bsk_rt_rnd_state@PAGEOFF]   // s
    mov x11, #RNG_MULT
    mul x10, x10, x11               // 16807 * s  (< 2^46, exact)
    mov x11, #(RNG_MOD & 0xFFFF)
    movk x11, #(RNG_MOD >> 16), lsl #16        // x11 = 2^31 - 1
    udiv x12, x10, x11
    msub x10, x12, x11, x10         // s = product mod (2^31 - 1)
    str x10, [x9, _bsk_rt_rnd_state@PAGEOFF]
    ucvtf d0, x10                   // exact (s < 2^31)
    ucvtf d1, x11                   // 2147483647.0, exact
    fdiv d0, d0, d1                 // RND = s / 2147483647.0
    ret

// ---------------------------------------------------------------------
// State: the generator value s (u64), initially RNG_SEED.
// ---------------------------------------------------------------------
    .section __DATA,__data
    .p2align 3
_bsk_rt_rnd_state:
    .quad RNG_SEED
