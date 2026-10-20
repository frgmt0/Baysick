# =====================================================================
# src/runtime_x86_64_linux/rt_print.s -- PRINT column logic, buffered
# stdout and the output side of the files (LANGUAGE.md 7.21, 7.24, 8, 10;
# DESIGN.md 6.2, 6.7, 6.8).
#
# Defines (global, runtime.inc):
#   bsk_print_num bsk_print_str bsk_print_comma bsk_print_semi
#   bsk_print_nl bsk_print_sv bsk_print_tab
# Defines (private to the runtime, .globl + .hidden):
#   bsk_rt_finish_output    pending-line newline + flush of stdout (END /
#                           errors); reports whether output was lost
#   bsk_rt_write_all        write(2) loop handling short writes / EINTR
#   bsk_rt_print_fresh      newline if col != 0 (MAT PRINT, rt_mat.s)
#   bsk_rt_flush            write the stdout buffer now (rt_input.s)
#   bsk_rt_print_prompt     the terminal INPUT prompt "? " (rt_input.s)
#   bsk_rt_print_linedone   col = out = 0 after a terminal line
#   bsk_rt_out_start        file k enters write mode (SCRATCH, rt_files.s)
#   bsk_rt_out_discard      drop file k's unwritten output (SCRATCH)
#   bsk_rt_out_failed       file k: has a write to it failed? (rt_files.s)
#   bsk_rt_out_finish       file k: newline if col != 0, then flush
#                           (RESTORE #, termination)
#   bsk_rt_err_newline      end standard error's pending line (before a
#                           BASIC message, at termination)
# Uses: bsk_rt_fsel (the pending file selection: 0 none, k + 1 file k,
# FILE_NUM_STDERR standard error) and bsk_rt_file_wcheck
# (rt_files.s), bsk_rt_fmtnum (rt_numfmt.s).
#
# Output records. Standard output and each file k (1 .. LIM_FILES) have
# one output record (OR_* below): the column state `col` / `out`, the
# output buffer, its fill count and capacity, the file descriptor and a
# "failed" flag. Record k is .Lrt_print_recs + k * OR_SIZE; record 0 is
# stdout. Standard error has one more record (.Lrt_print_errrec, fd 2,
# LANGUAGE.md 15.3, DESIGN.md 6.10). The column logic is one set of
# routines taking a record pointer, so the rules for stdout, standard
# error and the files cannot drift apart (DESIGN.md 6.8).
#
# Column model (LANGUAGE.md section 8): `col` is the logical column,
# `out` the number of characters physically written on this line.
# Spaces are lazy: a space only advances `col`; before any other
# character, col - out spaces are written. Hence no trailing blanks.
#
# Buffers. Bytes are appended by .Lrt_print_putc, the only place that
# writes a full buffer: as soon as a byte makes the fill count equal to
# the capacity (RT_OUTBUF_SIZE for stdout, RT_FILEBUF_SIZE for a file),
# the whole buffer is written. Otherwise stdout is written at
# termination, by the INPUT prompt and diagnostics and before every
# write to standard error; a file only at
# RESTORE # and at termination (bsk_rt_out_finish).
#
# Broken stdout (LANGUAGE.md section 10): if write(2) to fd 1 fails with
# an error other than EINTR, or writes 0 bytes, stdout is marked broken;
# all further output is discarded and bsk_rt_finish_output reports it,
# so END / STOP / OUT OF DATA exit with status 1 instead of 0.
# A failed write of a file (DESIGN.md 6.8) sets the file's "failed"
# flag, empties its buffer and remembers that output was lost (exit
# status 1); while printing it raises CAN'T WRITE FILE, while finishing
# it is only reported to the caller.
#
# Standard error (PRINT #-1) is not buffered between entry points: a
# print entry point on its record that put at least one byte into its
# buffer writes the buffer before it returns, and a full buffer is
# written as soon as it fills. Every write of the standard-error buffer
# (.Lrt_print_drain) first flushes stdout, so the bytes of both streams
# appear in program order on a shared file. A failed write to fd 2 drops
# the bytes and is otherwise ignored (no flag, no error, no status).
# SIGPIPE keeps the action the process inherited (no handler).
# =====================================================================
.include "baysick.inc"

.equ RT_EINTR, 4                    # <errno.h> EINTR on Linux
.equ RT_NUMBUF, 48                  # stack buffer for one number field
                                    # (longest field: "-1.23457E-308 " = 14)
.equ RT_CH_LF, 10                   # '\n'
.equ RT_CH_SPACE, 32                # ' '
.equ RT_CH_QMARK, 63                # '?'

# Output record (runtime-private, this file only).
.equ OR_COL,    0                   # u64 logical column
.equ OR_OUT,    8                   # u64 characters written on this line
.equ OR_FILL,   16                  # u64 bytes in the buffer
.equ OR_BUF,    24                  # ptr buffer (file: malloc'd at the first SCRATCH)
.equ OR_CAP,    32                  # u64 buffer capacity
.equ OR_FD,     40                  # u32 file descriptor
.equ OR_FAILED, 44                  # u32 stdout: broken; file: a write failed
.equ OR_SIZE,   48
.equ RT_PRINT_NRECS, LIM_FILES + 1  # stdout + files 1 .. LIM_FILES

    .text

