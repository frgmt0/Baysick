# =====================================================================
# src/runtime_x86_64_linux/rt_ed6.s -- the Sixth Edition string
# operations: concatenation &, SEG$ and POS (LANGUAGE.md 4.6, 6.2;
# DESIGN.md 6.9).
#
# Defines (global, runtime.inc):
#   bsk_str_cat bsk_seg bsk_pos
# Uses (private): bsk_rt_round_half (rt_array.s: floor(x + 1/2),
# exactly, the subscript rule of LANGUAGE.md 7.11), bsk_rt_str_assign
# (rt_str.s).
# Strings are SD records (runtime.inc, rt_str.s): SD_CAP > 0 means PTR
# is a malloc'd buffer owned by the record, SD_CAP = 0 that PTR is not
# owned (never written, never passed to realloc).
# The max(r, 1) / min(r, L) clamps treat a NaN position (never produced
# by a BASIC expression: every arithmetic result is checked for
# OVERFLOW) as "no bound": SEG$ first 1, SEG$ last L, POS start 1 --
# the same as src/runtime/rt_ed6.s.
# =====================================================================
.include "baysick.inc"

.equ RT_ED6_GRAIN, 16               # capacities are multiples of 16

    .text

# ---------------------------------------------------------------------
# bsk_str_cat -- dst := dst & src (LANGUAGE.md 4.6, DESIGN.md 6.9).
#   Purpose : Ld = dst LEN and Ls = src LEN are read first (src may be
#             dst); n = Ld + Ls. n > LIM_STRING_LEN -> STRING TOO LONG
#             (dst unchanged). If n > dst CAP the buffer grows to
#             cap' = max(n, 2 * CAP) rounded up to a multiple of 16:
#             CAP > 0: realloc(PTR, cap'); CAP = 0 (PTR not owned):
#             malloc(cap') and the Ld bytes of the old PTR copied into
#             it; NULL -> OUT OF ROOM (dst unchanged). Then the Ls bytes
#             of src (read through src's PTR after the growth, so from
#             the new buffer when src = dst) go to PTR + Ld; LEN := n.
#   Inputs  : %rdi = destination SD, %rsi = source SD
#   Outputs : none
#   Errors  : STRING TOO LONG, OUT OF ROOM
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = dst, %r12 = src, %r13 = Ld, %r14 = Ls,
#             %r15 = cap', %rbp = frame pointer
#   Frame   : 56 bytes (%rbp, %rbx, %r12-%r15 + 8 bytes pad)
# ---------------------------------------------------------------------
    .globl bsk_str_cat
    .type bsk_str_cat, @function
    .p2align 4
bsk_str_cat:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    subq $8, %rsp                   # %rsp = 0 (mod 16) at calls
    movq %rdi, %rbx
    movq %rsi, %r12
    movl SD_LEN(%rbx), %r13d        # Ld (before anything changes)
    movl SD_LEN(%r12), %r14d        # Ls
    leaq (%r13,%r14), %rax          # n = Ld + Ls
    cmpq $LIM_STRING_LEN, %rax
    ja .Lrt_ed6_cat_long            # longer than any string may be
    movl SD_CAP(%rbx), %ecx         # owned capacity (0 = not owned)
    cmpq %rcx, %rax
    jbe .Lrt_ed6_cat_copy           # fits: no growth

    # Growth: cap' = max(n, 2 * CAP) rounded up to RT_ED6_GRAIN.
    leaq (%rcx,%rcx), %rdx          # 2 * CAP
    cmpq %rdx, %rax
    cmovb %rdx, %rax                # max(n, 2 * CAP)
    addq $RT_ED6_GRAIN - 1, %rax
    andq $-RT_ED6_GRAIN, %rax
    movq %rax, %r15                 # cap'
    testl %ecx, %ecx
    jz .Lrt_ed6_cat_fresh           # PTR not owned: a new buffer
    movq SD_PTR(%rbx), %rdi         # owned: grow it in place or move it
    movq %r15, %rsi
    call realloc@PLT
    testq %rax, %rax
    jz .Lrt_ed6_cat_room            # realloc failed: dst unchanged
    jmp .Lrt_ed6_cat_grown
