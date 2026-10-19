// =====================================================================
// src/runtime/rt_numfmt.s -- Dartmouth number format (LANGUAGE.md §9).
//
// Defines (private to the runtime, .private_extern):
//   _bsk_rt_fmtnum   format the PRINT field F = sign + body + " "
//   _bsk_rt_utoa     unsigned 64-bit integer -> decimal digits
//
// Integers with |x| < 1e9 are converted with integer arithmetic.
// Everything else is rounded to six significant digits by
// snprintf("%.5e") (correct rounding from the exact binary value, ties
// to even); the digits and exponent are then laid out by the rules of
// section 9 here.
// =====================================================================
.include "baysick.inc"

// Bits of the double 1e9 (= PRINT_INT_LIMIT): 0x41CDCD6500000000.
.equ RT_D1E9_HI16,  0x41CD
.equ RT_D1E9_MID16, 0xCD65
// snprintf scratch: "d.ddddde+ddd" is at most 12 bytes + NUL.
.equ RT_SCI_BUF,    32

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _bsk_rt_utoa -- write the decimal digits of an unsigned integer.
//   Inputs  : x0 = value, x1 = destination (needs up to 20 bytes)
//   Outputs : x0 = number of digits written (>= 1); no NUL is written
//   Clobbers: x1-x6
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .private_extern _bsk_rt_utoa
    .p2align 2
_bsk_rt_utoa:
    // Count the digits first so they can be written right to left.
    mov x2, #1                      // digit count
    mov x3, x0
    mov x4, #10
Lrt_numfmt_utoa_count:
    cmp x3, #10
    b.lo Lrt_numfmt_utoa_write
    udiv x3, x3, x4
    add x2, x2, #1
    b Lrt_numfmt_utoa_count
Lrt_numfmt_utoa_write:
    add x5, x1, x2                  // one past the last digit
    mov x3, x0