# ---------------------------------------------------------------------
# bsk_rt_write_all -- write a whole byte range to a file descriptor.
#   Purpose : call write(2) until every byte is written; retry on
#             EINTR; give up on any other error or on a write that
#             makes no progress (returns 0), reporting failure to the
#             caller (nothing is printed: there is no better channel).
#   Inputs  : %edi = fd, %rsi = pointer, %rdx = length
#   Outputs : %eax = 0 if every byte was written, 1 on failure
#   Clobbers: all caller-saved registers (calls libc)
#   Callee-saved used: %rbx = fd, %r12 = cursor, %r13 = bytes remaining,
#             %rbp = frame pointer
#   Frame   : 40 bytes (%rbp, %rbx, %r12, %r13 + 8 bytes alignment pad)
# ---------------------------------------------------------------------
    .globl bsk_rt_write_all
    .hidden bsk_rt_write_all
    .type bsk_rt_write_all, @function
    .p2align 4
bsk_rt_write_all:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    subq $8, %rsp                   # 4 pushes + pad: %rsp = 0 (mod 16)
    movl %edi, %ebx                 # fd
    movq %rsi, %r12                 # next byte to write
    movq %rdx, %r13                 # bytes left
.Lrt_print_wa_loop:
    testq %r13, %r13
    jz .Lrt_print_wa_ok             # everything written
    movl %ebx, %edi
    movq %r12, %rsi
    movq %r13, %rdx
    call write@PLT                  # %rax = bytes written or -1
    testq %rax, %rax
    js .Lrt_print_wa_err            # -1: inspect errno
    jz .Lrt_print_wa_fail           # 0 bytes: no progress, give up
    addq %rax, %r12                 # advance past the bytes written
    subq %rax, %r13
    jmp .Lrt_print_wa_loop
.Lrt_print_wa_err:
    call __errno_location@PLT       # %rax = &errno (int *)
    cmpl $RT_EINTR, (%rax)
    je .Lrt_print_wa_loop           # interrupted: try again
.Lrt_print_wa_fail:
    movl $1, %eax                   # real error: report failure
    jmp .Lrt_print_wa_done
.Lrt_print_wa_ok:
    xorl %eax, %eax                 # all bytes written
.Lrt_print_wa_done:
    addq $8, %rsp
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret
    .size bsk_rt_write_all, . - bsk_rt_write_all

# ---------------------------------------------------------------------
# .Lrt_print_drain -- write a record's buffered bytes, empty the buffer.
#   Purpose : once the record has failed (stdout broken) the bytes are
#             discarded. A failed write sets OR_FAILED; for a file it
#             also reports failure. Standard error's record: stdout is
#             flushed first (this routine on record 0), then the bytes
#             go to fd 2; a failure there is ignored (never a flag).
#   Inputs  : %rdi = output record
#   Outputs : %eax = 1 if a file write failed now, else 0 (a stdout
#             failure is silent: it only marks stdout broken; a
#             standard-error failure is ignored)
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = record, %rbp = frame pointer
#   Frame   : 24 bytes (%rbp, %rbx + 8 bytes alignment pad)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_print_drain:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    subq $8, %rsp                   # %rsp = 0 (mod 16)
    movq %rdi, %rbx
    xorl %eax, %eax                 # nothing failed (yet)
    movq OR_FILL(%rbx), %rdx        # number of buffered bytes
    testq %rdx, %rdx
    jz 1f                           # nothing to write
    leaq .Lrt_print_errrec(%rip), %rcx
    cmpq %rcx, %rbx
    je .Lrt_print_drain_err         # standard error: its own rules
    movq $0, OR_FILL(%rbx)          # the buffer is empty afterwards
    cmpl $0, OR_FAILED(%rbx)
    jne 1f                          # broken / failed: discard
    movl OR_FD(%rbx), %edi
    movq OR_BUF(%rbx), %rsi
    call bsk_rt_write_all           # %eax = 0 ok, 1 failed
    testl %eax, %eax
    jz 1f                           # written completely
    movl $1, OR_FAILED(%rbx)        # stdout broken / file failed
    leaq .Lrt_print_recs(%rip), %rcx
    xorl %eax, %eax
    cmpq %rcx, %rbx
    je 1f                           # stdout: silent (LANGUAGE.md 10)
    movl $1, %eax                   # report the file failure
1:
    addq $8, %rsp
    popq %rbx
    popq %rbp
    ret
.Lrt_print_drain_err:
    # Standard output's buffered bytes go first (LANGUAGE.md 15.3).
    leaq .Lrt_print_recs(%rip), %rdi
    call .Lrt_print_drain           # stdout: a failure only marks it broken
    # Then every byte of the standard-error buffer, which is emptied
    # whatever happens: a failed write drops the rest, silently.
    movl OR_FD(%rbx), %edi          # fd 2
    movq OR_BUF(%rbx), %rsi
    movq OR_FILL(%rbx), %rdx
    movq $0, OR_FILL(%rbx)
    call bsk_rt_write_all           # result ignored (DESIGN.md 6.10)
    xorl %eax, %eax                 # never a reported failure
    jmp 1b

