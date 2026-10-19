# =====================================================================
# src/runtime_x86_64_linux/rt_print.s -- PRINT column logic and
# buffered stdout.
#
# Defines (global, runtime.inc):
#   bsk_print_num bsk_print_str bsk_print_comma bsk_print_semi
#   bsk_print_nl
# Defines (private to the runtime, .globl + .hidden):
#   bsk_rt_finish_output    pending-line newline + flush (END / errors);
#                           reports whether stdout broke
#   bsk_rt_write_all        write(2) loop handling short writes / EINTR
#
# Column model (LANGUAGE.md section 8): `col` is the logical column,
# `out` the number of characters physically written on this line.
# Spaces are lazy: a space only advances `col`; before any other
# character, col - out spaces are written. Hence no trailing blanks.
# Output goes through a RT_OUTBUF_SIZE-byte buffer, flushed when full
# and at termination. No stdio is used.
#
# Broken stdout (LANGUAGE.md section 10): if write(2) to fd 1 fails with
# an error other than EINTR, or writes 0 bytes, stdout is marked broken;
# all further output is discarded and bsk_rt_finish_output reports it,
# so END / STOP / OUT OF DATA exit with status 1 instead of 0.
# =====================================================================
.include "baysick.inc"

.equ RT_EINTR, 4                    # <errno.h> EINTR on Linux
.equ RT_NUMBUF, 48                  # stack buffer for one number field
                                    # (longest field: "-1.23457E-308 " = 14)
.equ RT_CH_LF, 10                   # '\n'
.equ RT_CH_SPACE, 32                # ' '

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
# .Lrt_print_flush -- write the buffered bytes to fd 1, empty the buffer.
#   Purpose : once stdout is broken (.Lrt_print_broken != 0) the bytes
#             are discarded; a failed write marks stdout broken.
#   Inputs  : none
#   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbp = frame pointer
#   Frame   : 8 bytes (saved %rbp)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_print_flush:
    pushq %rbp                      # aligns %rsp for the call below
    movq %rsp, %rbp
    movq .Lrt_print_fill(%rip), %rdx    # number of buffered bytes
    testq %rdx, %rdx
    jz 1f                               # nothing to write
    movq $0, .Lrt_print_fill(%rip)      # buffer is empty afterwards
    cmpl $0, .Lrt_print_broken(%rip)
    jne 1f                              # stdout broken: discard
    leaq .Lrt_print_buf(%rip), %rsi
    movl $1, %edi                       # stdout
    call bsk_rt_write_all
    testl %eax, %eax
    jz 1f                               # written completely
    movl $1, .Lrt_print_broken(%rip)    # write failed: stdout broken
1:
    popq %rbp
    ret

# ---------------------------------------------------------------------
# .Lrt_print_putc -- append one byte to the stdout buffer.
#   Inputs  : %edi = byte (low 8 bits)
#   Outputs : none
#   Clobbers: all caller-saved registers (may flush via libc write)
#   Callee-saved used: none
#   Frame   : none (leaf, except for a tail jump to .Lrt_print_flush,
#             which then sees the caller's alignment like a call would)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_print_putc:
    movq .Lrt_print_fill(%rip), %rax
    leaq .Lrt_print_buf(%rip), %rcx
    movb %dil, (%rcx,%rax)              # buf[fill] = byte
    addq $1, %rax
    movq %rax, .Lrt_print_fill(%rip)
    cmpq $RT_OUTBUF_SIZE, %rax
    jae .Lrt_print_flush                # full: flush (tail call)
    ret

# ---------------------------------------------------------------------
# .Lrt_print_newline -- the "newline" action: write LF, col = out = 0.
#   Inputs  : none
#   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbp = frame pointer
#   Frame   : 8 bytes (saved %rbp)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_print_newline:
    pushq %rbp
    movq %rsp, %rbp
    movl $RT_CH_LF, %edi
    call .Lrt_print_putc
    movq $0, .Lrt_print_col(%rip)       # col = 0
    movq $0, .Lrt_print_out(%rip)       # out = 0
    popq %rbp
    ret

