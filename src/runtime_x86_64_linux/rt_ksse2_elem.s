# =====================================================================
# src/runtime_x86_64_linux/rt_ksse2_elem.s -- SSE2 element-wise matrix
# kernels of the "sse2" variant (docs/DESIGN.md 6.6.1, 6.6.5).
#
# Defines (private to the runtime, .globl + .hidden):
#   bsk_rt_ksse2_add    C = A + B       -> %rax KS_*
#   bsk_rt_ksse2_sub    C = A - B       -> %rax KS_*
#   bsk_rt_ksse2_scale  C = k * A       -> %rax KS_*
#   bsk_rt_ksse2_copy   C = A
#   bsk_rt_ksse2_fill   C(i,j) = v
#   bsk_rt_ksse2_chkfin %rax = KS_NONFINITE if any element of a view is
#                       not finite, else KS_OK (used by GEMM and INV)
#
# Class E (DESIGN.md 6.6.4): exactly one IEEE operation per element
# (the lanes of addpd/subpd/mulpd are independent roundings), so the
# result is bit-identical to any other variant. Loops: rows x
# contiguous columns, 4 two-wide vectors per iteration, then single
# vectors, then a scalar tail. All loads/stores are unaligned forms
# (movupd), so alignment never decides a value.
#
# Fused finite check: for each result vector r, t = r - r is +0 in
# both lanes when r is finite and NaN otherwise; t is OR-ed into the
# accumulator %xmm7, whose bits stay all zero exactly when every stored
# element is finite.
#
# Views are MV_* records (runtime.inc); all have the shape of C.
# Shared loop registers: %rdi/%rsi/%rdx = current row of C/A/B,
# %r8/%r9/%rbx = row strides in bytes, %r11 = columns, %rcx = rows
# left, %rax = column index, %r10 = loop bound.
# =====================================================================
.include "baysick.inc"

    .text

# RT_ELEM_FIN r, t -- OR the finiteness witness of \r into %xmm7.
.macro RT_ELEM_FIN r, t
    movapd \r, \t
    subpd \t, \t                    # +0 if finite, NaN if inf/NaN
    orpd \t, %xmm7
.endm

# RT_ELEM_STATUS -- %rax = KS_OK if %xmm7 is all zero bits, else
#   KS_NONFINITE. Clobbers %xmm6, %rcx.
.macro RT_ELEM_STATUS
    movapd %xmm7, %xmm6
    unpckhpd %xmm6, %xmm6           # high lane down
    orpd %xmm6, %xmm7               # OR of both lanes in the low lane
    movq %xmm7, %rcx
    xorl %eax, %eax                 # KS_OK
    testq %rcx, %rcx
    setnz %al                       # KS_NONFINITE (= 1) if any bit set
.endm

# RT_ELEM_PROLOG2 -- load C (%rdi) and A (%rsi) views into the loop
#   registers (rows, cols, strides, data pointers).
.macro RT_ELEM_PROLOG2
    movq MV_ROWS(%rdi), %rcx
    movq MV_COLS(%rdi), %r11
    movq MV_LD(%rdi), %r8
    shlq $3, %r8                    # C stride in bytes
    movq MV_LD(%rsi), %r9
    shlq $3, %r9                    # A stride in bytes
    movq MV_DATA(%rdi), %rdi        # row pointers from here on
    movq MV_DATA(%rsi), %rsi
.endm

# ---------------------------------------------------------------------
# RT_ELEM_BINOP name, lbl, vop, sop -- C = A (op) B, fused finite check
#   (lbl names the local labels .Lrt_elem_<lbl>_*).
#   Inputs  : %rdi = C view, %rsi = A view, %rdx = B view (same shape;
#             C may be A or B exactly)
#   Outputs : %rax = KS_OK / KS_NONFINITE
#   Clobbers: %rcx %rdx %rsi %rdi %r8-%r11 %xmm0-%xmm7
#   Callee-saved used: %rbx = B row stride in bytes (saved/restored)
#   Frame   : 8 bytes (saved %rbx); leaf
# ---------------------------------------------------------------------
.macro RT_ELEM_BINOP name, lbl, vop, sop
    .globl \name
    .hidden \name
    .type \name, @function
    .p2align 4
\name:
    pushq %rbx
    movq MV_LD(%rdx), %rbx
    shlq $3, %rbx                   # B stride in bytes
    movq MV_DATA(%rdx), %rdx        # B row pointer
    RT_ELEM_PROLOG2
    xorpd %xmm7, %xmm7              # finite witness accumulator
