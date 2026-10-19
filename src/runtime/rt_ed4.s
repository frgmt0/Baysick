// =====================================================================
// src/runtime/rt_ed4.s -- the small Third/Fourth Edition entry points
// (DESIGN.md 6.7): ON, RANDOMIZE, SGN, COT, NUM, DET and PRINT TAB.
//
// Defines (global, runtime.inc):
//   _bsk_on _bsk_randomize _bsk_sgn _bsk_cot _bsk_num _bsk_det
//   _bsk_print_tab
// Defines (private to the runtime, .private_extern):
//   _bsk_rt_num   double, the NUM value (initially 0), written by MAT
//                 INPUT (rt_input.s)
// Uses: _bsk_rt_kinv_det (the DET cell, rt_kinit.s), _bsk_rt_rnd_state
// (rt_rnd.s), _bsk_rt_print_tabcol (rt_print.s).
// =====================================================================
.include "baysick.inc"

.equ RT_ED4_INF_HI16, 0x7FF0        // upper 16 bits of +infinity

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _bsk_on -- the selector of ON ... GO TO (LANGUAGE.md 7.17).
//   Purpose : k = trunc(x); 1 <= k <= n (compared as doubles, so a huge
//             x can never wrap) -> k; else ON EVALUATED OUT OF RANGE.
//   Inputs  : d0 = x (finite), w0 = n (number of line numbers, >= 1)
//   Outputs : d0 = k (an integer-valued double)
//   Errors  : ON EVALUATED OUT OF RANGE
//   Clobbers: x0, d0, d1
//   Callee-saved used: none
//   Frame   : none (leaf; the error exit is a branch)
// ---------------------------------------------------------------------
    .globl _bsk_on
    .p2align 2
_bsk_on:
    frintz d0, d0                   // k = trunc(x), exact
    fmov d1, #1.0
    fcmp d0, d1
    b.lt Lrt_ed4_on_bad             // k < 1
    ucvtf d1, w0                    // n, exact
    fcmp d0, d1
    b.gt Lrt_ed4_on_bad             // k > n
    ret
Lrt_ed4_on_bad:
    mov w0, #ERR_ON_RANGE
    b _bsk_err

