# =====================================================================
# src/runtime_x86_64_linux/rt_ksse2_gemm.s -- SSE2 matrix product and
# product update of the "sse2" variant (docs/DESIGN.md 6.6.1, 6.6.4,
# 6.6.5; LANGUAGE.md 7.14.7).
#
# Defines (private to the runtime, .globl + .hidden):
#   bsk_rt_ksse2_gemm     C = A * B      (A m x k, B k x n, C m x n)
#                         -> %rax KS_OK / KS_NONFINITE
#   bsk_rt_ksse2_gemm_sub C = C - A * B  (same shapes; C in and out)
#                         -> %rax KS_OK / KS_NONFINITE
#
# Both entries run one driver (.Lrt_gemm_drv) with the same packing,
# blocking and staging tile; they differ only in the micro-kernel
# (RT_GEMM_MICRO instantiated twice: GEMM accumulates mulpd + addpd,
# gemm_sub mulpd + subpd) and in when C is read: GEMM stores the first
# pc block and adds the later ones, gemm_sub adds the tile to C for
# EVERY pc block, so each element is C0 - sum of the products (class R,
# k + 1 terms, DESIGN.md 6.6.4).
#
# Goto/BLIS structure:
#   for jc (columns, step NC):
#     for pc (inner dimension, step KC):
#       pack B(pc.., jc..) into NR-wide micro-panels   (Bp, k-major)
#       for ic (rows, step MC):
#         pack A(ic.., pc..) into MR-high micro-panels (Ap)
#         for jr (step NR): for ir (step MR):
#           micro-kernel: the MR x NR block of C stays in registers for
#           the whole kc loop; stored (pc = 0) or added to C (pc > 0;
#           gemm_sub: every pc)
# MR x NR = 4 x 6: 12 accumulator registers (%xmm0-%xmm11), each two
# adjacent elements of one row of C; %xmm12-%xmm14 hold one k-row of
# the B micro-panel, %xmm15 is the product temporary (SSE2 has no FMA:
# mulpd then addpd). Ap stores every A value twice, (a, a), so one
# aligned load is the broadcast (SSE2 lacks movddup).
# Edges: zero-padded packing and a partial store through a 4 x 6
# staging tile. IEEE propagation (DESIGN.md 6.6.4): inputs may hold
# +-inf and NaN. No path tests a factor for zero, so 0 * inf reaches
# its element as NaN. A padding lane (a zero row of Ap or column of Bp)
# may hold 0 * inf = NaN, but such lanes are only in the staged part
# that is never copied out; full tiles have no padding lanes. Nothing
# outside the views is read (packing copies only the mc x kc / kc x nc
# blocks) or written (partial tiles store only the valid part).
# Class R (DESIGN.md 6.6.4): the summation order depends only on the
# shapes (fixed blocking), never on addresses or alignment (all C
# accesses are movupd; the packed buffers are 64-byte aligned).
# The finite check is a separate vectorised pass over C at the end
# (bsk_rt_ksse2_chkfin), so KS_NONFINITE is reported exactly when a
# stored element is not finite.
# =====================================================================
.include "baysick.inc"

.equ RT_GEMM_MR, 4
.equ RT_GEMM_NR, 6
# Blocking (tunable with --defsym for experiments; DESIGN.md 6.6.5):
.ifndef RT_GEMM_KC
.equ RT_GEMM_KC, 256                # inner-dimension block depth
.endif
.ifndef RT_GEMM_MC
.equ RT_GEMM_MC, 48                 # row block height (multiple of MR)
.endif
.ifndef RT_GEMM_NC
.equ RT_GEMM_NC, 2046               # column block width (multiple of NR)
.endif
.if (RT_GEMM_MC % RT_GEMM_MR) != 0
    .error "rt_ksse2_gemm.s: MC must be a multiple of MR"
.endif
.if (RT_GEMM_NC % RT_GEMM_NR) != 0
    .error "rt_ksse2_gemm.s: NC must be a multiple of NR"
