# =====================================================================
# src/runtime_x86_64_linux/rt_str.s -- string values: assignment and
# comparison (LANGUAGE.md 4.4, 7.1, 7.7; DESIGN.md 6.7).
#
# Defines (global, runtime.inc):
#   bsk_str_set bsk_str_cmp
# Defines (private to the runtime, .globl + .hidden):
#   bsk_rt_str_reserve   make an SD own at least n bytes (OUT OF ROOM)
#   bsk_rt_str_assign    SD := copy of n bytes (INPUT, MAT INPUT,
#                        string DATA, CHANGE)
#
# A string value is an SD record (runtime.inc): LEN bytes at PTR.
# SD_CAP > 0: PTR is a malloc'd buffer of CAP bytes owned by the
# record (string variables and string-list elements), grown with
# realloc, never shrunk or freed. SD_CAP = 0: PTR is not owned
# (string constants, string DATA, a never-assigned variable) and is
# never written or passed to realloc. Two records never share a
# buffer, so a copy never overlaps its source.
# =====================================================================
.include "baysick.inc"

.equ RT_STR_GRAIN, 16               # capacities are multiples of 16 (>= 16)
.equ RT_CH_SPACE, 32                # ' ' (trailing blanks are ignored by cmp)

    .text

# ---------------------------------------------------------------------
# bsk_rt_str_reserve -- make the record own at least n bytes.
#   Purpose : n <= SD_CAP: nothing; otherwise cap' = n rounded up to a
#             multiple of RT_STR_GRAIN (at least RT_STR_GRAIN),
#             PTR := realloc(CAP > 0 ? PTR : NULL, cap'), CAP := cap'.
#             realloc failure -> OUT OF ROOM (the record is unchanged).
#             LEN and the bytes already owned are not changed.
#   Inputs  : %rdi = SD record, %rsi = n (0 .. LIM_STRING_LEN)
#   Outputs : %rax = SD_PTR afterwards (may be 0 only when n = 0)
#   Clobbers: all caller-saved registers (realloc)
#   Callee-saved used: %rbx = record, %r12 = cap', %rbp = frame pointer
#   Frame   : 24 bytes (%rbp, %rbx, %r12); %rsp = 0 (mod 16) at calls
# ---------------------------------------------------------------------
    .globl bsk_rt_str_reserve
    .hidden bsk_rt_str_reserve
    .type bsk_rt_str_reserve, @function
    .p2align 4
bsk_rt_str_reserve:
    movl SD_CAP(%rdi), %eax         # owned capacity (0 = not owned)
    cmpq %rax, %rsi
    ja 1f                           # n > CAP: grow
    movq SD_PTR(%rdi), %rax         # enough room already
    ret
1:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12                      # 3 pushes: %rsp = 0 (mod 16)
    movq %rdi, %rbx
    leaq RT_STR_GRAIN - 1(%rsi), %r12
    andq $-RT_STR_GRAIN, %r12       # n rounded up (n >= 1 here, so >= 16)
    xorl %edi, %edi                 # not owned: realloc(NULL, ..) = malloc
    cmpl $0, SD_CAP(%rbx)
    je 2f
    movq SD_PTR(%rbx), %rdi         # owned: grow the existing buffer
2:
    movq %r12, %rsi
    call realloc@PLT
    testq %rax, %rax
    jz .Lrt_str_room                # no memory: OUT OF ROOM
    movq %rax, SD_PTR(%rbx)
    movl %r12d, SD_CAP(%rbx)        # cap' <= LIM_STRING_LEN fits a u32
    popq %r12
    popq %rbx
    popq %rbp
    ret
.Lrt_str_room:
    movl $ERR_OUT_OF_ROOM, %edi
    jmp bsk_err                     # noreturn; realigns the stack
    .size bsk_rt_str_reserve, . - bsk_rt_str_reserve

# ---------------------------------------------------------------------
# bsk_rt_str_assign -- record := copy of the n bytes at src.
#   Purpose : the copy of DESIGN.md 6.7 (bsk_str_set) for a source that
#             is a byte range rather than a record (an input line, the
#             string DATA block, CHANGE).
#   Inputs  : %rdi = destination SD, %rsi = source bytes (not inside
#             the destination's buffer), %rdx = n (0 .. LIM_STRING_LEN)
#   Outputs : none
#   Errors  : OUT OF ROOM (bsk_rt_str_reserve)
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = record, %r12 = source, %r13 = n,
#             %rbp = frame pointer
#   Frame   : 40 bytes (%rbp, %rbx, %r12, %r13 + 8 bytes pad)
# ---------------------------------------------------------------------
    .globl bsk_rt_str_assign
    .hidden bsk_rt_str_assign
    .type bsk_rt_str_assign, @function
    .p2align 4
