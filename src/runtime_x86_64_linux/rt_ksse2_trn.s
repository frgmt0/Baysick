# =====================================================================
# src/runtime_x86_64_linux/rt_ksse2_trn.s -- SSE2 blocked transpose of
# the "sse2" variant (docs/DESIGN.md 6.6.1, 6.6.5).
#
# Defines (private to the runtime, .globl + .hidden):
#   bsk_rt_ksse2_trn    C = transpose of A  (A m x n, C n x m)
#
# Class E: exact copies only (bit patterns move through xmm registers
# by loads, unpcklpd/unpckhpd and stores; no arithmetic).
#
# Structure: the m x n source is walked in RT_TRN_BLK x RT_TRN_BLK
# blocks (both blocks of A and C then stay in L1); inside a block, 2 x 2
# tiles are transposed in registers:
#     x0 = A(i,   j..j+1)            x1 = A(i+1, j..j+1)
#     unpcklpd -> (A(i,j),   A(i+1,j))   = C(j,   i..i+1)
#     unpckhpd -> (A(i,j+1), A(i+1,j+1)) = C(j+1, i..i+1)
# An odd last column / row of a block is copied element by element.
# =====================================================================
.include "baysick.inc"

.equ RT_TRN_BLK, 32                 # block edge in elements (even)

    .text

# ---------------------------------------------------------------------
# bsk_rt_ksse2_trn
#   Inputs  : %rdi = C view (n x m), %rsi = A view (m x n); no overlap
#   Outputs : none
#   Clobbers: %rax %rcx %rdx %rsi %rdi %r8-%r11 %xmm0-%xmm2
#   Callee-saved used: %rbx = i, %r12 = ib, %r13 = jb, %r14 = ie,
#             %r15 = je, %rbp = j (all saved/restored)
#   Frame   : 48 bytes (six saved registers); leaf
#   Other registers: %rdi = C data, %rsi = A data, %r8 = C stride
#             bytes, %r9 = A stride bytes, %r10 = m, %r11 = n,
#             %rax = &A(i,j), %rdx = &C(j,i), %rcx = scratch
# ---------------------------------------------------------------------
    .globl bsk_rt_ksse2_trn
    .hidden bsk_rt_ksse2_trn
    .type bsk_rt_ksse2_trn, @function
    .p2align 4
bsk_rt_ksse2_trn:
    pushq %rbx
    pushq %rbp
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    movq MV_ROWS(%rsi), %r10        # m
    movq MV_COLS(%rsi), %r11        # n
    movq MV_LD(%rdi), %r8
    shlq $3, %r8                    # C stride in bytes
    movq MV_LD(%rsi), %r9
    shlq $3, %r9                    # A stride in bytes
    movq MV_DATA(%rdi), %rdi
    movq MV_DATA(%rsi), %rsi
    xorl %r12d, %r12d               # ib = 0
.Lrt_trn_iblk:
    leaq RT_TRN_BLK(%r12), %r14     # ie = min(ib + BLK, m)
    cmpq %r10, %r14
    cmova %r10, %r14
    xorl %r13d, %r13d               # jb = 0
.Lrt_trn_jblk:
    leaq RT_TRN_BLK(%r13), %r15     # je = min(jb + BLK, n)
    cmpq %r11, %r15
    cmova %r11, %r15
    movq %r12, %rbx                 # i = ib
.Lrt_trn_ipair:
    leaq 2(%rbx), %rcx
    cmpq %r14, %rcx
    ja .Lrt_trn_irow                # fewer than two rows left
    # %rax = &A(i, jb), %rdx = &C(jb, i)
    movq %rbx, %rax
    imulq %r9, %rax
    addq %rsi, %rax
    leaq (%rax,%r13,8), %rax
    movq %r13, %rdx
    imulq %r8, %rdx
    addq %rdi, %rdx
    leaq (%rdx,%rbx,8), %rdx
    movq %r13, %rbp                 # j = jb
.Lrt_trn_jpair:
    leaq 2(%rbp), %rcx
    cmpq %r15, %rcx
    ja .Lrt_trn_jlast               # fewer than two columns left
    movupd (%rax), %xmm0            # A(i,   j..j+1)
    movupd (%rax,%r9), %xmm1        # A(i+1, j..j+1)
    movapd %xmm0, %xmm2
    unpcklpd %xmm1, %xmm2           # (A(i,j), A(i+1,j))
    unpckhpd %xmm1, %xmm0           # (A(i,j+1), A(i+1,j+1))
    movupd %xmm2, (%rdx)            # C(j,   i..i+1)
    movupd %xmm0, (%rdx,%r8)        # C(j+1, i..i+1)
    addq $16, %rax                  # two columns right in A
    leaq (%rdx,%r8,2), %rdx         # two rows down in C
    addq $2, %rbp
    jmp .Lrt_trn_jpair
.Lrt_trn_jlast:
    cmpq %r15, %rbp
    jae .Lrt_trn_inext
    movq (%rax), %rcx               # C(j, i) = A(i, j)
    movq %rcx, (%rdx)
    movq (%rax,%r9), %rcx           # C(j, i+1) = A(i+1, j)
    movq %rcx, 8(%rdx)
.Lrt_trn_inext:
    addq $2, %rbx
    jmp .Lrt_trn_ipair
.Lrt_trn_irow:
    # odd last row of the block: element by element
    cmpq %r14, %rbx
    jae .Lrt_trn_jnext
    movq %rbx, %rax
    imulq %r9, %rax
    addq %rsi, %rax
    leaq (%rax,%r13,8), %rax        # &A(i, jb)
    movq %r13, %rdx
    imulq %r8, %rdx
    addq %rdi, %rdx
    leaq (%rdx,%rbx,8), %rdx        # &C(jb, i)
    movq %r13, %rbp
1:
    movq (%rax), %rcx
    movq %rcx, (%rdx)
    addq $8, %rax
    addq %r8, %rdx
    addq $1, %rbp
    cmpq %r15, %rbp
    jb 1b
.Lrt_trn_jnext:
    movq %r15, %r13                 # jb = je
    cmpq %r11, %r13
    jb .Lrt_trn_jblk
    movq %r14, %r12                 # ib = ie
    cmpq %r10, %r12
    jb .Lrt_trn_iblk
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    popq %rbx
    ret
    .size bsk_rt_ksse2_trn, . - bsk_rt_ksse2_trn

    .section .note.GNU-stack,"",@progbits
