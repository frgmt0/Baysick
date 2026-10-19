# =====================================================================
# src/runtime_x86_64_linux/rt_kavx2_elem.s -- AVX copy/fill and finite-check
# kernels of the "avx2" variant (docs/DESIGN.md 6.6.1, 6.6.5, 6.6.7).
# Reached only through the variant table, whose record requires
# KF_X64_AVX2 | KF_X64_FMA (OS YMM state included).
#
# Defines (private to the runtime, .globl + .hidden):
#   bsk_rt_kavx2_copy   C = A
#   bsk_rt_kavx2_fill   C(i,j) = v
#   bsk_rt_kavx2_chkfin %rax = KS_NONFINITE if any element of a view is
#                       not finite, else KS_OK (used by GEMM and INV)
#
# Class E (DESIGN.md 6.6.4): pure copies and stores, so bit-identical to
# the "sse2" kernels. Add, sub and scale are not specialised here: the
# variant table points them at the sse2 kernels because Haswell lowers
# the core clock while 256-bit FP arithmetic runs (DESIGN.md 6.6.3).
# Loops: rows x contiguous columns, 4 four-wide vectors per iteration,
# then single four-wide vectors, then one two-wide vector, then a
# scalar tail. All loads/stores are unaligned forms (vmovupd).
#
# Finite check (bsk_rt_kavx2_chkfin): for each vector r, t = r - r is
# +0 in every lane when r is finite and NaN otherwise; t is OR-ed into
# the accumulator %ymm7, whose bits stay all zero exactly when every
# element is finite. The witness is always formed with 256-bit
# operations: a VEX.128 result has zero upper lanes (0 - 0 = +0), and a
# VEX.128 OR into %ymm7 would clear its upper half.
#
# Views are MV_* records (runtime.inc). Shared loop registers: %rdi/%rsi =
# current row of C/A, %r8/%r9 = row strides in bytes, %r11 = columns,
# %rcx = rows left, %rax = column index, %r10 = loop bound.
# Every function ends with vzeroupper (DESIGN.md 6.6.7).
# =====================================================================
.include "baysick.inc"

    .text

# RT_KAVX2_FIN r, t -- OR the finiteness witness of ymm \r into %ymm7.
.macro RT_KAVX2_FIN r, t
    vsubpd \r, \r, \t               # +0 if finite, NaN if inf/NaN
    vorpd \t, %ymm7, %ymm7
.endm

# RT_KAVX2_STATUS -- %rax = KS_OK if %ymm7 is all zero bits, else
#   KS_NONFINITE. Clobbers %xmm6, %rcx.
.macro RT_KAVX2_STATUS
    vextractf128 $1, %ymm7, %xmm6   # upper two lanes
    vorpd %xmm6, %xmm7, %xmm7       # OR into the lower two
    vunpckhpd %xmm7, %xmm7, %xmm6   # lane 1 down
    vorpd %xmm6, %xmm7, %xmm7       # OR of all four in lane 0
    vmovq %xmm7, %rcx
    xorl %eax, %eax                 # KS_OK
    testq %rcx, %rcx
    setnz %al                       # KS_NONFINITE (= 1) if any bit set
.endm

# RT_KAVX2_PROLOG2 -- load C (%rdi) and A (%rsi) views into the loop
#   registers (rows, cols, strides, data pointers).
.macro RT_KAVX2_PROLOG2
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
# bsk_rt_kavx2_copy -- C = A (exact copies).
#   Inputs  : %rdi = C view, %rsi = A view (same shape, no overlap)
#   Outputs : none
#   Clobbers: %rax %rcx %rsi %rdi %r8-%r11 %ymm0-%ymm3 (upper state
#             clean on exit)
#   Callee-saved used: none
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_rt_kavx2_copy
    .hidden bsk_rt_kavx2_copy
    .type bsk_rt_kavx2_copy, @function
    .p2align 4
