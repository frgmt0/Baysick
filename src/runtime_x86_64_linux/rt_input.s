# =====================================================================
# src/runtime_x86_64_linux/rt_input.s -- INPUT, MAT INPUT and NUM
# (LANGUAGE.md 7.14.8, 7.15, 10; DESIGN.md 6.7).
#
# Defines (global, runtime.inc):
#   bsk_input_begin bsk_input_num bsk_input_str bsk_input_str_el
#   bsk_input_end
#   bsk_mat_input bsk_smat_input bsk_num
# Uses (private): bsk_rt_flush bsk_rt_print_prompt bsk_rt_print_linedone
# bsk_rt_write_all (rt_print.s), bsk_rt_str_assign (rt_str.s); bsk_saref1
# (rt_array.s).
#
# Input reader. Standard input is read with read(0, buf, RT_INBUF_SIZE)
# into a static chunk buffer (EINTR retried; any other error or 0 bytes
# = end of input, remembered). A line is assembled from it into a static
# line buffer: the bytes up to LF; one CR immediately before the LF is
# removed; a non-empty last line without LF counts. A line longer than
# LIM_INPUT_LINE bytes (after the CR removal) -> INPUT LINE TOO LONG. The
# buffer holds LIM_INPUT_LINE + 1 bytes so that a maximal line can still
# carry its CR. isatty(0) is called once, at the first line request; on
# a terminal every line request first writes the prompt (pending spaces,
# "? ", flush) and resets the column after the line. End of input at a
# line request -> END OF INPUT (bsk_err: pending newline, flush, message,
# exit 0).
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
# with: flush stdout, then write(2, msg, len) (failures ignored).
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
.equ RT_IN_NUMMAX, 16               # longest valid numeric field without
                                    # blanks: sign 9 digits . E sign 2 = 15
.equ RT_IN_GROW_MIN, 4096           # first size of a MAT INPUT buffer

# Growable buffer record (MAT INPUT text and values): ptr, capacity.
.equ RT_IN_GB_PTR, 0
.equ RT_IN_GB_CAP, 8

# Frame of .Lrt_in_mat (offsets from %rsp)
.equ RT_IN_M_BASE, 0                # text offset of the current line
.equ RT_IN_M_TMP,  8                # value offset / scratch
.equ RT_IN_M_TMPLEN, 16             # string length, the second word after RT_IN_M_TMP
.equ RT_IN_M_FRAME, 24

    .text

# ---------------------------------------------------------------------
# .Lrt_in_fillbuf -- refill the chunk buffer from fd 0.
#   Purpose : read(0, buf, RT_INBUF_SIZE), retried on EINTR; any other
#             error counts as end of input (0 bytes).
#   Inputs  : none
#   Outputs : %rax = bytes now in the buffer (0 = end of input);
#             .Lrt_in_pos = 0, .Lrt_in_fill = %rax
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbp = frame pointer
#   Frame   : 8 bytes (saved %rbp)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_in_fillbuf:
    pushq %rbp
    movq %rsp, %rbp
1:
    xorl %edi, %edi                 # fd 0
    leaq .Lrt_in_buf(%rip), %rsi
    movl $RT_INBUF_SIZE, %edx
    call read@PLT                   # bytes read, 0 at end, -1 on error
    testq %rax, %rax
    jns 2f
    call __errno_location@PLT
    cmpl $RT_EINTR, (%rax)
    je 1b                           # interrupted: read again
    xorl %eax, %eax                 # real error: end of input
2:
    movq %rax, .Lrt_in_fill(%rip)
    movq $0, .Lrt_in_pos(%rip)
    popq %rbp
    ret

