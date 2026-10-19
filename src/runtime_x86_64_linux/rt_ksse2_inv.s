# =====================================================================
# src/runtime_x86_64_linux/rt_ksse2_inv.s -- pinned Gauss-Jordan
# inverse of the "sse2" variant (docs/LANGUAGE.md 7.14.6,
# docs/DESIGN.md 6.6.1, 6.6.5).
#
# Defines (private to the runtime, .globl + .hidden):
#   bsk_rt_ksse2_inv    X = inverse of A -> %rax KS_OK / KS_SINGULAR /
#                       KS_NONFINITE
#
# The pinned algorithm (0-based; LANGUAGE.md 7.14.6):
#   m := max |A(i,j)|;  tol := (n * 2^-52) * m;  W := A;  X := I
#   for p = 0 .. n-1:
#     r := p; best := |W(p,p)|
#     for i = p+1 .. n-1: if |W(i,p)| > best: r := i; best := |W(i,p)|
#     if best <= tol: SINGULAR
#     if r != p: swap rows p, r of W and of X
#     d := W(p,p); if d is not finite: NONFINITE
#     W(p,j) /= d (j > p);  X(p,j) /= d (all j)
#     for i != p: f := W(i,p); W(i,j) -= f*W(p,j) (j > p);
#                 X(i,j) -= f*X(p,j) (all j)
#   NONFINITE if any element of X is not finite.
#
# Schedule: delayed updates in panels of RT_INV_NB pivot columns
# (p0 <= p < pe). Every element still receives exactly the same IEEE
# operations in the same order as above (one rounded product, then one
# rounded subtraction; true divisions; nothing skipped), so the result
# is bit-identical to the plain loop -- only the order in which
# DIFFERENT elements are processed changes:
#   * panel columns (p0 .. pe-1) of W are updated eagerly at every step,
#     so the pivot search and the multipliers f = W(i,p) are always
#     current; a multiplier stays stored at W(i,p) (column p is never
#     written after step p);
#   * the trailing part T = (W columns pe .. n-1, all of X) of a row is
#     updated late: the pivot row p is brought up to date (steps
#     p0 .. p-1, multipliers W(p,q)) just before its division;
#     after the panel every non-pivot row applies steps p0 .. pe-1
#     (register-blocked 4 x 6 micro-kernel, 12 accumulators), then each
#     panel pivot row i applies the steps after its own (i+1 .. pe-1),
#     in increasing i, so every step reads its pivot row's values as of
#     that step;
#   * a row exchange moves the whole row (W columns p0 .. n-1 including
#     the stored multipliers, all of X), so pending updates travel with
#     their row.
# Comparisons: "|W(i,p)| > best" and "best <= tol" are false for NaN
# (ucomisd + ja / jae).
# =====================================================================
.include "baysick.inc"

.equ RT_INV_INF_BITS, 0x7FF0000000000000    # |x| bits >= this: inf/NaN
.equ RT_INV_ULP_BITS, (1023 - RT_INV_TOL_SHIFT) << 52   # 2^-52
.ifndef RT_INV_NB
.equ RT_INV_NB, 16                  # panel width (measured best 16-24 on Haswell)
.endif

# Frame of bsk_rt_ksse2_inv (offsets from %rsp)
.equ RT_INV_WVIEW, 0                # MV_SIZE bytes: view of W
.equ RT_INV_TOL,   32               # double tol
.equ RT_INV_XVIEW, 40               # ptr: the X view argument
.equ RT_INV_P0,    48               # first pivot column of the panel
.equ RT_INV_PE,    56               # end of the panel (exclusive)
.equ RT_INV_WLD,   64               # W row stride in bytes (8 n)
.equ RT_INV_I,     72               # row index in the trailing phase
.equ RT_INV_RHI,   80               # end of the current row range
.equ RT_INV_BC,    88               # pe - p0
.equ RT_INV_FRAME, 104

    .text

# ---------------------------------------------------------------------
# .Lrt_inv_axpy -- dst(j) := dst(j) - f * src(j), j = 0 .. count-1.
#   Private convention (leaf):
#   Inputs  : %rdi = dst, %rsi = src, %rdx = count (may be 0),
#             %xmm0 = (f, f)
#   Clobbers: %rax %rcx %xmm1-%xmm4 (preserves every other register)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_inv_axpy:
    xorl %eax, %eax                 # j
    movq %rdx, %rcx
    andq $-8, %rcx                  # end of the 4-vector part
    jz .Lrt_inv_axpy_v1
