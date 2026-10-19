# =====================================================================
# src/runtime_x86_64_linux/rt_ed4.s -- CHANGE, ON, SGN, COT and DET
# (LANGUAGE.md 6, 7.17, 7.19; DESIGN.md 6.7).
#
# Defines (global, runtime.inc):
#   bsk_change_s2n bsk_change_n2s bsk_change_n2s_el bsk_on bsk_sgn
#   bsk_cot bsk_det
# Uses: bsk_saref1 (rt_array.s). Uses (private): bsk_rt_round_half
# (rt_array.s), bsk_rt_str_reserve
# (rt_str.s), bsk_rt_kinv_det (the DET cell, rt_kinit.s).
#
# Every value that must be an integer (the CHANGE length and codes) is
# converted with the subscript rounding floor(x + 1/2), computed exactly,
# and range-checked as a double before any conversion to an integer, so
# huge, negative or (impossible here) non-finite values can never wrap.
# =====================================================================
.include "baysick.inc"

# Bits of +infinity shifted left by one (sign bit dropped): a double is
# not finite exactly when (bits << 1) >= this value.
.equ RT_DINF_SHL1, 0xFFE0000000000000

# RT_ED4_FINITE_OR_OVERFLOW: if %xmm0 is +-inf or NaN, jump to bsk_err
# with ERR_OVERFLOW (no return); otherwise fall through.
# Clobbers %rax, %rcx (and %edi only on the error path).
.macro RT_ED4_FINITE_OR_OVERFLOW
    movq %xmm0, %rax
    addq %rax, %rax                 # drop the sign bit
    movabsq $RT_DINF_SHL1, %rcx
    cmpq %rcx, %rax
    jb .Lrt_ed4_finite_\@           # exponent not all ones: finite
    movl $ERR_OVERFLOW, %edi
    jmp bsk_err                     # noreturn
.Lrt_ed4_finite_\@:
.endm

    .text

# ---------------------------------------------------------------------
# bsk_change_s2n -- CHANGE string TO list (LANGUAGE.md 7.19).
#   Purpose : n = length of the string; n > the list's current bound ->
#             SUBSCRIPT ERROR; else L(0) = n and L(i) = code (0 .. 255)
#             of byte i, i = 1 .. n. Elements after n are not changed.
#   Inputs  : %rdi = numeric-list descriptor (RTA_*, ROWLEN 1),
#             %rsi = source SD
#   Outputs : none
#   Clobbers: %rax, %rcx, %rdx, %rsi, %rdi, %r8, %xmm0
#   Callee-saved used: none
#   Frame   : none (leaf; the error leaves by a jump to bsk_err)
# ---------------------------------------------------------------------
    .globl bsk_change_s2n
    .type bsk_change_s2n, @function
    .p2align 4
bsk_change_s2n:
    movl SD_LEN(%rsi), %ecx         # n
    movq SD_PTR(%rsi), %rsi         # the bytes
    movl RTA_B1(%rdi), %eax         # current bound
    cmpq %rax, %rcx
    ja .Lrt_ed4_subscript           # the string does not fit
    movq RTA_DATA(%rdi), %rdi       # &L(0)
    cvtsi2sdq %rcx, %xmm0
    movsd %xmm0, (%rdi)             # L(0) = n
    xorl %edx, %edx                 # i - 1
1:
    cmpq %rcx, %rdx
    jae 2f
    movzbl (%rsi,%rdx), %r8d        # unsigned byte code
    cvtsi2sdl %r8d, %xmm0
    movsd %xmm0, 8(%rdi,%rdx,8)     # L(i)
    addq $1, %rdx
    jmp 1b
2:
    ret
    .size bsk_change_s2n, . - bsk_change_s2n

# ---------------------------------------------------------------------
# bsk_change_n2s -- CHANGE list TO string (LANGUAGE.md 7.19).
#   Purpose : n = floor(L(0) + 1/2); n < 0 or n > the list's current
#             bound -> SUBSCRIPT ERROR; n > LIM_STRING_LEN -> STRING TOO
#             LONG; every code c = floor(L(i) + 1/2), i = 1 .. n, must
#             be in 0 .. LIM_CHAR_CODE, else ILLEGAL CHARACTER; only
#             then is the destination assigned the n bytes (grown with
#             realloc as by bsk_str_set; failure -> OUT OF ROOM).
#   Inputs  : %rdi = destination SD, %rsi = numeric-list descriptor
#   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: see .Lrt_ed4_n2s
#   Frame   : none (jump to .Lrt_ed4_n2s)
# ---------------------------------------------------------------------
    .globl bsk_change_n2s
    .type bsk_change_n2s, @function
    .p2align 4
bsk_change_n2s:
    xorl %eax, %eax                 # %rdi is the destination itself
    jmp .Lrt_ed4_n2s
    .size bsk_change_n2s, . - bsk_change_n2s

