// =====================================================================
// src/runtime/rt_data.s -- READ from the program's two data blocks
// (LANGUAGE.md 7.4, 7.5, 7.14.4, 7.16; DESIGN.md 6.2, 6.5, 6.7).
//
// Defines: _bsk_read _bsk_restore
//          _bsk_sread _bsk_sread_el _bsk_smat_read   (string data block;
//          _bsk_smat_read also reads string tables, DESIGN.md 6.8)
// Uses (defined by every compiled program): _bsk_data (double[]),
// _bsk_data_count (u64), _bsk_sdata (SD[], CAP 0), _bsk_sdata_count (u64).
//
// The numeric and the string block have independent cursors (the index
// of the next value, initially 0); RESTORE resets one or both.
// =====================================================================
.include "baysick.inc"

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _bsk_read -- next DATA value, in program order.
//   Inputs  : none
//   Outputs : d0 = value
//   Errors  : no value left -> OUT OF DATA (the program ends, exit 0)
//   Clobbers: x0, x9-x12, d0
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .globl _bsk_read
    .p2align 2
_bsk_read:
    adrp x9, _bsk_rt_data_cursor@PAGE
    ldr x10, [x9, _bsk_rt_data_cursor@PAGEOFF]     // index of next value
    adrp x11, _bsk_data_count@PAGE
    ldr x11, [x11, _bsk_data_count@PAGEOFF]
    cmp x10, x11
    b.hs Lrt_data_out               // block exhausted
    adrp x12, _bsk_data@PAGE
    add x12, x12, _bsk_data@PAGEOFF
    ldr d0, [x12, x10, lsl #3]      // _bsk_data[cursor]
    add x10, x10, #1
    str x10, [x9, _bsk_rt_data_cursor@PAGEOFF]
    ret
Lrt_data_out:
    mov w0, #ERR_OUT_OF_DATA
    b _bsk_err                      // prints OUT OF DATA IN n, exit 0

// ---------------------------------------------------------------------
// _bsk_restore -- RESTORE (both blocks), RESTORE* (numeric block only),
//   RESTORE$ (string block only): the next READ of a restored block
//   starts again at its first value.
//   Inputs  : w0 = RESTORE_ALL, RESTORE_NUM or RESTORE_STR
//   Outputs : none
//   Clobbers: x9
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .globl _bsk_restore
    .p2align 2
_bsk_restore:
    cmp w0, #RESTORE_STR
    b.eq 1f                         // RESTORE$: numeric cursor kept
    adrp x9, _bsk_rt_data_cursor@PAGE
    str xzr, [x9, _bsk_rt_data_cursor@PAGEOFF]
1:
    cmp w0, #RESTORE_NUM
    b.eq 2f                         // RESTORE*: string cursor kept
    adrp x9, _bsk_rt_sdata_cursor@PAGE
    str xzr, [x9, _bsk_rt_sdata_cursor@PAGEOFF]
2:
    ret

// ---------------------------------------------------------------------
// _bsk_sread -- READ a string target: dst := the next value of the string
//   data block (copied like LET, _bsk_str_set semantics).
//   Inputs  : x0 = destination SD
//   Outputs : none
//   Errors  : no value left -> OUT OF DATA (exit 0); OUT OF ROOM
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : none (tail call)
// ---------------------------------------------------------------------
    .globl _bsk_sread
    .p2align 2
_bsk_sread:
    adrp x9, _bsk_rt_sdata_cursor@PAGE
    ldr x10, [x9, _bsk_rt_sdata_cursor@PAGEOFF]    // index of next value
    adrp x11, _bsk_sdata_count@PAGE
    ldr x11, [x11, _bsk_sdata_count@PAGEOFF]
    cmp x10, x11
    b.hs Lrt_data_out               // string block exhausted
    add x11, x10, #1
    str x11, [x9, _bsk_rt_sdata_cursor@PAGEOFF]
    adrp x12, _bsk_sdata@PAGE
    add x12, x12, _bsk_sdata@PAGEOFF
    add x1, x12, x10, lsl #4        // &_bsk_sdata[cursor] (SD_SIZE 16)
    b _bsk_str_set                  // tail call: dst := copy

// ---------------------------------------------------------------------
// _bsk_sread_el -- READ into a string list element L$(i) (the element
//   form of `sread`, IR.md 3.2): the next value of the string data block
//   is taken first, then the subscript is checked at the store
//   (LANGUAGE.md 7.1, 7.4), then the value is copied as by _bsk_sread.
//   Inputs  : x0 = string-list descriptor (RTA_*), d0 = subscript i
//   Outputs : none
//   Errors  : no value left -> OUT OF DATA (exit 0); then SUBSCRIPT
//             ERROR (_bsk_saref1); OUT OF ROOM
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : 32 bytes (frame record + the source SD at [sp,#16]);
//             tail call to _bsk_str_set
// ---------------------------------------------------------------------
    .globl _bsk_sread_el
    .p2align 2
_bsk_sread_el:
    adrp x9, _bsk_rt_sdata_cursor@PAGE
    ldr x10, [x9, _bsk_rt_sdata_cursor@PAGEOFF]    // index of next value
    adrp x11, _bsk_sdata_count@PAGE
    ldr x11, [x11, _bsk_sdata_count@PAGEOFF]
    cmp x10, x11
    b.hs Lrt_data_out               // string block exhausted
    add x11, x10, #1
    str x11, [x9, _bsk_rt_sdata_cursor@PAGEOFF]
    adrp x12, _bsk_sdata@PAGE
    add x12, x12, _bsk_sdata@PAGEOFF
    add x12, x12, x10, lsl #4       // &_bsk_sdata[cursor] (SD_SIZE 16)
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x12, [sp, #16]              // the value, kept across the check
    bl _bsk_saref1                  // x0 = &L$(i); SUBSCRIPT ERROR here
    ldr x1, [sp, #16]
    ldp x29, x30, [sp], #32
    b _bsk_str_set                  // tail call: element := copy

// ---------------------------------------------------------------------
// _bsk_smat_read -- MAT READ of a string list or (Fifth Edition) string
//   table with its current shape: a list's elements 1..n, a table's
//   elements (1,1) .. (1,c), (2,1) .. (r,c) receive the next string data
//   values, each stored as it is read (an OUT OF DATA in the middle ends
//   the program after the earlier ones). A zero dimension (list bound 0,
//   table r or c 0) -> DIMENSION ERROR (LANGUAGE.md 7.14.4).
//   Inputs  : x0 = string-list or string-table descriptor (RTA_*, SD
//             elements)
//   Outputs : none
//   Errors  : DIMENSION ERROR; OUT OF DATA (exit 0); OUT OF ROOM
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = address of the current row's first element,
//             x20 = rows left, x21 = columns, x22 = row stride (bytes),
//             x23 = column index
//   Frame   : 64 bytes (frame record + x19..x23, padded)
// ---------------------------------------------------------------------
    .globl _bsk_smat_read
    .p2align 2
_bsk_smat_read:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]
    ldr w20, [x0, #RTA_B1]          // rows (a list: its n)
    cbz w20, Lrt_data_dimerr        // an empty list is no vector
    ldr x19, [x0, #RTA_DATA]
    ldr w9, [x0, #RTA_DIMS]
    cmp w9, #1
    b.ne 1f
    mov w21, #1                     // a list: n rows of one element
    mov x22, #SD_SIZE
    add x19, x19, #SD_SIZE          // element 1
    b Lrt_data_smread_row
1:
    ldr w21, [x0, #RTA_B2]          // a table: c columns
    cbz w21, Lrt_data_dimerr
    ldr w22, [x0, #RTA_ROWLEN]
    lsl x22, x22, #4                // row stride: ROWLEN SD records
    add x19, x19, x22
    add x19, x19, #SD_SIZE          // element (1,1)
Lrt_data_smread_row:
    mov x23, #0
Lrt_data_smread_col:
    add x0, x19, x23, lsl #4        // element of column x23 + 1
    bl _bsk_sread
    add x23, x23, #1
    cmp x23, x21
    b.lo Lrt_data_smread_col
    add x19, x19, x22               // next row
    subs x20, x20, #1
    b.ne Lrt_data_smread_row
    ldr x23, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

Lrt_data_dimerr:
    mov w0, #ERR_DIMENSION_ERROR
    b _bsk_err

.if SD_SIZE != 16
    .error "rt_data: _bsk_sread assumes SD_SIZE == 16"
.endif

// Cursors: index of the next value of each block, initially 0.
.zerofill __DATA,__bss,_bsk_rt_data_cursor,8,3
.zerofill __DATA,__bss,_bsk_rt_sdata_cursor,8,3