.endif
.equ RT_GEMM_AP_BYTES, RT_GEMM_MC * RT_GEMM_KC * 2 * 8     # duplicated A
.equ RT_GEMM_BP_BYTES, RT_GEMM_NC * RT_GEMM_KC * 8
.if (RT_GEMM_AP_BYTES + RT_GEMM_BP_BYTES) > 8388608
    .error "rt_ksse2_gemm.s: packing buffers exceed 8 MiB (DESIGN.md 6.6.6)"
.endif

# Frame of bsk_rt_ksse2_gemm (offsets from %rsp)
.equ RT_GEMM_M,     0
.equ RT_GEMM_N,     8
.equ RT_GEMM_K,     16
.equ RT_GEMM_CDATA, 24
.equ RT_GEMM_LDC,   32              # bytes
.equ RT_GEMM_ADATA, 40
.equ RT_GEMM_LDA,   48              # bytes
.equ RT_GEMM_BDATA, 56
.equ RT_GEMM_LDB,   64              # bytes
.equ RT_GEMM_NCUR,  72              # current nc
.equ RT_GEMM_KCUR,  80              # current kc
.equ RT_GEMM_MCUR,  88              # current mc
.equ RT_GEMM_CVIEW, 96              # C view pointer
.equ RT_GEMM_SUB,   104             # 1 for gemm_sub, 0 for GEMM
.equ RT_GEMM_UKER,  112             # micro-kernel of the entry
.equ RT_GEMM_FRAME, 120             # 56 + 120 = 0 (mod 16)

    .text

# ---------------------------------------------------------------------
# .Lrt_gemm_packA -- pack an mc x kc block of A into MR-high panels.
#   Panel q holds rows 4q..4q+3; for each k, 8 doubles
#   (a0,a0, a1,a1, a2,a2, a3,a3) = 64 bytes; rows past mc are zero.
#   Private convention (leaf):
#   Inputs  : %rdi = Ap (64-byte aligned), %rsi = &A(ic,pc),
#             %rdx = A stride in bytes, %rcx = kc (>= 1), %r8 = mc (>= 1)
#   Clobbers: %rax %rsi %rdi %r8-%r11 %xmm0-%xmm2
#   Callee-saved used: %rbx = loop bound (saved)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_gemm_packA:
    pushq %rbx
    xorpd %xmm2, %xmm2
.Lrt_gemm_packA_panel:
    xorl %r9d, %r9d                 # i = row within the panel
.Lrt_gemm_packA_row:
    movq %r9, %r11
    shlq $4, %r11
    addq %rdi, %r11                 # d = panel + 16 i (lane slot of row i)
    cmpq %r8, %r9
    jae .Lrt_gemm_packA_zero        # row past mc: zero padding
    movq %r9, %r10
    imulq %rdx, %r10
    addq %rsi, %r10                 # s = &A(ic + 4q + i, pc)
    xorl %eax, %eax                 # kk
.Lrt_gemm_packA_pair:
    leaq 2(%rax), %rbx
    cmpq %rcx, %rbx
    ja .Lrt_gemm_packA_odd
    movupd (%r10,%rax,8), %xmm0     # (a_k, a_k+1)
    movapd %xmm0, %xmm1
    unpcklpd %xmm1, %xmm1           # (a_k,   a_k)
    unpckhpd %xmm0, %xmm0           # (a_k+1, a_k+1)
    movapd %xmm1, (%r11)
    movapd %xmm0, 64(%r11)
    addq $128, %r11                 # two k steps further
    addq $2, %rax
    jmp .Lrt_gemm_packA_pair
.Lrt_gemm_packA_odd:
    cmpq %rcx, %rax
    jae .Lrt_gemm_packA_next
    movsd (%r10,%rax,8), %xmm1
    unpcklpd %xmm1, %xmm1
    movapd %xmm1, (%r11)
    jmp .Lrt_gemm_packA_next
.Lrt_gemm_packA_zero:
    movq %rcx, %rax                 # kc zero slots
1:
    movapd %xmm2, (%r11)
    addq $64, %r11
    subq $1, %rax
    jnz 1b