.Lrt_inv_axpy_v4:
    movupd (%rsi,%rax,8), %xmm1
    mulpd %xmm0, %xmm1              # f * src, rounded
    movupd (%rdi,%rax,8), %xmm2
    subpd %xmm1, %xmm2              # dst - product, rounded
    movupd %xmm2, (%rdi,%rax,8)
    movupd 16(%rsi,%rax,8), %xmm3
    mulpd %xmm0, %xmm3
    movupd 16(%rdi,%rax,8), %xmm4
    subpd %xmm3, %xmm4
    movupd %xmm4, 16(%rdi,%rax,8)
    movupd 32(%rsi,%rax,8), %xmm1
    mulpd %xmm0, %xmm1
    movupd 32(%rdi,%rax,8), %xmm2
    subpd %xmm1, %xmm2
    movupd %xmm2, 32(%rdi,%rax,8)
    movupd 48(%rsi,%rax,8), %xmm3
    mulpd %xmm0, %xmm3
    movupd 48(%rdi,%rax,8), %xmm4
    subpd %xmm3, %xmm4
    movupd %xmm4, 48(%rdi,%rax,8)
    addq $8, %rax
    cmpq %rcx, %rax
    jb .Lrt_inv_axpy_v4
.Lrt_inv_axpy_v1:
    leaq 2(%rax), %rcx
    cmpq %rdx, %rcx
    ja .Lrt_inv_axpy_s
    movupd (%rsi,%rax,8), %xmm1
    mulpd %xmm0, %xmm1
    movupd (%rdi,%rax,8), %xmm2
    subpd %xmm1, %xmm2
    movupd %xmm2, (%rdi,%rax,8)
    addq $2, %rax
    jmp .Lrt_inv_axpy_v1
.Lrt_inv_axpy_s:
    cmpq %rdx, %rax
    jae 1f
    movsd (%rsi,%rax,8), %xmm1
    mulsd %xmm0, %xmm1
    movsd (%rdi,%rax,8), %xmm2
    subsd %xmm1, %xmm2
    movsd %xmm2, (%rdi,%rax,8)
1:
    ret

# ---------------------------------------------------------------------
# .Lrt_inv_divrow -- row(j) := row(j) / d, j = 0 .. count-1.
#   Private convention (leaf):
#   Inputs  : %rdi = row, %rdx = count (may be 0), %xmm0 = (d, d)
#   Clobbers: %rax %rcx %xmm1 %xmm2
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_inv_divrow:
    xorl %eax, %eax
.Lrt_inv_divrow_v1:
    leaq 2(%rax), %rcx
    cmpq %rdx, %rcx
    ja .Lrt_inv_divrow_s
    movupd (%rdi,%rax,8), %xmm1
    divpd %xmm0, %xmm1              # true division per lane
    movupd %xmm1, (%rdi,%rax,8)
    addq $2, %rax
    jmp .Lrt_inv_divrow_v1
.Lrt_inv_divrow_s:
    cmpq %rdx, %rax
    jae 1f
    movsd (%rdi,%rax,8), %xmm1
    divsd %xmm0, %xmm1
    movsd %xmm1, (%rdi,%rax,8)
1:
    ret

# ---------------------------------------------------------------------
# .Lrt_inv_swap -- exchange count doubles between two rows.
#   Private convention (leaf):
#   Inputs  : %rdi, %rsi = rows, %rdx = count (>= 1)
#   Clobbers: %rax %rcx %xmm1 %xmm2
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_inv_swap:
    xorl %eax, %eax
.Lrt_inv_swap_v1:
    leaq 2(%rax), %rcx
    cmpq %rdx, %rcx
    ja .Lrt_inv_swap_s
    movupd (%rdi,%rax,8), %xmm1
    movupd (%rsi,%rax,8), %xmm2
    movupd %xmm2, (%rdi,%rax,8)
    movupd %xmm1, (%rsi,%rax,8)
    addq $2, %rax
    jmp .Lrt_inv_swap_v1
.Lrt_inv_swap_s:
    cmpq %rdx, %rax
    jae 1f
    movsd (%rdi,%rax,8), %xmm1
    movsd (%rsi,%rax,8), %xmm2
    movsd %xmm2, (%rdi,%rax,8)
    movsd %xmm1, (%rsi,%rax,8)
1:
    ret

# ---------------------------------------------------------------------
# .Lrt_inv_seq -- delayed steps applied row by row (any width).
#   For r = 0 .. rows-1, q = 0 .. nq-1 (in that order):
#     T(r, 0..count-1) -= M(r, q) * P(q, 0..count-1)
#   where T(r, .) = dst + r*ld, P(q, .) = src + q*ld (pivot rows of the
#   same region), M(r, q) = mult[r*mld + 8q] (the stored multipliers).
#   Private convention:
#   Inputs  : %rdi = dst, %rsi = src, %rdx = count, %rcx = ld (bytes),
#             %r8 = mult, %r9 = nq, %r10 = rows (>= 1), %r11 = mld
#             (bytes); count = 0 or nq = 0 do nothing
#   Clobbers: %rax %rcx %rsi %rdi %r8 %r10 %xmm0-%xmm4
#   Callee-saved used: %rbx = ld, %rbp = src, %r12 = rows left,
#             %r13 = dst row, %r14 = multiplier row, %r15 = q
#   Frame   : 48 bytes (six saved registers); calls only the leaf
#             .Lrt_inv_axpy
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_inv_seq:
    testq %rdx, %rdx
    jz 3f
    testq %r9, %r9
    jz 3f
    pushq %rbx
    pushq %rbp
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    movq %rcx, %rbx
    movq %rsi, %rbp
    movq %r10, %r12
    movq %rdi, %r13
    movq %r8, %r14
