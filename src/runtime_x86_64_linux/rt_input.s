# =====================================================================
# src/runtime_x86_64_linux/rt_input.s -- INPUT, INPUT #, MAT INPUT, NUM
# and the line readers of standard input and the files (LANGUAGE.md
# 7.14.8, 7.15, 7.21, 7.25, 7.26, 10; DESIGN.md 6.7, 6.8).
#
# Defines (global, runtime.inc):
#   bsk_input_begin bsk_input_num bsk_input_str bsk_input_str_el
#   bsk_input_end
#   bsk_mat_input bsk_smat_input bsk_num
# Defines (private to the runtime, .globl + .hidden):
#   bsk_rt_numtext     validate and convert a numeric field text (VAL)
#   bsk_rt_in_attach   file k's reader starts on an fd opened for reading
#   bsk_rt_in_detach   empty file k's reader (RESTORE #, SCRATCH #)
#   bsk_rt_in_ateof    IF END #k: is the reader at its end?
#   bsk_rt_in_linput   LINPUT: the next unread line of the selected reader
# Uses (private): bsk_rt_flush bsk_rt_print_prompt bsk_rt_print_linedone
# bsk_rt_write_all bsk_rt_err_newline (rt_print.s), bsk_rt_str_assign
# (rt_str.s), bsk_rt_fsel and bsk_rt_file_ropen (rt_files.s); bsk_saref1
# (rt_array.s).
#
# Readers. Standard input (reader 0) and each file k (reader k, 1 ..
# LIM_FILES) have one reader record (RD_* below): fd, a chunk buffer with
# its read position and fill count, the line buffer, the current line's
# length, the field cursor and "a field is left". Every reader is read
# with read(fd, chunk, RT_INBUF_SIZE) only when it needs a byte and holds
# no unread byte (the chunk rule, LANGUAGE.md 7.21), EINTR retried; any
# other error or 0 bytes is the end of that reader for this request.
# The end is not remembered: the next request that needs a byte reads
# again, so a file read through another number sees the bytes written
# to it since (LANGUAGE.md 7.21). Reader 0 uses static buffers; a file reader's buffers are
# malloc'd when the file is first opened for reading (bsk_rt_in_attach)
# and reused after RESTORE #.
#
# Lines: the bytes up to LF; one CR immediately before the LF is
# removed; a non-empty last line without LF counts. A line longer than
# LIM_INPUT_LINE bytes (after the CR removal) -> INPUT LINE TOO LONG; at
# most LIM_INPUT_LINE + 1 bytes (a maximal line plus its CR) are ever
# stored. isatty(0) is called once, at the first use of standard input.
#
# Every input entry point first reads the pending file selection
# (bsk_rt_fsel) and resets it (DESIGN.md 6.8): none -> reader 0 with the
# INPUT dialogue (on a terminal the prompt; the three diagnostics; END
# OF INPUT); file 0 or k -> that reader with the INPUT # rules (no prompt,
# no diagnostics; END OF FILE, INCORRECT FORMAT IN FILE; on a terminal
# stdout is flushed before each line of file 0). The entry point stores
# the reader in .Lrt_in_rd and the rules in .Lrt_in_fmode, which
# parameterise the one line-assembly and field-scanning code below.
#
# Fields. The current line is scanned lazily from a cursor: a field ends
# at the next comma outside quotes (every '"' toggles the quote state);
# an empty or all-blank line has no field. Numeric field: after removing
# every blank (0x20) it must be [+|-] mantissa [E [+|-] digits] with at
# most 9 mantissa digits and 1-2 exponent digits ('e' accepted); the
# blank-free text goes to strtod. String field: after its leading blanks
# either '"' bytes '"' followed only by blanks (the value is the bytes
# between the quotes), or unquoted text without '"' (and, in MAT INPUT,
# without '&'): the value is the field without its leading blanks.
#
# The three diagnostics (BSK_EMIT_INPUT_MSGS, errors.inc) are written
# with: flush stdout, end standard error's pending line
# (bsk_rt_err_newline), then write(2, msg, len) (failures ignored).
# A selection of standard error (FILE_NUM_STDERR) is INVALID FILE
# NUMBER for every input entry point and for LINPUT (DESIGN.md 6.10).
# =====================================================================
.include "baysick.inc"

.equ RT_EINTR, 4                    # <errno.h> EINTR on Linux
.equ RT_CH_LF, 10                   # '\n'
.equ RT_CH_CR, 13                   # '\r'
.equ RT_CH_SPACE, 32                # ' '
.equ RT_CH_QUOTE, 34                # '"'
.equ RT_CH_AMP, 38                  # '&'
.equ RT_CH_PLUS, 43                 # '+'
.equ RT_CH_COMMA, 44                # ','
.equ RT_CH_MINUS, 45                # '-'
.equ RT_CH_DOT, 46                  # '.'
.equ RT_CH_0, 48                    # '0'
.equ RT_CH_UE, 69                   # 'E'
.equ RT_CH_LE, 101                  # 'e'
.equ RT_IN_LINEBUF, LIM_INPUT_LINE + 1  # a maximal line plus its CR
.equ RT_IN_FLINEBUF, LIM_INPUT_LINE + 16 # a file reader's line buffer (DESIGN.md 6.8)
.equ RT_IN_NUMMAX, 16               # longest valid numeric field without
                                    # blanks: sign 9 digits . E sign 2 = 15
.equ RT_IN_GROW_MIN, 4096           # first size of a MAT INPUT buffer

# Reader record (runtime-private, this file only).
.equ RD_FD,     0                   # u32 file descriptor
.equ RD_RSV,    4                   # u32 unused (alignment)
.equ RD_CHUNK,  8                   # ptr chunk buffer (RT_INBUF_SIZE bytes)
.equ RD_POS,    16                  # u64 next unread byte of the chunk
.equ RD_FILL,   24                  # u64 bytes in the chunk
.equ RD_LINE,   32                  # ptr line buffer
.equ RD_LEN,    40                  # u64 length of the current line
.equ RD_CUR,    48                  # u64 field cursor (offset in the line)
.equ RD_MORE,   56                  # u32 1 if a field is left on the line
.equ RD_RSV2,   60                  # u32 unused (pads the record to 64 bytes)
.equ RD_SIZE,   64
.if RD_SIZE - 64
    .error "RT_IN_RDK multiplies by RD_SIZE with a shift by 6"
.endif

# Growable buffer record (MAT INPUT text and values): ptr, capacity.
.equ RT_IN_GB_PTR, 0
.equ RT_IN_GB_CAP, 8

# Frame of .Lrt_in_mat (offsets from %rsp)
.equ RT_IN_M_BASE, 0                # text offset of the current line
.equ RT_IN_M_TMP,  8                # value offset / scratch
.equ RT_IN_M_TMPLEN, 16             # string length, the second word after RT_IN_M_TMP
.equ RT_IN_M_FRAME, 24

# RT_IN_RDK: %rax = reader record k (%edi = k, 0 .. LIM_FILES).
# Clobbers %rax, %rcx.
.macro RT_IN_RDK
    movl %edi, %eax
    shlq $6, %rax                   # k * RD_SIZE (RD_SIZE = 64)
    leaq .Lrt_in_readers(%rip), %rcx
    addq %rcx, %rax
.endm

    .text

