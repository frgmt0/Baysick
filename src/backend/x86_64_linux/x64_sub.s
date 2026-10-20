// =====================================================================
// src/backend/x86_64_linux/x64_sub.s -- SUB units of the x86_64-linux
// backend (Sixth Edition; docs/DESIGN.md sections 5.3.1 and 5.4.6): the
// activation block layout of a unit, its parameter and descriptor lookups,
// the unit cost SUBL_COST (the same number as the arm64 backend's, from the
// IR alone) and the .Lsubl_<u> / .Lsubt_<u> records.
//
// This file is arm64 code for Apple as (part of the compiler); the text
// it produces is GNU as AT&T x86_64 assembly.
//
// Exports: _bk_x64_unit_layout, _bk_x64_unit_param,
//          _bk_x64_unit_desc_index, _bk_x64_unit_cost, _bk_x64_emit_subl
// Uses:    _bk_x64_func_shape (x64_insn.s), _bk_x64_fmt, _bk_x64_bytes
//          (x64_text.s)
// =====================================================================
.include "baysick.inc"


// A block offset or size above this does not fit the signed 32-bit x86
// displacement the unit's code addresses it with (DESIGN.md 5.4.6).
.equ BK_X64_MAX_BLOCK, 0x7FFFFFF0

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _bk_x64_unit_layout -- the activation block layout of a SUB unit
// (DESIGN.md 5.3.1 "Activation block"), all offsets in bytes:
//   numeric slots at 0 (8 x NSLOTS); parameter pointers at PARAMOFF =
//   8 x NSLOTS (8 x SUBNPARAMS); SD records at SDOFF = align16(PARAMOFF +
//   8 x SUBNPARAMS): NSD = 286 string variables + NSTEMPS cells + the
//   elements of each non-parameter string array in letter order;
//   descriptors at DESCOFF = SDOFF + 16 x NSD: NDESC = the used
//   non-parameter numeric arrays, then string arrays, letter order;
//   numeric array storage at STOREOFF = DESCOFF + 32 x NDESC (8 x cap
//   per used non-parameter numeric array, letter order); SIZE =
//   align16(end). "Used" = DIMS != 0, as for main's .Ldesc_ / .Lsdesc_.
// In:  x0 = unit Module*
// Out: x0 = 0 or reason; x1 = PARAMOFF, x2 = SDOFF, x3 = DESCOFF,
//      x4 = NSD, x5 = NDESC, x6 = STOREOFF, x7 = SIZE
// Clobbers: x0-x17.  Leaf, no frame.
// ---------------------------------------------------------------------
    .globl _bk_x64_unit_layout
    .p2align 2
