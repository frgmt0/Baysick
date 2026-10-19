# =====================================================================
# src/runtime_x86_64_linux/rt_main.s -- process entry, program
# termination and the current-line variable shared with compiled code.
#
# Defines: main, bsk_end, bsk_curline   (docs/DESIGN.md sections 6, 6.4)
#
# main first selects the matrix kernels (bsk_kern_init, rt_kinit.s).
# All other runtime state is initialised statically in the file that
# owns it (print counters and buffer: rt_print.s, RND state: rt_rnd.s,
# DATA cursor: rt_data.s, GOSUB stack: rt_gosub.s), so main has nothing
# to set up before it transfers control to the program.
# =====================================================================
.include "baysick.inc"

    .text

# ---------------------------------------------------------------------
# main -- process entry point of every compiled BASIC program (called
#   by glibc's start code).
#   Purpose : select the matrix kernel variant (bsk_kern_init,
#             DESIGN.md 6.6.2), then run the compiled main function
#             bsk_program; if that ever returns (it should end with
#             bsk_end), terminate exactly like END.
#   Inputs  : %edi = argc, %rsi = argv (ignored; programs read no input)
#   Outputs : never returns
#   Clobbers: everything (control never comes back)
#   Callee-saved used: %rbp = frame pointer
#   Frame   : 8 bytes (saved %rbp; %rsp is then 16-byte aligned)
# ---------------------------------------------------------------------
    .globl main
    .type main, @function
    .p2align 4
main:
    pushq %rbp                      # entered with %rsp = 8 (mod 16)
    movq %rsp, %rbp                 # now 0 (mod 16): calls are aligned
    call bsk_kern_init              # choose the matrix kernel variant
    call bsk_program                # run the BASIC program
    call bsk_end                    # fell off the end: behave like END
    ud2                             # bsk_end does not return
    .size main, . - main

# ---------------------------------------------------------------------
# bsk_end -- END / STOP: normal termination.
#   Purpose : write the pending-line newline (if col != 0), flush the
#             stdout buffer, exit with status EXIT_RUN_OK, or
#             EXIT_RUN_ERROR if writing stdout failed (LANGUAGE.md 10).
#   Inputs  : none
#   Outputs : never returns
#   Clobbers: everything
#   Callee-saved used: %rbp = frame pointer
#   Frame   : 8 bytes (saved %rbp), then %rsp is rounded down to a
#             multiple of 16 so the stack is aligned however we came here
# ---------------------------------------------------------------------
    .globl bsk_end
    .type bsk_end, @function
    .p2align 4
bsk_end:
    pushq %rbp
    movq %rsp, %rbp
    andq $-16, %rsp                 # noreturn: force 16-byte alignment
    call bsk_rt_finish_output       # newline if mid-line, then flush
    movl $EXIT_RUN_OK, %edi         # END and STOP exit 0 ...
    movl $EXIT_RUN_ERROR, %ecx
    testl %eax, %eax                # %eax = 1 if stdout broke
    cmovnel %ecx, %edi              # ... or 1 if output was lost
    call exit@PLT                   # libc exit(3); does not return
    ud2
    .size bsk_end, . - bsk_end

# ---------------------------------------------------------------------
# Data shared with compiled code.
# bsk_curline: u32, BASIC line number of the statement being executed.
# Compiled code stores it at every OP_LINE; bsk_err prints it.
# ---------------------------------------------------------------------
    .bss
    .p2align 2
    .globl bsk_curline
    .type bsk_curline, @object
    .size bsk_curline, 4
bsk_curline:
    .zero 4

    .section .note.GNU-stack,"",@progbits