# ---------------------------------------------------------------------
# .Lrt_in_fillbuf -- refill a reader's chunk buffer.
#   Purpose : read(fd, chunk, RT_INBUF_SIZE), retried on EINTR; any other
#             error counts as the end (0 bytes).
#   Inputs  : %rdi = reader record
#   Outputs : %rax = bytes now in the chunk (0 = end); RD_POS = 0,
#             RD_FILL = %rax
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = reader, %rbp = frame pointer
#   Frame   : 24 bytes (%rbp, %rbx + 8 bytes alignment pad)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_in_fillbuf:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    subq $8, %rsp                   # %rsp = 0 (mod 16)
    movq %rdi, %rbx
1:
    movl RD_FD(%rbx), %edi
    movq RD_CHUNK(%rbx), %rsi
    movl $RT_INBUF_SIZE, %edx
    call read@PLT                   # bytes read, 0 at end, -1 on error
    testq %rax, %rax
    jns 2f
    call __errno_location@PLT
    cmpl $RT_EINTR, (%rax)
    je 1b                           # interrupted: read again
    xorl %eax, %eax                 # real error: the end
2:
    movq %rax, RD_FILL(%rbx)
    movq $0, RD_POS(%rbx)
    addq $8, %rsp
    popq %rbx
    popq %rbp
    ret

# ---------------------------------------------------------------------
# .Lrt_in_ttycheck -- isatty(0), asked once per run (DESIGN.md 6.7).
#   Inputs  : none
#   Outputs : %eax = 1 if standard input is a terminal, else 0
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbp = frame pointer
#   Frame   : 8 bytes (saved %rbp)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_in_ttycheck:
    pushq %rbp
    movq %rsp, %rbp
    cmpl $0, .Lrt_in_ttyknown(%rip)
    jne 1f
    xorl %edi, %edi
    call isatty@PLT                 # once per run
    xorl %ecx, %ecx
    testl %eax, %eax
    setne %cl
    movl %ecx, .Lrt_in_tty(%rip)
    movl $1, .Lrt_in_ttyknown(%rip)
1:
    movl .Lrt_in_tty(%rip), %eax
    popq %rbp
    ret

# ---------------------------------------------------------------------
# .Lrt_in_readline -- one line request on the current reader
#   (.Lrt_in_rd) with the current rules (.Lrt_in_fmode).
#   Purpose : standard input on a terminal: dialogue -> the prompt; INPUT
#             # rules -> flush stdout; after the line col = out = 0. A
#             reader at its end (a refill read returns 0 bytes with nothing
#             on the line) -> END OF INPUT (dialogue) / END OF FILE (INPUT #
#             rules). Assemble the line into RD_LINE / RD_LEN (CR before
#             LF removed; too long -> INPUT LINE TOO LONG); field cursor
#             at 0; RD_MORE = 1 unless the line is empty or blank.
#   Inputs  : none (.Lrt_in_rd, .Lrt_in_fmode)
#   Outputs : the line state of the reader
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = line buffer, %r12 = line length,
#             %r13 = chunk position, %r14 = reader, %r15 = 1 if the
#             reader is standard input on a terminal, %rbp = frame
#             pointer
#   Frame   : 56 bytes (%rbp, %rbx, %r12-%r15 + 8 bytes pad)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_in_readline:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    subq $8, %rsp                   # %rsp = 0 (mod 16)
    movq .Lrt_in_rd(%rip), %r14     # the reader
    xorl %r15d, %r15d               # not a terminal
    leaq .Lrt_in_readers(%rip), %rax
    cmpq %rax, %r14
    jne 2f                          # a file: no terminal rules
    call .Lrt_in_ttycheck
    movl %eax, %r15d
    testl %r15d, %r15d
    jz 2f
    cmpl $0, .Lrt_in_fmode(%rip)
    jne 1f
    call bsk_rt_print_prompt        # INPUT: "? " on a terminal only
    jmp 2f
1:
    call bsk_rt_flush               # INPUT #0: no prompt, but flush
2:
    movq RD_LINE(%r14), %rbx
    xorl %r12d, %r12d               # line length so far
.Lrt_in_rl_chunk:
    movq RD_POS(%r14), %r13
    cmpq RD_FILL(%r14), %r13
    jb .Lrt_in_rl_scan              # bytes left in the chunk
    movq %r14, %rdi
    call .Lrt_in_fillbuf            # needs a byte, holds none: read
    testq %rax, %rax
    jnz .Lrt_in_rl_chunk
    testq %r12, %r12
    jz .Lrt_in_eoi                  # nothing on this line: no line
    jmp .Lrt_in_rl_done             # unterminated last line counts
.Lrt_in_rl_scan:
    # Copy bytes until LF or the end of the chunk.
    movq RD_CHUNK(%r14), %rcx
    movq RD_FILL(%r14), %r8
.Lrt_in_rl_byte:
    cmpq %r8, %r13
    jae .Lrt_in_rl_more             # chunk used up, no LF yet
    movzbl (%rcx,%r13), %eax
    addq $1, %r13
    cmpl $RT_CH_LF, %eax
    je .Lrt_in_rl_lf
    cmpq $RT_IN_LINEBUF, %r12
    jae .Lrt_in_toolong             # longer than any valid line
    movb %al, (%rbx,%r12)
    addq $1, %r12
    jmp .Lrt_in_rl_byte
.Lrt_in_rl_more:
    movq %r13, RD_POS(%r14)
    jmp .Lrt_in_rl_chunk
.Lrt_in_rl_lf:
    movq %r13, RD_POS(%r14)         # the LF is consumed
    testq %r12, %r12
    jz .Lrt_in_rl_done
    cmpb $RT_CH_CR, -1(%rbx,%r12)
    jne .Lrt_in_rl_done
    subq $1, %r12                   # one CR before the LF removed
.Lrt_in_rl_done:
    cmpq $LIM_INPUT_LINE, %r12
    ja .Lrt_in_toolong
    movq %r12, RD_LEN(%r14)
    movq $0, RD_CUR(%r14)           # field cursor at the start
    call .Lrt_in_setmore
    testl %r15d, %r15d
    jz 3f
    call bsk_rt_print_linedone      # the terminal is at a new line
3:
    addq $8, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret
.Lrt_in_eoi:
    movl $ERR_END_OF_INPUT, %edi    # INPUT: exit 0 after the message
    cmpl $0, .Lrt_in_fmode(%rip)
    je 4f
    movl $ERR_END_OF_FILE, %edi     # INPUT #: a program error
4:
    jmp bsk_err
.Lrt_in_toolong:
    movl $ERR_INPUT_LINE_TOO_LONG, %edi
    jmp bsk_err

# ---------------------------------------------------------------------
# .Lrt_in_setmore -- RD_MORE = 1 if the current reader's line has a byte
#   that is not a blank (the line has fields), else 0.
#   Private convention (leaf): Inputs: .Lrt_in_rd. Clobbers %rax %rcx
#   %rdx %rsi.
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_in_setmore:
    movq .Lrt_in_rd(%rip), %rsi
    movq RD_LINE(%rsi), %rcx
    movq RD_LEN(%rsi), %rdx
    xorl %eax, %eax
1:
    cmpq %rdx, %rax
    jae 2f                          # only blanks: no field
    cmpb $RT_CH_SPACE, (%rcx,%rax)
    jne 3f
    addq $1, %rax
    jmp 1b
