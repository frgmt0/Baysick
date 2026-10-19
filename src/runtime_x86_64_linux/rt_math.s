# =====================================================================
# src/runtime_x86_64_linux/rt_math.s -- checked arithmetic and builtin
# functions.
#
# Defines: bsk_div bsk_pow bsk_chk bsk_sin bsk_cos bsk_tan bsk_atn
#          bsk_exp bsk_abs bsk_log bsk_sqr bsk_int
# Semantics: LANGUAGE.md sections 5.4 and 6, DESIGN.md sections 6.2 and
# 6.4.3 (libm sin cos tan atan exp log pow trunc through the PLT; SQR is
# sqrtsd of |x|; ABS clears the sign bit). Inputs are always finite (any
# non-finite value raises OVERFLOW at the operation that produced it).
# Error exits jump to bsk_err, which never returns and realigns the
# stack itself, so a jump from any stack depth is safe.
# =====================================================================
.include "baysick.inc"

# Bits of +infinity shifted left by one (sign bit dropped): a double is
# not finite exactly when (bits << 1) >= this value.
.equ RT_DINF_SHL1, 0xFFE0000000000000

# RT_FINITE_OR_OVERFLOW: if %xmm0 is +-inf or NaN, jump to bsk_err with
# ERR_OVERFLOW (no return); otherwise fall through.
# Clobbers %rax, %rcx (and %edi only on the error path).
.macro RT_FINITE_OR_OVERFLOW
    movq %xmm0, %rax
    addq %rax, %rax                 # drop the sign bit
    movabsq $RT_DINF_SHL1, %rcx
    cmpq %rcx, %rax
    jb .Lrt_math_finite_\@          # exponent not all ones: finite
    movl $ERR_OVERFLOW, %edi
    jmp bsk_err                     # noreturn
.Lrt_math_finite_\@:
.endm

# RT_ABS_XMM0: %xmm0 = |%xmm0| (clear the sign bit). Clobbers %rax.
.macro RT_ABS_XMM0
    movq %xmm0, %rax
    btrq $63, %rax
    movq %rax, %xmm0
.endm

# RT_LIBM_CHECKED name, libmfn: a builtin that calls libm and raises
# OVERFLOW when the result is not finite.
#   Inputs  : %xmm0 = x
#   Outputs : %xmm0 = libmfn(x)
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbp = frame pointer
#   Frame   : 8 bytes (saved %rbp; aligns %rsp for the libm call)
.macro RT_LIBM_CHECKED name, libmfn
    .globl \name
    .type \name, @function
    .p2align 4
\name:
    pushq %rbp
    movq %rsp, %rbp
    call \libmfn@PLT                # %xmm0 = libm result
    popq %rbp
    RT_FINITE_OR_OVERFLOW
    ret
    .size \name, . - \name
.endm

    .text

# ---------------------------------------------------------------------
# bsk_div -- a / b.
#   Inputs  : %xmm0 = a, %xmm1 = b
#   Outputs : %xmm0 = a / b
#   Errors  : b = +-0 -> DIVISION BY ZERO; non-finite result -> OVERFLOW
#   Clobbers: %rax, %rcx, %rdi, %xmm0, %xmm2
#   Callee-saved used: none
#   Frame   : none (leaf; errors leave by a jump to bsk_err)
# ---------------------------------------------------------------------
    .globl bsk_div
    .type bsk_div, @function
    .p2align 4
bsk_div:
    pxor %xmm2, %xmm2
    ucomisd %xmm2, %xmm1            # +0 and -0 both compare equal
    jp 1f                           # unordered: not zero
    jne 1f
    movl $ERR_DIVISION_BY_ZERO, %edi
    jmp bsk_err
1:
    divsd %xmm1, %xmm0
    RT_FINITE_OR_OVERFLOW
    ret
    .size bsk_div, . - bsk_div

# ---------------------------------------------------------------------
# bsk_pow -- a ^ b.
#   Purpose : a = 0: b < 0 -> error, b = 0 -> 1, b > 0 -> 0;
#             otherwise pow(|a|, b) ([M64] p. 9).
#   Inputs  : %xmm0 = a, %xmm1 = b
#   Outputs : %xmm0 = result
#   Errors  : ZERO TO A NEGATIVE POWER; OVERFLOW if result not finite
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbp = frame pointer (general case only)
#   Frame   : none for a = 0; 8 bytes (saved %rbp) around the libm call
# ---------------------------------------------------------------------
    .globl bsk_pow
    .type bsk_pow, @function
    .p2align 4
