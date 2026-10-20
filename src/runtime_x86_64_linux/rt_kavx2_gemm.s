# =====================================================================
# src/runtime_x86_64_linux/rt_kavx2_gemm.s -- AVX2/FMA matrix product and
# product update of the "avx2" variant (docs/DESIGN.md 6.6.1, 6.6.4,
# 6.6.5, 6.6.7; LANGUAGE.md 7.14.7). Reached only through the variant
# table, whose record requires KF_X64_AVX2 | KF_X64_FMA (OS YMM state included).
#
# Defines (private to the runtime, .globl + .hidden):
#   bsk_rt_kavx2_gemm     C = A * B      (A m x k, B k x n, C m x n)
#                         -> %rax KS_OK / KS_NONFINITE
#   bsk_rt_kavx2_gemm_sub C = C - A * B  (same shapes; C in and out)
#                         -> %rax KS_OK / KS_NONFINITE
#
# Both entries run one driver (.Lrt_kavx2_gemm_drv) with the same
# packing, blocking and staging tile; they differ only in the
# micro-kernel (RT_KAVX2_GEMM_MICRO instantiated twice: GEMM with
# vfmadd231pd, gemm_sub with vfnmadd231pd) and in when C is read: GEMM
# stores the first pc block and adds the later ones, gemm_sub adds the
# tile to C for EVERY pc block, so each element is C0 - sum of the
# products (class R, k + 1 terms, DESIGN.md 6.6.4).
#
# Goto/BLIS structure (as rt_ksse2_gemm.s):
#   for jc (columns, step NC):
#     for pc (inner dimension, step KC):
#       pack B(pc.., jc..) into NR-wide micro-panels   (Bp, k-major)
#       for ic (rows, step MC):
#         pack A(ic.., pc..) into MR-high micro-panels (Ap, k-major)
#         for jr (step NR): for ir (step MR):
#           micro-kernel: the MR x NR block of C stays in registers for
#           the whole kc loop; stored (pc = 0) or added to C (pc > 0;
#           gemm_sub: every pc)
#
# Micro-kernel MR x NR = 6 x 8 (the BLIS Haswell shape). Each row of the
# C tile is 8 contiguous doubles = two ymm accumulators, so 12
# accumulators (%ymm4-%ymm15) hold the tile; %ymm0/%ymm1 hold one k-row
# of the B micro-panel (64 bytes, one cache line) and %ymm2/%ymm3 the
# broadcast A values (vbroadcastsd from the packed panel). Per k step:
# 2 B loads + 6 broadcasts feed 12 vfmadd231pd, so the two FMA ports
# (5-cycle latency, 10 FMAs in flight needed) stay busy with 12
# independent chains, and the two load ports carry 8 loads per 6
# cycles. 4 x 12 would need 3 B loads + 4 broadcasts (7 loads) but
# rows of 12 columns, i.e. 96-byte B rows straddling cache lines; 6 x 8
# keeps every packed B row on one line.
#
# Blocking (Haswell i7-4790: 32 KiB L1D, 256 KiB L2, 8 MiB L3):
#   KC = 256: one B micro-panel (KC x 8 doubles = 16 KiB) stays in L1;
#   MC = 72:  the packed A block (MC x KC = 144 KiB) stays in L2;
#   NC = 2048: the packed B block (KC x NC = 4 MiB) stays in L3.
#
# Edges: zero-padded packing and a partial store through a 6 x 8
# staging tile. IEEE propagation (DESIGN.md 6.6.4): inputs may hold
# +-inf and NaN. No path tests a factor for zero, so 0 * inf reaches
# its element as NaN. A padding lane (a zero row of Ap or column of Bp)
# may hold 0 * inf = NaN, but such lanes are only in the staged part
# that is never copied out; full tiles have no padding lanes. Nothing
# outside the views is read into a result (packing copies only the
# mc x kc / kc x nc blocks; the C prefetches load no register) or
# written (partial tiles store only the valid part).
# Class R (DESIGN.md 6.6.4): the summation order depends only on the
# shapes (fixed blocking, fixed micro-kernel order), never on addresses
# or alignment (C is accessed with vmovupd/vaddpd on unaligned memory;
# the packed buffers are 64-byte aligned). The finite check is a
# separate vectorised pass over C (bsk_rt_kavx2_chkfin), so
# KS_NONFINITE is reported exactly when a stored element is not finite.
# Every exit runs vzeroupper (DESIGN.md 6.6.7).
# =====================================================================
.include "baysick.inc"