2:
    movl $0, RD_MORE(%rsi)
    ret
3:
    movl $1, RD_MORE(%rsi)
    ret

# ---------------------------------------------------------------------
# .Lrt_in_take -- take the next field of the current reader's line.
#   Purpose : the field runs from the cursor to the next comma outside
#             quotes (every '"' toggles the quote state) or the end of
#             the line; the cursor moves past the comma (more = 1) or to
#             the end (more = 0).
#   Private convention (leaf). Precondition: RD_MORE = 1.
#   Outputs : %rax = field start, %rdx = field end (pointers into the
#             line buffer)
#   Clobbers: %rax %rcx %rdx %rsi %r8 %r9 %r10
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_in_take:
    movq .Lrt_in_rd(%rip), %r10
    movq RD_LINE(%r10), %rsi
    movq RD_LEN(%r10), %r8
    movq RD_CUR(%r10), %rax         # field start
    movq %rax, %rcx
    xorl %r9d, %r9d                 # inside quotes?
1:
    cmpq %r8, %rcx
    jae 4f                          # end of the line
    movzbl (%rsi,%rcx), %edx
    cmpl $RT_CH_QUOTE, %edx
    jne 2f
    xorl $1, %r9d                   # a quote toggles the state
    jmp 3f
2:
    cmpl $RT_CH_COMMA, %edx
    jne 3f
    testl %r9d, %r9d
    jz 5f                           # a comma outside quotes ends it
3:
    addq $1, %rcx
    jmp 1b
4:
    movq %r8, %rdx                  # last field of the line
    movq %r8, RD_CUR(%r10)
    movl $0, RD_MORE(%r10)
    jmp 6f
5:
    movq %rcx, %rdx                 # field ends before the comma
    addq $1, %rcx
    movq %rcx, RD_CUR(%r10)         # next field after it
    movl $1, RD_MORE(%r10)
6:
    addq %rsi, %rax                 # offsets -> pointers
    addq %rsi, %rdx
    ret

# ---------------------------------------------------------------------
# bsk_rt_numtext -- validate and convert a numeric field (INPUT,
#   INPUT #, MAT INPUT and VAL: one number syntax, LANGUAGE.md 6.1, 7.15).
#   Purpose : copy the non-blank bytes (at most RT_IN_NUMMAX; more ->
#             invalid, so nothing longer than a valid field is copied)
#             to a stack buffer, check
#             [+|-] mantissa [E|e [+|-] digits] with mantissa :=
#             digits [ "." [digits] ] | "." digits, 1..9 mantissa digits
#             and 1..2 exponent digits, then strtod the text.
#   Inputs  : %rdi = first byte, %rsi = end (one past the last byte)
#   Outputs : %eax = 1 and %xmm0 = value if valid, else %eax = 0
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbp = frame pointer
#   Frame   : 8 bytes (saved %rbp) + 32 bytes text buffer at (%rsp)
# ---------------------------------------------------------------------
    .globl bsk_rt_numtext
    .hidden bsk_rt_numtext
    .type bsk_rt_numtext, @function
    .p2align 4
bsk_rt_numtext:
    pushq %rbp
    movq %rsp, %rbp
    subq $32, %rsp                  # %rsp = 0 (mod 16); text at (%rsp)
    xorl %edx, %edx                 # bytes copied
1:
    cmpq %rsi, %rdi
    jae 2f
    movzbl (%rdi), %eax
    addq $1, %rdi
    cmpl $RT_CH_SPACE, %eax
    je 1b                           # every blank is removed
    cmpq $RT_IN_NUMMAX, %rdx
    jae .Lrt_in_nf_bad              # too long to be valid
    movb %al, (%rsp,%rdx)
    addq $1, %rdx
    jmp 1b
2:
    movb $0, (%rsp,%rdx)            # NUL for strtod
    movq %rsp, %rcx                 # p
    leaq (%rsp,%rdx), %rsi          # end
    # optional sign
    cmpq %rsi, %rcx
    jae .Lrt_in_nf_bad              # empty field
    movzbl (%rcx), %eax
    cmpl $RT_CH_PLUS, %eax
    je 3f
    cmpl $RT_CH_MINUS, %eax
    jne 4f
3:
    addq $1, %rcx
4:
    xorl %r8d, %r8d                 # mantissa digits
5:
    cmpq %rsi, %rcx                 # integer digits
    jae 7f
    movzbl (%rcx), %eax
    subl $RT_CH_0, %eax
    cmpl $9, %eax
    ja 6f
    addq $1, %rcx
    addq $1, %r8
    jmp 5b
6:
    cmpb $RT_CH_DOT, (%rcx)
    jne 7f
    addq $1, %rcx                   # the point
8:
    cmpq %rsi, %rcx                 # fraction digits
    jae 7f
    movzbl (%rcx), %eax
    subl $RT_CH_0, %eax
    cmpl $9, %eax
    ja 7f
    addq $1, %rcx
    addq $1, %r8
    jmp 8b
7:
    testq %r8, %r8
    jz .Lrt_in_nf_bad               # no digit in the mantissa
    cmpq $LIM_NUM_DIGITS, %r8
    ja .Lrt_in_nf_bad               # more than 9 digits
    cmpq %rsi, %rcx
    jae .Lrt_in_nf_ok               # no exponent
    movzbl (%rcx), %eax
    cmpl $RT_CH_UE, %eax
    je 9f
    cmpl $RT_CH_LE, %eax
    jne .Lrt_in_nf_bad              # anything else after the mantissa
9:
    addq $1, %rcx
    cmpq %rsi, %rcx
    jae .Lrt_in_nf_bad              # "E" alone
    movzbl (%rcx), %eax
    cmpl $RT_CH_PLUS, %eax
    je 10f
    cmpl $RT_CH_MINUS, %eax
    jne 11f
10:
    addq $1, %rcx
11:
    xorl %r9d, %r9d                 # exponent digits
12:
    cmpq %rsi, %rcx
    jae 13f
    movzbl (%rcx), %eax
    subl $RT_CH_0, %eax
    cmpl $9, %eax
    ja .Lrt_in_nf_bad               # a non-digit in the exponent
    addq $1, %rcx
    addq $1, %r9
    jmp 12b
13:
    testq %r9, %r9
    jz .Lrt_in_nf_bad               # no exponent digit
    cmpq $LIM_EXP_DIGITS, %r9
    ja .Lrt_in_nf_bad               # more than 2 exponent digits
.Lrt_in_nf_ok:
    movq %rsp, %rdi
    xorl %esi, %esi                 # endptr = NULL
    call strtod@PLT                 # nearest double (round-half-even)
    movl $1, %eax
    jmp 14f
.Lrt_in_nf_bad:
    xorl %eax, %eax
14:
    movq %rbp, %rsp
    popq %rbp
    ret
    .size bsk_rt_numtext, . - bsk_rt_numtext

# ---------------------------------------------------------------------
# .Lrt_in_strfield -- validate a string field and locate its value.
#   Purpose : skip leading blanks; quoted: '"', bytes but '"', '"', then
#             only blanks; value = the bytes between the quotes.
#             Unquoted: no '"' (and no '&' when %edx = 1, MAT INPUT);
#             value = the rest of the field.
#   Private convention (leaf):
#   Inputs  : %rdi = field start, %rsi = field end (pointers),
#             %edx = 1 to reject '&' in an unquoted field, else 0
#   Outputs : %eax = 1 valid / 0 invalid; when valid %rcx = value start
#             (pointer), %rdx = value length
#   Clobbers: %rax %rcx %rdx %rdi %r9 %r10
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_in_strfield:
    movl %edx, %r10d                # '&' rule
