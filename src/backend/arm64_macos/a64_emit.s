// =====================================================================
// src/backend/arm64_macos/a64_emit.s -- module-level code generation for
// the arm64-macos backend (docs/DESIGN.md section 5.3 "Output skeleton").
//
// Exports: _bk_arm64_emit  (BKD_EMIT of _bk_arm64_macos_desc)
// Uses:    _bk_arm64_emit_func (a64_insn.s), _bk_arm64_fmt (a64_text.s),
//          _ob_puts / _ob_putu / _ob_putc (driver)
// =====================================================================
.include "baysick.inc"

.equ BK_BYTES_PER_LINE, 16          // string literal bytes per ".byte" line

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _bk_arm64_emit -- BKD_EMIT: append one complete assembly file for the
// Module to the OutBuf, in the order of DESIGN.md 5.3: text (main, then
// present FN functions in letter order), string literals, DATA block,
// array descriptors, zero-filled globals and array storage.
// In:  x0 = const Module*, x1 = OutBuf*
// Out: x0 = 0 on success, else pointer to a NUL-terminated reason
// Clobbers: x0-x17, d0-d7, d16-d31
// Callee-saved used: x19 = Module*, x20 = OutBuf*, x21 = loop index,
//                    x22 = pointer to the current table entry,
//                    x23 = loop limit, x24 = scratch kept across calls
//                    (string byte pointer / array element count)
//                    x25 = scratch kept across calls (string length /
//                    bytes left on the current .byte line)
// Frame: 80 bytes
// ---------------------------------------------------------------------
    .globl _bk_arm64_emit
    .p2align 2
