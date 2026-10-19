# =====================================================================
# src/runtime_x86_64_linux/rt_numfmt.s -- Dartmouth number format
# (LANGUAGE.md section 9).
#
# Defines (private to the runtime, .globl + .hidden):
#   bsk_rt_fmtnum   format the PRINT field F = sign + body + " "
#   bsk_rt_utoa     unsigned 64-bit integer -> decimal digits
#
# Integers with |x| < 1e9 are converted with integer arithmetic
# (cvttsd2si). Everything else is rounded to six significant digits by
# snprintf("%.5e") (correct rounding from the exact binary value, ties
# to even); the digits and exponent are then laid out by the rules of
# section 9 here. Same algorithm as src/runtime/rt_numfmt.s.
# =====================================================================
.include "baysick.inc"

# snprintf scratch: "d.ddddde+ddd" is at most 12 bytes + NUL.
.equ RT_SCI_BUF,    32
# Characters written into the field.
.equ RT_CH_SPACE,   32              # ' '
.equ RT_CH_PLUS,    43              # '+'
.equ RT_CH_MINUS,   45              # '-'
.equ RT_CH_POINT,   46              # '.'
.equ RT_CH_ZERO,    48              # '0'
.equ RT_CH_E,       69              # 'E'

    .text

# ---------------------------------------------------------------------
# bsk_rt_utoa -- write the decimal digits of an unsigned integer.
#   Inputs  : %rdi = value, %rsi = destination (needs up to 20 bytes)
#   Outputs : %rax = number of digits written (>= 1); no NUL is written
#   Clobbers: %rax, %rcx, %rdx, %r8, %r9 (%rdi and %rsi are preserved)
#   Callee-saved used: none
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_rt_utoa
    .hidden bsk_rt_utoa
    .type bsk_rt_utoa, @function
    .p2align 4
bsk_rt_utoa:
    # Count the digits first so they can be written right to left.
    movl $1, %ecx                   # digit count
    movq %rdi, %rax
    movl $10, %r8d
.Lrt_numfmt_utoa_count:
    cmpq $10, %rax
    jb .Lrt_numfmt_utoa_write
    xorl %edx, %edx
    divq %r8                        # drop one digit
    addq $1, %rcx
    jmp .Lrt_numfmt_utoa_count
.Lrt_numfmt_utoa_write:
    leaq (%rsi,%rcx), %r9           # one past the last digit
    movq %rdi, %rax
.Lrt_numfmt_utoa_digit:
    xorl %edx, %edx
    divq %r8                        # %rax = quotient, %rdx = digit
    addl $RT_CH_ZERO, %edx
    subq $1, %r9
    movb %dl, (%r9)                 # store right to left
    testq %rax, %rax
    jnz .Lrt_numfmt_utoa_digit
    movq %rcx, %rax                 # digit count
    ret
    .size bsk_rt_utoa, . - bsk_rt_utoa

# ---------------------------------------------------------------------
# bsk_rt_fmtnum -- build the PRINT field for a number.
#   Purpose : F = sign + body + " " per LANGUAGE.md section 9.
#   Inputs  : %xmm0 = x (finite), %rdi = destination buffer (>= 16 bytes)
#   Outputs : %rax = length of F
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = start of destination, %r12 = write cursor,
#             %r13 = address of the six contiguous rounded digits,
#             %rbp = frame pointer
#   Frame   : 32 bytes (%rbp, %rbx, %r12, %r13) + RT_SCI_BUF snprintf
#             output at (%rsp) + 8 bytes alignment pad = 72 bytes
#   Register use in the layout part: %rcx = decimal exponent e (signed),
#             %rdx = k (significant digits kept), %r8/%r9 = counters
# ---------------------------------------------------------------------
    .globl bsk_rt_fmtnum
    .hidden bsk_rt_fmtnum
    .type bsk_rt_fmtnum, @function
    .p2align 4
bsk_rt_fmtnum:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    subq $(RT_SCI_BUF + 8), %rsp    # %rsp = 0 (mod 16) for snprintf
    movq %rdi, %rbx                 # field start
    movq %rdi, %r12                 # write cursor

    # Sign: '-' only if x < 0 (so -0 gets a space).
    movl $RT_CH_SPACE, %eax
    movl $RT_CH_MINUS, %ecx
    pxor %xmm1, %xmm1
    ucomisd %xmm0, %xmm1            # flags of 0 - x
    cmoval %ecx, %eax               # above: 0 > x, strictly negative
    movb %al, (%r12)
    addq $1, %r12

    # a = |x|: clear the sign bit through an integer register.
    movq %xmm0, %rax
    btrq $63, %rax
    movq %rax, %xmm0

    # Rule 1: a = 0 -> "0" (with the sign bit clear, only +0 has bits 0).
    testq %rax, %rax
    jz .Lrt_numfmt_zero

    # Rule 2: integer below 1e9 -> all its digits.
    movl $PRINT_INT_LIMIT, %eax
    cvtsi2sdl %eax, %xmm2           # 1e9, exact
    ucomisd %xmm2, %xmm0
    jae .Lrt_numfmt_sci             # a >= 1e9: too big for "in full"
    cvttsd2si %xmm0, %rax           # trunc(a), exact below 1e9
    cvtsi2sdq %rax, %xmm1
    ucomisd %xmm0, %xmm1
    jne .Lrt_numfmt_sci             # trunc(a) != a: has a fraction
    movq %rax, %rdi
    movq %r12, %rsi
    call bsk_rt_utoa
    addq %rax, %r12
    jmp .Lrt_numfmt_trail

