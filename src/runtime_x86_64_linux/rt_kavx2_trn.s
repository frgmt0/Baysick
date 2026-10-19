# =====================================================================
# src/runtime_x86_64_linux/rt_kavx2_trn.s -- AVX blocked transpose of
# the "avx2" variant (docs/DESIGN.md 6.6.1, 6.6.5, 6.6.7). Reached only
# through the variant table, whose record requires KF_X64_AVX2 |
# KF_X64_FMA (OS YMM state included).
#
# Defines (private to the runtime, .globl + .hidden):
#   bsk_rt_kavx2_trn    C = transpose of A  (A m x n, C n x m)
#
# Class E: exact copies only (bit patterns move through registers by
# loads, vinsertf128, vunpcklpd/vunpckhpd and stores; no arithmetic),
# so the result is bit-identical to the "sse2" transpose.
#
# Structure: the m x n source is walked in RT_KAVX2_TRN_BLK x
# RT_KAVX2_TRN_BLK blocks (both blocks of A and C then stay in L1);
# inside a block, 4 x 4 tiles are transposed in registers. The 128-bit
# halves are gathered by the loads (vinsertf128 from memory, which uses
# a load port instead of the single shuffle port), so one in-lane
# unpack per output row finishes the tile:
#     y0 = (A(i,j),   A(i,j+1)   | A(i+2,j),   A(i+2,j+1))
#     y1 = (A(i+1,j), A(i+1,j+1) | A(i+3,j),   A(i+3,j+1))
#     y2 = (A(i,j+2), A(i,j+3)   | A(i+2,j+2), A(i+2,j+3))
#     y3 = (A(i+1,j+2),A(i+1,j+3)| A(i+3,j+2), A(i+3,j+3))
#     vunpcklpd y0,y1 -> C(j,   i..i+3)    vunpckhpd y0,y1 -> C(j+1, ..)
#     vunpcklpd y2,y3 -> C(j+2, i..i+3)    vunpckhpd y2,y3 -> C(j+3, ..)
# The last 1..3 columns of a 4-row strip and the last 1..3 rows of a
# block are copied element by element. Ends with vzeroupper.
# =====================================================================
.include "baysick.inc"

.equ RT_KAVX2_TRN_BLK, 32           # block edge in elements (multiple of 4)

    .text

# ---------------------------------------------------------------------
# bsk_rt_kavx2_trn
#   Inputs  : %rdi = C view (n x m), %rsi = A view (m x n); no overlap
#   Outputs : none
#   Clobbers: %rax %rcx %rdx %rsi %rdi %r8-%r11 %ymm0-%ymm7 (upper state
#             clean on exit)
#   Callee-saved used: %rbx = i, %r12 = ib, %r13 = jb, %r14 = ie,
#             %r15 = je, %rbp = j (all saved/restored)
#   Frame   : 48 bytes (six saved registers); leaf
#   Other registers: %rdi = C data, %rsi = A data, %r8 = C stride
#             bytes, %r9 = A stride bytes, %r10 = m, %r11 = n,
#             %rax = &A(i,j), %rdx = &C(j,i), %rcx = scratch
# ---------------------------------------------------------------------
    .globl bsk_rt_kavx2_trn
    .hidden bsk_rt_kavx2_trn
    .type bsk_rt_kavx2_trn, @function
    .p2align 4
bsk_rt_kavx2_trn:
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
.Lrt_kavx2_trn_iblk:
    leaq RT_KAVX2_TRN_BLK(%r12), %r14   # ie = min(ib + BLK, m)
    cmpq %r10, %r14
    cmova %r10, %r14
    xorl %r13d, %r13d               # jb = 0
.Lrt_kavx2_trn_jblk:
    leaq RT_KAVX2_TRN_BLK(%r13), %r15   # je = min(jb + BLK, n)
    cmpq %r11, %r15
    cmova %r11, %r15
    movq %r12, %rbx                 # i = ib