.Lrt_inv_seq_row:
    xorl %r15d, %r15d               # q = 0
    movq %rbp, %rsi                 # P(0, .)
.Lrt_inv_seq_q:
    movsd (%r14,%r15,8), %xmm0
    unpcklpd %xmm0, %xmm0           # (f, f) = M(r, q)
    movq %r13, %rdi
    call .Lrt_inv_axpy              # keeps %rsi %rdx %r8-%r11
    addq %rbx, %rsi                 # next pivot row
    addq $1, %r15
    cmpq %r9, %r15
    jb .Lrt_inv_seq_q
    addq %rbx, %r13                 # next destination row
    addq %r11, %r14                 # its multipliers
    subq $1, %r12
    jnz .Lrt_inv_seq_row
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    popq %rbx
3:
    ret

# ---------------------------------------------------------------------
# .Lrt_inv_packf -- pack the multipliers of 4 rows for the micro-kernel:
#   Fbuf[q] = (M0,M0, M1,M1, M2,M2, M3,M3) with Mr = W(i+r, p0+q).
#   Private convention (leaf):
#   Inputs  : %rdi = &W(i, p0), %rsi = W stride (bytes), %rdx = nq
#   Clobbers: %rax %rcx %r8 %r9 %xmm0
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_inv_packf:
    leaq .Lrt_inv_fbuf(%rip), %r8
    xorl %ecx, %ecx                 # r
.Lrt_inv_packf_r:
    xorl %eax, %eax                 # q
1:
    movsd (%rdi,%rax,8), %xmm0
    unpcklpd %xmm0, %xmm0
    movq %rax, %r9
    shlq $6, %r9                    # q * 64
    movapd %xmm0, (%r8,%r9)
    addq $1, %rax
    cmpq %rdx, %rax
    jb 1b
    addq %rsi, %rdi                 # next row
    addq $16, %r8                   # its lane pair
    addq $1, %rcx
    cmpq $4, %rcx
    jb .Lrt_inv_packf_r
    ret

# RT_INV_MK_ROW aoff, c0, c1, c2 -- one tile row for one step:
#   c_k -= (M, M) * y_k   (product rounded, then the subtraction)
.macro RT_INV_MK_ROW aoff, c0, c1, c2
    movapd \aoff(%rdi), %xmm15
    mulpd %xmm12, %xmm15
    subpd %xmm15, \c0
    movapd \aoff(%rdi), %xmm15
    mulpd %xmm13, %xmm15
    subpd %xmm15, \c1
    movapd \aoff(%rdi), %xmm15
    mulpd %xmm14, %xmm15
    subpd %xmm15, \c2
.endm

# RT_INV_MK_IO rowreg, c0, c1, c2, load -- load (load = 1) or store
#   (load = 0) one tile row at (rowreg) with movupd
.macro RT_INV_MK_IO rowreg, c0, c1, c2, load
.if \load
    movupd (\rowreg), \c0
    movupd 16(\rowreg), \c1
    movupd 32(\rowreg), \c2
.else
    movupd \c0, (\rowreg)
    movupd \c1, 16(\rowreg)
    movupd \c2, 32(\rowreg)
.endif
.endm

# ---------------------------------------------------------------------
# .Lrt_inv_mk -- 4 x 6 register-blocked delayed update.
#   T(i+r, j..j+5) -= M(r, q) * P(q, j..j+5) for q = 0 .. nq-1 in order,
#   the tile held in %xmm0-%xmm11 for the whole q loop.
#   Private convention (leaf):
#   Inputs  : %rdi = Fbuf (packed multipliers), %rsi = &P(0, j),
#             %rdx = ld (bytes), %rcx = nq (>= 1), %r8 = &T(i, j)
#   Clobbers: %rax %rcx %rsi %rdi %xmm0-%xmm15
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_inv_mk:
    movq %r8, %rax
    RT_INV_MK_IO %rax, %xmm0, %xmm1, %xmm2, 1
    addq %rdx, %rax
    RT_INV_MK_IO %rax, %xmm3, %xmm4, %xmm5, 1
    addq %rdx, %rax
    RT_INV_MK_IO %rax, %xmm6, %xmm7, %xmm8, 1
    addq %rdx, %rax
    RT_INV_MK_IO %rax, %xmm9, %xmm10, %xmm11, 1
