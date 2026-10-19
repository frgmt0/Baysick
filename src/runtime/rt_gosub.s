// =====================================================================
// src/runtime/rt_gosub.s -- GOSUB return-address stack.
//
// Defines: _bsk_gosub_push _bsk_gosub_pop
// The stack holds LIM_GOSUB_DEPTH machine addresses (return labels in
// compiled code). Pushing onto a full stack is TOO MANY GOSUBS; popping
// an empty one is ILLEGAL RETURN.
// =====================================================================
.include "baysick.inc"

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _bsk_gosub_push -- push a return address.
//   Inputs  : x0 = code address to return to
//   Outputs : none
//   Errors  : LIM_GOSUB_DEPTH addresses already pending -> TOO MANY GOSUBS
//   Clobbers: x0, x9-x11
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .globl _bsk_gosub_push
    .p2align 2
_bsk_gosub_push:
    adrp x9, _bsk_rt_gosub_depth@PAGE
    ldr x10, [x9, _bsk_rt_gosub_depth@PAGEOFF]
    cmp x10, #LIM_GOSUB_DEPTH
    b.hs Lrt_gosub_full
    adrp x11, _bsk_rt_gosub_stack@PAGE
    add x11, x11, _bsk_rt_gosub_stack@PAGEOFF
    str x0, [x11, x10, lsl #3]      // stack[depth] = address
    add x10, x10, #1
    str x10, [x9, _bsk_rt_gosub_depth@PAGEOFF]
    ret
Lrt_gosub_full:
    mov w0, #ERR_TOO_MANY_GOSUBS
    b _bsk_err

// ---------------------------------------------------------------------
// _bsk_gosub_pop -- pop the most recent return address.
//   Inputs  : none
//   Outputs : x0 = code address
//   Errors  : stack empty -> ILLEGAL RETURN
//   Clobbers: x9-x11
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .globl _bsk_gosub_pop
    .p2align 2
_bsk_gosub_pop:
    adrp x9, _bsk_rt_gosub_depth@PAGE
    ldr x10, [x9, _bsk_rt_gosub_depth@PAGEOFF]
    cbz x10, Lrt_gosub_empty
    sub x10, x10, #1                // top index
    str x10, [x9, _bsk_rt_gosub_depth@PAGEOFF]
    adrp x11, _bsk_rt_gosub_stack@PAGE
    add x11, x11, _bsk_rt_gosub_stack@PAGEOFF
    ldr x0, [x11, x10, lsl #3]
    ret
Lrt_gosub_empty:
    mov w0, #ERR_ILLEGAL_RETURN
    b _bsk_err

// State: depth (u64) and LIM_GOSUB_DEPTH 8-byte return addresses.
.zerofill __DATA,__bss,_bsk_rt_gosub_depth,8,3
.zerofill __DATA,__bss,_bsk_rt_gosub_stack,(8 * LIM_GOSUB_DEPTH),3