.Lrt_numfmt_zero:
    movb $RT_CH_ZERO, (%r12)
    addq $1, %r12
    jmp .Lrt_numfmt_trail

    # Rule 3: six significant digits via snprintf(buf, 32, "%.5e", a).
    # Variadic call: the double goes in %xmm0, %al = 1 vector register.
.Lrt_numfmt_sci:
    movq %rsp, %rdi
    movl $RT_SCI_BUF, %esi
    leaq .Lrt_numfmt_fmt(%rip), %rdx
    movl $1, %eax
    call snprintf@PLT
    # Output is "d.ddddde<sign><2 or 3 digits>". Make the six digits
    # contiguous by copying d1 over the '.': digits at 1..6(%rsp).
    movzbl (%rsp), %eax
    movb %al, 1(%rsp)
    leaq 1(%rsp), %r13              # %r13 -> d1..d6

    # Decimal exponent e (signed) into %rcx.
    leaq 9(%rsp), %rsi              # first exponent digit
    xorl %ecx, %ecx
.Lrt_numfmt_exp:
    movzbl (%rsi), %eax
    addq $1, %rsi
    testl %eax, %eax
    jz .Lrt_numfmt_exp_done
    subl $RT_CH_ZERO, %eax
    imulq $10, %rcx, %rcx
    addq %rax, %rcx                 # e = e*10 + digit
    jmp .Lrt_numfmt_exp
.Lrt_numfmt_exp_done:
    cmpb $RT_CH_MINUS, 8(%rsp)      # exponent sign
    jne 1f
    negq %rcx
1:

    # k = number of digits left after dropping trailing zeros (>= 1).
    movl $6, %edx
.Lrt_numfmt_k:
    cmpq $1, %rdx
    jle .Lrt_numfmt_k_done
    cmpb $RT_CH_ZERO, -1(%r13,%rdx) # digit d_k
    jne .Lrt_numfmt_k_done
    subq $1, %rdx                   # trailing zero: drop it
    jmp .Lrt_numfmt_k
.Lrt_numfmt_k_done:

    # Form selection (%rcx = e, %rdx = k).
    cmpq $-1, %rcx
    jl .Lrt_numfmt_small            # e < -1
    cmpq $5, %rcx
    jg .Lrt_numfmt_eform            # e >= 6

    # Fixed form, -1 <= e <= 5: e+1 digits, '.', remaining digits up to k.
    leaq 1(%rcx), %r8               # digits before the point
    xorl %r9d, %r9d                 # digit index
.Lrt_numfmt_int:
    cmpq %r8, %r9
    jge .Lrt_numfmt_point
    movzbl (%r13,%r9), %eax
    movb %al, (%r12)
    addq $1, %r12
    addq $1, %r9
    jmp .Lrt_numfmt_int
.Lrt_numfmt_point:
    movb $RT_CH_POINT, (%r12)       # point kept even with nothing after
    addq $1, %r12
.Lrt_numfmt_frac:
    cmpq %rdx, %r9
    jge .Lrt_numfmt_trail
    movzbl (%r13,%r9), %eax
    movb %al, (%r12)
    addq $1, %r12
    addq $1, %r9
    jmp .Lrt_numfmt_frac

    # e < -1: fixed only if e - k + 1 >= -6 (all digits in 6 decimals).
.Lrt_numfmt_small:
    movq %rcx, %r8
    subq %rdx, %r8
    addq $1, %r8                    # e - k + 1
    cmpq $-6, %r8
    jl .Lrt_numfmt_eform
    movb $RT_CH_POINT, (%r12)
    addq $1, %r12
    movq %rcx, %r8
    notq %r8                        # zeros after the point: -e - 1
.Lrt_numfmt_zeros:
    testq %r8, %r8
    jz .Lrt_numfmt_sdig
    movb $RT_CH_ZERO, (%r12)
    addq $1, %r12
    subq $1, %r8
    jmp .Lrt_numfmt_zeros
.Lrt_numfmt_sdig:
    xorl %r9d, %r9d                 # then d1..dk
    jmp .Lrt_numfmt_frac

    # E form: d1 '.' d2..d6 'E' sign |e|, all six digits kept.
.Lrt_numfmt_eform:
    movzbl (%r13), %eax
    movb %al, (%r12)
    movb $RT_CH_POINT, 1(%r12)
    addq $2, %r12
    movl $1, %r9d
.Lrt_numfmt_edig:
    movzbl (%r13,%r9), %eax
    movb %al, (%r12)
    addq $1, %r12
    addq $1, %r9
    cmpq $6, %r9
    jb .Lrt_numfmt_edig
    movb $RT_CH_E, (%r12)
    movl $RT_CH_PLUS, %eax
    movl $RT_CH_MINUS, %r8d
    movq %rcx, %rdi                 # |e| for utoa
    testq %rcx, %rcx
    jns 2f
    movl %r8d, %eax                 # negative exponent: '-'
    negq %rdi
2:
    movb %al, 1(%r12)
    addq $2, %r12
    movq %r12, %rsi
    call bsk_rt_utoa                # exponent without leading zeros
    addq %rax, %r12

.Lrt_numfmt_trail:
    movb $RT_CH_SPACE, (%r12)       # every field ends with a space
    addq $1, %r12
    movq %r12, %rax
    subq %rbx, %rax                 # field length
    addq $(RT_SCI_BUF + 8), %rsp
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret
    .size bsk_rt_fmtnum, . - bsk_rt_fmtnum

    .section .rodata
.Lrt_numfmt_fmt:
    .asciz "%.5e"

    .section .note.GNU-stack,"",@progbits