.equ RT_KAVX2_GEMM_MR, 6
.equ RT_KAVX2_GEMM_NR, 8
# Blocking (tunable with --defsym for experiments; DESIGN.md 6.6.5):
.ifndef RT_KAVX2_GEMM_KC
.equ RT_KAVX2_GEMM_KC, 256          # inner-dimension block depth
.endif
.ifndef RT_KAVX2_GEMM_MC
.equ RT_KAVX2_GEMM_MC, 72           # row block height (multiple of MR)
.endif
.ifndef RT_KAVX2_GEMM_NC
.equ RT_KAVX2_GEMM_NC, 2048         # column block width (multiple of NR)
.endif
.if (RT_KAVX2_GEMM_MC % RT_KAVX2_GEMM_MR) != 0
    .error "rt_kavx2_gemm.s: MC must be a multiple of MR"
.endif
.if (RT_KAVX2_GEMM_NC % RT_KAVX2_GEMM_NR) != 0
    .error "rt_kavx2_gemm.s: NC must be a multiple of NR"
.endif
.equ RT_KAVX2_GEMM_AP_BYTES, RT_KAVX2_GEMM_MC * RT_KAVX2_GEMM_KC * 8
.equ RT_KAVX2_GEMM_BP_BYTES, RT_KAVX2_GEMM_NC * RT_KAVX2_GEMM_KC * 8
.if (RT_KAVX2_GEMM_AP_BYTES + RT_KAVX2_GEMM_BP_BYTES) > 8388608
    .error "rt_kavx2_gemm.s: packing buffers exceed 8 MiB (DESIGN.md 6.6.6)"
.endif

# Frame of bsk_rt_kavx2_gemm (offsets from %rsp)
.equ RT_KAVX2_GEMM_M,     0
.equ RT_KAVX2_GEMM_N,     8
.equ RT_KAVX2_GEMM_K,     16
.equ RT_KAVX2_GEMM_CDATA, 24
.equ RT_KAVX2_GEMM_LDC,   32        # bytes
.equ RT_KAVX2_GEMM_ADATA, 40
.equ RT_KAVX2_GEMM_LDA,   48        # bytes
.equ RT_KAVX2_GEMM_BDATA, 56
.equ RT_KAVX2_GEMM_LDB,   64        # bytes
.equ RT_KAVX2_GEMM_NCUR,  72        # current nc
.equ RT_KAVX2_GEMM_KCUR,  80        # current kc
.equ RT_KAVX2_GEMM_MCUR,  88        # current mc
.equ RT_KAVX2_GEMM_CVIEW, 96        # C view pointer
.equ RT_KAVX2_GEMM_SUB,   104       # 1 for gemm_sub, 0 for GEMM
.equ RT_KAVX2_GEMM_UKER,  112       # micro-kernel of the entry
.equ RT_KAVX2_GEMM_FRAME, 120       # 56 + 120 = 0 (mod 16)

    .text

# ---------------------------------------------------------------------
# .Lrt_kavx2_gemm_packA -- pack an mc x kc block of A into MR-high panels.
#   Panel q holds rows 6q..6q+5; for each k, 6 doubles (a0 .. a5) =
#   48 bytes; rows past mc are zero. Filled row by row: each source row
#   is read contiguously and written with a 48-byte stride.
#   Private convention (leaf):
#   Inputs  : %rdi = Ap (64-byte aligned), %rsi = &A(ic,pc),
#             %rdx = A stride in bytes, %rcx = kc (>= 1), %r8 = mc (>= 1)
#   Clobbers: %rax %rsi %rdi %r8-%r11 %xmm0-%xmm3
#   Callee-saved used: %rbx = row slot within the panel (saved)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_kavx2_gemm_packA:
    pushq %rbx
    vxorpd %xmm3, %xmm3, %xmm3      # zero for padding rows
.Lrt_kavx2_gemm_packA_panel:
    xorl %ebx, %ebx                 # i = row within the panel
