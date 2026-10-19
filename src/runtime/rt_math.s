// =====================================================================
// src/runtime/rt_math.s -- checked arithmetic and builtin functions.
//
// Defines: _bsk_div _bsk_pow _bsk_chk _bsk_sin _bsk_cos _bsk_tan
//          _bsk_atn _bsk_exp _bsk_abs _bsk_log _bsk_sqr _bsk_int
// Semantics: LANGUAGE.md sections 5.4 and 6, DESIGN.md section 6.2.
// Inputs are always finite (any non-finite value raises OVERFLOW at the
// operation that produced it).
// =====================================================================
.include "baysick.inc"

// Upper 16 bits of +infinity (0x7FF0000000000000).
.equ RT_DINF_HI16, 0x7FF0

// RT_FINITE_OR_OVERFLOW: if d0 is +-inf or NaN, branch to _bsk_err with
// ERR_OVERFLOW (no return); otherwise fall through.
// Clobbers d16, d17, x9 (and w0 only on the error path).
.macro RT_FINITE_OR_OVERFLOW
    fabs d16, d0
    movz x9, #RT_DINF_HI16, lsl #48
    fmov d17, x9                    // +infinity
    fcmp d16, d17
    b.lo 1f                         // |x| < inf: finite (NaN is unordered)
    mov w0, #ERR_OVERFLOW
    b _bsk_err                      // noreturn
1:
.endm

// RT_LIBM_CHECKED name, libmfn: a builtin that calls libm and raises
// OVERFLOW when the result is not finite.
//   Inputs  : d0 = x
//   Outputs : d0 = libmfn(x)
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : 16 bytes (frame record)
.macro RT_LIBM_CHECKED name, libmfn
    .globl \name
    .p2align 2
\name:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl \libmfn                      // d0 = libm result
    ldp x29, x30, [sp], #16
    RT_FINITE_OR_OVERFLOW
    ret
.endm

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _bsk_div -- a / b.
//   Inputs  : d0 = a, d1 = b
//   Outputs : d0 = a / b
//   Errors  : b = +-0 -> DIVISION BY ZERO; non-finite result -> OVERFLOW
//   Clobbers: x0, x9, d16, d17
//   Callee-saved used: none
//   Frame   : none (leaf; errors leave by a branch to _bsk_err)
// ---------------------------------------------------------------------
    .globl _bsk_div
    .p2align 2
_bsk_div:
    fcmp d1, #0.0                   // +0 and -0 both compare equal
    b.ne 1f
    mov w0, #ERR_DIVISION_BY_ZERO
    b _bsk_err
1:
    fdiv d0, d0, d1
    RT_FINITE_OR_OVERFLOW
    ret

// ---------------------------------------------------------------------
// _bsk_pow -- a ^ b.
//   Purpose : a = 0: b < 0 -> error, b = 0 -> 1, b > 0 -> 0;
//             otherwise pow(|a|, b) ([M64] p. 9).
//   Inputs  : d0 = a, d1 = b
//   Outputs : d0 = result
//   Errors  : ZERO TO A NEGATIVE POWER; OVERFLOW if result not finite
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : 16 bytes (frame record)
// ---------------------------------------------------------------------
    .globl _bsk_pow
    .p2align 2
_bsk_pow:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    fcmp d0, #0.0
    b.ne Lrt_math_pow_general
    // a = 0 (either sign)
    fcmp d1, #0.0
    b.lt Lrt_math_pow_zneg
    fmov d0, #1.0                   // 0 ^ 0 = 1
    b.eq Lrt_math_pow_done
    movi d0, #0                     // 0 ^ positive = 0
    b Lrt_math_pow_done
Lrt_math_pow_zneg:
    mov w0, #ERR_ZERO_NEG_POWER
    b _bsk_err
Lrt_math_pow_general:
    fabs d0, d0                     // pow(|a|, b)
    bl _pow
    RT_FINITE_OR_OVERFLOW
Lrt_math_pow_done:
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// _bsk_chk -- return x unchanged, or OVERFLOW if x is not finite.
//   Inputs  : d0 = x
//   Outputs : d0 = x
//   Clobbers: x0, x9, d16, d17
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .globl _bsk_chk
    .p2align 2
_bsk_chk:
    RT_FINITE_OR_OVERFLOW
    ret

// ---------------------------------------------------------------------
// _bsk_sin _bsk_cos _bsk_tan _bsk_atn _bsk_exp -- libm sin, cos, tan,
// atan, exp; OVERFLOW if the result is not finite (EXP(710)).
// (atan of a finite value is always finite; the check is uniform.)
// ---------------------------------------------------------------------
    RT_LIBM_CHECKED _bsk_sin, _sin
    RT_LIBM_CHECKED _bsk_cos, _cos
    RT_LIBM_CHECKED _bsk_tan, _tan
    RT_LIBM_CHECKED _bsk_atn, _atan
    RT_LIBM_CHECKED _bsk_exp, _exp

// ---------------------------------------------------------------------
// _bsk_abs -- |x|.
//   Inputs  : d0 = x     Outputs : d0 = |x|
//   Clobbers: none other   Callee-saved used: none   Frame: none (leaf)
// ---------------------------------------------------------------------
    .globl _bsk_abs
    .p2align 2
_bsk_abs:
    fabs d0, d0
    ret

// ---------------------------------------------------------------------
// _bsk_sqr -- sqrt(|x|) ([M64] p. 11).
//   Inputs  : d0 = x     Outputs : d0 = sqrt(|x|)
//   Clobbers: none other   Callee-saved used: none   Frame: none (leaf)
// ---------------------------------------------------------------------
    .globl _bsk_sqr
    .p2align 2
_bsk_sqr:
    fabs d0, d0
    fsqrt d0, d0                    // IEEE correctly rounded, as libm sqrt
    ret

// ---------------------------------------------------------------------
// _bsk_int -- chop the fraction toward zero (C trunc): INT(-7.8) = -7.
//   Inputs  : d0 = x     Outputs : d0 = trunc(x)
//   Clobbers: none other   Callee-saved used: none   Frame: none (leaf)
// ---------------------------------------------------------------------
    .globl _bsk_int
    .p2align 2
_bsk_int:
    frintz d0, d0
    ret

// ---------------------------------------------------------------------
// _bsk_log -- log(|x|); x = 0 -> LOG OF ZERO.
//   Inputs  : d0 = x
//   Outputs : d0 = log(|x|)
//   Errors  : LOG OF ZERO; OVERFLOW if the result is not finite
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : 16 bytes (frame record)
// ---------------------------------------------------------------------
    .globl _bsk_log
    .p2align 2
_bsk_log:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    fcmp d0, #0.0
    b.ne 1f
    mov w0, #ERR_LOG_OF_ZERO
    b _bsk_err
1:
    fabs d0, d0
    bl _log
    RT_FINITE_OR_OVERFLOW
    ldp x29, x30, [sp], #16
    ret
