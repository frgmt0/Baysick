// =====================================================================
// src/backend/x86_64_linux/x64_emit.s -- module-level code generation
// for the x86_64-linux backend (docs/DESIGN.md section 5.4.3 "Output
// skeleton"). Emits GNU as AT&T x86_64 ELF text.
//
// Exports: _bk_x64_emit  (BKD_EMIT of _bk_x86_64_linux_desc)
// Uses:    _bk_x64_emit_func (x64_insn.s), _bk_x64_fmt, _bk_x64_bytes
//          (x64_text.s), _ob_puts (driver)
// =====================================================================
.include "baysick.inc"

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _bk_x64_emit -- BKD_EMIT: append one complete GNU as file for the
// Module to the OutBuf, in the order of DESIGN.md 5.4.3: .text (main as
// bsk_program, then present FN functions in letter order), .rodata
// (string literals, DATA block, count), .data (array descriptors), .bss
// (globals, array storage), and the .note.GNU-stack marker.
// In:  x0 = const Module*, x1 = OutBuf*
// Out: x0 = 0 on success, else pointer to a NUL-terminated reason
// Clobbers: x0-x17, d0-d7, d16-d31
// Callee-saved used: x19 = Module*, x20 = OutBuf*, x21 = loop index,
//                    x22 = pointer to the current table entry,
//                    x23 = loop limit
// Frame: 48 bytes
// ---------------------------------------------------------------------
    .globl _bk_x64_emit
    .p2align 2
