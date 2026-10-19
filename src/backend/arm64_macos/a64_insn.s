// =====================================================================
// src/backend/arm64_macos/a64_insn.s -- per-function and per-opcode code
// generation for the arm64-macos backend (docs/DESIGN.md section 5.3
// "Frames and temps" and "Per-opcode translation").
//
// Exports: _bk_arm64_emit_func
// Uses:    _bk_arm64_fmt, _bk_arm64_movimm, _bk_arm64_memop (a64_text.s)
//
// Temp slots: a temp is never read after the next `line` (IR.md 1), so
// slots are reused per line: slot(t) = t - base, base = the first temp
// defined after the most recent `line` (start of function counts as a
// `line`). W = the largest number of temps one such segment needs.
// After the W temp slots come the local cells (parameters; for a
// multi-line function also the function value and the saved run-time
// line), cell k at [sp, #8*(W+k)]. An sref temp holds a pointer and is
// moved with x registers; every other temp is a double in a d register.
// Labels of main are Lbsk_L<id>, those of a multi-line function FN<L>
// are Lfn_<L>_L<id> (Lbk_in_lblpfx).
// =====================================================================
.include "baysick.inc"

.equ BK_IMM12_MAX,  4095            // largest plain "sub sp, sp, #imm"

// ---------------------------------------------------------------------
// FMT label -- append the format string `label` via _bk_arm64_fmt with
// x0 = OutBuf* (x19); arguments must already be in x2..x7.
// Clobbers x0, x1 and everything _bk_arm64_fmt clobbers.
// ---------------------------------------------------------------------
.macro FMT label
    mov x0, x19
    adrp x1, \label@PAGE
    add x1, x1, \label@PAGEOFF
    bl _bk_arm64_fmt
.endm

// FAIL label -- abort the function emission with reason string `label`.
.macro FAIL label
    adrp x0, \label@PAGE
    add x0, x0, \label@PAGEOFF
    b Lbk_in_fail