bsk_pow:
    pxor %xmm2, %xmm2
    ucomisd %xmm2, %xmm0
    jp .Lrt_math_pow_general        # unordered: not zero
    jne .Lrt_math_pow_general
    # a = 0 (either sign)
    ucomisd %xmm2, %xmm1            # flags of b - 0
    jb .Lrt_math_pow_zneg           # b < 0
    je .Lrt_math_pow_one            # b = 0
    pxor %xmm0, %xmm0               # 0 ^ positive = 0
    ret
.Lrt_math_pow_one:
    movl $1, %eax
    cvtsi2sdl %eax, %xmm0           # 0 ^ 0 = 1
    ret
.Lrt_math_pow_zneg:
    movl $ERR_ZERO_NEG_POWER, %edi
    jmp bsk_err
.Lrt_math_pow_general:
    pushq %rbp                      # aligns %rsp for the libm call
    movq %rsp, %rbp
    RT_ABS_XMM0                     # pow(|a|, b)
    call pow@PLT
    popq %rbp
    RT_FINITE_OR_OVERFLOW
    ret
    .size bsk_pow, . - bsk_pow

# ---------------------------------------------------------------------
# bsk_chk -- return x unchanged, or OVERFLOW if x is not finite.
#   Inputs  : %xmm0 = x
#   Outputs : %xmm0 = x
#   Clobbers: %rax, %rcx, %rdi
#   Callee-saved used: none
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_chk
    .type bsk_chk, @function
    .p2align 4
bsk_chk:
    RT_FINITE_OR_OVERFLOW
    ret
    .size bsk_chk, . - bsk_chk

# ---------------------------------------------------------------------
# bsk_sin bsk_cos bsk_tan bsk_atn bsk_exp -- libm sin, cos, tan, atan,
# exp; OVERFLOW if the result is not finite (EXP(710)).
# (atan of a finite value is always finite; the check is uniform.)
# ---------------------------------------------------------------------
    RT_LIBM_CHECKED bsk_sin, sin
    RT_LIBM_CHECKED bsk_cos, cos
    RT_LIBM_CHECKED bsk_tan, tan
    RT_LIBM_CHECKED bsk_atn, atan
    RT_LIBM_CHECKED bsk_exp, exp

# ---------------------------------------------------------------------
# bsk_abs -- |x| (clear the sign bit).
#   Inputs  : %xmm0 = x     Outputs : %xmm0 = |x|
#   Clobbers: %rax   Callee-saved used: none   Frame: none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_abs
    .type bsk_abs, @function
    .p2align 4
bsk_abs:
    RT_ABS_XMM0
    ret
    .size bsk_abs, . - bsk_abs

# ---------------------------------------------------------------------
# bsk_sqr -- sqrt(|x|) ([M64] p. 11).
#   Inputs  : %xmm0 = x     Outputs : %xmm0 = sqrt(|x|)
#   Clobbers: %rax   Callee-saved used: none   Frame: none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_sqr
    .type bsk_sqr, @function
    .p2align 4
bsk_sqr:
    RT_ABS_XMM0
    sqrtsd %xmm0, %xmm0             # IEEE correctly rounded, as libm sqrt
    ret
    .size bsk_sqr, . - bsk_sqr

# ---------------------------------------------------------------------
# bsk_int -- chop the fraction toward zero (C trunc): INT(-7.8) = -7.
#   Inputs  : %xmm0 = x     Outputs : %xmm0 = trunc(x)
#   Clobbers: all caller-saved registers (libm)
#   Callee-saved used: none
#   Frame   : none (tail call: trunc sees our caller's alignment)
# ---------------------------------------------------------------------
    .globl bsk_int
    .type bsk_int, @function
    .p2align 4
bsk_int:
    jmp trunc@PLT                   # SSE2 has no roundsd; libm trunc
    .size bsk_int, . - bsk_int

# ---------------------------------------------------------------------
# bsk_log -- log(|x|); x = 0 -> LOG OF ZERO.
#   Inputs  : %xmm0 = x
#   Outputs : %xmm0 = log(|x|)
#   Errors  : LOG OF ZERO; OVERFLOW if the result is not finite
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbp = frame pointer
#   Frame   : 8 bytes (saved %rbp) around the libm call
# ---------------------------------------------------------------------
    .globl bsk_log
    .type bsk_log, @function
    .p2align 4
bsk_log:
    pxor %xmm2, %xmm2
    ucomisd %xmm2, %xmm0
    jp 1f                           # unordered: not zero
    jne 1f
    movl $ERR_LOG_OF_ZERO, %edi
    jmp bsk_err
1:
    pushq %rbp                      # aligns %rsp for the libm call
    movq %rsp, %rbp
    RT_ABS_XMM0
    call log@PLT
    popq %rbp
    RT_FINITE_OR_OVERFLOW
    ret
    .size bsk_log, . - bsk_log

    .section .note.GNU-stack,"",@progbits
