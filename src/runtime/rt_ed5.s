// =====================================================================
// src/runtime/rt_ed5.s -- the Fifth Edition string functions LEN, ASC,
// VAL, STR$ and the string clear of string function values (DESIGN.md
// 6.8, LANGUAGE.md 6.1, 7.10.1).
//
// Defines (global, runtime.inc):
//   _bsk_len _bsk_asc _bsk_val _bsk_str _bsk_str_clear
// Uses: _bsk_rt_fmtnum (rt_numfmt.s: the PRINT field), _bsk_rt_parsenum
// (rt_input.s: the INPUT numeric-field rule), _bsk_rt_str_setbytes
// (rt_str.s), _bsk_err.
// =====================================================================
.include "baysick.inc"

.equ RT_ED5_NUMBUF, 48              // one PRINT field (at most 14 bytes)

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _bsk_str_clear -- the string := empty (LEN 0; PTR and CAP kept, so an
//   owned buffer stays owned for the next value).
//   Inputs  : x0 = SD
//   Outputs : none
//   Clobbers: none
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .globl _bsk_str_clear
    .p2align 2
_bsk_str_clear:
    str wzr, [x0, #SD_LEN]
    ret

// ---------------------------------------------------------------------
// _bsk_len -- LEN(s): the number of bytes of s, trailing blanks
//   included (LANGUAGE.md 6.1).
//   Inputs  : x0 = SD
//   Outputs : d0 = length (0 .. LIM_STRING_LEN, exact)
//   Clobbers: w9, d0
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .globl _bsk_len
    .p2align 2
_bsk_len:
    ldr w9, [x0, #SD_LEN]           // zero-extended u32
    ucvtf d0, w9
    ret

// ---------------------------------------------------------------------
// _bsk_asc -- ASC(s): the code 0..255 of the first byte of s.
//   Inputs  : x0 = SD
//   Outputs : d0 = code
//   Errors  : ASC OF EMPTY STRING (s empty)
//   Clobbers: x0, w9, d0
//   Callee-saved used: none
//   Frame   : none (leaf; the error exit is a branch)
// ---------------------------------------------------------------------
    .globl _bsk_asc
    .p2align 2
_bsk_asc:
    ldr w9, [x0, #SD_LEN]
    cbz w9, Lrt_ed5_asc_empty
    ldr x9, [x0, #SD_PTR]
    ldrb w9, [x9]                   // first byte, unsigned
    ucvtf d0, w9
    ret
Lrt_ed5_asc_empty:
    mov w0, #ERR_ASC_EMPTY
    b _bsk_err

// ---------------------------------------------------------------------
// _bsk_val -- VAL(s) (LANGUAGE.md 6.1): s read exactly like a numeric
//   INPUT field -- every blank removed, then [+|-] constant with the
//   §4.1 limits -- and converted with strtod.
//   Inputs  : x0 = SD
//   Outputs : d0 = value
//   Errors  : ILLEGAL 'VAL' ARGUMENT (empty, all blank, not a number)
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : 16 bytes (frame record)
// ---------------------------------------------------------------------
    .globl _bsk_val
    .p2align 2
_bsk_val:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    ldr w1, [x0, #SD_LEN]
    ldr x0, [x0, #SD_PTR]           // (not read when LEN = 0)
    bl _bsk_rt_parsenum             // w0 valid, d0 value
    cbz w0, Lrt_ed5_val_bad
    ldp x29, x30, [sp], #16
    ret
Lrt_ed5_val_bad:
    mov w0, #ERR_ILLEGAL_VAL
    bl _bsk_err                     // noreturn

// ---------------------------------------------------------------------
// _bsk_str -- dst := STR$(x) (LANGUAGE.md 6.1): the §9 field
//   sign + body + " " without its leading blank (x >= 0, -0 included)
//   and without its trailing blank; stored like _bsk_str_set.
//   Inputs  : x0 = destination SD, d0 = x (finite)
//   Outputs : none
//   Errors  : OUT OF ROOM
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = destination
//   Frame   : 32 bytes (frame record + x19) + RT_ED5_NUMBUF (the field)
// ---------------------------------------------------------------------
    .globl _bsk_str
    .p2align 2
_bsk_str:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    sub sp, sp, #RT_ED5_NUMBUF      // the field at [sp]
    mov x19, x0
    mov x0, sp
    bl _bsk_rt_fmtnum               // x0 = field length (>= 3)
    mov x1, sp
    sub x2, x0, #1                  // without the trailing blank
    ldrb w9, [x1]
    cmp w9, #' '
    b.ne 1f                         // '-': the sign stays
    add x1, x1, #1                  // a blank sign is dropped
    sub x2, x2, #1
1:
    mov x0, x19
    bl _bsk_rt_str_setbytes         // dst := the bytes (OUT OF ROOM)
    add sp, sp, #RT_ED5_NUMBUF
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