# ---------------------------------------------------------------------
# .Lrt_print_putc -- append one byte to a record's buffer.
#   Purpose : the byte-append routine of DESIGN.md 6.8: right after a
#             byte makes the fill count equal to the capacity, the full
#             buffer is written (.Lrt_print_drain); a file whose write
#             fails -> CAN'T WRITE FILE.
#   Inputs  : %rdi = output record, %esi = byte (low 8 bits)
#   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbp = frame pointer
#   Frame   : 8 bytes (saved %rbp; %rsp = 0 (mod 16) at the call)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_print_putc:
    movq OR_FILL(%rdi), %rax
    movq OR_BUF(%rdi), %rcx
    movb %sil, (%rcx,%rax)          # buf[fill] = byte
    addq $1, %rax
    movq %rax, OR_FILL(%rdi)
    cmpq OR_CAP(%rdi), %rax
    jae 1f                          # full: write it now
    ret
1:
    pushq %rbp
    movq %rsp, %rbp
    call .Lrt_print_drain           # %eax = 1 if a file write failed
    popq %rbp
    testl %eax, %eax
    jnz .Lrt_print_cantwrite
    ret
.Lrt_print_cantwrite:
    movl $ERR_CANT_WRITE_FILE, %edi
    jmp bsk_err                     # noreturn; realigns the stack

# ---------------------------------------------------------------------
# .Lrt_print_newline -- the "newline" action: write LF, col = out = 0.
#   Inputs  : %rdi = output record
#   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = record, %rbp = frame pointer
#   Frame   : 24 bytes (%rbp, %rbx + 8 bytes alignment pad)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_print_newline:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    subq $8, %rsp                   # %rsp = 0 (mod 16)
    movq %rdi, %rbx
    movl $RT_CH_LF, %esi
    call .Lrt_print_putc
    movq $0, OR_COL(%rbx)           # col = 0
    movq $0, OR_OUT(%rbx)           # out = 0
    addq $8, %rsp
    popq %rbx
    popq %rbp
    ret

# ---------------------------------------------------------------------
# .Lrt_print_emit -- the "emit(c)" action of LANGUAGE.md section 8.
#   Purpose : a space only advances col; any other byte is preceded by
#             col - out real spaces, then written; col += 1; out = col.
#   Inputs  : %rdi = output record, %esi = byte (low 8 bits)
#   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = record, %r12 = the byte, %r13 = spaces
#             still to write, %rbp = frame pointer
#   Frame   : 40 bytes (%rbp, %rbx, %r12, %r13 + 8 bytes pad)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_print_emit:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    subq $8, %rsp                   # %rsp = 0 (mod 16)
    movq %rdi, %rbx
    movzbl %sil, %r12d              # the byte
    cmpl $RT_CH_SPACE, %r12d
    jne .Lrt_print_emit_real
    addq $1, OR_COL(%rbx)           # lazy space: col += 1 only
    jmp .Lrt_print_emit_done
.Lrt_print_emit_real:
    movq OR_COL(%rbx), %r13
    subq OR_OUT(%rbx), %r13         # pending spaces = col - out
.Lrt_print_emit_pad:
    testq %r13, %r13
    jz .Lrt_print_emit_char
    movq %rbx, %rdi
    movl $RT_CH_SPACE, %esi
    call .Lrt_print_putc
    subq $1, %r13
    jmp .Lrt_print_emit_pad
.Lrt_print_emit_char:
    movq %rbx, %rdi
    movl %r12d, %esi
    call .Lrt_print_putc            # the byte itself
    movq OR_COL(%rbx), %rax
    addq $1, %rax                   # col += 1
    movq %rax, OR_COL(%rbx)
    movq %rax, OR_OUT(%rbx)         # out = col
.Lrt_print_emit_done:
    addq $8, %rsp
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret

# ---------------------------------------------------------------------
# .Lrt_print_select -- the output record of a print entry point.
#   Purpose : read the pending file selection (bsk_rt_fsel: 0 = none,
#             k + 1 = file k, FILE_NUM_STDERR = standard error) and
#             reset it to none; none or file 0 -> stdout's record;
#             standard error -> its record (always writable, DESIGN.md
#             6.10); file k >= 1 -> it must be in write mode
#             (bsk_rt_file_wcheck: else ILLEGAL FILE COMMAND), then its
#             record (DESIGN.md 6.8 "Pending selection").
#   Inputs  : none
#   Outputs : %rax = output record
#   Clobbers: all caller-saved registers except %xmm0 / %xmm1 (no
#             floating-point instruction is executed)
#   Callee-saved used: %rbx = k, %rbp = frame pointer
#   Frame   : 24 bytes (%rbp, %rbx + 8 bytes alignment pad)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_print_select:
    movl bsk_rt_fsel(%rip), %eax    # pending selection
    movl $0, bsk_rt_fsel(%rip)      # reset on entry, before anything else
    cmpl $FILE_NUM_STDERR, %eax
    je 2f                           # standard error: no mode check
    cmpl $1, %eax
    jbe 1f                          # none, or file 0: stdout
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    subq $8, %rsp                   # %rsp = 0 (mod 16)
    leal -1(%rax), %ebx             # k >= 1
    movl %ebx, %edi
    call bsk_rt_file_wcheck         # ILLEGAL FILE COMMAND unless write mode
    imulq $OR_SIZE, %rbx, %rax
    leaq .Lrt_print_recs(%rip), %rcx
    addq %rcx, %rax                 # record k
    addq $8, %rsp
    popq %rbx
    popq %rbp
    ret
