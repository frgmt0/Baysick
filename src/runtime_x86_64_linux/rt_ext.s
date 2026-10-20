# =====================================================================
# src/runtime_x86_64_linux/rt_ext.s -- the Baysick extensions: LINPUT
# and END / STOP with an exit status (LANGUAGE.md 15.2, 15.4, 15.5;
# DESIGN.md 6.10).
#
# Defines (global, runtime.inc):
#   bsk_linput bsk_linput_el bsk_exit
# Uses (private): bsk_rt_in_linput (rt_input.s: the line request on the
# selected reader), bsk_rt_str_assign (rt_str.s), bsk_rt_terminate
# (rt_main.s: the termination shared with bsk_end); bsk_saref1
# (rt_array.s), bsk_err (rt_error.s).
#
# PRINT #-1 (standard error) lives with the rest of the output in
# rt_print.s, its file number check in rt_files.s (bsk_fsel), the
# rejection of -1 by the input entry points in rt_input.s, and the
# pending standard-error line before messages in rt_print.s
# (bsk_rt_err_newline), rt_error.s and rt_input.s.
# =====================================================================
.include "baysick.inc"

    .text

# ---------------------------------------------------------------------
# bsk_linput -- LINPUT target / LINPUT #k, target (LANGUAGE.md 15.2):
#   the next unread line of the selected reader, verbatim, into dst.
#   Purpose : an input entry point: bsk_rt_in_linput reads the pending
#             selection and resets it (none: standard input with the
#             INPUT dialogue's line request; file 0 / k: the INPUT #
#             line request; -1: INVALID FILE NUMBER) and reads the line;
#             then the whole line is stored with bsk_str_set semantics.
#   Inputs  : %rdi = destination SD
#   Outputs : none
#   Errors  : END OF INPUT (exit 0), END OF FILE, INPUT LINE TOO LONG,
#             INVALID FILE NUMBER, ILLEGAL FILE COMMAND, CAN'T OPEN FILE,
#             OUT OF ROOM
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = destination, %rbp = frame pointer
#   Frame   : 24 bytes (%rbp, %rbx + 8 bytes alignment pad)
# ---------------------------------------------------------------------
    .globl bsk_linput
    .type bsk_linput, @function
    .p2align 4
bsk_linput:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    subq $8, %rsp                   # %rsp = 0 (mod 16)
    movq %rdi, %rbx                 # the destination
    call bsk_rt_in_linput           # %rax = line bytes, %rdx = length
    movq %rbx, %rdi
    movq %rax, %rsi
    call bsk_rt_str_assign          # dst := the line (OUT OF ROOM)
    addq $8, %rsp
    popq %rbx
    popq %rbp
    ret
    .size bsk_linput, . - bsk_linput

# ---------------------------------------------------------------------
# bsk_linput_el -- LINPUT into a string list element L$(i) (the element
#   form, IR.md 3.5; LANGUAGE.md 15.2 order of evaluation): the line is
#   read exactly as by bsk_linput (every error of that first); only then
#   is element i addressed (bsk_saref1: SUBSCRIPT ERROR at the store);
#   then the element := the line.
#   Inputs  : %rdi = string-list descriptor (RTA_*), %xmm0 = subscript i
#   Outputs : none
#   Errors  : those of bsk_linput, then SUBSCRIPT ERROR, OUT OF ROOM
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = descriptor, %r12 = line bytes, %r13 = line
#             length, %rbp = frame pointer
#   Frame   : 56 bytes (%rbp, %rbx, %r12, %r13 + 24 bytes: the subscript
#             at 0(%rsp)); %rsp = 0 (mod 16) at calls
# ---------------------------------------------------------------------
    .globl bsk_linput_el
    .type bsk_linput_el, @function
    .p2align 4
bsk_linput_el:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    subq $24, %rsp                  # %rsp = 0 (mod 16)
    movq %rdi, %rbx                 # the list
    movsd %xmm0, (%rsp)             # the subscript, kept across the read
    call bsk_rt_in_linput           # %rax = line bytes, %rdx = length
    movq %rax, %r12
    movq %rdx, %r13
    movq %rbx, %rdi
    movsd (%rsp), %xmm0
    call bsk_saref1                 # %rax = &L$(i); SUBSCRIPT ERROR here
    movq %rax, %rdi
    movq %r12, %rsi
    movq %r13, %rdx
    call bsk_rt_str_assign          # element := the line (OUT OF ROOM)
    addq $24, %rsp
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret
    .size bsk_linput_el, . - bsk_linput_el

.equ RT_EXT_EXIT_MIN, 0                 # lowest legal exit status k (LANGUAGE.md 15.4)

# ---------------------------------------------------------------------
# bsk_exit -- END e / STOP e (LANGUAGE.md 15.4, DESIGN.md 6.10).
#   Purpose : k = trunc(x) must satisfy 0 <= k <= LIM_EXIT_STATUS, else
#             EXIT STATUS OUT OF RANGE. Compared as doubles before any
#             conversion, so huge or NaN values can never wrap:
#             0 <= trunc(x) <= LIM_EXIT_STATUS is exactly
#             -1 < x < LIM_EXIT_STATUS + 1. Then the termination of END
#             (bsk_rt_terminate: files, stdout, standard error) with
#             status k, or 1 if output was lost.
#   Inputs  : %xmm0 = x
#   Outputs : never returns
#   Errors  : EXIT STATUS OUT OF RANGE, CAN'T WRITE FILE
#   Clobbers: everything
#   Callee-saved used: %rbp = frame pointer (not restored: noreturn)
#   Frame   : 8 bytes (saved %rbp), then %rsp is rounded down to a
#             multiple of 16 so the stack is aligned however we came here
# ---------------------------------------------------------------------
    .globl bsk_exit
    .type bsk_exit, @function
    .p2align 4
bsk_exit:
    pushq %rbp
    movq %rsp, %rbp
    andq $-16, %rsp                 # noreturn: force 16-byte alignment
    movl $(RT_EXT_EXIT_MIN - 1), %eax  # exclusive lower bound of x: k >= RT_EXT_EXIT_MIN
    cvtsi2sdl %eax, %xmm1           # -1.0
    ucomisd %xmm1, %xmm0
    jbe .Lrt_ext_exit_range         # x <= -1, or NaN: k < 0
    movl $(LIM_EXIT_STATUS + 1), %eax
    cvtsi2sdl %eax, %xmm1           # 256.0
    ucomisd %xmm0, %xmm1
    jbe .Lrt_ext_exit_range         # x >= 256: k > LIM_EXIT_STATUS
    cvttsd2si %xmm0, %edi           # -1 < x < 256: k = trunc(x)
    call bsk_rt_terminate           # noreturn
    ud2
.Lrt_ext_exit_range:
    movl $ERR_EXIT_RANGE, %edi
    call bsk_err                    # "EXIT STATUS OUT OF RANGE IN n", exit 1
    ud2
    .size bsk_exit, . - bsk_exit

    .section .note.GNU-stack,"",@progbits
