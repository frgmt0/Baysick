# =====================================================================
# src/runtime_x86_64_linux/rt_files.s -- the Fifth Edition file layer:
# file numbers, modes, opening, SCRATCH #, RESTORE #, IF END # and the
# finishing of the files at termination (LANGUAGE.md 7.21-7.26, 10;
# DESIGN.md 6.8).
#
# Defines (global, runtime.inc):
#   bsk_fsel bsk_feof bsk_scratch bsk_frestore
# Defines (private to the runtime, .globl + .hidden):
#   bsk_rt_fsel            u32 pending file selection: 0 = none, k + 1 =
#                          file k (read and reset by every print and
#                          input entry point, rt_print.s / rt_input.s)
#   bsk_rt_file_wcheck     print to file k: must be in write mode
#   bsk_rt_file_ropen      input from file k: read mode, open if needed
#   bsk_rt_files_finish    termination: finish every file in write mode
# Uses (private): bsk_rt_out_start bsk_rt_out_discard bsk_rt_out_finish
# bsk_rt_out_failed
# (rt_print.s: each file's output record), bsk_rt_in_attach
# bsk_rt_in_detach bsk_rt_in_ateof (rt_input.s: each file's reader).
# Uses (defined by every program of a Fifth Edition compiler):
# bsk_files (SD[], entry k - 1 = the name of file k), bsk_files_count.
#
# File table. Runtime-private, LIM_FILES entries indexed by k - 1,
# zero-initialised = "read, not open": the state (FS_*) and the fd. The
# column state and output buffer of a file live in its output record
# (rt_print.s), its reader in its reader record (rt_input.s). Entries
# beyond bsk_files_count are never touched.
#
# Opening (LANGUAGE.md 7.21, DESIGN.md 6.8): the name is copied into a
# NUL-terminated buffer of LIM_FILE_NAME + 1 bytes and used as the path,
# unchanged. Read: open(path, O_RDONLY), then fstat; a directory is
# closed and fails. Write: open(path, O_WRONLY | O_CREAT | O_TRUNC,
# 0666). Any failure -> CAN'T OPEN FILE. close results are ignored.
# =====================================================================
.include "baysick.inc"

# File states (runtime-private).
.equ FS_READ_CLOSED, 0              # read mode, not open (initial; RESTORE #)
.equ FS_READ_OPEN,   1              # read mode, open (first INPUT # / IF END #)
.equ FS_WRITE,       2              # write mode (SCRATCH #)

# Linux <fcntl.h> / <sys/stat.h> values (DESIGN.md 6.4.3, 6.8).
.equ RT_O_RDONLY,    0
.equ RT_O_WRONLY,    01
.equ RT_O_CREAT,     0100
.equ RT_O_TRUNC,     01000
.equ RT_OPEN_MODE,   0666           # before the process umask
.equ RT_STAT_SIZE,   144            # sizeof(struct stat)
.equ RT_STAT_MODE,   24             # offset of st_mode (u32)
.equ RT_S_IFMT,      0170000
.equ RT_S_IFDIR,     0040000

    .text

# ---------------------------------------------------------------------
# .Lrt_files_number -- the file number of a designator (LANGUAGE.md
#   7.21): k = trunc(x) must satisfy 0 <= k <= bsk_files_count, else
#   INVALID FILE NUMBER. Compared as doubles before any conversion, so
#   huge, infinite or NaN values can never wrap: 0 <= trunc(x) <= N is
#   exactly -1 < x < N + 1.
#   Private convention (leaf):
#   Inputs  : %xmm0 = x
#   Outputs : %eax = k
#   Clobbers: %rax %rcx %xmm1
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_files_number:
    movq bsk_files_count(%rip), %rax  # N
    addq $1, %rax
    cvtsi2sdq %rax, %xmm1           # N + 1 (exact: N <= LIM_FILES)
    ucomisd %xmm0, %xmm1
    jbe .Lrt_files_invalid          # x >= N + 1, or NaN
    movsd .Lrt_files_minus1(%rip), %xmm1
    ucomisd %xmm1, %xmm0
    jbe .Lrt_files_invalid          # x <= -1 (NaN handled above)
    cvttsd2si %xmm0, %eax           # -1 < x < N + 1: k = trunc(x)
    ret
.Lrt_files_invalid:
    movl $ERR_INVALID_FILE_NUMBER, %edi
    jmp bsk_err