1:
    leaq .Lrt_print_recs(%rip), %rax    # record 0: stdout
    ret
2:
    leaq .Lrt_print_errrec(%rip), %rax  # standard error's record
    ret

# ---------------------------------------------------------------------
# .Lrt_print_release -- the end of a print entry point that may have
#   put bytes into its record: standard error's record is written now
#   (stdout first, .Lrt_print_drain), so it never holds a byte between
#   two entry-point calls; an empty buffer writes nothing anywhere.
#   Any other record is left alone (buffered).
#   Inputs  : %rdi = output record
#   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: none
#   Frame   : none (tail jump; .Lrt_print_drain aligns itself)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_print_release:
    leaq .Lrt_print_errrec(%rip), %rax
    cmpq %rax, %rdi
    je .Lrt_print_drain             # standard error: write it now
    ret

# ---------------------------------------------------------------------
# bsk_print_str -- PRINT a string item (label).
#   Purpose : emit every byte to the selected output; never truncated
#             or wrapped.
#   Inputs  : %rdi = pointer to the bytes, %rsi = length (may be 0)
#   Outputs : none
#   Errors  : ILLEGAL FILE COMMAND, CAN'T WRITE FILE (selected file)
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = cursor, %r12 = end pointer, %r13 = output
#             record, %rbp = frame pointer
#   Frame   : 40 bytes (%rbp, %rbx, %r12, %r13 + 8 bytes pad)
# ---------------------------------------------------------------------
    .globl bsk_print_str
    .type bsk_print_str, @function
    .p2align 4
bsk_print_str:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    subq $8, %rsp                   # %rsp = 0 (mod 16)
    movq %rdi, %rbx                 # cursor
    leaq (%rdi,%rsi), %r12          # end
    call .Lrt_print_select
    movq %rax, %r13                 # output record
.Lrt_print_str_loop:
    cmpq %r12, %rbx
    jae .Lrt_print_str_done
    movzbl (%rbx), %esi             # next byte
    addq $1, %rbx
    movq %r13, %rdi
    call .Lrt_print_emit
    jmp .Lrt_print_str_loop
.Lrt_print_str_done:
    movq %r13, %rdi
    call .Lrt_print_release         # standard error: written now
    addq $8, %rsp
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret
    .size bsk_print_str, . - bsk_print_str

# ---------------------------------------------------------------------
# bsk_print_num -- PRINT a number item.
#   Purpose : format the field F (LANGUAGE.md section 9); if fewer than
#             PRINT_MIN_ROOM columns remain before PRINT_LINE_WIDTH,
#             newline first; then emit every character of F, on the
#             selected output.
#   Inputs  : %xmm0 = value (finite)
#   Outputs : none
#   Errors  : ILLEGAL FILE COMMAND, CAN'T WRITE FILE (selected file)
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = cursor in the field, %r12 = end of field,
#             %r13 = output record, %rbp = frame pointer
#   Frame   : 32 bytes (%rbp, %rbx, %r12, %r13) + RT_NUMBUF field
#             buffer at (%rsp) + 8 bytes pad
# ---------------------------------------------------------------------
    .globl bsk_print_num
    .type bsk_print_num, @function
    .p2align 4
bsk_print_num:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    subq $RT_NUMBUF + 8, %rsp       # field buffer; %rsp = 0 (mod 16)
    call .Lrt_print_select          # keeps %xmm0 (the value)
    movq %rax, %r13                 # output record
    movq %rsp, %rdi
    call bsk_rt_fmtnum              # %rax = field length
    movq %rsp, %rbx                 # cursor
    leaq (%rsp,%rax), %r12          # end of field
    # Room check: newline if 75 - col < 12, i.e. col > 63 (col may
    # exceed 75 after a long label; the unsigned test covers that).
    cmpq $(PRINT_LINE_WIDTH - PRINT_MIN_ROOM), OR_COL(%r13)
    jbe .Lrt_print_num_loop
    movq %r13, %rdi
    call .Lrt_print_newline
.Lrt_print_num_loop:
    cmpq %r12, %rbx
    jae .Lrt_print_num_done
    movzbl (%rbx), %esi             # next character of the field
    addq $1, %rbx
    movq %r13, %rdi
    call .Lrt_print_emit
    jmp .Lrt_print_num_loop
.Lrt_print_num_done:
    movq %r13, %rdi
    call .Lrt_print_release         # standard error: written now
    addq $RT_NUMBUF + 8, %rsp
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret
    .size bsk_print_num, . - bsk_print_num

# ---------------------------------------------------------------------
# bsk_print_comma -- PRINT ',' : next zone strictly to the right.
#   Purpose : col = (col / 15 + 1) * 15; newline if col >= 75 (on the
#             selected output).
#   Inputs  : none
#   Outputs : none
#   Errors  : ILLEGAL FILE COMMAND, CAN'T WRITE FILE (selected file)
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = output record, %rbp = frame pointer
#   Frame   : 24 bytes (%rbp, %rbx + 8 bytes alignment pad)
# ---------------------------------------------------------------------
    .globl bsk_print_comma
    .type bsk_print_comma, @function
    .p2align 4
