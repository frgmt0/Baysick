# =====================================================================
# src/runtime_x86_64_linux/rt_rnd.s -- RND generator (LANGUAGE.md 6).
#
# Defines: bsk_rnd
# Park-Miller "minimal standard" Lehmer generator:
#   s := (RNG_MULT * s) mod RNG_MOD      (exact 64-bit integers)
#   RND := s / RNG_MOD                    (one IEEE division)
# with s = RNG_SEED at program start. s stays in 1..RNG_MOD-1, so the
# result is strictly between 0 and 1.
# =====================================================================
.include "baysick.inc"

    .text

# ---------------------------------------------------------------------
# bsk_rnd -- next pseudo-random number.
#   Inputs  : none
#   Outputs : %xmm0 = value in (0, 1)
#   Clobbers: %rax, %rcx, %rdx, %xmm1
#   Callee-saved used: none
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_rnd
    .type bsk_rnd, @function
    .p2align 4
bsk_rnd:
    movq .Lrt_rnd_state(%rip), %rax     # s
    imulq $RNG_MULT, %rax, %rax         # 16807 * s  (< 2^46, exact)
    movl $RNG_MOD, %ecx                 # 2^31 - 1
    xorl %edx, %edx
    divq %rcx                           # %rdx = product mod (2^31 - 1)
    movq %rdx, .Lrt_rnd_state(%rip)
    cvtsi2sdq %rdx, %xmm0               # exact (s < 2^31)
    cvtsi2sdq %rcx, %xmm1               # 2147483647.0, exact
    divsd %xmm1, %xmm0                  # RND = s / 2147483647.0
    ret
    .size bsk_rnd, . - bsk_rnd

# ---------------------------------------------------------------------
# State: the generator value s (u64), initially RNG_SEED.
# ---------------------------------------------------------------------
    .data
    .p2align 3
.Lrt_rnd_state:
    .quad RNG_SEED

    .section .note.GNU-stack,"",@progbits