.Lrt_elem_\lbl\()_row:
    xorl %eax, %eax                 # j = 0
    movq %r11, %r10
    andq $-8, %r10                  # columns covered by the 4x loop
    jz .Lrt_elem_\lbl\()_v1
.Lrt_elem_\lbl\()_v4:
    # four two-wide vectors: columns j .. j+7; all loads before the
    # stores, so C == A or C == B is safe
    movupd (%rsi,%rax,8), %xmm0
    movupd 16(%rsi,%rax,8), %xmm1
    movupd 32(%rsi,%rax,8), %xmm2
    movupd 48(%rsi,%rax,8), %xmm3
    movupd (%rdx,%rax,8), %xmm4
    \vop %xmm4, %xmm0               # a (op) b, one rounding per lane
    movupd 16(%rdx,%rax,8), %xmm5
    \vop %xmm5, %xmm1
    movupd 32(%rdx,%rax,8), %xmm4
    \vop %xmm4, %xmm2
    movupd 48(%rdx,%rax,8), %xmm5
    \vop %xmm5, %xmm3
    movupd %xmm0, (%rdi,%rax,8)
    movupd %xmm1, 16(%rdi,%rax,8)
    movupd %xmm2, 32(%rdi,%rax,8)
    movupd %xmm3, 48(%rdi,%rax,8)
    RT_ELEM_FIN %xmm0, %xmm4
    RT_ELEM_FIN %xmm1, %xmm5
    RT_ELEM_FIN %xmm2, %xmm4
    RT_ELEM_FIN %xmm3, %xmm5
    addq $8, %rax
    cmpq %r10, %rax
    jb .Lrt_elem_\lbl\()_v4
.Lrt_elem_\lbl\()_v1:
    # single vectors while two columns remain
    leaq 2(%rax), %r10
    cmpq %r11, %r10
    ja .Lrt_elem_\lbl\()_s
    movupd (%rsi,%rax,8), %xmm0
    movupd (%rdx,%rax,8), %xmm4
    \vop %xmm4, %xmm0
    movupd %xmm0, (%rdi,%rax,8)
    RT_ELEM_FIN %xmm0, %xmm4
    addq $2, %rax
    jmp .Lrt_elem_\lbl\()_v1
.Lrt_elem_\lbl\()_s:
    # odd last column
    cmpq %r11, %rax
    jae .Lrt_elem_\lbl\()_rowend
    movsd (%rsi,%rax,8), %xmm0      # upper lane zeroed by the load
    movsd (%rdx,%rax,8), %xmm4
    \sop %xmm4, %xmm0
    movsd %xmm0, (%rdi,%rax,8)
    RT_ELEM_FIN %xmm0, %xmm4        # upper lane: 0 - 0 = +0
.Lrt_elem_\lbl\()_rowend:
    addq %r8, %rdi                  # next rows
    addq %r9, %rsi
    addq %rbx, %rdx
    subq $1, %rcx
    jnz .Lrt_elem_\lbl\()_row
    RT_ELEM_STATUS
    popq %rbx
    ret
    .size \name, . - \name
.endm

    RT_ELEM_BINOP bsk_rt_ksse2_add, add, addpd, addsd
    RT_ELEM_BINOP bsk_rt_ksse2_sub, sub, subpd, subsd

# ---------------------------------------------------------------------
# bsk_rt_ksse2_scale -- C = k * A, fused finite check.
#   Inputs  : %rdi = C view, %rsi = A view (same shape; C may be A
#             exactly), %xmm0 = k
#   Outputs : %rax = KS_OK / KS_NONFINITE
#   Clobbers: %rcx %rsi %rdi %r8-%r11 %xmm0-%xmm8
#   Callee-saved used: none
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_rt_ksse2_scale
    .hidden bsk_rt_ksse2_scale
    .type bsk_rt_ksse2_scale, @function
    .p2align 4
bsk_rt_ksse2_scale:
    movapd %xmm0, %xmm8
    unpcklpd %xmm8, %xmm8           # (k, k)
    RT_ELEM_PROLOG2
    xorpd %xmm7, %xmm7
.Lrt_ksse2_scale_row:
    xorl %eax, %eax
    movq %r11, %r10
    andq $-8, %r10
    jz .Lrt_ksse2_scale_v1