bsk_print_comma:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    subq $8, %rsp                   # %rsp = 0 (mod 16)
    call .Lrt_print_select
    movq %rax, %rbx                 # output record
    movq OR_COL(%rbx), %rax
    movl $PRINT_ZONE_WIDTH, %ecx
    xorl %edx, %edx
    divq %rcx                       # %rax = current zone index
    addq $1, %rax                   # next zone
    imulq %rcx, %rax                # its first column
    movq %rax, OR_COL(%rbx)
    cmpq $PRINT_LINE_WIDTH, %rax
    jb 1f                           # still on this line: nothing written
    movq %rbx, %rdi
    call .Lrt_print_newline         # the line is full
    movq %rbx, %rdi
    call .Lrt_print_release         # standard error: written now
1:
    addq $8, %rsp
    popq %rbx
    popq %rbp
    ret
    .size bsk_print_comma, . - bsk_print_comma

# ---------------------------------------------------------------------
# bsk_print_semi -- PRINT ';' after a number: next multiple of 3
#   strictly to the right; no newline is forced.
#   Inputs  : none
#   Outputs : none
#   Errors  : ILLEGAL FILE COMMAND (selected file)
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbp = frame pointer
#   Frame   : 8 bytes (saved %rbp)
# ---------------------------------------------------------------------
    .globl bsk_print_semi
    .type bsk_print_semi, @function
    .p2align 4
bsk_print_semi:
    pushq %rbp
    movq %rsp, %rbp
    call .Lrt_print_select
    movq %rax, %rdi                 # output record
    movq OR_COL(%rdi), %rax
    movl $PRINT_PACK_WIDTH, %ecx
    xorl %edx, %edx
    divq %rcx                       # floor(col / 3)
    addq $1, %rax
    imulq %rcx, %rax                # next multiple of 3
    movq %rax, OR_COL(%rdi)
    popq %rbp
    ret
    .size bsk_print_semi, . - bsk_print_semi

# ---------------------------------------------------------------------
# bsk_print_nl -- end of a PRINT without a trailing separator: newline
#   on the selected output.
#   Inputs  : none
#   Outputs : none
#   Errors  : ILLEGAL FILE COMMAND, CAN'T WRITE FILE (selected file)
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = output record, %rbp = frame pointer
#   Frame   : 24 bytes (%rbp, %rbx + 8 bytes alignment pad)
# ---------------------------------------------------------------------
    .globl bsk_print_nl
    .type bsk_print_nl, @function
    .p2align 4
bsk_print_nl:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    subq $8, %rsp                   # %rsp = 0 (mod 16)
    call .Lrt_print_select
    movq %rax, %rbx                 # output record
    movq %rbx, %rdi
    call .Lrt_print_newline
    movq %rbx, %rdi
    call .Lrt_print_release         # standard error: written now
    addq $8, %rsp
    popq %rbx
    popq %rbp
    ret
    .size bsk_print_nl, . - bsk_print_nl

# ---------------------------------------------------------------------
# bsk_rt_print_fresh -- start a fresh line on stdout: newline if
#   col != 0 (MAT PRINT, DESIGN.md 6.5 / LANGUAGE.md 7.14.5 step 2).
#   Inputs  : none
#   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: none
#   Frame   : none (tail jump; .Lrt_print_newline sees our alignment)
# ---------------------------------------------------------------------
    .globl bsk_rt_print_fresh
    .hidden bsk_rt_print_fresh
    .type bsk_rt_print_fresh, @function
    .p2align 4
bsk_rt_print_fresh:
    leaq .Lrt_print_recs(%rip), %rdi    # stdout
    cmpq $0, OR_COL(%rdi)
    jne .Lrt_print_newline          # mid-line: end it
    ret                             # already at column 0
    .size bsk_rt_print_fresh, . - bsk_rt_print_fresh

# ---------------------------------------------------------------------
# bsk_print_sv -- PRINT a string variable, list or table element
#   (LANGUAGE.md 8 string item; DESIGN.md 6.7).
#   Purpose : emit every byte of the value through the column logic
#             (bsk_print_str reads the pending selection).
#   Inputs  : %rdi = SD record
#   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: none
#   Frame   : none (tail jump; bsk_print_str sees our caller's alignment)
# ---------------------------------------------------------------------
    .globl bsk_print_sv
    .type bsk_print_sv, @function
    .p2align 4
bsk_print_sv:
    movl SD_LEN(%rdi), %esi         # length (u32, zero-extended)
    movq SD_PTR(%rdi), %rdi         # bytes (may be 0 when length is 0)
    jmp bsk_print_str
    .size bsk_print_sv, . - bsk_print_sv

# ---------------------------------------------------------------------
# bsk_print_tab -- PRINT TAB(x) (LANGUAGE.md 8, DESIGN.md 6.7).
#   Purpose : m = fmod(trunc(x), 75) (both exact), m += 75 if m < 0,
#             so m is in 0 .. 74; if col < m then col = m (a lazy
#             movement: nothing is written), on the selected output.
#             Never starts a new line.
#   Inputs  : %xmm0 = x (finite)
#   Outputs : none
#   Errors  : ILLEGAL FILE COMMAND (selected file)
#   Clobbers: all caller-saved registers (libm)
#   Callee-saved used: %rbx = output record, %rbp = frame pointer
#   Frame   : 24 bytes (%rbp, %rbx + 8 bytes alignment pad)
# ---------------------------------------------------------------------
    .globl bsk_print_tab
    .type bsk_print_tab, @function
    .p2align 4