# ---------------------------------------------------------------------
# .Lrt_in_readline -- one line request (LANGUAGE.md 7.15 "Lines").
#   Purpose : first call: remember isatty(0). End of input (remembered
#             or found now, with nothing on the line) -> END OF INPUT.
#             Terminal: prompt before, col = out = 0 after. Assemble the
#             line into .Lrt_in_line / .Lrt_in_len (CR before LF
#             removed; too long -> INPUT LINE TOO LONG); field cursor
#             at 0; .Lrt_in_more = 1 unless the line is empty or blank.
#   Inputs  : none
#   Outputs : the line state above
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = line buffer, %r12 = line length,
#             %r13 = chunk position, %rbp = frame pointer
#   Frame   : 40 bytes (%rbp, %rbx, %r12, %r13 + 8 bytes pad)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_in_readline:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    subq $8, %rsp                   # %rsp = 0 (mod 16)
    cmpl $0, .Lrt_in_ttyknown(%rip)
    jne 1f
    xorl %edi, %edi
    call isatty@PLT                 # once per run (DESIGN.md 6.7)
    xorl %ecx, %ecx
    testl %eax, %eax
    setne %cl
    movl %ecx, .Lrt_in_tty(%rip)
    movl $1, .Lrt_in_ttyknown(%rip)
1:
    cmpl $0, .Lrt_in_tty(%rip)
    je 2f
    call bsk_rt_print_prompt        # "? " on a terminal only
2:
    cmpl $0, .Lrt_in_eof(%rip)
    jne .Lrt_in_eoi                 # input already ended (after the prompt, as arm64)
    leaq .Lrt_in_line(%rip), %rbx
    xorl %r12d, %r12d               # line length so far
.Lrt_in_rl_chunk:
    movq .Lrt_in_pos(%rip), %r13
    cmpq .Lrt_in_fill(%rip), %r13
    jb .Lrt_in_rl_scan              # bytes left in the chunk
    call .Lrt_in_fillbuf
    testq %rax, %rax
    jnz .Lrt_in_rl_chunk
    movl $1, .Lrt_in_eof(%rip)      # end of input: remembered
    testq %r12, %r12
    jz .Lrt_in_eoi                  # nothing on this line: END OF INPUT
    jmp .Lrt_in_rl_done             # unterminated last line counts
.Lrt_in_rl_scan:
    # Copy bytes until LF or the end of the chunk.
    leaq .Lrt_in_buf(%rip), %rcx
    movq .Lrt_in_fill(%rip), %r8
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
    movq %r13, .Lrt_in_pos(%rip)
    jmp .Lrt_in_rl_chunk
.Lrt_in_rl_lf:
    movq %r13, .Lrt_in_pos(%rip)    # the LF is consumed
    testq %r12, %r12
    jz .Lrt_in_rl_done
    cmpb $RT_CH_CR, -1(%rbx,%r12)
    jne .Lrt_in_rl_done
    subq $1, %r12                   # one CR before the LF removed
.Lrt_in_rl_done:
    cmpq $LIM_INPUT_LINE, %r12
    ja .Lrt_in_toolong
    movq %r12, .Lrt_in_len(%rip)
    movq $0, .Lrt_in_cur(%rip)      # field cursor at the start
    call .Lrt_in_setmore
    cmpl $0, .Lrt_in_tty(%rip)
    je 3f
    call bsk_rt_print_linedone      # the terminal is at a new line
3:
    addq $8, %rsp
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret
.Lrt_in_eoi:
    movl $ERR_END_OF_INPUT, %edi
    jmp bsk_err                     # exit 0 after the message
.Lrt_in_toolong:
    movl $ERR_INPUT_LINE_TOO_LONG, %edi
    jmp bsk_err

# ---------------------------------------------------------------------
# .Lrt_in_setmore -- .Lrt_in_more = 1 if line[0 .. len) has a byte that
#   is not a blank (the line has fields), else 0.
#   Private convention (leaf): Inputs: line state. Clobbers %rax %rcx
#   %rdx.
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_in_setmore:
    leaq .Lrt_in_line(%rip), %rcx
    movq .Lrt_in_len(%rip), %rdx
    xorl %eax, %eax
1:
    cmpq %rdx, %rax
    jae 2f                          # only blanks: no field
    cmpb $RT_CH_SPACE, (%rcx,%rax)
    jne 3f
    addq $1, %rax
    jmp 1b
2:
    movl $0, .Lrt_in_more(%rip)
    ret
3:
    movl $1, .Lrt_in_more(%rip)
    ret

