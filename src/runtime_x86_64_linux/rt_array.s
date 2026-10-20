# =====================================================================
# src/runtime_x86_64_linux/rt_array.s -- array element addressing with
# bounds checks.
#
# Defines: bsk_aref1 bsk_aref2 bsk_saref1 bsk_saref2   (DESIGN.md sections
#          6.2, 6.4, 6.7, 6.8)
# Defines (private to the runtime, .globl + .hidden):
#   bsk_rt_round_half   floor(x + 1/2), exactly (CHANGE, rt_ed4.s)
# A subscript s is converted to r = floor(s + 0.5) (LANGUAGE.md 7.11),
# evaluated exactly: r = floor(s), plus 1 if s - floor(s) >= 0.5. The
# IEEE sum s + 0.5 is NOT used: it can round up (s = 0.5 - 2^-54 gives
# 1.0), which would make r one too large.
# 0 <= r <= bound is checked on the rounded double before conversion to
# an integer, so huge or negative subscripts can never wrap.
# Element (i, j) is at RTA_DATA + 8 * (i * RTA_ROWLEN + j).
# Same algorithm as src/runtime/rt_array.s; floor() is built from SSE2
# (the baseline has no roundsd, DESIGN.md 6.4.3).
# =====================================================================
.include "baysick.inc"

# Bits of the double 2^52: from this magnitude on, every double is an
# integer (and +-inf / NaN have even larger magnitude bits).
.equ RT_D2P52_BITS, 0x4330000000000000

# RT_SUBSCRIPT xs, boundoff, out: round the subscript in register xs,
# check it against the u32 bound at boundoff(%rdi), leave the integer
# in the 64-bit register out. Error branch: SUBSCRIPT ERROR (no return).
# floor(s): if |s| >= 2^52 (or s is inf/NaN) s is its own floor;
# otherwise t = trunc(s) via cvttsd2si (exact, |s| < 2^52) and, when
# t > s (negative non-integer), floor = t - 1.
# Rounding: f = s - floor(s) is computed exactly whenever it matters
# (see src/runtime/rt_array.s), so "f >= 0.5" decides floor(s + 0.5)
# exactly. NaN: r stays NaN and the unordered compare with 0 takes the
# error branch; +-inf: r = +-inf fails a range test. So NaN, infinite,
# huge and negative subscripts are rejected before any conversion.
# Clobbers xs, %rax, %rcx, %xmm2 (r), %xmm3.
.macro RT_SUBSCRIPT xs, boundoff, out
    RT_ROUND_HALF \xs
    pxor %xmm3, %xmm3
    ucomisd %xmm3, %xmm2
    jb .Lrt_array_bad               # r < 0, or NaN (unordered)
    movl \boundoff(%rdi), %eax      # u32 bound, zero-extended
    cvtsi2sdq %rax, %xmm3           # bound as a double (exact)
    ucomisd %xmm3, %xmm2
    ja .Lrt_array_bad               # r > bound
    cvttsd2si %xmm2, \out           # 0 <= r <= bound: exact
.endm

# RT_ROUND_HALF xs: %xmm2 = floor(xs + 1/2), exactly (see above);
# +-inf and NaN come out as +-inf and NaN, huge values unchanged.
# Clobbers xs, %rax, %rcx, %xmm2.
.macro RT_ROUND_HALF xs
    movq \xs, %rax
    btrq $63, %rax                  # bits of |s|
    movabsq $RT_D2P52_BITS, %rcx
    movapd \xs, %xmm2               # r = s (if already integral/inf/NaN)
    cmpq %rcx, %rax
    jae .Lrt_array_floored_\@       # |s| >= 2^52, inf or NaN
    cvttsd2si \xs, %rax             # t = trunc(s)
    cvtsi2sdq %rax, %xmm2
    ucomisd \xs, %xmm2              # flags of t - s
    jbe .Lrt_array_floored_\@       # t <= s: floor(s) = t
    subq $1, %rax                   # negative with a fraction: t - 1
    cvtsi2sdq %rax, %xmm2
.Lrt_array_floored_\@:
    subsd %xmm2, \xs                # f = s - r, in [0, 1)
    ucomisd .Lrt_array_half(%rip), \xs
    jb .Lrt_array_rounded_\@        # f < 0.5 (or NaN): r = floor(s)
    addsd .Lrt_array_one(%rip), %xmm2   # f >= 0.5: r = floor(s) + 1
.Lrt_array_rounded_\@:
.endm

    .text

# ---------------------------------------------------------------------
# bsk_aref1 -- address of list element L(i).
#   Inputs  : %rdi = array descriptor (RTA_*), %xmm0 = subscript i
#   Outputs : %rax = address of the element
#   Errors  : SUBSCRIPT ERROR if the rounded subscript is outside 0..B1
#   Clobbers: %rax, %rcx, %rdx, %xmm0, %xmm2, %xmm3
#   Callee-saved used: none
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_aref1
    .type bsk_aref1, @function
    .p2align 4
bsk_aref1:
    RT_SUBSCRIPT %xmm0, RTA_B1, %rdx
    movl RTA_ROWLEN(%rdi), %ecx     # 1 for lists
    imulq %rcx, %rdx                # i * rowlen
    movq RTA_DATA(%rdi), %rax
    leaq (%rax,%rdx,8), %rax        # data + 8 * index
    ret
    .size bsk_aref1, . - bsk_aref1