_bk_x64_emit:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #40]
    mov x19, x0
    mov x20, x1

    // ---- file comment and text section header ----------------------
    mov x0, x20
    adrp x1, Lbk_x64_em_head@PAGE
    add x1, x1, Lbk_x64_em_head@PAGEOFF
    bl _ob_puts

    // ---- main (function index 0) must exist ---------------------------
    add x9, x19, #IRM_FUNCS
    ldr w10, [x9, #IRF_PRESENT]
    cbnz w10, 1f
    adrp x0, Lbk_x64_em_err_nomain@PAGE
    add x0, x0, Lbk_x64_em_err_nomain@PAGEOFF
    b Lbk_x64_em_return
1:
    mov x0, x20
    mov x1, x19
    mov x2, #FUNC_MAIN
    bl _bk_x64_emit_func
    cbnz x0, Lbk_x64_em_return

    // ---- FN functions, letter order -----------------------------------
    mov x21, #FUNC_FN_BASE
Lbk_x64_em_fn_loop:
    // x22 = &funcs[x21]
    add x22, x19, #IRM_FUNCS
    mov x9, #IRF_SIZE
    madd x22, x21, x9, x22
    ldr w10, [x22, #IRF_PRESENT]
    cbz w10, Lbk_x64_em_fn_next
    mov x0, x20
    mov x1, x19
    mov x2, x21
    bl _bk_x64_emit_func
    cbnz x0, Lbk_x64_em_return
Lbk_x64_em_fn_next:
    add x21, x21, #1
    cmp x21, #NUM_FUNCS
    b.lo Lbk_x64_em_fn_loop

    // ---- .rodata: string literals .Lstr_<id> as decimal .byte lists ---
    mov x0, x20
    adrp x1, Lbk_x64_em_sec_rodata@PAGE
    add x1, x1, Lbk_x64_em_sec_rodata@PAGEOFF
    bl _ob_puts
    ldr w23, [x19, #IRM_NSTRINGS]
    ldr x22, [x19, #IRM_STRINGS]
    mov x21, #0
Lbk_x64_em_str_loop:
    cmp x21, x23
    b.hs Lbk_x64_em_str_done
    // label line, then the bytes (an empty literal is the label alone)
    mov x0, x20
    adrp x1, Lbk_x64_em_str_label@PAGE
    add x1, x1, Lbk_x64_em_str_label@PAGEOFF
    mov x2, x21
    bl _bk_x64_fmt
    mov x0, x20
    ldr x1, [x22, #IRS_PTR]
    ldr w2, [x22, #IRS_LEN]
    bl _bk_x64_bytes
    add x22, x22, #IRS_SIZE
    add x21, x21, #1
    b Lbk_x64_em_str_loop
Lbk_x64_em_str_done:

    // ---- DATA block: bsk_data, one .quad of IEEE bits per value -------
    mov x0, x20
    adrp x1, Lbk_x64_em_data_head@PAGE
    add x1, x1, Lbk_x64_em_data_head@PAGEOFF
    bl _ob_puts
    ldr w23, [x19, #IRM_NDATA]
    ldr x22, [x19, #IRM_DATA]
    mov x21, #0
Lbk_x64_em_data_loop:
    cmp x21, x23
    b.hs Lbk_x64_em_data_done
    // program order; the raw bits keep -0 distinct from 0
    mov x0, x20
    adrp x1, Lbk_x64_em_quad_hex@PAGE
    add x1, x1, Lbk_x64_em_quad_hex@PAGEOFF
    ldr x2, [x22, x21, lsl #3]
    bl _bk_x64_fmt
    add x21, x21, #1
    b Lbk_x64_em_data_loop
Lbk_x64_em_data_done:
    // bsk_data_count
    mov x0, x20
    adrp x1, Lbk_x64_em_data_count@PAGE
    add x1, x1, Lbk_x64_em_data_count@PAGEOFF
    mov x2, x23
    bl _bk_x64_fmt

    // ---- .data: array descriptors (RTA_*), letter order ----------------
    mov x0, x20
    adrp x1, Lbk_x64_em_sec_data@PAGE
    add x1, x1, Lbk_x64_em_sec_data@PAGEOFF
    bl _ob_puts
    mov x21, #0
Lbk_x64_em_desc_loop:
    // x22 = &arrays[x21]
    add x22, x19, #IRM_ARRAYS
    add x22, x22, x21, lsl #4
    ldr w9, [x22, #IRA_DIMS]
    cbz w9, Lbk_x64_em_desc_next
    cmp w9, #2
    b.hi Lbk_x64_em_bad_dims
    // rowlen (x6) = b2 + 1 for tables, 1 for lists
    ldr w6, [x22, #IRA_B2]
    add w6, w6, #1
    cmp w9, #1
    mov w10, #1
    csel w6, w10, w6, eq
    // ".Ldesc_<L>:", ".quad .Lbsk_arr_<L>",
    // ".long dims, b1, b2, rowlen, letter, cap"
    mov x0, x20
    adrp x1, Lbk_x64_em_desc_fmt@PAGE
    add x1, x1, Lbk_x64_em_desc_fmt@PAGEOFF
    mov x2, x21
    mov x3, x21
    mov w4, w9
    ldr w5, [x22, #IRA_B1]
    mov w7, w6
    ldr w6, [x22, #IRA_B2]
    // six fields fit x2..x7; the helper appends ", <letter>, <cap>"
    bl Lbk_x64_em_desc_call
Lbk_x64_em_desc_next:
    add x21, x21, #1
    cmp x21, #NUM_LETTERS
    b.lo Lbk_x64_em_desc_loop

    // ---- .bss: the NSLOTS global cells -----------------------------------
    ldr w9, [x19, #IRM_NSLOTS]
    lsl x2, x9, #3
    mov x0, x20
    adrp x1, Lbk_x64_em_vars@PAGE
    add x1, x1, Lbk_x64_em_vars@PAGEOFF
    bl _bk_x64_fmt

    // ---- .bss: zero-filled array element storage, letter order -----------
    mov x21, #0
Lbk_x64_em_arr_loop:
    add x22, x19, #IRM_ARRAYS
    add x22, x22, x21, lsl #4
    ldr w9, [x22, #IRA_DIMS]
    cbz w9, Lbk_x64_em_arr_next
    // bytes = 8 * (b1 + 1) * (b2 + 1)   (b2 = 0 for lists)
    ldr w10, [x22, #IRA_B1]
    ldr w11, [x22, #IRA_B2]
    add x10, x10, #1
    add x11, x11, #1
    mul x3, x10, x11
    lsl x3, x3, #3
    mov x0, x20
    adrp x1, Lbk_x64_em_arr@PAGE
    add x1, x1, Lbk_x64_em_arr@PAGEOFF
    mov x2, x21
    bl _bk_x64_fmt
Lbk_x64_em_arr_next:
    add x21, x21, #1
    cmp x21, #NUM_LETTERS
    b.lo Lbk_x64_em_arr_loop

    // ---- non-executable stack marker (last line of the file) -------------
    mov x0, x20
    adrp x1, Lbk_x64_em_tail@PAGE
    add x1, x1, Lbk_x64_em_tail@PAGEOFF
    bl _ob_puts

    mov x0, #0
    b Lbk_x64_em_return

Lbk_x64_em_bad_dims:
    adrp x0, Lbk_x64_em_err_dims@PAGE
    add x0, x0, Lbk_x64_em_err_dims@PAGEOFF
Lbk_x64_em_return:
    ldr x23, [sp, #40]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// Lbk_x64_em_desc_call -- file-local: format one array descriptor.
// Private convention: x0 = OutBuf*, x1 = format, x2 = letter (label),
// x3 = letter (storage label), x4 = dims, x5 = b1, x6 = b2, x7 = rowlen,
// x21 = letter (the RTA_LETTER field), x22 = the IRA entry. Calls _bk_x64_fmt with the six
// register arguments x2..x7 followed by the letter: _bk_x64_fmt reads
// only x2..x7, so the letter is emitted by a second call.
// Clobbers: x0-x17, d0-d7, d16-d31
// Callee-saved used: x19 (saved; holds the OutBuf* for the second call)
// Frame: 32 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lbk_x64_em_desc_call:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov x19, x0
    bl _bk_x64_fmt
    // ", <letter>, <cap>" closes the .long line; cap = (b1+1)*(b2+1)
    ldr w9, [x22, #IRA_B1]
    ldr w10, [x22, #IRA_B2]
    add x9, x9, #1
    add x10, x10, #1
    mul x3, x9, x10
    mov x0, x19
    adrp x1, Lbk_x64_em_desc_tail@PAGE
    add x1, x1, Lbk_x64_em_desc_tail@PAGEOFF
    mov x2, x21
    bl _bk_x64_fmt
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

    .section __TEXT,__cstring,cstring_literals
Lbk_x64_em_head:
    .ascii "# generated by baysick\n"
    .ascii "    .text\n"
    .ascii "    .globl bsk_program\n"
    .ascii "    .type bsk_program, @function\n"
    .asciz "    .p2align 4\n"
Lbk_x64_em_sec_rodata:
    .asciz "    .section .rodata\n"
Lbk_x64_em_str_label:
    .asciz ".Lstr_%u:\n"
Lbk_x64_em_data_head:
    .ascii "    .p2align 3\n"
    .ascii "    .globl bsk_data\n"
    .ascii "    .type bsk_data, @object\n"
    .asciz "bsk_data:\n"
Lbk_x64_em_quad_hex:
    .asciz "    .quad %x\n"
Lbk_x64_em_data_count:
    .ascii "    .globl bsk_data_count\n"
    .ascii "    .type bsk_data_count, @object\n"
    .ascii "bsk_data_count:\n"
    .asciz "    .quad %u\n"
Lbk_x64_em_sec_data:
    .ascii "    .data\n"
    .asciz "    .p2align 3\n"
Lbk_x64_em_desc_fmt:
    .ascii ".Ldesc_%L:\n"
    .ascii "    .quad .Lbsk_arr_%L\n"
    .asciz "    .long %u, %u, %u, %u"
Lbk_x64_em_desc_tail:
    .asciz ", %u, %u\n"
Lbk_x64_em_vars:
    .ascii "    .bss\n"
    .ascii "    .p2align 3\n"
    .ascii ".Lbsk_vars:\n"
    .asciz "    .zero %u\n"
Lbk_x64_em_arr:
    .ascii "    .p2align 3\n"
    .ascii ".Lbsk_arr_%L:\n"
    .asciz "    .zero %u\n"
Lbk_x64_em_tail:
    .asciz "    .section .note.GNU-stack,\"\",@progbits\n"
Lbk_x64_em_err_nomain:
    .asciz "x86_64-linux backend: module has no main function"
Lbk_x64_em_err_dims:
    .asciz "x86_64-linux backend: array with more than 2 dimensions"