# ---------------------------------------------------------------------
# .Lrt_in_take -- take the next field of the current line.
#   Purpose : the field runs from the cursor to the next comma outside
#             quotes (every '"' toggles the quote state) or the end of
#             the line; the cursor moves past the comma (more = 1) or to
#             the end (more = 0).
#   Private convention (leaf). Precondition: .Lrt_in_more = 1.
#   Outputs : %rax = field start, %rdx = field end (offsets in the line)
#   Clobbers: %rax %rcx %rdx %rsi %r8 %r9
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_in_take:
    leaq .Lrt_in_line(%rip), %rsi
    movq .Lrt_in_len(%rip), %r8
    movq .Lrt_in_cur(%rip), %rax    # field start
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
    movq %r8, .Lrt_in_cur(%rip)
    movl $0, .Lrt_in_more(%rip)
    ret
5:
    movq %rcx, %rdx                 # field ends before the comma
    addq $1, %rcx
    movq %rcx, .Lrt_in_cur(%rip)    # next field after it
    movl $1, .Lrt_in_more(%rip)
    ret

# ---------------------------------------------------------------------
# .Lrt_in_numfield -- validate and convert a numeric field.
#   Purpose : copy the non-blank bytes (at most RT_IN_NUMMAX; more ->
#             invalid) to a stack buffer, check
#             [+|-] mantissa [E|e [+|-] digits] with mantissa :=
#             digits [ "." [digits] ] | "." digits, 1..9 mantissa digits
#             and 1..2 exponent digits, then strtod the text.
#   Inputs  : %rdi = field start, %rsi = field end (line offsets)
#   Outputs : %eax = 1 and %xmm0 = value if valid, else %eax = 0
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbp = frame pointer
#   Frame   : 8 bytes (saved %rbp) + 32 bytes text buffer at (%rsp)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_in_numfield:
    pushq %rbp
    movq %rsp, %rbp
    subq $32, %rsp                  # %rsp = 0 (mod 16); text at (%rsp)
    leaq .Lrt_in_line(%rip), %rcx
    xorl %edx, %edx                 # bytes copied
1:
    cmpq %rsi, %rdi
    jae 2f
    movzbl (%rcx,%rdi), %eax
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

# ---------------------------------------------------------------------
# .Lrt_in_strfield -- validate a string field and locate its value.
#   Purpose : skip leading blanks; quoted: '"', bytes but '"', '"', then
#             only blanks; value = the bytes between the quotes.
#             Unquoted: no '"' (and no '&' when %edx = 1, MAT INPUT);
#             value = the rest of the field.
#   Private convention (leaf):
#   Inputs  : %rdi = field start, %rsi = field end (line offsets),
#             %edx = 1 to reject '&' in an unquoted field, else 0
#   Outputs : %eax = 1 valid / 0 invalid; when valid %rcx = value start
#             (line offset), %rdx = value length
#   Clobbers: %rax %rcx %rdx %rdi %r8 %r9 %r10
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_in_strfield:
    leaq .Lrt_in_line(%rip), %r8
    movl %edx, %r10d                # '&' rule
1:
    cmpq %rsi, %rdi
    jae 5f                          # blank (or empty) field: unquoted ""
    cmpb $RT_CH_SPACE, (%r8,%rdi)
    jne 2f
    addq $1, %rdi                   # leading blanks are not part of it
    jmp 1b
2:
    cmpb $RT_CH_QUOTE, (%r8,%rdi)
    jne 5f
    # quoted: find the closing quote
    leaq 1(%rdi), %rcx              # value start
    movq %rcx, %r9
3:
    cmpq %rsi, %r9
    jae .Lrt_in_sf_bad              # no closing quote
    cmpb $RT_CH_QUOTE, (%r8,%r9)
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
    cmpb $RT_CH_SPACE, (%r8,%r9)
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
    movzbl (%r8,%r9), %eax
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
# .Lrt_in_diag -- write an INPUT diagnostic: flush stdout, then
#   write(2, msg, len); failures are ignored.
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
# bsk_input_begin -- INPUT: read the statement's first line.
#   Inputs  : none   Outputs : none
#   Errors  : END OF INPUT (exit 0), INPUT LINE TOO LONG
#   Clobbers: all caller-saved registers
#   Callee-saved used: none
#   Frame   : none (tail jump to .Lrt_in_readline)
# ---------------------------------------------------------------------
    .globl bsk_input_begin
    .type bsk_input_begin, @function
    .p2align 4
bsk_input_begin:
    jmp .Lrt_in_readline
    .size bsk_input_begin, . - bsk_input_begin

