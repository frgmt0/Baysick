# =====================================================================
# src/runtime_x86_64_linux/rt_ed5.s -- the Fifth Edition string
# functions LEN, ASC, VAL and STR$ (LANGUAGE.md 6, 6.1; DESIGN.md 6.8).
#
# Defines (global, runtime.inc):
#   bsk_str bsk_len bsk_asc bsk_val
# Uses (private): bsk_rt_fmtnum (rt_numfmt.s), bsk_rt_str_assign
# (rt_str.s), bsk_rt_numtext (rt_input.s: the numeric-field rule of
# INPUT, so program constants, INPUT fields and VAL share one syntax).
# =====================================================================
.include "baysick.inc"

.equ RT_ED5_NUMBUF, 32              # one PRINT field (at most 14 bytes)
.equ RT_CH_SPACE, 32                # ' '

    .text

# ---------------------------------------------------------------------
# bsk_str -- dst := STR$(x) (LANGUAGE.md 6.1).
#   Purpose : the section 9 field F of x (bsk_rt_fmtnum: sign or blank,
#             body, blank) without its leading blank (x >= 0, -0
#             included) and without its trailing blank; stored with
#             bsk_str_set semantics.
#   Inputs  : %rdi = destination SD, %xmm0 = x (finite)
#   Outputs : none
#   Errors  : OUT OF ROOM
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = destination, %rbp = frame pointer
#   Frame   : 24 bytes (%rbp, %rbx + 8 bytes pad) + RT_ED5_NUMBUF field
#             buffer at (%rsp)
# ---------------------------------------------------------------------
    .globl bsk_str
    .type bsk_str, @function
    .p2align 4
bsk_str:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    subq $RT_ED5_NUMBUF + 8, %rsp   # field buffer; %rsp = 0 (mod 16)
    movq %rdi, %rbx
    movq %rsp, %rdi
    call bsk_rt_fmtnum              # %rax = length of F (>= 3)
    movq %rsp, %rsi                 # F
    leaq -1(%rax), %rdx             # without the trailing blank
    cmpb $RT_CH_SPACE, (%rsi)
    jne 1f                          # '-': the sign stays
    addq $1, %rsi                   # x >= 0: the leading blank goes
    subq $1, %rdx
1:
    movq %rbx, %rdi
    call bsk_rt_str_assign          # dst := the bytes (not overlapping)
    addq $RT_ED5_NUMBUF + 8, %rsp
    popq %rbx
    popq %rbp
    ret
    .size bsk_str, . - bsk_str

# ---------------------------------------------------------------------
# bsk_len -- LEN(s): the length in bytes, trailing blanks included.
#   Inputs  : %rdi = SD
#   Outputs : %xmm0 = SD_LEN as a double (zero-extended u32, exact)
#   Clobbers: %rax %xmm0   Callee-saved used: none   Frame: none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_len
    .type bsk_len, @function
    .p2align 4
bsk_len:
    movl SD_LEN(%rdi), %eax         # zero-extended into %rax
    cvtsi2sdq %rax, %xmm0
    ret
    .size bsk_len, . - bsk_len

# ---------------------------------------------------------------------
# bsk_asc -- ASC(s): the code 0 .. 255 of the first byte.
#   Inputs  : %rdi = SD
#   Outputs : %xmm0 = the code as a double
#   Errors  : the empty string -> ASC OF EMPTY STRING
#   Clobbers: %rax %rdi %xmm0   Callee-saved used: none
#   Frame   : none (leaf; the error leaves by a jump to bsk_err)
# ---------------------------------------------------------------------
    .globl bsk_asc
    .type bsk_asc, @function
    .p2align 4
bsk_asc:
    cmpl $0, SD_LEN(%rdi)
    je 1f                           # no first byte
    movq SD_PTR(%rdi), %rax
    movzbl (%rax), %eax             # unsigned byte
    cvtsi2sdl %eax, %xmm0
    ret
1:
    movl $ERR_ASC_EMPTY, %edi
    jmp bsk_err
    .size bsk_asc, . - bsk_asc

# ---------------------------------------------------------------------
# bsk_val -- VAL(s) (LANGUAGE.md 6.1): the INPUT numeric-field rule on
#   the whole value (every blank removed, then [+|-] mantissa [E [+|-]
#   digits] with the section 4.1 limits; bsk_rt_numtext copies at most
#   16 non-blank bytes, so a longer text is rejected before copying),
#   then strtod.
#   Inputs  : %rdi = SD
#   Outputs : %xmm0 = the value
#   Errors  : not a number (also empty or all blank) -> ILLEGAL 'VAL'
#             ARGUMENT
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbp = frame pointer
#   Frame   : 8 bytes (saved %rbp)
# ---------------------------------------------------------------------
    .globl bsk_val
    .type bsk_val, @function
    .p2align 4
bsk_val:
    pushq %rbp
    movq %rsp, %rbp
    movl SD_LEN(%rdi), %esi         # length
    movq SD_PTR(%rdi), %rdi         # bytes (may be 0 when empty)
    addq %rdi, %rsi                 # end
    call bsk_rt_numtext             # %eax = valid, %xmm0 = value
    testl %eax, %eax
    jz 1f
    popq %rbp
    ret
1:
    movl $ERR_ILLEGAL_VAL, %edi
    jmp bsk_err
    .size bsk_val, . - bsk_val

    .section .note.GNU-stack,"",@progbits
