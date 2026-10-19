// =====================================================================
// src/backend/arm64_macos/a64_text.s -- stateless text helpers for the
// arm64-macos backend: a tiny formatter and the two instruction shapes
// that need immediate splitting (mov of a wide constant, d-register
// load/store with a possibly out-of-range offset).
//
// Exports (AAPCS64, used by a64_emit.s and a64_insn.s):
//   _bk_arm64_fmt     formatted append to an OutBuf
//   _bk_arm64_movimm  movz/movk sequence building a constant
//   _bk_arm64_memop   ldr/str of a d register at [base, #off]
// =====================================================================
.include "baysick.inc"

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _bk_arm64_fmt -- append a formatted string to an OutBuf.
//   Directives (each consumes the next argument from x2, x3, ... x7):
//     %u  u64 in unsigned decimal         %s  NUL-terminated string
//     %L  letter: 'A' + argument (0..25)  %x  "0x" + 16 uppercase hex digits
//     %%  a literal '%'
//   Any other character after '%' is emitted literally (with the '%').
// In:  x0 = OutBuf*, x1 = NUL-terminated format, x2..x7 = arguments
// Out: none
// Clobbers: x0-x17, d0-d7, d16-d31 (calls _ob_*)
// Callee-saved used: x19 = OutBuf*, x20 = format cursor,
//                    x21 = next-argument pointer, x22 = start of the
//                    pending literal run
// Frame: 96 bytes (frame record, x19-x22, six spilled arguments at sp+48)
// ---------------------------------------------------------------------
    .globl _bk_arm64_fmt
    .p2align 2