_bk_arm64_emit:
    stp x29, x30, [sp, #-80]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    str x25, [sp, #64]
    mov x19, x0
    mov x20, x1

    // ---- text section header ------------------------------------------
    mov x0, x20
    adrp x1, Lbk_em_head@PAGE
    add x1, x1, Lbk_em_head@PAGEOFF
    bl _ob_puts

    // ---- main (function index 0) must exist ---------------------------
    add x9, x19, #IRM_FUNCS
    ldr w10, [x9, #IRF_PRESENT]
    cbnz w10, 1f
    adrp x0, Lbk_em_err_nomain@PAGE
    add x0, x0, Lbk_em_err_nomain@PAGEOFF
    b Lbk_em_return
1:
    mov x0, x20
    mov x1, x19
    mov x2, #FUNC_MAIN
    bl _bk_arm64_emit_func
    cbnz x0, Lbk_em_return

    // ---- FN functions, letter order -----------------------------------
    mov x21, #FUNC_FN_BASE
Lbk_em_fn_loop:
    // x22 = &funcs[x21]
    add x22, x19, #IRM_FUNCS
    mov x9, #IRF_SIZE
    madd x22, x21, x9, x22
    ldr w10, [x22, #IRF_PRESENT]
    cbz w10, Lbk_em_fn_next
    mov x0, x20
    mov x1, x19
    mov x2, x21
    bl _bk_arm64_emit_func
    cbnz x0, Lbk_em_return
Lbk_em_fn_next:
    add x21, x21, #1
    cmp x21, #NUM_FUNCS
    b.lo Lbk_em_fn_loop

    // ---- string literals: Lstr_<id> as decimal .byte lists ------------
    mov x0, x20
    adrp x1, Lbk_em_sec_str@PAGE
    add x1, x1, Lbk_em_sec_str@PAGEOFF
    bl _ob_puts
    ldr w23, [x19, #IRM_NSTRINGS]
    ldr x22, [x19, #IRM_STRINGS]
    mov x21, #0
Lbk_em_str_loop:
    cmp x21, x23
    b.hs Lbk_em_str_done
    // label line
    mov x0, x20
    adrp x1, Lbk_em_str_label@PAGE
    add x1, x1, Lbk_em_str_label@PAGEOFF
    mov x2, x21
    bl _bk_arm64_fmt
    ldr x24, [x22, #IRS_PTR]
    ldr w25, [x22, #IRS_LEN]
Lbk_em_str_line:
    // one ".byte" line of up to BK_BYTES_PER_LINE values
    cbz x25, Lbk_em_str_next
    mov x0, x20
    adrp x1, Lbk_em_byte_kw@PAGE
    add x1, x1, Lbk_em_byte_kw@PAGEOFF
    bl _ob_puts
    // x10 = bytes on this line (kept on the stack across the calls)
    mov x10, #BK_BYTES_PER_LINE
    cmp x25, x10
    csel x10, x25, x10, lo
    sub x25, x25, x10
    str x10, [sp, #72]
Lbk_em_str_byte:
    ldrb w1, [x24], #1
    mov x0, x20
    bl _ob_putu
    ldr x10, [sp, #72]
    subs x10, x10, #1
    str x10, [sp, #72]
    b.eq Lbk_em_str_eol
    // separator between values
    mov x0, x20
    adrp x1, Lbk_em_sep@PAGE
    add x1, x1, Lbk_em_sep@PAGEOFF
    bl _ob_puts
    b Lbk_em_str_byte
Lbk_em_str_eol:
    mov x0, x20
    mov w1, #10                 // LF
    bl _ob_putc
    b Lbk_em_str_line
Lbk_em_str_next:
    add x22, x22, #IRS_SIZE
    add x21, x21, #1
    b Lbk_em_str_loop
Lbk_em_str_done:

    // ---- DATA block -----------------------------------------------------
    mov x0, x20
    adrp x1, Lbk_em_data_head@PAGE
    add x1, x1, Lbk_em_data_head@PAGEOFF
    bl _ob_puts
    ldr w23, [x19, #IRM_NDATA]
    ldr x22, [x19, #IRM_DATA]
    mov x21, #0
Lbk_em_data_loop:
    cmp x21, x23
    b.hs Lbk_em_data_done
    // one ".quad 0x<bits>" per value, program order
    mov x0, x20
    adrp x1, Lbk_em_quad_hex@PAGE
    add x1, x1, Lbk_em_quad_hex@PAGEOFF
    ldr x2, [x22, x21, lsl #3]
    bl _bk_arm64_fmt
    add x21, x21, #1
    b Lbk_em_data_loop
Lbk_em_data_done:
    mov x0, x20
    adrp x1, Lbk_em_data_count@PAGE
    add x1, x1, Lbk_em_data_count@PAGEOFF
    mov x2, x23
    bl _bk_arm64_fmt

    // ---- array descriptors (RTA_*) in __DATA,__data ---------------------
    mov x0, x20
    adrp x1, Lbk_em_sec_data@PAGE
    add x1, x1, Lbk_em_sec_data@PAGEOFF
    bl _ob_puts
    mov x21, #0
Lbk_em_desc_loop:
    // x22 = &arrays[x21]
    add x22, x19, #IRM_ARRAYS
    add x22, x22, x21, lsl #4
    ldr w9, [x22, #IRA_DIMS]
    cbz w9, Lbk_em_desc_next
    cmp w9, #2
    b.hi Lbk_em_bad_dims
    // rowlen = b2 + 1 for tables, 1 for lists
    ldr w6, [x22, #IRA_B2]
    add w6, w6, #1
    cmp w9, #1
    mov w10, #1
    csel w6, w10, w6, eq
    // keep rowlen across the first call (frame scratch slot)
    str x6, [sp, #72]
    // "Ldesc_<L>:", ".quad _bsk_arr_<L>", ".long dims, b1, b2, " ...
    mov x0, x20
    adrp x1, Lbk_em_desc_fmt@PAGE
    add x1, x1, Lbk_em_desc_fmt@PAGEOFF
    mov x2, x21
    mov x3, x21
    mov w4, w9
    ldr w5, [x22, #IRA_B1]
    ldr w6, [x22, #IRA_B2]
    bl _bk_arm64_fmt
    // ... "rowlen, letter, 0"
    ldr x2, [sp, #72]
    mov x3, x21
    mov x0, x20
    adrp x1, Lbk_em_desc_tail@PAGE
    add x1, x1, Lbk_em_desc_tail@PAGEOFF
    bl _bk_arm64_fmt
Lbk_em_desc_next:
    add x21, x21, #1
    cmp x21, #NUM_LETTERS
    b.lo Lbk_em_desc_loop

    // ---- zero-filled globals --------------------------------------------
    ldr w9, [x19, #IRM_NSLOTS]
    lsl x2, x9, #3
    mov x0, x20
    adrp x1, Lbk_em_vars@PAGE
    add x1, x1, Lbk_em_vars@PAGEOFF
    bl _bk_arm64_fmt

    // ---- zero-filled array element storage ------------------------------
    mov x21, #0
Lbk_em_arr_loop:
    add x22, x19, #IRM_ARRAYS
    add x22, x22, x21, lsl #4
    ldr w9, [x22, #IRA_DIMS]
    cbz w9, Lbk_em_arr_next
    // bytes = 8 * (b1 + 1) * (b2 + 1)   (b2 = 0 for lists)
    ldr w10, [x22, #IRA_B1]
    ldr w11, [x22, #IRA_B2]
    add x10, x10, #1
    add x11, x11, #1
    mul x3, x10, x11
    lsl x3, x3, #3
    mov x0, x20
    adrp x1, Lbk_em_arr@PAGE
    add x1, x1, Lbk_em_arr@PAGEOFF
    mov x2, x21
    bl _bk_arm64_fmt
Lbk_em_arr_next:
    add x21, x21, #1
    cmp x21, #NUM_LETTERS
    b.lo Lbk_em_arr_loop

    mov x0, #0
    b Lbk_em_return

Lbk_em_bad_dims:
    adrp x0, Lbk_em_err_dims@PAGE
    add x0, x0, Lbk_em_err_dims@PAGEOFF
Lbk_em_return:
    ldr x25, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #80
    ret

    .section __TEXT,__cstring,cstring_literals
Lbk_em_head:
    .ascii "// generated by baysick\n"
    .ascii "    .section __TEXT,__text,regular,pure_instructions\n"
    .ascii "    .globl _bsk_program\n"
    .asciz "    .p2align 2\n"
Lbk_em_sec_str:
    .asciz "    .section __TEXT,__const\n"
Lbk_em_str_label:
    .asciz "Lstr_%u:\n"
Lbk_em_byte_kw:
    .asciz "    .byte "
Lbk_em_sep:
    .asciz ", "
Lbk_em_data_head:
    .ascii "    .section __DATA,__const\n"
    .ascii "    .globl _bsk_data\n"
    .ascii "    .p2align 3\n"
    .asciz "_bsk_data:\n"
Lbk_em_quad_hex:
    .asciz "    .quad %x\n"
Lbk_em_data_count:
    .ascii "    .globl _bsk_data_count\n"
    .ascii "_bsk_data_count:\n"
    .asciz "    .quad %u\n"
Lbk_em_sec_data:
    .ascii "    .section __DATA,__data\n"
    .asciz "    .p2align 3\n"
Lbk_em_desc_fmt:
    .ascii "Ldesc_%L:\n"
    .ascii "    .quad _bsk_arr_%L\n"
    .asciz "    .long %u, %u, %u, "
Lbk_em_desc_tail:
    .asciz "%u, %u, 0\n"
Lbk_em_vars:
    .asciz "    .zerofill __DATA,__bss,_bsk_vars,%u,3\n"
Lbk_em_arr:
    .asciz "    .zerofill __DATA,__bss,_bsk_arr_%L,%u,3\n"
Lbk_em_err_nomain:
    .asciz "arm64-macos backend: module has no main function"
Lbk_em_err_dims:
    .asciz "arm64-macos backend: array with more than 2 dimensions"
