// =====================================================================
// src/runtime/rt_data.s -- READ from the program's DATA block.
//
// Defines: _bsk_read
// Uses (defined by every compiled program): _bsk_data (double[]),
// _bsk_data_count (u64).
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

// DATA cursor: index of the next value to read, initially 0.
.zerofill __DATA,__bss,_bsk_rt_data_cursor,8,3