.Lrt_inv_mk_q:
    movupd (%rsi), %xmm12           # pivot row q, six columns
    movupd 16(%rsi), %xmm13
    movupd 32(%rsi), %xmm14
    RT_INV_MK_ROW 0,  %xmm0, %xmm1,  %xmm2
    RT_INV_MK_ROW 16, %xmm3, %xmm4,  %xmm5
    RT_INV_MK_ROW 32, %xmm6, %xmm7,  %xmm8
    RT_INV_MK_ROW 48, %xmm9, %xmm10, %xmm11
    addq $64, %rdi                  # next multipliers
    addq %rdx, %rsi                 # next pivot row
    subq $1, %rcx
    jnz .Lrt_inv_mk_q
    movq %r8, %rax
    RT_INV_MK_IO %rax, %xmm0, %xmm1, %xmm2, 0
    addq %rdx, %rax
    RT_INV_MK_IO %rax, %xmm3, %xmm4, %xmm5, 0
    addq %rdx, %rax
    RT_INV_MK_IO %rax, %xmm6, %xmm7, %xmm8, 0
    addq %rdx, %rax
    RT_INV_MK_IO %rax, %xmm9, %xmm10, %xmm11, 0
    ret

# ---------------------------------------------------------------------
# .Lrt_inv_region -- delayed panel update of 4 rows over one region
#   (W's trailing columns or X), multipliers already in Fbuf:
#   6-column strips through .Lrt_inv_mk, the last count % 6 columns
#   through .Lrt_inv_seq.
#   Private convention:
#   Inputs  : %rdi = &T(i, 0) (first column of the region), %rsi =
#             &P(0, 0) (first pivot row, same column), %rdx = count,
#             %rcx = ld (bytes), %r8 = &W(i, p0), %r9 = nq (>= 1),
#             %r11 = W stride (bytes)
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = &T(i, j), %rbp = &P(0, j), %r12 = columns
#             left, %r13 = ld, %r14 = &W(i, p0), %r15 = nq
#   Frame   : 56 bytes (six saved registers, then the W stride %r11
#             pushed as a seventh slot and read back for the tail)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_inv_region:
    pushq %rbx
    pushq %rbp
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    pushq %r11                      # W stride (needed for the tail)
    movq %rdi, %rbx
    movq %rsi, %rbp
    movq %rdx, %r12
    movq %rcx, %r13
    movq %r8, %r14
    movq %r9, %r15
.Lrt_inv_region_strip:
    cmpq $6, %r12
    jb .Lrt_inv_region_tail
    leaq .Lrt_inv_fbuf(%rip), %rdi
    movq %rbp, %rsi
    movq %r13, %rdx
    movq %r15, %rcx
    movq %rbx, %r8
    call .Lrt_inv_mk
    addq $48, %rbx                  # six columns right
    addq $48, %rbp
    subq $6, %r12
    jmp .Lrt_inv_region_strip
.Lrt_inv_region_tail:
    movq %rbx, %rdi                 # 0..5 columns left: per row, per q
    movq %rbp, %rsi
    movq %r12, %rdx
    movq %r13, %rcx
    movq %r14, %r8
    movq %r15, %r9
    movl $4, %r10d
    movq (%rsp), %r11
    call .Lrt_inv_seq
    popq %r11
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    popq %rbx
    ret

# ---------------------------------------------------------------------
# bsk_rt_ksse2_inv
#   Inputs  : %rdi = X view (n x n), %rsi = A view (n x n),
#             n <= RT_KERN_INV_MAXN, no overlap, A finite
#   Outputs : %rax = KS_OK, KS_SINGULAR or KS_NONFINITE
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = n, %r12 = p / row index, %r13 = W base,
#             %r14 = X data, %r15 = X row stride in bytes,
#             %rbp = frame pointer
#   Frame   : 48 bytes of saved registers + RT_INV_FRAME locals (W
#             view, tol, X view, panel bounds, W stride, loop state);
#             %rsp = 0 (mod 16) at calls
# ---------------------------------------------------------------------
    .globl bsk_rt_ksse2_inv
    .hidden bsk_rt_ksse2_inv
    .type bsk_rt_ksse2_inv, @function
    .p2align 4
bsk_rt_ksse2_inv:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    subq $RT_INV_FRAME, %rsp        # %rsp = 0 (mod 16)
    movq %rdi, RT_INV_XVIEW(%rsp)
    movq MV_ROWS(%rsi), %rbx        # n
    movq MV_DATA(%rdi), %r14        # X data
    movq MV_LD(%rdi), %r15
    shlq $3, %r15                   # X stride in bytes
    leaq .Lrt_inv_w(%rip), %r13     # W base (row stride n)
    leaq (,%rbx,8), %rax
    movq %rax, RT_INV_WLD(%rsp)

    # ---- m = max |A(i,j)| ------------------------------------------
    movq MV_DATA(%rsi), %rax        # A row pointer
    movq MV_LD(%rsi), %rcx
    shlq $3, %rcx                   # A stride in bytes
    movq %rbx, %rdx                 # rows left
    xorpd %xmm1, %xmm1              # running max (both lanes)
    movapd .Lrt_inv_absmask(%rip), %xmm2