# ---------------------------------------------------------------------
# bsk_change_n2s_el -- CHANGE list TO L$(i) (the element form of
#   `chgn2s`, IR.md 3.2): the conversion and all its checks as
#   bsk_change_n2s first; then the subscript is checked at the store
#   (bsk_saref1, LANGUAGE.md 7.1, 7.19); then the element is assigned.
#   Inputs  : %rdi = string-list descriptor (RTA_*), %xmm0 = subscript
#             i, %rsi = numeric-list descriptor
#   Outputs : none
#   Errors  : SUBSCRIPT ERROR (length), STRING TOO LONG, ILLEGAL
#             CHARACTER; then SUBSCRIPT ERROR (i); OUT OF ROOM
#   Clobbers: all caller-saved registers
#   Callee-saved used: see .Lrt_ed4_n2s
#   Frame   : none (jump to .Lrt_ed4_n2s)
# ---------------------------------------------------------------------
    .globl bsk_change_n2s_el
    .type bsk_change_n2s_el, @function
    .p2align 4
bsk_change_n2s_el:
    movl $1, %eax                   # %rdi is a string list, %xmm0 = i
    jmp .Lrt_ed4_n2s
    .size bsk_change_n2s_el, . - bsk_change_n2s_el

# ---------------------------------------------------------------------
# .Lrt_ed4_n2s -- the body of bsk_change_n2s / bsk_change_n2s_el.
#   Inputs  : %rdi = destination SD (%eax = 0) or string-list descriptor
#             (%eax = 1, %xmm0 = subscript), %rsi = numeric-list
#             descriptor
#   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = destination (the string list until the
#             store), %r12 = &L(1), %r13 = n, %r14 = index, %r15 =
#             destination bytes, %rbp = frame pointer
#   Frame   : 72 bytes (%rbp, %rbx, %r12-%r15 + 24 bytes: the subscript
#             at 0(%rsp), the %eax flag at 8(%rsp)); %rsp = 0 (mod 16)
#             at calls
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_ed4_n2s:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    subq $24, %rsp                  # %rsp = 0 (mod 16)
    movsd %xmm0, (%rsp)             # subscript (element form only)
    movl %eax, 8(%rsp)              # 1: element form
    movq %rdi, %rbx
    movq RTA_DATA(%rsi), %r12
    movl RTA_B1(%rsi), %r13d        # current bound (for the test)
    movsd (%r12), %xmm0
    addq $8, %r12                   # &L(1)
    call bsk_rt_round_half          # %xmm0 = floor(L(0) + 1/2)
    pxor %xmm1, %xmm1
    ucomisd %xmm1, %xmm0
    jb .Lrt_ed4_subscript           # n < 0 (or NaN)
    cvtsi2sdq %r13, %xmm1           # bound, exact
    ucomisd %xmm1, %xmm0
    ja .Lrt_ed4_subscript           # n > bound
    movl $LIM_STRING_LEN, %eax
    cvtsi2sdl %eax, %xmm1
    ucomisd %xmm1, %xmm0
    ja .Lrt_ed4_toolong             # n > 65536
    cvttsd2si %xmm0, %r13           # 0 <= n <= 65536: exact

    # Pass 1: every code must be a byte before anything is assigned.
    xorl %r14d, %r14d
.Lrt_ed4_n2s_check:
    cmpq %r13, %r14
    jae .Lrt_ed4_n2s_store
    movsd (%r12,%r14,8), %xmm0
    call bsk_rt_round_half          # c = floor(L(i) + 1/2)
    pxor %xmm1, %xmm1
    ucomisd %xmm1, %xmm0
    jb .Lrt_ed4_badchar             # c < 0 (or NaN)
    movl $LIM_CHAR_CODE, %eax
    cvtsi2sdl %eax, %xmm1
    ucomisd %xmm1, %xmm0
    ja .Lrt_ed4_badchar             # c > 255
    addq $1, %r14
    jmp .Lrt_ed4_n2s_check

    # A string list element: its subscript is checked now, at the store,
    # after the conversion's own checks (LANGUAGE.md 7.19).
.Lrt_ed4_n2s_store:
    cmpl $0, 8(%rsp)
    je 3f
    movq %rbx, %rdi
    movsd (%rsp), %xmm0
    call bsk_saref1                 # %rax = &L$(i); SUBSCRIPT ERROR here
    movq %rax, %rbx
3:
    # Pass 2: own n bytes, then convert and store the codes.
    movq %rbx, %rdi
    movq %r13, %rsi
    call bsk_rt_str_reserve         # OUT OF ROOM on failure
    movq %rax, %r15
    xorl %r14d, %r14d
1:
    cmpq %r13, %r14
    jae 2f
    movsd (%r12,%r14,8), %xmm0
    call bsk_rt_round_half
    cvttsd2si %xmm0, %eax           # 0 .. 255, checked in pass 1
    movb %al, (%r15,%r14)
    addq $1, %r14
    jmp 1b
2:
    movl %r13d, SD_LEN(%rbx)        # LEN := n
    addq $24, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret

# Error exits shared by this file (reached by jumps; bsk_err realigns
# the stack itself and never returns).
.Lrt_ed4_subscript:
    movl $ERR_SUBSCRIPT, %edi
    jmp bsk_err