bsk_print_tab:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    subq $8, %rsp                   # %rsp = 0 (mod 16)
    call .Lrt_print_select          # keeps %xmm0 (x)
    movq %rax, %rbx                 # output record
    call trunc@PLT                  # k = trunc(x), exact
    movl $TAB_MODULUS, %eax
    cvtsi2sdl %eax, %xmm1           # 75.0
    call fmod@PLT                   # k mod 75 with the sign of k, exact
    pxor %xmm1, %xmm1
    ucomisd %xmm1, %xmm0
    jae 1f                          # m >= 0 (also -0)
    movl $TAB_MODULUS, %eax
    cvtsi2sdl %eax, %xmm1
    addsd %xmm1, %xmm0              # m in -74 .. -1: + 75, exact
1:
    cvttsd2si %xmm0, %rax           # 0 <= m <= 74
    cmpq OR_COL(%rbx), %rax
    jbe 2f                          # col >= m: TAB is ignored
    movq %rax, OR_COL(%rbx)         # col = m (lazy spaces)
2:
    addq $8, %rsp
    popq %rbx
    popq %rbp
    ret
    .size bsk_print_tab, . - bsk_print_tab

# ---------------------------------------------------------------------
# bsk_rt_flush -- write the stdout buffer now (INPUT diagnostics, the
#   terminal prompt, INPUT #0 and IF END #0 on a terminal; rt_input.s).
#   Same rules as every flush: once stdout is broken the bytes are
#   discarded.
#   Inputs  : none
#   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: none
#   Frame   : none (tail jump; .Lrt_print_drain aligns itself)
# ---------------------------------------------------------------------
    .globl bsk_rt_flush
    .hidden bsk_rt_flush
    .type bsk_rt_flush, @function
    .p2align 4
bsk_rt_flush:
    leaq .Lrt_print_recs(%rip), %rdi    # stdout
    jmp .Lrt_print_drain
    .size bsk_rt_flush, . - bsk_rt_flush

# ---------------------------------------------------------------------
# bsk_rt_print_prompt -- the INPUT prompt on a terminal (LANGUAGE.md
#   7.15, DESIGN.md 6.7): write the pending lazy spaces (col - out),
#   then "?" and a space; col = out = col + 2; flush stdout.
#   Inputs  : none
#   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = spaces still to write, %r12 = stdout's
#             record, %rbp = frame pointer
#   Frame   : 24 bytes (%rbp, %rbx, %r12)
# ---------------------------------------------------------------------
    .globl bsk_rt_print_prompt
    .hidden bsk_rt_print_prompt
    .type bsk_rt_print_prompt, @function
    .p2align 4
bsk_rt_print_prompt:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12                      # 3 pushes: %rsp = 0 (mod 16)
    leaq .Lrt_print_recs(%rip), %r12    # stdout
    movq OR_COL(%r12), %rbx
    subq OR_OUT(%r12), %rbx         # pending spaces = col - out
1:
    testq %rbx, %rbx
    jz 2f
    movq %r12, %rdi
    movl $RT_CH_SPACE, %esi
    call .Lrt_print_putc
    subq $1, %rbx
    jmp 1b
2:
    movq %r12, %rdi
    movl $RT_CH_QMARK, %esi
    call .Lrt_print_putc            # "?"
    movq %r12, %rdi
    movl $RT_CH_SPACE, %esi
    call .Lrt_print_putc            # " " (written, not lazy)
    movq OR_COL(%r12), %rax
    addq $2, %rax                   # the prompt's two columns
    movq %rax, OR_COL(%r12)
    movq %rax, OR_OUT(%r12)         # out = col: nothing pending
    movq %r12, %rdi
    call .Lrt_print_drain           # the user must see the prompt
    popq %r12
    popq %rbx
    popq %rbp
    ret
    .size bsk_rt_print_prompt, . - bsk_rt_print_prompt

# ---------------------------------------------------------------------
# bsk_rt_print_linedone -- after a line was read from a terminal the
#   cursor is at the start of a new line: stdout's col = out = 0
#   (nothing is written).
#   Inputs  : none   Outputs : none   Clobbers: %rax
#   Callee-saved used: none   Frame: none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_rt_print_linedone
    .hidden bsk_rt_print_linedone
    .type bsk_rt_print_linedone, @function
    .p2align 4
bsk_rt_print_linedone:
    leaq .Lrt_print_recs(%rip), %rax    # stdout
    movq $0, OR_COL(%rax)
    movq $0, OR_OUT(%rax)
    ret
    .size bsk_rt_print_linedone, . - bsk_rt_print_linedone

# ---------------------------------------------------------------------
# bsk_rt_finish_output -- termination step for END, STOP, OUT OF DATA
#   and every run-time error: stdout's newline if col != 0, then flush
#   stdout. (The files are finished before, by bsk_rt_files_finish.)
#   Inputs  : none
#   Outputs : %eax = 1 if output was lost (stdout broke, or a write of
#             a file failed at any time: the caller exits with status
#             1), else 0
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = stdout's record, %rbp = frame pointer
#   Frame   : 24 bytes (%rbp, %rbx + 8 bytes alignment pad)
# ---------------------------------------------------------------------
    .globl bsk_rt_finish_output
    .hidden bsk_rt_finish_output
    .type bsk_rt_finish_output, @function
    .p2align 4