1:
    cmpq %rsi, %rdi
    jae 5f                          # blank (or empty) field: unquoted ""
    cmpb $RT_CH_SPACE, (%rdi)
    jne 2f
    addq $1, %rdi                   # leading blanks are not part of it
    jmp 1b
2:
    cmpb $RT_CH_QUOTE, (%rdi)
    jne 5f
    # quoted: find the closing quote
    leaq 1(%rdi), %rcx              # value start
    movq %rcx, %r9
3:
    cmpq %rsi, %r9
    jae .Lrt_in_sf_bad              # no closing quote
    cmpb $RT_CH_QUOTE, (%r9)
    je 4f
    addq $1, %r9
    jmp 3b
4:
    movq %r9, %rdx
    subq %rcx, %rdx                 # value length
    addq $1, %r9                    # after the closing quote ...
41:
    cmpq %rsi, %r9
    jae .Lrt_in_sf_ok
    cmpb $RT_CH_SPACE, (%r9)
    jne .Lrt_in_sf_bad              # ... only blanks may follow
    addq $1, %r9
    jmp 41b
5:
    # unquoted: the value is the rest of the field
    movq %rdi, %rcx
    movq %rsi, %rdx
    subq %rdi, %rdx
    movq %rdi, %r9
6:
    cmpq %rsi, %r9
    jae .Lrt_in_sf_ok
    movzbl (%r9), %eax
    cmpl $RT_CH_QUOTE, %eax
    je .Lrt_in_sf_bad               # a quote inside an unquoted string
    cmpl $RT_CH_AMP, %eax
    jne 7f
    testl %r10d, %r10d
    jnz .Lrt_in_sf_bad              # '&' is not allowed in MAT INPUT
7:
    addq $1, %r9
    jmp 6b
.Lrt_in_sf_ok:
    movl $1, %eax
    ret
.Lrt_in_sf_bad:
    xorl %eax, %eax
    ret

# ---------------------------------------------------------------------
# .Lrt_in_diag -- write an INPUT diagnostic: flush stdout, end standard
#   error's pending line, then write(2, msg, len); failures are ignored.
#   Inputs  : %rdi = message (with its LF), %rsi = length
#   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = message, %r12 = length, %rbp = frame
#             pointer
#   Frame   : 24 bytes (%rbp, %rbx, %r12)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_in_diag:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12                      # 3 pushes: %rsp = 0 (mod 16)
    movq %rdi, %rbx
    movq %rsi, %r12
    call bsk_rt_flush               # stdout first: keep the order
    call bsk_rt_err_newline         # never glued to a partial stderr line
    movl $2, %edi
    movq %rbx, %rsi
    movq %r12, %rdx
    call bsk_rt_write_all           # result ignored
    popq %r12
    popq %rbx
    popq %rbp
    ret

# RT_IN_DIAG which: write the diagnostic .Lrt_in_msg_<which>.
.macro RT_IN_DIAG which
    leaq .Lrt_in_msg_\which(%rip), %rdi
    movl $(.Lrt_in_msg_\which\()_end - .Lrt_in_msg_\which), %esi
    call .Lrt_in_diag
.endm

# ---------------------------------------------------------------------
# .Lrt_in_select -- the reader and rules of an input entry point.
#   Purpose : read the pending file selection (bsk_rt_fsel: 0 = none,
#             k + 1 = file k, FILE_NUM_STDERR = standard error) and reset
#             it to none, first of all (DESIGN.md 6.8). Standard error ->
#             INVALID FILE NUMBER (DESIGN.md 6.10). None: reader 0 with
#             the INPUT dialogue (fmode 0).
#             File 0: reader 0 with the INPUT # rules (fmode 1). File
#             k >= 1: bsk_rt_file_ropen (read mode, else ILLEGAL FILE
#             COMMAND; opened if necessary, CAN'T OPEN FILE), then reader
#             k with the INPUT # rules. Sets .Lrt_in_rd, .Lrt_in_fmode.
#   Inputs  : none
#   Outputs : none
#   Errors  : INVALID FILE NUMBER, ILLEGAL FILE COMMAND, CAN'T OPEN FILE,
#             OUT OF ROOM
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = k, %rbp = frame pointer
#   Frame   : 24 bytes (%rbp, %rbx + 8 bytes alignment pad)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_in_select:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    subq $8, %rsp                   # %rsp = 0 (mod 16)
    movl bsk_rt_fsel(%rip), %ebx    # pending selection
    movl $0, bsk_rt_fsel(%rip)      # reset on entry
    cmpl $FILE_NUM_STDERR, %ebx
    je .Lrt_in_stderr               # standard error is not an input
    xorl %eax, %eax
    testl %ebx, %ebx
    setnz %al                       # a selection: the INPUT # rules
    movl %eax, .Lrt_in_fmode(%rip)
    cmpl $1, %ebx
    jbe 1f                          # none or file 0: standard input
    subl $1, %ebx                   # k >= 1
    movl %ebx, %edi
    call bsk_rt_file_ropen          # mode check, open if necessary
    movl %ebx, %edi
    RT_IN_RDK                       # reader k
    jmp 2f
1:
    leaq .Lrt_in_readers(%rip), %rax    # reader 0: standard input
2:
    movq %rax, .Lrt_in_rd(%rip)
    addq $8, %rsp
    popq %rbx
    popq %rbp
    ret
.Lrt_in_stderr:
    movl $ERR_INVALID_FILE_NUMBER, %edi # INPUT #-1, LINPUT #-1
    jmp bsk_err

# ---------------------------------------------------------------------
# bsk_rt_in_linput -- the line request of LINPUT (LANGUAGE.md 15.2,
#   DESIGN.md 6.10; called by bsk_linput / bsk_linput_el, rt_ext.s).
#   Purpose : the selection as for every input entry point
#             (.Lrt_in_select: none -> standard input with the INPUT
#             dialogue's line request, prompt on a terminal, END OF
#             INPUT; file 0 or k -> the INPUT # line request, END OF
#             FILE; standard error -> INVALID FILE NUMBER); then the
#             reader's next unread line (.Lrt_in_readline: a partly
#             scanned current line is simply replaced, so its rest is
#             discarded; INPUT LINE TOO LONG). The whole line is the
#             value, and the reader has no field left afterwards
#             (RD_MORE = 0): the next line request reads the following
#             line, exactly as after bsk_input_end.
#   Inputs  : none
#   Outputs : %rax = the line's bytes (the reader's line buffer, valid
#             until its next line request), %rdx = its length
#   Errors  : those of .Lrt_in_select and .Lrt_in_readline
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbp = frame pointer
#   Frame   : 8 bytes (saved %rbp)
# ---------------------------------------------------------------------
    .globl bsk_rt_in_linput
    .hidden bsk_rt_in_linput
    .type bsk_rt_in_linput, @function
    .p2align 4
