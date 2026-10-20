// =====================================================================
// src/backend/x86_64_linux/x64_text.s -- stateless text helpers for the
// x86_64-linux backend: a tiny formatter for x86 operands/immediates and
// the decimal ".byte" list writer used for string literals
// (docs/DESIGN.md section 5.4.2-5.4.3).
//
// This file is arm64 code for Apple as (part of the compiler); the text
// it produces is GNU as AT&T x86_64 assembly.
//
// Exports (AAPCS64, used by x64_emit.s and x64_insn.s):
//   _bk_x64_fmt     formatted append to an OutBuf
//   _bk_x64_bytes   "    .byte a, b, ..." lines (decimal, <= 16 per line)
// =====================================================================
.include "baysick.inc"

.equ BK_X64_BYTES_PER_LINE, 16      // string literal bytes per ".byte" line

// Label key of %B (x64_insn.s builds it the same way): function index in
// the low 5 bits (0..26), SUB unit index + 1 above them (0 = main module).
.equ BK_X64_KEY_UNIT_SHIFT, 5
.equ BK_X64_KEY_FUNC_MASK,  31
.if NUM_FUNCS > BK_X64_KEY_FUNC_MASK + 1
    .error "x64_text.s label key: function index does not fit 5 bits"
.endif

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _bk_x64_fmt -- append a formatted string to an OutBuf.
//   Directives (each consumes the next argument from x2, x3, ... x7):
//     %u  u64 in unsigned decimal         %s  NUL-terminated string
//     %L  letter: 'A' + argument (0..25)  %x  "0x" + 16 uppercase hex digits
//     %B  label base of a function (argument = label key: function index
//         + 32 * (SUB unit + 1), the unit part 0 in the main module): main
//         gives ".Lbsk_L", FN L ".Lfn_<L>_L", the SUB body of unit u
//         ".Lsub_<u>_L", FN L of unit u ".Lsub_<u>_fn_<L>_L"; the label id
//         follows as a separate %u
//     %%  a literal '%' (AT&T register names are written "%%rax")
//   Any other character after '%' is emitted literally (with the '%').
// In:  x0 = OutBuf*, x1 = NUL-terminated format, x2..x7 = arguments
// Out: none
// Clobbers: x0-x17, d0-d7, d16-d31 (calls _ob_*)
// Callee-saved used: x19 = OutBuf*, x20 = format cursor,
//                    x21 = next-argument pointer, x22 = start of the
//                    pending literal run
// Frame: 96 bytes (frame record, x19-x22, six spilled arguments at sp+48)
// ---------------------------------------------------------------------
    .globl _bk_x64_fmt
    .p2align 2