# ---------------------------------------------------------------------
# bsk_input_num -- INPUT: the next field as a number.
#   Purpose : no field left -> NOT ENOUGH INPUT -- ADD MORE, new line;
#             invalid field -> INPUT DATA NOT IN CORRECT FORMAT --
#             RETYPE IT, new line (rest of the line discarded); repeat
#             until a valid field is found.
#   Inputs  : none
#   Outputs : %xmm0 = value
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
.Lrt_in_num_loop:
    cmpl $0, .Lrt_in_more(%rip)
    jne 1f
    RT_IN_DIAG more                 # nothing left on this line
    call .Lrt_in_readline
    jmp .Lrt_in_num_loop
1:
    call .Lrt_in_take               # %rax = start, %rdx = end
    movq %rax, %rdi
    movq %rdx, %rsi
    call .Lrt_in_numfield
    testl %eax, %eax
    jnz 2f                          # valid: %xmm0 = value
    RT_IN_DIAG retype
    call .Lrt_in_readline           # the rest of the line is discarded
    jmp .Lrt_in_num_loop
2:
    popq %rbp
    ret
    .size bsk_input_num, . - bsk_input_num

# ---------------------------------------------------------------------
# .Lrt_in_strvalue -- INPUT: the value of the next valid field for a
#   string target, with the diagnostics of bsk_input_num (NOT ENOUGH
#   INPUT, new line; invalid -> RETYPE, new line; repeated).
#   Inputs  : none
#   Outputs : %rsi = value bytes (inside the line buffer), %rdx = length
#   Errors  : END OF INPUT, INPUT LINE TOO LONG
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbp = frame pointer
#   Frame   : 8 bytes (saved %rbp)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_in_strvalue:
    pushq %rbp
    movq %rsp, %rbp
.Lrt_in_str_loop:
    cmpl $0, .Lrt_in_more(%rip)
    jne 1f
    RT_IN_DIAG more
    call .Lrt_in_readline
    jmp .Lrt_in_str_loop
1:
    call .Lrt_in_take
    movq %rax, %rdi
    movq %rdx, %rsi
    xorl %edx, %edx                 # INPUT: '&' is an ordinary byte
    call .Lrt_in_strfield
    testl %eax, %eax
    jnz 2f
    RT_IN_DIAG retype
    call .Lrt_in_readline
    jmp .Lrt_in_str_loop
2:
    leaq .Lrt_in_line(%rip), %rsi
    addq %rcx, %rsi                 # value bytes (%rdx = length)
    popq %rbp
    ret

# ---------------------------------------------------------------------
# bsk_input_str -- INPUT: the next field as a string, stored into dst
#   with bsk_str_set semantics; the same diagnostics as bsk_input_num.
#   Inputs  : %rdi = destination SD
#   Outputs : none
#   Errors  : END OF INPUT, INPUT LINE TOO LONG, OUT OF ROOM
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
    call .Lrt_in_strvalue           # %rsi / %rdx = the value
    movq %rbx, %rdi
    call bsk_rt_str_assign          # dst := the value
    addq $8, %rsp
    popq %rbx
    popq %rbp
    ret
    .size bsk_input_str, . - bsk_input_str

# ---------------------------------------------------------------------
# bsk_input_str_el -- INPUT into a string list element L$(i) (the
#   element form of `insv`, IR.md 3.2): the field is taken first, with
#   every diagnostic and retype of bsk_input_str; only when the value is
#   assigned is the subscript checked (LANGUAGE.md 7.1, 7.15), then the
#   element := the value.
#   Inputs  : %rdi = string-list descriptor (RTA_*), %xmm0 = subscript i
#   Outputs : none
#   Errors  : END OF INPUT, INPUT LINE TOO LONG; then SUBSCRIPT ERROR
#             (bsk_saref1); OUT OF ROOM
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
# bsk_input_end -- INPUT: fields left on the line -> TOO MUCH INPUT --
#   EXCESS IGNORED (a diagnostic; the program continues).
#   Inputs  : none   Outputs : none
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
    cmpl $0, .Lrt_in_more(%rip)
    je 1f
    RT_IN_DIAG excess