.Lrt_ksse2_scale_v4:
    movupd (%rsi,%rax,8), %xmm0
    movupd 16(%rsi,%rax,8), %xmm1
    movupd 32(%rsi,%rax,8), %xmm2
    movupd 48(%rsi,%rax,8), %xmm3
    mulpd %xmm8, %xmm0              # k * a, one rounding per lane
    mulpd %xmm8, %xmm1
    mulpd %xmm8, %xmm2
    mulpd %xmm8, %xmm3
    movupd %xmm0, (%rdi,%rax,8)
    movupd %xmm1, 16(%rdi,%rax,8)
    movupd %xmm2, 32(%rdi,%rax,8)
    movupd %xmm3, 48(%rdi,%rax,8)
    RT_ELEM_FIN %xmm0, %xmm4
    RT_ELEM_FIN %xmm1, %xmm5
    RT_ELEM_FIN %xmm2, %xmm4
    RT_ELEM_FIN %xmm3, %xmm5
    addq $8, %rax
    cmpq %r10, %rax
    jb .Lrt_ksse2_scale_v4
.Lrt_ksse2_scale_v1:
    leaq 2(%rax), %r10
    cmpq %r11, %r10
    ja .Lrt_ksse2_scale_s
    movupd (%rsi,%rax,8), %xmm0
    mulpd %xmm8, %xmm0
    movupd %xmm0, (%rdi,%rax,8)
    RT_ELEM_FIN %xmm0, %xmm4
    addq $2, %rax
    jmp .Lrt_ksse2_scale_v1
.Lrt_ksse2_scale_s:
    cmpq %r11, %rax
    jae .Lrt_ksse2_scale_rowend
    movsd (%rsi,%rax,8), %xmm0      # upper lane 0; 0 * k = 0 (k finite)
    mulsd %xmm8, %xmm0
    movsd %xmm0, (%rdi,%rax,8)
    RT_ELEM_FIN %xmm0, %xmm4
.Lrt_ksse2_scale_rowend:
    addq %r8, %rdi
    addq %r9, %rsi
    subq $1, %rcx
    jnz .Lrt_ksse2_scale_row
    RT_ELEM_STATUS
    ret
    .size bsk_rt_ksse2_scale, . - bsk_rt_ksse2_scale

# ---------------------------------------------------------------------
# bsk_rt_ksse2_copy -- C = A (exact copies).
#   Inputs  : %rdi = C view, %rsi = A view (same shape, no overlap)
#   Outputs : none
#   Clobbers: %rax %rcx %rsi %rdi %r8-%r11 %xmm0-%xmm3
#   Callee-saved used: none
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_rt_ksse2_copy
    .hidden bsk_rt_ksse2_copy
    .type bsk_rt_ksse2_copy, @function
    .p2align 4
bsk_rt_ksse2_copy:
    RT_ELEM_PROLOG2
.Lrt_ksse2_copy_row:
    xorl %eax, %eax
    movq %r11, %r10
    andq $-8, %r10
    jz .Lrt_ksse2_copy_v1
.Lrt_ksse2_copy_v4:
    movupd (%rsi,%rax,8), %xmm0     # bit patterns move unchanged
    movupd 16(%rsi,%rax,8), %xmm1
    movupd 32(%rsi,%rax,8), %xmm2
    movupd 48(%rsi,%rax,8), %xmm3
    movupd %xmm0, (%rdi,%rax,8)
    movupd %xmm1, 16(%rdi,%rax,8)
    movupd %xmm2, 32(%rdi,%rax,8)
    movupd %xmm3, 48(%rdi,%rax,8)
    addq $8, %rax
    cmpq %r10, %rax
    jb .Lrt_ksse2_copy_v4
.Lrt_ksse2_copy_v1:
    leaq 2(%rax), %r10
    cmpq %r11, %r10
    ja .Lrt_ksse2_copy_s
    movupd (%rsi,%rax,8), %xmm0
    movupd %xmm0, (%rdi,%rax,8)
    addq $2, %rax
    jmp .Lrt_ksse2_copy_v1
.Lrt_ksse2_copy_s:
    cmpq %r11, %rax
    jae .Lrt_ksse2_copy_rowend
    movq (%rsi,%rax,8), %r10        # integer move: exact bits
    movq %r10, (%rdi,%rax,8)
.Lrt_ksse2_copy_rowend:
    addq %r8, %rdi
    addq %r9, %rsi
    subq $1, %rcx
    jnz .Lrt_ksse2_copy_row
    ret
    .size bsk_rt_ksse2_copy, . - bsk_rt_ksse2_copy

# ---------------------------------------------------------------------
# bsk_rt_ksse2_fill -- every element of C := v.
#   Inputs  : %rdi = C view, %xmm0 = v
#   Outputs : none
#   Clobbers: %rax %rcx %rdi %r8 %r10 %r11 %xmm0
#   Callee-saved used: none
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_rt_ksse2_fill
    .hidden bsk_rt_ksse2_fill
    .type bsk_rt_ksse2_fill, @function
    .p2align 4