.Lrt_inv_max_row:
    xorl %edi, %edi                 # j
.Lrt_inv_max_v:
    leaq 2(%rdi), %r8
    cmpq %rbx, %r8
    ja .Lrt_inv_max_s
    movupd (%rax,%rdi,8), %xmm3
    andpd %xmm2, %xmm3              # |a|
    maxpd %xmm3, %xmm1
    addq $2, %rdi
    jmp .Lrt_inv_max_v
.Lrt_inv_max_s:
    cmpq %rbx, %rdi
    jae 1f
    movsd (%rax,%rdi,8), %xmm3      # upper lane 0: cannot raise the max
    andpd %xmm2, %xmm3
    maxpd %xmm3, %xmm1
1:
    addq %rcx, %rax
    subq $1, %rdx
    jnz .Lrt_inv_max_row
    movapd %xmm1, %xmm3
    unpckhpd %xmm3, %xmm3
    maxsd %xmm3, %xmm1              # m in the low lane
    # tol = (n * 2^-52) * m: the first product is exact, one rounding
    cvtsi2sdq %rbx, %xmm0
    mulsd .Lrt_inv_ulp(%rip), %xmm0
    mulsd %xmm1, %xmm0
    movsd %xmm0, RT_INV_TOL(%rsp)

    # ---- W := A, X := I ----------------------------------------------
    movq %r13, RT_INV_WVIEW + MV_DATA(%rsp)
    movq %rbx, RT_INV_WVIEW + MV_ROWS(%rsp)
    movq %rbx, RT_INV_WVIEW + MV_COLS(%rsp)
    movq %rbx, RT_INV_WVIEW + MV_LD(%rsp)
    leaq RT_INV_WVIEW(%rsp), %rdi
    call bsk_rt_ksse2_copy          # %rsi = A view still
    movq RT_INV_XVIEW(%rsp), %rdi
    xorpd %xmm0, %xmm0
    call bsk_rt_ksse2_fill
    movsd .Lrt_inv_one(%rip), %xmm0
    movq %r14, %rax
    movq %rbx, %rcx
1:
    movsd %xmm0, (%rax)             # X(i,i) = 1
    leaq 8(%rax,%r15), %rax         # next diagonal element
    subq $1, %rcx
    jnz 1b

    movq $0, RT_INV_P0(%rsp)        # first panel
.Lrt_inv_panel:
    movq RT_INV_P0(%rsp), %rax
    leaq RT_INV_NB(%rax), %rcx
    cmpq %rbx, %rcx
    cmova %rbx, %rcx
    movq %rcx, RT_INV_PE(%rsp)      # pe = min(p0 + NB, n)
    subq %rax, %rcx
    movq %rcx, RT_INV_BC(%rsp)      # panel width
    movq %rax, %r12                 # p = p0

.Lrt_inv_step:
    # ---- pivot search in column p, rows p .. n-1 ---------------------
    movq RT_INV_WLD(%rsp), %r8
    movq %r12, %rax
    imulq %r8, %rax
    addq %r13, %rax
    leaq (%rax,%r12,8), %rax        # &W(p,p)
    movapd .Lrt_inv_absmask(%rip), %xmm2
    movsd (%rax), %xmm0
    andpd %xmm2, %xmm0              # best = |W(p,p)|
    movq %r12, %rcx                 # r = p
    leaq 1(%r12), %rdx              # i = p + 1
    leaq (%rax,%r8), %rsi           # &W(i,p)
.Lrt_inv_piv:
    cmpq %rbx, %rdx
    jae .Lrt_inv_piv_done
    movsd (%rsi), %xmm1
    andpd %xmm2, %xmm1              # |W(i,p)|
    ucomisd %xmm0, %xmm1
    jbe 1f                          # not strictly greater (or NaN)
    movapd %xmm1, %xmm0             # best = |W(i,p)|, r = i
    movq %rdx, %rcx
1:
    addq $1, %rdx
    addq %r8, %rsi
    jmp .Lrt_inv_piv