.Lrt_ed4_toolong:
    movl $ERR_STRING_TOO_LONG, %edi
    jmp bsk_err
.Lrt_ed4_badchar:
    movl $ERR_ILLEGAL_CHARACTER, %edi
    jmp bsk_err
.Lrt_ed4_onrange:
    movl $ERR_ON_RANGE, %edi
    jmp bsk_err
.Lrt_ed4_divzero:
    movl $ERR_DIVISION_BY_ZERO, %edi
    jmp bsk_err

# ---------------------------------------------------------------------
# bsk_on -- the ON selector (LANGUAGE.md 7.17).
#   Purpose : k = trunc(x); 1 <= k <= n -> k, else ON EVALUATED OUT OF
#             RANGE. Compared as doubles (trunc(x) >= 1 exactly when
#             x >= 1, and trunc(x) <= n exactly when x < n + 1), so a
#             huge x cannot wrap; k is converted only once in range.
#   Inputs  : %xmm0 = x (finite), %edi = n (number of line numbers, >= 1)
#   Outputs : %xmm0 = k (an integer 1 .. n, as a double)
#   Clobbers: %rax, %xmm1
#   Callee-saved used: none
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_on
    .type bsk_on, @function
    .p2align 4
bsk_on:
    movl $1, %eax
    cvtsi2sdl %eax, %xmm1           # 1.0
    ucomisd %xmm1, %xmm0
    jb .Lrt_ed4_onrange             # x < 1: k <= 0
    movl %edi, %eax
    addq $1, %rax                   # n + 1 (no u32 overflow in 64 bits)
    cvtsi2sdq %rax, %xmm1
    ucomisd %xmm1, %xmm0
    jae .Lrt_ed4_onrange            # x >= n + 1: k > n
    cvttsd2si %xmm0, %rax           # k = trunc(x), 1 .. n
    cvtsi2sdq %rax, %xmm0
    ret
    .size bsk_on, . - bsk_on

# ---------------------------------------------------------------------
# bsk_sgn -- SGN(x): 1 if x > 0, 0 if x = 0 (either sign), -1 if x < 0.
#   Inputs  : %xmm0 = x (finite)
#   Outputs : %xmm0 = sign
#   Clobbers: %rax, %rcx, %xmm1
#   Callee-saved used: none
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_sgn
    .type bsk_sgn, @function
    .p2align 4
bsk_sgn:
    pxor %xmm1, %xmm1
    xorl %eax, %eax                 # 0 for +0 and -0
    movl $1, %ecx
    ucomisd %xmm1, %xmm0
    cmova %ecx, %eax                # x > 0: 1
    movl $-1, %ecx
    cmovb %ecx, %eax                # x < 0: -1
    cvtsi2sdl %eax, %xmm0
    ret
    .size bsk_sgn, . - bsk_sgn

# ---------------------------------------------------------------------
# bsk_cot -- COT(x) = 1 / tan(x) (LANGUAGE.md 6).
#   Purpose : t = libm tan(x); t = +-0 -> DIVISION BY ZERO; then one
#             IEEE division 1 / t; a non-finite result -> OVERFLOW.
#   Inputs  : %xmm0 = x (finite)
#   Outputs : %xmm0 = cot(x)
#   Clobbers: all caller-saved registers (libm)
#   Callee-saved used: %rbp = frame pointer
#   Frame   : 8 bytes (saved %rbp; aligns %rsp for the libm call)
# ---------------------------------------------------------------------
    .globl bsk_cot
    .type bsk_cot, @function
    .p2align 4
bsk_cot:
    pushq %rbp
    movq %rsp, %rbp
    call tan@PLT                    # t
    popq %rbp
    pxor %xmm1, %xmm1
    ucomisd %xmm1, %xmm0
    jp 1f                           # unordered: not zero
    je .Lrt_ed4_divzero             # t = +0 or -0
1:
    movapd %xmm0, %xmm1
    movl $1, %eax
    cvtsi2sdl %eax, %xmm0
    divsd %xmm1, %xmm0              # 1 / t, one rounding
    RT_ED4_FINITE_OR_OVERFLOW
    ret
    .size bsk_cot, . - bsk_cot

# ---------------------------------------------------------------------
# bsk_det -- DET: the determinant of the matrix most recently inverted
#   (LANGUAGE.md 6, 7.14.6): the DET cell the inv kernels write
#   (bsk_rt_kinv_det, initially 0); a non-finite value -> OVERFLOW.
#   Inputs  : none
#   Outputs : %xmm0 = DET
#   Clobbers: %rax, %rcx, %xmm0
#   Callee-saved used: none
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_det
    .type bsk_det, @function
    .p2align 4
bsk_det:
    movsd bsk_rt_kinv_det(%rip), %xmm0
    RT_ED4_FINITE_OR_OVERFLOW
    ret
    .size bsk_det, . - bsk_det

    .section .note.GNU-stack,"",@progbits
