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
// present FN functions in letter order), string literals and string DATA
// bytes, DATA block, string descriptors and string DATA records, array and
// string-list descriptors, zero-filled globals, string variables and
// array / string-list storage.
// In:  x0 = const Module*, x1 = OutBuf*
// Out: x0 = 0 on success, else pointer to a NUL-terminated reason
// Clobbers: x0-x17, d0-d7, d16-d31
// Callee-saved used: x19 = Module*, x20 = OutBuf*, x21 = loop index,
//                    x22 = pointer to the current table entry,
//                    x23 = loop limit (also NSDATA for the count line),
//                    x24, x25 = saved but unused
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
    mov x0, x20
    adrp x1, Lbk_em_str_label@PAGE
    add x1, x1, Lbk_em_str_label@PAGEOFF
    mov x2, x21
    ldr x3, [x22, #IRS_PTR]
    ldr w4, [x22, #IRS_LEN]
    bl Lbk_em_bytes
    add x22, x22, #IRS_SIZE
    add x21, x21, #1
    b Lbk_em_str_loop
Lbk_em_str_done:

    // ---- string DATA values: Lsdb_<k> as decimal .byte lists -----------
    ldr w23, [x19, #IRM_NSDATA]
    ldr x22, [x19, #IRM_SDATA]
    mov x21, #0
Lbk_em_sdb_loop:
    cmp x21, x23
    b.hs Lbk_em_sdb_done
    mov x0, x20
    adrp x1, Lbk_em_sdb_label@PAGE
    add x1, x1, Lbk_em_sdb_label@PAGEOFF
    mov x2, x21
    ldr x3, [x22, #IRS_PTR]
    ldr w4, [x22, #IRS_LEN]
    bl Lbk_em_bytes
    add x22, x22, #IRS_SIZE
    add x21, x21, #1
    b Lbk_em_sdb_loop
Lbk_em_sdb_done:

    // ---- FILES names: Lfile_<k> (k = 1 ... NFILES) as .byte lists --------
    ldr w23, [x19, #IRM_NFILES]
    ldr x22, [x19, #IRM_FILES]
    mov x21, #0
Lbk_em_file_loop:
    cmp x21, x23
    b.hs Lbk_em_file_done
    mov x0, x20
    adrp x1, Lbk_em_file_label@PAGE
    add x1, x1, Lbk_em_file_label@PAGEOFF
    add x2, x21, #1
    ldr x3, [x22, #IRS_PTR]
    ldr w4, [x22, #IRS_LEN]
    bl Lbk_em_bytes
    add x22, x22, #IRS_SIZE
    add x21, x21, #1
    b Lbk_em_file_loop
Lbk_em_file_done:

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

    // ---- string descriptors: Lsd_<id> (SD_*, CAP 0) per string id -------
    ldr w23, [x19, #IRM_NSTRINGS]
    ldr x22, [x19, #IRM_STRINGS]
    mov x21, #0
Lbk_em_sd_loop:
    cmp x21, x23
    b.hs Lbk_em_sd_done
    mov x0, x20
    adrp x1, Lbk_em_sd_fmt@PAGE
    add x1, x1, Lbk_em_sd_fmt@PAGEOFF
    mov x2, x21
    mov x3, x21
    ldr w4, [x22, #IRS_LEN]
    bl _bk_arm64_fmt
    add x22, x22, #IRS_SIZE
    add x21, x21, #1
    b Lbk_em_sd_loop
Lbk_em_sd_done:

    // ---- _bsk_sdata: one SD record per string DATA value ----------------
    mov x0, x20
    adrp x1, Lbk_em_sdata_head@PAGE
    add x1, x1, Lbk_em_sdata_head@PAGEOFF
    bl _ob_puts
    ldr w23, [x19, #IRM_NSDATA]
    ldr x22, [x19, #IRM_SDATA]
    mov x21, #0
Lbk_em_sdata_loop:
    cmp x21, x23
    b.hs Lbk_em_sdata_done
    mov x0, x20
    adrp x1, Lbk_em_sdata_fmt@PAGE
    add x1, x1, Lbk_em_sdata_fmt@PAGEOFF
    mov x2, x21
    ldr w3, [x22, #IRS_LEN]
    bl _bk_arm64_fmt
    add x22, x22, #IRS_SIZE
    add x21, x21, #1
    b Lbk_em_sdata_loop
Lbk_em_sdata_done:
    mov x0, x20
    adrp x1, Lbk_em_sdata_count@PAGE
    add x1, x1, Lbk_em_sdata_count@PAGEOFF
    mov x2, x23
    bl _bk_arm64_fmt

    // ---- _bsk_files: one SD record per FILES name (entry k-1 = file #k) ---
    mov x0, x20
    adrp x1, Lbk_em_files_head@PAGE
    add x1, x1, Lbk_em_files_head@PAGEOFF
    bl _ob_puts
    ldr w23, [x19, #IRM_NFILES]
    ldr x22, [x19, #IRM_FILES]
    mov x21, #0
Lbk_em_files_loop:
    cmp x21, x23
    b.hs Lbk_em_files_done
    mov x0, x20
    adrp x1, Lbk_em_files_fmt@PAGE
    add x1, x1, Lbk_em_files_fmt@PAGEOFF
    add x2, x21, #1
    ldr w3, [x22, #IRS_LEN]
    bl _bk_arm64_fmt
    add x22, x22, #IRS_SIZE
    add x21, x21, #1
    b Lbk_em_files_loop
Lbk_em_files_done:
    mov x0, x20
    adrp x1, Lbk_em_files_count@PAGE
    add x1, x1, Lbk_em_files_count@PAGEOFF
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
    // ... "rowlen, letter, cap" with cap = (b1 + 1) * (b2 + 1)
    ldr x2, [sp, #72]
    mov x3, x21
    ldr w4, [x22, #IRA_B1]
    ldr w5, [x22, #IRA_B2]
    add x4, x4, #1
    add x5, x5, #1
    mul x4, x4, x5
    mov x0, x20
    adrp x1, Lbk_em_desc_tail@PAGE
    add x1, x1, Lbk_em_desc_tail@PAGEOFF
    bl _bk_arm64_fmt
Lbk_em_desc_next:
    add x21, x21, #1
    cmp x21, #NUM_LETTERS
    b.lo Lbk_em_desc_loop

    // ---- string-list descriptors Lsdesc_<L> (RTA_*, DIMS 1) -------------
    mov x21, #0
Lbk_em_sdesc_loop:
    add x22, x19, #IRM_SARRAYS
    add x22, x22, x21, lsl #4
    ldr w9, [x22, #IRA_DIMS]
    cbz w9, Lbk_em_sdesc_next
    cmp w9, #2
    b.eq Lbk_em_sdesc_table
    cmp w9, #1
    b.ne Lbk_em_bad_dims
    // "Lsdesc_<L>: .quad _bsk_sarr_<L> / .long 1, b1, 0, 1, letter, b1+1"
    mov x0, x20
    adrp x1, Lbk_em_sdesc_fmt@PAGE
    add x1, x1, Lbk_em_sdesc_fmt@PAGEOFF
    mov x2, x21
    mov x3, x21
    ldr w4, [x22, #IRA_B1]
    mov x5, x21
    add x6, x4, #1
    bl _bk_arm64_fmt
    b Lbk_em_sdesc_next
Lbk_em_sdesc_table:
    // string table: ".long 2, b1, b2, " then "b2+1, letter, (b1+1)*(b2+1)"
    mov x0, x20
    adrp x1, Lbk_em_sdesc2_fmt@PAGE
    add x1, x1, Lbk_em_sdesc2_fmt@PAGEOFF
    mov x2, x21
    mov x3, x21
    ldr w4, [x22, #IRA_B1]
    ldr w5, [x22, #IRA_B2]
    bl _bk_arm64_fmt
    ldr w4, [x22, #IRA_B1]
    ldr w5, [x22, #IRA_B2]
    add x2, x5, #1
    mov x3, x21
    add x4, x4, #1
    mul x4, x4, x2
    mov x0, x20
    adrp x1, Lbk_em_desc_tail@PAGE
    add x1, x1, Lbk_em_desc_tail@PAGEOFF
    bl _bk_arm64_fmt
Lbk_em_sdesc_next:
    add x21, x21, #1
    cmp x21, #NUM_LETTERS
    b.lo Lbk_em_sdesc_loop

    // ---- zero-filled globals --------------------------------------------
    ldr w9, [x19, #IRM_NSLOTS]
    lsl x2, x9, #3
    mov x0, x20
    adrp x1, Lbk_em_vars@PAGE
    add x1, x1, Lbk_em_vars@PAGEOFF
    bl _bk_arm64_fmt

    // ---- zero-filled string variables: 286 SD records -------------------
    mov x0, x20
    adrp x1, Lbk_em_svars@PAGE
    add x1, x1, Lbk_em_svars@PAGEOFF
    mov x2, #NUM_STRING_SLOTS * SD_SIZE
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

    // ---- zero-filled string-list storage: (b1 + 1) SD records ------------
    mov x21, #0
Lbk_em_sarr_loop:
    add x22, x19, #IRM_SARRAYS
    add x22, x22, x21, lsl #4
    ldr w9, [x22, #IRA_DIMS]
    cbz w9, Lbk_em_sarr_next
    ldr w10, [x22, #IRA_B1]
    add x3, x10, #1
    ldr w11, [x22, #IRA_B2]         // 0 for a list, so the product is b1 + 1
    add x11, x11, #1
    mul x3, x3, x11                 // elements (b1 + 1) * (b2 + 1)
.if (SD_SIZE != 16)
    .error "a64_emit.s shifts the element count by 4: SD_SIZE must be 16"
.endif
    lsl x3, x3, #4                  // SD_SIZE = 16
    mov x0, x20
    adrp x1, Lbk_em_sarr@PAGE
    add x1, x1, Lbk_em_sarr@PAGEOFF
    mov x2, x21
    bl _bk_arm64_fmt
Lbk_em_sarr_next:
    add x21, x21, #1
    cmp x21, #NUM_LETTERS
    b.lo Lbk_em_sarr_loop

    // ---- zero-filled string temp cells: NSTEMPS SD records ---------------
    ldr w9, [x19, #IRM_NSTEMPS]
    cbz w9, Lbk_em_scells_done
    lsl x2, x9, #4                  // SD_SIZE = 16
    mov x0, x20
    adrp x1, Lbk_em_scells@PAGE
    add x1, x1, Lbk_em_scells@PAGEOFF
    bl _bk_arm64_fmt
Lbk_em_scells_done:

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

// ---------------------------------------------------------------------
// Lbk_em_bytes -- emit "<label line>" and then the bytes as ".byte"
// lines of up to BK_BYTES_PER_LINE decimal values (none for length 0).
// In:  x0 = OutBuf*, x1 = label format (one %u: the index), x2 = index,
//      x3 = byte pointer, x4 = length
// Out: none
// Clobbers: x0-x17, d0-d7, d16-d31
// Callee-saved used: x19 = OutBuf*, x20 = bytes left on the current
//                    line, x21 = byte pointer, x22 = bytes left in all
// Frame: 48 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lbk_em_bytes:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov x19, x0
    mov x21, x3
    mov x22, x4
    bl _bk_arm64_fmt                // label line (x0, x1, x2 as passed)
Lbk_em_bytes_line:
    cbz x22, Lbk_em_bytes_done
    mov x0, x19
    adrp x1, Lbk_em_byte_kw@PAGE
    add x1, x1, Lbk_em_byte_kw@PAGEOFF
    bl _ob_puts
    // x20 = bytes on this line
    mov x20, #BK_BYTES_PER_LINE
    cmp x22, x20
    csel x20, x22, x20, lo
    sub x22, x22, x20
Lbk_em_bytes_byte:
    ldrb w1, [x21], #1
    mov x0, x19
    bl _ob_putu
    subs x20, x20, #1
    b.eq Lbk_em_bytes_eol
    mov x0, x19
    adrp x1, Lbk_em_sep@PAGE
    add x1, x1, Lbk_em_sep@PAGEOFF
    bl _ob_puts
    b Lbk_em_bytes_byte
Lbk_em_bytes_eol:
    mov x0, x19
    mov w1, #10                     // LF
    bl _ob_putc
    b Lbk_em_bytes_line
Lbk_em_bytes_done:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
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
Lbk_em_sdb_label:
    .asciz "Lsdb_%u:\n"
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
Lbk_em_sd_fmt:
    .ascii "Lsd_%u:\n"
    .ascii "    .quad Lstr_%u\n"
    .asciz "    .long %u, 0\n"
Lbk_em_sdata_head:
    .ascii "    .globl _bsk_sdata\n"
    .asciz "_bsk_sdata:\n"
Lbk_em_sdata_fmt:
    .ascii "    .quad Lsdb_%u\n"
    .asciz "    .long %u, 0\n"
Lbk_em_sdata_count:
    .ascii "    .globl _bsk_sdata_count\n"
    .ascii "_bsk_sdata_count:\n"
    .asciz "    .quad %u\n"
Lbk_em_file_label:
    .asciz "Lfile_%u:\n"
Lbk_em_files_head:
    .ascii "    .globl _bsk_files\n"
    .asciz "_bsk_files:\n"
Lbk_em_files_fmt:
    .ascii "    .quad Lfile_%u\n"
    .asciz "    .long %u, 0\n"
Lbk_em_files_count:
    .ascii "    .globl _bsk_files_count\n"
    .ascii "_bsk_files_count:\n"
    .asciz "    .quad %u\n"
Lbk_em_sdesc2_fmt:
    .ascii "Lsdesc_%L:\n"
    .ascii "    .quad _bsk_sarr_%L\n"
    .asciz "    .long 2, %u, %u, "
Lbk_em_scells:
    .asciz "    .zerofill __DATA,__bss,_bsk_scells,%u,3\n"
Lbk_em_sec_data:
    .ascii "    .section __DATA,__data\n"
    .asciz "    .p2align 3\n"
Lbk_em_desc_fmt:
    .ascii "Ldesc_%L:\n"
    .ascii "    .quad _bsk_arr_%L\n"
    .asciz "    .long %u, %u, %u, "
Lbk_em_desc_tail:
    .asciz "%u, %u, %u\n"
Lbk_em_sdesc_fmt:
    .ascii "Lsdesc_%L:\n"
    .ascii "    .quad _bsk_sarr_%L\n"
    .asciz "    .long 1, %u, 0, 1, %u, %u\n"
Lbk_em_svars:
    .asciz "    .zerofill __DATA,__bss,_bsk_svars,%u,3\n"
Lbk_em_sarr:
    .asciz "    .zerofill __DATA,__bss,_bsk_sarr_%L,%u,3\n"
Lbk_em_vars:
    .asciz "    .zerofill __DATA,__bss,_bsk_vars,%u,3\n"
Lbk_em_arr:
    .asciz "    .zerofill __DATA,__bss,_bsk_arr_%L,%u,3\n"
Lbk_em_err_nomain:
    .asciz "arm64-macos backend: module has no main function"
Lbk_em_err_dims:
    .asciz "arm64-macos backend: array with more than 2 dimensions"