bsk_rt_kavx2_copy:
    RT_KAVX2_PROLOG2
.Lrt_kavx2_copy_row:
    xorl %eax, %eax
    movq %r11, %r10
    andq $-16, %r10
    jz .Lrt_kavx2_copy_v1
.Lrt_kavx2_copy_v4:
    vmovupd (%rsi,%rax,8), %ymm0    # bit patterns move unchanged
    vmovupd 32(%rsi,%rax,8), %ymm1
    vmovupd 64(%rsi,%rax,8), %ymm2
    vmovupd 96(%rsi,%rax,8), %ymm3
    vmovupd %ymm0, (%rdi,%rax,8)
    vmovupd %ymm1, 32(%rdi,%rax,8)
    vmovupd %ymm2, 64(%rdi,%rax,8)
    vmovupd %ymm3, 96(%rdi,%rax,8)
    addq $16, %rax
    cmpq %r10, %rax
    jb .Lrt_kavx2_copy_v4
.Lrt_kavx2_copy_v1:
    leaq 4(%rax), %r10
    cmpq %r11, %r10
    ja .Lrt_kavx2_copy_v2
    vmovupd (%rsi,%rax,8), %ymm0
    vmovupd %ymm0, (%rdi,%rax,8)
    addq $4, %rax
    jmp .Lrt_kavx2_copy_v1
.Lrt_kavx2_copy_v2:
    leaq 2(%rax), %r10
    cmpq %r11, %r10
    ja .Lrt_kavx2_copy_s
    vmovupd (%rsi,%rax,8), %xmm0
    vmovupd %xmm0, (%rdi,%rax,8)
    addq $2, %rax
.Lrt_kavx2_copy_s:
    cmpq %r11, %rax
    jae .Lrt_kavx2_copy_rowend
    movq (%rsi,%rax,8), %r10        # integer move: exact bits
    movq %r10, (%rdi,%rax,8)
.Lrt_kavx2_copy_rowend:
    addq %r8, %rdi
    addq %r9, %rsi
    subq $1, %rcx
    jnz .Lrt_kavx2_copy_row
    vzeroupper
    ret
    .size bsk_rt_kavx2_copy, . - bsk_rt_kavx2_copy

# ---------------------------------------------------------------------
# bsk_rt_kavx2_fill -- every element of C := v.
#   Inputs  : %rdi = C view, %xmm0 = v
#   Outputs : none
#   Clobbers: %rax %rcx %rdi %r8 %r10 %r11 %ymm0 (upper state clean on
#             exit)
#   Callee-saved used: none
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_rt_kavx2_fill
    .hidden bsk_rt_kavx2_fill
    .type bsk_rt_kavx2_fill, @function
    .p2align 4
bsk_rt_kavx2_fill:
    vbroadcastsd %xmm0, %ymm0       # (v, v, v, v)
    movq MV_ROWS(%rdi), %rcx
    movq MV_COLS(%rdi), %r11
    movq MV_LD(%rdi), %r8
    shlq $3, %r8
    movq MV_DATA(%rdi), %rdi
.Lrt_kavx2_fill_row:
    xorl %eax, %eax
    movq %r11, %r10
    andq $-16, %r10
    jz .Lrt_kavx2_fill_v1
.Lrt_kavx2_fill_v4:
    vmovupd %ymm0, (%rdi,%rax,8)
    vmovupd %ymm0, 32(%rdi,%rax,8)
    vmovupd %ymm0, 64(%rdi,%rax,8)
    vmovupd %ymm0, 96(%rdi,%rax,8)
    addq $16, %rax
    cmpq %r10, %rax
    jb .Lrt_kavx2_fill_v4
.Lrt_kavx2_fill_v1:
    leaq 4(%rax), %r10
    cmpq %r11, %r10
    ja .Lrt_kavx2_fill_v2
    vmovupd %ymm0, (%rdi,%rax,8)
    addq $4, %rax
    jmp .Lrt_kavx2_fill_v1