# ---------------------------------------------------------------------
# .Lrt_files_path -- copy the name of file k into .Lrt_files_pathbuf as
#   a NUL-terminated path (the bytes unchanged).
#   Inputs  : %edi = k (1 .. bsk_files_count)
#   Outputs : %rax = the path; 0 if the name does not fit (never for a
#             compiled program: a name has at most 249 bytes)
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = name length, %rbp = frame pointer
#   Frame   : 24 bytes (%rbp, %rbx + 8 bytes alignment pad)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_files_path:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    subq $8, %rsp                   # %rsp = 0 (mod 16)
    movl %edi, %eax
    subl $1, %eax
    shlq $4, %rax                   # (k - 1) * SD_SIZE
    leaq bsk_files(%rip), %rsi
    addq %rax, %rsi                 # the name's SD record
    movl SD_LEN(%rsi), %ebx
    xorl %eax, %eax
    cmpl $LIM_FILE_NAME, %ebx
    ja 1f                           # cannot be a FILES name
    movq SD_PTR(%rsi), %rsi
    leaq .Lrt_files_pathbuf(%rip), %rdi
    movq %rbx, %rdx
    call memcpy@PLT                 # %rax = the buffer
    movb $0, (%rax,%rbx)            # NUL-terminated
1:
    addq $8, %rsp
    popq %rbx
    popq %rbp
    ret

.equ RT_SD_SIZE_IS_16, SD_SIZE - 16
.if RT_SD_SIZE_IS_16
    .error ".Lrt_files_path multiplies by SD_SIZE with a shift by 4"
.endif

# ---------------------------------------------------------------------
# bsk_fsel -- select the file of the next print or input entry point
#   (PRINT #, INPUT #; DESIGN.md 6.8).
#   Inputs  : %xmm0 = the designator value
#   Outputs : none (bsk_rt_fsel := k + 1)
#   Errors  : INVALID FILE NUMBER
#   Clobbers: %rax %rcx %xmm1
#   Callee-saved used: %rbp = frame pointer
#   Frame   : 8 bytes (saved %rbp)
# ---------------------------------------------------------------------
    .globl bsk_fsel
    .type bsk_fsel, @function
    .p2align 4
bsk_fsel:
    pushq %rbp
    movq %rsp, %rbp
    call .Lrt_files_number          # %eax = k
    addl $1, %eax
    movl %eax, bsk_rt_fsel(%rip)    # pending: file k
    popq %rbp
    ret
    .size bsk_fsel, . - bsk_fsel

# ---------------------------------------------------------------------
# bsk_rt_file_wcheck -- a print entry point selected file k: it must be
#   in write mode, else ILLEGAL FILE COMMAND.
#   Inputs  : %edi = k (1 .. bsk_files_count)
#   Outputs : none
#   Clobbers: %rax, %rcx (no floating-point register is touched)
#   Callee-saved used: none   Frame: none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_rt_file_wcheck
    .hidden bsk_rt_file_wcheck
    .type bsk_rt_file_wcheck, @function
    .p2align 4
bsk_rt_file_wcheck:
    leaq .Lrt_files_state(%rip), %rcx
    movl %edi, %eax
    cmpl $FS_WRITE, -4(%rcx,%rax,4) # state of file k
    jne .Lrt_files_illegal
    ret
.Lrt_files_illegal:
    movl $ERR_ILLEGAL_FILE_COMMAND, %edi
    jmp bsk_err
    .size bsk_rt_file_wcheck, . - bsk_rt_file_wcheck

# ---------------------------------------------------------------------
# bsk_rt_file_ropen -- an input entry point or IF END # uses file k: it
#   must be in read mode (else ILLEGAL FILE COMMAND); "read, not open"
#   opens the host file for reading (open, fstat: a directory fails;
#   CAN'T OPEN FILE) and attaches the file's reader at its first byte
#   (OUT OF ROOM if its buffers cannot be allocated); then "read, open".
#   Inputs  : %edi = k (1 .. bsk_files_count)
#   Outputs : none
#   Errors  : ILLEGAL FILE COMMAND, CAN'T OPEN FILE, OUT OF ROOM
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = k, %r12 = fd, %r13 = &state of file k,
#             %rbp = frame pointer
#   Frame   : 32 bytes (%rbp, %rbx, %r12, %r13) + RT_STAT_SIZE bytes
#             struct stat at (%rsp) + 8 bytes pad
# ---------------------------------------------------------------------
    .globl bsk_rt_file_ropen
    .hidden bsk_rt_file_ropen
    .type bsk_rt_file_ropen, @function
    .p2align 4