.Lrt_gemm_packA_next:
    addq $1, %r9
    cmpq $RT_GEMM_MR, %r9
    jb .Lrt_gemm_packA_row
    # next panel: Ap += kc * 64, A rows += 4, mc -= 4
    movq %rcx, %rax
    shlq $6, %rax
    addq %rax, %rdi
    leaq (%rsi,%rdx,4), %rsi
    subq $RT_GEMM_MR, %r8
    jg .Lrt_gemm_packA_panel
    popq %rbx
    ret

# ---------------------------------------------------------------------
# .Lrt_gemm_packB -- pack a kc x nc block of B into NR-wide panels.
#   Panel t holds columns 6t..6t+5; for each k, 6 doubles (48 bytes);
#   columns past nc are zero.
#   Private convention (leaf):
#   Inputs  : %rdi = Bp (64-byte aligned), %rsi = &B(pc,jc),
#             %rdx = B stride in bytes, %rcx = kc (>= 1), %r8 = nc (>= 1)
#   Clobbers: %rax %rsi %rdi %r8-%r11 %xmm0-%xmm3
#   Callee-saved used: %rbx = column index in a partial panel (saved)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_gemm_packB:
    pushq %rbx
    xorpd %xmm3, %xmm3
.Lrt_gemm_packB_panel:
    movq %rsi, %r10                 # s = &B(pc, column 6t)
    movq %rdi, %r11                 # d = panel start
    movq %rcx, %rax                 # k rows left
    cmpq $RT_GEMM_NR, %r8
    jb .Lrt_gemm_packB_part
.Lrt_gemm_packB_full:
    movupd (%r10), %xmm0            # six columns of one k-row
    movupd 16(%r10), %xmm1
    movupd 32(%r10), %xmm2
    movapd %xmm0, (%r11)
    movapd %xmm1, 16(%r11)
    movapd %xmm2, 32(%r11)
    addq %rdx, %r10
    addq $48, %r11
    subq $1, %rax
    jnz .Lrt_gemm_packB_full
    jmp .Lrt_gemm_packB_next
.Lrt_gemm_packB_part:
    movapd %xmm3, (%r11)            # zero the six slots ...
    movapd %xmm3, 16(%r11)
    movapd %xmm3, 32(%r11)
    xorl %ebx, %ebx
1:
    movq (%r10,%rbx,8), %r9         # ... then copy the nc valid ones
    movq %r9, (%r11,%rbx,8)
    addq $1, %rbx
    cmpq %r8, %rbx
    jb 1b
    addq %rdx, %r10
    addq $48, %r11
    subq $1, %rax
    jnz .Lrt_gemm_packB_part
.Lrt_gemm_packB_next:
    imulq $48, %rcx, %rax
    addq %rax, %rdi                 # next panel: Bp += kc * 48
    addq $48, %rsi                  # B columns += 6
    subq $RT_GEMM_NR, %r8
    jg .Lrt_gemm_packB_panel
    popq %rbx
    ret

# RT_GEMM_ROW aoff, c0, c1, c2, op -- one row of the micro-tile for
#   one k: c_j = c_j op (a, a) * b_j, j = 0..2 (%xmm12-%xmm14 = b row;
#   op = addpd for GEMM, subpd for gemm_sub; one rounded product, one
#   rounded add or subtract: never fused, never a zero test).
.macro RT_GEMM_ROW aoff, c0, c1, c2, op
    movapd \aoff(%rdi), %xmm15
    mulpd %xmm12, %xmm15
    \op %xmm15, \c0
    movapd \aoff(%rdi), %xmm15
    mulpd %xmm13, %xmm15
    \op %xmm15, \c1
    movapd \aoff(%rdi), %xmm15
    mulpd %xmm14, %xmm15
    \op %xmm15, \c2
.endm

# RT_GEMM_KSTEP kk, op -- the whole 4 x 6 update for k step \kk of a
#   4-step unrolled group (A at 64 kk, B at 48 kk).
.macro RT_GEMM_KSTEP kk, op
    movapd 48*\kk(%rsi), %xmm12
    movapd 48*\kk+16(%rsi), %xmm13
    movapd 48*\kk+32(%rsi), %xmm14
    RT_GEMM_ROW 64*\kk,    %xmm0, %xmm1,  %xmm2,  \op
    RT_GEMM_ROW 64*\kk+16, %xmm3, %xmm4,  %xmm5,  \op
    RT_GEMM_ROW 64*\kk+32, %xmm6, %xmm7,  %xmm8,  \op
    RT_GEMM_ROW 64*\kk+48, %xmm9, %xmm10, %xmm11, \op