Lrt_numfmt_utoa_digit:
    udiv x6, x3, x4                 // quotient
    msub x1, x6, x4, x3             // remainder = value - q*10
    add w1, w1, #'0'
    strb w1, [x5, #-1]!             // store right to left
    mov x3, x6
    cbnz x3, Lrt_numfmt_utoa_digit
    mov x0, x2
    ret

// ---------------------------------------------------------------------
// _bsk_rt_fmtnum -- build the PRINT field for a number.
//   Purpose : F = sign + body + " " per LANGUAGE.md section 9.
//   Inputs  : d0 = x (finite), x0 = destination buffer (>= 16 bytes)
//   Outputs : x0 = length of F
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = start of destination, x20 = write cursor,
//             x21 = address of the six contiguous rounded digits
//   Frame   : 48 bytes (frame record + x19..x21) + 16 (variadic slot)
//             + RT_SCI_BUF (snprintf output) = 96 bytes
//   Local stack layout after the prologue:
//     [sp, #0]   variadic argument slot for snprintf (the double)
//     [sp, #16]  snprintf output "d.ddddde±XX"
// ---------------------------------------------------------------------
    .private_extern _bsk_rt_fmtnum
    .p2align 2
_bsk_rt_fmtnum:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    sub sp, sp, #(16 + RT_SCI_BUF)
    mov x19, x0                     // field start
    mov x20, x0                     // write cursor

    // Sign: '-' only if x < 0 (so -0 gets a space).
    mov w9, #' '
    mov w10, #'-'
    fcmp d0, #0.0
    csel w9, w10, w9, mi            // mi: strictly less than 0
    strb w9, [x20], #1
    fabs d0, d0                     // a = |x|

    // Rule 1: a = 0 -> "0".
    fcmp d0, #0.0
    b.eq Lrt_numfmt_zero

    // Rule 2: integer below 1e9 -> all its digits.
    frintz d1, d0
    fcmp d1, d0
    b.ne Lrt_numfmt_sci             // has a fraction
    movz x9, #RT_D1E9_HI16, lsl #48
    movk x9, #RT_D1E9_MID16, lsl #32
    fmov d2, x9                     // 1e9
    fcmp d0, d2
    b.ge Lrt_numfmt_sci             // too big for "in full"
    fcvtzu x0, d0                   // exact: integer < 1e9
    mov x1, x20
    bl _bsk_rt_utoa
    add x20, x20, x0
    b Lrt_numfmt_trail

Lrt_numfmt_zero:
    mov w9, #'0'
    strb w9, [x20], #1
    b Lrt_numfmt_trail

    // Rule 3: six significant digits via snprintf(buf, 32, "%.5e", a).
    // Apple arm64: the variadic double goes in the stack slot at [sp].
Lrt_numfmt_sci:
    str d0, [sp]
    add x0, sp, #16
    mov x1, #RT_SCI_BUF
    adrp x2, Lrt_numfmt_fmt@PAGE
    add x2, x2, Lrt_numfmt_fmt@PAGEOFF
    bl _snprintf
    // Output is "d.ddddde<sign><2 or 3 digits>". Make the six digits
    // contiguous by copying d1 over the '.': digits at [sp, #17..22].
    ldrb w9, [sp, #16]
    strb w9, [sp, #17]
    add x21, sp, #17                // x21 -> d1..d6

    // Decimal exponent e (signed) into x11.
    add x10, sp, #25                // first exponent digit
    mov x11, #0
    mov x13, #10
Lrt_numfmt_exp:
    ldrb w12, [x10], #1
    cbz w12, Lrt_numfmt_exp_done
    sub w12, w12, #'0'
    madd x11, x11, x13, x12         // e = e*10 + digit
    b Lrt_numfmt_exp
Lrt_numfmt_exp_done:
    ldrb w12, [sp, #24]             // exponent sign
    cmp w12, #'-'
    cneg x11, x11, eq

    // k = number of digits left after dropping trailing zeros (>= 1).
    mov x12, #6
Lrt_numfmt_k:
    cmp x12, #1
    b.le Lrt_numfmt_k_done
    sub x13, x12, #1
    ldrb w14, [x21, x13]            // digit d_k
    cmp w14, #'0'
    b.ne Lrt_numfmt_k_done
    mov x12, x13                    // trailing zero: drop it
    b Lrt_numfmt_k
Lrt_numfmt_k_done:

    // Form selection (x11 = e, x12 = k).
    cmn x11, #1
    b.lt Lrt_numfmt_small           // e < -1
    cmp x11, #5
    b.gt Lrt_numfmt_eform           // e >= 6

    // Fixed form, -1 <= e <= 5: e+1 digits, '.', remaining digits up to k.
    add x13, x11, #1                // digits before the point
    mov x14, #0                     // digit index
Lrt_numfmt_int:
    cmp x14, x13
    b.ge Lrt_numfmt_point
    ldrb w15, [x21, x14]
    strb w15, [x20], #1
    add x14, x14, #1
    b Lrt_numfmt_int
Lrt_numfmt_point:
    mov w15, #'.'                   // point kept even with nothing after
    strb w15, [x20], #1
Lrt_numfmt_frac:
    cmp x14, x12
    b.ge Lrt_numfmt_trail
    ldrb w15, [x21, x14]
    strb w15, [x20], #1
    add x14, x14, #1
    b Lrt_numfmt_frac

    // e < -1: fixed only if e - k + 1 >= -6 (all digits in 6 decimals).
Lrt_numfmt_small:
    sub x13, x11, x12
    add x13, x13, #1                // e - k + 1
    cmn x13, #6
    b.lt Lrt_numfmt_eform
    mov w15, #'.'
    strb w15, [x20], #1
    mvn x13, x11                    // zeros after the point: -e - 1
    mov w15, #'0'
Lrt_numfmt_zeros:
    cbz x13, Lrt_numfmt_sdig
    strb w15, [x20], #1
    sub x13, x13, #1
    b Lrt_numfmt_zeros
Lrt_numfmt_sdig:
    mov x14, #0                     // then d1..dk
    b Lrt_numfmt_frac

    // E form: d1 '.' d2..d6 'E' sign |e|, all six digits kept.
Lrt_numfmt_eform:
    ldrb w15, [x21]
    strb w15, [x20], #1
    mov w15, #'.'
    strb w15, [x20], #1
    mov x14, #1
Lrt_numfmt_edig:
    ldrb w15, [x21, x14]
    strb w15, [x20], #1
    add x14, x14, #1
    cmp x14, #6
    b.lo Lrt_numfmt_edig
    mov w15, #'E'
    strb w15, [x20], #1
    mov w15, #'+'
    mov w16, #'-'
    cmp x11, #0
    csel w15, w16, w15, lt
    strb w15, [x20], #1
    cneg x0, x11, lt                // |e|
    mov x1, x20
    bl _bsk_rt_utoa                 // exponent without leading zeros
    add x20, x20, x0

Lrt_numfmt_trail:
    mov w9, #' '                    // every field ends with a space
    strb w9, [x20], #1
    sub x0, x20, x19                // field length
    add sp, sp, #(16 + RT_SCI_BUF)
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

    .section __TEXT,__cstring,cstring_literals
Lrt_numfmt_fmt:
    .asciz "%.5e"