.Lrt_kavx2_gemm_packA_row:
    leaq (%rdi,%rbx,8), %r11        # d = &Ap[panel][k = 0][i]
    cmpq %r8, %rbx
    jae .Lrt_kavx2_gemm_packA_zero  # row past mc: zero padding
    movq %rbx, %r10
    imulq %rdx, %r10
    addq %rsi, %r10                 # s = &A(ic + 6q + i, pc)
    xorl %eax, %eax                 # kk
    movq %rcx, %r9
    andq $-4, %r9                   # k covered four at a time
    jz .Lrt_kavx2_gemm_packA_one
.Lrt_kavx2_gemm_packA_four:
    vmovupd (%r10,%rax,8), %ymm0    # a(i, kk .. kk+3)
    vextractf128 $1, %ymm0, %xmm1   # (a kk+2, a kk+3)
    vmovlpd %xmm0, (%r11)           # scatter with the 48-byte k stride
    vmovhpd %xmm0, 48(%r11)
    vmovlpd %xmm1, 96(%r11)
    vmovhpd %xmm1, 144(%r11)
    addq $192, %r11
    addq $4, %rax
    cmpq %r9, %rax
    jb .Lrt_kavx2_gemm_packA_four
.Lrt_kavx2_gemm_packA_one:
    cmpq %rcx, %rax
    jae .Lrt_kavx2_gemm_packA_next
    vmovsd (%r10,%rax,8), %xmm0
    vmovsd %xmm0, (%r11)
    addq $48, %r11
    addq $1, %rax
    jmp .Lrt_kavx2_gemm_packA_one
.Lrt_kavx2_gemm_packA_zero:
    movq %rcx, %rax                 # kc zero slots
1:
    vmovsd %xmm3, (%r11)
    addq $48, %r11
    subq $1, %rax
    jnz 1b
.Lrt_kavx2_gemm_packA_next:
    addq $1, %rbx
    cmpq $RT_KAVX2_GEMM_MR, %rbx
    jb .Lrt_kavx2_gemm_packA_row
    # next panel: Ap += kc * 48, A rows += 6, mc -= 6
    imulq $48, %rcx, %rax
    addq %rax, %rdi
    imulq $RT_KAVX2_GEMM_MR, %rdx, %rax
    addq %rax, %rsi
    subq $RT_KAVX2_GEMM_MR, %r8
    jg .Lrt_kavx2_gemm_packA_panel
    popq %rbx
    ret

# ---------------------------------------------------------------------
# .Lrt_kavx2_gemm_packB -- pack a kc x nc block of B into NR-wide panels.
#   Panel t holds columns 8t..8t+7; for each k, 8 doubles (64 bytes,
#   one cache line); columns past nc are zero.
#   Private convention (leaf):
#   Inputs  : %rdi = Bp (64-byte aligned), %rsi = &B(pc,jc),
#             %rdx = B stride in bytes, %rcx = kc (>= 1), %r8 = nc (>= 1)
#   Clobbers: %rax %rsi %rdi %r8-%r11 %ymm0-%ymm2
#   Callee-saved used: %rbx = column index in a partial panel (saved)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_kavx2_gemm_packB:
    pushq %rbx
    vxorpd %ymm2, %ymm2, %ymm2
.Lrt_kavx2_gemm_packB_panel:
    movq %rsi, %r10                 # s = &B(pc, column 8t)
    movq %rdi, %r11                 # d = panel start
    movq %rcx, %rax                 # k rows left
    cmpq $RT_KAVX2_GEMM_NR, %r8
    jb .Lrt_kavx2_gemm_packB_part
.Lrt_kavx2_gemm_packB_full:
    vmovupd (%r10), %ymm0           # eight columns of one k-row
    vmovupd 32(%r10), %ymm1
    vmovapd %ymm0, (%r11)
    vmovapd %ymm1, 32(%r11)
    addq %rdx, %r10
    addq $64, %r11
    subq $1, %rax
    jnz .Lrt_kavx2_gemm_packB_full
    jmp .Lrt_kavx2_gemm_packB_next
.Lrt_kavx2_gemm_packB_part:
    vmovapd %ymm2, (%r11)           # zero the eight slots ...
    vmovapd %ymm2, 32(%r11)
    xorl %ebx, %ebx
1:
    movq (%r10,%rbx,8), %r9         # ... then copy the nc valid ones
    movq %r9, (%r11,%rbx,8)
    addq $1, %rbx
    cmpq %r8, %rbx
    jb 1b
    addq %rdx, %r10
    addq $64, %r11
    subq $1, %rax
    jnz .Lrt_kavx2_gemm_packB_part
