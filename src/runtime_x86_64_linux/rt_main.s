# =====================================================================
# src/runtime_x86_64_linux/rt_main.s -- process entry, program
# termination and the current-line variable shared with compiled code.
#
# Defines: main, bsk_end, bsk_curline   (docs/DESIGN.md sections 6, 6.4)
#
# main first selects the matrix kernels (bsk_kern_init, rt_kinit.s).
# All other runtime state is initialised statically in the file that
# owns it (print counters and buffer: rt_print.s, RND state: rt_rnd.s,
# DATA cursor: rt_data.s, GOSUB stack: rt_gosub.s, call stack:
# rt_sub.s). Then main maps the program stack (DESIGN.md 6.9) and runs
# the program on it.
# =====================================================================
.include "baysick.inc"

# glibc / Linux x86_64 values for the program stack (DESIGN.md 6.9).
.equ RT_MAIN_SC_PAGESIZE, 30        # sysconf name _SC_PAGESIZE
.equ RT_MAIN_PROT_NONE,   0
.equ RT_MAIN_PROT_RW,     3         # PROT_READ | PROT_WRITE
.equ RT_MAIN_MAP_FLAGS,   0x22      # MAP_PRIVATE (0x02) | MAP_ANONYMOUS (0x20)
.equ RT_MAIN_MADV_NOHUGEPAGE, 15    # madvise advice MADV_NOHUGEPAGE (14 is MADV_HUGEPAGE)

    .text

# ---------------------------------------------------------------------
# main -- process entry point of every compiled BASIC program (called
#   by glibc's start code).
#   Purpose : select the matrix kernel variant (bsk_kern_init,
#             DESIGN.md 6.6.2); map the program stack (DESIGN.md 6.9):
#             RT_PROGRAM_STACK_BYTES plus one guard page G
#             (sysconf(_SC_PAGESIZE)) with mmap(NULL, size + G,
#             PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0),
#             the lowest G bytes made inaccessible with mprotect(base,
#             G, PROT_NONE); then run the compiled main function
#             bsk_program with %rsp = base + G + RT_PROGRAM_STACK_BYTES
#             (page-aligned, so 16-byte aligned at the call); if that
#             ever returns (it should end with bsk_end), terminate
#             exactly like END. A failure of sysconf, mmap or mprotect
#             -> OUT OF ROOM (bsk_curline is still 0). Right after the
#             mmap, madvise(base, size + G, MADV_NOHUGEPAGE) keeps a
#             THP-always host from backing the stack with a 2 MiB huge
#             page; its result is ignored (advisory; old kernels may
#             return EINVAL). The stack is used for nothing else and
#             never freed.
#   Inputs  : %edi = argc, %rsi = argv (ignored; programs read no
#             arguments)
#   Outputs : never returns
#   Clobbers: everything (control never comes back)
#   Callee-saved used (not restored: the function never returns):
#             %rbp = frame pointer, %rbx = mapping base, %r12 = G
#   Frame   : 24 bytes on the process stack (%rbp, %rbx, %r12); entered
#             at %rsp = 8 (mod 16), the three pushes leave %rsp = 0
#             (mod 16), so no pad is needed; then the program stack
# ---------------------------------------------------------------------
    .globl main
    .type main, @function
    .p2align 4
main:
    pushq %rbp                      # entered with %rsp = 8 (mod 16): now 0
    movq %rsp, %rbp
    pushq %rbx                      # %rsp = 8 (mod 16)
    pushq %r12                      # %rsp = 0 (mod 16): calls are aligned
    call bsk_kern_init              # choose the matrix kernel variant

    # G = the host page size.
    movl $RT_MAIN_SC_PAGESIZE, %edi
    call sysconf@PLT
    testq %rax, %rax
    jle .Lrt_main_room              # -1 (or 0): no page size
    movq %rax, %r12

    # base = mmap(NULL, RT_PROGRAM_STACK_BYTES + G, RW, private anon)
    xorl %edi, %edi
    leaq RT_PROGRAM_STACK_BYTES(%r12), %rsi
    movl $RT_MAIN_PROT_RW, %edx
    movl $RT_MAIN_MAP_FLAGS, %ecx
    movl $-1, %r8d                  # no file
    xorl %r9d, %r9d                 # offset 0
    call mmap@PLT
    cmpq $-1, %rax
    je .Lrt_main_room               # MAP_FAILED
    movq %rax, %rbx

    # Advisory: no transparent huge page for the stack (a THP would make
    # every run touch about 2 MiB). The result is ignored: old kernels may
    # return EINVAL, and the program is correct either way.
    movq %rbx, %rdi
    leaq RT_PROGRAM_STACK_BYTES(%r12), %rsi
    movl $RT_MAIN_MADV_NOHUGEPAGE, %edx
    call madvise@PLT

    # The guard page: the lowest G bytes, no access.
    movq %rbx, %rdi
    movq %r12, %rsi
    movl $RT_MAIN_PROT_NONE, %edx
    call mprotect@PLT
    testl %eax, %eax
    jnz .Lrt_main_room

    # Switch to the program stack (its top is page-aligned) and run.
    leaq RT_PROGRAM_STACK_BYTES(%rbx,%r12), %rsp
    call bsk_program                # run the BASIC program
    call bsk_end                    # fell off the end: behave like END
    ud2                             # bsk_end does not return
.Lrt_main_room:
    movl $ERR_OUT_OF_ROOM, %edi
    call bsk_err                    # "OUT OF ROOM IN 0", exit 1
    ud2
    .size main, . - main

# ---------------------------------------------------------------------
# bsk_end -- END / STOP: normal termination.
#   Purpose : finish the files in write mode (bsk_rt_files_finish:
#             pending newline, flush; DESIGN.md 6.8); if writing one of
#             them failed, end as the run-time error CAN'T WRITE FILE
#             (bsk_curline is still the END / STOP line). Otherwise write
#             stdout's pending-line newline (if col != 0), flush the
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
    call bsk_rt_files_finish        # every file in write mode, in order
    testl %eax, %eax
    jz 1f
    movl $ERR_CANT_WRITE_FILE, %edi # a file's last output was lost
    call bsk_err                    # noreturn
1:
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
