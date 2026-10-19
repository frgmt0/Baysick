// =====================================================================
// src/driver/diag.s -- compiler diagnostics on stderr.
//
//   _drv_diag(x0=fmt, x1=arg0, x2=arg1)   "baysick: <fmt expanded>\n"
//   _drv_usage_line()                     "baysick: usage: ..." line
//   _drv_basic_error(w0=code, w1=line)    "<MESSAGE> IN <line>\n" or
//                                         "<MESSAGE>\n" (line == 0)
//
// The BASIC message texts come only from BSK_EMIT_ERRMSG_TABLE
// (include/errors.inc). Formats understand "%s" (NUL-terminated string)
// and "%d" (signed 64-bit decimal); arguments are used in order.
// =====================================================================
.include "baysick.inc"

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _drv_diag -- print one "baysick: ..." line to stderr.
//   in:  x0 = format, x1 = first argument, x2 = second argument
//   out: none (write errors on stderr are ignored)
//   clobbers: x0-x17
//   callee-saved: x19 = format cursor, x20 = next argument,
//                 x21 = the argument after that
//   frame: 64 bytes (frame record, x19-x21, OutBuf at [sp,#40])
// ---------------------------------------------------------------------
    .globl _drv_diag
    .p2align 2
_drv_diag:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov x19, x0
    mov x20, x1
    mov x21, x2
    // a fresh buffer, freed at the end
    add x0, sp, #40
    bl _ob_init
    add x0, sp, #40
    adrp x1, Ldrv_diag_prefix@PAGE
    add x1, x1, Ldrv_diag_prefix@PAGEOFF
    bl _ob_puts
Ldrv_diag_loop:
    ldrb w1, [x19], #1
    cbz w1, Ldrv_diag_end
    cmp w1, #'%'
    b.ne Ldrv_diag_lit
    // a directive: look at the conversion letter
    ldrb w9, [x19]
    cmp w9, #'s'
    b.eq Ldrv_diag_str
    cmp w9, #'d'
    b.eq Ldrv_diag_dec
    // any other '%' is literal text
Ldrv_diag_lit:
    add x0, sp, #40
    bl _ob_putc
    b Ldrv_diag_loop
Ldrv_diag_str:
    add x19, x19, #1
    add x0, sp, #40
    mov x1, x20
    bl _ob_puts
    mov x20, x21                        // shift the argument list
    b Ldrv_diag_loop
Ldrv_diag_dec:
    add x19, x19, #1
    add x0, sp, #40
    mov x1, x20
    bl _ob_puti
    mov x20, x21
    b Ldrv_diag_loop
Ldrv_diag_end:
    // newline, write to stderr, release the buffer
    add x0, sp, #40
    mov w1, #'\n'
    bl _ob_putc
    add x0, sp, #40
    mov w1, #2
    bl _ob_write_fd
    ldr x0, [sp, #40 + OB_DATA]
    bl _free
    ldp x19, x20, [sp, #16]
    ldr x21, [sp, #32]
    ldp x29, x30, [sp], #64
    ret

// ---------------------------------------------------------------------
// _drv_usage_line -- print the usage line (DESIGN.md 4.2) to stderr.
//   in:  none   out: none
//   clobbers: x0-x17   callee-saved: none
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .globl _drv_usage_line
    .p2align 2
_drv_usage_line:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x0, Ldrv_usage_fmt@PAGE
    add x0, x0, Ldrv_usage_fmt@PAGEOFF
    mov x1, #0
    mov x2, #0
    bl _drv_diag
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// _drv_basic_error -- print a BASIC compile error (LANGUAGE.md 10.1).
//   in:  w0 = ERR_* code (1..ERR_TABLE_SIZE-1 with a message),
//        w1 = BASIC line number, 0 = message without a line number
//   out: none; an invalid code is an internal error (_drv_fatal)
//   clobbers: x0-x17
//   callee-saved: x19 = message, x20 = line
//   frame: 64 bytes (frame record, x19/x20, OutBuf at [sp,#32])
// ---------------------------------------------------------------------
    .globl _drv_basic_error
    .p2align 2
_drv_basic_error:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov w20, w1
    // look the code up in the shared message table
    cmp w0, #ERR_TABLE_SIZE
    b.hs Ldrv_basic_error_bad
    adrp x9, Ldrv_errmsg@PAGE
    add x9, x9, Ldrv_errmsg@PAGEOFF
    ldr x19, [x9, w0, uxtw #3]
    cbz x19, Ldrv_basic_error_bad
    add x0, sp, #32
    bl _ob_init
    add x0, sp, #32
    mov x1, x19
    bl _ob_puts
    cbz w20, 1f
    // " IN <line>"
    add x0, sp, #32
    adrp x1, Ldrv_in_text@PAGE
    add x1, x1, Ldrv_in_text@PAGEOFF
    bl _ob_puts
    add x0, sp, #32
    mov w1, w20
    bl _ob_putu
1:
    add x0, sp, #32
    mov w1, #'\n'
    bl _ob_putc
    add x0, sp, #32
    mov w1, #2
    bl _ob_write_fd
    ldr x0, [sp, #32 + OB_DATA]
    bl _free
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret
Ldrv_basic_error_bad:
    adrp x0, Ldrv_bad_code@PAGE
    add x0, x0, Ldrv_bad_code@PAGEOFF
    bl _drv_fatal

    .section __TEXT,__cstring,cstring_literals
Ldrv_diag_prefix:
    .asciz "baysick: "
Ldrv_usage_fmt:
    .asciz "usage: baysick <file.bas> [-o out] [-S] [--emit-ir] [--target arm64-macos] [--keep-temps]"
Ldrv_in_text:
    .asciz " IN "
Ldrv_bad_code:
    .asciz "frontend returned an unknown error code"

    .section __DATA,__const
    BSK_EMIT_ERRMSG_TABLE Ldrv_errmsg
