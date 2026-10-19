// =====================================================================
// src/driver/outbuf.s -- growable text output buffers (driver.inc OB_*).
//
// The data block is malloc'd and grown with realloc (doubling). A zeroed
// OutBuf (data NULL, cap 0) is also valid: the first append allocates.
// All functions follow AAPCS64 and preserve x19-x28 and d8-d15.
// Allocation failure exits through _drv_oom.
// =====================================================================
.include "baysick.inc"

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _ob_init -- make an empty buffer with OB_INITIAL_CAP bytes of room.
//   in:  x0 = OutBuf*
//   out: none
//   clobbers: x0-x17
//   callee-saved: x19 = OutBuf*
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .globl _ob_init
    .p2align 2
_ob_init:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov x19, x0
    mov x0, #OB_INITIAL_CAP
    bl _malloc
    cbz x0, Lob_init_oom
    // data = block, len = 0, cap = OB_INITIAL_CAP
    str x0, [x19, #OB_DATA]
    str xzr, [x19, #OB_LEN]
    mov x9, #OB_INITIAL_CAP
    str x9, [x19, #OB_CAP]
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
Lob_init_oom:
    bl _drv_oom

// ---------------------------------------------------------------------
// _ob_reserve -- make room for n more bytes (driver-internal helper,
// also usable by any module through the normal ABI).
//   in:  x0 = OutBuf*, x1 = n
//   out: x0 = pointer where the next byte goes (data + len); len unchanged
//   clobbers: x0-x17
//   callee-saved: x19 = OutBuf*, x20 = required total length
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .globl _ob_reserve
    .p2align 2
_ob_reserve:
    ldp x9, x10, [x0, #OB_LEN]          // x9 = len, x10 = cap
    add x11, x9, x1                     // required length
    cmp x11, x10
    b.hi Lob_reserve_grow
    // fast path: enough room already
    ldr x12, [x0, #OB_DATA]
    add x0, x12, x9
    ret
Lob_reserve_grow:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    mov x20, x11
    // new capacity = max(2*cap, required, OB_INITIAL_CAP)
    lsl x1, x10, #1
    cmp x1, x20
    csel x1, x1, x20, hs
    mov x9, #OB_INITIAL_CAP
    cmp x1, x9
    csel x1, x1, x9, hs
    str x1, [sp, #-16]!                 // keep the new capacity across realloc
    ldr x0, [x19, #OB_DATA]
    bl _realloc
    ldr x1, [sp], #16
    cbz x0, Lob_reserve_oom
    str x0, [x19, #OB_DATA]
    str x1, [x19, #OB_CAP]
    // return data + len
    ldr x9, [x19, #OB_LEN]
    add x0, x0, x9
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
Lob_reserve_oom:
    bl _drv_oom

// ---------------------------------------------------------------------
// _ob_putc -- append one byte.
//   in:  x0 = OutBuf*, w1 = byte
//   out: none
//   clobbers: x0-x17
//   callee-saved: x19 = OutBuf*, x20 = byte
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .globl _ob_putc
    .p2align 2
_ob_putc:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    mov w20, w1
    mov x1, #1
    bl _ob_reserve
    // store the byte and bump len
    strb w20, [x0]
    ldr x9, [x19, #OB_LEN]
    add x9, x9, #1
    str x9, [x19, #OB_LEN]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _ob_putn -- append len bytes.
//   in:  x0 = OutBuf*, x1 = ptr, x2 = len
//   out: none
//   clobbers: x0-x17
//   callee-saved: x19 = OutBuf*, x20 = ptr, x21 = len
//   frame: 48 bytes
// ---------------------------------------------------------------------
    .globl _ob_putn
    .p2align 2
_ob_putn:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov x19, x0
    mov x20, x1
    mov x21, x2
    cbz x21, Lob_putn_done              // nothing to append
    mov x1, x21
    bl _ob_reserve
    // copy into place
    mov x1, x20
    mov x2, x21
    bl _memcpy
    ldr x9, [x19, #OB_LEN]
    add x9, x9, x21
    str x9, [x19, #OB_LEN]
Lob_putn_done:
    ldp x19, x20, [sp, #16]
    ldr x21, [sp, #32]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// _ob_puts -- append a NUL-terminated string (without the NUL).
//   in:  x0 = OutBuf*, x1 = string
//   out: none
//   clobbers: x0-x17
//   callee-saved: x19 = OutBuf*, x20 = string
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .globl _ob_puts
    .p2align 2
_ob_puts:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    mov x20, x1
    mov x0, x1
    bl _strlen
    // putn(ob, s, strlen(s))
    mov x2, x0
    mov x0, x19
    mov x1, x20
    bl _ob_putn
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _ob_putu -- append an unsigned decimal number (no padding).
//   in:  x0 = OutBuf*, x1 = u64
//   out: none
//   clobbers: x0-x17
//   callee-saved: none
//   frame: 48 bytes (frame record + 32-byte digit buffer at [sp,#16])
// ---------------------------------------------------------------------
    .globl _ob_putu
    .p2align 2
_ob_putu:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    // digits are produced backwards from the end of the buffer
    add x9, sp, #48                     // one past the buffer end
    mov x10, x9
    mov x11, #10
1:
    udiv x12, x1, x11                   // q = n / 10
    msub x13, x12, x11, x1              // r = n - q*10
    add w13, w13, #'0'
    strb w13, [x10, #-1]!
    mov x1, x12
    cbnz x1, 1b                         // at least one digit ("0")
    // putn(ob, first digit, count)
    mov x1, x10
    sub x2, x9, x10
    bl _ob_putn
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// _ob_puti -- append a signed decimal number ('-' if negative).
//   in:  x0 = OutBuf*, x1 = s64
//   out: none
//   clobbers: x0-x17
//   callee-saved: x19 = OutBuf*, x20 = value
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .globl _ob_puti
    .p2align 2
_ob_puti:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    mov x20, x1
    tbz x20, #63, 1f
    // negative: sign, then the magnitude as unsigned (works for INT64_MIN)
    mov w1, #'-'
    bl _ob_putc
    neg x20, x20
1:
    mov x0, x19
    mov x1, x20
    bl _ob_putu
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _ob_puthex16 -- append exactly 16 uppercase hexadecimal digits.
//   in:  x0 = OutBuf*, x1 = u64
//   out: none
//   clobbers: x0-x17
//   callee-saved: none
//   frame: 32 bytes (frame record + 16-byte digit buffer at [sp,#16])
// ---------------------------------------------------------------------
    .globl _ob_puthex16
    .p2align 2
_ob_puthex16:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    add x9, sp, #32                     // fill backwards from the end
    mov x10, #16                        // digit count
1:
    and x11, x1, #0xF
    cmp x11, #10
    // '0'..'9' or 'A'..'F'
    add x12, x11, #'0'
    add x13, x11, #('A' - 10)
    csel x12, x12, x13, lo
    strb w12, [x9, #-1]!
    lsr x1, x1, #4
    subs x10, x10, #1
    b.ne 1b
    mov x1, x9
    mov x2, #16
    bl _ob_putn
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _ob_putg17 -- append a double formatted exactly like printf("%.17g").
//   in:  x0 = OutBuf*, d0 = value
//   out: none
//   clobbers: x0-x17, d0-d7, d16-d31
//   callee-saved: x19 = OutBuf*
//   frame: 16-byte frame record + 96 bytes of locals: [sp] variadic slot
//          for snprintf, [sp,#16] saved x19, [sp,#32..#95] text buffer
// ---------------------------------------------------------------------
    .globl _ob_putg17
    .p2align 2
_ob_putg17:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    sub sp, sp, #96
    str x19, [sp, #16]
    mov x19, x0
    // snprintf(buf, 64, "%.17g", value): the double is variadic -> [sp]
    str d0, [sp]
    add x0, sp, #32
    mov x1, #64
    adrp x2, Lob_g17_fmt@PAGE
    add x2, x2, Lob_g17_fmt@PAGEOFF
    bl _snprintf
    // append the produced text (snprintf returns its length, < 64 here)
    mov x2, x0
    add x1, sp, #32
    mov x0, x19
    bl _ob_putn
    ldr x19, [sp, #16]
    add sp, sp, #96
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// _ob_write_fd -- write the whole buffer to a file descriptor.
//   in:  x0 = OutBuf*, w1 = fd
//   out: x0 = 0 on success, -1 on a write error (errno is set)
//   clobbers: x0-x17
//   callee-saved: x19 = cursor, x20 = bytes remaining, x21 = fd
//   frame: 48 bytes
// ---------------------------------------------------------------------
    .globl _ob_write_fd
    .p2align 2
_ob_write_fd:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    ldr x19, [x0, #OB_DATA]
    ldr x20, [x0, #OB_LEN]
    mov w21, w1
Lob_write_loop:
    cbz x20, Lob_write_ok
    mov w0, w21
    mov x1, x19
    mov x2, x20
    bl _write
    tbnz x0, #63, Lob_write_err
    // partial writes advance the cursor and continue
    add x19, x19, x0
    sub x20, x20, x0
    b Lob_write_loop
Lob_write_err:
    // retry on EINTR, otherwise fail
    bl ___error
    ldr w9, [x0]
    cmp w9, #4                          // EINTR
    b.eq Lob_write_loop
    mov x0, #-1
    b Lob_write_done
Lob_write_ok:
    mov x0, #0
Lob_write_done:
    ldp x19, x20, [sp, #16]
    ldr x21, [sp, #32]
    ldp x29, x30, [sp], #48
    ret

    .section __TEXT,__cstring,cstring_literals
Lob_g17_fmt:
    .asciz "%.17g"