bsk_rt_file_ropen:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    subq $RT_STAT_SIZE + 8, %rsp    # %rsp = 0 (mod 16)
    movl %edi, %ebx
    leaq .Lrt_files_state(%rip), %r13
    leaq -4(%r13,%rbx,4), %r13      # &state[k - 1]
    movl (%r13), %eax
    cmpl $FS_WRITE, %eax
    je .Lrt_files_illegal           # INPUT # from a file in write mode
    cmpl $FS_READ_OPEN, %eax
    je 9f                           # already open: nothing to do
    movl %ebx, %edi
    call .Lrt_files_path            # %rax = path or 0
    testq %rax, %rax
    jz .Lrt_files_cantopen
    movq %rax, %rdi
    movl $RT_O_RDONLY, %esi
    xorl %eax, %eax                 # variadic: no vector registers
    call open@PLT                   # %eax = fd or -1
    testl %eax, %eax
    js .Lrt_files_cantopen
    movl %eax, %r12d
    movl %r12d, %edi
    movq %rsp, %rsi
    call fstat@PLT                  # a directory opens on Unix: reject it
    testl %eax, %eax
    jnz 1f                          # fstat failed: cannot read it
    movl RT_STAT_MODE(%rsp), %eax
    andl $RT_S_IFMT, %eax
    cmpl $RT_S_IFDIR, %eax
    jne 2f                          # not a directory: usable
1:
    movl %r12d, %edi
    call close@PLT                  # result ignored
    jmp .Lrt_files_cantopen
2:
    movl %ebx, %edi
    movl %r12d, %esi
    call bsk_rt_in_attach           # reader at the first byte
    leaq .Lrt_files_fd(%rip), %rax
    movl %r12d, -4(%rax,%rbx,4)     # fd of file k
    movl $FS_READ_OPEN, (%r13)
9:
    addq $RT_STAT_SIZE + 8, %rsp
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret
.Lrt_files_cantopen:
    movl $ERR_CANT_OPEN_FILE, %edi
    jmp bsk_err
    .size bsk_rt_file_ropen, . - bsk_rt_file_ropen

# ---------------------------------------------------------------------
# bsk_feof -- IF END # (LANGUAGE.md 7.26): 1 if file k is at its end.
#   Purpose : number check; k = 0: the standard-input reader; k >= 1 in
#             write mode: 0; in read mode: opened if necessary, then 1 if
#             its reader holds no unread byte and a refill read returns
#             0 bytes (bsk_rt_in_ateof).
#   Inputs  : %xmm0 = the designator value
#   Outputs : %eax = 1 at the end, else 0
#   Errors  : INVALID FILE NUMBER, CAN'T OPEN FILE, OUT OF ROOM
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = k, %rbp = frame pointer
#   Frame   : 24 bytes (%rbp, %rbx + 8 bytes alignment pad)
# ---------------------------------------------------------------------
    .globl bsk_feof
    .type bsk_feof, @function
    .p2align 4
bsk_feof:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    subq $8, %rsp                   # %rsp = 0 (mod 16)
    call .Lrt_files_number          # %eax = k
    movl %eax, %ebx
    testl %ebx, %ebx
    jz 1f                           # standard input
    leaq .Lrt_files_state(%rip), %rcx
    xorl %eax, %eax
    cmpl $FS_WRITE, -4(%rcx,%rbx,4)
    je 2f                           # write mode: never at its end
    movl %ebx, %edi
    call bsk_rt_file_ropen          # open if necessary
1:
    movl %ebx, %edi
    call bsk_rt_in_ateof            # %eax = 1 at the end
2:
    addq $8, %rsp
    popq %rbx
    popq %rbp
    ret
    .size bsk_feof, . - bsk_feof