.Lrt_kavx2_gemm_packB_next:
    movq %rcx, %rax
    shlq $6, %rax
    addq %rax, %rdi                 # next panel: Bp += kc * 64
    addq $64, %rsi                  # B columns += 8
    subq $RT_KAVX2_GEMM_NR, %r8
    jg .Lrt_kavx2_gemm_packB_panel
    popq %rbx
    ret

# RT_KAVX2_GEMM_KSTEP kk, op -- the whole 6 x 8 update for k step \kk of
#   an unrolled group (A at 48 kk, B at 64 kk), with op = vfmadd231pd
#   (GEMM: acc += a_r * b) or vfnmadd231pd (gemm_sub: acc -= a_r * b,
#   one fused rounding either way; never a zero test):
#   acc(r, 0..3) op= a_r * b(0..3), acc(r, 4..7) op= a_r * b(4..7).
.macro RT_KAVX2_GEMM_KSTEP kk, op
    vmovapd 64*\kk(%rsi), %ymm0             # b(k, 0..3)
    vmovapd 64*\kk+32(%rsi), %ymm1          # b(k, 4..7)
    vbroadcastsd 48*\kk(%rdi), %ymm2        # a(0, k) in all lanes
    \op %ymm0, %ymm2, %ymm4
    \op %ymm1, %ymm2, %ymm5
    vbroadcastsd 48*\kk+8(%rdi), %ymm3      # a(1, k)
    \op %ymm0, %ymm3, %ymm6
    \op %ymm1, %ymm3, %ymm7
    vbroadcastsd 48*\kk+16(%rdi), %ymm2     # a(2, k)
    \op %ymm0, %ymm2, %ymm8
    \op %ymm1, %ymm2, %ymm9
    vbroadcastsd 48*\kk+24(%rdi), %ymm3     # a(3, k)
    \op %ymm0, %ymm3, %ymm10
    \op %ymm1, %ymm3, %ymm11
    vbroadcastsd 48*\kk+32(%rdi), %ymm2     # a(4, k)
    \op %ymm0, %ymm2, %ymm12
    \op %ymm1, %ymm2, %ymm13
    vbroadcastsd 48*\kk+40(%rdi), %ymm3     # a(5, k)
    \op %ymm0, %ymm3, %ymm14
    \op %ymm1, %ymm3, %ymm15
.endm

# RT_KAVX2_GEMM_STROW c0, c1, add -- write one row of the tile to C at
#   (%rax): with add = 1, C + acc (one rounding per element); else acc.
.macro RT_KAVX2_GEMM_STROW c0, c1, add
.if \add
    vaddpd (%rax), \c0, \c0
    vaddpd 32(%rax), \c1, \c1
.endif
    vmovupd \c0, (%rax)
    vmovupd \c1, 32(%rax)
    addq %r8, %rax                  # next row of C
.endm

# ---------------------------------------------------------------------
# RT_KAVX2_GEMM_MICRO name, op -- defines the 6 x 8 register-blocked
#   micro-kernel \name, accumulating with \op (vfmadd231pd: GEMM, the
#   tile is A * B; vfnmadd231pd: gemm_sub, the tile is -(A * B)).
#   Instantiated as .Lrt_kavx2_gemm_micro and .Lrt_kavx2_gemm_micro_sub.
#   Private convention (leaf):
#   Inputs  : %rdi = A micro-panel, %rsi = B micro-panel, %rdx = kc
#             (>= 1), %rcx = &C(tile), %r8 = C stride in bytes,
#             %r9 = 1 to add the tile to C / 0 to store it,
#             %r10 = valid rows (1..6), %r11 = valid columns (1..8)
#   Outputs : the valid rows x columns of the tile at %rcx, stored or
#             added to C; nothing else of C is read or written
#   Clobbers: %rax %rdx %rsi %rdi %r9-%r11 %ymm0-%ymm15
#             (upper halves left dirty: the caller ends with vzeroupper)
#   Callee-saved used: none
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
.macro RT_KAVX2_GEMM_MICRO name, op
    .p2align 4