.endm

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _bk_arm64_emit_func -- emit one IR function (main as _bsk_program, or
// FN letter L as Lfn_<L>) with prologue, body and (FN) epilogues.
// In:  x0 = OutBuf*, x1 = const Module*, x2 = function index
//      (FUNC_MAIN or FUNC_FN_BASE + letter); the function must be present
// Out: x0 = 0 on success, else pointer to a NUL-terminated reason
// Clobbers: x0-x17, d0-d7, d16-d31
// Callee-saved used (this is also the private state that the file-local
// helpers below read):
//   x19 = OutBuf*            x20 = Module*
//   x21 = current IRI record x22 = end of the instruction array
//   x23 = W (temp slots)     x24 = base temp of the current segment,
//                                  or -1 before the first definition
//   x25 = function index     x26 = sp right after the prologue
//                                  (unwind point for Lbk_in_fail)
//   x27 = Function*          x28 = 1 + highest temp defined in the
//                                  current segment (0 if none); during
//                                  the prologue x28 = NP and x24 = k
// Frame: 96 bytes (frame record + x19-x28)
// ---------------------------------------------------------------------
    .globl _bk_arm64_emit_func
    .p2align 2
_bk_arm64_emit_func:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    mov x26, sp
    mov x19, x0
    mov x20, x1
    mov x25, x2
    // x27 = &funcs[index]
    add x27, x20, #IRM_FUNCS
    mov x9, #IRF_SIZE
    madd x27, x25, x9, x27
    // x21 = first instruction, x22 = one past the last
    ldr x21, [x27, #IRF_INSNS]
    ldr w9, [x27, #IRF_NINSNS]
    add x22, x21, x9, lsl #IRI_SHIFT

    // ---- pass 1: W = max temps defined in one line segment ----------
    mov x23, #0
    mov x10, #-1                    // segment base, -1 = none yet
    mov x11, x21
Lbk_in_w_loop:
    cmp x11, x22
    b.hs Lbk_in_w_done
    ldrh w12, [x11, #IRI_OP]
    cmp w12, #OP_LINE
    b.ne 1f
    // a `line` starts a new segment
    mov x10, #-1
    b Lbk_in_w_next
1:
    ldr w12, [x11, #IRI_DST]
    cmn w12, #1                     // IR_NONE: defines nothing
    b.eq Lbk_in_w_next
    // first definition of the segment fixes its base
    cmn x10, #1
    csel x10, x12, x10, eq
    cmp x12, x10
    b.lo Lbk_in_w_order
    // W = max(W, t - base + 1)
    sub x13, x12, x10
    add x13, x13, #1
    cmp x13, x23
    csel x23, x13, x23, hi
Lbk_in_w_next:
    add x11, x11, #IRI_SIZE
    b Lbk_in_w_loop
Lbk_in_w_order:
    FAIL Lbk_in_err_order
Lbk_in_w_done:

    // ---- function label --------------------------------------------------
    cbnz x25, 1f
    FMT Lbk_in_main_label
    b 2f
1:
    sub x2, x25, #FUNC_FN_BASE
    FMT Lbk_in_fn_label
2:
    // ---- prologue: frame record, x19/x20, temp area, globals base -------
    FMT Lbk_in_prologue
    // frame = align16(8*(W+L) + 8): temps + local cells (+ one spare word)
    bl Lbk_in_fn_shape              // w0 = NP, w1 = multi-line flag
    cbnz w1, 1f
    cmp w0, #1                      // L = max(1, NP)
    mov w2, #1
    csel w2, w0, w2, hi
    b 2f
1:
    add w2, w0, #2                  // L = NP + 2
2:
    add x9, x23, x2
    lsl x9, x9, #3
    add x9, x9, #8 + 15
    and x2, x9, #~15
    cmp x2, #BK_IMM12_MAX
    b.hi 1f
    FMT Lbk_in_sub_imm
    b 2f
1:
    // large frame: size via x16
    mov x0, x19
    adrp x1, Lbk_in_x16@PAGE
    add x1, x1, Lbk_in_x16@PAGEOFF
    bl _bk_arm64_movimm
    FMT Lbk_in_sub_x16
2:
    FMT Lbk_in_globals
    // FN functions spill their arguments d0..d<NP-1> to cells 0..NP-1
    // (x28 = NP and x24 = k are free until pass 2 starts)
    bl Lbk_in_fn_shape
    mov x28, x0
    mov x24, #0
Lbk_in_pro_loop:
    cmp x24, x28
    b.hs Lbk_in_pro_done
    adrp x0, Lbk_in_str@PAGE
    add x0, x0, Lbk_in_str@PAGEOFF
    adrp x1, Lbk_in_pd@PAGE
    add x1, x1, Lbk_in_pd@PAGEOFF
    mov x2, x24
    mov x3, x24
    bl Lbk_in_cell
    add x24, x24, #1
    b Lbk_in_pro_loop
Lbk_in_pro_done:
    // multi-line function: value := 0, save the caller's run-time line
    bl Lbk_in_fn_shape
    cbz w1, Lbk_in_pro_end
    mov x28, x0                     // NP
    FMT Lbk_in_ml_zero
    adrp x0, Lbk_in_str@PAGE
    add x0, x0, Lbk_in_str@PAGEOFF
    adrp x1, Lbk_in_px@PAGE
    add x1, x1, Lbk_in_px@PAGEOFF
    mov x2, #17
    mov x3, x28                     // cell NP: the function value
    bl Lbk_in_cell
    FMT Lbk_in_ml_saveline
    adrp x0, Lbk_in_str@PAGE
    add x0, x0, Lbk_in_str@PAGEOFF
    adrp x1, Lbk_in_px@PAGE
    add x1, x1, Lbk_in_px@PAGEOFF
    mov x2, #17
    add x3, x28, #1                 // cell NP+1: the saved run-time line
    bl Lbk_in_cell
Lbk_in_pro_end:

    // ---- pass 2: translate every instruction ----------------------------
    mov x24, #-1
    mov x28, #0
Lbk_in_loop:
    cmp x21, x22
    b.hs Lbk_in_ok
    ldrh w9, [x21, #IRI_OP]
    cmp w9, #OP_COUNT
    b.hs Lbk_in_bad_op
    // dispatch through the relative jump table
    adr x10, Lbk_in_table
    ldrsw x11, [x10, x9, lsl #2]
    add x10, x10, x11
    br x10
Lbk_in_next:
    add x21, x21, #IRI_SIZE
    b Lbk_in_loop

Lbk_in_ok:
    mov x0, #0
    b Lbk_in_return
Lbk_in_bad_op:
    FAIL Lbk_in_err_op
// Lbk_in_fail -- non-local error exit, reachable by a plain branch from
// this function or from any of the file-local helpers below at any call
// depth: x0 = reason; restores sp/x29 to this function's frame.
Lbk_in_fail:
    mov sp, x26
    mov x29, x26
Lbk_in_return:
    ldp x27, x28, [sp, #80]
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret

// ======================================================================
// Opcode cases. Entered by `br` from the dispatcher with x21 = record;
// each one ends with `b Lbk_in_next`.
// ======================================================================

Lbk_in_op_nop:
    b Lbk_in_next

Lbk_in_op_line:
    // "<label>:" then store the BASIC line number into _bsk_curline
    bl Lbk_in_lblpfx
    mov x2, x0
    ldr w3, [x21, #IRI_X]
    FMT Lbk_in_label_def
    FMT Lbk_in_line_adrp
    ldr x2, [x21, #IRI_IMM]
    lsr x9, x2, #32
    cbnz x9, Lbk_in_line_range
    mov x0, x19
    adrp x1, Lbk_in_w17@PAGE
    add x1, x1, Lbk_in_w17@PAGEOFF
    bl _bk_arm64_movimm
    FMT Lbk_in_line_str
    // a new temp segment starts here
    mov x24, #-1
    mov x28, #0
    b Lbk_in_next
Lbk_in_line_range:
    FAIL Lbk_in_err_line

Lbk_in_op_label:
    bl Lbk_in_lblpfx
    mov x2, x0
    ldr w3, [x21, #IRI_X]
    FMT Lbk_in_label_def
    b Lbk_in_next

Lbk_in_op_const:
    // x16 = bits; d0 = x16; store
    mov x0, x19
    adrp x1, Lbk_in_x16@PAGE
    add x1, x1, Lbk_in_x16@PAGEOFF
    ldr x2, [x21, #IRI_IMM]
    bl _bk_arm64_movimm
    FMT Lbk_in_fmov_d0
    b Lbk_in_store_dst

Lbk_in_op_ldv:
    // d0 = global cell X
    adrp x0, Lbk_in_ldr@PAGE
    add x0, x0, Lbk_in_ldr@PAGEOFF
    bl Lbk_in_global_access
    b Lbk_in_store_dst

Lbk_in_op_stv:
    // global cell X = A
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load
    adrp x0, Lbk_in_str@PAGE
    add x0, x0, Lbk_in_str@PAGEOFF
    bl Lbk_in_global_access
    b Lbk_in_next

Lbk_in_op_arith:
    // add/sub/mul: d0 = A op B, inline overflow check, store
    bl Lbk_in_load_ab
    ldrh w9, [x21, #IRI_OP]
    sub w9, w9, #OP_ADD
    adrp x10, Lbk_in_arith_names@PAGE
    add x10, x10, Lbk_in_arith_names@PAGEOFF
    ldr x2, [x10, x9, lsl #3]
    FMT Lbk_in_arith_fmt
    mov x2, #ERR_OVERFLOW
    FMT Lbk_in_ovf_check
    b Lbk_in_store_dst

Lbk_in_op_div:
    bl Lbk_in_load_ab
    adrp x2, Lbk_in_rt_div@PAGE
    add x2, x2, Lbk_in_rt_div@PAGEOFF
    FMT Lbk_in_bl_fmt
    b Lbk_in_store_dst

Lbk_in_op_pow:
    bl Lbk_in_load_ab
    adrp x2, Lbk_in_rt_pow@PAGE
    add x2, x2, Lbk_in_rt_pow@PAGEOFF
    FMT Lbk_in_bl_fmt
    b Lbk_in_store_dst

Lbk_in_op_neg:
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load
    FMT Lbk_in_fneg
    b Lbk_in_store_dst

Lbk_in_op_builtin:
    // sin..int: d0 = A; bl _bsk_<name>; store
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load
    ldrh w9, [x21, #IRI_OP]
    sub w9, w9, #OP_SIN
    adrp x10, Lbk_in_builtin_names@PAGE
    add x10, x10, Lbk_in_builtin_names@PAGEOFF
    ldr x2, [x10, x9, lsl #3]
    FMT Lbk_in_bl_fmt
    b Lbk_in_store_dst

Lbk_in_op_rnd:
    adrp x2, Lbk_in_rt_rnd@PAGE
    add x2, x2, Lbk_in_rt_rnd@PAGEOFF
    FMT Lbk_in_bl_fmt
    b Lbk_in_store_dst

Lbk_in_op_ald1:
    // x0 = &Ldesc_<L>; d0 = A; x0 = _bsk_aref1; d0 = [x0]
    bl Lbk_in_desc_addr
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load
    adrp x2, Lbk_in_rt_aref1@PAGE
    add x2, x2, Lbk_in_rt_aref1@PAGEOFF
    FMT Lbk_in_bl_fmt
    FMT Lbk_in_ldr_elem
    b Lbk_in_store_dst

Lbk_in_op_ald2:
    bl Lbk_in_desc_addr
    bl Lbk_in_load_ab
    adrp x2, Lbk_in_rt_aref2@PAGE
    add x2, x2, Lbk_in_rt_aref2@PAGEOFF
    FMT Lbk_in_bl_fmt
    FMT Lbk_in_ldr_elem
    b Lbk_in_store_dst

Lbk_in_op_ast1:
    // x0 = element address of A; d0 = B; [x0] = d0
    bl Lbk_in_desc_addr
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load
    adrp x2, Lbk_in_rt_aref1@PAGE
    add x2, x2, Lbk_in_rt_aref1@PAGEOFF
    FMT Lbk_in_bl_fmt
    ldr w0, [x21, #IRI_B]
    mov x1, #0
    bl Lbk_in_load
    FMT Lbk_in_str_elem
    b Lbk_in_next

Lbk_in_op_ast2:
    // x0 = element address of (A, B); d0 = C; [x0] = d0
    bl Lbk_in_desc_addr
    bl Lbk_in_load_ab
    adrp x2, Lbk_in_rt_aref2@PAGE
    add x2, x2, Lbk_in_rt_aref2@PAGEOFF
    FMT Lbk_in_bl_fmt
    ldr w0, [x21, #IRI_C]
    mov x1, #0
    bl Lbk_in_load
    FMT Lbk_in_str_elem
    b Lbk_in_next

Lbk_in_op_callfn:
    // d0 = A (nothing for a call without arguments); bl Lfn_<L>; store
    ldr w0, [x21, #IRI_A]
    cmn w0, #1                      // IR_NONE: no argument
    b.eq 1f
    mov x1, #0
    bl Lbk_in_load
1:
    ldr w2, [x21, #IRI_X]
    cmp w2, #NUM_LETTERS
    b.hs Lbk_in_bad_letter
    FMT Lbk_in_bl_fn
    b Lbk_in_store_dst

Lbk_in_op_param:
    // d0 = parameter cell k = [sp, #8*(W+k)], k = IMM
    cbz x25, Lbk_in_bad_place
    ldr x3, [x21, #IRI_IMM]
    bl Lbk_in_check_cell
    adrp x0, Lbk_in_ldr@PAGE
    add x0, x0, Lbk_in_ldr@PAGEOFF
    adrp x1, Lbk_in_pd@PAGE
    add x1, x1, Lbk_in_pd@PAGEOFF
    mov x2, #0
    bl Lbk_in_cell
    b Lbk_in_store_dst

Lbk_in_op_ret:
    // d0 = A; a multi-line function first restores the caller's run-time
    // line from its cell NP+1; then the epilogue
    cbz x25, Lbk_in_bad_place
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load
    bl Lbk_in_fn_shape
    cbz w1, 1f
    add x3, x0, #1
    adrp x0, Lbk_in_ldr@PAGE
    add x0, x0, Lbk_in_ldr@PAGEOFF
    adrp x1, Lbk_in_px@PAGE
    add x1, x1, Lbk_in_px@PAGEOFF
    mov x2, #17
    bl Lbk_in_cell
    FMT Lbk_in_line_adrp
    FMT Lbk_in_line_str
1:
    FMT Lbk_in_epilogue
    b Lbk_in_next

Lbk_in_op_jmp:
    bl Lbk_in_lblpfx
    mov x2, x0
    ldr w3, [x21, #IRI_X]
    FMT Lbk_in_b_label
    b Lbk_in_next

Lbk_in_op_jcmp:
    // fcmp; skip the branch on the inverse relation
    bl Lbk_in_load_ab
    ldrh w9, [x21, #IRI_REL]
    sub w9, w9, #REL_EQ
    cmp w9, #REL_GE - REL_EQ
    b.hi Lbk_in_bad_rel
    adrp x10, Lbk_in_inverse_cc@PAGE
    add x10, x10, Lbk_in_inverse_cc@PAGEOFF
    ldr x2, [x10, x9, lsl #3]
    bl Lbk_in_lblpfx
    mov x3, x0
    ldr w4, [x21, #IRI_X]
    FMT Lbk_in_jcmp_fmt
    b Lbk_in_next

Lbk_in_op_jfor:
    // d0 = value, d1 = limit, d2 = step; jump if exhausted
    bl Lbk_in_load_ab
    ldr w0, [x21, #IRI_C]
    mov x1, #2
    bl Lbk_in_load
    bl Lbk_in_lblpfx
    mov x2, x0
    ldr w3, [x21, #IRI_X]
    mov x4, x0
    mov x5, x3
    FMT Lbk_in_jfor_fmt
    b Lbk_in_next

Lbk_in_op_gosub:
    // push the address of the return label, jump to the target
    ldr x2, [x21, #IRI_IMM]
    lsr x9, x2, #32
    cbnz x9, Lbk_in_bad_label
    bl Lbk_in_lblpfx
    mov x3, x2                      // return label id
    mov x2, x0
    mov x4, x0
    mov x5, x3
    mov x6, x0
    ldr w7, [x21, #IRI_X]
    FMT Lbk_in_gosub_fmt
    b Lbk_in_next

Lbk_in_op_return:
    FMT Lbk_in_return_fmt
    b Lbk_in_next

Lbk_in_op_read:
    adrp x2, Lbk_in_rt_read@PAGE
    add x2, x2, Lbk_in_rt_read@PAGEOFF
    FMT Lbk_in_bl_fmt
    b Lbk_in_store_dst

Lbk_in_op_prnum:
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load
    adrp x2, Lbk_in_rt_prnum@PAGE
    add x2, x2, Lbk_in_rt_prnum@PAGEOFF
    FMT Lbk_in_bl_fmt
    b Lbk_in_next

Lbk_in_op_prstr:
    // x0 = &Lstr_<id>, x1 = length, bl _bsk_print_str
    ldr w2, [x21, #IRI_X]
    ldr w9, [x20, #IRM_NSTRINGS]
    cmp w2, w9
    b.hs Lbk_in_bad_string
    mov x3, x2
    FMT Lbk_in_prstr_addr
    ldr w9, [x21, #IRI_X]
    ldr x10, [x20, #IRM_STRINGS]
    add x10, x10, x9, lsl #4
    ldr w2, [x10, #IRS_LEN]
    mov x0, x19
    adrp x1, Lbk_in_x1@PAGE
    add x1, x1, Lbk_in_x1@PAGEOFF
    bl _bk_arm64_movimm
    adrp x2, Lbk_in_rt_prstr@PAGE
    add x2, x2, Lbk_in_rt_prstr@PAGEOFF
    FMT Lbk_in_bl_fmt
    b Lbk_in_next

Lbk_in_op_prcomma:
    adrp x2, Lbk_in_rt_prcomma@PAGE
    add x2, x2, Lbk_in_rt_prcomma@PAGEOFF
    FMT Lbk_in_bl_fmt
    b Lbk_in_next

Lbk_in_op_prsemi:
    adrp x2, Lbk_in_rt_prsemi@PAGE
    add x2, x2, Lbk_in_rt_prsemi@PAGEOFF
    FMT Lbk_in_bl_fmt
    b Lbk_in_next

Lbk_in_op_prnl:
    adrp x2, Lbk_in_rt_prnl@PAGE
    add x2, x2, Lbk_in_rt_prnl@PAGEOFF
    FMT Lbk_in_bl_fmt
    b Lbk_in_next

Lbk_in_op_end:
    // END and STOP: normal termination
    adrp x2, Lbk_in_rt_end@PAGE
    add x2, x2, Lbk_in_rt_end@PAGEOFF
    FMT Lbk_in_bl_fmt
    b Lbk_in_next

// ---- MAT statements (docs/DESIGN.md 5.3) ---------------------------------
// MAT REDIM: x0 = &Ldesc_<X>, d0 = rows (A); with B: d1 = cols, redim2.
Lbk_in_op_matredim:
    mov w0, #0
    mov x1, #IRI_X
    bl Lbk_in_desc_reg
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load
    ldr w9, [x21, #IRI_B]
    cmn w9, #1                      // IR_NONE: one-dimensional form
    b.eq 1f
    mov w0, w9
    mov x1, #1
    bl Lbk_in_load
    adrp x2, Lbk_in_rt_mat_redim2@PAGE
    add x2, x2, Lbk_in_rt_mat_redim2@PAGEOFF
    b 2f
1:
    adrp x2, Lbk_in_rt_mat_redim1@PAGE
    add x2, x2, Lbk_in_rt_mat_redim1@PAGEOFF
2:
    FMT Lbk_in_bl_fmt
    b Lbk_in_next

// MAT READ / ZER / CON / IDN: x0 = &Ldesc_<X>; bl _bsk_mat_<name>.
Lbk_in_op_mat0:
    mov w0, #0
    mov x1, #IRI_X
    bl Lbk_in_desc_reg
    b Lbk_in_mat_call

// MAT PRINT: x0 = &Ldesc_<X>, w1 = IMM (MATPR_*).
Lbk_in_op_matprint:
    mov w0, #0
    mov x1, #IRI_X
    bl Lbk_in_desc_reg
    ldr x2, [x21, #IRI_IMM]
    FMT Lbk_in_mov_w1
    b Lbk_in_mat_call

// MAT COPY / TRN / INV: x0 = &Ldesc_<X>, x1 = &Ldesc_<A>.
Lbk_in_op_mat1:
    mov w0, #0
    mov x1, #IRI_X
    bl Lbk_in_desc_reg
    mov w0, #1
    mov x1, #IRI_A
    bl Lbk_in_desc_reg
    b Lbk_in_mat_call

// MAT ADD / SUB / MUL: x0 = X, x1 = A, x2 = B descriptors.
Lbk_in_op_mat2:
    mov w0, #0
    mov x1, #IRI_X
    bl Lbk_in_desc_reg
    mov w0, #1
    mov x1, #IRI_A
    bl Lbk_in_desc_reg
    mov w0, #2
    mov x1, #IRI_B
    bl Lbk_in_desc_reg
    b Lbk_in_mat_call

// MAT scale: x0 = &Ldesc_<X>, x1 = &Ldesc_<B>, d0 = scalar temp A.
Lbk_in_op_matscale:
    mov w0, #0
    mov x1, #IRI_X
    bl Lbk_in_desc_reg
    mov w0, #1
    mov x1, #IRI_B
    bl Lbk_in_desc_reg
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load
    // fall through

// common tail: bl <runtime name of the current MAT opcode>
Lbk_in_mat_call:
    ldrh w9, [x21, #IRI_OP]
    sub w9, w9, #OP_MATREDIM
    adrp x10, Lbk_in_mat_names@PAGE
    add x10, x10, Lbk_in_mat_names@PAGEOFF
    ldr x2, [x10, x9, lsl #3]
    FMT Lbk_in_bl_fmt
    b Lbk_in_next


// ---- Third and Fourth Edition opcodes (docs/DESIGN.md 5.3) ---------------
// An sref temp holds the address of an SD record: it is stored with
// "str x0" and loaded with "ldr x<n>"; every other temp is a double.

// common tail: store x0 (an sref) into the DST temp's slot
Lbk_in_store_sref:
    ldr w0, [x21, #IRI_DST]
    mov x1, #0
    bl Lbk_in_store_x
    b Lbk_in_next

// SLIT: x0 = &Lsd_<id>
Lbk_in_op_slit:
    ldr w2, [x21, #IRI_X]
    ldr w9, [x20, #IRM_NSTRINGS]
    cmp w2, w9
    b.hs Lbk_in_bad_string
    mov x3, x2
    FMT Lbk_in_slit_fmt
    b Lbk_in_store_sref

// SVAR: x0 = &_bsk_svars + 16*slot (offsets above 4095 go through x16)
Lbk_in_op_svar:
    ldr w9, [x21, #IRI_X]
    cmp w9, #NUM_STRING_SLOTS
    b.hs Lbk_in_bad_slot
    FMT Lbk_in_svar_base
    ldr w9, [x21, #IRI_X]
.if (SD_SIZE != 16)
    .error "a64_insn.s svar shifts the slot by 4: SD_SIZE must be 16"
.endif
    lsl x9, x9, #4                  // SD_SIZE * slot
    cbz x9, Lbk_in_store_sref
    cmp x9, #BK_IMM12_MAX
    b.hi 1f
    mov x2, x9
    FMT Lbk_in_svar_add
    b Lbk_in_store_sref
1:
    mov x0, x19
    adrp x1, Lbk_in_x16@PAGE
    add x1, x1, Lbk_in_x16@PAGEOFF
    mov x2, x9
    bl _bk_arm64_movimm
    FMT Lbk_in_svar_addx16
    b Lbk_in_store_sref

// SALD1: x0 = &Lsdesc_<X>, d0 = A; x0 = _bsk_saref1(...); DST := x0
Lbk_in_op_sald1:
    mov w0, #0
    mov x1, #IRI_X
    bl Lbk_in_sdesc_reg
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load
    bl Lbk_in_ed_emit_call
    b Lbk_in_store_sref

// SSET: x0 = A, x1 = B (both sref)
Lbk_in_op_sset:
    bl Lbk_in_load_ab_x
    bl Lbk_in_ed_emit_call
    b Lbk_in_next

// SJCMP: x0 = A, x1 = B; _bsk_str_cmp; compare w0 with 0, jump on REL
Lbk_in_op_sjcmp:
    bl Lbk_in_load_ab_x
    bl Lbk_in_ed_emit_call
    ldrh w9, [x21, #IRI_REL]
    sub w9, w9, #REL_EQ
    cmp w9, #REL_GE - REL_EQ
    b.hi Lbk_in_bad_rel
    adrp x10, Lbk_in_inverse_cc@PAGE
    add x10, x10, Lbk_in_inverse_cc@PAGEOFF
    ldr x2, [x10, x9, lsl #3]
    bl Lbk_in_lblpfx
    mov x3, x0
    ldr w4, [x21, #IRI_X]
    FMT Lbk_in_sjcmp_fmt
    b Lbk_in_next

// SREAD / INSV: the plain form (A = sref) as PRSV; the element form
// (A = IR_NONE): x0 = &Lsdesc_<X>, d0 = B; bl _bsk_sread_el /
// _bsk_input_str_el (value first, subscript checked at the store)
Lbk_in_op_sstore:
    ldr w9, [x21, #IRI_A]
    cmn w9, #1                      // IR_NONE: element form
    b.ne Lbk_in_op_sref1
    mov w0, #0
    mov x1, #IRI_X
    bl Lbk_in_sdesc_reg
    ldr w0, [x21, #IRI_B]
    mov x1, #0
    bl Lbk_in_load
    ldrh w9, [x21, #IRI_OP]
    adrp x2, Lbk_in_rt_sread_el@PAGE
    add x2, x2, Lbk_in_rt_sread_el@PAGEOFF
    adrp x10, Lbk_in_rt_input_str_el@PAGE
    add x10, x10, Lbk_in_rt_input_str_el@PAGEOFF
    cmp w9, #OP_INSV
    csel x2, x10, x2, eq
    FMT Lbk_in_bl_fmt
    b Lbk_in_next

// PRSV / SREAD / INSV (plain form): x0 = A (sref)
Lbk_in_op_sref1:
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load_x
    bl Lbk_in_ed_emit_call
    b Lbk_in_next

// PRTAB: d0 = A
Lbk_in_op_prtab:
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load
    bl Lbk_in_ed_emit_call
    b Lbk_in_next

// INBEG / INEND / RANDOMIZE: a bare call
Lbk_in_op_call0:
    bl Lbk_in_ed_emit_call
    b Lbk_in_next

// INNUM / NUM / DET: a bare call, d0 stored
Lbk_in_op_edval:
    bl Lbk_in_ed_emit_call
    b Lbk_in_store_dst

// SGN / COT: d0 = A, call, d0 stored
Lbk_in_op_sfn:
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load
    bl Lbk_in_ed_emit_call
    b Lbk_in_store_dst

// MAT INPUT: x0 = &Ldesc_<X>
Lbk_in_op_matinput:
    mov w0, #0
    mov x1, #IRI_X
    bl Lbk_in_desc_reg
    bl Lbk_in_ed_emit_call
    b Lbk_in_next

// SMATINPUT / SMATREAD: x0 = &Lsdesc_<X>
Lbk_in_op_sdesc0:
    mov w0, #0
    mov x1, #IRI_X
    bl Lbk_in_sdesc_reg
    bl Lbk_in_ed_emit_call
    b Lbk_in_next

// SMATREDIM: x0 = &Lsdesc_<X>, d0 = A
Lbk_in_op_smatredim:
    mov w0, #0
    mov x1, #IRI_X
    bl Lbk_in_sdesc_reg
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load
    bl Lbk_in_ed_emit_call
    b Lbk_in_next

// SMATPRINT: x0 = &Lsdesc_<X>, w1 = IMM (MATPR_*)
Lbk_in_op_smatprint:
    mov w0, #0
    mov x1, #IRI_X
    bl Lbk_in_sdesc_reg
    ldr x2, [x21, #IRI_IMM]
    FMT Lbk_in_mov_w1
    bl Lbk_in_ed_emit_call
    b Lbk_in_next

// CHGS2N: x0 = &Ldesc_<X>, x1 = A (sref)
Lbk_in_op_chgs2n:
    mov w0, #0
    mov x1, #IRI_X
    bl Lbk_in_desc_reg
    ldr w0, [x21, #IRI_A]
    mov x1, #1
    bl Lbk_in_load_x
    bl Lbk_in_ed_emit_call
    b Lbk_in_next

// CHGN2S: x0 = A (sref), x1 = &Ldesc_<X>; bl _bsk_change_n2s.
// Element form (A = IR_NONE): x0 = &Lsdesc_<IMM>, d0 = B,
// x1 = &Ldesc_<X>; bl _bsk_change_n2s_el.
Lbk_in_op_chgn2s:
    ldr w9, [x21, #IRI_A]
    cmn w9, #1                      // IR_NONE: element form
    b.ne 1f
    ldr x9, [x21, #IRI_IMM]
    lsr x9, x9, #32
    cbnz x9, Lbk_in_bad_imm         // the letter is the low word only
    mov w0, #0
    mov x1, #IRI_IMM
    bl Lbk_in_sdesc_reg
    ldr w0, [x21, #IRI_B]
    mov x1, #0
    bl Lbk_in_load
    mov w0, #1
    mov x1, #IRI_X
    bl Lbk_in_desc_reg
    adrp x2, Lbk_in_rt_change_n2s_el@PAGE
    add x2, x2, Lbk_in_rt_change_n2s_el@PAGEOFF
    FMT Lbk_in_bl_fmt
    b Lbk_in_next
1:
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load_x
    mov w0, #1
    mov x1, #IRI_X
    bl Lbk_in_desc_reg
    bl Lbk_in_ed_emit_call
    b Lbk_in_next

// ONSEL: d0 = A, w0 = N; d0 = _bsk_on(...); DST := d0
Lbk_in_op_onsel:
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load
    ldr x2, [x21, #IRI_IMM]
    lsr x9, x2, #32
    cbnz x9, Lbk_in_bad_imm
    mov x0, x19
    adrp x1, Lbk_in_w0@PAGE
    add x1, x1, Lbk_in_w0@PAGEOFF
    bl _bk_arm64_movimm
    bl Lbk_in_ed_emit_call
    b Lbk_in_store_dst

// RESTORE: w0 = IMM (RESTORE_*)
Lbk_in_op_restore:
    ldr x2, [x21, #IRI_IMM]
    cmp x2, #RESTORE_STR
    b.hi Lbk_in_bad_imm
    FMT Lbk_in_mov_w0
    bl Lbk_in_ed_emit_call
    b Lbk_in_next

// FNARG k: d<k> = A (k = 1..7); the callfn that follows loads d0 only
Lbk_in_op_fnarg:
    ldr x1, [x21, #IRI_IMM]
    sub x9, x1, #1
    cmp x9, #6
    b.hi Lbk_in_bad_imm
    ldr w0, [x21, #IRI_A]
    bl Lbk_in_load
    b Lbk_in_next

// STPARAM k: parameter cell k := A
Lbk_in_op_stparam:
    cbz x25, Lbk_in_bad_place
    ldr x3, [x21, #IRI_IMM]
    bl Lbk_in_check_cell
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load
    ldr x3, [x21, #IRI_IMM]
    adrp x0, Lbk_in_str@PAGE
    add x0, x0, Lbk_in_str@PAGEOFF
    adrp x1, Lbk_in_pd@PAGE
    add x1, x1, Lbk_in_pd@PAGEOFF
    mov x2, #0
    bl Lbk_in_cell
    b Lbk_in_next

// LDFV: d0 = the function value cell (cell NP); DST := d0
Lbk_in_op_ldfv:
    bl Lbk_in_fn_shape
    cbz w1, Lbk_in_bad_place
    mov x3, x0
    adrp x0, Lbk_in_ldr@PAGE
    add x0, x0, Lbk_in_ldr@PAGEOFF
    adrp x1, Lbk_in_pd@PAGE
    add x1, x1, Lbk_in_pd@PAGEOFF
    mov x2, #0
    bl Lbk_in_cell
    b Lbk_in_store_dst

// STFV: d0 = A; the function value cell (cell NP) := d0
Lbk_in_op_stfv:
    bl Lbk_in_fn_shape
    cbz w1, Lbk_in_bad_place
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load
    bl Lbk_in_fn_shape
    mov x3, x0
    adrp x0, Lbk_in_str@PAGE
    add x0, x0, Lbk_in_str@PAGEOFF
    adrp x1, Lbk_in_pd@PAGE
    add x1, x1, Lbk_in_pd@PAGEOFF
    mov x2, #0
    bl Lbk_in_cell
    b Lbk_in_next

// common tail: store d0 into the DST temp's slot
Lbk_in_store_dst:
    ldr w0, [x21, #IRI_DST]
    mov x1, #0
    bl Lbk_in_store
    b Lbk_in_next

Lbk_in_bad_letter:
    FAIL Lbk_in_err_letter
Lbk_in_bad_place:
    FAIL Lbk_in_err_place
Lbk_in_bad_rel:
    FAIL Lbk_in_err_rel
Lbk_in_bad_label:
    FAIL Lbk_in_err_label
Lbk_in_bad_string:
    FAIL Lbk_in_err_string
Lbk_in_bad_slot:
    FAIL Lbk_in_err_slot
Lbk_in_bad_imm:
    FAIL Lbk_in_err_imm

// ---- dispatch table: entry k = Lbk_in_op_<opcode k> - Lbk_in_table ------
    .p2align 2
Lbk_in_table:
    .long Lbk_in_op_nop - Lbk_in_table          // OP_NOP      0
    .long Lbk_in_op_line - Lbk_in_table         // OP_LINE     1
    .long Lbk_in_op_label - Lbk_in_table        // OP_LABEL    2
    .long Lbk_in_op_const - Lbk_in_table        // OP_CONST    3
    .long Lbk_in_op_ldv - Lbk_in_table          // OP_LDV      4
    .long Lbk_in_op_stv - Lbk_in_table          // OP_STV      5
    .long Lbk_in_op_arith - Lbk_in_table        // OP_ADD      6
    .long Lbk_in_op_arith - Lbk_in_table        // OP_SUB      7
    .long Lbk_in_op_arith - Lbk_in_table        // OP_MUL      8
    .long Lbk_in_op_div - Lbk_in_table          // OP_DIV      9
    .long Lbk_in_op_pow - Lbk_in_table          // OP_POW      10
    .long Lbk_in_op_neg - Lbk_in_table          // OP_NEG      11
    .long Lbk_in_op_builtin - Lbk_in_table      // OP_SIN      12
    .long Lbk_in_op_builtin - Lbk_in_table      // OP_COS      13
    .long Lbk_in_op_builtin - Lbk_in_table      // OP_TAN      14
    .long Lbk_in_op_builtin - Lbk_in_table      // OP_ATN      15
    .long Lbk_in_op_builtin - Lbk_in_table      // OP_EXP      16
    .long Lbk_in_op_builtin - Lbk_in_table      // OP_ABS      17
    .long Lbk_in_op_builtin - Lbk_in_table      // OP_LOG      18
    .long Lbk_in_op_builtin - Lbk_in_table      // OP_SQR      19
    .long Lbk_in_op_builtin - Lbk_in_table      // OP_INT      20
    .long Lbk_in_op_rnd - Lbk_in_table          // OP_RND      21
    .long Lbk_in_op_ald1 - Lbk_in_table         // OP_ALD1     22
    .long Lbk_in_op_ald2 - Lbk_in_table         // OP_ALD2     23
    .long Lbk_in_op_ast1 - Lbk_in_table         // OP_AST1     24
    .long Lbk_in_op_ast2 - Lbk_in_table         // OP_AST2     25
    .long Lbk_in_op_callfn - Lbk_in_table       // OP_CALLFN   26
    .long Lbk_in_op_param - Lbk_in_table        // OP_PARAM    27
    .long Lbk_in_op_ret - Lbk_in_table          // OP_RET      28
    .long Lbk_in_op_jmp - Lbk_in_table          // OP_JMP      29
    .long Lbk_in_op_jcmp - Lbk_in_table         // OP_JCMP     30
    .long Lbk_in_op_jfor - Lbk_in_table         // OP_JFOR     31
    .long Lbk_in_op_gosub - Lbk_in_table        // OP_GOSUB    32
    .long Lbk_in_op_return - Lbk_in_table       // OP_RETURN   33
    .long Lbk_in_op_read - Lbk_in_table         // OP_READ     34
    .long Lbk_in_op_prnum - Lbk_in_table        // OP_PRNUM    35
    .long Lbk_in_op_prstr - Lbk_in_table        // OP_PRSTR    36
    .long Lbk_in_op_prcomma - Lbk_in_table      // OP_PRCOMMA  37
    .long Lbk_in_op_prsemi - Lbk_in_table       // OP_PRSEMI   38
    .long Lbk_in_op_prnl - Lbk_in_table         // OP_PRNL     39
    .long Lbk_in_op_end - Lbk_in_table          // OP_END      40
    .long Lbk_in_op_end - Lbk_in_table          // OP_STOP     41
    .long Lbk_in_op_matredim - Lbk_in_table     // OP_MATREDIM 42
    .long Lbk_in_op_mat0 - Lbk_in_table         // OP_MATREAD  43
    .long Lbk_in_op_matprint - Lbk_in_table     // OP_MATPRINT 44
    .long Lbk_in_op_mat0 - Lbk_in_table         // OP_MATZER   45
    .long Lbk_in_op_mat0 - Lbk_in_table         // OP_MATCON   46
    .long Lbk_in_op_mat0 - Lbk_in_table         // OP_MATIDN   47
    .long Lbk_in_op_mat1 - Lbk_in_table         // OP_MATCOPY  48
    .long Lbk_in_op_mat2 - Lbk_in_table         // OP_MATADD   49
    .long Lbk_in_op_mat2 - Lbk_in_table         // OP_MATSUB   50
    .long Lbk_in_op_mat2 - Lbk_in_table         // OP_MATMUL   51
    .long Lbk_in_op_matscale - Lbk_in_table     // OP_MATSCALE 52
    .long Lbk_in_op_mat1 - Lbk_in_table         // OP_MATTRN   53
    .long Lbk_in_op_mat1 - Lbk_in_table         // OP_MATINV   54
    .long Lbk_in_op_slit - Lbk_in_table // OP_SLIT 55
    .long Lbk_in_op_svar - Lbk_in_table // OP_SVAR 56
    .long Lbk_in_op_sald1 - Lbk_in_table // OP_SALD1 57
    .long Lbk_in_op_sset - Lbk_in_table // OP_SSET 58
    .long Lbk_in_op_sjcmp - Lbk_in_table // OP_SJCMP 59
    .long Lbk_in_op_sref1 - Lbk_in_table // OP_PRSV 60
    .long Lbk_in_op_prtab - Lbk_in_table // OP_PRTAB 61
    .long Lbk_in_op_sstore - Lbk_in_table // OP_SREAD 62
    .long Lbk_in_op_call0 - Lbk_in_table // OP_INBEG 63
    .long Lbk_in_op_edval - Lbk_in_table // OP_INNUM 64
    .long Lbk_in_op_sstore - Lbk_in_table // OP_INSV 65
    .long Lbk_in_op_call0 - Lbk_in_table // OP_INEND 66
    .long Lbk_in_op_matinput - Lbk_in_table // OP_MATINPUT 67
    .long Lbk_in_op_sdesc0 - Lbk_in_table // OP_SMATINPUT 68
    .long Lbk_in_op_smatredim - Lbk_in_table // OP_SMATREDIM 69
    .long Lbk_in_op_sdesc0 - Lbk_in_table // OP_SMATREAD 70
    .long Lbk_in_op_smatprint - Lbk_in_table // OP_SMATPRINT 71
    .long Lbk_in_op_chgs2n - Lbk_in_table // OP_CHGS2N 72
    .long Lbk_in_op_chgn2s - Lbk_in_table // OP_CHGN2S 73
    .long Lbk_in_op_onsel - Lbk_in_table // OP_ONSEL 74
    .long Lbk_in_op_restore - Lbk_in_table // OP_RESTORE 75
    .long Lbk_in_op_call0 - Lbk_in_table // OP_RANDOMIZE 76
    .long Lbk_in_op_sfn - Lbk_in_table // OP_SGN 77
    .long Lbk_in_op_sfn - Lbk_in_table // OP_COT 78
    .long Lbk_in_op_edval - Lbk_in_table // OP_NUM 79
    .long Lbk_in_op_edval - Lbk_in_table // OP_DET 80
    .long Lbk_in_op_fnarg - Lbk_in_table // OP_FNARG 81
    .long Lbk_in_op_stparam - Lbk_in_table // OP_STPARAM 82
    .long Lbk_in_op_ldfv - Lbk_in_table // OP_LDFV 83
    .long Lbk_in_op_stfv - Lbk_in_table // OP_STFV 84
Lbk_in_table_end:
.if (Lbk_in_table_end - Lbk_in_table) != 4 * OP_COUNT
    .error "a64_insn.s dispatch table does not cover OP_COUNT opcodes"
.endif
.if (OP_MATINV != OP_MATREDIM + 12) || (OP_MATPRINT != OP_MATREDIM + 2) || (OP_MATSCALE != OP_MATREDIM + 10)
    .error "a64_insn.s MAT name table assumes opcodes 42..54 in contract order"
.endif
.if (OP_STFV != OP_SLIT + 29) || (OP_COUNT != OP_STFV + 1)
    .error "a64_insn.s Third/Fourth Edition tables assume opcodes 55..84 in contract order"
.endif
.if (OP_SUB != OP_ADD + 1) || (OP_MUL != OP_ADD + 2) || (OP_INT != OP_SIN + 8)
    .error "a64_insn.s name tables assume consecutive opcodes"
.endif
.if (REL_EQ != 1) || (REL_NE != 2) || (REL_LT != 3) || (REL_LE != 4) || (REL_GT != 5) || (REL_GE != 6)
    .error "a64_insn.s inverse condition table assumes REL_EQ..REL_GE = 1..6"
.endif

// ======================================================================
// File-local helpers. Private convention: they read the state registers
// of _bk_arm64_emit_func (x19-x28, see its header) and preserve x19-x28;
// they clobber x0-x17, d0-d7, d16-d31. On invalid IR they branch to
// Lbk_in_fail (which unwinds to _bk_arm64_emit_func's frame).
// ======================================================================

// ---------------------------------------------------------------------
// Lbk_in_use_off -- byte offset of a temp being READ.
// In:  w0 = temp
// Out: x0 = 8 * (t - base)
// Checks: t is a temp defined earlier in the current line segment.
// Leaf, no frame.
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_use_off:
    mov w0, w0                      // zero-extend the u32 temp
    cmn x24, #1
    b.eq Lbk_in_use_bad             // nothing defined in this segment
    cmp x0, x24
    b.lo Lbk_in_use_bad             // defined before the last `line`
    cmp x0, x28
    b.hs Lbk_in_use_bad             // not defined yet (or IR_NONE)
    sub x0, x0, x24
    lsl x0, x0, #3
    ret
Lbk_in_use_bad:
    FAIL Lbk_in_err_temp

// ---------------------------------------------------------------------
// Lbk_in_def_off -- byte offset of a temp being DEFINED; the first
// definition after a `line` fixes the segment base.
// In:  w0 = temp
// Out: x0 = 8 * (t - base); x24/x28 updated
// Leaf, no frame.
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_def_off:
    mov w0, w0
    cmn w0, #1
    b.eq Lbk_in_def_bad             // IR_NONE as a destination
    cmn x24, #1
    csel x24, x0, x24, eq
    cmp x0, x24
    b.lo Lbk_in_def_bad
    // slot must lie inside the temp area computed in pass 1
    sub x9, x0, x24
    cmp x9, x23
    b.hs Lbk_in_def_bad
    // top = max(top, t + 1)
    add x10, x0, #1
    cmp x10, x28
    csel x28, x10, x28, hi
    lsl x0, x9, #3
    ret
Lbk_in_def_bad:
    FAIL Lbk_in_err_temp

// ---------------------------------------------------------------------
// Lbk_in_load / Lbk_in_load_x -- emit "ldr d<n>, [sp, #slot(t)]" /
//   "ldr x<n>, [sp, #slot(t)]" (an sref temp holds a pointer).
// Lbk_in_store / Lbk_in_store_x -- emit "str d<n>" / "str x<n>" (t is
//   being defined).
// In:  w0 = temp, x1 = register number
// Frame: 32 bytes (frame record + saved register number and class)
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_load:
    adrp x2, Lbk_in_pd@PAGE
    add x2, x2, Lbk_in_pd@PAGEOFF
    b Lbk_in_load_p
    .p2align 2
Lbk_in_load_x:
    adrp x2, Lbk_in_px@PAGE
    add x2, x2, Lbk_in_px@PAGEOFF
Lbk_in_load_p:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x1, [sp, #16]
    str x2, [sp, #24]
    bl Lbk_in_use_off
    mov x4, x0
    adrp x1, Lbk_in_ldr@PAGE
    add x1, x1, Lbk_in_ldr@PAGEOFF
    b Lbk_in_ldst_emit
    .p2align 2
Lbk_in_store:
    adrp x2, Lbk_in_pd@PAGE
    add x2, x2, Lbk_in_pd@PAGEOFF
    b Lbk_in_store_p
    .p2align 2
Lbk_in_store_x:
    adrp x2, Lbk_in_px@PAGE
    add x2, x2, Lbk_in_px@PAGEOFF
Lbk_in_store_p:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x1, [sp, #16]
    str x2, [sp, #24]
    bl Lbk_in_def_off
    mov x4, x0
    adrp x1, Lbk_in_str@PAGE
    add x1, x1, Lbk_in_str@PAGEOFF
Lbk_in_ldst_emit:
    // shared tail: memop(ob, mnemonic, reg, "sp", offset, class)
    ldr x2, [sp, #16]
    ldr x5, [sp, #24]
    adrp x3, Lbk_in_sp@PAGE
    add x3, x3, Lbk_in_sp@PAGEOFF
    mov x0, x19
    bl _bk_arm64_memop
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lbk_in_load_ab -- load temp A into d0 and temp B into d1.
// In:  x21 = current record
// Frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_load_ab:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load
    ldr w0, [x21, #IRI_B]
    mov x1, #1
    bl Lbk_in_load
    ldp x29, x30, [sp], #16
    ret


// ---------------------------------------------------------------------
// Lbk_in_load_ab_x -- load sref temp A into x0 and sref temp B into x1.
// In:  x21 = current record
// Frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_load_ab_x:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load_x
    ldr w0, [x21, #IRI_B]
    mov x1, #1
    bl Lbk_in_load_x
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Lbk_in_sdesc_reg -- emit "adrp/add x<n>, Lsdesc_<L>" where L is the
// string-list letter held in the current record's field at offset x1.
// In:  w0 = register number n, x1 = field offset (IRI_X; IRI_IMM for
//      the element form of chgn2s, whose low word holds the letter),
//      x21 = current record
// Checks: the field is a letter of a string list in use (DIMS = 1).
// Frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_sdesc_reg:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    ldr w3, [x21, x1]
    cmp w3, #NUM_LETTERS
    b.hs Lbk_in_sdesc_reg_bad
    add x9, x20, #IRM_SARRAYS
    add x9, x9, x3, lsl #4
    ldr w9, [x9, #IRA_DIMS]
    cmp w9, #1
    b.ne Lbk_in_sdesc_reg_bad
    mov w2, w0
    mov x4, x2
    mov x5, x2
    mov x6, x3
    FMT Lbk_in_sdesc_reg_fmt
    ldp x29, x30, [sp], #16
    ret
Lbk_in_sdesc_reg_bad:
    FAIL Lbk_in_err_letter

// ---------------------------------------------------------------------
// Lbk_in_ed_emit_call -- emit "bl <runtime name>" for the current
// Third/Fourth Edition opcode (Lbk_in_ed_names, indexed by opcode - OP_SLIT).
// In:  x21 = current record
// Frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_ed_emit_call:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    ldrh w9, [x21, #IRI_OP]
    sub w9, w9, #OP_SLIT
    adrp x10, Lbk_in_ed_names@PAGE
    add x10, x10, Lbk_in_ed_names@PAGEOFF
    ldr x2, [x10, x9, lsl #3]
    FMT Lbk_in_bl_fmt
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Lbk_in_global_access -- emit "<mnem> d0, [x19, #8*X]" for the global
// cell named by the current record's X field.
// In:  x0 = mnemonic ("ldr"/"str"), x21 = current record
// Checks: X < NSLOTS.
// Frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_global_access:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x1, x0
    ldr w4, [x21, #IRI_X]
    ldr w9, [x20, #IRM_NSLOTS]
    cmp w4, w9
    b.hs Lbk_in_global_bad
    lsl x4, x4, #3
    mov x2, #0
    adrp x3, Lbk_in_x19@PAGE
    add x3, x3, Lbk_in_x19@PAGEOFF
    adrp x5, Lbk_in_pd@PAGE
    add x5, x5, Lbk_in_pd@PAGEOFF
    mov x0, x19
    bl _bk_arm64_memop
    ldp x29, x30, [sp], #16
    ret
Lbk_in_global_bad:
    FAIL Lbk_in_err_slot

// ---------------------------------------------------------------------
// Lbk_in_fn_shape -- the shape of the function being emitted.
// Out: w0 = NP, the number of parameters (0 for main);
//      w1 = 1 for a multi-line function (FUNC_KIND_FNML), else 0
// Leaf, no frame; clobbers x9 only.
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_fn_shape:
    ldr w0, [x27, #IRF_NPARAMS]
    ldr w9, [x27, #IRF_KIND]
    cmp w9, #FUNC_KIND_FNML
    cset w1, eq
    ret

// ---------------------------------------------------------------------
// Lbk_in_check_cell -- reject a local-cell index the function does not
// have (cells: NP parameters, or max(1, NP); a multi-line function adds
// the value and the saved line).
// In:  x3 = cell index
// Leaf, no frame (the failure path unwinds through Lbk_in_fail);
// clobbers x0, x1, x9, x11; preserves x2-x8.
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_check_cell:
    mov x11, x30                    // fn_shape is a leaf reached by bl
    bl Lbk_in_fn_shape
    mov x30, x11
    cbnz w1, 1f
    cmp w0, #1
    mov w9, #1
    csel w9, w0, w9, hi             // L = max(1, NP)
    b 2f
1:
    add w9, w0, #2                  // multi-line: NP + 2
2:
    cmp x3, x9
    b.hs Lbk_in_bad_place
    ret

// ---------------------------------------------------------------------
// Lbk_in_cell -- emit "<mnem> <class><n>, [sp, #8*(W+k)]" for local
// cell k.
// In:  x0 = mnemonic ("ldr"/"str"), x1 = register class ("d"/"x"),
//      x2 = register number, x3 = cell index k
// Frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_cell:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x5, x1
    mov x1, x0
    add x4, x23, x3
    lsl x4, x4, #3
    adrp x3, Lbk_in_sp@PAGE
    add x3, x3, Lbk_in_sp@PAGEOFF
    mov x0, x19
    bl _bk_arm64_memop
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Lbk_in_lblpfx -- the text prefix of this function's label names:
// "Lbsk_L" for main, "Lfn_<L>_L" for a multi-line function FN<L>
// (label text is prefix + decimal id, DESIGN.md 5.3).
// Out: x0 = NUL-terminated prefix
// Leaf, no frame; clobbers x9-x11, preserves x1-x8.
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_lblpfx:
    adrp x0, Lbk_in_pfx_main@PAGE
    add x0, x0, Lbk_in_pfx_main@PAGEOFF
    cbz x25, 1f
    ldr w9, [x27, #IRF_KIND]
    cmp w9, #FUNC_KIND_FNML
    b.ne 1f
    adrp x10, Lbk_in_pfx_tab@PAGE
    add x10, x10, Lbk_in_pfx_tab@PAGEOFF
    sub x11, x25, #FUNC_FN_BASE
    ldr x0, [x10, x11, lsl #3]
1:
    ret

// ---------------------------------------------------------------------
// Lbk_in_desc_addr -- emit "adrp/add x0, Ldesc_<L>" for the array named
// by the current record's X field.
// In:  x21 = current record
// Checks: X is a letter of an array in use.
// Frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_desc_addr:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    ldr w2, [x21, #IRI_X]
    cmp w2, #NUM_LETTERS
    b.hs Lbk_in_desc_bad
    add x9, x20, #IRM_ARRAYS
    add x9, x9, x2, lsl #4
    ldr w9, [x9, #IRA_DIMS]
    cbz w9, Lbk_in_desc_bad
    mov x3, x2
    FMT Lbk_in_desc_fmt
    ldp x29, x30, [sp], #16
    ret
Lbk_in_desc_bad:
    FAIL Lbk_in_err_letter

// ---------------------------------------------------------------------
// Lbk_in_desc_reg -- emit "adrp/add x<n>, Ldesc_<L>" where L is the
// array letter held in the current record's field at offset x1.
// In:  w0 = register number n, x1 = field offset (IRI_X/IRI_A/IRI_B),
//      x21 = current record
// Checks: the field is a letter of an array in use.
// Frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_desc_reg:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    ldr w3, [x21, x1]
    cmp w3, #NUM_LETTERS
    b.hs Lbk_in_desc_reg_bad
    add x9, x20, #IRM_ARRAYS
    add x9, x9, x3, lsl #4
    ldr w9, [x9, #IRA_DIMS]
    cbz w9, Lbk_in_desc_reg_bad
    mov w2, w0
    mov x4, x2
    mov x5, x2
    mov x6, x3
    FMT Lbk_in_desc_reg_fmt
    ldp x29, x30, [sp], #16
    ret
Lbk_in_desc_reg_bad:
    FAIL Lbk_in_err_letter

// ======================================================================
// Text templates
// ======================================================================
    .section __TEXT,__cstring,cstring_literals
Lbk_in_main_label:
    .asciz "_bsk_program:\n"
Lbk_in_fn_label:
    .asciz "Lfn_%L:\n"
Lbk_in_prologue:
    .ascii "    stp x29, x30, [sp, #-32]!\n"
    .ascii "    mov x29, sp\n"
    .asciz "    stp x19, x20, [sp, #16]\n"
Lbk_in_sub_imm:
    .asciz "    sub sp, sp, #%u\n"
Lbk_in_sub_x16:
    .asciz "    sub sp, sp, x16\n"
Lbk_in_globals:
    .ascii "    adrp x19, _bsk_vars@PAGE\n"
    .asciz "    add x19, x19, _bsk_vars@PAGEOFF\n"
Lbk_in_epilogue:
    .ascii "    mov sp, x29\n"
    .ascii "    ldp x19, x20, [sp, #16]\n"
    .ascii "    ldp x29, x30, [sp], #32\n"
    .asciz "    ret\n"
Lbk_in_label_def:
    .asciz "%s%u:\n"
Lbk_in_line_adrp:
    .asciz "    adrp x16, _bsk_curline@PAGE\n"
Lbk_in_line_str:
    .asciz "    str w17, [x16, _bsk_curline@PAGEOFF]\n"
Lbk_in_fmov_d0:
    .asciz "    fmov d0, x16\n"
Lbk_in_arith_fmt:
    .asciz "    %s d0, d0, d1\n"
Lbk_in_ovf_check:
    .ascii "    fabs d16, d0\n"
    .ascii "    movz x16, #0x7FF0, lsl #48\n"
    .ascii "    fmov d17, x16\n"
    .ascii "    fcmp d16, d17\n"
    .ascii "    b.lo 1f\n"
    .ascii "    mov w0, #%u\n"
    .ascii "    bl _bsk_err\n"
    .asciz "1:\n"
Lbk_in_fneg:
    .asciz "    fneg d0, d0\n"
Lbk_in_bl_fmt:
    .asciz "    bl %s\n"
Lbk_in_bl_fn:
    .asciz "    bl Lfn_%L\n"
Lbk_in_desc_fmt:
    .ascii "    adrp x0, Ldesc_%L@PAGE\n"
    .asciz "    add x0, x0, Ldesc_%L@PAGEOFF\n"
Lbk_in_desc_reg_fmt:
    .ascii "    adrp x%u, Ldesc_%L@PAGE\n"
    .asciz "    add x%u, x%u, Ldesc_%L@PAGEOFF\n"
Lbk_in_mov_w1:
    .asciz "    mov w1, #%u\n"
Lbk_in_ml_zero:
    .asciz "    mov x17, xzr\n"
Lbk_in_ml_saveline:
    .ascii "    adrp x16, _bsk_curline@PAGE\n"
    .asciz "    ldr w17, [x16, _bsk_curline@PAGEOFF]\n"
Lbk_in_mov_w0:
    .asciz "    mov w0, #%u\n"
Lbk_in_slit_fmt:
    .ascii "    adrp x0, Lsd_%u@PAGE\n"
    .asciz "    add x0, x0, Lsd_%u@PAGEOFF\n"
Lbk_in_svar_base:
    .ascii "    adrp x0, _bsk_svars@PAGE\n"
    .asciz "    add x0, x0, _bsk_svars@PAGEOFF\n"
Lbk_in_svar_add:
    .asciz "    add x0, x0, #%u\n"
Lbk_in_svar_addx16:
    .asciz "    add x0, x0, x16\n"
Lbk_in_sjcmp_fmt:
    .ascii "    cmp w0, #0\n"
    .ascii "    b.%s 1f\n"
    .ascii "    b %s%u\n"
    .asciz "1:\n"
Lbk_in_sdesc_reg_fmt:
    .ascii "    adrp x%u, Lsdesc_%L@PAGE\n"
    .asciz "    add x%u, x%u, Lsdesc_%L@PAGEOFF\n"
Lbk_in_ldr_elem:
    .asciz "    ldr d0, [x0]\n"
Lbk_in_str_elem:
    .asciz "    str d0, [x0]\n"
Lbk_in_b_label:
    .asciz "    b %s%u\n"
Lbk_in_jcmp_fmt:
    .ascii "    fcmp d0, d1\n"
    .ascii "    b.%s 1f\n"
    .ascii "    b %s%u\n"
    .asciz "1:\n"
Lbk_in_jfor_fmt:
    .ascii "    fcmp d2, #0.0\n"
    .ascii "    b.lt 2f\n"
    .ascii "    fcmp d0, d1\n"
    .ascii "    b.le 3f\n"
    .ascii "    b %s%u\n"
    .ascii "2:\n"
    .ascii "    fcmp d0, d1\n"
    .ascii "    b.ge 3f\n"
    .ascii "    b %s%u\n"
    .asciz "3:\n"
Lbk_in_gosub_fmt:
    .ascii "    adrp x0, %s%u@PAGE\n"
    .ascii "    add x0, x0, %s%u@PAGEOFF\n"
    .ascii "    bl _bsk_gosub_push\n"
    .asciz "    b %s%u\n"
Lbk_in_return_fmt:
    .ascii "    bl _bsk_gosub_pop\n"
    .asciz "    br x0\n"
Lbk_in_prstr_addr:
    .ascii "    adrp x0, Lstr_%u@PAGE\n"
    .asciz "    add x0, x0, Lstr_%u@PAGEOFF\n"

// register names and mnemonics passed to the a64_text.s helpers
Lbk_in_ldr:     .asciz "ldr"
Lbk_in_str:     .asciz "str"
Lbk_in_sp:      .asciz "sp"
Lbk_in_x19:     .asciz "x19"
Lbk_in_x16:     .asciz "x16"
Lbk_in_w17:     .asciz "w17"
Lbk_in_w0:      .asciz "w0"
Lbk_in_pd:      .asciz "d"
Lbk_in_px:      .asciz "x"
Lbk_in_pfx_main: .asciz "Lbsk_L"
Lbk_in_pfx_A: .asciz "Lfn_A_L"
Lbk_in_pfx_B: .asciz "Lfn_B_L"
Lbk_in_pfx_C: .asciz "Lfn_C_L"
Lbk_in_pfx_D: .asciz "Lfn_D_L"
Lbk_in_pfx_E: .asciz "Lfn_E_L"
Lbk_in_pfx_F: .asciz "Lfn_F_L"
Lbk_in_pfx_G: .asciz "Lfn_G_L"
Lbk_in_pfx_H: .asciz "Lfn_H_L"
Lbk_in_pfx_I: .asciz "Lfn_I_L"
Lbk_in_pfx_J: .asciz "Lfn_J_L"
Lbk_in_pfx_K: .asciz "Lfn_K_L"
Lbk_in_pfx_L: .asciz "Lfn_L_L"
Lbk_in_pfx_M: .asciz "Lfn_M_L"
Lbk_in_pfx_N: .asciz "Lfn_N_L"
Lbk_in_pfx_O: .asciz "Lfn_O_L"
Lbk_in_pfx_P: .asciz "Lfn_P_L"
Lbk_in_pfx_Q: .asciz "Lfn_Q_L"
Lbk_in_pfx_R: .asciz "Lfn_R_L"
Lbk_in_pfx_S: .asciz "Lfn_S_L"
Lbk_in_pfx_T: .asciz "Lfn_T_L"
Lbk_in_pfx_U: .asciz "Lfn_U_L"
Lbk_in_pfx_V: .asciz "Lfn_V_L"
Lbk_in_pfx_W: .asciz "Lfn_W_L"
Lbk_in_pfx_X: .asciz "Lfn_X_L"
Lbk_in_pfx_Y: .asciz "Lfn_Y_L"
Lbk_in_pfx_Z: .asciz "Lfn_Z_L"
Lbk_in_x1:      .asciz "x1"

// runtime entry points (runtime.inc)
Lbk_in_rt_div:      .asciz "_bsk_div"
Lbk_in_rt_pow:      .asciz "_bsk_pow"
Lbk_in_rt_rnd:      .asciz "_bsk_rnd"
Lbk_in_rt_aref1:    .asciz "_bsk_aref1"
Lbk_in_rt_aref2:    .asciz "_bsk_aref2"
Lbk_in_rt_read:     .asciz "_bsk_read"
Lbk_in_rt_prnum:    .asciz "_bsk_print_num"
Lbk_in_rt_prstr:    .asciz "_bsk_print_str"
Lbk_in_rt_prcomma:  .asciz "_bsk_print_comma"
Lbk_in_rt_prsemi:   .asciz "_bsk_print_semi"
Lbk_in_rt_prnl:     .asciz "_bsk_print_nl"
Lbk_in_rt_end:      .asciz "_bsk_end"
Lbk_in_rt_sin:      .asciz "_bsk_sin"
Lbk_in_rt_cos:      .asciz "_bsk_cos"
Lbk_in_rt_tan:      .asciz "_bsk_tan"
Lbk_in_rt_atn:      .asciz "_bsk_atn"
Lbk_in_rt_exp:      .asciz "_bsk_exp"
Lbk_in_rt_abs:      .asciz "_bsk_abs"
Lbk_in_rt_log:      .asciz "_bsk_log"
Lbk_in_rt_sqr:      .asciz "_bsk_sqr"
Lbk_in_rt_int:      .asciz "_bsk_int"
Lbk_in_rt_mat_redim1: .asciz "_bsk_mat_redim1"
Lbk_in_rt_mat_redim2: .asciz "_bsk_mat_redim2"
Lbk_in_rt_mat_read:   .asciz "_bsk_mat_read"
Lbk_in_rt_mat_print:  .asciz "_bsk_mat_print"
Lbk_in_rt_mat_zer:    .asciz "_bsk_mat_zer"
Lbk_in_rt_mat_con:    .asciz "_bsk_mat_con"
Lbk_in_rt_mat_idn:    .asciz "_bsk_mat_idn"
Lbk_in_rt_mat_copy:   .asciz "_bsk_mat_copy"
Lbk_in_rt_mat_add:    .asciz "_bsk_mat_add"
Lbk_in_rt_mat_sub:    .asciz "_bsk_mat_sub"
Lbk_in_rt_mat_mul:    .asciz "_bsk_mat_mul"
Lbk_in_rt_mat_scale:  .asciz "_bsk_mat_scale"
Lbk_in_rt_mat_trn:    .asciz "_bsk_mat_trn"
Lbk_in_rt_mat_inv:    .asciz "_bsk_mat_inv"
Lbk_in_rt_saref1: .asciz "_bsk_saref1"
Lbk_in_rt_str_set: .asciz "_bsk_str_set"
Lbk_in_rt_str_cmp: .asciz "_bsk_str_cmp"
Lbk_in_rt_print_sv: .asciz "_bsk_print_sv"
Lbk_in_rt_print_tab: .asciz "_bsk_print_tab"
Lbk_in_rt_sread: .asciz "_bsk_sread"
Lbk_in_rt_sread_el: .asciz "_bsk_sread_el"
Lbk_in_rt_input_begin: .asciz "_bsk_input_begin"
Lbk_in_rt_input_num: .asciz "_bsk_input_num"
Lbk_in_rt_input_str: .asciz "_bsk_input_str"
Lbk_in_rt_input_str_el: .asciz "_bsk_input_str_el"
Lbk_in_rt_input_end: .asciz "_bsk_input_end"
Lbk_in_rt_mat_input: .asciz "_bsk_mat_input"
Lbk_in_rt_smat_input: .asciz "_bsk_smat_input"
Lbk_in_rt_smat_read: .asciz "_bsk_smat_read"
Lbk_in_rt_smat_print: .asciz "_bsk_smat_print"
Lbk_in_rt_change_s2n: .asciz "_bsk_change_s2n"
Lbk_in_rt_change_n2s: .asciz "_bsk_change_n2s"
Lbk_in_rt_change_n2s_el: .asciz "_bsk_change_n2s_el"
Lbk_in_rt_on: .asciz "_bsk_on"
Lbk_in_rt_restore: .asciz "_bsk_restore"
Lbk_in_rt_randomize: .asciz "_bsk_randomize"
Lbk_in_rt_sgn: .asciz "_bsk_sgn"
Lbk_in_rt_cot: .asciz "_bsk_cot"
Lbk_in_rt_num: .asciz "_bsk_num"
Lbk_in_rt_det: .asciz "_bsk_det"
Lbk_in_fadd:        .asciz "fadd"
Lbk_in_fsub:        .asciz "fsub"
Lbk_in_fmul:        .asciz "fmul"
Lbk_in_cc_eq:       .asciz "eq"
Lbk_in_cc_ne:       .asciz "ne"
Lbk_in_cc_lt:       .asciz "lt"
Lbk_in_cc_le:       .asciz "le"
Lbk_in_cc_gt:       .asciz "gt"
Lbk_in_cc_ge:       .asciz "ge"

// internal-error reasons
Lbk_in_err_order:   .asciz "arm64-macos backend: temps not defined in increasing order"
Lbk_in_err_op:      .asciz "arm64-macos backend: unknown IR opcode"
Lbk_in_err_temp:    .asciz "arm64-macos backend: temp used outside its line segment"
Lbk_in_err_line:    .asciz "arm64-macos backend: line number out of range"
Lbk_in_err_letter:  .asciz "arm64-macos backend: bad array or function letter"
Lbk_in_err_place:   .asciz "arm64-macos backend: param/ret outside an FN function"
Lbk_in_err_rel:     .asciz "arm64-macos backend: bad relation code"
Lbk_in_err_label:   .asciz "arm64-macos backend: bad label id"
Lbk_in_err_string:  .asciz "arm64-macos backend: bad string id"
Lbk_in_err_slot:    .asciz "arm64-macos backend: bad variable slot"
Lbk_in_err_imm:     .asciz "arm64-macos backend: bad immediate operand"

// ---- name tables (pointers) ---------------------------------------------
    .section __DATA,__const
    .p2align 3
// indexed by opcode - OP_ADD
Lbk_in_arith_names:
    .quad Lbk_in_fadd, Lbk_in_fsub, Lbk_in_fmul
// indexed by opcode - OP_SIN
Lbk_in_builtin_names:
    .quad Lbk_in_rt_sin, Lbk_in_rt_cos, Lbk_in_rt_tan, Lbk_in_rt_atn
    .quad Lbk_in_rt_exp, Lbk_in_rt_abs, Lbk_in_rt_log, Lbk_in_rt_sqr
    .quad Lbk_in_rt_int
// indexed by opcode - OP_MATREDIM (the redim slot is never read: the
// handler picks redim1/redim2 itself)
Lbk_in_mat_names:
    .quad Lbk_in_rt_mat_redim1, Lbk_in_rt_mat_read, Lbk_in_rt_mat_print
    .quad Lbk_in_rt_mat_zer, Lbk_in_rt_mat_con, Lbk_in_rt_mat_idn
    .quad Lbk_in_rt_mat_copy, Lbk_in_rt_mat_add, Lbk_in_rt_mat_sub
    .quad Lbk_in_rt_mat_mul, Lbk_in_rt_mat_scale, Lbk_in_rt_mat_trn
    .quad Lbk_in_rt_mat_inv
// indexed by opcode - OP_SLIT: runtime entry of each Third/Fourth Edition
// opcode that is one plain call (0 for slit, svar, fnarg, stparam, ldfv, stfv)
Lbk_in_ed_names:
    .quad 0
    .quad 0
    .quad Lbk_in_rt_saref1
    .quad Lbk_in_rt_str_set
    .quad Lbk_in_rt_str_cmp
    .quad Lbk_in_rt_print_sv
    .quad Lbk_in_rt_print_tab
    .quad Lbk_in_rt_sread
    .quad Lbk_in_rt_input_begin
    .quad Lbk_in_rt_input_num
    .quad Lbk_in_rt_input_str
    .quad Lbk_in_rt_input_end
    .quad Lbk_in_rt_mat_input
    .quad Lbk_in_rt_smat_input
    .quad Lbk_in_rt_mat_redim1
    .quad Lbk_in_rt_smat_read
    .quad Lbk_in_rt_smat_print
    .quad Lbk_in_rt_change_s2n
    .quad Lbk_in_rt_change_n2s
    .quad Lbk_in_rt_on
    .quad Lbk_in_rt_restore
    .quad Lbk_in_rt_randomize
    .quad Lbk_in_rt_sgn
    .quad Lbk_in_rt_cot
    .quad Lbk_in_rt_num
    .quad Lbk_in_rt_det
    .quad 0
    .quad 0
    .quad 0
    .quad 0
Lbk_in_pfx_tab:
    .quad Lbk_in_pfx_A, Lbk_in_pfx_B, Lbk_in_pfx_C, Lbk_in_pfx_D, Lbk_in_pfx_E, Lbk_in_pfx_F
    .quad Lbk_in_pfx_G, Lbk_in_pfx_H, Lbk_in_pfx_I, Lbk_in_pfx_J, Lbk_in_pfx_K, Lbk_in_pfx_L
    .quad Lbk_in_pfx_M, Lbk_in_pfx_N, Lbk_in_pfx_O, Lbk_in_pfx_P, Lbk_in_pfx_Q, Lbk_in_pfx_R
    .quad Lbk_in_pfx_S, Lbk_in_pfx_T, Lbk_in_pfx_U, Lbk_in_pfx_V, Lbk_in_pfx_W, Lbk_in_pfx_X
    .quad Lbk_in_pfx_Y, Lbk_in_pfx_Z
// indexed by relation - REL_EQ: condition that SKIPS the jump
Lbk_in_inverse_cc:
    .quad Lbk_in_cc_ne              // eq -> ne
    .quad Lbk_in_cc_eq              // ne -> eq
    .quad Lbk_in_cc_ge              // lt -> ge
    .quad Lbk_in_cc_gt              // le -> gt
    .quad Lbk_in_cc_le              // gt -> le
    .quad Lbk_in_cc_lt              // ge -> lt