.endm

# RT_GEMM_STROW c0, c1, c2, add -- write one row of the tile to C at
#   (%rax): with add = 1, C + acc; else acc.
.macro RT_GEMM_STROW c0, c1, c2, add
.if \add
    movupd (%rax), %xmm12
    addpd %xmm12, \c0
    movupd 16(%rax), %xmm13
    addpd %xmm13, \c1
    movupd 32(%rax), %xmm14
    addpd %xmm14, \c2
.endif
    movupd \c0, (%rax)
    movupd \c1, 16(%rax)
    movupd \c2, 32(%rax)
    addq %r8, %rax                  # next row of C
.endm

# ---------------------------------------------------------------------
# RT_GEMM_MICRO name, op -- defines the 4 x 6 register-blocked
#   micro-kernel \name, accumulating with \op (addpd: GEMM, the tile is
#   A * B; subpd: gemm_sub, the tile is -(A * B)). Instantiated as
#   .Lrt_gemm_micro and .Lrt_gemm_micro_sub below.
#   Private convention (leaf):
#   Inputs  : %rdi = A micro-panel, %rsi = B micro-panel, %rdx = kc
#             (>= 1), %rcx = &C(tile), %r8 = C stride in bytes,
#             %r9 = 1 to add the tile to C / 0 to store it,
#             %r10 = valid rows (1..4), %r11 = valid columns (1..6)
#   Outputs : the valid rows x columns of the tile at %rcx, stored or
#             added to C; nothing else of C is read or written
#   Clobbers: %rax %rdx %rsi %rdi %r9-%r11 %xmm0-%xmm15
#   Callee-saved used: none
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
.macro RT_GEMM_MICRO name, op
    .p2align 4
\name:
    xorpd %xmm0, %xmm0              # 12 accumulators = 0
    xorpd %xmm1, %xmm1
    xorpd %xmm2, %xmm2
    xorpd %xmm3, %xmm3
    xorpd %xmm4, %xmm4
    xorpd %xmm5, %xmm5
    xorpd %xmm6, %xmm6
    xorpd %xmm7, %xmm7
    xorpd %xmm8, %xmm8
    xorpd %xmm9, %xmm9
    xorpd %xmm10, %xmm10
    xorpd %xmm11, %xmm11
    movq %rdx, %rax
    shrq $2, %rax                   # groups of four k steps
    jz \name\()_k1
\name\()_k4:
    RT_GEMM_KSTEP 0, \op
    RT_GEMM_KSTEP 1, \op
    RT_GEMM_KSTEP 2, \op
    RT_GEMM_KSTEP 3, \op
    addq $256, %rdi                 # 4 k steps of A (4 x 64 bytes)
    addq $192, %rsi                 # 4 k steps of B (4 x 48 bytes)
    subq $1, %rax
    jnz \name\()_k4
\name\()_k1:
    andq $3, %rdx                   # remaining single k steps
    jz \name\()_store
1:
    RT_GEMM_KSTEP 0, \op
    addq $64, %rdi
    addq $48, %rsi
    subq $1, %rdx
    jnz 1b
\name\()_store:
    cmpq $RT_GEMM_MR, %r10
    jne \name\()_partial
    cmpq $RT_GEMM_NR, %r11
    jne \name\()_partial
    movq %rcx, %rax                 # full tile straight into C
    testq %r9, %r9
    jnz \name\()_add
    RT_GEMM_STROW %xmm0, %xmm1, %xmm2, 0
    RT_GEMM_STROW %xmm3, %xmm4, %xmm5, 0
    RT_GEMM_STROW %xmm6, %xmm7, %xmm8, 0
    RT_GEMM_STROW %xmm9, %xmm10, %xmm11, 0
    ret