\name:
    vxorpd %ymm4, %ymm4, %ymm4      # 12 accumulators = 0
    vxorpd %ymm5, %ymm5, %ymm5
    vxorpd %ymm6, %ymm6, %ymm6
    vxorpd %ymm7, %ymm7, %ymm7
    vxorpd %ymm8, %ymm8, %ymm8
    vxorpd %ymm9, %ymm9, %ymm9
    vxorpd %ymm10, %ymm10, %ymm10
    vxorpd %ymm11, %ymm11, %ymm11
    vxorpd %ymm12, %ymm12, %ymm12
    vxorpd %ymm13, %ymm13, %ymm13
    vxorpd %ymm14, %ymm14, %ymm14
    vxorpd %ymm15, %ymm15, %ymm15
    # warm the C tile (six rows, 64 bytes each, possibly two lines;
    # a prefetch never faults, so reaching past a view is harmless)
    movq %rcx, %rax
    prefetcht0 (%rax)
    prefetcht0 63(%rax)
    addq %r8, %rax
    prefetcht0 (%rax)
    prefetcht0 63(%rax)
    addq %r8, %rax
    prefetcht0 (%rax)
    prefetcht0 63(%rax)
    addq %r8, %rax
    prefetcht0 (%rax)
    prefetcht0 63(%rax)
    addq %r8, %rax
    prefetcht0 (%rax)
    prefetcht0 63(%rax)
    addq %r8, %rax
    prefetcht0 (%rax)
    prefetcht0 63(%rax)
    movq %rdx, %rax
    shrq $2, %rax                   # groups of four k steps
    jz \name\()_k1
\name\()_k4:
    prefetcht0 384(%rdi)            # A panel, two groups ahead
    RT_KAVX2_GEMM_KSTEP 0, \op
    RT_KAVX2_GEMM_KSTEP 1, \op
    prefetcht0 448(%rdi)
    RT_KAVX2_GEMM_KSTEP 2, \op
    RT_KAVX2_GEMM_KSTEP 3, \op
    addq $192, %rdi                 # 4 k steps of A (4 x 48 bytes)
    addq $256, %rsi                 # 4 k steps of B (4 x 64 bytes)
    subq $1, %rax
    jnz \name\()_k4
\name\()_k1:
    andq $3, %rdx                   # remaining single k steps
    jz \name\()_store
1:
    RT_KAVX2_GEMM_KSTEP 0, \op
    addq $48, %rdi
    addq $64, %rsi
    subq $1, %rdx
    jnz 1b
\name\()_store:
    cmpq $RT_KAVX2_GEMM_MR, %r10
    jne \name\()_partial
    cmpq $RT_KAVX2_GEMM_NR, %r11
    jne \name\()_partial
    movq %rcx, %rax                 # full tile straight into C
    testq %r9, %r9
    jnz \name\()_add
    RT_KAVX2_GEMM_STROW %ymm4, %ymm5, 0
    RT_KAVX2_GEMM_STROW %ymm6, %ymm7, 0
    RT_KAVX2_GEMM_STROW %ymm8, %ymm9, 0
    RT_KAVX2_GEMM_STROW %ymm10, %ymm11, 0
    RT_KAVX2_GEMM_STROW %ymm12, %ymm13, 0
    RT_KAVX2_GEMM_STROW %ymm14, %ymm15, 0
    ret
\name\()_add:
    RT_KAVX2_GEMM_STROW %ymm4, %ymm5, 1
    RT_KAVX2_GEMM_STROW %ymm6, %ymm7, 1
    RT_KAVX2_GEMM_STROW %ymm8, %ymm9, 1
    RT_KAVX2_GEMM_STROW %ymm10, %ymm11, 1
    RT_KAVX2_GEMM_STROW %ymm12, %ymm13, 1
    RT_KAVX2_GEMM_STROW %ymm14, %ymm15, 1
    ret
\name\()_partial:
    # stage the tile (row-major 6 x 8), then copy the valid part; the
    # padding lanes (which may be NaN from 0 * inf) stay in the tile
    leaq .Lrt_kavx2_gemm_tile(%rip), %rax
    vmovapd %ymm4, 0(%rax)
    vmovapd %ymm5, 32(%rax)
    vmovapd %ymm6, 64(%rax)
    vmovapd %ymm7, 96(%rax)
    vmovapd %ymm8, 128(%rax)
    vmovapd %ymm9, 160(%rax)
    vmovapd %ymm10, 192(%rax)
    vmovapd %ymm11, 224(%rax)
    vmovapd %ymm12, 256(%rax)
    vmovapd %ymm13, 288(%rax)
    vmovapd %ymm14, 320(%rax)
    vmovapd %ymm15, 352(%rax)