.Lrt_kavx2_trn_iquad:
    leaq 4(%rbx), %rcx
    cmpq %r14, %rcx
    ja .Lrt_kavx2_trn_irow          # fewer than four rows left
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
.Lrt_kavx2_trn_jquad:
    leaq 4(%rbp), %rcx
    cmpq %r15, %rcx
    ja .Lrt_kavx2_trn_jlast         # fewer than four columns left
    leaq (%rax,%r9,2), %rcx         # &A(i+2, j)
    vmovupd (%rax), %xmm0           # A(i,   j..j+1)
    vinsertf128 $1, (%rcx), %ymm0, %ymm0            # | A(i+2, j..j+1)
    vmovupd (%rax,%r9), %xmm1       # A(i+1, j..j+1)
    vinsertf128 $1, (%rcx,%r9), %ymm1, %ymm1        # | A(i+3, j..j+1)
    vmovupd 16(%rax), %xmm2         # A(i,   j+2..j+3)
    vinsertf128 $1, 16(%rcx), %ymm2, %ymm2          # | A(i+2, j+2..j+3)
    vmovupd 16(%rax,%r9), %xmm3     # A(i+1, j+2..j+3)
    vinsertf128 $1, 16(%rcx,%r9), %ymm3, %ymm3      # | A(i+3, j+2..j+3)
    vunpcklpd %ymm1, %ymm0, %ymm4   # C(j,   i..i+3)
    vunpckhpd %ymm1, %ymm0, %ymm5   # C(j+1, i..i+3)
    vunpcklpd %ymm3, %ymm2, %ymm6   # C(j+2, i..i+3)
    vunpckhpd %ymm3, %ymm2, %ymm7   # C(j+3, i..i+3)
    leaq (%rdx,%r8,2), %rcx         # &C(j+2, i)
    vmovupd %ymm4, (%rdx)
    vmovupd %ymm5, (%rdx,%r8)
    vmovupd %ymm6, (%rcx)
    vmovupd %ymm7, (%rcx,%r8)
    addq $32, %rax                  # four columns right in A
    leaq (%rdx,%r8,4), %rdx         # four rows down in C
    addq $4, %rbp
    jmp .Lrt_kavx2_trn_jquad
.Lrt_kavx2_trn_jlast:
    # last 0..3 columns of the strip: C(j, i..i+3) = A(i..i+3, j)
    cmpq %r15, %rbp
    jae .Lrt_kavx2_trn_inext
    # (vmovsd moves the 64-bit pattern unchanged; no arithmetic)
    leaq (%rax,%r9,2), %rcx         # &A(i+2, j)
    vmovsd (%rax), %xmm0            # A(i,   j)
    vmovsd (%rax,%r9), %xmm1        # A(i+1, j)
    vmovsd (%rcx), %xmm2            # A(i+2, j)
    vmovsd (%rcx,%r9), %xmm3        # A(i+3, j)
    vmovsd %xmm0, (%rdx)            # C(j, i .. i+3)
    vmovsd %xmm1, 8(%rdx)
    vmovsd %xmm2, 16(%rdx)
    vmovsd %xmm3, 24(%rdx)
    addq $8, %rax                   # next column of A
    addq %r8, %rdx                  # next row of C
    addq $1, %rbp
    jmp .Lrt_kavx2_trn_jlast
.Lrt_kavx2_trn_inext:
    addq $4, %rbx
    jmp .Lrt_kavx2_trn_iquad
.Lrt_kavx2_trn_irow:
    # last 0..3 rows of the block: element by element
    cmpq %r14, %rbx
    jae .Lrt_kavx2_trn_jnext
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
    addq $1, %rbx
    jmp .Lrt_kavx2_trn_irow
.Lrt_kavx2_trn_jnext:
    movq %r15, %r13                 # jb = je
    cmpq %r11, %r13
    jb .Lrt_kavx2_trn_jblk
    movq %r14, %r12                 # ib = ie
    cmpq %r10, %r12
    jb .Lrt_kavx2_trn_iblk
    vzeroupper
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    popq %rbx
    ret
    .size bsk_rt_kavx2_trn, . - bsk_rt_kavx2_trn

    .section .note.GNU-stack,"",@progbits