# ---------------------------------------------------------------------
# .Lrt_print_emit -- the "emit(c)" action of LANGUAGE.md section 8.
#   Purpose : a space only advances col; any other byte is preceded by
#             col - out real spaces, then written; col += 1; out = col.
#   Inputs  : %edi = byte (low 8 bits)
#   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = the byte, %r12 = spaces still to write,
#             %rbp = frame pointer
#   Frame   : 24 bytes (%rbp, %rbx, %r12)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_print_emit:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12                      # 3 pushes: %rsp = 0 (mod 16)
    movzbl %dil, %ebx               # the byte
    cmpl $RT_CH_SPACE, %ebx
    jne .Lrt_print_emit_real
    addq $1, .Lrt_print_col(%rip)   # lazy space: col += 1 only
    jmp .Lrt_print_emit_done
.Lrt_print_emit_real:
    movq .Lrt_print_col(%rip), %r12
    subq .Lrt_print_out(%rip), %r12 # pending spaces = col - out
.Lrt_print_emit_pad:
    testq %r12, %r12
    jz .Lrt_print_emit_char
    movl $RT_CH_SPACE, %edi
    call .Lrt_print_putc
    subq $1, %r12
    jmp .Lrt_print_emit_pad
.Lrt_print_emit_char:
    movl %ebx, %edi
    call .Lrt_print_putc            # the byte itself
    movq .Lrt_print_col(%rip), %rax
    addq $1, %rax                   # col += 1
    movq %rax, .Lrt_print_col(%rip)
    movq %rax, .Lrt_print_out(%rip) # out = col
.Lrt_print_emit_done:
    popq %r12
    popq %rbx
    popq %rbp
    ret

# ---------------------------------------------------------------------
# bsk_print_str -- PRINT a string item (label).
#   Purpose : emit every byte; never truncated or wrapped.
#   Inputs  : %rdi = pointer to the bytes, %rsi = length (may be 0)
#   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = cursor, %r12 = end pointer,
#             %rbp = frame pointer
#   Frame   : 24 bytes (%rbp, %rbx, %r12)
# ---------------------------------------------------------------------
    .globl bsk_print_str
    .type bsk_print_str, @function
    .p2align 4
bsk_print_str:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12                      # 3 pushes: %rsp = 0 (mod 16)
    movq %rdi, %rbx                 # cursor
    leaq (%rdi,%rsi), %r12          # end
.Lrt_print_str_loop:
    cmpq %r12, %rbx
    jae .Lrt_print_str_done
    movzbl (%rbx), %edi             # next byte
    addq $1, %rbx
    call .Lrt_print_emit
    jmp .Lrt_print_str_loop
.Lrt_print_str_done:
    popq %r12
    popq %rbx
    popq %rbp
    ret
    .size bsk_print_str, . - bsk_print_str

# ---------------------------------------------------------------------
# bsk_print_num -- PRINT a number item.
#   Purpose : format the field F (LANGUAGE.md section 9); if fewer than
#             PRINT_MIN_ROOM columns remain before PRINT_LINE_WIDTH,
#             newline first; then emit every character of F.
#   Inputs  : %xmm0 = value (finite)
#   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = cursor in the field, %r12 = end of field,
#             %rbp = frame pointer
#   Frame   : 24 bytes (%rbp, %rbx, %r12) + RT_NUMBUF field buffer at
#             (%rsp)
# ---------------------------------------------------------------------
    .globl bsk_print_num
    .type bsk_print_num, @function
    .p2align 4
bsk_print_num:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    subq $RT_NUMBUF, %rsp           # field buffer; %rsp = 0 (mod 16)
    movq %rsp, %rdi
    call bsk_rt_fmtnum              # %rax = field length
    movq %rsp, %rbx                 # cursor
    leaq (%rsp,%rax), %r12          # end of field
    # Room check: newline if 75 - col < 12, i.e. col > 63 (col may
    # exceed 75 after a long label; the unsigned test covers that).
    cmpq $(PRINT_LINE_WIDTH - PRINT_MIN_ROOM), .Lrt_print_col(%rip)
    jbe .Lrt_print_num_loop
    call .Lrt_print_newline
.Lrt_print_num_loop:
    cmpq %r12, %rbx
    jae .Lrt_print_num_done
    movzbl (%rbx), %edi             # next character of the field
    addq $1, %rbx
    call .Lrt_print_emit
    jmp .Lrt_print_num_loop
.Lrt_print_num_done:
    addq $RT_NUMBUF, %rsp
    popq %r12
    popq %rbx
    popq %rbp
    ret
    .size bsk_print_num, . - bsk_print_num