bsk_rt_str_assign:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    subq $8, %rsp                   # %rsp = 0 (mod 16)
    movq %rdi, %rbx
    movq %rsi, %r12
    movq %rdx, %r13
    movq %rdx, %rsi
    call bsk_rt_str_reserve         # %rax = owned buffer (n > 0)
    testq %r13, %r13
    jz 1f                           # empty value: nothing to copy
    movq %rax, %rdi
    movq %r12, %rsi
    movq %r13, %rdx
    call memcpy@PLT                 # never overlapping (see header)
1:
    movl %r13d, SD_LEN(%rbx)        # LEN := n
    addq $8, %rsp
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret
    .size bsk_rt_str_assign, . - bsk_rt_str_assign

# ---------------------------------------------------------------------
# bsk_str_set -- dst := copy of src (LET, DESIGN.md 6.7).
#   Purpose : dst = src (the same record): nothing; otherwise copy the
#             LEN bytes into storage owned by dst (grown with realloc
#             when LEN > CAP), LEN := src LEN. Afterwards the two are
#             independent.
#   Inputs  : %rdi = destination SD, %rsi = source SD
#   Outputs : none
#   Errors  : OUT OF ROOM
#   Clobbers: all caller-saved registers
#   Callee-saved used: none
#   Frame   : none (tail jump to bsk_rt_str_assign)
# ---------------------------------------------------------------------
    .globl bsk_str_set
    .type bsk_str_set, @function
    .p2align 4
bsk_str_set:
    cmpq %rsi, %rdi
    je 1f                           # LET A$ = A$: nothing to do
    movl SD_LEN(%rsi), %edx         # n
    movq SD_PTR(%rsi), %rsi         # source bytes
    jmp bsk_rt_str_assign
1:
    ret
    .size bsk_str_set, . - bsk_str_set

# ---------------------------------------------------------------------
# bsk_str_cmp -- compare two strings (LANGUAGE.md 7.7).
#   Purpose : drop every trailing blank (0x20) from both; compare the
#             first min(la, lb) bytes as unsigned numbers; the first
#             difference decides; otherwise the shorter is smaller.
#   Inputs  : %rdi = SD a, %rsi = SD b
#   Outputs : %eax = -1 (a < b), 0 (a = b), +1 (a > b)
#   Clobbers: %rax, %rcx, %rdx, %rsi, %rdi, %r8, %r9
#   Callee-saved used: none
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_str_cmp
    .type bsk_str_cmp, @function
    .p2align 4
bsk_str_cmp:
    movl SD_LEN(%rdi), %r8d         # la
    movq SD_PTR(%rdi), %rdi         # pa
    movl SD_LEN(%rsi), %r9d         # lb
    movq SD_PTR(%rsi), %rsi         # pb
.Lrt_str_cmp_trima:
    testq %r8, %r8
    jz .Lrt_str_cmp_trimb
    cmpb $RT_CH_SPACE, -1(%rdi,%r8)
    jne .Lrt_str_cmp_trimb
    subq $1, %r8                    # trailing blank of a ignored
    jmp .Lrt_str_cmp_trima
.Lrt_str_cmp_trimb:
    testq %r9, %r9
    jz .Lrt_str_cmp_bytes
    cmpb $RT_CH_SPACE, -1(%rsi,%r9)
    jne .Lrt_str_cmp_bytes
    subq $1, %r9                    # trailing blank of b ignored
    jmp .Lrt_str_cmp_trimb
.Lrt_str_cmp_bytes:
    movq %r8, %rcx
    cmpq %r9, %rcx
    cmova %r9, %rcx                 # m = min(la, lb)
    xorl %edx, %edx                 # i
.Lrt_str_cmp_loop:
    cmpq %rcx, %rdx
    jae .Lrt_str_cmp_len            # common prefix equal
    movzbl (%rdi,%rdx), %eax
    cmpb (%rsi,%rdx), %al           # unsigned byte comparison
    jne .Lrt_str_cmp_diff
    addq $1, %rdx
    jmp .Lrt_str_cmp_loop
.Lrt_str_cmp_diff:
    movl $-1, %eax
    movl $1, %ecx
    cmova %ecx, %eax                # a's byte above b's: +1
    ret
.Lrt_str_cmp_len:
    xorl %eax, %eax
    cmpq %r9, %r8
    je 1f                           # same length: equal
    movl $-1, %eax
    movl $1, %ecx
    cmova %ecx, %eax                # a longer: +1
1:
    ret
    .size bsk_str_cmp, . - bsk_str_cmp

    .section .note.GNU-stack,"",@progbits