_bk_arm64_fmt:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    // spill the variadic-style arguments so they can be walked in order
    stp x2, x3, [sp, #48]
    stp x4, x5, [sp, #64]
    stp x6, x7, [sp, #80]
    mov x19, x0
    mov x20, x1
    add x21, sp, #48
Lbk_fmt_run:
    // start a new literal run at the cursor
    mov x22, x20
Lbk_fmt_scan:
    ldrb w9, [x20]
    cbz w9, Lbk_fmt_finish
    cmp w9, #'%'
    b.eq Lbk_fmt_directive
    add x20, x20, #1
    b Lbk_fmt_scan
Lbk_fmt_directive:
    // flush the literal bytes before the '%'
    subs x2, x20, x22
    b.eq 1f
    mov x0, x19
    mov x1, x22
    bl _ob_putn
1:
    // w9 = directive character; skip "%c"
    ldrb w9, [x20, #1]
    cbz w9, Lbk_fmt_lonepct
    add x20, x20, #2
    cmp w9, #'u'
    b.eq Lbk_fmt_u
    cmp w9, #'s'
    b.eq Lbk_fmt_s
    cmp w9, #'L'
    b.eq Lbk_fmt_letter
    cmp w9, #'x'
    b.eq Lbk_fmt_hex
    cmp w9, #'%'
    b.eq Lbk_fmt_pct
    // unknown directive: emit both characters as text
    sub x1, x20, #2
    mov x2, #2
    mov x0, x19
    bl _ob_putn
    b Lbk_fmt_run
Lbk_fmt_u:
    // unsigned decimal argument
    ldr x1, [x21], #8
    mov x0, x19
    bl _ob_putu
    b Lbk_fmt_run
Lbk_fmt_s:
    // C-string argument
    ldr x1, [x21], #8
    mov x0, x19
    bl _ob_puts
    b Lbk_fmt_run
Lbk_fmt_letter:
    // letter index argument -> 'A'..'Z'
    ldr x1, [x21], #8
    add w1, w1, #'A'
    mov x0, x19
    bl _ob_putc
    b Lbk_fmt_run
Lbk_fmt_hex:
    // "0x" prefix, then exactly 16 hex digits of the argument
    mov x0, x19
    mov w1, #'0'
    bl _ob_putc
    mov x0, x19
    mov w1, #'x'
    bl _ob_putc
    ldr x1, [x21], #8
    mov x0, x19
    bl _ob_puthex16
    b Lbk_fmt_run
Lbk_fmt_pct:
    // "%%" -> '%'
    mov x0, x19
    mov w1, #'%'
    bl _ob_putc
    b Lbk_fmt_run
Lbk_fmt_lonepct:
    // a trailing '%' at the end of the format is emitted as text
    mov x0, x19
    mov w1, #'%'
    bl _ob_putc
    b Lbk_fmt_done
Lbk_fmt_finish:
    // flush the final literal run
    subs x2, x20, x22
    b.eq Lbk_fmt_done
    mov x0, x19
    mov x1, x22
    bl _ob_putn
Lbk_fmt_done:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret

// ---------------------------------------------------------------------
// _bk_arm64_movimm -- emit instructions that load a 64-bit constant:
//   "movz REG, #c, lsl #s" for the lowest non-zero 16-bit chunk (or
//   "movz REG, #0, lsl #0" for zero), then "movk REG, #c, lsl #s" for
//   each further non-zero chunk. For a w register the caller guarantees
//   value < 2^32 (only chunks 0 and 1 can then be non-zero).
// In:  x0 = OutBuf*, x1 = register name (e.g. "x16", "w17"), x2 = value
// Out: none
// Clobbers: x0-x17, d0-d7, d16-d31
// Callee-saved used: x19 = OutBuf*, x20 = register name, x21 = value,
//                    x22 = shift of the current chunk (0..48),
//                    x23 = mnemonic of the next instruction ("movz" until
//                          the first one is emitted, then "movk")
// Frame: 64 bytes
// ---------------------------------------------------------------------
    .globl _bk_arm64_movimm
    .p2align 2
_bk_arm64_movimm:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]
    mov x19, x0
    mov x20, x1
    mov x21, x2
    adrp x23, Lbk_mi_movz@PAGE
    add x23, x23, Lbk_mi_movz@PAGEOFF
    // zero has no non-zero chunk: a single movz #0
    cbnz x21, 1f
    mov x0, x19
    adrp x1, Lbk_mi_fmt@PAGE
    add x1, x1, Lbk_mi_fmt@PAGEOFF
    mov x2, x23
    mov x3, x20
    mov x4, #0
    mov x5, #0
    bl _bk_arm64_fmt
    b Lbk_mi_done
1:
    mov x22, #0
Lbk_mi_loop:
    // chunk = (value >> shift) & 0xFFFF; skip zero chunks
    lsr x4, x21, x22
    and x4, x4, #0xFFFF
    cbz x4, Lbk_mi_next
    mov x0, x19
    adrp x1, Lbk_mi_fmt@PAGE
    add x1, x1, Lbk_mi_fmt@PAGEOFF
    mov x2, x23
    mov x3, x20
    mov x5, x22
    bl _bk_arm64_fmt
    // every later chunk keeps the bits already built
    adrp x23, Lbk_mi_movk@PAGE
    add x23, x23, Lbk_mi_movk@PAGEOFF
Lbk_mi_next:
    add x22, x22, #16
    cmp x22, #64
    b.lo Lbk_mi_loop
Lbk_mi_done:
    ldr x23, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

// ---------------------------------------------------------------------
// _bk_arm64_memop -- emit a d-register load or store:
//   "MNEM dN, [BASE, #off]"            if off <= 32760 and off % 8 == 0
//   movz/movk x16 = off; "MNEM dN, [BASE, x16]"   otherwise
// In:  x0 = OutBuf*, x1 = mnemonic ("ldr"/"str"), x2 = d register number,
//      x3 = base register name ("sp"/"x19"), x4 = byte offset
// Out: none
// Clobbers: x0-x17, d0-d7, d16-d31
// Callee-saved used: x19 = OutBuf*, x20 = mnemonic, x21 = register
//                    number, x22 = base name, x23 = offset
// Frame: 64 bytes
// ---------------------------------------------------------------------
    .globl _bk_arm64_memop
    .p2align 2
_bk_arm64_memop:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x23, x4
    // the scaled unsigned 12-bit immediate reaches 8*4095 = 32760
    tst x23, #7
    b.ne Lbk_mo_reg
    mov x9, #32760
    cmp x23, x9
    b.hi Lbk_mo_reg
    mov x0, x19
    adrp x1, Lbk_mo_imm_fmt@PAGE
    add x1, x1, Lbk_mo_imm_fmt@PAGEOFF
    mov x2, x20
    mov x3, x21
    mov x4, x22
    mov x5, x23
    bl _bk_arm64_fmt
    b Lbk_mo_done
Lbk_mo_reg:
    // materialise the offset in x16 and use a register offset
    mov x0, x19
    adrp x1, Lbk_mo_x16@PAGE
    add x1, x1, Lbk_mo_x16@PAGEOFF
    mov x2, x23
    bl _bk_arm64_movimm
    mov x0, x19
    adrp x1, Lbk_mo_reg_fmt@PAGE
    add x1, x1, Lbk_mo_reg_fmt@PAGEOFF
    mov x2, x20
    mov x3, x21
    mov x4, x22
    bl _bk_arm64_fmt
Lbk_mo_done:
    ldr x23, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

    .section __TEXT,__cstring,cstring_literals
Lbk_mi_fmt:
    .asciz "    %s %s, #%u, lsl #%u\n"
Lbk_mi_movz:
    .asciz "movz"
Lbk_mi_movk:
    .asciz "movk"
Lbk_mo_imm_fmt:
    .asciz "    %s d%u, [%s, #%u]\n"
Lbk_mo_reg_fmt:
    .asciz "    %s d%u, [%s, x16]\n"
Lbk_mo_x16:
    .asciz "x16"