# ---------------------------------------------------------------------
# bsk_print_comma -- PRINT ',' : next zone strictly to the right.
#   Purpose : col = (col / 15 + 1) * 15; newline if col >= 75.
#   Inputs  : none
#   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbp = frame pointer
#   Frame   : 8 bytes (saved %rbp)
# ---------------------------------------------------------------------
    .globl bsk_print_comma
    .type bsk_print_comma, @function
    .p2align 4
bsk_print_comma:
    pushq %rbp
    movq %rsp, %rbp
    movq .Lrt_print_col(%rip), %rax
    movl $PRINT_ZONE_WIDTH, %ecx
    xorl %edx, %edx
    divq %rcx                       # %rax = current zone index
    addq $1, %rax                   # next zone
    imulq %rcx, %rax                # its first column
    movq %rax, .Lrt_print_col(%rip)
    cmpq $PRINT_LINE_WIDTH, %rax
    jb 1f                           # still on this line
    call .Lrt_print_newline
1:
    popq %rbp
    ret
    .size bsk_print_comma, . - bsk_print_comma

# ---------------------------------------------------------------------
# bsk_print_semi -- PRINT ';' after a number: next multiple of 3
#   strictly to the right; no newline is forced.
#   Inputs  : none
#   Outputs : none
#   Clobbers: %rax, %rcx, %rdx
#   Callee-saved used: none
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_print_semi
    .type bsk_print_semi, @function
    .p2align 4
bsk_print_semi:
    movq .Lrt_print_col(%rip), %rax
    movl $PRINT_PACK_WIDTH, %ecx
    xorl %edx, %edx
    divq %rcx                       # floor(col / 3)
    addq $1, %rax
    imulq %rcx, %rax                # next multiple of 3
    movq %rax, .Lrt_print_col(%rip)
    ret
    .size bsk_print_semi, . - bsk_print_semi

# ---------------------------------------------------------------------
# bsk_print_nl -- end of a PRINT without a trailing separator.
#   Inputs  : none
#   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: none
#   Frame   : none (tail jump; .Lrt_print_newline sees our alignment)
# ---------------------------------------------------------------------
    .globl bsk_print_nl
    .type bsk_print_nl, @function
    .p2align 4
bsk_print_nl:
    jmp .Lrt_print_newline
    .size bsk_print_nl, . - bsk_print_nl

# ---------------------------------------------------------------------
# bsk_rt_finish_output -- termination step for END, STOP, OUT OF DATA
#   and every run-time error: newline if col != 0, then flush stdout.
#   Inputs  : none
#   Outputs : %eax = 1 if stdout is broken (some output was lost; the
#             caller exits with status 1), else 0
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbp = frame pointer
#   Frame   : 8 bytes (saved %rbp)
# ---------------------------------------------------------------------
    .globl bsk_rt_finish_output
    .hidden bsk_rt_finish_output
    .type bsk_rt_finish_output, @function
    .p2align 4
bsk_rt_finish_output:
    pushq %rbp
    movq %rsp, %rbp
    cmpq $0, .Lrt_print_col(%rip)
    je 1f                           # at column 0: no pending line
    call .Lrt_print_newline
1:
    call .Lrt_print_flush
    movl .Lrt_print_broken(%rip), %eax  # 0 = ok, 1 = output lost
    popq %rbp
    ret
    .size bsk_rt_finish_output, . - bsk_rt_finish_output

# ---------------------------------------------------------------------
# State (file-local, zero-initialised):
#   .Lrt_print_col     u64 logical column
#   .Lrt_print_out     u64 characters physically written on this line
#   .Lrt_print_fill    u64 bytes in the stdout buffer
#   .Lrt_print_buf     RT_OUTBUF_SIZE bytes of stdout buffer
#   .Lrt_print_broken  u32 1 once a write to stdout failed, else 0
# ---------------------------------------------------------------------
    .bss
    .p2align 3
.Lrt_print_col:
    .zero 8
.Lrt_print_out:
    .zero 8
.Lrt_print_fill:
    .zero 8
    .p2align 4
.Lrt_print_buf:
    .zero RT_OUTBUF_SIZE
    .p2align 2
.Lrt_print_broken:
    .zero 4

    .section .note.GNU-stack,"",@progbits