\name\()_add:
    RT_GEMM_STROW %xmm0, %xmm1, %xmm2, 1
    RT_GEMM_STROW %xmm3, %xmm4, %xmm5, 1
    RT_GEMM_STROW %xmm6, %xmm7, %xmm8, 1
    RT_GEMM_STROW %xmm9, %xmm10, %xmm11, 1
    ret
\name\()_partial:
    # stage the tile (row-major 4 x 6), then copy the valid part; the
    # padding lanes (which may be NaN from 0 * inf) stay in the tile
    leaq .Lrt_gemm_tile(%rip), %rax
    movapd %xmm0, 0(%rax)
    movapd %xmm1, 16(%rax)
    movapd %xmm2, 32(%rax)
    movapd %xmm3, 48(%rax)
    movapd %xmm4, 64(%rax)
    movapd %xmm5, 80(%rax)
    movapd %xmm6, 96(%rax)
    movapd %xmm7, 112(%rax)
    movapd %xmm8, 128(%rax)
    movapd %xmm9, 144(%rax)
    movapd %xmm10, 160(%rax)
    movapd %xmm11, 176(%rax)
\name\()_prow:
    xorl %edx, %edx                 # column
\name\()_pcol:
    movsd (%rax,%rdx,8), %xmm0      # staged value
    testq %r9, %r9
    jz 2f
    addsd (%rcx,%rdx,8), %xmm0      # add mode: + the element of C
2:
    movsd %xmm0, (%rcx,%rdx,8)
    addq $1, %rdx
    cmpq %r11, %rdx
    jb \name\()_pcol
    addq $48, %rax                  # next staged row
    addq %r8, %rcx                  # next row of C
    subq $1, %r10
    jnz \name\()_prow
    ret
.endm

    RT_GEMM_MICRO .Lrt_gemm_micro, addpd        # GEMM: tile = A * B
    RT_GEMM_MICRO .Lrt_gemm_micro_sub, subpd    # gemm_sub: tile = -(A * B)

# ---------------------------------------------------------------------
# bsk_rt_ksse2_gemm -- C = A * B (DESIGN.md 6.6.1).
#   Inputs  : %rdi = C view (m x n), %rsi = A view (m x k),
#             %rdx = B view (k x n); C overlaps neither; elements of A
#             and B may be +-inf or NaN (DESIGN.md 6.6.4); C's previous
#             contents are never read
#   Outputs : %rax = KS_OK / KS_NONFINITE
#   Clobbers: all caller-saved registers
#   Callee-saved used: none here (the driver saves its own)
#   Frame   : none (tail-jumps to .Lrt_gemm_drv with %ecx = 0)
# ---------------------------------------------------------------------
    .globl bsk_rt_ksse2_gemm
    .hidden bsk_rt_ksse2_gemm
    .type bsk_rt_ksse2_gemm, @function
    .p2align 4
bsk_rt_ksse2_gemm:
    xorl %ecx, %ecx                 # mode 0: GEMM
    jmp .Lrt_gemm_drv
    .size bsk_rt_ksse2_gemm, . - bsk_rt_ksse2_gemm

# ---------------------------------------------------------------------
# bsk_rt_ksse2_gemm_sub -- C = C - A * B (DESIGN.md 6.6.1, 6.6.4).
#   Inputs  : %rdi = C view (m x n, input and output), %rsi = A view
#             (m x k), %rdx = B view (k x n); C overlaps neither; any
#             element may be +-inf or NaN
#   Outputs : %rax = KS_OK / KS_NONFINITE
#   Clobbers: all caller-saved registers
#   Callee-saved used: none here (the driver saves its own)
#   Frame   : none (tail-jumps to .Lrt_gemm_drv with %ecx = 1)
# ---------------------------------------------------------------------
    .globl bsk_rt_ksse2_gemm_sub
    .hidden bsk_rt_ksse2_gemm_sub
    .type bsk_rt_ksse2_gemm_sub, @function
    .p2align 4
bsk_rt_ksse2_gemm_sub:
    movl $1, %ecx                   # mode 1: gemm_sub
    jmp .Lrt_gemm_drv
    .size bsk_rt_ksse2_gemm_sub, . - bsk_rt_ksse2_gemm_sub