\name\()_prow:
    xorl %edx, %edx                 # column
\name\()_pcol:
    vmovsd (%rax,%rdx,8), %xmm0     # staged value
    testq %r9, %r9
    jz 2f
    vaddsd (%rcx,%rdx,8), %xmm0, %xmm0  # add mode: staged + C element
2:
    vmovsd %xmm0, (%rcx,%rdx,8)
    addq $1, %rdx
    cmpq %r11, %rdx
    jb \name\()_pcol
    addq $64, %rax                  # next staged row
    addq %r8, %rcx                  # next row of C
    subq $1, %r10
    jnz \name\()_prow
    ret
.endm

    RT_KAVX2_GEMM_MICRO .Lrt_kavx2_gemm_micro, vfmadd231pd       # A * B
    RT_KAVX2_GEMM_MICRO .Lrt_kavx2_gemm_micro_sub, vfnmadd231pd  # -(A * B)

# ---------------------------------------------------------------------
# bsk_rt_kavx2_gemm -- C = A * B (DESIGN.md 6.6.1).
#   Inputs  : %rdi = C view (m x n), %rsi = A view (m x k),
#             %rdx = B view (k x n); C overlaps neither; elements of A
#             and B may be +-inf or NaN (DESIGN.md 6.6.4); C's previous
#             contents are never read
#   Outputs : %rax = KS_OK / KS_NONFINITE
#   Clobbers: all caller-saved registers; upper ymm state clean on exit
#   Callee-saved used: none here (the driver saves its own)
#   Frame   : none (tail-jumps to .Lrt_kavx2_gemm_drv with %ecx = 0)
# ---------------------------------------------------------------------
    .globl bsk_rt_kavx2_gemm
    .hidden bsk_rt_kavx2_gemm
    .type bsk_rt_kavx2_gemm, @function
    .p2align 4
bsk_rt_kavx2_gemm:
    xorl %ecx, %ecx                 # mode 0: GEMM
    jmp .Lrt_kavx2_gemm_drv
    .size bsk_rt_kavx2_gemm, . - bsk_rt_kavx2_gemm

# ---------------------------------------------------------------------
# bsk_rt_kavx2_gemm_sub -- C = C - A * B (DESIGN.md 6.6.1, 6.6.4).
#   Inputs  : %rdi = C view (m x n, input and output), %rsi = A view
#             (m x k), %rdx = B view (k x n); C overlaps neither; any
#             element may be +-inf or NaN
#   Outputs : %rax = KS_OK / KS_NONFINITE
#   Clobbers: all caller-saved registers; upper ymm state clean on exit
#   Callee-saved used: none here (the driver saves its own)
#   Frame   : none (tail-jumps to .Lrt_kavx2_gemm_drv with %ecx = 1)
# ---------------------------------------------------------------------
    .globl bsk_rt_kavx2_gemm_sub
    .hidden bsk_rt_kavx2_gemm_sub
    .type bsk_rt_kavx2_gemm_sub, @function
    .p2align 4
bsk_rt_kavx2_gemm_sub:
    movl $1, %ecx                   # mode 1: gemm_sub
    jmp .Lrt_kavx2_gemm_drv
    .size bsk_rt_kavx2_gemm_sub, . - bsk_rt_kavx2_gemm_sub

