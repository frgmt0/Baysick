// =====================================================================
// src/runtime/rt_gosub.s -- GOSUB return-address stack.
//
// Defines: _bsk_gosub_push _bsk_gosub_pop
// Defines (private to the runtime, .private_extern):
//   _bsk_rt_gosub_depth  u64  pending GOSUBs of all activations
//   _bsk_rt_gosub_base   u64  depth at which the current SUB activation
//                             started (0 in the main program)
// The stack holds LIM_GOSUB_DEPTH machine addresses (return labels in
// compiled code), counted over all SUB activations together. Pushing
// onto a full stack is TOO MANY GOSUBS. Popping when depth = base (no
// GOSUB of the current activation pending) is ILLEGAL RETURN, so a
// RETURN never pops a GOSUB of another activation (LANGUAGE.md 7.9,
// 7.27; DESIGN.md 6.9). _bsk_sub_enter / _bsk_sub_leave (rt_sub.s) set
// the base and drop an ending activation's pending GOSUBs. Without SUB
// units the base stays 0 and both functions behave as before.
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
// _bsk_gosub_pop -- pop the most recent return address of the current
//   activation.
//   Inputs  : none
//   Outputs : x0 = code address
//   Errors  : depth = GOSUB base (none pending in this activation)
//             -> ILLEGAL RETURN
//   Clobbers: x9-x11
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .globl _bsk_gosub_pop
    .p2align 2
_bsk_gosub_pop:
    adrp x9, _bsk_rt_gosub_depth@PAGE
    ldr x10, [x9, _bsk_rt_gosub_depth@PAGEOFF]
    adrp x11, _bsk_rt_gosub_base@PAGE
    ldr x11, [x11, _bsk_rt_gosub_base@PAGEOFF]
    cmp x10, x11
    b.ls Lrt_gosub_empty            // depth = base: nothing of this activation
    sub x10, x10, #1                // top index
    str x10, [x9, _bsk_rt_gosub_depth@PAGEOFF]
    adrp x11, _bsk_rt_gosub_stack@PAGE
    add x11, x11, _bsk_rt_gosub_stack@PAGEOFF
    ldr x0, [x11, x10, lsl #3]
    ret
Lrt_gosub_empty:
    mov w0, #ERR_ILLEGAL_RETURN
    b _bsk_err

// State: depth and base (u64, shared with rt_sub.s) and LIM_GOSUB_DEPTH
// 8-byte return addresses.
    .private_extern _bsk_rt_gosub_depth
    .private_extern _bsk_rt_gosub_base
.zerofill __DATA,__bss,_bsk_rt_gosub_depth,8,3
.zerofill __DATA,__bss,_bsk_rt_gosub_base,8,3
.zerofill __DATA,__bss,_bsk_rt_gosub_stack,(8 * LIM_GOSUB_DEPTH),3