_bk_x64_unit_layout:
    mov x9, x0
    // PARAMOFF = 8 * NSLOTS
    ldr w10, [x9, #IRM_NSLOTS]
    lsl x1, x10, #3
    // SDOFF = align16(PARAMOFF + 8 * SUBNPARAMS)
    ldr w11, [x9, #IRM_SUBNPARAMS]
    cmp w11, #LIM_SUB_PARAMS
    b.hi Lbk_x64_sub_lay_bad_np
    add x2, x1, x11, lsl #3
    add x2, x2, #15
    and x2, x2, #~15
    // NSD starts with the string variables and the unit's string temp cells
    ldr w4, [x9, #IRM_NSTEMPS]
    add x4, x4, #(NUM_LETTERS * SLOT_PER_LETTER)
    mov x5, #0                      // NDESC
    mov x7, #0                      // numeric storage bytes
    mov x12, #0                     // letter
Lbk_x64_sub_lay_loop:
    // ---- numeric array of this letter: a descriptor and 8*cap bytes ----
    add x13, x9, #IRM_ARRAYS
    add x13, x13, x12, lsl #4
    ldr w14, [x13, #IRA_DIMS]
    cbz w14, 1f
    ldr w15, [x13, #IRA_FLAGS]
    tst w15, #IRA_FLAG_PARAM
    b.ne 1f                         // a parameter has no storage of its own
    cmp w14, #2
    b.hi Lbk_x64_sub_lay_bad_dims
    add x5, x5, #1
    ldr w15, [x13, #IRA_B1]
    ldr w16, [x13, #IRA_B2]
    add x15, x15, #1
    add x16, x16, #1
    mul x15, x15, x16
    add x7, x7, x15, lsl #3
1:
    // ---- string array of this letter: a descriptor and cap SD records ----
    add x13, x9, #IRM_SARRAYS
    add x13, x13, x12, lsl #4
    ldr w14, [x13, #IRA_DIMS]
    cbz w14, 2f
    ldr w15, [x13, #IRA_FLAGS]
    tst w15, #IRA_FLAG_PARAM
    b.ne 2f
    cmp w14, #2
    b.hi Lbk_x64_sub_lay_bad_dims
    add x5, x5, #1
    ldr w15, [x13, #IRA_B1]
    ldr w16, [x13, #IRA_B2]         // 0 for a list
    add x15, x15, #1
    add x16, x16, #1
    mul x15, x15, x16
    add x4, x4, x15
2:
    add x12, x12, #1
    cmp x12, #NUM_LETTERS
    b.lo Lbk_x64_sub_lay_loop
    // DESCOFF, STOREOFF, SIZE
    add x3, x2, x4, lsl #4
    add x6, x3, x5, lsl #5
    add x7, x6, x7
    add x7, x7, #15
    and x7, x7, #~15
    mov x9, #BK_X64_MAX_BLOCK
    cmp x7, x9
    b.hi Lbk_x64_sub_lay_bad_size
    mov x0, #0
    ret
Lbk_x64_sub_lay_bad_np:
    adrp x0, Lbk_x64_sub_err_np@PAGE
    add x0, x0, Lbk_x64_sub_err_np@PAGEOFF
    ret
Lbk_x64_sub_lay_bad_dims:
    adrp x0, Lbk_x64_sub_err_dims@PAGE
    add x0, x0, Lbk_x64_sub_err_dims@PAGEOFF
    ret
Lbk_x64_sub_lay_bad_size:
    adrp x0, Lbk_x64_sub_err_size@PAGE
    add x0, x0, Lbk_x64_sub_err_size@PAGEOFF
    ret

// ---------------------------------------------------------------------
// _bk_x64_unit_param -- the parameter of a SUB unit that a variable or
// array names: the k < SUBNPARAMS with SUBPKINDS[k] = kind and
// SUBPARAMS[k] = value.
// In:  x0 = unit Module*, w1 = scalar slot / string slot / letter,
//      w2 = SUBP_* kind
// Out: x0 = k, or -1 if the variable is not a parameter
// Clobbers: x0, x9-x13.  Leaf, no frame.
// ---------------------------------------------------------------------
    .globl _bk_x64_unit_param
    .p2align 2
_bk_x64_unit_param:
    ldr w9, [x0, #IRM_SUBNPARAMS]
    cmp w9, #LIM_SUB_PARAMS
    mov w10, #LIM_SUB_PARAMS
    csel w9, w10, w9, hi            // never read past the arrays
    mov x10, #0
1:
    cmp x10, x9
    b.hs 3f
    add x11, x0, #IRM_SUBPKINDS
    ldrb w12, [x11, x10]
    cmp w12, w2
    b.ne 2f
    add x11, x0, #IRM_SUBPARAMS
    ldr w13, [x11, x10, lsl #2]
    cmp w13, w1
    b.ne 2f
    mov x0, x10
    ret
2:
    add x10, x10, #1
    b 1b
3:
    mov x0, #-1
    ret

// ---------------------------------------------------------------------
// _bk_x64_unit_desc_index -- d(L): the index of a non-parameter array's
// descriptor in the block (DESIGN.md 5.3.1): the used non-parameter
// numeric arrays in letter order, then the string arrays in letter order.
// In:  x0 = unit Module*, w1 = letter, x2 = 0 numeric / 1 string array
// Out: x0 = d(L)
// Clobbers: x0, x9-x15.  Leaf, no frame.
// ---------------------------------------------------------------------
    .globl _bk_x64_unit_desc_index
    .p2align 2
_bk_x64_unit_desc_index:
    mov w1, w1
    mov x9, #0                      // count
    // numeric arrays below the limit: the letter (numeric) or all (string)
    mov x10, x1
    cbz x2, 1f
    mov x10, #NUM_LETTERS
1:
    add x11, x0, #IRM_ARRAYS
    mov x12, #0
2:
    cmp x12, x10
    b.hs 3f
    add x13, x11, x12, lsl #4
    ldr w14, [x13, #IRA_DIMS]
    ldr w15, [x13, #IRA_FLAGS]
    add x12, x12, #1
    cbz w14, 2b
    tst w15, #IRA_FLAG_PARAM
    b.ne 2b
    add x9, x9, #1
    b 2b
3:
    cbz x2, 6f
    // string arrays below the letter
    add x11, x0, #IRM_SARRAYS
    mov x12, #0
4:
    cmp x12, x1
    b.hs 6f
    add x13, x11, x12, lsl #4
    ldr w14, [x13, #IRA_DIMS]
    ldr w15, [x13, #IRA_FLAGS]
    add x12, x12, #1
    cbz w14, 4b
    tst w15, #IRA_FLAG_PARAM
    b.ne 4b
    add x9, x9, #1
    b 4b
6:
    mov x0, x9
    ret

// ---------------------------------------------------------------------
// _bk_x64_unit_cost -- SUBL_COST of a unit in 8-byte words (DESIGN.md
// 5.3.1): COST = SIZE/8 + frame(SUB body) + chain(u), with
//   frame(f)  = W(f) + L(f) + V(f) + RT_FRAME_EXTRA_WORDS
//   fchain(g) = frame(g) + max(0, max over the callfn/scallfn of g: fchain(h))
//   chain(u)  = max(0, max over the present FN functions g of u: fchain(g))
// fchain is memoised per function (FN calls form no cycle: a cycle, or a
// call of an absent function, is reported as invalid IR).
// In:  x0 = unit Module*, x1 = main Module*
// Out: x0 = COST, x1 = 0; or x1 = reason
// Clobbers: x0-x17
// Callee-saved used: x19 = unit, x20 = main, x21 = memo base (27 u64:
//                    0 = not computed, -1 = in progress), x22 = COST so far,
//                    x23 = function index
// Frame: 64 + 224 bytes (frame record, x19-x23, the memo)
// ---------------------------------------------------------------------
    .globl _bk_x64_unit_cost
    .p2align 2
_bk_x64_unit_cost:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]
    sub sp, sp, #224
    mov x19, x0
    mov x20, x1
    mov x21, sp
    // clear the memo (27 entries, 216 bytes)
    mov x9, #0
1:
    str xzr, [x21, x9, lsl #3]
    add x9, x9, #1
    cmp x9, #NUM_FUNCS
    b.lo 1b
    // SIZE / 8
    mov x0, x19
    bl _bk_x64_unit_layout
    cbnz x0, Lbk_x64_sub_cost_fail
    lsr x22, x7, #3
    // + frame(SUB body)
    mov x0, x19
    mov x1, x20
    mov x2, #FUNC_MAIN
    bl _bk_x64_func_shape
    cbnz x3, Lbk_x64_sub_cost_fail3
    add x22, x22, x0
    add x22, x22, x1
    add x22, x22, x2
    add x22, x22, #RT_FRAME_EXTRA_WORDS
    // + chain(u): the longest fchain over the unit's present FN functions
    mov x23, #FUNC_FN_BASE
    mov x9, #0
    str x9, [x21, #(NUM_FUNCS * 8)] // chain(u) so far (the memo's spare word)
2:
    add x9, x19, #IRM_FUNCS
    mov x10, #IRF_SIZE
    madd x9, x23, x10, x9
    ldr w10, [x9, #IRF_PRESENT]
    cbz w10, 3f
    mov x0, x23
    bl Lbk_x64_sub_fchain
    cbnz x1, Lbk_x64_sub_cost_ret
    ldr x9, [x21, #(NUM_FUNCS * 8)]
    cmp x0, x9
    csel x9, x0, x9, hi
    str x9, [x21, #(NUM_FUNCS * 8)]
3:
    add x23, x23, #1
    cmp x23, #NUM_FUNCS
    b.lo 2b
    ldr x9, [x21, #(NUM_FUNCS * 8)]
    add x0, x22, x9
    // the record holds COST as a u32
    lsr x9, x0, #32
    cbnz x9, Lbk_x64_sub_cost_big
    mov x1, #0
    b Lbk_x64_sub_cost_ret
Lbk_x64_sub_cost_big:
    adrp x1, Lbk_x64_sub_err_size@PAGE
    add x1, x1, Lbk_x64_sub_err_size@PAGEOFF
    b Lbk_x64_sub_cost_ret
Lbk_x64_sub_cost_fail3:
    mov x1, x3
    b Lbk_x64_sub_cost_ret
Lbk_x64_sub_cost_fail:
    mov x1, x0
Lbk_x64_sub_cost_ret:
    add sp, sp, #224
    ldr x23, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret
.if NUM_FUNCS * 8 + 8 > 224
    .error "x64_sub.s: the fchain memo does not fit its 224 bytes"
.endif

// ---------------------------------------------------------------------
// Lbk_x64_sub_fchain -- file-local, recursive: fchain(g) of _bk_x64_unit_cost.
// Private convention: x19 = unit Module*, x20 = main Module*, x21 = memo
// base, all preserved.
// In:  x0 = function index g (present)
// Out: x0 = fchain(g), x1 = 0; or x1 = reason
// Clobbers: x0-x17
// Callee-saved used: x22 = g, x23 = frame(g), x24 = longest callee chain,
//                    x25 = instruction cursor, x26 = end of the instructions
// Frame: 64 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lbk_x64_sub_fchain:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x22, x23, [sp, #16]
    stp x24, x25, [sp, #32]
    str x26, [sp, #48]
    mov x22, x0
    // memo: a value, or -1 while g is being computed (a call cycle)
    ldr x9, [x21, x22, lsl #3]
    cmn x9, #1
    b.eq Lbk_x64_sub_fc_bad
    cbz x9, 1f
    mov x0, x9
    mov x1, #0
    b Lbk_x64_sub_fc_ret
1:
    mov x9, #-1
    str x9, [x21, x22, lsl #3]
    // frame(g) = W + L + V + RT_FRAME_EXTRA_WORDS
    mov x0, x19
    mov x1, x20
    mov x2, x22
    bl _bk_x64_func_shape
    cbz x3, 2f
    mov x1, x3
    b Lbk_x64_sub_fc_ret
2:
    add x23, x0, x1
    add x23, x23, x2
    add x23, x23, #RT_FRAME_EXTRA_WORDS
    mov x24, #0
    // walk g's instructions for its FN calls
    add x9, x19, #IRM_FUNCS
    mov x10, #IRF_SIZE
    madd x9, x22, x10, x9
    ldr x25, [x9, #IRF_INSNS]
    ldr w26, [x9, #IRF_NINSNS]
    add x26, x25, x26, lsl #IRI_SHIFT
Lbk_x64_sub_fc_loop:
    cmp x25, x26
    b.hs Lbk_x64_sub_fc_done
    ldrh w9, [x25, #IRI_OP]
    cmp w9, #OP_CALLFN
    b.eq 3f
    cmp w9, #OP_SCALLFN
    b.ne Lbk_x64_sub_fc_next
3:
    // callee h = FUNC_FN_BASE + X, which must be a present FN of the unit
    ldr w9, [x25, #IRI_X]
    cmp w9, #NUM_LETTERS
    b.hs Lbk_x64_sub_fc_bad
    add x0, x9, #FUNC_FN_BASE
    add x9, x19, #IRM_FUNCS
    mov x10, #IRF_SIZE
    madd x9, x0, x10, x9
    ldr w10, [x9, #IRF_PRESENT]
    cbz w10, Lbk_x64_sub_fc_bad
    bl Lbk_x64_sub_fchain
    cbnz x1, Lbk_x64_sub_fc_ret
    cmp x0, x24
    csel x24, x0, x24, hi
Lbk_x64_sub_fc_next:
    add x25, x25, #IRI_SIZE
    b Lbk_x64_sub_fc_loop
Lbk_x64_sub_fc_done:
    add x0, x23, x24
    str x0, [x21, x22, lsl #3]
    mov x1, #0
    b Lbk_x64_sub_fc_ret
Lbk_x64_sub_fc_bad:
    adrp x1, Lbk_x64_sub_err_call@PAGE
    add x1, x1, Lbk_x64_sub_err_call@PAGEOFF
Lbk_x64_sub_fc_ret:
    ldr x26, [sp, #48]
    ldp x24, x25, [sp, #32]
    ldp x22, x23, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

// ---------------------------------------------------------------------
// _bk_x64_emit_subl -- emit the SUBL_* record of a unit and its descriptor
// templates (DESIGN.md 5.3.1 "Records", 5.4.6), in .data.rel.ro:
//       .p2align 3
//   .Lsubl_<u>:
//       .long SIZE, SUBNPARAMS, PARAMOFF, SDOFF, NSD, DESCOFF, NDESC, COST
//       .quad .Lsubt_<u>                (.quad 0 when NDESC = 0)
//       .byte p0, ..., p15              SUBL_PDIMS
//   .Lsubt_<u>:                         (only when NDESC > 0)
//       per descriptor, in d(L) order:
//       .quad <block offset of its elements>
//       .long dims, b1, b2, rowlen, letter, cap
// In:  x0 = OutBuf*, x1 = unit Module*, x2 = main Module*
// Out: x0 = 0 or reason
// Clobbers: x0-x17, d0-d7, d16-d31
// Callee-saved used: x19 = OutBuf*, x20 = unit, x21 = unit index u,
//                    x22 = letter, x23 = next numeric storage offset,
//                    x24 = next string element offset, x25 = IRA entry,
//                    x26 = NDESC
// Frame: 96 bytes (frame record, x19-x26, 16-byte PDIMS buffer at sp+80)
// ---------------------------------------------------------------------
    .globl _bk_x64_emit_subl
    .p2align 2
_bk_x64_emit_subl:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    mov x19, x0
    mov x20, x1
    ldr w21, [x20, #IRM_UNITIDX]
    // COST first (it also validates the layout and every frame)
    mov x0, x20
    mov x1, x2
    bl _bk_x64_unit_cost
    cbnz x1, Lbk_x64_sub_es_fail
    mov x22, x0                     // COST, until the letter loop
    mov x0, x20
    bl _bk_x64_unit_layout
    cbnz x0, Lbk_x64_sub_es_ret
    // remember what the templates need: STOREOFF, the first string
    // element, NDESC
    mov x23, x6
    ldr w9, [x20, #IRM_NSTEMPS]
    add x9, x9, #(NUM_LETTERS * SLOT_PER_LETTER)
    add x24, x2, x9, lsl #4
    mov x26, x5
    // ".Lsubl_<u>:" / ".long SIZE, NP, PARAMOFF, SDOFF, NSD"
    stp x3, x5, [sp, #80]           // DESCOFF, NDESC across the call
    mov x9, x4                      // NSD
    mov x10, x1                     // PARAMOFF
    mov x6, x2                      // SDOFF
    mov x3, x7                      // SIZE
    ldr w4, [x20, #IRM_SUBNPARAMS]
    mov x5, x10
    mov x7, x9
    mov x2, x21
    mov x0, x19
    adrp x1, Lbk_x64_sub_subl_fmt@PAGE
    add x1, x1, Lbk_x64_sub_subl_fmt@PAGEOFF
    bl _bk_x64_fmt
    // ", DESCOFF, NDESC, COST"
    ldp x2, x3, [sp, #80]
    mov x4, x22
    mov x0, x19
    adrp x1, Lbk_x64_sub_subl_tail@PAGE
    add x1, x1, Lbk_x64_sub_subl_tail@PAGEOFF
    bl _bk_x64_fmt
    // ".quad .Lsubt_<u>" or ".quad 0"
    mov x2, x21
    mov x0, x19
    adrp x1, Lbk_x64_sub_subt_ref@PAGE
    add x1, x1, Lbk_x64_sub_subt_ref@PAGEOFF
    cbnz x26, 1f
    adrp x1, Lbk_x64_sub_quad0@PAGE
    add x1, x1, Lbk_x64_sub_quad0@PAGEOFF
1:
    bl _bk_x64_fmt

    // ---- SUBL_PDIMS: SUBD_* per parameter, 0 when unused ----------------
    stp xzr, xzr, [sp, #80]
    ldr w9, [x20, #IRM_SUBNPARAMS]
    mov x10, #0
Lbk_x64_sub_es_pd_loop:
    cmp x10, x9
    b.hs Lbk_x64_sub_es_pd_done
    add x11, x20, #IRM_SUBPKINDS
    ldrb w11, [x11, x10]
    add x12, x20, #IRM_SUBPARAMS
    ldr w12, [x12, x10, lsl #2]
    // a scalar parameter (number or string) is not checked
    cmp w11, #SUBP_ARR
    b.eq 2f
    cmp w11, #SUBP_SARR
    b.ne Lbk_x64_sub_es_pd_next
    add x13, x20, #IRM_SARRAYS
    b 3f
2:
    add x13, x20, #IRM_ARRAYS
3:
    // an array parameter: its DIMS 1 / 2 / IRA_DIMS_ANY is the SUBD_* value
    cmp w12, #NUM_LETTERS
    b.hs Lbk_x64_sub_es_bad_param
    add x13, x13, x12, lsl #4
    ldr w14, [x13, #IRA_DIMS]
    sub w15, w14, #1
    cmp w15, #(IRA_DIMS_ANY - 1)
    b.hi Lbk_x64_sub_es_bad_param
    add x15, sp, #80
    strb w14, [x15, x10]
Lbk_x64_sub_es_pd_next:
    add x10, x10, #1
    b Lbk_x64_sub_es_pd_loop
Lbk_x64_sub_es_pd_done:
    mov x0, x19
    add x1, sp, #80
    mov x2, #LIM_SUB_PARAMS
    bl _bk_x64_bytes

    // ---- .Lsubt_<u>: the descriptor templates, d(L) order -----------------
    cbz x26, Lbk_x64_sub_es_ok
    mov x2, x21
    mov x0, x19
    adrp x1, Lbk_x64_sub_subt_label@PAGE
    add x1, x1, Lbk_x64_sub_subt_label@PAGEOFF
    bl _bk_x64_fmt
    // numeric arrays: elements in the block's numeric storage
    mov x22, #0
Lbk_x64_sub_es_num_loop:
    add x25, x20, #IRM_ARRAYS
    add x25, x25, x22, lsl #4
    ldr w9, [x25, #IRA_DIMS]
    cbz w9, 4f
    ldr w10, [x25, #IRA_FLAGS]
    tst w10, #IRA_FLAG_PARAM
    b.ne 4f
    mov x0, x23
    bl Lbk_x64_sub_es_template      // x0 = cap
    add x23, x23, x0, lsl #3
4:
    add x22, x22, #1
    cmp x22, #NUM_LETTERS
    b.lo Lbk_x64_sub_es_num_loop
    // string arrays: elements among the block's SD records
    mov x22, #0
Lbk_x64_sub_es_str_loop:
    add x25, x20, #IRM_SARRAYS
    add x25, x25, x22, lsl #4
    ldr w9, [x25, #IRA_DIMS]
    cbz w9, 5f
    ldr w10, [x25, #IRA_FLAGS]
    tst w10, #IRA_FLAG_PARAM
    b.ne 5f
    mov x0, x24
    bl Lbk_x64_sub_es_template
    add x24, x24, x0, lsl #4
5:
    add x22, x22, #1
    cmp x22, #NUM_LETTERS
    b.lo Lbk_x64_sub_es_str_loop
Lbk_x64_sub_es_ok:
    mov x0, #0
    b Lbk_x64_sub_es_ret
Lbk_x64_sub_es_bad_param:
    adrp x0, Lbk_x64_sub_err_param@PAGE
    add x0, x0, Lbk_x64_sub_err_param@PAGEOFF
    b Lbk_x64_sub_es_ret
Lbk_x64_sub_es_fail:
    mov x0, x1
Lbk_x64_sub_es_ret:
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret

// ---------------------------------------------------------------------
// Lbk_x64_sub_es_template -- file-local: one descriptor template
//   "    .quad <offset>" / "    .long dims, b1, b2, rowlen, letter, cap"
// with rowlen = b2+1 for a table, 1 for a list, cap = (b1+1)*(b2+1) (b2 = 0
// for a list), as .Ldesc_ / .Lsdesc_ (DESIGN.md 5.4.3).
// In:  x0 = block offset of the elements; x19 = OutBuf*, x22 = letter,
//      x25 = the IRA entry (DIMS 1 or 2, checked by the layout)
// Out: x0 = cap
// Clobbers: x0-x17 (it calls _bk_x64_fmt)
// Callee-saved used: none (x19, x22 and x25 are only read)
// Frame: 32 bytes (frame record, cap)
// ---------------------------------------------------------------------
    .p2align 2
Lbk_x64_sub_es_template:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    ldr w3, [x25, #IRA_DIMS]
    ldr w4, [x25, #IRA_B1]
    ldr w5, [x25, #IRA_B2]
    // rowlen
    add x6, x5, #1
    cmp w3, #1
    mov x9, #1
    csel x6, x9, x6, eq
    // cap
    add x9, x4, #1
    add x10, x5, #1
    mul x9, x9, x10
    str x9, [sp, #16]
    mov x2, x0
    mov x7, x22
    mov x0, x19
    adrp x1, Lbk_x64_sub_tmpl_fmt@PAGE
    add x1, x1, Lbk_x64_sub_tmpl_fmt@PAGEOFF
    bl _bk_x64_fmt
    // ", <cap>\n" closes the .long line
    ldr x2, [sp, #16]
    mov x0, x19
    adrp x1, Lbk_x64_sub_tmpl_tail@PAGE
    add x1, x1, Lbk_x64_sub_tmpl_tail@PAGEOFF
    bl _bk_x64_fmt
    ldr x0, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

    .section __TEXT,__cstring,cstring_literals
Lbk_x64_sub_subl_fmt:
    .ascii "    .p2align 3\n"
    .ascii ".Lsubl_%u:\n"
    .asciz "    .long %u, %u, %u, %u, %u"
Lbk_x64_sub_subl_tail:
    .asciz ", %u, %u, %u\n"
Lbk_x64_sub_subt_ref:
    .asciz "    .quad .Lsubt_%u\n"
Lbk_x64_sub_quad0:
    .asciz "    .quad 0\n"
Lbk_x64_sub_subt_label:
    .asciz ".Lsubt_%u:\n"
Lbk_x64_sub_tmpl_fmt:
    .ascii "    .quad %u\n"
    .asciz "    .long %u, %u, %u, %u, %u"
Lbk_x64_sub_tmpl_tail:
    .asciz ", %u\n"
Lbk_x64_sub_err_np:
    .asciz "x86_64-linux backend: SUB unit with too many parameters"
Lbk_x64_sub_err_dims:
    .asciz "x86_64-linux backend: SUB unit array with more than 2 dimensions"
Lbk_x64_sub_err_size:
    .asciz "x86_64-linux backend: SUB unit activation too large"
Lbk_x64_sub_err_call:
    .asciz "x86_64-linux backend: bad FN call in a SUB unit (absent function or call cycle)"
Lbk_x64_sub_err_param:
    .asciz "x86_64-linux backend: bad SUB array parameter"

// The record and templates are written field by field: keep them tied to
// runtime.inc (SUBL_*, SUBD_*, RTA_*) and ir.inc (IRA_DIMS_ANY).
.if (SUBL_BLOCKSIZE != 0) || (SUBL_NPARAMS != 4) || (SUBL_PARAMOFF != 8) || (SUBL_SDOFF != 12) || (SUBL_NSD != 16) || (SUBL_DESCOFF != 20) || (SUBL_NDESC != 24) || (SUBL_COST != 28) || (SUBL_DESCS != 32) || (SUBL_PDIMS != 40) || (SUBL_RECSIZE != 40 + LIM_SUB_PARAMS)
    .error "x64_sub.s emits SUBL_* records with a different layout than runtime.inc"
.endif
.if (SUBD_SCALAR != 0) || (SUBD_LIST != 1) || (SUBD_TABLE != 2) || (SUBD_ANY != IRA_DIMS_ANY) || (IRA_DIMS_ANY != 3)
    .error "x64_sub.s writes an array parameter's DIMS as its SUBD_* value"
.endif
.if (RTA_DATA != 0) || (RTA_DIMS != 8) || (RTA_SIZE != 32) || (SD_SIZE != 16)
    .error "x64_sub.s lays out RTA_* templates and SD records differently than runtime.inc"
.endif