# ---------------------------------------------------------------------
# .Lrt_kavx2_gemm_drv -- the blocked driver shared by GEMM and gemm_sub.
#   Inputs  : %rdi = C view, %rsi = A view, %rdx = B view (as above),
#             %rcx = mode: 0 GEMM (first pc block stored, later ones
#             added), 1 gemm_sub (every pc block added to C, with the
#             subtracting micro-kernel)
#   Outputs : %rax = KS_OK / KS_NONFINITE (finite check of C's view)
#   Clobbers: all caller-saved registers; upper ymm state clean on exit
#             (bsk_rt_kavx2_chkfin, the only exit, ends with vzeroupper)
#   Callee-saved used: %rbx = jc, %r12 = pc, %r13 = ic, %r14 = jr,
#             %r15 = ir, %rbp = frame pointer
#   Frame   : 48 bytes of saved registers + RT_KAVX2_GEMM_FRAME locals
#             (shapes, data pointers, byte strides, current block
#             sizes, mode, micro-kernel); %rsp = 0 (mod 16) at calls
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_kavx2_gemm_drv:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    subq $RT_KAVX2_GEMM_FRAME, %rsp     # %rsp = 0 (mod 16)
    movq %rdi, RT_KAVX2_GEMM_CVIEW(%rsp)
    movq %rcx, RT_KAVX2_GEMM_SUB(%rsp)  # mode
    leaq .Lrt_kavx2_gemm_micro(%rip), %rax
    leaq .Lrt_kavx2_gemm_micro_sub(%rip), %r8
    testq %rcx, %rcx
    cmovnz %r8, %rax
    movq %rax, RT_KAVX2_GEMM_UKER(%rsp) # micro-kernel of this entry
    movq MV_ROWS(%rsi), %rax
    movq %rax, RT_KAVX2_GEMM_M(%rsp)    # m
    movq MV_COLS(%rsi), %rax
    movq %rax, RT_KAVX2_GEMM_K(%rsp)    # k
    movq MV_COLS(%rdx), %rax
    movq %rax, RT_KAVX2_GEMM_N(%rsp)    # n
    movq MV_DATA(%rdi), %rax
    movq %rax, RT_KAVX2_GEMM_CDATA(%rsp)
    movq MV_LD(%rdi), %rax
    shlq $3, %rax
    movq %rax, RT_KAVX2_GEMM_LDC(%rsp)
    movq MV_DATA(%rsi), %rax
    movq %rax, RT_KAVX2_GEMM_ADATA(%rsp)
    movq MV_LD(%rsi), %rax
    shlq $3, %rax
    movq %rax, RT_KAVX2_GEMM_LDA(%rsp)
    movq MV_DATA(%rdx), %rax
    movq %rax, RT_KAVX2_GEMM_BDATA(%rsp)
    movq MV_LD(%rdx), %rax
    shlq $3, %rax
    movq %rax, RT_KAVX2_GEMM_LDB(%rsp)

    xorl %ebx, %ebx                 # jc = 0
.Lrt_kavx2_gemm_jc:
    movq RT_KAVX2_GEMM_N(%rsp), %rax
    subq %rbx, %rax
    movl $RT_KAVX2_GEMM_NC, %ecx
    cmpq %rcx, %rax
    cmova %rcx, %rax
    movq %rax, RT_KAVX2_GEMM_NCUR(%rsp) # nc = min(NC, n - jc)
    xorl %r12d, %r12d               # pc = 0
.Lrt_kavx2_gemm_pc:
    movq RT_KAVX2_GEMM_K(%rsp), %rax
    subq %r12, %rax
    movl $RT_KAVX2_GEMM_KC, %ecx
    cmpq %rcx, %rax
    cmova %rcx, %rax
    movq %rax, RT_KAVX2_GEMM_KCUR(%rsp) # kc = min(KC, k - pc)
    # pack B(pc .. pc+kc-1, jc .. jc+nc-1)
    leaq .Lrt_kavx2_gemm_bp(%rip), %rdi
    movq %r12, %rsi
    imulq RT_KAVX2_GEMM_LDB(%rsp), %rsi
    addq RT_KAVX2_GEMM_BDATA(%rsp), %rsi
    leaq (%rsi,%rbx,8), %rsi        # &B(pc, jc)
    movq RT_KAVX2_GEMM_LDB(%rsp), %rdx
    movq RT_KAVX2_GEMM_KCUR(%rsp), %rcx
    movq RT_KAVX2_GEMM_NCUR(%rsp), %r8
    call .Lrt_kavx2_gemm_packB
    xorl %r13d, %r13d               # ic = 0
.Lrt_kavx2_gemm_ic:
    movq RT_KAVX2_GEMM_M(%rsp), %rax
    subq %r13, %rax
    movl $RT_KAVX2_GEMM_MC, %ecx
    cmpq %rcx, %rax
    cmova %rcx, %rax
    movq %rax, RT_KAVX2_GEMM_MCUR(%rsp) # mc = min(MC, m - ic)
    # pack A(ic .. ic+mc-1, pc .. pc+kc-1)
    leaq .Lrt_kavx2_gemm_ap(%rip), %rdi
    movq %r13, %rsi
    imulq RT_KAVX2_GEMM_LDA(%rsp), %rsi
    addq RT_KAVX2_GEMM_ADATA(%rsp), %rsi
    leaq (%rsi,%r12,8), %rsi        # &A(ic, pc)
    movq RT_KAVX2_GEMM_LDA(%rsp), %rdx
    movq RT_KAVX2_GEMM_KCUR(%rsp), %rcx
    movq RT_KAVX2_GEMM_MCUR(%rsp), %r8
    call .Lrt_kavx2_gemm_packA
    xorl %r14d, %r14d               # jr = 0