_bk_x64_fmt:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    // spill the arguments so they can be walked in order
    stp x2, x3, [sp, #48]
    stp x4, x5, [sp, #64]
    stp x6, x7, [sp, #80]
    mov x19, x0
    mov x20, x1
    add x21, sp, #48
Lbk_x64_fmt_run:
    // start a new literal run at the cursor
    mov x22, x20
Lbk_x64_fmt_scan:
    ldrb w9, [x20]
    cbz w9, Lbk_x64_fmt_finish
    cmp w9, #'%'
    b.eq Lbk_x64_fmt_directive
    add x20, x20, #1
    b Lbk_x64_fmt_scan
Lbk_x64_fmt_directive:
    // flush the literal bytes before the '%'
    subs x2, x20, x22
    b.eq 1f
    mov x0, x19
    mov x1, x22
    bl _ob_putn
1:
    // w9 = directive character; skip "%c"
    ldrb w9, [x20, #1]
    cbz w9, Lbk_x64_fmt_lonepct
    add x20, x20, #2
    cmp w9, #'u'
    b.eq Lbk_x64_fmt_u
    cmp w9, #'s'
    b.eq Lbk_x64_fmt_s
    cmp w9, #'L'
    b.eq Lbk_x64_fmt_letter
    cmp w9, #'x'
    b.eq Lbk_x64_fmt_hex
    cmp w9, #'B'
    b.eq Lbk_x64_fmt_base
    cmp w9, #'%'
    b.eq Lbk_x64_fmt_pct
    // unknown directive: emit both characters as text
    sub x1, x20, #2
    mov x2, #2
    mov x0, x19
    bl _ob_putn
    b Lbk_x64_fmt_run
Lbk_x64_fmt_u:
    // unsigned decimal argument
    ldr x1, [x21], #8
    mov x0, x19
    bl _ob_putu
    b Lbk_x64_fmt_run
Lbk_x64_fmt_s:
    // C-string argument
    ldr x1, [x21], #8
    mov x0, x19
    bl _ob_puts
    b Lbk_x64_fmt_run
Lbk_x64_fmt_letter:
    // letter index argument -> 'A'..'Z'
    ldr x1, [x21], #8
    add w1, w1, #'A'
    mov x0, x19
    bl _ob_putc
    b Lbk_x64_fmt_run
Lbk_x64_fmt_hex:
    // "0x" prefix, then exactly 16 uppercase hex digits of the argument
    mov x0, x19
    mov w1, #'0'
    bl _ob_putc
    mov x0, x19
    mov w1, #'x'
    bl _ob_putc
    ldr x1, [x21], #8
    mov x0, x19
    bl _ob_puthex16
    b Lbk_x64_fmt_run
Lbk_x64_fmt_base:
    // label base from a label key (BK_X64_KEY_*): bits 0-4 = function index,
    // the bits above = SUB unit index + 1 (0 = the main module).
    // Main module: index 0 -> ".Lbsk_L", index 1+L -> ".Lfn_<L>_L".
    // Unit u: index 0 -> ".Lsub_<u>_L", index 1+L -> ".Lsub_<u>_fn_<L>_L".
    // (x22, the literal-run start, is dead until Lbk_x64_fmt_run resets it)
    ldr x22, [x21], #8
    lsr x9, x22, #BK_X64_KEY_UNIT_SHIFT
    cbz x9, Lbk_x64_fmt_base_module
    // ".Lsub_<u>" with u = unit field - 1
    mov x0, x19
    adrp x1, Lbk_x64_fmt_s_sub@PAGE
    add x1, x1, Lbk_x64_fmt_s_sub@PAGEOFF
    bl _ob_puts
    lsr x1, x22, #BK_X64_KEY_UNIT_SHIFT
    sub x1, x1, #1
    mov x0, x19
    bl _ob_putu
    and x22, x22, #BK_X64_KEY_FUNC_MASK
    cbz x22, Lbk_x64_fmt_base_sfx   // the SUB body: ".Lsub_<u>_L"
    // a function of the unit: "_fn_<L>_L"
    mov x0, x19
    adrp x1, Lbk_x64_fmt_s_unitfn@PAGE
    add x1, x1, Lbk_x64_fmt_s_unitfn@PAGEOFF
    bl _ob_puts
    b Lbk_x64_fmt_base_letter
Lbk_x64_fmt_base_module:
    mov x0, x19
    cbz x22, Lbk_x64_fmt_base_main
    adrp x1, Lbk_x64_fmt_s_fn@PAGE
    add x1, x1, Lbk_x64_fmt_s_fn@PAGEOFF
    bl _ob_puts
Lbk_x64_fmt_base_letter:
    // the function letter, then "_L"
    sub w1, w22, #1
    add w1, w1, #'A'
    mov x0, x19
    bl _ob_putc
Lbk_x64_fmt_base_sfx:
    mov x0, x19
    adrp x1, Lbk_x64_fmt_s_sfx@PAGE
    add x1, x1, Lbk_x64_fmt_s_sfx@PAGEOFF
    bl _ob_puts
    b Lbk_x64_fmt_run
Lbk_x64_fmt_base_main:
    adrp x1, Lbk_x64_fmt_s_main@PAGE
    add x1, x1, Lbk_x64_fmt_s_main@PAGEOFF
    bl _ob_puts
    b Lbk_x64_fmt_run
Lbk_x64_fmt_pct:
    // "%%" -> '%'
    mov x0, x19
    mov w1, #'%'
    bl _ob_putc
    b Lbk_x64_fmt_run
Lbk_x64_fmt_lonepct:
    // a trailing '%' at the end of the format is emitted as text
    mov x0, x19
    mov w1, #'%'
    bl _ob_putc
    b Lbk_x64_fmt_done
Lbk_x64_fmt_finish:
    // flush the final literal run
    subs x2, x20, x22
    b.eq Lbk_x64_fmt_done
    mov x0, x19
    mov x1, x22
    bl _ob_putn
Lbk_x64_fmt_done:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret

// ---------------------------------------------------------------------
// _bk_x64_bytes -- emit a byte string as GNU as data lines:
//   "    .byte 65, 32, 61\n", at most 16 decimal values per line.
//   Nothing is emitted for an empty string.
// In:  x0 = OutBuf*, x1 = bytes, x2 = length
// Out: none
// Clobbers: x0-x17, d0-d7, d16-d31
// Callee-saved used: x19 = OutBuf*, x20 = byte cursor, x21 = bytes left
//                    in the string, x22 = bytes left on the current line
// Frame: 48 bytes
// ---------------------------------------------------------------------
    .globl _bk_x64_bytes
    .p2align 2
_bk_x64_bytes:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov x19, x0
    mov x20, x1
    mov x21, x2
Lbk_x64_bytes_line:
    // start a new ".byte" line while bytes remain
    cbz x21, Lbk_x64_bytes_done
    mov x0, x19
    adrp x1, Lbk_x64_bytes_kw@PAGE
    add x1, x1, Lbk_x64_bytes_kw@PAGEOFF
    bl _ob_puts
    // x22 = min(left, 16) values on this line
    mov x22, #BK_X64_BYTES_PER_LINE
    cmp x21, x22
    csel x22, x21, x22, lo
    sub x21, x21, x22
Lbk_x64_bytes_one:
    // one decimal value
    ldrb w1, [x20], #1
    mov x0, x19
    bl _ob_putu
    subs x22, x22, #1
    b.eq Lbk_x64_bytes_eol
    // separator between values on the same line
    mov x0, x19
    adrp x1, Lbk_x64_bytes_sep@PAGE
    add x1, x1, Lbk_x64_bytes_sep@PAGEOFF
    bl _ob_puts
    b Lbk_x64_bytes_one
Lbk_x64_bytes_eol:
    mov x0, x19
    mov w1, #10                     // LF
    bl _ob_putc
    b Lbk_x64_bytes_line
Lbk_x64_bytes_done:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

    .section __TEXT,__cstring,cstring_literals
Lbk_x64_fmt_s_main:
    .asciz ".Lbsk_L"
Lbk_x64_fmt_s_fn:
    .asciz ".Lfn_"
Lbk_x64_fmt_s_sfx:
    .asciz "_L"
Lbk_x64_fmt_s_sub:
    .asciz ".Lsub_"
Lbk_x64_fmt_s_unitfn:
    .asciz "_fn_"

Lbk_x64_bytes_kw:
    .asciz "    .byte "
Lbk_x64_bytes_sep:
    .asciz ", "