bsk_rt_in_linput:
    pushq %rbp
    movq %rsp, %rbp                 # %rsp = 0 (mod 16)
    call .Lrt_in_select             # reader and rules; resets the selection
    call .Lrt_in_readline           # the next unread line
    movq .Lrt_in_rd(%rip), %rcx
    movl $0, RD_MORE(%rcx)          # the whole line is consumed
    movq RD_LINE(%rcx), %rax        # verbatim: no field scan
    movq RD_LEN(%rcx), %rdx
    popq %rbp
    ret
    .size bsk_rt_in_linput, . - bsk_rt_in_linput

# ---------------------------------------------------------------------
# bsk_input_begin -- INPUT / INPUT #: read the statement's first line.
#   Inputs  : none   Outputs : none
#   Errors  : END OF INPUT (exit 0) / END OF FILE, INPUT LINE TOO LONG,
#             and the selection's errors (.Lrt_in_select)
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbp = frame pointer
#   Frame   : 8 bytes (saved %rbp)
# ---------------------------------------------------------------------
    .globl bsk_input_begin
    .type bsk_input_begin, @function
    .p2align 4
bsk_input_begin:
    pushq %rbp
    movq %rsp, %rbp
    call .Lrt_in_select
    call .Lrt_in_readline
    popq %rbp
    ret
    .size bsk_input_begin, . - bsk_input_begin

# ---------------------------------------------------------------------
# .Lrt_in_nextfield -- the next field of the current reader, reading
#   new lines while none is left on the current one.
#   Purpose : dialogue: NOT ENOUGH INPUT -- ADD MORE, then a new line;
#             INPUT # rules: a new line silently (none -> END OF FILE).
#   Inputs  : none (.Lrt_in_rd, .Lrt_in_fmode)
#   Outputs : %rax = field start, %rdx = field end (pointers)
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbp = frame pointer
#   Frame   : 8 bytes (saved %rbp)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_in_nextfield:
    pushq %rbp
    movq %rsp, %rbp
1:
    movq .Lrt_in_rd(%rip), %rax
    cmpl $0, RD_MORE(%rax)
    jne 3f                          # a field is left
    cmpl $0, .Lrt_in_fmode(%rip)
    jne 2f                          # INPUT #: no diagnostic
    RT_IN_DIAG more                 # nothing left on this line
2:
    call .Lrt_in_readline
    jmp 1b
3:
    call .Lrt_in_take               # %rax = start, %rdx = end
    popq %rbp
    ret

# ---------------------------------------------------------------------
# .Lrt_in_badfield -- the field just taken is not valid for its target.
#   Purpose : INPUT # rules: INCORRECT FORMAT IN FILE (no return).
#             Dialogue: INPUT DATA NOT IN CORRECT FORMAT -- RETYPE IT,
#             then a new line (the rest of this one is discarded).
#   Inputs  : none   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbp = frame pointer
#   Frame   : 8 bytes (saved %rbp)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_in_badfield:
    cmpl $0, .Lrt_in_fmode(%rip)
    jne 1f
    pushq %rbp
    movq %rsp, %rbp
    RT_IN_DIAG retype
    call .Lrt_in_readline           # the rest of the line is discarded
    popq %rbp
    ret
1:
    movl $ERR_FILE_FORMAT, %edi
    jmp bsk_err

# ---------------------------------------------------------------------
# bsk_input_num -- INPUT / INPUT #: the next field as a number.
#   Purpose : no field left -> .Lrt_in_nextfield; invalid field ->
#             .Lrt_in_badfield (dialogue: retype; INPUT #: error);
#             repeat until a valid field is found.
#   Inputs  : none
#   Outputs : %xmm0 = value
#   Errors  : END OF INPUT / END OF FILE, INPUT LINE TOO LONG, INCORRECT
#             FORMAT IN FILE, and the selection's errors
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbp = frame pointer
#   Frame   : 8 bytes (saved %rbp)
# ---------------------------------------------------------------------
    .globl bsk_input_num
    .type bsk_input_num, @function
    .p2align 4
bsk_input_num:
    pushq %rbp
    movq %rsp, %rbp
    call .Lrt_in_select
1:
    call .Lrt_in_nextfield          # %rax = start, %rdx = end
    movq %rax, %rdi
    movq %rdx, %rsi
    call bsk_rt_numtext
    testl %eax, %eax
    jnz 2f                          # valid: %xmm0 = value
    call .Lrt_in_badfield
    jmp 1b
2:
    popq %rbp
    ret
    .size bsk_input_num, . - bsk_input_num

# ---------------------------------------------------------------------
# .Lrt_in_strvalue -- the value of the next valid field for a string
#   target, with the rules of bsk_input_num.
#   Inputs  : none (the selection was made by the caller)
#   Outputs : %rsi = value bytes (inside the line buffer), %rdx = length
#   Errors  : as bsk_input_num
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbp = frame pointer
#   Frame   : 8 bytes (saved %rbp)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_in_strvalue:
    pushq %rbp
    movq %rsp, %rbp
1:
    call .Lrt_in_nextfield          # %rax = start, %rdx = end
    movq %rax, %rdi
    movq %rdx, %rsi
    xorl %edx, %edx                 # INPUT: '&' is an ordinary byte
    call .Lrt_in_strfield
    testl %eax, %eax
    jnz 2f
    call .Lrt_in_badfield
    jmp 1b
2:
    movq %rcx, %rsi                 # value bytes (%rdx = length)
    popq %rbp
    ret

# ---------------------------------------------------------------------
# bsk_input_str -- INPUT / INPUT #: the next field as a string, stored
#   into dst with bsk_str_set semantics.
#   Inputs  : %rdi = destination SD
#   Outputs : none
#   Errors  : as bsk_input_num, OUT OF ROOM
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = destination, %rbp = frame pointer
#   Frame   : 24 bytes (%rbp, %rbx + 8 bytes pad)
# ---------------------------------------------------------------------
    .globl bsk_input_str
    .type bsk_input_str, @function
    .p2align 4
bsk_input_str:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    subq $8, %rsp                   # %rsp = 0 (mod 16)
    movq %rdi, %rbx
    call .Lrt_in_select
    call .Lrt_in_strvalue           # %rsi / %rdx = the value
    movq %rbx, %rdi
    call bsk_rt_str_assign          # dst := the value
    addq $8, %rsp
    popq %rbx
    popq %rbp
    ret
    .size bsk_input_str, . - bsk_input_str

# ---------------------------------------------------------------------
# bsk_input_str_el -- INPUT / INPUT # into a string list element L$(i)
#   (the element form of `insv`, IR.md 3.2): the field is taken first,
#   with every diagnostic and retype (or file error) of bsk_input_str;
#   only when the value is assigned is the subscript checked
#   (LANGUAGE.md 7.1, 7.15, 7.25), then the element := the value.
#   Inputs  : %rdi = string-list descriptor (RTA_*), %xmm0 = subscript i
#   Outputs : none
#   Errors  : as bsk_input_num; then SUBSCRIPT ERROR (bsk_saref1); OUT OF
#             ROOM
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = descriptor, %r12 = value bytes, %r13 =
#             value length, %rbp = frame pointer
#   Frame   : 56 bytes (%rbp, %rbx, %r12, %r13 + 24 bytes: the subscript
#             at 0(%rsp)); %rsp = 0 (mod 16) at calls
# ---------------------------------------------------------------------
    .globl bsk_input_str_el
    .type bsk_input_str_el, @function
    .p2align 4