.Lrt_inv_piv_done:
    movsd RT_INV_TOL(%rsp), %xmm1
    ucomisd %xmm0, %xmm1            # tol >= best?  (false if NaN)
    jae .Lrt_inv_singular
    # ---- row exchange (W columns p0 .. n-1 with the multipliers, X) ---
    cmpq %r12, %rcx
    je .Lrt_inv_noswap
    movq %rcx, RT_INV_I(%rsp)       # r
    movq RT_INV_P0(%rsp), %rdx
    movq %r12, %rdi
    imulq %r8, %rdi
    addq %r13, %rdi
    leaq (%rdi,%rdx,8), %rdi        # &W(p,p0)
    movq %rcx, %rsi
    imulq %r8, %rsi
    addq %r13, %rsi
    leaq (%rsi,%rdx,8), %rsi        # &W(r,p0)
    negq %rdx
    addq %rbx, %rdx                 # n - p0 columns
    call .Lrt_inv_swap
    movq %r12, %rdi
    imulq %r15, %rdi
    addq %r14, %rdi                 # &X(p,0)
    movq RT_INV_I(%rsp), %rsi
    imulq %r15, %rsi
    addq %r14, %rsi                 # &X(r,0)
    movq %rbx, %rdx
    call .Lrt_inv_swap
.Lrt_inv_noswap:
    # ---- bring the pivot row's trailing part up to date (p0 .. p-1) ---
    movq RT_INV_WLD(%rsp), %r11
    movq RT_INV_PE(%rsp), %rax
    movq %r12, %rdi
    imulq %r11, %rdi
    addq %r13, %rdi
    leaq (%rdi,%rax,8), %rdi        # &W(p,pe)
    movq RT_INV_P0(%rsp), %rcx
    movq %rcx, %rsi
    imulq %r11, %rsi
    addq %r13, %rsi
    leaq (%rsi,%rax,8), %rsi        # &W(p0,pe)
    movq %rbx, %rdx
    subq %rax, %rdx                 # n - pe columns
    movq %r12, %r8
    imulq %r11, %r8
    addq %r13, %r8
    leaq (%r8,%rcx,8), %r8          # &W(p,p0): multipliers
    movq %r12, %r9
    subq %rcx, %r9                  # nq = p - p0
    movl $1, %r10d
    movq %r11, %rcx                 # ld = W stride
    call .Lrt_inv_seq
    movq RT_INV_WLD(%rsp), %r11
    movq %r12, %rdi
    imulq %r15, %rdi
    addq %r14, %rdi                 # &X(p,0)
    movq RT_INV_P0(%rsp), %rcx
    movq %rcx, %rsi
    imulq %r15, %rsi
    addq %r14, %rsi                 # &X(p0,0)
    movq %rbx, %rdx                 # n columns
    movq %r12, %r8
    imulq %r11, %r8
    addq %r13, %r8
    leaq (%r8,%rcx,8), %r8          # &W(p,p0)
    movq %r12, %r9
    subq %rcx, %r9
    movl $1, %r10d
    movq %r15, %rcx                 # ld = X stride
    call .Lrt_inv_seq
    # ---- pivot d, finite check, divide the pivot row ------------------
    movq RT_INV_WLD(%rsp), %r8
    movq %r12, %rax
    imulq %r8, %rax
    addq %r13, %rax
    leaq (%rax,%r12,8), %rax        # &W(p,p)
    movq (%rax), %rcx
    btrq $63, %rcx                  # |d| bits
    movabsq $RT_INV_INF_BITS, %rdx
    cmpq %rdx, %rcx
    jae .Lrt_inv_nonfinite          # d is +-inf or NaN
    movsd (%rax), %xmm0
    unpcklpd %xmm0, %xmm0           # (d, d)
    leaq 8(%rax), %r10              # &W(p,p+1)
    movq %r10, %rdi
    movq %rbx, %rdx
    subq %r12, %rdx
    subq $1, %rdx                   # columns p+1 .. n-1
    call .Lrt_inv_divrow
    movq %r12, %rdi
    imulq %r15, %rdi
    addq %r14, %rdi                 # &X(p,0)
    movq %rbx, %rdx
    call .Lrt_inv_divrow
    # ---- eager update of the panel columns p+1 .. pe-1, every i != p --
    movq RT_INV_PE(%rsp), %r11
    subq %r12, %r11
    subq $1, %r11                   # pe - p - 1 columns
    jz .Lrt_inv_step_next           # last panel column: nothing to do
    xorl %r9d, %r9d                 # i = 0
.Lrt_inv_elim:
    cmpq %r12, %r9
    je .Lrt_inv_elim_next           # skip the pivot row itself
    movq %r9, %rdi
    imulq %r8, %rdi
    addq %r13, %rdi
    leaq (%rdi,%r12,8), %rdi        # &W(i,p)
    movsd (%rdi), %xmm0
    unpcklpd %xmm0, %xmm0           # (f, f)
    addq $8, %rdi                   # &W(i,p+1)
    movq %r10, %rsi                 # &W(p,p+1)
    movq %r11, %rdx
    call .Lrt_inv_axpy              # keeps %r8-%r11
.Lrt_inv_elim_next:
    addq $1, %r9
    cmpq %rbx, %r9
    jb .Lrt_inv_elim