# ---------------------------------------------------------------------
# .Lrt_gemm_drv -- the blocked driver shared by GEMM and gemm_sub.
#   Inputs  : %rdi = C view, %rsi = A view, %rdx = B view (as above),
#             %rcx = mode: 0 GEMM (first pc block stored, later ones
#             added), 1 gemm_sub (every pc block added to C, with the
#             subtracting micro-kernel)
#   Outputs : %rax = KS_OK / KS_NONFINITE (finite check of C's view)
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = jc, %r12 = pc, %r13 = ic, %r14 = jr,
#             %r15 = ir, %rbp = frame pointer
#   Frame   : 48 bytes of saved registers + RT_GEMM_FRAME locals
#             (shapes, data pointers, byte strides, current block
#             sizes, mode, micro-kernel); %rsp = 0 (mod 16) at calls
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_gemm_drv:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    subq $RT_GEMM_FRAME, %rsp       # %rsp = 0 (mod 16)
    movq %rdi, RT_GEMM_CVIEW(%rsp)
    movq %rcx, RT_GEMM_SUB(%rsp)    # mode
    leaq .Lrt_gemm_micro(%rip), %rax
    leaq .Lrt_gemm_micro_sub(%rip), %r8
    testq %rcx, %rcx
    cmovnz %r8, %rax
    movq %rax, RT_GEMM_UKER(%rsp)   # micro-kernel of this entry
    movq MV_ROWS(%rsi), %rax
    movq %rax, RT_GEMM_M(%rsp)      # m
    movq MV_COLS(%rsi), %rax
    movq %rax, RT_GEMM_K(%rsp)      # k
    movq MV_COLS(%rdx), %rax
    movq %rax, RT_GEMM_N(%rsp)      # n
    movq MV_DATA(%rdi), %rax
    movq %rax, RT_GEMM_CDATA(%rsp)
    movq MV_LD(%rdi), %rax
    shlq $3, %rax
    movq %rax, RT_GEMM_LDC(%rsp)
    movq MV_DATA(%rsi), %rax
    movq %rax, RT_GEMM_ADATA(%rsp)
    movq MV_LD(%rsi), %rax
    shlq $3, %rax
    movq %rax, RT_GEMM_LDA(%rsp)
    movq MV_DATA(%rdx), %rax
    movq %rax, RT_GEMM_BDATA(%rsp)
    movq MV_LD(%rdx), %rax
    shlq $3, %rax
    movq %rax, RT_GEMM_LDB(%rsp)

    xorl %ebx, %ebx                 # jc = 0
.Lrt_gemm_jc:
    movq RT_GEMM_N(%rsp), %rax
    subq %rbx, %rax
    movl $RT_GEMM_NC, %ecx
    cmpq %rcx, %rax
    cmova %rcx, %rax
    movq %rax, RT_GEMM_NCUR(%rsp)   # nc = min(NC, n - jc)
    xorl %r12d, %r12d               # pc = 0
.Lrt_gemm_pc:
    movq RT_GEMM_K(%rsp), %rax
    subq %r12, %rax
    movl $RT_GEMM_KC, %ecx
    cmpq %rcx, %rax
    cmova %rcx, %rax
    movq %rax, RT_GEMM_KCUR(%rsp)   # kc = min(KC, k - pc)
    # pack B(pc .. pc+kc-1, jc .. jc+nc-1)
    leaq .Lrt_gemm_bp(%rip), %rdi
    movq %r12, %rsi
    imulq RT_GEMM_LDB(%rsp), %rsi
    addq RT_GEMM_BDATA(%rsp), %rsi
    leaq (%rsi,%rbx,8), %rsi        # &B(pc, jc)
    movq RT_GEMM_LDB(%rsp), %rdx
    movq RT_GEMM_KCUR(%rsp), %rcx
    movq RT_GEMM_NCUR(%rsp), %r8
    call .Lrt_gemm_packB
    xorl %r13d, %r13d               # ic = 0