bsk_input_str_el:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    subq $24, %rsp                  # %rsp = 0 (mod 16)
    movq %rdi, %rbx
    movsd %xmm0, (%rsp)             # the subscript, kept across the field
    call .Lrt_in_select
    call .Lrt_in_strvalue           # %rsi / %rdx = the value
    movq %rsi, %r12
    movq %rdx, %r13
    movq %rbx, %rdi
    movsd (%rsp), %xmm0
    call bsk_saref1                 # %rax = &L$(i); SUBSCRIPT ERROR here
    movq %rax, %rdi
    movq %r12, %rsi
    movq %r13, %rdx
    call bsk_rt_str_assign          # element := the value
    addq $24, %rsp
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret
    .size bsk_input_str_el, . - bsk_input_str_el

# ---------------------------------------------------------------------
# bsk_input_end -- end of INPUT / INPUT #. Dialogue: fields left on the
#   line -> TOO MUCH INPUT -- EXCESS IGNORED (a diagnostic; the program
#   continues). INPUT # rules: the rest of the line is discarded
#   silently.
#   Inputs  : none   Outputs : none
#   Errors  : the selection's errors
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbp = frame pointer
#   Frame   : 8 bytes (saved %rbp)
# ---------------------------------------------------------------------
    .globl bsk_input_end
    .type bsk_input_end, @function
    .p2align 4
bsk_input_end:
    pushq %rbp
    movq %rsp, %rbp
    call .Lrt_in_select
    movq .Lrt_in_rd(%rip), %rax
    cmpl $0, .Lrt_in_fmode(%rip)
    je 1f
    movl $0, RD_MORE(%rax)          # INPUT #: the rest is discarded
    jmp 2f
1:
    cmpl $0, RD_MORE(%rax)
    je 2f
    RT_IN_DIAG excess
2:
    popq %rbp
    ret
    .size bsk_input_end, . - bsk_input_end

# ---------------------------------------------------------------------
# bsk_rt_in_attach -- file k's reader starts on a file just opened for
#   reading (rt_files.s): its buffers are malloc'd the first time
#   (RT_INBUF_SIZE chunk, RT_IN_FLINEBUF line bytes; failure -> OUT OF
#   ROOM) and reused afterwards; the reader is empty, positioned at the
#   file's first byte.
#   Inputs  : %edi = k (1 .. LIM_FILES), %esi = fd
#   Outputs : none
#   Errors  : OUT OF ROOM
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = reader, %r12 = fd, %rbp = frame pointer
#   Frame   : 24 bytes (%rbp, %rbx, %r12)
# ---------------------------------------------------------------------
    .globl bsk_rt_in_attach
    .hidden bsk_rt_in_attach
    .type bsk_rt_in_attach, @function
    .p2align 4
bsk_rt_in_attach:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12                      # 3 pushes: %rsp = 0 (mod 16)
    movl %esi, %r12d
    RT_IN_RDK
    movq %rax, %rbx
    cmpq $0, RD_CHUNK(%rbx)
    jne 1f                          # buffers of an earlier open
    movl $RT_INBUF_SIZE, %edi
    call malloc@PLT
    testq %rax, %rax
    jz 2f
    movq %rax, RD_CHUNK(%rbx)
    movl $RT_IN_FLINEBUF, %edi
    call malloc@PLT
    testq %rax, %rax
    jz 2f
    movq %rax, RD_LINE(%rbx)
1:
    movl %r12d, RD_FD(%rbx)
    movq $0, RD_POS(%rbx)           # no byte held
    movq $0, RD_FILL(%rbx)
    movq $0, RD_LEN(%rbx)           # no current line
    movq $0, RD_CUR(%rbx)
    movl $0, RD_MORE(%rbx)
    popq %r12
    popq %rbx
    popq %rbp
    ret
2:
    movl %r12d, %edi
    call close@PLT                  # the new file's fd is not leaked
    movl $ERR_OUT_OF_ROOM, %edi
    jmp bsk_err
    .size bsk_rt_in_attach, . - bsk_rt_in_attach

# ---------------------------------------------------------------------
# bsk_rt_in_detach -- empty file k's reader (RESTORE #k, SCRATCH #k):
#   its unread bytes and current line are dropped; buffers are kept.
#   Inputs  : %edi = k (1 .. LIM_FILES)   Outputs : none
#   Clobbers: %rax %rcx   Callee-saved used: none   Frame: none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_rt_in_detach
    .hidden bsk_rt_in_detach
    .type bsk_rt_in_detach, @function
    .p2align 4
bsk_rt_in_detach:
    RT_IN_RDK
    movq $0, RD_POS(%rax)
    movq $0, RD_FILL(%rax)
    movq $0, RD_LEN(%rax)
    movq $0, RD_CUR(%rax)
    movl $0, RD_MORE(%rax)
    ret
    .size bsk_rt_in_detach, . - bsk_rt_in_detach

# ---------------------------------------------------------------------
# bsk_rt_in_ateof -- IF END #k on a reader (LANGUAGE.md 7.26, DESIGN.md
#   6.8): at its end when it holds no unread byte and a refill read
#   returns 0 bytes. Standard input (k = 0): on a terminal stdout is flushed before the refill read.
#   Inputs  : %edi = k (0, or a file in read mode, opened)
#   Outputs : %eax = 1 at the end, else 0
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = reader, %r12 = k, %rbp = frame pointer
#   Frame   : 24 bytes (%rbp, %rbx, %r12)
# ---------------------------------------------------------------------
    .globl bsk_rt_in_ateof
    .hidden bsk_rt_in_ateof
    .type bsk_rt_in_ateof, @function
    .p2align 4
bsk_rt_in_ateof:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12                      # 3 pushes: %rsp = 0 (mod 16)
    movl %edi, %r12d
    RT_IN_RDK
    movq %rax, %rbx
    testl %r12d, %r12d
    jnz 1f
    call .Lrt_in_ttycheck           # the first use of stdin may be here
1:
    xorl %eax, %eax
    movq RD_POS(%rbx), %rcx
    cmpq RD_FILL(%rbx), %rcx
    jb 3f                           # an unread byte: not at the end
    testl %r12d, %r12d
    jnz 2f
    cmpl $0, .Lrt_in_tty(%rip)
    je 2f
    call bsk_rt_flush               # terminal: the user sees the output
2:
    movq %rbx, %rdi
    call .Lrt_in_fillbuf            # %rax = bytes now held
    xorl %ecx, %ecx
    testq %rax, %rax
    sete %cl
    movl %ecx, %eax                 # 0 bytes: at the end
3:
    popq %r12
    popq %rbx
    popq %rbp
    ret
    .size bsk_rt_in_ateof, . - bsk_rt_in_ateof

# ---------------------------------------------------------------------
# .Lrt_in_grow -- make a growable buffer hold at least n bytes.
#   Purpose : n > capacity: new capacity = max(n, 2 * capacity,
#             RT_IN_GROW_MIN), realloc; failure -> OUT OF ROOM.
#   Inputs  : %rdi = buffer record (RT_IN_GB_*), %rsi = n
#   Outputs : %rax = buffer pointer
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = record, %r12 = new capacity,
#             %rbp = frame pointer
#   Frame   : 24 bytes (%rbp, %rbx, %r12)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_in_grow:
    movq RT_IN_GB_PTR(%rdi), %rax
    cmpq RT_IN_GB_CAP(%rdi), %rsi
    ja 1f
    ret                             # big enough
1:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12                      # 3 pushes: %rsp = 0 (mod 16)
    movq %rdi, %rbx
    movq RT_IN_GB_CAP(%rdi), %r12
    addq %r12, %r12                 # twice the old capacity
    cmpq %rsi, %r12
    cmovb %rsi, %r12                # at least n
    movl $RT_IN_GROW_MIN, %eax
    cmpq %rax, %r12
    cmovb %rax, %r12                # at least the minimum
    movq RT_IN_GB_PTR(%rbx), %rdi   # NULL the first time
    movq %r12, %rsi
    call realloc@PLT
    testq %rax, %rax
    jz 2f
    movq %rax, RT_IN_GB_PTR(%rbx)
    movq %r12, RT_IN_GB_CAP(%rbx)
    popq %r12
    popq %rbx
    popq %rbp
    ret
2:
    movl $ERR_OUT_OF_ROOM, %edi
    jmp bsk_err

# ---------------------------------------------------------------------
# .Lrt_in_mat -- MAT INPUT of a list (LANGUAGE.md 7.14.8, transactional),
#   always from standard input with the INPUT dialogue.
#   Purpose : read a line; a line whose last non-blank byte is an '&'
#             outside quotes continues (the '&' and one comma right
#             before it, blanks ignored, are removed) on another line.
#             Every field of these lines is validated and collected
#             (numbers into .Lrt_in_mvals as doubles; strings as
#             (offset, length) pairs into the lines' text, kept in
#             .Lrt_in_mtext); a bad field anywhere -> RETYPE IT, all of
#             it discarded, start again. Then n = 0 -> NUM := 0 (list
#             unchanged); n + 1 > RTA_CAP -> DIMENSION ERROR; else
#             RTA_B1 := n, elements 1 .. n stored, NUM := n.
#   Inputs  : %rdi = list descriptor (RTA_*), %esi = 0 numeric list,
#             1 string list
#   Outputs : none
#   Errors  : END OF INPUT, INPUT LINE TOO LONG, DIMENSION ERROR,
#             OUT OF ROOM
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = descriptor, %r12 = kind, %r13 = fields
#             collected (n), %r14 = 1 once a bad field was seen,
#             %r15 = 1 if the current line continues / element index,
#             %rbp = frame pointer
#   Frame   : 48 bytes of saved registers + RT_IN_M_FRAME locals;
#             %rsp = 0 (mod 16) at calls
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_in_mat:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    subq $RT_IN_M_FRAME, %rsp       # %rsp = 0 (mod 16)
    movq %rdi, %rbx
    movl %esi, %r12d
    leaq .Lrt_in_readers(%rip), %rax
    movq %rax, .Lrt_in_rd(%rip)     # standard input ...
    movl $0, .Lrt_in_fmode(%rip)    # ... with the INPUT dialogue
.Lrt_in_mat_restart:
    xorl %r13d, %r13d               # no field collected
    xorl %r14d, %r14d               # nothing bad yet
    movq $0, .Lrt_in_mtext_len(%rip)    # text of this statement's lines
.Lrt_in_mat_line:
    call .Lrt_in_readline
    # ---- continuation: the last non-blank byte is '&' outside quotes --
    xorl %r15d, %r15d               # not continued
    leaq .Lrt_in_readers(%rip), %rax
    movq RD_LINE(%rax), %rsi
    movq RD_LEN(%rax), %rcx         # k = end of the non-blank part
1:
    testq %rcx, %rcx
    jz .Lrt_in_mat_text             # blank line: no '&'
    cmpb $RT_CH_SPACE, -1(%rsi,%rcx)
    jne 2f
    subq $1, %rcx
    jmp 1b
2:
    cmpb $RT_CH_AMP, -1(%rsi,%rcx)
    jne .Lrt_in_mat_text
    subq $1, %rcx                   # index of the '&'
    xorl %eax, %eax                 # quotes before it
    xorl %edx, %edx
3:
    cmpq %rcx, %rdx
    jae 4f
    cmpb $RT_CH_QUOTE, (%rsi,%rdx)
    jne 31f
    xorl $1, %eax
31:
    addq $1, %rdx
    jmp 3b
4:
    testl %eax, %eax
    jnz .Lrt_in_mat_text            # the '&' is inside quotes
    movl $1, %r15d                  # continued on another line
    movq %rcx, %rdx                 # new length: up to the '&' ...
5:
    testq %rcx, %rcx
    jz 6f
    cmpb $RT_CH_SPACE, -1(%rsi,%rcx)
    jne 51f
    subq $1, %rcx                   # blanks before the '&'
    jmp 5b
51:
    cmpb $RT_CH_COMMA, -1(%rsi,%rcx)
    jne 6f
    leaq -1(%rcx), %rdx             # ... or up to one comma before it
6:
    leaq .Lrt_in_readers(%rip), %rax
    movq %rdx, RD_LEN(%rax)
    call .Lrt_in_setmore            # fields of the shortened line
.Lrt_in_mat_text:
    # ---- strings: append this line to the statement's text ------------
    cmpl $0, %r12d
    je .Lrt_in_mat_fields
    movq .Lrt_in_mtext_len(%rip), %rax
    movq %rax, RT_IN_M_BASE(%rsp)   # offset of this line in the text
    leaq .Lrt_in_readers(%rip), %rcx
    addq RD_LEN(%rcx), %rax
    leaq .Lrt_in_mtext(%rip), %rdi
    movq %rax, %rsi
    call .Lrt_in_grow               # %rax = text buffer
    movq RT_IN_M_BASE(%rsp), %rdi
    addq %rax, %rdi
    leaq .Lrt_in_readers(%rip), %rcx
    movq RD_LINE(%rcx), %rsi
    movq RD_LEN(%rcx), %rdx
    addq %rdx, .Lrt_in_mtext_len(%rip)
    testq %rdx, %rdx
    jz .Lrt_in_mat_fields           # empty line: nothing to keep
    call memcpy@PLT
.Lrt_in_mat_fields:
    # ---- collect the fields of the line --------------------------------
    leaq .Lrt_in_readers(%rip), %rax
    cmpl $0, RD_MORE(%rax)
    je .Lrt_in_mat_lineend
    call .Lrt_in_take               # %rax = start, %rdx = end
    testl %r14d, %r14d
    jnz .Lrt_in_mat_fields          # already bad: just skip the rest
    movq %rax, %rdi
    movq %rdx, %rsi
    cmpl $0, %r12d
    jne .Lrt_in_mat_sfield
    call bsk_rt_numtext             # %eax valid, %xmm0 value
    testl %eax, %eax
    jz .Lrt_in_mat_bad
    movsd %xmm0, RT_IN_M_TMP(%rsp)
    leaq .Lrt_in_mvals(%rip), %rdi
    leaq 8(,%r13,8), %rsi           # room for n + 1 doubles
    call .Lrt_in_grow
    movsd RT_IN_M_TMP(%rsp), %xmm0
    movsd %xmm0, (%rax,%r13,8)
    addq $1, %r13
    jmp .Lrt_in_mat_fields