.Lrt_inv_step_next:
    addq $1, %r12
    cmpq RT_INV_PE(%rsp), %r12
    jb .Lrt_inv_step

    # ---- trailing update: non-pivot rows [0, p0) then [pe, n) ----------
    movq $0, RT_INV_I(%rsp)
    movq RT_INV_P0(%rsp), %rax
    movq %rax, RT_INV_RHI(%rsp)
    call .Lrt_inv_rows
    movq RT_INV_PE(%rsp), %rax
    movq %rax, RT_INV_I(%rsp)
    movq %rbx, RT_INV_RHI(%rsp)
    call .Lrt_inv_rows
    # ---- then the panel's pivot rows, increasing i: steps i+1 .. pe-1 --
    movq RT_INV_P0(%rsp), %r12
.Lrt_inv_prow:
    movq RT_INV_PE(%rsp), %r9
    subq %r12, %r9
    subq $1, %r9                    # nq = pe - i - 1
    jz .Lrt_inv_prow_next
    movq RT_INV_WLD(%rsp), %r11
    movq RT_INV_PE(%rsp), %rax
    movq %r12, %rdi
    imulq %r11, %rdi
    addq %r13, %rdi
    leaq (%rdi,%rax,8), %rdi        # &W(i,pe)
    leaq (%rdi,%r11), %rsi          # &W(i+1,pe)
    movq %rbx, %rdx
    subq %rax, %rdx                 # n - pe
    movq %r12, %r8
    imulq %r11, %r8
    addq %r13, %r8
    leaq 8(%r8,%r12,8), %r8         # &W(i,i+1)
    movl $1, %r10d
    movq %r11, %rcx
    call .Lrt_inv_seq
    movq RT_INV_PE(%rsp), %r9
    subq %r12, %r9
    subq $1, %r9
    movq RT_INV_WLD(%rsp), %r11
    movq %r12, %rdi
    imulq %r15, %rdi
    addq %r14, %rdi                 # &X(i,0)
    leaq (%rdi,%r15), %rsi          # &X(i+1,0)
    movq %rbx, %rdx
    movq %r12, %r8
    imulq %r11, %r8
    addq %r13, %r8
    leaq 8(%r8,%r12,8), %r8         # &W(i,i+1)
    movl $1, %r10d
    movq %r15, %rcx
    call .Lrt_inv_seq
.Lrt_inv_prow_next:
    addq $1, %r12
    cmpq RT_INV_PE(%rsp), %r12
    jb .Lrt_inv_prow
    # ---- next panel ---------------------------------------------------
    movq RT_INV_PE(%rsp), %rax
    movq %rax, RT_INV_P0(%rsp)
    cmpq %rbx, %rax
    jb .Lrt_inv_panel

    # ---- result check -------------------------------------------------
    movq RT_INV_XVIEW(%rsp), %rdi
    call bsk_rt_ksse2_chkfin        # %rax = KS_OK / KS_NONFINITE
    jmp .Lrt_inv_out
.Lrt_inv_singular:
    movl $KS_SINGULAR, %eax
    jmp .Lrt_inv_out
.Lrt_inv_nonfinite:
    movl $KS_NONFINITE, %eax
.Lrt_inv_out:
    addq $RT_INV_FRAME, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret
    .size bsk_rt_ksse2_inv, . - bsk_rt_ksse2_inv

# ---------------------------------------------------------------------
# .Lrt_inv_rows -- delayed panel update of the non-pivot rows
#   RT_INV_I .. RT_INV_RHI-1 (caller's frame): blocks of 4 rows through
#   .Lrt_inv_packf + .Lrt_inv_region (W trailing columns, then X), the
#   remaining 0..3 rows one at a time through .Lrt_inv_seq.
#   Private convention: called directly from bsk_rt_ksse2_inv, whose
#   frame is at 8(%rsp) and whose %rbx %r13 %r14 %r15 (n, W, X, X
#   stride) it reads; %r12 is the row index.
#   Clobbers: all caller-saved registers, %r12
#   Frame   : 8 bytes (alignment pad; caller's frame at 16(%rsp))
# ---------------------------------------------------------------------
.equ RT_INV_UP, 16                  # caller's frame offset inside rows
    .p2align 4
.Lrt_inv_rows:
    subq $8, %rsp                   # %rsp = 0 (mod 16) for the calls
    movq RT_INV_UP + RT_INV_I(%rsp), %r12