bsk_rt_finish_output:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    subq $8, %rsp                   # %rsp = 0 (mod 16)
    leaq .Lrt_print_recs(%rip), %rbx    # stdout
    cmpq $0, OR_COL(%rbx)
    je 1f                           # at column 0: no pending line
    movq %rbx, %rdi
    call .Lrt_print_newline
1:
    movq %rbx, %rdi
    call .Lrt_print_drain
    movl OR_FAILED(%rbx), %eax      # 1 = stdout broken
    addq $8, %rsp
    popq %rbx
    popq %rbp
    ret
    .size bsk_rt_finish_output, . - bsk_rt_finish_output

# ---------------------------------------------------------------------
# bsk_rt_err_newline -- end standard error's pending line (DESIGN.md
#   6.10, LANGUAGE.md 15.3, 15.5 step 3): if its col != 0, an LF is
#   written to fd 2 (stdout flushed first, as before every write to
#   standard error; a failure is ignored) and col = out = 0. Called
#   before every BASIC message (bsk_err, the INPUT and MAT INPUT
#   diagnostics) and at termination after stdout's flush.
#   Inputs  : none
#   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = standard error's record, %rbp = frame
#             pointer
#   Frame   : 24 bytes (%rbp, %rbx + 8 bytes alignment pad); none when
#             col = 0
# ---------------------------------------------------------------------
    .globl bsk_rt_err_newline
    .hidden bsk_rt_err_newline
    .type bsk_rt_err_newline, @function
    .p2align 4
bsk_rt_err_newline:
    leaq .Lrt_print_errrec(%rip), %rax
    cmpq $0, OR_COL(%rax)
    jne 1f
    ret                             # at column 0: nothing pending
1:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    subq $8, %rsp                   # %rsp = 0 (mod 16)
    movq %rax, %rbx
    movq %rbx, %rdi
    call .Lrt_print_newline         # LF into the buffer, col = out = 0
    movq %rbx, %rdi
    call .Lrt_print_drain           # stdout first, then the LF to fd 2
    addq $8, %rsp
    popq %rbx
    popq %rbp
    ret
    .size bsk_rt_err_newline, . - bsk_rt_err_newline

# RT_PRINT_FREC: %rax = output record of file k (%edi = k, 1 ..
# LIM_FILES). Clobbers %rax, %rcx.
.macro RT_PRINT_FREC
    movl %edi, %eax
    imulq $OR_SIZE, %rax, %rax
    leaq .Lrt_print_recs(%rip), %rcx
    addq %rcx, %rax
.endm
# ---------------------------------------------------------------------
# bsk_rt_out_failed -- has a write to file k failed?
#   Inputs  : %edi = k (1 .. LIM_FILES)
#   Outputs : %eax = the file's "write failed" flag (0 or 1); SCRATCH
#             (bsk_rt_out_start) clears it
#   Clobbers: %rax, %rcx
#   Callee-saved used: none   Frame: none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_rt_out_failed
    .hidden bsk_rt_out_failed
    .type bsk_rt_out_failed, @function
    .p2align 4
bsk_rt_out_failed:
    RT_PRINT_FREC
    movl OR_FAILED(%rax), %eax
    ret
    .size bsk_rt_out_failed, . - bsk_rt_out_failed

# ---------------------------------------------------------------------
# bsk_rt_out_start -- file k enters write mode (SCRATCH #k, after its
#   open succeeded; LANGUAGE.md 7.22, DESIGN.md 6.8).
#   Purpose : if the file has no output buffer yet, malloc
#             RT_FILEBUF_SIZE bytes (failure -> OUT OF ROOM; the buffer
#             is then reused by every later SCRATCH); then col = out = 0,
#             the buffer empty, the "failed" flag clear, the fd stored.
#   Inputs  : %edi = k (1 .. LIM_FILES), %esi = fd (open for writing)
#   Outputs : none
#   Errors  : OUT OF ROOM
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = record, %r12 = fd, %rbp = frame pointer
#   Frame   : 24 bytes (%rbp, %rbx, %r12)
# ---------------------------------------------------------------------
    .globl bsk_rt_out_start
    .hidden bsk_rt_out_start
    .type bsk_rt_out_start, @function
    .p2align 4
bsk_rt_out_start:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12                      # 3 pushes: %rsp = 0 (mod 16)
    movl %esi, %r12d
    RT_PRINT_FREC
    movq %rax, %rbx
    cmpq $0, OR_BUF(%rbx)
    jne 1f                          # buffer from an earlier SCRATCH
    movl $RT_FILEBUF_SIZE, %edi
    call malloc@PLT
    testq %rax, %rax
    jz 2f                           # no memory: OUT OF ROOM
    movq %rax, OR_BUF(%rbx)
    movq $RT_FILEBUF_SIZE, OR_CAP(%rbx)
1:
    movq $0, OR_COL(%rbx)           # col = out = 0
    movq $0, OR_OUT(%rbx)
    movq $0, OR_FILL(%rbx)          # buffer empty
    movl %r12d, OR_FD(%rbx)
    movl $0, OR_FAILED(%rbx)        # a new file: nothing failed
    popq %r12
    popq %rbx
    popq %rbp
    ret