1:
    popq %rbp
    ret
    .size bsk_input_end, . - bsk_input_end

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
# .Lrt_in_mat -- MAT INPUT of a list (LANGUAGE.md 7.14.8, transactional).
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
.Lrt_in_mat_restart:
    xorl %r13d, %r13d               # no field collected
    xorl %r14d, %r14d               # nothing bad yet
    movq $0, .Lrt_in_mtext_len(%rip)    # text of this statement's lines
.Lrt_in_mat_line:
    call .Lrt_in_readline
    # ---- continuation: the last non-blank byte is '&' outside quotes --
    xorl %r15d, %r15d               # not continued
    leaq .Lrt_in_line(%rip), %rsi
    movq .Lrt_in_len(%rip), %rcx    # k = end of the non-blank part
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
    movq %rdx, .Lrt_in_len(%rip)
    call .Lrt_in_setmore            # fields of the shortened line
.Lrt_in_mat_text:
    # ---- strings: append this line to the statement's text ------------
    cmpl $0, %r12d
    je .Lrt_in_mat_fields
    movq .Lrt_in_mtext_len(%rip), %rax
    movq %rax, RT_IN_M_BASE(%rsp)   # offset of this line in the text
    addq .Lrt_in_len(%rip), %rax
    leaq .Lrt_in_mtext(%rip), %rdi
    movq %rax, %rsi
    call .Lrt_in_grow               # %rax = text buffer
    movq RT_IN_M_BASE(%rsp), %rdi
    addq %rax, %rdi
    leaq .Lrt_in_line(%rip), %rsi
    movq .Lrt_in_len(%rip), %rdx
    addq %rdx, .Lrt_in_mtext_len(%rip)
    testq %rdx, %rdx
    jz .Lrt_in_mat_fields           # empty line: nothing to keep
    call memcpy@PLT
.Lrt_in_mat_fields:
    # ---- collect the fields of the line --------------------------------
    cmpl $0, .Lrt_in_more(%rip)
    je .Lrt_in_mat_lineend
    call .Lrt_in_take               # %rax = start, %rdx = end
    testl %r14d, %r14d
    jnz .Lrt_in_mat_fields          # already bad: just skip the rest
    movq %rax, %rdi
    movq %rdx, %rsi
    cmpl $0, %r12d
    jne .Lrt_in_mat_sfield
    call .Lrt_in_numfield           # %eax valid, %xmm0 value
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
    addq RT_IN_M_BASE(%rsp), %rcx   # value offset in the text
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
# State (zero-initialised):
#   .Lrt_in_buf        RT_INBUF_SIZE bytes: the read(0) chunk
#   .Lrt_in_pos        u64 next unread byte of the chunk
#   .Lrt_in_fill       u64 bytes in the chunk
#   .Lrt_in_eof        u32 1 once read reported the end (or an error)
#   .Lrt_in_ttyknown   u32 1 once isatty(0) was asked
#   .Lrt_in_tty        u32 1 if stdin is a terminal
#   .Lrt_in_line       RT_IN_LINEBUF bytes: the current line
#   .Lrt_in_len        u64 its length
#   .Lrt_in_cur        u64 field cursor (offset of the next field)
#   .Lrt_in_more       u32 1 if a field is left on the line
#   .Lrt_in_numval     double NUM
#   .Lrt_in_mtext      growable buffer (ptr, cap): MAT INPUT line text
#   .Lrt_in_mtext_len  u64 bytes used in it
#   .Lrt_in_mvals      growable buffer (ptr, cap): MAT INPUT values
# ---------------------------------------------------------------------
    .bss
    .p2align 4
.Lrt_in_buf:
    .zero RT_INBUF_SIZE
    .p2align 4
.Lrt_in_line:
    .zero RT_IN_LINEBUF
    .p2align 3
.Lrt_in_pos:
    .zero 8
.Lrt_in_fill:
    .zero 8
.Lrt_in_len:
    .zero 8
.Lrt_in_cur:
    .zero 8
.Lrt_in_numval:
    .zero 8
.Lrt_in_mtext:
    .zero 16
.Lrt_in_mtext_len:
    .zero 8
.Lrt_in_mvals:
    .zero 16
.Lrt_in_eof:
    .zero 4
.Lrt_in_ttyknown:
    .zero 4
.Lrt_in_tty:
    .zero 4
.Lrt_in_more:
    .zero 4

    .section .note.GNU-stack,"",@progbits