.Lrt_ed6_cat_fresh:
    movq %r15, %rdi
    call malloc@PLT
    testq %rax, %rax
    jz .Lrt_ed6_cat_room
    testq %r13, %r13
    jz .Lrt_ed6_cat_grown           # no old bytes to keep
    movq %rax, %rdi                 # the Ld bytes of the old (not owned)
    movq SD_PTR(%rbx), %rsi         # PTR move into the new buffer
    movq %r13, %rdx
    call memcpy@PLT                 # returns the new buffer in %rax
.Lrt_ed6_cat_grown:
    movq %rax, SD_PTR(%rbx)
    movl %r15d, SD_CAP(%rbx)        # cap' <= 2 * LIM_STRING_LEN: a u32

.Lrt_ed6_cat_copy:
    testq %r14, %r14
    jz .Lrt_ed6_cat_len             # empty source: nothing to copy
    movq SD_PTR(%rbx), %rdi
    addq %r13, %rdi                 # PTR + Ld
    movq SD_PTR(%r12), %rsi         # src bytes (dst's new PTR if src = dst)
    movq %r14, %rdx
    call memcpy@PLT                 # [0, Ld) and [Ld, n) never overlap
.Lrt_ed6_cat_len:
    addl %r14d, %r13d
    movl %r13d, SD_LEN(%rbx)        # LEN := n
    addq $8, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret
.Lrt_ed6_cat_long:
    movl $ERR_STRING_TOO_LONG, %edi
    jmp bsk_err                     # noreturn; realigns the stack
.Lrt_ed6_cat_room:
    movl $ERR_OUT_OF_ROOM, %edi
    jmp bsk_err
    .size bsk_str_cat, . - bsk_str_cat

# ---------------------------------------------------------------------
# bsk_seg -- dst := SEG$(src, m, n) (LANGUAGE.md 6.2).
#   Purpose : m', n' = floor(m + 1/2), floor(n + 1/2), exactly; L = src
#             LEN; first = max(m', 1), last = min(n', L), compared as
#             doubles (no conversion can wrap). first > last: dst := ""
#             (LEN := 0, the buffer kept); otherwise dst := the bytes
#             first .. last of src (1-based) with bsk_str_set semantics.
#             dst is a string temp cell, never src, so the bytes never
#             lie in dst's buffer.
#   Inputs  : %rdi = destination SD, %rsi = source SD, %xmm0 = m,
#             %xmm1 = n
#   Outputs : none
#   Errors  : OUT OF ROOM
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = dst, %r12 = src, %rbp = frame pointer
#   Frame   : 40 bytes (%rbp, %rbx, %r12) + 16 bytes holding n and m'
#             at 0(%rsp) / 8(%rsp)
# ---------------------------------------------------------------------
    .globl bsk_seg
    .type bsk_seg, @function
    .p2align 4
bsk_seg:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    subq $16, %rsp                  # %rsp = 0 (mod 16)
    movq %rdi, %rbx
    movq %rsi, %r12
    movsd %xmm1, (%rsp)             # n, kept across the first rounding
    call bsk_rt_round_half          # %xmm0 = m'
    movsd %xmm0, 8(%rsp)
    movsd (%rsp), %xmm0
    call bsk_rt_round_half          # %xmm0 = n'
    movapd %xmm0, %xmm1             # last candidate n'
    movsd 8(%rsp), %xmm0            # first candidate m'

    # first = max(m', 1)
    movsd .Lrt_ed6_one(%rip), %xmm2
    ucomisd %xmm2, %xmm0
    jae 1f
    movapd %xmm2, %xmm0             # m' < 1: from position 1
1:
    # last = min(n', L)
    movl SD_LEN(%r12), %eax
    cvtsi2sdq %rax, %xmm2           # L as a double (exact)
    ucomisd %xmm1, %xmm2
    jae 2f                          # n' <= L: n' stays
    movapd %xmm2, %xmm1             # n' > L (or NaN): to the end
