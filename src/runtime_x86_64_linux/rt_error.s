# =====================================================================
# src/runtime_x86_64_linux/rt_error.s -- run-time error reporting.
#
# Defines: bsk_err (docs/DESIGN.md sections 6.2, 6.4; LANGUAGE.md 10)
#
# The message text comes only from include/errors.inc via
# BSK_EMIT_ERRMSG_TABLE, so it can never diverge from the compiler's.
# =====================================================================
.include "baysick.inc"

# Size of the stack buffer used to build "<MESSAGE> IN <line>\n".
# The longest run-time message is 25 bytes, " IN " is 4, a u32 has at most 10
# digits, plus LF: 40 bytes. 64 leaves room (and keeps %rsp aligned).
.equ RT_ERR_MSGBUF, 64
.equ RT_CH_LF,      10              # '\n'
.equ RT_CH_SPACE,   32              # ' '
.equ RT_CH_I,       73              # 'I'
.equ RT_CH_N,       78              # 'N'

    .text

# ---------------------------------------------------------------------
# bsk_err -- report a run-time error and terminate.
#   Purpose : finish the files in write mode not yet finished
#             (bsk_rt_files_finish, DESIGN.md 6.8), pending-line
#             newline + flush of stdout, then write
#             "<MESSAGE> IN <bsk_curline>" + LF to fd 2 and exit.
#             Exit status EXIT_RUN_OK (0) for ERR_OUT_OF_DATA and
#             ERR_END_OF_INPUT, else EXIT_RUN_ERROR (1); also 1 for
#             those two if writing stdout or a file failed (LANGUAGE.md
#             section 10).
#   Inputs  : %edi = ERR_* code; must be a run-time code
#             (ERR_FIRST_RUNTIME..ERR_TABLE_SIZE-1). Any other code (a
#             caller bug) prints nothing and exits with status 1
#             (DESIGN.md 6.2).
#   Outputs : never returns
#   Clobbers: everything
#   Callee-saved used (not restored: the function never returns):
#             %rbx = error code, %r12 = write cursor in the message
#             buffer, %r13 = start of the message buffer,
#             %r14 = 1 if output was lost (stdout or a file), else 0,
#             %rbp = frame pointer
#   Frame   : 8 bytes (saved %rbp), then %rsp is rounded down to a
#             multiple of 16 (callers may jump here from any depth) and
#             RT_ERR_MSGBUF bytes of message buffer at (%rsp)
# ---------------------------------------------------------------------
    .globl bsk_err
    .type bsk_err, @function
    .p2align 4
bsk_err:
    pushq %rbp
    movq %rsp, %rbp
    andq $-16, %rsp                 # force 16-byte alignment
    subq $RT_ERR_MSGBUF, %rsp       # message buffer at (%rsp)
    movl %edi, %ebx                 # keep the code across calls

    # The files in write mode first (once; a failure only forces exit
    # status 1), then stdout: the error text must appear after all
    # output.
    call bsk_rt_files_finish
    movl %eax, %r14d                # 1 if a file's output was lost
    call bsk_rt_finish_output       # %eax = 1 if stdout broke
    orl %eax, %r14d                 # output lost anywhere: status 1

    # Look up the message; a code that is not a run-time error prints
    # nothing.
    cmpl $ERR_FIRST_RUNTIME, %ebx
    jb .Lrt_err_exit
    cmpl $ERR_TABLE_SIZE, %ebx
    jae .Lrt_err_exit
    leaq .Lrt_errmsg(%rip), %rax
    movq (%rax,%rbx,8), %rsi        # message pointer or 0
    testq %rsi, %rsi
    jz .Lrt_err_exit

    # Copy the NUL-terminated message into the buffer.
    movq %rsp, %r13                 # buffer start
    movq %rsp, %r12                 # write cursor
.Lrt_err_copy:
    movzbl (%rsi), %eax
    addq $1, %rsi
    testl %eax, %eax
    jz .Lrt_err_in
    movb %al, (%r12)
    addq $1, %r12
    jmp .Lrt_err_copy

    # Append " IN " and the decimal line number.
.Lrt_err_in:
    movb $RT_CH_SPACE, (%r12)
    movb $RT_CH_I, 1(%r12)
    movb $RT_CH_N, 2(%r12)
    movb $RT_CH_SPACE, 3(%r12)
    addq $4, %r12
    movl bsk_curline(%rip), %edi    # zero-extended u32 line
    movq %r12, %rsi
    call bsk_rt_utoa                # %rax = digit count
    addq %rax, %r12
    movb $RT_CH_LF, (%r12)
    addq $1, %r12

    # write(2, buf, len); a failure here has no better channel.
    movl $2, %edi
    movq %r13, %rsi
    movq %r12, %rdx
    subq %r13, %rdx
    call bsk_rt_write_all

.Lrt_err_exit:
    # OUT OF DATA is the normal end of a 1964 program and END OF INPUT
    # the normal end of a filter: exit 0, unless stdout broke or a file
    # write failed (output was lost): then exit 1 like any error.
    movl $EXIT_RUN_ERROR, %edi
    movl $EXIT_RUN_OK, %eax
    cmpl $ERR_OUT_OF_DATA, %ebx
    cmovel %eax, %edi
    cmpl $ERR_END_OF_INPUT, %ebx
    cmovel %eax, %edi
    movl $EXIT_RUN_ERROR, %eax
    testl %r14d, %r14d
    cmovnel %eax, %edi              # stdout broken: status 1
    call exit@PLT                   # does not return
    ud2
    .size bsk_err, . - bsk_err

# ---------------------------------------------------------------------
# Message table (pointers indexed by error code) and texts. The table
# holds absolute addresses, hence .data.rel.ro (DESIGN.md 6.4.4).
# ---------------------------------------------------------------------
    .section .data.rel.ro,"aw",@progbits
    BSK_EMIT_ERRMSG_TABLE .Lrt_errmsg

    .section .note.GNU-stack,"",@progbits
