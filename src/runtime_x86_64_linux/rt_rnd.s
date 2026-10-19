# =====================================================================
# src/runtime_x86_64_linux/rt_rnd.s -- RND generator (LANGUAGE.md 6).
#
# Defines: bsk_rnd bsk_randomize
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
# bsk_randomize -- RANDOMIZE (LANGUAGE.md 7.18, DESIGN.md 6.7).
#   Purpose : v = 64 bits from getentropy(&v, 8); if that fails,
#             v = time(NULL); then s := 1 + (v mod RNG_RANDOMIZE_MOD)
#             with v taken as an unsigned 64-bit integer, so s stays
#             in 1 .. 2^31 - 2 (a valid Lehmer state, never 0).
#   Inputs  : none
#   Outputs : none
#   Clobbers: all caller-saved registers (libc calls)
#   Callee-saved used: %rbp = frame pointer
#   Frame   : 8 bytes (saved %rbp) + 16 bytes (v at (%rsp), pad);
#             %rsp = 0 (mod 16) at the calls
# ---------------------------------------------------------------------
    .globl bsk_randomize
    .type bsk_randomize, @function
    .p2align 4
bsk_randomize:
    pushq %rbp
    movq %rsp, %rbp
    subq $16, %rsp                      # v at (%rsp)
    movq $0, (%rsp)
    movq %rsp, %rdi
    movl $8, %esi
    call getentropy@PLT                 # 0 = success, -1 = failure
    testl %eax, %eax
    jz 1f
    xorl %edi, %edi
    call time@PLT                       # fallback: seconds since epoch
    movq %rax, (%rsp)
1:
    movq (%rsp), %rax                   # v (unsigned)
    xorl %edx, %edx
    movl $RNG_RANDOMIZE_MOD, %ecx
    divq %rcx                           # %rdx = v mod (2^31 - 2)
    addq $1, %rdx                       # s = 1 + remainder
    movq %rdx, .Lrt_rnd_state(%rip)
    movq %rbp, %rsp
    popq %rbp
    ret
    .size bsk_randomize, . - bsk_randomize

# ---------------------------------------------------------------------
# State: the generator value s (u64), initially RNG_SEED.
# ---------------------------------------------------------------------
    .data
    .p2align 3
.Lrt_rnd_state:
    .quad RNG_SEED

    .section .note.GNU-stack,"",@progbits