2:
    ucomisd %xmm1, %xmm0            # both ordered now
    ja .Lrt_ed6_seg_empty           # first > last: the empty string

    # 1 <= first <= last <= L: both convert exactly.
    cvttsd2si %xmm0, %rax           # first
    cvttsd2si %xmm1, %rdx           # last
    subq %rax, %rdx
    addq $1, %rdx                   # count = last - first + 1
    movq SD_PTR(%r12), %rsi
    leaq -1(%rsi,%rax), %rsi        # src bytes at position first
    movq %rbx, %rdi
    addq $16, %rsp
    popq %r12
    popq %rbx
    popq %rbp
    jmp bsk_rt_str_assign           # dst := the bytes (OUT OF ROOM)
.Lrt_ed6_seg_empty:
    movl $0, SD_LEN(%rbx)           # LEN := 0
    addq $16, %rsp
    popq %r12
    popq %rbx
    popq %rbp
    ret
    .size bsk_seg, . - bsk_seg

# ---------------------------------------------------------------------
# bsk_pos -- POS(a, b, start) (LANGUAGE.md 6.2).
#   Purpose : s' = floor(start + 1/2) exactly, p0 = max(s', 1); L = a
#             LEN, K = b LEN. The smallest p with p0 <= p <= L - K + 1
#             whose K bytes of a at positions p .. p + K - 1 equal b's
#             (exactly, unsigned; K = 0 matches at every such p), else
#             0. The bounds are compared as doubles, so a huge or
#             negative start never wraps. No error.
#   Inputs  : %rdi = SD a, %rsi = SD b, %xmm0 = start
#   Outputs : %xmm0 = p as a double, or 0
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = p (current candidate, 1-based),
#             %r12 = a's bytes, %r13 = b's bytes, %r14 = K,
#             %r15 = last candidate L - K + 1, %rbp = frame pointer
#   Frame   : 56 bytes (%rbp, %rbx, %r12-%r15 + 8 bytes pad)
# ---------------------------------------------------------------------
    .globl bsk_pos
    .type bsk_pos, @function
    .p2align 4
bsk_pos:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    subq $8, %rsp                   # %rsp = 0 (mod 16) at calls
    movq SD_PTR(%rdi), %r12
    movq SD_PTR(%rsi), %r13
    movl SD_LEN(%rsi), %r14d        # K
    movl SD_LEN(%rdi), %r15d        # L
    subq %r14, %r15
    addq $1, %r15                   # last candidate L - K + 1 (may be <= 0)
    call bsk_rt_round_half          # %xmm0 = s'
    movsd .Lrt_ed6_one(%rip), %xmm1
    ucomisd %xmm1, %xmm0
    jae 1f
    movapd %xmm1, %xmm0             # p0 = max(s', 1)
1:
    cvtsi2sdq %r15, %xmm1           # L - K + 1 as a double (exact)
    ucomisd %xmm1, %xmm0            # both ordered (p0 >= 1)
    ja .Lrt_ed6_pos_none           # p0 beyond the last candidate
    cvttsd2si %xmm0, %rbx           # 1 <= p0 <= L - K + 1: exact
    testq %r14, %r14
    jz .Lrt_ed6_pos_found           # empty b matches at p0

.Lrt_ed6_pos_loop:
    # Quick test of the first byte, then the whole pattern.
    movzbl -1(%r12,%rbx), %eax
    cmpb (%r13), %al
    jne .Lrt_ed6_pos_next
    leaq -1(%r12,%rbx), %rdi        # a's bytes at position p
    movq %r13, %rsi
    movq %r14, %rdx
    call memcmp@PLT
    testl %eax, %eax
    jz .Lrt_ed6_pos_found
.Lrt_ed6_pos_next:
    addq $1, %rbx
    cmpq %r15, %rbx
    jle .Lrt_ed6_pos_loop           # signed: L - K + 1 >= 1 here
.Lrt_ed6_pos_none:
    xorl %ebx, %ebx                 # not found: 0
.Lrt_ed6_pos_found:
    cvtsi2sdq %rbx, %xmm0           # p (or 0) as a double
    addq $8, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret
    .size bsk_pos, . - bsk_pos

# 1.0 for the max(x, 1) steps (8-byte load, 8-byte aligned).
    .section .rodata
    .p2align 3
.Lrt_ed6_one:
    .double 1.0

    .section .note.GNU-stack,"",@progbits