# ---------------------------------------------------------------------
# .Lrt_files_close -- close file k if it is open and make it "read, not
#   open" with an empty reader. Write mode: the unwritten output is
#   discarded when %esi = 1 (SCRATCH), else it must have been finished
#   by the caller.
#   Inputs  : %edi = k, %esi = 1 to discard buffered output
#   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = k, %r12 = discard flag, %rbp = frame
#             pointer
#   Frame   : 24 bytes (%rbp, %rbx, %r12)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_files_close:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12                      # 3 pushes: %rsp = 0 (mod 16)
    movl %edi, %ebx
    movl %esi, %r12d
    leaq .Lrt_files_state(%rip), %rcx
    movl -4(%rcx,%rbx,4), %eax
    cmpl $FS_READ_CLOSED, %eax
    je 2f                           # not open
    cmpl $FS_WRITE, %eax
    jne 1f
    testl %r12d, %r12d
    jz 1f
    movl %ebx, %edi
    call bsk_rt_out_discard         # SCRATCH: the file is emptied anyway
1:
    leaq .Lrt_files_fd(%rip), %rcx
    movl -4(%rcx,%rbx,4), %edi
    call close@PLT                  # result ignored
    leaq .Lrt_files_state(%rip), %rcx
    movl $FS_READ_CLOSED, -4(%rcx,%rbx,4)
2:
    movl %ebx, %edi
    call bsk_rt_in_detach           # the reader holds nothing
    popq %r12
    popq %rbx
    popq %rbp
    ret

# ---------------------------------------------------------------------
# bsk_scratch -- SCRATCH # (LANGUAGE.md 7.22).
#   Purpose : number check; k = 0 -> INVALID FILE NUMBER. Close the file
#             if open (write mode: buffered output discarded); then
#             open(path, O_WRONLY|O_CREAT|O_TRUNC, 0666) (failure ->
#             CAN'T OPEN FILE); only then the output buffer (allocated
#             at the first SCRATCH, OUT OF ROOM) and write mode with
#             col = out = 0.
#   Inputs  : %xmm0 = the designator value
#   Outputs : none
#   Errors  : INVALID FILE NUMBER, CAN'T OPEN FILE, OUT OF ROOM
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = k, %r12 = fd, %rbp = frame pointer
#   Frame   : 24 bytes (%rbp, %rbx, %r12)
# ---------------------------------------------------------------------
    .globl bsk_scratch
    .type bsk_scratch, @function
    .p2align 4
bsk_scratch:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12                      # 3 pushes: %rsp = 0 (mod 16)
    call .Lrt_files_number          # %eax = k
    testl %eax, %eax
    jz .Lrt_files_invalid           # SCRATCH #0
    movl %eax, %ebx
    movl %ebx, %edi
    movl $1, %esi                   # discard unwritten output
    call .Lrt_files_close
    movl %ebx, %edi
    call .Lrt_files_path            # %rax = path or 0
    testq %rax, %rax
    jz .Lrt_files_cantopen
    movq %rax, %rdi
    movl $(RT_O_WRONLY | RT_O_CREAT | RT_O_TRUNC), %esi
    movl $RT_OPEN_MODE, %edx
    xorl %eax, %eax                 # variadic: no vector registers
    call open@PLT                   # create or truncate
    testl %eax, %eax
    js .Lrt_files_cantopen
    movl %eax, %r12d
    movl %ebx, %edi
    movl %r12d, %esi
    call bsk_rt_out_start           # buffer (OUT OF ROOM), col = out = 0
    leaq .Lrt_files_fd(%rip), %rcx
    movl %r12d, -4(%rcx,%rbx,4)     # fd of file k
    leaq .Lrt_files_state(%rip), %rcx
    movl $FS_WRITE, -4(%rcx,%rbx,4) # write mode
    popq %r12
    popq %rbx
    popq %rbp
    ret
    .size bsk_scratch, . - bsk_scratch

# ---------------------------------------------------------------------
# bsk_frestore -- RESTORE # (LANGUAGE.md 7.23).
#   Purpose : number check; k = 0 -> INVALID FILE NUMBER. Write mode:
#             newline if col != 0, buffered output written (CAN'T WRITE
#             FILE), closed. Read mode, open: closed. Then "read, not
#             open" with an empty reader.
#   Inputs  : %xmm0 = the designator value
#   Outputs : none
#   Errors  : INVALID FILE NUMBER, CAN'T WRITE FILE
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = k, %rbp = frame pointer
#   Frame   : 24 bytes (%rbp, %rbx + 8 bytes alignment pad)
# ---------------------------------------------------------------------
    .globl bsk_frestore
    .type bsk_frestore, @function
    .p2align 4