.Lrt_kavx2_fill_v2:
    leaq 2(%rax), %r10
    cmpq %r11, %r10
    ja .Lrt_kavx2_fill_s
    vmovupd %xmm0, (%rdi,%rax,8)
    addq $2, %rax
.Lrt_kavx2_fill_s:
    cmpq %r11, %rax
    jae .Lrt_kavx2_fill_rowend
    vmovsd %xmm0, (%rdi,%rax,8)
.Lrt_kavx2_fill_rowend:
    addq %r8, %rdi
    subq $1, %rcx
    jnz .Lrt_kavx2_fill_row
    vzeroupper
    ret
    .size bsk_rt_kavx2_fill, . - bsk_rt_kavx2_fill

# ---------------------------------------------------------------------
# bsk_rt_kavx2_chkfin -- finiteness of every element of a view.
#   Inputs  : %rdi = view
#   Outputs : %rax = KS_OK if all elements are finite, else KS_NONFINITE
#   Clobbers: %rax %rcx %rdi %r8 %r10 %r11 %ymm0-%ymm7 (upper state
#             clean on exit)
#   Callee-saved used: none
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_rt_kavx2_chkfin
    .hidden bsk_rt_kavx2_chkfin
    .type bsk_rt_kavx2_chkfin, @function
    .p2align 4
bsk_rt_kavx2_chkfin:
    movq MV_ROWS(%rdi), %rcx
    movq MV_COLS(%rdi), %r11
    movq MV_LD(%rdi), %r8
    shlq $3, %r8
    movq MV_DATA(%rdi), %rdi
    vxorpd %ymm7, %ymm7, %ymm7
.Lrt_kavx2_chkfin_row:
    xorl %eax, %eax
    movq %r11, %r10
    andq $-16, %r10
    jz .Lrt_kavx2_chkfin_v1
.Lrt_kavx2_chkfin_v4:
    vmovupd (%rdi,%rax,8), %ymm0
    vmovupd 32(%rdi,%rax,8), %ymm1
    vmovupd 64(%rdi,%rax,8), %ymm2
    vmovupd 96(%rdi,%rax,8), %ymm3
    RT_KAVX2_FIN %ymm0, %ymm4
    RT_KAVX2_FIN %ymm1, %ymm5
    RT_KAVX2_FIN %ymm2, %ymm4
    RT_KAVX2_FIN %ymm3, %ymm5
    addq $16, %rax
    cmpq %r10, %rax
    jb .Lrt_kavx2_chkfin_v4
.Lrt_kavx2_chkfin_v1:
    leaq 4(%rax), %r10
    cmpq %r11, %r10
    ja .Lrt_kavx2_chkfin_v2
    vmovupd (%rdi,%rax,8), %ymm0
    RT_KAVX2_FIN %ymm0, %ymm4
    addq $4, %rax
    jmp .Lrt_kavx2_chkfin_v1
.Lrt_kavx2_chkfin_v2:
    leaq 2(%rax), %r10
    cmpq %r11, %r10
    ja .Lrt_kavx2_chkfin_s
    vmovupd (%rdi,%rax,8), %xmm0    # upper lanes zeroed
    RT_KAVX2_FIN %ymm0, %ymm4
    addq $2, %rax
.Lrt_kavx2_chkfin_s:
    cmpq %r11, %rax
    jae .Lrt_kavx2_chkfin_rowend
    vmovsd (%rdi,%rax,8), %xmm0     # upper lanes zeroed
    RT_KAVX2_FIN %ymm0, %ymm4
.Lrt_kavx2_chkfin_rowend:
    addq %r8, %rdi
    subq $1, %rcx
    jnz .Lrt_kavx2_chkfin_row
    RT_KAVX2_STATUS
    vzeroupper
    ret
    .size bsk_rt_kavx2_chkfin, . - bsk_rt_kavx2_chkfin

    .section .note.GNU-stack,"",@progbits