# ---------------------------------------------------------------------
# bsk_aref2 -- address of table element T(i, j).
#   Inputs  : %rdi = array descriptor, %xmm0 = subscript i,
#             %xmm1 = subscript j
#   Outputs : %rax = address of the element
#   Errors  : SUBSCRIPT ERROR if i is outside 0..B1 or j outside 0..B2
#   Clobbers: %rax, %rcx, %r8, %r9, %xmm0, %xmm1, %xmm2, %xmm3
#   Callee-saved used: none
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_aref2
    .type bsk_aref2, @function
    .p2align 4
bsk_aref2:
    RT_SUBSCRIPT %xmm0, RTA_B1, %r8 # row
    RT_SUBSCRIPT %xmm1, RTA_B2, %r9 # column
    movl RTA_ROWLEN(%rdi), %ecx
    imulq %rcx, %r8                 # i * rowlen
    addq %r9, %r8                   # + j
    movq RTA_DATA(%rdi), %rax
    leaq (%rax,%r8,8), %rax
    ret
    .size bsk_aref2, . - bsk_aref2

# ---------------------------------------------------------------------
# bsk_saref1 -- address of string list element L$(i) (DESIGN.md 6.7).
#   Purpose : the subscript rule of bsk_aref1 (LANGUAGE.md 7.11) against
#             the current RTA_B1; element i is the SD record at
#             RTA_DATA + SD_SIZE * i.
#   Inputs  : %rdi = string-list descriptor (RTA_*), %xmm0 = subscript
#   Outputs : %rax = address of the SD record
#   Errors  : SUBSCRIPT ERROR if the rounded subscript is outside 0..B1
#   Clobbers: %rax, %rcx, %rdx, %xmm0, %xmm2, %xmm3
#   Callee-saved used: none
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_saref1
    .type bsk_saref1, @function
    .p2align 4
bsk_saref1:
    RT_SUBSCRIPT %xmm0, RTA_B1, %rdx
    imulq $SD_SIZE, %rdx, %rdx      # SD_SIZE bytes per element
    movq RTA_DATA(%rdi), %rax
    addq %rdx, %rax
    ret
    .size bsk_saref1, . - bsk_saref1

# ---------------------------------------------------------------------
# bsk_saref2 -- address of string table element T$(i, j) (DESIGN.md
#   6.8, LANGUAGE.md 4.4, 7.11).
#   Purpose : the subscript rule of bsk_aref2 against the current
#             RTA_B1 / RTA_B2; element (i, j) is the SD record at
#             RTA_DATA + SD_SIZE * (i * RTA_ROWLEN + j).
#   Inputs  : %rdi = string-table descriptor (RTA_*), %xmm0 = subscript
#             i, %xmm1 = subscript j
#   Outputs : %rax = address of the SD record
#   Errors  : SUBSCRIPT ERROR if i is outside 0..B1 or j outside 0..B2
#   Clobbers: %rax, %rcx, %r8, %r9, %xmm0, %xmm1, %xmm2, %xmm3
#   Callee-saved used: none
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_saref2
    .type bsk_saref2, @function
    .p2align 4
bsk_saref2:
    RT_SUBSCRIPT %xmm0, RTA_B1, %r8 # row
    RT_SUBSCRIPT %xmm1, RTA_B2, %r9 # column
    movl RTA_ROWLEN(%rdi), %ecx
    imulq %rcx, %r8                 # i * rowlen
    addq %r9, %r8                   # + j
    imulq $SD_SIZE, %r8, %r8        # SD_SIZE bytes per element
    movq RTA_DATA(%rdi), %rax
    addq %r8, %rax
    ret
    .size bsk_saref2, . - bsk_saref2

# ---------------------------------------------------------------------
# bsk_rt_round_half -- r = floor(x + 1/2), computed exactly (the
#   subscript rounding of LANGUAGE.md 7.11, also used by CHANGE for
#   the length L(0) and the character codes, LANGUAGE.md 7.19).
#   Inputs  : %xmm0 = x
#   Outputs : %xmm0 = r as a double (an integer; +-inf / NaN / huge
#             values come back unchanged, so the caller's range test
#             on the double rejects them before any conversion)
#   Clobbers: %rax, %rcx, %xmm2
#   Callee-saved used: none
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_rt_round_half
    .hidden bsk_rt_round_half
    .type bsk_rt_round_half, @function
    .p2align 4
bsk_rt_round_half:
    RT_ROUND_HALF %xmm0             # %xmm2 = floor(x + 1/2)
    movapd %xmm2, %xmm0
    ret
    .size bsk_rt_round_half, . - bsk_rt_round_half

# Shared error exit for the four functions (reached by a jump from a leaf,
# so %rsp is as at a call entry; bsk_err realigns anyway).
.Lrt_array_bad:
    movl $ERR_SUBSCRIPT, %edi
    jmp bsk_err

# Constants for the rounding step (8-byte loads, 8-byte aligned).
    .section .rodata
    .p2align 3
.Lrt_array_half:
    .double 0.5
.Lrt_array_one:
    .double 1.0

    .section .note.GNU-stack,"",@progbits