bsk_frestore:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    subq $8, %rsp                   # %rsp = 0 (mod 16)
    call .Lrt_files_number          # %eax = k
    testl %eax, %eax
    jz .Lrt_files_invalid           # RESTORE #0
    movl %eax, %ebx
    leaq .Lrt_files_state(%rip), %rcx
    cmpl $FS_WRITE, -4(%rcx,%rbx,4)
    jne 1f
    movl %ebx, %edi
    movl $1, %esi                   # a failure is CAN'T WRITE FILE
    call bsk_rt_out_finish          # pending newline, then flush
1:
    movl %ebx, %edi
    xorl %esi, %esi                 # nothing left to discard
    call .Lrt_files_close
    addq $8, %rsp
    popq %rbx
    popq %rbp
    ret
    .size bsk_frestore, . - bsk_frestore

# ---------------------------------------------------------------------
# bsk_rt_files_finish -- finish the files at termination (LANGUAGE.md 10,
#   DESIGN.md 6.8), once per run: for k = 1 .. bsk_files_count in
#   ascending order, every file in write mode whose "failed" flag is
#   clear gets an LF if its col != 0 and is flushed; a failure is
#   remembered and the loop continues. A second call finishes nothing.
#   Inputs  : none
#   Outputs : %eax = 1 if the "failed" flag of any file 1 .. N is set
#             (now or earlier, until its next SCRATCH), else 0
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = k, %r12 = N, %r13 = failure seen,
#             %rbp = frame pointer
#   Frame   : 40 bytes (%rbp, %rbx, %r12, %r13 + 8 bytes pad)
# ---------------------------------------------------------------------
    .globl bsk_rt_files_finish
    .hidden bsk_rt_files_finish
    .type bsk_rt_files_finish, @function
    .p2align 4
bsk_rt_files_finish:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    subq $8, %rsp                   # %rsp = 0 (mod 16)
    movq bsk_files_count(%rip), %r12  # N, never beyond the table
    movl $LIM_FILES, %eax
    cmpq %rax, %r12
    cmovaq %rax, %r12
    cmpl $0, .Lrt_files_done(%rip)
    jne 4f                          # finished already
    movl $1, .Lrt_files_done(%rip)
    movl $1, %ebx                   # k
1:
    cmpq %r12, %rbx
    ja 4f
    leaq .Lrt_files_state(%rip), %rcx
    cmpl $FS_WRITE, -4(%rcx,%rbx,4)
    jne 2f                          # read mode: nothing to finish
    movl %ebx, %edi
    xorl %esi, %esi                 # report a failure, do not raise
    call bsk_rt_out_finish          # skips a file that failed before
2:
    addq $1, %rbx
    jmp 1b
4:
    # The result: any file whose "write failed" flag is set.
    xorl %r13d, %r13d
    movl $1, %ebx
5:
    cmpq %r12, %rbx
    ja 3f
    movl %ebx, %edi
    call bsk_rt_out_failed
    orl %eax, %r13d
    addq $1, %rbx
    jmp 5b
3:
    movl %r13d, %eax
    addq $8, %rsp
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret
    .size bsk_rt_files_finish, . - bsk_rt_files_finish

    .section .rodata
    .p2align 3
.Lrt_files_minus1:
    .double -1.0

# ---------------------------------------------------------------------
# State (zero-initialised):
#   bsk_rt_fsel           u32 pending selection (0 none, k + 1 file k)
#   .Lrt_files_state      LIM_FILES u32: FS_* of file k at index k - 1
#   .Lrt_files_fd         LIM_FILES u32: its fd while open
#   .Lrt_files_done       u32 1 once the files were finished
#   .Lrt_files_pathbuf    LIM_FILE_NAME + 1 bytes: the NUL-terminated path
# ---------------------------------------------------------------------
    .bss
    .p2align 2
    .globl bsk_rt_fsel
    .hidden bsk_rt_fsel
    .type bsk_rt_fsel, @object
    .size bsk_rt_fsel, 4
bsk_rt_fsel:
    .zero 4
.Lrt_files_state:
    .zero 4 * LIM_FILES
.Lrt_files_fd:
    .zero 4 * LIM_FILES
.Lrt_files_done:
    .zero 4
.Lrt_files_pathbuf:
    .zero LIM_FILE_NAME + 1

    .section .note.GNU-stack,"",@progbits