.Lrt_kavx2_gemm_jr:
    xorl %r15d, %r15d               # ir = 0
.Lrt_kavx2_gemm_ir:
    movq RT_KAVX2_GEMM_KCUR(%rsp), %rdx     # kc
    # A micro-panel: Ap + (ir / 6) * kc * 48 = Ap + ir * kc * 8
    movq %r15, %rdi
    imulq %rdx, %rdi
    leaq .Lrt_kavx2_gemm_ap(%rip), %rax
    leaq (%rax,%rdi,8), %rdi
    # B micro-panel: Bp + (jr / 8) * kc * 64 = Bp + jr * kc * 8
    movq %r14, %rsi
    imulq %rdx, %rsi
    leaq .Lrt_kavx2_gemm_bp(%rip), %rax
    leaq (%rax,%rsi,8), %rsi
    # &C(ic + ir, jc + jr)
    leaq (%r13,%r15), %rcx
    imulq RT_KAVX2_GEMM_LDC(%rsp), %rcx
    addq RT_KAVX2_GEMM_CDATA(%rsp), %rcx
    leaq (%rbx,%r14), %rax
    leaq (%rcx,%rax,8), %rcx
    movq RT_KAVX2_GEMM_LDC(%rsp), %r8
    # add to C after the first k block (GEMM) or always (gemm_sub)
    xorl %r9d, %r9d
    testq %r12, %r12
    setnz %r9b
    orq RT_KAVX2_GEMM_SUB(%rsp), %r9
    movq RT_KAVX2_GEMM_MCUR(%rsp), %r10
    subq %r15, %r10
    movl $RT_KAVX2_GEMM_MR, %eax
    cmpq %rax, %r10
    cmova %rax, %r10                # valid rows = min(6, mc - ir)
    movq RT_KAVX2_GEMM_NCUR(%rsp), %r11
    subq %r14, %r11
    movl $RT_KAVX2_GEMM_NR, %eax
    cmpq %rax, %r11
    cmova %rax, %r11                # valid columns = min(8, nc - jr)
    call *RT_KAVX2_GEMM_UKER(%rsp)  # .Lrt_kavx2_gemm_micro / _micro_sub
    addq $RT_KAVX2_GEMM_MR, %r15
    cmpq RT_KAVX2_GEMM_MCUR(%rsp), %r15
    jb .Lrt_kavx2_gemm_ir
    addq $RT_KAVX2_GEMM_NR, %r14
    cmpq RT_KAVX2_GEMM_NCUR(%rsp), %r14
    jb .Lrt_kavx2_gemm_jr
    addq $RT_KAVX2_GEMM_MC, %r13
    cmpq RT_KAVX2_GEMM_M(%rsp), %r13
    jb .Lrt_kavx2_gemm_ic
    addq $RT_KAVX2_GEMM_KC, %r12
    cmpq RT_KAVX2_GEMM_K(%rsp), %r12
    jb .Lrt_kavx2_gemm_pc
    addq $RT_KAVX2_GEMM_NC, %rbx
    cmpq RT_KAVX2_GEMM_N(%rsp), %rbx
    jb .Lrt_kavx2_gemm_jc

    movq RT_KAVX2_GEMM_CVIEW(%rsp), %rdi
    call bsk_rt_kavx2_chkfin        # %rax = KS_*; ends with vzeroupper
    addq $RT_KAVX2_GEMM_FRAME, %rsp
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
.Lrt_kavx2_gemm_ap:
    .zero RT_KAVX2_GEMM_AP_BYTES
    .p2align 6
.Lrt_kavx2_gemm_bp:
    .zero RT_KAVX2_GEMM_BP_BYTES
    .p2align 6
.Lrt_kavx2_gemm_tile:
    .zero RT_KAVX2_GEMM_MR * RT_KAVX2_GEMM_NR * 8

    .section .note.GNU-stack,"",@progbits