bsk_rt_ksse2_fill:
    unpcklpd %xmm0, %xmm0           # (v, v)
    movq MV_ROWS(%rdi), %rcx
    movq MV_COLS(%rdi), %r11
    movq MV_LD(%rdi), %r8
    shlq $3, %r8
    movq MV_DATA(%rdi), %rdi
.Lrt_ksse2_fill_row:
    xorl %eax, %eax
    movq %r11, %r10
    andq $-8, %r10
    jz .Lrt_ksse2_fill_v1
.Lrt_ksse2_fill_v4:
    movupd %xmm0, (%rdi,%rax,8)
    movupd %xmm0, 16(%rdi,%rax,8)
    movupd %xmm0, 32(%rdi,%rax,8)
    movupd %xmm0, 48(%rdi,%rax,8)
    addq $8, %rax
    cmpq %r10, %rax
    jb .Lrt_ksse2_fill_v4
.Lrt_ksse2_fill_v1:
    leaq 2(%rax), %r10
    cmpq %r11, %r10
    ja .Lrt_ksse2_fill_s
    movupd %xmm0, (%rdi,%rax,8)
    addq $2, %rax
    jmp .Lrt_ksse2_fill_v1
.Lrt_ksse2_fill_s:
    cmpq %r11, %rax
    jae .Lrt_ksse2_fill_rowend
    movsd %xmm0, (%rdi,%rax,8)
.Lrt_ksse2_fill_rowend:
    addq %r8, %rdi
    subq $1, %rcx
    jnz .Lrt_ksse2_fill_row
    ret
    .size bsk_rt_ksse2_fill, . - bsk_rt_ksse2_fill

# ---------------------------------------------------------------------
# bsk_rt_ksse2_chkfin -- finiteness of every element of a view.
#   Inputs  : %rdi = view
#   Outputs : %rax = KS_OK if all elements are finite, else KS_NONFINITE
#   Clobbers: %rax %rcx %rdi %r8 %r10 %r11 %xmm0-%xmm7
#   Callee-saved used: none
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_rt_ksse2_chkfin
    .hidden bsk_rt_ksse2_chkfin
    .type bsk_rt_ksse2_chkfin, @function
    .p2align 4
bsk_rt_ksse2_chkfin:
    movq MV_ROWS(%rdi), %rcx
    movq MV_COLS(%rdi), %r11
    movq MV_LD(%rdi), %r8
    shlq $3, %r8
    movq MV_DATA(%rdi), %rdi
    xorpd %xmm7, %xmm7
.Lrt_ksse2_chkfin_row:
    xorl %eax, %eax
    movq %r11, %r10
    andq $-8, %r10
    jz .Lrt_ksse2_chkfin_v1
.Lrt_ksse2_chkfin_v4:
    movupd (%rdi,%rax,8), %xmm0
    movupd 16(%rdi,%rax,8), %xmm1
    movupd 32(%rdi,%rax,8), %xmm2
    movupd 48(%rdi,%rax,8), %xmm3
    RT_ELEM_FIN %xmm0, %xmm4
    RT_ELEM_FIN %xmm1, %xmm5
    RT_ELEM_FIN %xmm2, %xmm4
    RT_ELEM_FIN %xmm3, %xmm5
    addq $8, %rax
    cmpq %r10, %rax
    jb .Lrt_ksse2_chkfin_v4
.Lrt_ksse2_chkfin_v1:
    leaq 2(%rax), %r10
    cmpq %r11, %r10
    ja .Lrt_ksse2_chkfin_s
    movupd (%rdi,%rax,8), %xmm0
    RT_ELEM_FIN %xmm0, %xmm4
    addq $2, %rax
    jmp .Lrt_ksse2_chkfin_v1
.Lrt_ksse2_chkfin_s:
    cmpq %r11, %rax
    jae .Lrt_ksse2_chkfin_rowend
    movsd (%rdi,%rax,8), %xmm0      # upper lane zeroed
    RT_ELEM_FIN %xmm0, %xmm4
.Lrt_ksse2_chkfin_rowend:
    addq %r8, %rdi
    subq $1, %rcx
    jnz .Lrt_ksse2_chkfin_row
    RT_ELEM_STATUS
    ret
    .size bsk_rt_ksse2_chkfin, . - bsk_rt_ksse2_chkfin

    .section .note.GNU-stack,"",@progbits