2:
    movl %r12d, %edi
    call close@PLT                  # the new file's fd is not leaked
    movl $ERR_OUT_OF_ROOM, %edi
    jmp bsk_err
    .size bsk_rt_out_start, . - bsk_rt_out_start

# ---------------------------------------------------------------------
# bsk_rt_out_discard -- drop file k's unwritten output (SCRATCH of a
#   file in write mode: the file is emptied anyway, LANGUAGE.md 7.22).
#   Inputs  : %edi = k   Outputs : none   Clobbers: %rax %rcx
#   Callee-saved used: none   Frame: none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_rt_out_discard
    .hidden bsk_rt_out_discard
    .type bsk_rt_out_discard, @function
    .p2align 4
bsk_rt_out_discard:
    RT_PRINT_FREC
    movq $0, OR_FILL(%rax)          # nothing is written
    ret
    .size bsk_rt_out_discard, . - bsk_rt_out_discard

# ---------------------------------------------------------------------
# bsk_rt_out_finish -- finish file k's output (RESTORE #k, termination;
#   LANGUAGE.md 7.21, 7.23, 10).
#   Purpose : a file whose "failed" flag is set is skipped (status 0).
#             Otherwise: if its col != 0 an LF is added to the buffer
#             (col = out = 0), then the buffered bytes are written.
#             A failed write: the flag is set, the buffer emptied,
#             output marked lost; then CAN'T WRITE FILE if %esi = 1,
#             else status 1 is returned.
#   Inputs  : %edi = k (a file in write mode), %esi = 1 to raise the
#             error on failure, 0 to report it
#   Outputs : %eax = 1 if the write failed (only with %esi = 0), else 0
#   Errors  : CAN'T WRITE FILE (with %esi = 1)
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = record, %r12 = raise flag, %rbp = frame
#             pointer
#   Frame   : 24 bytes (%rbp, %rbx, %r12)
# ---------------------------------------------------------------------
    .globl bsk_rt_out_finish
    .hidden bsk_rt_out_finish
    .type bsk_rt_out_finish, @function
    .p2align 4
bsk_rt_out_finish:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12                      # 3 pushes: %rsp = 0 (mod 16)
    movl %esi, %r12d
    RT_PRINT_FREC
    movq %rax, %rbx
    xorl %eax, %eax
    cmpl $0, OR_FAILED(%rbx)
    jne 2f                          # flagged: skipped by every flush
    cmpq $0, OR_COL(%rbx)
    je 1f                           # at column 0: no pending line
    # The pending newline. The buffer is never full at rest (the append
    # routine writes it as soon as it fills), so the LF fits; a buffer
    # it fills is written by the drain below in one piece.
    movq OR_FILL(%rbx), %rax
    movq OR_BUF(%rbx), %rcx
    movb $RT_CH_LF, (%rcx,%rax)
    addq $1, %rax
    movq %rax, OR_FILL(%rbx)
    movq $0, OR_COL(%rbx)           # col = out = 0
    movq $0, OR_OUT(%rbx)
1:
    movq %rbx, %rdi
    call .Lrt_print_drain           # %eax = 1 if the write failed
    testl %eax, %eax
    jz 2f
    testl %r12d, %r12d
    jnz .Lrt_print_cantwrite        # RESTORE #: CAN'T WRITE FILE
2:
    popq %r12
    popq %rbx
    popq %rbp
    ret
    .size bsk_rt_out_finish, . - bsk_rt_out_finish

# ---------------------------------------------------------------------
# State:
#   .Lrt_print_recs    RT_PRINT_NRECS output records (OR_*): record 0 is
#                      stdout (static buffer, fd 1), records 1 ..
#                      LIM_FILES the files (zero until their first
#                      SCRATCH)
#   .Lrt_print_errrec  standard error's output record (fd 2)
#   .Lrt_print_buf     RT_OUTBUF_SIZE bytes of stdout buffer
#   .Lrt_print_errbuf  RT_OUTBUF_SIZE bytes of standard-error buffer
# ---------------------------------------------------------------------
    .data
    .p2align 3
.Lrt_print_recs:
    .quad 0                         # OR_COL
    .quad 0                         # OR_OUT
    .quad 0                         # OR_FILL
    .quad .Lrt_print_buf            # OR_BUF
    .quad RT_OUTBUF_SIZE            # OR_CAP
    .long 1                         # OR_FD: stdout
    .long 0                         # OR_FAILED: not broken
    .zero OR_SIZE * LIM_FILES       # files 1 .. LIM_FILES
.Lrt_print_errrec:                  # standard error (PRINT #-1)
    .quad 0                         # OR_COL
    .quad 0                         # OR_OUT
    .quad 0                         # OR_FILL: empty between entry points
    .quad .Lrt_print_errbuf         # OR_BUF
    .quad RT_OUTBUF_SIZE            # OR_CAP
    .long 2                         # OR_FD: standard error
    .long 0                         # OR_FAILED: never set (failures ignored)

    .bss
    .p2align 4
.Lrt_print_buf:
    .zero RT_OUTBUF_SIZE
    .p2align 4
.Lrt_print_errbuf:
    .zero RT_OUTBUF_SIZE

    .section .note.GNU-stack,"",@progbits