.Lrt_gemm_ic:
    movq RT_GEMM_M(%rsp), %rax
    subq %r13, %rax
    movl $RT_GEMM_MC, %ecx
    cmpq %rcx, %rax
    cmova %rcx, %rax
    movq %rax, RT_GEMM_MCUR(%rsp)   # mc = min(MC, m - ic)
    # pack A(ic .. ic+mc-1, pc .. pc+kc-1)
    leaq .Lrt_gemm_ap(%rip), %rdi
    movq %r13, %rsi
    imulq RT_GEMM_LDA(%rsp), %rsi
    addq RT_GEMM_ADATA(%rsp), %rsi
    leaq (%rsi,%r12,8), %rsi        # &A(ic, pc)
    movq RT_GEMM_LDA(%rsp), %rdx
    movq RT_GEMM_KCUR(%rsp), %rcx
    movq RT_GEMM_MCUR(%rsp), %r8
    call .Lrt_gemm_packA
    xorl %r14d, %r14d               # jr = 0
.Lrt_gemm_jr:
    xorl %r15d, %r15d               # ir = 0
.Lrt_gemm_ir:
    movq RT_GEMM_KCUR(%rsp), %rdx   # kc
    # A micro-panel: Ap + (ir / 4) * kc * 64 = Ap + ir * kc * 16
    movq %r15, %rdi
    imulq %rdx, %rdi
    shlq $4, %rdi
    leaq .Lrt_gemm_ap(%rip), %rax
    addq %rax, %rdi
    # B micro-panel: Bp + (jr / 6) * kc * 48 = Bp + jr * kc * 8
    movq %r14, %rsi
    imulq %rdx, %rsi
    leaq .Lrt_gemm_bp(%rip), %rax
    leaq (%rax,%rsi,8), %rsi
    # &C(ic + ir, jc + jr)
    leaq (%r13,%r15), %rcx
    imulq RT_GEMM_LDC(%rsp), %rcx
    addq RT_GEMM_CDATA(%rsp), %rcx
    leaq (%rbx,%r14), %rax
    leaq (%rcx,%rax,8), %rcx
    movq RT_GEMM_LDC(%rsp), %r8
    # add to C after the first k block (GEMM) or always (gemm_sub)
    xorl %r9d, %r9d
    testq %r12, %r12
    setnz %r9b
    orq RT_GEMM_SUB(%rsp), %r9
    movq RT_GEMM_MCUR(%rsp), %r10
    subq %r15, %r10
    movl $RT_GEMM_MR, %eax
    cmpq %rax, %r10
    cmova %rax, %r10                # valid rows = min(4, mc - ir)
    movq RT_GEMM_NCUR(%rsp), %r11
    subq %r14, %r11
    movl $RT_GEMM_NR, %eax
    cmpq %rax, %r11
    cmova %rax, %r11                # valid columns = min(6, nc - jr)
    call *RT_GEMM_UKER(%rsp)        # .Lrt_gemm_micro / _micro_sub
    addq $RT_GEMM_MR, %r15
    cmpq RT_GEMM_MCUR(%rsp), %r15
    jb .Lrt_gemm_ir
    addq $RT_GEMM_NR, %r14
    cmpq RT_GEMM_NCUR(%rsp), %r14
    jb .Lrt_gemm_jr
    addq $RT_GEMM_MC, %r13
    cmpq RT_GEMM_M(%rsp), %r13
    jb .Lrt_gemm_ic
    addq $RT_GEMM_KC, %r12
    cmpq RT_GEMM_K(%rsp), %r12
    jb .Lrt_gemm_pc
    addq $RT_GEMM_NC, %rbx
    cmpq RT_GEMM_N(%rsp), %rbx
    jb .Lrt_gemm_jc

    movq RT_GEMM_CVIEW(%rsp), %rdi
    call bsk_rt_ksse2_chkfin        # %rax = KS_OK / KS_NONFINITE
    addq $RT_GEMM_FRAME, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret

# Packing buffers and the partial-tile staging area (DESIGN.md 6.6.6)
    .bss
    .p2align 6
.Lrt_gemm_ap:
    .zero RT_GEMM_AP_BYTES
    .p2align 6
.Lrt_gemm_bp:
    .zero RT_GEMM_BP_BYTES
    .p2align 6
.Lrt_gemm_tile:
    .zero RT_GEMM_MR * RT_GEMM_NR * 8

    .section .note.GNU-stack,"",@progbits