// ---------------------------------------------------------------------
// _bsk_randomize -- RANDOMIZE (LANGUAGE.md 7.18).
//   Purpose : v = 64 bits from getentropy(&v, 8); if that fails,
//             v = time(NULL); RND state s := 1 + (v mod 2147483646)
//             with v unsigned 64-bit, so 1 <= s <= 2^31 - 2.
//   Inputs  : none
//   Outputs : none
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : 32 bytes (frame record + v at [sp, #16])
// ---------------------------------------------------------------------
    .globl _bsk_randomize
    .p2align 2
_bsk_randomize:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    add x0, sp, #16
    mov x1, #8
    bl _getentropy                  // 0 on success
    cbz w0, 1f
    mov x0, #0
    bl _time                        // fallback: seconds since the epoch
    str x0, [sp, #16]
1:
    ldr x9, [sp, #16]               // v
    mov x10, #(RNG_RANDOMIZE_MOD & 0xFFFF)
    movk x10, #(RNG_RANDOMIZE_MOD >> 16), lsl #16 // 2^31 - 2
    udiv x11, x9, x10
    msub x9, x11, x10, x9           // v mod (2^31 - 2)
    add x9, x9, #1                  // s = 1 + (v mod (2^31 - 2))
    adrp x10, _bsk_rt_rnd_state@PAGE
    str x9, [x10, _bsk_rt_rnd_state@PAGEOFF]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _bsk_sgn -- SGN(x) (LANGUAGE.md 6): 1, 0 (either zero), -1.
//   Inputs  : d0 = x (finite)
//   Outputs : d0 = sign
//   Clobbers: d0, d1
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .globl _bsk_sgn
    .p2align 2
_bsk_sgn:
    fcmp d0, #0.0
    fmov d0, #1.0
    fmov d1, #-1.0
    fcsel d0, d1, d0, lt            // x < 0 -> -1
    movi d1, #0                     // +0
    fcsel d0, d1, d0, eq            // x = +-0 -> 0
    ret

// ---------------------------------------------------------------------
// _bsk_cot -- COT(x) = 1 / tan(x) (LANGUAGE.md 6).
//   Purpose : t = tan(x) (libm); t = +-0 -> DIVISION BY ZERO; 1/t (one
//             IEEE division); a non-finite result -> OVERFLOW.
//   Inputs  : d0 = x (finite)
//   Outputs : d0 = cot(x)
//   Errors  : DIVISION BY ZERO, OVERFLOW
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : 16 bytes (frame record)
// ---------------------------------------------------------------------
    .globl _bsk_cot
    .p2align 2
_bsk_cot:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl _tan                         // d0 = t
    ldp x29, x30, [sp], #16
    fcmp d0, #0.0
    b.ne 1f                         // +0 and -0 both compare equal
    mov w0, #ERR_DIVISION_BY_ZERO
    b _bsk_err
1:
    fmov d1, #1.0
    fdiv d0, d1, d0                 // 1 / t
    b Lrt_ed4_finite                // OVERFLOW unless finite

// ---------------------------------------------------------------------
// _bsk_num -- NUM: the number of values the latest MAT INPUT accepted.
//   Inputs  : none
//   Outputs : d0 = NUM (0 before the first MAT INPUT)
//   Clobbers: x9, d0
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .globl _bsk_num
    .p2align 2
_bsk_num:
    adrp x9, _bsk_rt_num@PAGE
    ldr d0, [x9, _bsk_rt_num@PAGEOFF]
    ret

// ---------------------------------------------------------------------
// _bsk_det -- DET: the pinned determinant of the latest successful MAT
//   INV (the DET cell written by the inv kernel, DESIGN.md 6.6.1).
//   Inputs  : none
//   Outputs : d0 = DET (0 before the first inversion)
//   Errors  : OVERFLOW if the determinant is not finite
//   Clobbers: x0, x9, d0, d16, d17
//   Callee-saved used: none
//   Frame   : none (leaf; the error exit is a branch)
// ---------------------------------------------------------------------
    .globl _bsk_det
    .p2align 2
_bsk_det:
    adrp x9, _bsk_rt_kinv_det@PAGE
    ldr d0, [x9, _bsk_rt_kinv_det@PAGEOFF]
    // fall through to the finite check

// Lrt_ed4_finite -- return d0 if finite, else OVERFLOW (no return).
// Clobbers x0, x9, d16, d17.
Lrt_ed4_finite:
    fabs d16, d0
    movz x9, #RT_ED4_INF_HI16, lsl #48
    fmov d17, x9                    // +infinity
    fcmp d16, d17
    b.lo 1f                         // |x| < inf (NaN is unordered)
    mov w0, #ERR_OVERFLOW
    b _bsk_err
1:
    ret

// ---------------------------------------------------------------------
// _bsk_print_tab -- PRINT TAB(x) (LANGUAGE.md 8, DESIGN.md 6.7).
//   Purpose : m = fmod(trunc(x), 75) (both exact), m += 75 if m < 0;
//             if col < m then col = m (lazy; TAB never starts a line).
//   Inputs  : d0 = x (finite)
//   Outputs : none
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : 16 bytes (frame record)
// ---------------------------------------------------------------------
    .globl _bsk_print_tab
    .p2align 2
_bsk_print_tab:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    frintz d0, d0                   // k = trunc(x)
    mov w9, #TAB_MODULUS
    ucvtf d1, w9
    bl _fmod                        // m = fmod(k, 75): |m| < 75, sign of k
    fcmp d0, #0.0
    b.ge 1f
    mov w9, #TAB_MODULUS
    ucvtf d1, w9
    fadd d0, d0, d1                 // negative: m + 75 (exact)
1:
    fcvtzu x0, d0                   // 0 .. 74 (-0 converts to 0)
    bl _bsk_rt_print_tabcol
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// State: NUM (double, initially 0).
// ---------------------------------------------------------------------
    .private_extern _bsk_rt_num
.zerofill __DATA,__bss,_bsk_rt_num,8,3
