// =====================================================================
// src/runtime/rt_data.s -- READ from the program's two data blocks
// (LANGUAGE.md 7.4, 7.5, 7.14.4, 7.16; DESIGN.md 6.2, 6.5, 6.7).
//
// Defines: _bsk_read _bsk_restore
//          _bsk_sread _bsk_sread_el _bsk_smat_read   (string data block)
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
// _bsk_smat_read -- MAT READ of a string list with its current bound n:
//   elements 1..n receive the next string data values, each stored as
//   it is read (an OUT OF DATA in the middle ends the program after the
//   earlier ones). Current bound 0 -> DIMENSION ERROR.
//   Inputs  : x0 = string-list descriptor (RTA_*, SD elements)
//   Outputs : none
//   Errors  : DIMENSION ERROR; OUT OF DATA (exit 0); OUT OF ROOM
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = address of the next element, x20 = elements
//             left
//   Frame   : 32 bytes (frame record + x19, x20)
// ---------------------------------------------------------------------
    .globl _bsk_smat_read
    .p2align 2
_bsk_smat_read:
    ldr w9, [x0, #RTA_B1]
    cbz w9, Lrt_data_dimerr         // an empty list is no vector
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    ldr x19, [x0, #RTA_DATA]
    add x19, x19, #SD_SIZE          // element 1
    mov w20, w9                     // n
1:
    mov x0, x19
    bl _bsk_sread
    add x19, x19, #SD_SIZE
    subs x20, x20, #1
    b.ne 1b
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
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