.Lrt_inv_rows_blk:
    leaq 4(%r12), %rax
    cmpq RT_INV_UP + RT_INV_RHI(%rsp), %rax
    ja .Lrt_inv_rows_single         # fewer than 4 rows left
    # multipliers of rows i .. i+3, steps p0 .. pe-1
    movq RT_INV_UP + RT_INV_WLD(%rsp), %rsi
    movq %r12, %rdi
    imulq %rsi, %rdi
    addq %r13, %rdi
    movq RT_INV_UP + RT_INV_P0(%rsp), %rax
    leaq (%rdi,%rax,8), %rdi        # &W(i,p0)
    movq RT_INV_UP + RT_INV_BC(%rsp), %rdx
    call .Lrt_inv_packf
    # region 1: W columns pe .. n-1
    movq RT_INV_UP + RT_INV_WLD(%rsp), %r11
    movq RT_INV_UP + RT_INV_PE(%rsp), %rax
    movq %rbx, %rdx
    subq %rax, %rdx                 # n - pe columns
    jz 1f
    movq %r12, %rdi
    imulq %r11, %rdi
    addq %r13, %rdi
    leaq (%rdi,%rax,8), %rdi        # &W(i,pe)
    movq RT_INV_UP + RT_INV_P0(%rsp), %rcx
    movq %rcx, %rsi
    imulq %r11, %rsi
    addq %r13, %rsi
    leaq (%rsi,%rax,8), %rsi        # &W(p0,pe)
    movq %r12, %r8
    imulq %r11, %r8
    addq %r13, %r8
    leaq (%r8,%rcx,8), %r8          # &W(i,p0)
    movq RT_INV_UP + RT_INV_BC(%rsp), %r9
    movq %r11, %rcx
    call .Lrt_inv_region
1:
    # region 2: all X columns
    movq RT_INV_UP + RT_INV_WLD(%rsp), %r11
    movq %r12, %rdi
    imulq %r15, %rdi
    addq %r14, %rdi                 # &X(i,0)
    movq RT_INV_UP + RT_INV_P0(%rsp), %rcx
    movq %rcx, %rsi
    imulq %r15, %rsi
    addq %r14, %rsi                 # &X(p0,0)
    movq %r12, %r8
    imulq %r11, %r8
    addq %r13, %r8
    leaq (%r8,%rcx,8), %r8          # &W(i,p0)
    movq %rbx, %rdx
    movq RT_INV_UP + RT_INV_BC(%rsp), %r9
    movq %r15, %rcx
    call .Lrt_inv_region
    addq $4, %r12
    jmp .Lrt_inv_rows_blk
.Lrt_inv_rows_single:
    cmpq RT_INV_UP + RT_INV_RHI(%rsp), %r12
    jae .Lrt_inv_rows_done
    movq RT_INV_UP + RT_INV_WLD(%rsp), %r11
    movq RT_INV_UP + RT_INV_PE(%rsp), %rax
    movq RT_INV_UP + RT_INV_P0(%rsp), %rcx
    movq %r12, %rdi
    imulq %r11, %rdi
    addq %r13, %rdi
    leaq (%rdi,%rax,8), %rdi        # &W(i,pe)
    movq %rcx, %rsi
    imulq %r11, %rsi
    addq %r13, %rsi
    leaq (%rsi,%rax,8), %rsi        # &W(p0,pe)
    movq %rbx, %rdx
    subq %rax, %rdx                 # n - pe (may be 0)
    movq %r12, %r8
    imulq %r11, %r8
    addq %r13, %r8
    leaq (%r8,%rcx,8), %r8          # &W(i,p0)
    movq RT_INV_UP + RT_INV_BC(%rsp), %r9
    movl $1, %r10d
    movq %r11, %rcx
    call .Lrt_inv_seq
    movq RT_INV_UP + RT_INV_WLD(%rsp), %r11
    movq RT_INV_UP + RT_INV_P0(%rsp), %rcx
    movq %r12, %rdi
    imulq %r15, %rdi
    addq %r14, %rdi                 # &X(i,0)
    movq %rcx, %rsi
    imulq %r15, %rsi
    addq %r14, %rsi                 # &X(p0,0)
    movq %r12, %r8
    imulq %r11, %r8
    addq %r13, %r8
    leaq (%r8,%rcx,8), %r8          # &W(i,p0)
    movq %rbx, %rdx
    movq RT_INV_UP + RT_INV_BC(%rsp), %r9
    movl $1, %r10d
    movq %r15, %rcx
    call .Lrt_inv_seq
    addq $1, %r12
    jmp .Lrt_inv_rows_single
.Lrt_inv_rows_done:
    addq $8, %rsp
    ret

    .section .rodata
    .p2align 4
.Lrt_inv_absmask:
    .quad 0x7FFFFFFFFFFFFFFF, 0x7FFFFFFFFFFFFFFF
.Lrt_inv_ulp:
    .quad RT_INV_ULP_BITS           # 2^-52 (RT_INV_TOL_SHIFT)
.Lrt_inv_one:
    .double 1.0

# INV workspace W: RT_KERN_INV_MAXN^2 doubles (DESIGN.md 6.6.6), and
# the packed multipliers of one 4-row block (RT_INV_NB steps x 64 bytes)
    .bss
    .p2align 6
.Lrt_inv_w:
    .zero RT_KERN_INV_MAXN * RT_KERN_INV_MAXN * 8
    .p2align 6
.Lrt_inv_fbuf:
    .zero RT_INV_NB * 64

    .section .note.GNU-stack,"",@progbits
