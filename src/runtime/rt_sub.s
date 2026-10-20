// =====================================================================
// src/runtime/rt_sub.s -- SUB activations: the call stack, the call
// budget and the activation blocks (DESIGN.md 5.3.1, 6.9; LANGUAGE.md
// 7.27).
//
// Defines (global, runtime.inc):
//   _bsk_sub_enter _bsk_sub_leave
// Uses: _bsk_rt_gosub_depth, _bsk_rt_gosub_base (rt_gosub.s),
// _bsk_curline (rt_main.s), _calloc, _free, _bsk_err.
//
// State (private to this file):
//   _bsk_rt_sub_depth u64  active activations, 0 .. LIM_CALL_DEPTH
//   _bsk_rt_sub_words u64  summed SUBL_COST of the active activations,
//                        0 .. LIM_CALL_WORDS
//   _bsk_rt_sub_stack   LIM_CALL_DEPTH call records of RT_CALLREC_SIZE bytes,
//                   record k = activation k + 1 (the newest on top)
// A call record keeps what _bsk_sub_leave must restore or release.
// =====================================================================
.include "baysick.inc"

.equ RT_CALLREC_BLOCK,  0           // ptr  the activation block
.equ RT_CALLREC_SUBL,   8           // ptr  the unit's SUBL record
.equ RT_CALLREC_GBASE,  16          // u64  the GOSUB base before the call
.equ RT_CALLREC_LINE,   24          // u32  _bsk_curline at the CALL
.equ RT_CALLREC_SIZE,   32

// The record index is shifted by 5 (lsl #5) in _bsk_sub_enter and _bsk_sub_leave.
.if (RT_CALLREC_SIZE != 32)
    .error "rt_sub.s: the call record index is shifted by 5: RT_CALLREC_SIZE must be 32"