.Lrt_in_mat_sfield:
    movl $1, %edx                   # MAT INPUT: '&' not allowed unquoted
    call .Lrt_in_strfield           # %rcx = value start, %rdx = length
    testl %eax, %eax
    jz .Lrt_in_mat_bad
    leaq .Lrt_in_readers(%rip), %rax
    subq RD_LINE(%rax), %rcx        # value offset in the line ...
    addq RT_IN_M_BASE(%rsp), %rcx   # ... and in the text
    movq %rcx, RT_IN_M_TMP(%rsp)
    movq %rdx, RT_IN_M_TMPLEN(%rsp)
    leaq .Lrt_in_mvals(%rip), %rdi
    movq %r13, %rsi
    addq $1, %rsi
    shlq $4, %rsi                   # room for n + 1 (offset, length) pairs
    call .Lrt_in_grow
    movq %r13, %rcx
    shlq $4, %rcx
    movq RT_IN_M_TMP(%rsp), %rdx
    movq %rdx, (%rax,%rcx)          # offset
    movq RT_IN_M_TMPLEN(%rsp), %rdx
    movq %rdx, 8(%rax,%rcx)         # length
    addq $1, %r13
    jmp .Lrt_in_mat_fields
.Lrt_in_mat_bad:
    movl $1, %r14d                  # complain after the last line
    jmp .Lrt_in_mat_fields
.Lrt_in_mat_lineend:
    testl %r15d, %r15d
    jnz .Lrt_in_mat_line            # '&': the input goes on
    testl %r14d, %r14d
    jz .Lrt_in_mat_commit
    RT_IN_DIAG retype               # discard everything, start again
    jmp .Lrt_in_mat_restart

    # ---- every field is good: n = 0, too many, or store ----------------
.Lrt_in_mat_commit:
    testq %r13, %r13
    jz .Lrt_in_mat_num              # nothing typed: list unchanged
    leaq 1(%r13), %rax
    movl RTA_CAP(%rbx), %ecx
    cmpq %rcx, %rax
    ja .Lrt_in_mat_dimerr           # n + 1 elements do not fit
    movl %r13d, RTA_B1(%rbx)        # current bound := n
    movq .Lrt_in_mvals(%rip), %r14  # collected values / pairs
    movl $1, %r15d                  # element index
    cmpl $0, %r12d
    jne .Lrt_in_mat_sstore
    movq RTA_DATA(%rbx), %rdi
1:
    movsd -8(%r14,%r15,8), %xmm0    # value i - 1 ...
    movsd %xmm0, (%rdi,%r15,8)      # ... into element i
    addq $1, %r15
    cmpq %r13, %r15
    jbe 1b
    jmp .Lrt_in_mat_num
.Lrt_in_mat_sstore:
    movq %r15, %rdi
    imulq $SD_SIZE, %rdi, %rdi
    addq RTA_DATA(%rbx), %rdi       # element i
    movq %r15, %rax
    shlq $4, %rax
    movq -16(%r14,%rax), %rsi       # its text offset
    addq .Lrt_in_mtext(%rip), %rsi  # its bytes
    movq -8(%r14,%rax), %rdx        # its length
    call bsk_rt_str_assign
    addq $1, %r15
    cmpq %r13, %r15
    jbe .Lrt_in_mat_sstore
.Lrt_in_mat_num:
    cvtsi2sdq %r13, %xmm0
    movsd %xmm0, .Lrt_in_numval(%rip)   # NUM := n
    addq $RT_IN_M_FRAME, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret
.Lrt_in_mat_dimerr:
    movl $ERR_DIMENSION_ERROR, %edi
    jmp bsk_err

# ---------------------------------------------------------------------
# bsk_mat_input / bsk_smat_input -- MAT INPUT of a numeric / string list
#   (.Lrt_in_mat does the work; NUM is set).
#   Inputs  : %rdi = list descriptor
#   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: none
#   Frame   : none (tail jump)
# ---------------------------------------------------------------------
    .globl bsk_mat_input
    .type bsk_mat_input, @function
    .p2align 4
bsk_mat_input:
    xorl %esi, %esi                 # numbers
    jmp .Lrt_in_mat
    .size bsk_mat_input, . - bsk_mat_input

    .globl bsk_smat_input
    .type bsk_smat_input, @function
    .p2align 4
bsk_smat_input:
    movl $1, %esi                   # strings
    jmp .Lrt_in_mat
    .size bsk_smat_input, . - bsk_smat_input

# ---------------------------------------------------------------------
# bsk_num -- NUM: the number of values the most recent MAT INPUT
#   accepted (0 before the first).
#   Inputs  : none   Outputs : %xmm0 = NUM
#   Clobbers: %xmm0   Callee-saved used: none   Frame: none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_num
    .type bsk_num, @function
    .p2align 4
bsk_num:
    movsd .Lrt_in_numval(%rip), %xmm0
    ret
    .size bsk_num, . - bsk_num

# ---------------------------------------------------------------------
# The three INPUT diagnostics, from the shared include (errors.inc).
# ---------------------------------------------------------------------
    .section .rodata
    BSK_EMIT_INPUT_MSGS .Lrt_in_msg

# ---------------------------------------------------------------------
# State:
#   .Lrt_in_readers    (LIM_FILES + 1) reader records (RD_*): record 0 is
#                      standard input (fd 0, static buffers),
#                      records 1 .. LIM_FILES the files (zero until their
#                      first open for reading)
#   .Lrt_in_buf        RT_INBUF_SIZE bytes: standard input's chunk
#   .Lrt_in_line       RT_IN_LINEBUF bytes: standard input's line
#   .Lrt_in_rd         ptr the reader of the current input entry point
#   .Lrt_in_fmode      u32 1: INPUT # rules, 0: the INPUT dialogue
#   .Lrt_in_ttyknown   u32 1 once isatty(0) was asked
#   .Lrt_in_tty        u32 1 if stdin is a terminal
#   .Lrt_in_numval     double NUM
#   .Lrt_in_mtext      growable buffer (ptr, cap): MAT INPUT line text
#   .Lrt_in_mtext_len  u64 bytes used in it
#   .Lrt_in_mvals      growable buffer (ptr, cap): MAT INPUT values
# ---------------------------------------------------------------------
    .data
    .p2align 3
.Lrt_in_readers:
    .long 0                         # RD_FD: standard input
    .long 0                         # RD_RSV
    .quad .Lrt_in_buf               # RD_CHUNK
    .quad 0                         # RD_POS
    .quad 0                         # RD_FILL
    .quad .Lrt_in_line              # RD_LINE
    .quad 0                         # RD_LEN
    .quad 0                         # RD_CUR
    .long 0                         # RD_MORE
    .long 0                         # RD_RSV2
    .zero RD_SIZE * LIM_FILES       # files 1 .. LIM_FILES
.Lrt_in_rd:
    .quad .Lrt_in_readers           # standard input until selected

    .bss
    .p2align 4
.Lrt_in_buf:
    .zero RT_INBUF_SIZE
    .p2align 4
.Lrt_in_line:
    .zero RT_IN_LINEBUF
    .p2align 3
.Lrt_in_numval:
    .zero 8
.Lrt_in_mtext:
    .zero 16
.Lrt_in_mtext_len:
    .zero 8
.Lrt_in_mvals:
    .zero 16
.Lrt_in_fmode:
    .zero 4
.Lrt_in_ttyknown:
    .zero 4
.Lrt_in_tty:
    .zero 4

    .section .note.GNU-stack,"",@progbits