.endif

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _bsk_sub_enter -- start an activation of a SUB unit (LANGUAGE.md 7.27
//   step 2; DESIGN.md 6.9). In this order:
//   1. LIM_CALL_DEPTH activations already active -> TOO MANY CALLS;
//   2. summed cost + SUBL_COST > LIM_CALL_WORDS -> TOO MANY CALLS;
//   3. each parameter k (left to right) with SUBL_PDIMS[k] = SUBD_LIST /
//      SUBD_TABLE: argument k's RTA_DIMS must be 1 / 2, else DIMENSION
//      ERROR;
//   4. calloc(1, SUBL_BLOCKSIZE); NULL -> OUT OF ROOM;
//   then: summed cost += SUBL_COST; the NPARAMS argument pointers are
//   copied to block + SUBL_PARAMOFF; the SUBL_NDESC RTA templates to
//   block + SUBL_DESCOFF with the block address added to each RTA_DATA;
//   the call record {block, SUBL, GOSUB base, _bsk_curline} is pushed;
//   GOSUB base := GOSUB depth. Errors report the CALL line
//   (_bsk_curline is not changed).
//   Inputs  : x0 = SUBL record, x1 = argument vector (NPARAMS pointers)
//   Outputs : x0 = the zero-filled activation block
//   Errors  : TOO MANY CALLS, DIMENSION ERROR, OUT OF ROOM
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = SUBL record, x20 = argument vector,
//             x21 = block
//   Frame   : 48 bytes (frame record + x19..x21, padded)
// ---------------------------------------------------------------------
    .globl _bsk_sub_enter
    .p2align 2
_bsk_sub_enter:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov x19, x0
    mov x20, x1

    // 1. The activation count.
    adrp x9, _bsk_rt_sub_depth@PAGE
    ldr x10, [x9, _bsk_rt_sub_depth@PAGEOFF]
    cmp x10, #LIM_CALL_DEPTH
    b.hs Lrt_sub_too_many

    // 2. The call budget: words + COST must stay <= LIM_CALL_WORDS.
    adrp x9, _bsk_rt_sub_words@PAGE
    ldr x10, [x9, _bsk_rt_sub_words@PAGEOFF]
    ldr w11, [x19, #SUBL_COST]      // zero-extended u32
    add x10, x10, x11
    mov x12, #LIM_CALL_WORDS
    cmp x10, x12
    b.hi Lrt_sub_too_many

    // 3. Array parameters whose dimensionality the unit fixes.
    ldr w12, [x19, #SUBL_NPARAMS]
    mov x13, #0                     // k
Lrt_sub_dims_loop:
    cmp x13, x12
    b.hs Lrt_sub_dims_ok
    add x14, x19, x13
    ldrb w14, [x14, #SUBL_PDIMS]    // SUBD_* of parameter k
    cmp w14, #SUBD_LIST
    b.eq Lrt_sub_dims_check
    cmp w14, #SUBD_TABLE
    b.ne Lrt_sub_dims_next          // SUBD_SCALAR / SUBD_ANY: not checked
Lrt_sub_dims_check:
    ldr x15, [x20, x13, lsl #3]     // argument k: an RTA descriptor
    ldr w15, [x15, #RTA_DIMS]
    cmp w15, w14                    // SUBD_LIST = 1, SUBD_TABLE = 2
    b.ne Lrt_sub_dim_error
Lrt_sub_dims_next:
    add x13, x13, #1
    b Lrt_sub_dims_loop
Lrt_sub_dims_ok:

    // 4. The zero-filled block.
    mov x0, #1
    ldr w1, [x19, #SUBL_BLOCKSIZE]
    bl _calloc
    cbz x0, Lrt_sub_oom
    mov x21, x0

    // The activation is now active: its cost joins the budget.
    adrp x9, _bsk_rt_sub_words@PAGE
    ldr x10, [x9, _bsk_rt_sub_words@PAGEOFF]
    ldr w11, [x19, #SUBL_COST]
    add x10, x10, x11
    str x10, [x9, _bsk_rt_sub_words@PAGEOFF]

    // The argument pointers to block + PARAMOFF.
    ldr w12, [x19, #SUBL_NPARAMS]
    ldr w13, [x19, #SUBL_PARAMOFF]
    add x13, x21, x13               // destination
    mov x14, #0                     // k
Lrt_sub_param_loop:
    cmp x14, x12
    b.hs Lrt_sub_param_done
    ldr x15, [x20, x14, lsl #3]
    str x15, [x13, x14, lsl #3]
    add x14, x14, #1
    b Lrt_sub_param_loop
Lrt_sub_param_done:

    // The RTA templates to block + DESCOFF, RTA_DATA made absolute.
    ldr w12, [x19, #SUBL_NDESC]
    ldr x10, [x19, #SUBL_DESCS]     // source templates (0 when none)
    ldr w13, [x19, #SUBL_DESCOFF]
    add x13, x21, x13               // destination
Lrt_sub_desc_loop:
    cbz x12, Lrt_sub_desc_done
    ldp x14, x15, [x10, #0]         // RTA_DATA (an offset), DIMS/B1
    ldp x16, x17, [x10, #16]        // B2/ROWLEN, LETTER/CAP
    add x14, x14, x21               // RTA_DATA := block + offset
    stp x14, x15, [x13, #0]
    stp x16, x17, [x13, #16]
    add x10, x10, #RTA_SIZE
    add x13, x13, #RTA_SIZE
    sub x12, x12, #1
    b Lrt_sub_desc_loop
Lrt_sub_desc_done:

    // Push the call record {block, SUBL, GOSUB base, line}.
    adrp x9, _bsk_rt_sub_depth@PAGE
    ldr x10, [x9, _bsk_rt_sub_depth@PAGEOFF]
    adrp x11, _bsk_rt_sub_stack@PAGE
    add x11, x11, _bsk_rt_sub_stack@PAGEOFF
    add x11, x11, x10, lsl #5       // record = stack + 32 * depth
    stp x21, x19, [x11, #RT_CALLREC_BLOCK]
    adrp x12, _bsk_rt_gosub_base@PAGE
    ldr x13, [x12, _bsk_rt_gosub_base@PAGEOFF]
    str x13, [x11, #RT_CALLREC_GBASE]
    adrp x14, _bsk_curline@PAGE
    ldr w15, [x14, _bsk_curline@PAGEOFF]
    str x15, [x11, #RT_CALLREC_LINE] // zero-extended line
    add x10, x10, #1
    str x10, [x9, _bsk_rt_sub_depth@PAGEOFF]

    // The new activation starts with no GOSUB pending: base := depth.
    adrp x14, _bsk_rt_gosub_depth@PAGE
    ldr x15, [x14, _bsk_rt_gosub_depth@PAGEOFF]
    str x15, [x12, _bsk_rt_gosub_base@PAGEOFF]

    mov x0, x21                     // the block
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

Lrt_sub_too_many:
    mov w0, #ERR_TOO_MANY_CALLS
    bl _bsk_err                     // noreturn
Lrt_sub_dim_error:
    mov w0, #ERR_DIMENSION_ERROR
    bl _bsk_err                     // noreturn
Lrt_sub_oom:
    mov w0, #ERR_OUT_OF_ROOM
    bl _bsk_err                     // noreturn

// ---------------------------------------------------------------------
// _bsk_sub_leave -- end the newest activation (SUBEND; LANGUAGE.md 7.27
//   step 5, DESIGN.md 6.9): pop its call record; summed cost -= its
//   SUBL_COST; free the buffer of every SD record with SD_CAP > 0 among
//   the SUBL_NSD records at block + SUBL_SDOFF; free the block; GOSUB
//   depth := the current GOSUB base (the activation's pending GOSUBs are
//   dropped); GOSUB base := the saved base; _bsk_curline := the saved
//   CALL line.
//   Precondition: an activation is active (only a SUB body calls this).
//   Inputs  : none
//   Outputs : none
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = call record, x20 = SD cursor,
//             x21 = SD records left, x22 = block
//   Frame   : 48 bytes (frame record + x19..x22)
// ---------------------------------------------------------------------
    .globl _bsk_sub_leave
    .p2align 2
_bsk_sub_leave:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]

    // Pop the newest call record.
    adrp x9, _bsk_rt_sub_depth@PAGE
    ldr x10, [x9, _bsk_rt_sub_depth@PAGEOFF]
    sub x10, x10, #1
    str x10, [x9, _bsk_rt_sub_depth@PAGEOFF]
    adrp x19, _bsk_rt_sub_stack@PAGE
    add x19, x19, _bsk_rt_sub_stack@PAGEOFF
    add x19, x19, x10, lsl #5       // the record

    // Its cost leaves the budget.
    ldp x22, x11, [x19, #RT_CALLREC_BLOCK]  // x22 = block, x11 = SUBL
    ldr w12, [x11, #SUBL_COST]
    adrp x9, _bsk_rt_sub_words@PAGE
    ldr x10, [x9, _bsk_rt_sub_words@PAGEOFF]
    sub x10, x10, x12
    str x10, [x9, _bsk_rt_sub_words@PAGEOFF]

    // Free the owned string buffers of the activation's SD records.
    ldr w20, [x11, #SUBL_SDOFF]
    add x20, x22, x20               // first SD record
    ldr w21, [x11, #SUBL_NSD]
Lrt_sub_free_loop:
    cbz x21, Lrt_sub_free_done
    ldr w9, [x20, #SD_CAP]
    cbz w9, Lrt_sub_free_next       // not owned: nothing to free
    ldr x0, [x20, #SD_PTR]
    bl _free
Lrt_sub_free_next:
    add x20, x20, #SD_SIZE
    sub x21, x21, #1
    b Lrt_sub_free_loop
Lrt_sub_free_done:
    mov x0, x22
    bl _free                        // the block itself

    // Drop the activation's pending GOSUBs, restore the caller's base.
    adrp x9, _bsk_rt_gosub_base@PAGE
    ldr x10, [x9, _bsk_rt_gosub_base@PAGEOFF]
    adrp x11, _bsk_rt_gosub_depth@PAGE
    str x10, [x11, _bsk_rt_gosub_depth@PAGEOFF]
    ldr x10, [x19, #RT_CALLREC_GBASE]
    str x10, [x9, _bsk_rt_gosub_base@PAGEOFF]

    // The CALL line is current again.
    ldr w10, [x19, #RT_CALLREC_LINE]
    adrp x9, _bsk_curline@PAGE
    str w10, [x9, _bsk_curline@PAGEOFF]

    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// State (see the file header).
.zerofill __DATA,__bss,_bsk_rt_sub_depth,8,3
.zerofill __DATA,__bss,_bsk_rt_sub_words,8,3
.zerofill __DATA,__bss,_bsk_rt_sub_stack,(RT_CALLREC_SIZE * LIM_CALL_DEPTH),4
