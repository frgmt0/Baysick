// =====================================================================
// src/backend/arm64_macos/a64_insn.s -- per-function and per-opcode code
// generation for the arm64-macos backend (docs/DESIGN.md section 5.3
// "Frames and temps" and "Per-opcode translation"; 5.3.1 SUB units).
//
// Exports: _bk_arm64_emit_func, _bk_arm64_func_frame; Sixth Edition:
//          _bk_arm64_unit_layout, _bk_arm64_emit_subl
// Uses:    _bk_arm64_fmt, _bk_arm64_movimm, _bk_arm64_memop (a64_text.s)
//
// Temp slots: a temp is never read after the next `line` (IR.md 1), so
// slots are reused per line: slot(t) = t - base, base = the first temp
// defined after the most recent `line` (start of function counts as a
// `line`). W = the largest number of temps one such segment needs.
// After the W temp slots come the local cells (parameters; for a
// multi-line function also the function value and the saved run-time
// line), cell k at [sp, #8*(W+k)], then the V argument-vector slots of
// the function's `callsub` instructions, slot k at [sp, #8*(W+L+k)].
// An sref (and an nref, aref or saref) temp holds a pointer and is moved
// with x registers; every other temp is a double in a d register.
// Labels of main are Lbsk_L<id>, those of a multi-line function FN<L>
// are Lfn_<L>_L<id>; in SUB unit u, Lsub_<u>_L<id> in its body and
// Lsub_<u>_fn_<L>_L<id> in its functions (Lbk_in_lblpfx, Lbk_in_setup).
// In a SUB unit x19 holds the activation block instead of &_bsk_vars;
// its parameters, string records and descriptors are addressed through
// it (Lbk_in_find_param, Lbk_in_ldparam, Lbk_in_sd_addr, Lbk_in_desc_reg).
// =====================================================================
.include "baysick.inc"

.equ BK_IMM12_MAX,  4095            // largest plain "sub sp, sp, #imm"

// SUB unit block layout words (_bk_arm64_unit_layout, DESIGN.md 5.3.1):
// u32 indices into the result array; the per-letter tables have 26 words.
.equ LAY_PARAMOFF,  0               // 8 * NSLOTS
.equ LAY_SDOFF,     1               // first SD record
.equ LAY_NSD,       2               // number of SD records
.equ LAY_DESCOFF,   3               // first RTA descriptor
.equ LAY_NDESC,     4               // number of descriptors
.equ LAY_SIZE,      5               // block size, a multiple of 16
.equ LAY_NDESC_L,   6               // [26] numeric descriptor offset, or IR_NONE
.equ LAY_SDESC_L,   LAY_NDESC_L + NUM_LETTERS   // [26] string descriptor offset
.equ LAY_NDATA_L,   LAY_SDESC_L + NUM_LETTERS   // [26] numeric element offset
.equ LAY_SDATA_L,   LAY_NDATA_L + NUM_LETTERS   // [26] first SD record of a string array
.equ LAY_WORDS,     LAY_SDATA_L + NUM_LETTERS

// Per-function emission state (Lbk_st, file-local, filled by
// Lbk_in_setup; the backend emits one function at a time):
.equ ST_POOL,       0               // Module* holding strings and SUB units (main)
.equ ST_UNIT,       8               // u32 1 while a SUB unit's function is emitted
.equ ST_V,          12              // u32 V, the argument-vector words of the frame
.equ ST_NAME,       16              // char[48] the function's label name
.equ ST_FNPFX,      64              // char[48] FN call prefix "Lfn_" / "Lsub_<u>_fn_"
.equ ST_LBLPFX,     112             // char[48] label prefix ("Lbsk_L", "<name>_L")
.equ ST_LAYOUT,     160             // u32[LAY_WORDS] the unit's block layout
.equ ST_SIZE,       ST_LAYOUT + 4 * LAY_WORDS

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
// FN letter L as Lfn_<L>; of SUB unit u its body as Lsub_<u>, its FN L
// as Lsub_<u>_fn_<L>) with prologue, body and epilogues.
// In:  x0 = OutBuf*, x1 = const Module* (main, or a SUB unit), x2 = index
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
// Frame: 96 bytes (frame record + x19-x28). The rest of the per-function
// state (pool module, unit flag, V, names, unit layout) is in Lbk_st.
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

    // ---- per-function state: pool module, unit flag, label names ------
    bl Lbk_in_setup
    cbnz x0, Lbk_in_fail

    // ---- pass 1: W (temp slots), L (local cells), V (argument vector) ----
    mov x0, x20
    mov x1, x25
    bl _bk_arm64_func_frame
    cbnz x0, Lbk_in_fail
    mov x23, x1                     // W
    adrp x9, Lbk_st@PAGE
    add x9, x9, Lbk_st@PAGEOFF
    str w3, [x9, #ST_V]             // V

    // ---- function label: _bsk_program / Lfn_<L> / Lsub_<u> / Lsub_<u>_fn_<L>
    adrp x2, Lbk_st@PAGE
    add x2, x2, Lbk_st@PAGEOFF
    add x2, x2, #ST_NAME
    FMT Lbk_in_name_label
    // ---- prologue: frame record, x19/x20, temps + cells + argument vector
    FMT Lbk_in_prologue
    // frame = align16(8*(W+L+V) + 8)
    bl Lbk_in_fn_cells              // w0 = L, the number of local cells
    adrp x9, Lbk_st@PAGE
    add x9, x9, Lbk_st@PAGEOFF
    ldr w10, [x9, #ST_V]
    add x9, x23, x0
    add x9, x9, x10
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
    // x19 in the generated code: &_bsk_vars in main and its FN functions;
    // the activation block in a SUB unit (the body gets it from
    // _bsk_sub_enter, the unit's FN functions keep their caller's x19)
    adrp x9, Lbk_st@PAGE
    add x9, x9, Lbk_st@PAGEOFF
    ldr w10, [x9, #ST_UNIT]
    cbz w10, 3f
    cbnz x25, 4f
    ldr w2, [x20, #IRM_UNITIDX]
    mov x3, x2
    FMT Lbk_in_sub_enter_fmt
    b 4f
3:
    FMT Lbk_in_globals
4:
    // FN functions spill their arguments d0..d<NP-1> to cells 0..NP-1
    // (x28 = NP and x24 = k are free until pass 2 starts)
    bl Lbk_in_fn_shape
    mov x28, x0
    mov x24, #0
Lbk_in_pro_loop:
    cmp x24, x28
    b.hs Lbk_in_pro_done
    // parameter k arrives in d<k>, or in x<k> when its string-parameter
    // bit in IRM_FNKINDS is set (Fifth Edition)
    bl Lbk_in_fn_kinds
    lsr w9, w0, w24
    adrp x1, Lbk_in_pd@PAGE
    add x1, x1, Lbk_in_pd@PAGEOFF
    adrp x10, Lbk_in_px@PAGE
    add x10, x10, Lbk_in_px@PAGEOFF
    tst w9, #1
    csel x1, x10, x1, ne
    adrp x0, Lbk_in_str@PAGE
    add x0, x0, Lbk_in_str@PAGEOFF
    mov x2, x24
    mov x3, x24
    bl Lbk_in_cell
    add x24, x24, #1
    b Lbk_in_pro_loop
Lbk_in_pro_done:
    bl Lbk_in_fn_shape
    mov x28, x0                     // NP
    mov x24, x1                     // multi-line flag (the loop counter is dead)
    // string function: the hidden result address arrives in x8 and lives
    // in cell NP; a multi-line one also saves the caller's line and
    // clears its value variable
    bl Lbk_in_fn_kinds
    tst w0, #FNK_STRING
    b.eq Lbk_in_pro_numfn
    adrp x0, Lbk_in_str@PAGE
    add x0, x0, Lbk_in_str@PAGEOFF
    adrp x1, Lbk_in_px@PAGE
    add x1, x1, Lbk_in_px@PAGEOFF
    mov x2, #8
    mov x3, x28
    bl Lbk_in_cell
    cbz x24, Lbk_in_pro_end
    FMT Lbk_in_ml_saveline
    adrp x0, Lbk_in_str@PAGE
    add x0, x0, Lbk_in_str@PAGEOFF
    adrp x1, Lbk_in_px@PAGE
    add x1, x1, Lbk_in_px@PAGEOFF
    mov x2, #17
    add x3, x28, #1
    bl Lbk_in_cell
    adrp x0, Lbk_in_ldr@PAGE
    add x0, x0, Lbk_in_ldr@PAGEOFF
    adrp x1, Lbk_in_px@PAGE
    add x1, x1, Lbk_in_px@PAGEOFF
    mov x2, #0
    mov x3, x28
    bl Lbk_in_cell
    adrp x2, Lbk_in_rt_str_clear@PAGE
    add x2, x2, Lbk_in_rt_str_clear@PAGEOFF
    FMT Lbk_in_bl_fmt
    b Lbk_in_pro_end
Lbk_in_pro_numfn:
    // multi-line function: value := 0, save the caller's run-time line
    cbz x24, Lbk_in_pro_end
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
    // d0 = global cell X; in a SUB unit, a numeric parameter's slot reads
    // the caller's double through the parameter pointer
    mov w0, #SUBP_NUM
    ldr w1, [x21, #IRI_X]
    bl Lbk_in_find_param
    tbz x0, #63, 1f
    adrp x0, Lbk_in_ldr@PAGE
    add x0, x0, Lbk_in_ldr@PAGEOFF
    bl Lbk_in_global_access
    b Lbk_in_store_dst
1:
    mov x1, x0                      // parameter k
    mov w0, #16
    bl Lbk_in_ldparam               // x16 = parameter pointer k
    FMT Lbk_in_ldr_d0_x16
    b Lbk_in_store_dst

Lbk_in_op_stv:
    // global cell X = A; a numeric parameter stores into the caller's double
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load
    mov w0, #SUBP_NUM
    ldr w1, [x21, #IRI_X]
    bl Lbk_in_find_param
    tbz x0, #63, 1f
    adrp x0, Lbk_in_str@PAGE
    add x0, x0, Lbk_in_str@PAGEOFF
    bl Lbk_in_global_access
    b Lbk_in_next
1:
    mov x1, x0
    mov w0, #16
    bl Lbk_in_ldparam
    FMT Lbk_in_str_d0_x16
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
    // (argument 0 is an sref in x0 when the callee's parameter 0 is a string)
    ldr w2, [x21, #IRI_X]
    cmp w2, #NUM_LETTERS
    b.hs Lbk_in_bad_letter
    ldr w0, [x21, #IRI_A]
    cmn w0, #1                      // IR_NONE: no argument
    b.eq 1f
    bl Lbk_in_arg0
1:
    ldr w3, [x21, #IRI_X]
    adrp x2, Lbk_st@PAGE
    add x2, x2, Lbk_st@PAGEOFF
    add x2, x2, #ST_FNPFX           // "Lfn_" or "Lsub_<u>_fn_"
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
Lbk_in_ret_tail:
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
    bl Lbk_in_pool                  // strings live in the main module
    ldr w9, [x0, #IRM_NSTRINGS]
    cmp w2, w9
    b.hs Lbk_in_bad_string
    mov x3, x2
    FMT Lbk_in_prstr_addr
    bl Lbk_in_pool
    ldr w9, [x21, #IRI_X]
    ldr x10, [x0, #IRM_STRINGS]
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
    // string constants live in the main module (the pool) also in a unit
    ldr w2, [x21, #IRI_X]
    bl Lbk_in_pool
    ldr w9, [x0, #IRM_NSTRINGS]
    cmp w2, w9
    b.hs Lbk_in_bad_string
    mov x3, x2
    FMT Lbk_in_slit_fmt
    b Lbk_in_store_sref

// SVAR: x0 = &_bsk_svars + 16*slot (offsets above 4095 go through x16);
// in a SUB unit the block's SD record, or a string parameter's pointer
Lbk_in_op_svar:
    ldr w9, [x21, #IRI_X]
    cmp w9, #NUM_STRING_SLOTS
    b.hs Lbk_in_bad_slot
    mov w0, #SUBP_STR
    ldr w1, [x21, #IRI_X]
    bl Lbk_in_find_param
    tbz x0, #63, 1f
    mov w0, #0                      // a string variable
    ldr w1, [x21, #IRI_X]
    bl Lbk_in_sd_addr
    b Lbk_in_store_sref
1:
    mov x1, x0
    mov w0, #0
    bl Lbk_in_ldparam               // x0 = the caller's SD record
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

// LINPUT (Baysick extension): the plain form (A = sref): x0 = A, bl _bsk_linput;
// the element form (A = IR_NONE): x0 = &Lsdesc_<X>, d0 = B, bl _bsk_linput_el
// (the line is read first, the subscript checked at the store).
Lbk_in_op_linput:
    ldr w9, [x21, #IRI_A]
    cmn w9, #1                      // IR_NONE: element form
    b.ne 1f
    mov w0, #0
    mov x1, #IRI_X
    bl Lbk_in_sdesc_reg
    ldr w0, [x21, #IRI_B]
    mov x1, #0
    bl Lbk_in_load
    adrp x2, Lbk_in_rt_linput_el@PAGE
    add x2, x2, Lbk_in_rt_linput_el@PAGEOFF
    b 2f
1:
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load_x
    adrp x2, Lbk_in_rt_linput@PAGE
    add x2, x2, Lbk_in_rt_linput@PAGEOFF
2:
    FMT Lbk_in_bl_fmt
    b Lbk_in_next

// EXIT (Baysick extension): d0 = A, bl _bsk_exit (never returns)
Lbk_in_op_exit:
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load
    adrp x2, Lbk_in_rt_exit@PAGE
    add x2, x2, Lbk_in_rt_exit@PAGEOFF
    FMT Lbk_in_bl_fmt
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
    ldr w9, [x21, #IRI_B]
    cmn w9, #1                      // IR_NONE: list form
    b.eq 1f
    mov w0, w9                      // string table: d1 = columns, redim2
    mov x1, #1
    bl Lbk_in_load
    adrp x2, Lbk_in_rt_mat_redim2@PAGE
    add x2, x2, Lbk_in_rt_mat_redim2@PAGEOFF
    FMT Lbk_in_bl_fmt
    b Lbk_in_next
1:
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
    bl Lbk_in_call_kinds            // the callee's string-parameter bits
    lsr w9, w0, w1
    ldr w0, [x21, #IRI_A]
    tbnz w9, #0, 1f
    bl Lbk_in_load
    b Lbk_in_next
1:
    bl Lbk_in_load_x                // string parameter: an sref in x<k>
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

// ---- Fifth Edition opcodes (docs/DESIGN.md 5.3) --------------------------

// SCELL: x0 = &_bsk_scells + 16*X; DST := x0
Lbk_in_op_scell:
    ldr w9, [x21, #IRI_X]
    ldr w10, [x20, #IRM_NSTEMPS]
    cmp w9, w10
    b.hs Lbk_in_bad_slot
    mov w0, #1                      // a string temp cell
    ldr w1, [x21, #IRI_X]
    bl Lbk_in_sd_addr
    b Lbk_in_store_sref

// SSTR: x0 = A (sref), d0 = B; bl _bsk_str
Lbk_in_op_sstr:
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load_x
    ldr w0, [x21, #IRI_B]
    mov x1, #0
    bl Lbk_in_load
    bl Lbk_in_ed_emit_call
    b Lbk_in_next

// LEN / ASC / VAL: x0 = A (sref); d0 stored
Lbk_in_op_sref_d:
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load_x
    bl Lbk_in_ed_emit_call
    b Lbk_in_store_dst

// SALD2: x0 = &Lsdesc_<X>, d0 = A, d1 = B; x0 = _bsk_saref2(...); DST := x0
Lbk_in_op_sald2:
    mov w0, #0
    mov x1, #IRI_X
    bl Lbk_in_sdesc_reg
    bl Lbk_in_load_ab
    bl Lbk_in_ed_emit_call
    b Lbk_in_store_sref

// SPARAM k: x0 = local cell k (the string parameter's sref); DST := x0
Lbk_in_op_sparam:
    cbz x25, Lbk_in_bad_place
    ldr x3, [x21, #IRI_IMM]
    bl Lbk_in_check_cell
    adrp x0, Lbk_in_ldr@PAGE
    add x0, x0, Lbk_in_ldr@PAGEOFF
    adrp x1, Lbk_in_px@PAGE
    add x1, x1, Lbk_in_px@PAGEOFF
    mov x2, #0
    bl Lbk_in_cell
    b Lbk_in_store_sref

// SFV: x0 = cell NP (the multi-line string function's value); DST := x0
Lbk_in_op_sfv:
    bl Lbk_in_fn_shape
    cbz w1, Lbk_in_bad_place
    mov x3, x0
    adrp x0, Lbk_in_ldr@PAGE
    add x0, x0, Lbk_in_ldr@PAGEOFF
    adrp x1, Lbk_in_px@PAGE
    add x1, x1, Lbk_in_px@PAGEOFF
    mov x2, #0
    bl Lbk_in_cell
    b Lbk_in_store_sref

// SCALLFN: argument 0 (d0 or x0) = A unless none; x8 = B (the result
// descriptor); bl Lfn_<X>; nothing is stored
Lbk_in_op_scallfn:
    ldr w2, [x21, #IRI_X]
    cmp w2, #NUM_LETTERS
    b.hs Lbk_in_bad_letter
    ldr w0, [x21, #IRI_A]
    cmn w0, #1                      // IR_NONE: no argument
    b.eq 1f
    bl Lbk_in_arg0
1:
    ldr w0, [x21, #IRI_B]
    mov x1, #8
    bl Lbk_in_load_x
    ldr w3, [x21, #IRI_X]
    adrp x2, Lbk_st@PAGE
    add x2, x2, Lbk_st@PAGEOFF
    add x2, x2, #ST_FNPFX           // "Lfn_" or "Lsub_<u>_fn_"
    FMT Lbk_in_bl_fn
    b Lbk_in_next

// SRET: x0 = cell NP (the result descriptor), x1 = A; bl _bsk_str_set;
// then as `ret`: a multi-line function restores the caller's line; epilogue
Lbk_in_op_sret:
    cbz x25, Lbk_in_bad_place
    bl Lbk_in_fn_shape
    mov x3, x0
    adrp x0, Lbk_in_ldr@PAGE
    add x0, x0, Lbk_in_ldr@PAGEOFF
    adrp x1, Lbk_in_px@PAGE
    add x1, x1, Lbk_in_px@PAGEOFF
    mov x2, #0
    bl Lbk_in_cell
    ldr w0, [x21, #IRI_A]
    mov x1, #1
    bl Lbk_in_load_x
    adrp x2, Lbk_in_rt_str_set@PAGE
    add x2, x2, Lbk_in_rt_str_set@PAGEOFF
    FMT Lbk_in_bl_fmt
    b Lbk_in_ret_tail

// JEOF: d0 = A; bl _bsk_feof; jump to X when w0 is not 0
Lbk_in_op_jeof:
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load
    bl Lbk_in_ed_emit_call
    bl Lbk_in_lblpfx
    mov x2, x0
    ldr w3, [x21, #IRI_X]
    FMT Lbk_in_jeof_fmt
    b Lbk_in_next

// ---- Sixth Edition opcodes (docs/DESIGN.md 5.3, 5.3.1) -------------------
// SCAT: x0 = A, x1 = B (both sref); bl _bsk_str_cat
Lbk_in_op_scat:
    bl Lbk_in_load_ab_x
    adrp x2, Lbk_in_rt_str_cat@PAGE
    add x2, x2, Lbk_in_rt_str_cat@PAGEOFF
    FMT Lbk_in_bl_fmt
    b Lbk_in_next

// SSEG: x0 = address of cell X (as scell forms it), DST := x0; x1 = A,
// d0 = B, d1 = C; bl _bsk_seg
Lbk_in_op_sseg:
    ldr w9, [x21, #IRI_X]
    ldr w10, [x20, #IRM_NSTEMPS]
    cmp w9, w10
    b.hs Lbk_in_bad_slot
    mov w0, #1
    ldr w1, [x21, #IRI_X]
    bl Lbk_in_sd_addr
    ldr w0, [x21, #IRI_DST]
    mov x1, #0
    bl Lbk_in_store_x
    ldr w0, [x21, #IRI_A]
    mov x1, #1
    bl Lbk_in_load_x
    ldr w0, [x21, #IRI_B]
    mov x1, #0
    bl Lbk_in_load
    ldr w0, [x21, #IRI_C]
    mov x1, #1
    bl Lbk_in_load
    adrp x2, Lbk_in_rt_seg@PAGE
    add x2, x2, Lbk_in_rt_seg@PAGEOFF
    FMT Lbk_in_bl_fmt
    b Lbk_in_next

// POS: x0 = A, x1 = B (srefs), d0 = C; bl _bsk_pos; DST := d0
Lbk_in_op_pos:
    bl Lbk_in_load_ab_x
    ldr w0, [x21, #IRI_C]
    mov x1, #0
    bl Lbk_in_load
    adrp x2, Lbk_in_rt_pos@PAGE
    add x2, x2, Lbk_in_rt_pos@PAGEOFF
    FMT Lbk_in_bl_fmt
    b Lbk_in_store_dst

// VADDR: x0 = &numeric variable X (x19 + 8*X), or a numeric parameter's
// pointer in a SUB unit; DST := x0
Lbk_in_op_vaddr:
    ldr w9, [x21, #IRI_X]
    cmp w9, #SLOT_FOR_BASE          // user scalars 0..285 only
    b.hs Lbk_in_bad_slot
    mov w0, #SUBP_NUM
    ldr w1, [x21, #IRI_X]
    bl Lbk_in_find_param
    tbz x0, #63, 1f
    ldr w2, [x21, #IRI_X]
    lsl x2, x2, #3                  // at most 8*285: fits the immediate
    FMT Lbk_in_vaddr_fmt
    b Lbk_in_store_sref
1:
    mov x1, x0
    mov w0, #0
    bl Lbk_in_ldparam
    b Lbk_in_store_sref

// AADDR1: as ald1 up to the bl _bsk_aref1; DST := x0
Lbk_in_op_aaddr1:
    bl Lbk_in_desc_addr
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load
    adrp x2, Lbk_in_rt_aref1@PAGE
    add x2, x2, Lbk_in_rt_aref1@PAGEOFF
    FMT Lbk_in_bl_fmt
    b Lbk_in_store_sref

// AADDR2: as ald2 up to the bl _bsk_aref2; DST := x0
Lbk_in_op_aaddr2:
    bl Lbk_in_desc_addr
    bl Lbk_in_load_ab
    adrp x2, Lbk_in_rt_aref2@PAGE
    add x2, x2, Lbk_in_rt_aref2@PAGEOFF
    FMT Lbk_in_bl_fmt
    b Lbk_in_store_sref

// TADDR: x0 = sp + slot(A), the stack slot holding temp A; DST := x0
Lbk_in_op_taddr:
    ldr w0, [x21, #IRI_A]
    bl Lbk_in_use_off
    cmp x0, #BK_IMM12_MAX
    b.hi 1f
    mov x2, x0
    FMT Lbk_in_add_sp_imm
    b Lbk_in_store_sref
1:
    mov x2, x0
    mov x0, x19
    adrp x1, Lbk_in_x16@PAGE
    add x1, x1, Lbk_in_x16@PAGEOFF
    bl _bk_arm64_movimm
    FMT Lbk_in_add_sp_x16
    b Lbk_in_store_sref

// AREF / SAREF: x0 = the array's descriptor; DST := x0
Lbk_in_op_aref:
    mov w0, #0
    mov x1, #IRI_X
    bl Lbk_in_desc_reg
    b Lbk_in_store_sref
Lbk_in_op_saref:
    mov w0, #0
    mov x1, #IRI_X
    bl Lbk_in_sdesc_reg
    b Lbk_in_store_sref

// SUBARG k: x0 = A; argument-vector slot k = [sp, #8*(W+L+k)] := x0
Lbk_in_op_subarg:
    ldr x9, [x21, #IRI_IMM]
    sub x10, x9, #1
    cmp x10, #LIM_SUB_PARAMS - 2    // k = 1 .. LIM_SUB_PARAMS-1
    b.hi Lbk_in_bad_imm
    adrp x10, Lbk_st@PAGE
    add x10, x10, Lbk_st@PAGEOFF
    ldr w10, [x10, #ST_V]
    cmp x9, x10
    b.hs Lbk_in_bad_imm             // beyond this frame's argument vector
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_in_load_x
    bl Lbk_in_fn_cells
    ldr x9, [x21, #IRI_IMM]
    add x3, x9, w0, uxtw            // cell index L + k
    adrp x0, Lbk_in_str@PAGE
    add x0, x0, Lbk_in_str@PAGEOFF
    adrp x1, Lbk_in_px@PAGE
    add x1, x1, Lbk_in_px@PAGEOFF
    mov x2, #0
    bl Lbk_in_cell
    b Lbk_in_next

// CALLSUB: unless A = IR_NONE, slot 0 := A; x0 = &argument vector
// (sp + 8*(W+L)); bl Lsub_<X>; nothing is stored
Lbk_in_op_callsub:
    bl Lbk_in_pool
    ldr w9, [x0, #IRM_NSUBS]
    ldr w10, [x21, #IRI_X]
    cmp w10, w9
    b.hs Lbk_in_bad_sub
    ldr w0, [x21, #IRI_A]
    cmn w0, #1                      // IR_NONE: no arguments
    b.eq 1f
    adrp x10, Lbk_st@PAGE
    add x10, x10, Lbk_st@PAGEOFF
    ldr w10, [x10, #ST_V]
    cbz w10, Lbk_in_bad_sub         // an argument needs a vector slot
    mov x1, #0
    bl Lbk_in_load_x
    bl Lbk_in_fn_cells
    mov w3, w0                      // cell index L: argument slot 0
    adrp x0, Lbk_in_str@PAGE
    add x0, x0, Lbk_in_str@PAGEOFF
    adrp x1, Lbk_in_px@PAGE
    add x1, x1, Lbk_in_px@PAGEOFF
    mov x2, #0
    bl Lbk_in_cell
1:
    bl Lbk_in_fn_cells
    add x2, x23, w0, uxtw
    lsl x2, x2, #3                  // 8*(W+L)
    cmp x2, #BK_IMM12_MAX
    b.hi 2f
    FMT Lbk_in_add_sp_imm
    b 3f
2:
    mov x0, x19
    adrp x1, Lbk_in_x16@PAGE
    add x1, x1, Lbk_in_x16@PAGEOFF
    bl _bk_arm64_movimm
    FMT Lbk_in_add_sp_x16
3:
    ldr w2, [x21, #IRI_X]
    FMT Lbk_in_bl_sub
    b Lbk_in_next

// SUBRET (the SUB body only): bl _bsk_sub_leave, then the epilogue
Lbk_in_op_subret:
    cbnz x25, Lbk_in_bad_place
    adrp x9, Lbk_st@PAGE
    add x9, x9, Lbk_st@PAGEOFF
    ldr w9, [x9, #ST_UNIT]
    cbz w9, Lbk_in_bad_place
    adrp x2, Lbk_in_rt_sub_leave@PAGE
    add x2, x2, Lbk_in_rt_sub_leave@PAGEOFF
    FMT Lbk_in_bl_fmt
    FMT Lbk_in_epilogue
    b Lbk_in_next

Lbk_in_bad_sub:
    FAIL Lbk_in_err_sub

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
    .long Lbk_in_op_scell - Lbk_in_table // OP_SCELL 85
    .long Lbk_in_op_sstr - Lbk_in_table // OP_SSTR 86
    .long Lbk_in_op_sref_d - Lbk_in_table // OP_LEN 87
    .long Lbk_in_op_sref_d - Lbk_in_table // OP_ASC 88
    .long Lbk_in_op_sref_d - Lbk_in_table // OP_VAL 89
    .long Lbk_in_op_sald2 - Lbk_in_table // OP_SALD2 90
    .long Lbk_in_op_sparam - Lbk_in_table // OP_SPARAM 91
    .long Lbk_in_op_sfv - Lbk_in_table // OP_SFV 92
    .long Lbk_in_op_scallfn - Lbk_in_table // OP_SCALLFN 93
    .long Lbk_in_op_sret - Lbk_in_table // OP_SRET 94
    .long Lbk_in_op_prtab - Lbk_in_table // OP_FSEL 95 (d0 = A, one call)
    .long Lbk_in_op_jeof - Lbk_in_table // OP_JEOF 96
    .long Lbk_in_op_prtab - Lbk_in_table // OP_SCRATCH 97
    .long Lbk_in_op_prtab - Lbk_in_table // OP_FRESTORE 98
    .long Lbk_in_op_scat - Lbk_in_table // OP_SCAT 99
    .long Lbk_in_op_sseg - Lbk_in_table // OP_SSEG 100
    .long Lbk_in_op_pos - Lbk_in_table // OP_POS 101
    .long Lbk_in_op_vaddr - Lbk_in_table // OP_VADDR 102
    .long Lbk_in_op_aaddr1 - Lbk_in_table // OP_AADDR1 103
    .long Lbk_in_op_aaddr2 - Lbk_in_table // OP_AADDR2 104
    .long Lbk_in_op_taddr - Lbk_in_table // OP_TADDR 105
    .long Lbk_in_op_aref - Lbk_in_table // OP_AREF 106
    .long Lbk_in_op_saref - Lbk_in_table // OP_SAREF 107
    .long Lbk_in_op_subarg - Lbk_in_table // OP_SUBARG 108
    .long Lbk_in_op_callsub - Lbk_in_table // OP_CALLSUB 109
    .long Lbk_in_op_subret - Lbk_in_table // OP_SUBRET 110
    .long Lbk_in_op_linput - Lbk_in_table // OP_LINPUT 111
    .long Lbk_in_op_exit - Lbk_in_table // OP_EXIT 112
Lbk_in_table_end:
.if (Lbk_in_table_end - Lbk_in_table) != 4 * OP_COUNT
    .error "a64_insn.s dispatch table does not cover OP_COUNT opcodes"
.endif
.if (OP_MATINV != OP_MATREDIM + 12) || (OP_MATPRINT != OP_MATREDIM + 2) || (OP_MATSCALE != OP_MATREDIM + 10)
    .error "a64_insn.s MAT name table assumes opcodes 42..54 in contract order"
.endif
.if (OP_FRESTORE != OP_SCELL + 13) || (OP_SCAT != OP_FRESTORE + 1)
    .error "a64_insn.s Fifth Edition tables assume opcodes 85..98 in contract order"
.endif
.if (OP_SUBRET != OP_SCAT + 11) || (OP_COUNT != OP_EXIT + 1) || (OP_LINPUT != OP_SUBRET + 1) || (OP_EXIT != OP_LINPUT + 1)
    .error "a64_insn.s Sixth Edition and extension tables assume opcodes 99..112 in contract order"
.endif
.if (OP_STFV != OP_SLIT + 29) || (OP_SCELL != OP_STFV + 1)
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
    mov x11, x30                    // fn_cells is a leaf reached by bl
    bl Lbk_in_fn_cells
    mov x30, x11
    mov w9, w0                      // L local cells
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
// Lbk_in_fn_kinds -- IRM_FNKINDS bits of the function being emitted
// (0 for a function with no string parameter and a numeric value).
// Out: w0 = FNK_* bits.   Leaf, no frame; clobbers x9.
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_fn_kinds:
    add x9, x20, #IRM_FNKINDS
    ldr w0, [x9, x25, lsl #2]
    ret

// ---------------------------------------------------------------------
// Lbk_in_fn_cells -- L, the number of 8-byte local cells of the function
// being emitted (DESIGN.md 5.3): max(1, NP) for main and single-line
// functions, NP + 1 for a single-line string function (cell NP holds the
// result address), NP + 2 for a multi-line function.
// Out: w0 = L.   Leaf, no frame; clobbers x9, x10.
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_fn_cells:
    ldr w0, [x27, #IRF_NPARAMS]
    ldr w9, [x27, #IRF_KIND]
    cmp w9, #FUNC_KIND_FNML
    b.ne 1f
    add w0, w0, #2
    ret
1:
    add x10, x20, #IRM_FNKINDS
    ldr w10, [x10, x25, lsl #2]
    tst w10, #FNK_STRING
    b.eq 2f
    add w0, w0, #1
    ret
2:
    cmp w0, #1                      // L = max(1, NP)
    mov w9, #1
    csel w0, w9, w0, lo
    ret

// ---------------------------------------------------------------------
// Lbk_in_callee_kinds -- IRM_FNKINDS bits of a function.
// In:  w0 = function index (1 + letter).   Out: w0 = FNK_* bits.
// Leaf, no frame; clobbers x9.
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_callee_kinds:
    add x9, x20, #IRM_FNKINDS
    ldr w0, [x9, x0, lsl #2]
    ret

// ---------------------------------------------------------------------
// Lbk_in_call_kinds -- FNK_* bits of the callee of the call whose
// `fnarg` the current record is: the callfn / scallfn that follows the
// run of fnarg records (IR.md 3.2).  Preserves x1.
// In:  x21 = current record
// Out: w0 = FNK_* bits.   Leaf, no frame; clobbers x9, x10.
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_call_kinds:
    mov x9, x21
1:
    add x9, x9, #IRI_SIZE
    cmp x9, x22
    b.hs Lbk_in_bad_place           // no call follows
    ldrh w10, [x9, #IRI_OP]
    cmp w10, #OP_FNARG
    b.eq 1b
    cmp w10, #OP_CALLFN
    b.eq 2f
    cmp w10, #OP_SCALLFN
    b.ne Lbk_in_bad_place
2:
    ldr w10, [x9, #IRI_X]
    cmp w10, #NUM_LETTERS
    b.hs Lbk_in_bad_letter
    add w10, w10, #FUNC_FN_BASE
    add x9, x20, #IRM_FNKINDS
    ldr w0, [x9, x10, lsl #2]
    ret

// ---------------------------------------------------------------------
// Lbk_in_arg0 -- load argument 0 of the callfn / scallfn being emitted
// (temp A) into d0, or into x0 when the callee's parameter 0 is a
// string parameter.
// In:  x21 = current record (X = a valid letter)
// Frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_arg0:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    ldr w0, [x21, #IRI_X]
    add w0, w0, #FUNC_FN_BASE
    bl Lbk_in_callee_kinds
    and w9, w0, #FNK_SPARAM0
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    cbnz w9, 1f
    bl Lbk_in_load
    b 2f
1:
    bl Lbk_in_load_x
2:
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Lbk_in_pool -- the module that holds the program-wide pools (string
// constants, SUB units): the main module, also while a SUB unit's
// function is emitted (IR.md 2.2).
// Out: x0 = Module*.   Leaf, no frame; clobbers nothing else.
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_pool:
    adrp x0, Lbk_st@PAGE
    add x0, x0, Lbk_st@PAGEOFF
    ldr x0, [x0, #ST_POOL]
    ret

// ---------------------------------------------------------------------
// Lbk_in_lblpfx -- the text prefix of this function's label names
// (label text is prefix + decimal id, DESIGN.md 5.3, 5.3.1): "Lbsk_L" for
// main, "Lfn_<L>_L" for a multi-line function FN<L>, "Lsub_<u>_L" for a
// SUB body, "Lsub_<u>_fn_<L>_L" for a multi-line function of unit u.
// Out: x0 = NUL-terminated prefix (built by Lbk_in_setup)
// Leaf, no frame; clobbers nothing else (preserves x1-x17).
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_lblpfx:
    adrp x0, Lbk_st@PAGE
    add x0, x0, Lbk_st@PAGEOFF
    add x0, x0, #ST_LBLPFX
    ret

// ---------------------------------------------------------------------
// Lbk_in_find_param -- the parameter of the SUB unit being emitted that
// a variable or array is (DESIGN.md 5.3.1 "Addressing in a unit").
// In:  w0 = SUBP_* kind, w1 = slot (SUBP_NUM, SUBP_STR) or letter
//      (SUBP_ARR, SUBP_SARR)
// Out: x0 = parameter index k, or -1 (not a parameter, or not in a unit)
// Leaf, no frame; clobbers x9-x13; preserves x1-x8.
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_find_param:
    mov w12, w0                     // kind sought
    mov x0, #-1
    adrp x9, Lbk_st@PAGE
    add x9, x9, Lbk_st@PAGEOFF
    ldr w10, [x9, #ST_UNIT]
    cbz w10, 2f                     // main and its FN functions: none
    ldr w10, [x20, #IRM_SUBNPARAMS]
    mov x11, #0
1:
    cmp x11, x10
    b.hs 2f
    // parameter k matches when its kind and its slot/letter both do
    add x13, x20, #IRM_SUBPKINDS
    ldrb w13, [x13, x11]
    cmp w13, w12
    b.ne 3f
    add x13, x20, #IRM_SUBPARAMS
    ldr w13, [x13, x11, lsl #2]
    cmp w13, w1
    b.ne 3f
    mov x0, x11
    ret
3:
    add x11, x11, #1
    b 1b
2:
    ret

// ---------------------------------------------------------------------
// Lbk_in_ldparam -- emit "ldr x<n>, [x19, #P(k)]": parameter pointer k of
// the current activation block, P(k) = PARAMOFF + 8k (offsets above the
// immediate range go through x16, which is legal even for n = 16).
// In:  w0 = register number n, x1 = parameter index k
// Frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_ldparam:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov w2, w0
    adrp x9, Lbk_st@PAGE
    add x9, x9, Lbk_st@PAGEOFF
    ldr w4, [x9, #ST_LAYOUT + 4*LAY_PARAMOFF]
    add x4, x4, x1, lsl #3
    adrp x1, Lbk_in_ldr@PAGE
    add x1, x1, Lbk_in_ldr@PAGEOFF
    adrp x3, Lbk_in_x19@PAGE
    add x3, x3, Lbk_in_x19@PAGEOFF
    adrp x5, Lbk_in_px@PAGE
    add x5, x5, Lbk_in_px@PAGEOFF
    mov x0, x19
    bl _bk_arm64_memop
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Lbk_in_add_x19 -- emit "add x<n>, x19, #off" (an address inside the
// activation block), via x16 when off does not fit 12 bits.
// In:  w0 = register number n, x1 = byte offset
// Frame: 32 bytes (frame record + saved n and offset)
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_add_x19:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    mov w2, w0
    str x2, [sp, #16]
    cmp x1, #BK_IMM12_MAX
    b.hi 1f
    mov x3, x1
    FMT Lbk_in_add_x19_imm
    b 2f
1:
    mov x0, x19
    mov x2, x1
    adrp x1, Lbk_in_x16@PAGE
    add x1, x1, Lbk_in_x16@PAGEOFF
    bl _bk_arm64_movimm
    ldr x2, [sp, #16]
    FMT Lbk_in_add_x19_x16
2:
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lbk_in_sd_addr -- emit code leaving in x0 the address of string
// variable s or string temp cell X of the current program unit: in main
// "adrp/add x0, _bsk_svars|_bsk_scells" + 16*index; in a SUB unit
// "add x0, x19, #<SDOFF + 16*s>" or "#<SDOFF + 4576 + 16*X>" (5.3.1).
// In:  w0 = 0 for a string variable, 1 for a string temp cell;
//      w1 = slot or cell index
// Frame: 32 bytes (frame record + saved kind and index)
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_sd_addr:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x0, x1, [sp, #16]
.if (SD_SIZE != 16)
    .error "a64_insn.s shifts SD indices by 4: SD_SIZE must be 16"
.endif
    adrp x9, Lbk_st@PAGE
    add x9, x9, Lbk_st@PAGEOFF
    ldr w10, [x9, #ST_UNIT]
    cbz w10, 1f
    // unit: SDOFF + 16*index (+ the 286 string variables for a cell)
    ldr w11, [x9, #ST_LAYOUT + 4*LAY_SDOFF]
    mov w1, w1
    add x1, x11, x1, lsl #4
    mov x12, #NUM_STRING_SLOTS * SD_SIZE
    cmp w0, #0
    csel x12, xzr, x12, eq
    add x1, x1, x12
    mov w0, #0
    bl Lbk_in_add_x19
    b 9f
1:
    // main: the static base, then the offset
    cbnz w0, 2f
    FMT Lbk_in_svar_base
    b 3f
2:
    FMT Lbk_in_scell_base
3:
    ldr x9, [sp, #24]
    mov w9, w9
    lsl x9, x9, #4                  // SD_SIZE * index
    cbz x9, 9f
    cmp x9, #BK_IMM12_MAX
    b.hi 4f
    mov x2, x9
    FMT Lbk_in_svar_add
    b 9f
4:
    mov x0, x19
    adrp x1, Lbk_in_x16@PAGE
    add x1, x1, Lbk_in_x16@PAGEOFF
    mov x2, x9
    bl _bk_arm64_movimm
    FMT Lbk_in_svar_addx16
9:
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lbk_in_desc_addr -- Lbk_in_desc_reg for x0 and the record's X field.
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_desc_addr:
    mov w0, #0
    mov x1, #IRI_X
    b Lbk_in_desc_reg

// ---------------------------------------------------------------------
// Lbk_in_desc_reg -- emit code leaving in x<n> the descriptor address of
// the numeric array whose letter is in the current record's field at
// offset x1: "adrp/add x<n>, Ldesc_<L>" in main; in a SUB unit
// "add x<n>, x19, #<DESCOFF + 32*d(L)>", or "ldr x<n>, [x19, #P(k)]" for
// an array parameter k (DESIGN.md 5.3.1).
// In:  w0 = register number n, x1 = field offset (IRI_X/IRI_A/IRI_B),
//      x21 = current record
// Checks: the field is a letter of an array in use.
// Frame: 32 bytes (frame record + saved n and letter)
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_desc_reg:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    ldr w3, [x21, x1]
    cmp w3, #NUM_LETTERS
    b.hs Lbk_in_desc_reg_bad
    add x9, x20, #IRM_ARRAYS
    add x9, x9, x3, lsl #4
    ldr w9, [x9, #IRA_DIMS]
    cbz w9, Lbk_in_desc_reg_bad
    mov w0, w0
    stp x0, x3, [sp, #16]
    // an array parameter: the caller's descriptor
    mov w0, #SUBP_ARR
    mov w1, w3
    bl Lbk_in_find_param
    tbz x0, #63, 2f
    adrp x9, Lbk_st@PAGE
    add x9, x9, Lbk_st@PAGEOFF
    ldr w10, [x9, #ST_UNIT]
    cbnz w10, 1f
    // main: the static descriptor
    ldp x2, x3, [sp, #16]
    mov x4, x2
    mov x5, x2
    mov x6, x3
    FMT Lbk_in_desc_reg_fmt
    b 9f
1:
    // unit: the block's descriptor
    ldr x3, [sp, #24]
    add x9, x9, #ST_LAYOUT + 4*LAY_NDESC_L
    ldr w1, [x9, x3, lsl #2]
    cmn w1, #1
    b.eq Lbk_in_desc_reg_bad
    ldr x0, [sp, #16]
    bl Lbk_in_add_x19
    b 9f
2:
    mov x1, x0
    ldr x0, [sp, #16]
    bl Lbk_in_ldparam
9:
    ldp x29, x30, [sp], #32
    ret
Lbk_in_desc_reg_bad:
    FAIL Lbk_in_err_letter

// ---------------------------------------------------------------------
// Lbk_in_sdesc_reg -- as Lbk_in_desc_reg for the string array (list or
// table) whose letter is in the current record's field at offset x1:
// "adrp/add x<n>, Lsdesc_<L>" in main; the block's descriptor or a string
// array parameter's pointer in a SUB unit.
// In:  w0 = register number n, x1 = field offset (IRI_X; IRI_IMM for
//      the element form of chgn2s, whose low word holds the letter),
//      x21 = current record
// Checks: the field is a letter of a string list or table in use (an
//         array parameter may also have DIMS IRA_DIMS_ANY).
// Frame: 32 bytes (frame record + saved n and letter)
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_sdesc_reg:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    ldr w3, [x21, x1]
    cmp w3, #NUM_LETTERS
    b.hs Lbk_in_sdesc_reg_bad
    mov w0, w0
    stp x0, x3, [sp, #16]
    // a string array parameter: the caller's descriptor
    mov w0, #SUBP_SARR
    mov w1, w3
    bl Lbk_in_find_param
    tbz x0, #63, 2f
    ldr x3, [sp, #24]
    add x9, x20, #IRM_SARRAYS
    add x9, x9, x3, lsl #4
    ldr w9, [x9, #IRA_DIMS]
    sub w9, w9, #1                  // a string list (1) or table (2)
    cmp w9, #1
    b.hi Lbk_in_sdesc_reg_bad
    adrp x9, Lbk_st@PAGE
    add x9, x9, Lbk_st@PAGEOFF
    ldr w10, [x9, #ST_UNIT]
    cbnz w10, 1f
    // main: the static descriptor
    ldp x2, x3, [sp, #16]
    mov x4, x2
    mov x5, x2
    mov x6, x3
    FMT Lbk_in_sdesc_reg_fmt
    b 9f
1:
    // unit: the block's descriptor
    add x9, x9, #ST_LAYOUT + 4*LAY_SDESC_L
    ldr w1, [x9, x3, lsl #2]
    cmn w1, #1
    b.eq Lbk_in_sdesc_reg_bad
    ldr x0, [sp, #16]
    bl Lbk_in_add_x19
    b 9f
2:
    mov x1, x0
    ldr x0, [sp, #16]
    bl Lbk_in_ldparam
9:
    ldp x29, x30, [sp], #32
    ret
Lbk_in_sdesc_reg_bad:
    FAIL Lbk_in_err_letter

// ---------------------------------------------------------------------
// Lbk_in_setup -- fill the per-function state Lbk_st for the function
// _bk_arm64_emit_func is about to emit: the pool module, the unit flag
// and (in a unit) its block layout, the FN call prefix ("Lfn_" or
// "Lsub_<u>_fn_"), the function's label name and its label prefix
// (DESIGN.md 5.3, 5.3.1).
// In:  x20 = Module*, x25 = function index, x27 = Function*
// Out: x0 = 0, or a reason (bad SUB body placement, bad unit layout)
// Callee-saved used: x28 = &Lbk_st (saved and restored)
// Frame: 32 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lbk_in_setup:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x28, [sp, #16]
    adrp x28, Lbk_st@PAGE
    add x28, x28, Lbk_st@PAGEOFF
    str x20, [x28, #ST_POOL]
    str wzr, [x28, #ST_UNIT]
    str wzr, [x28, #ST_V]
    // a SUB unit has a parent: the pools are the parent's
    ldr x9, [x20, #IRM_PARENT]
    cbz x9, 1f
    str x9, [x28, #ST_POOL]
    mov w9, #1
    str w9, [x28, #ST_UNIT]
    mov x0, x20
    add x1, x28, #ST_LAYOUT
    bl _bk_arm64_unit_layout
    cbnz x0, Lbk_in_setup_ret
1:
    // ---- FN call prefix
    add x0, x28, #ST_FNPFX
    ldr w9, [x28, #ST_UNIT]
    cbnz w9, 2f
    adrp x1, Lbk_s_lfn@PAGE
    add x1, x1, Lbk_s_lfn@PAGEOFF
    bl Lbk_cpy
    b 3f
2:
    adrp x1, Lbk_s_lsub@PAGE
    add x1, x1, Lbk_s_lsub@PAGEOFF
    bl Lbk_cpy
    ldr w1, [x20, #IRM_UNITIDX]
    bl Lbk_dec
    adrp x1, Lbk_s_fn@PAGE
    add x1, x1, Lbk_s_fn@PAGEOFF
    bl Lbk_cpy
3:
    // ---- the function's label name
    add x0, x28, #ST_NAME
    cbnz x25, 5f
    // index 0: the body of a SUB unit exactly when the module is a unit
    ldr w9, [x27, #IRF_KIND]
    cmp w9, #FUNC_KIND_SUB
    cset w9, eq
    ldr w10, [x28, #ST_UNIT]
    cmp w9, w10
    b.ne Lbk_in_setup_kind
    cbnz w10, 4f
    adrp x1, Lbk_s_prog@PAGE
    add x1, x1, Lbk_s_prog@PAGEOFF
    bl Lbk_cpy
    // main's labels: Lbsk_L<id>
    add x0, x28, #ST_LBLPFX
    adrp x1, Lbk_in_pfx_main@PAGE
    add x1, x1, Lbk_in_pfx_main@PAGEOFF
    bl Lbk_cpy
    b 7f
4:
    // SUB body: Lsub_<u>
    adrp x1, Lbk_s_lsub@PAGE
    add x1, x1, Lbk_s_lsub@PAGEOFF
    bl Lbk_cpy
    ldr w1, [x20, #IRM_UNITIDX]
    bl Lbk_dec
    b 6f
5:
    // FN function: <FN call prefix><letter>
    add x1, x28, #ST_FNPFX
    bl Lbk_cpy
    sub w9, w25, #FUNC_FN_BASE
    add w9, w9, #'A'
    strb w9, [x0], #1
    strb wzr, [x0]
6:
    // label prefix: <name>_L
    add x0, x28, #ST_LBLPFX
    add x1, x28, #ST_NAME
    bl Lbk_cpy
    adrp x1, Lbk_s_L@PAGE
    add x1, x1, Lbk_s_L@PAGEOFF
    bl Lbk_cpy
7:
    mov x0, #0
Lbk_in_setup_ret:
    ldr x28, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
Lbk_in_setup_kind:
    adrp x0, Lbk_in_err_kind@PAGE
    add x0, x0, Lbk_in_err_kind@PAGEOFF
    b Lbk_in_setup_ret

// ---------------------------------------------------------------------
// Lbk_cpy -- copy a NUL-terminated string, NUL included.
// In:  x0 = destination, x1 = source
// Out: x0 = address of the copied NUL (append point)
// Leaf, no frame; clobbers x1, x9.
// ---------------------------------------------------------------------
    .p2align 2
Lbk_cpy:
    ldrb w9, [x1], #1
    strb w9, [x0]
    cbz w9, 1f
    add x0, x0, #1
    b Lbk_cpy
1:
    ret

// ---------------------------------------------------------------------
// Lbk_dec -- write an unsigned value in decimal, NUL-terminated.
// In:  x0 = destination, x1 = value
// Out: x0 = address of the NUL (append point)
// Leaf, no frame; clobbers x1, x9-x12.
// ---------------------------------------------------------------------
    .p2align 2
Lbk_dec:
    mov x12, #10
    // count the digits
    mov x9, x1
    mov x10, #0
1:
    udiv x9, x9, x12
    add x10, x10, #1
    cbnz x9, 1b
    add x0, x0, x10
    strb wzr, [x0]
    mov x11, x0
    // store them from the last one backwards
2:
    udiv x9, x1, x12
    msub x10, x9, x12, x1
    add w10, w10, #'0'
    strb w10, [x11, #-1]!
    mov x1, x9
    cbnz x1, 2b
    ret

// ---------------------------------------------------------------------
// _bk_arm64_func_frame -- the frame shape of one IR function (DESIGN.md
// 5.3 "Frames and temps", "Sixth Edition frames"; the same W, L, V that
// 5.3.1 uses for SUBL_COST): W = the largest number of temps defined
// between two `line` instructions, L = the local cells, V = the largest
// SUBNPARAMS of the units its `callsub` instructions call (0 without).
// In:  x0 = const Module* (main or a SUB unit), x1 = function index
//      (the function must be present)
// Out: x0 = 0 on success, else a reason; x1 = W, x2 = L, x3 = V
// Clobbers: x0-x17
// Callee-saved used: x20 = Module*, x21 = instruction cursor,
//                    x22 = end of the instructions, x25 = function
//                    index, x27 = Function*, x28 = W (the names
//                    Lbk_in_fn_cells reads)
// Frame: 64 bytes
// ---------------------------------------------------------------------
    .globl _bk_arm64_func_frame
    .p2align 2
_bk_arm64_func_frame:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x20, x21, [sp, #16]
    stp x22, x25, [sp, #32]
    stp x27, x28, [sp, #48]
    mov x20, x0
    mov x25, x1
    add x27, x20, #IRM_FUNCS
    mov x9, #IRF_SIZE
    madd x27, x25, x9, x27
    ldr x21, [x27, #IRF_INSNS]
    ldr w9, [x27, #IRF_NINSNS]
    add x22, x21, x9, lsl #IRI_SHIFT
    mov x28, #0                     // W
    mov x14, #0                     // V
    mov x10, #-1                    // segment base, -1 = none yet
    mov x11, x21
Lbk_ff_loop:
    cmp x11, x22
    b.hs Lbk_ff_done
    ldrh w12, [x11, #IRI_OP]
    cmp w12, #OP_LINE
    b.ne 1f
    // a `line` starts a new segment
    mov x10, #-1
    b Lbk_ff_next
1:
    cmp w12, #OP_CALLSUB
    b.ne 2f
    // V = max(V, SUBNPARAMS of the called unit, numbered in the main module)
    ldr x13, [x20, #IRM_PARENT]
    cmp x13, #0
    csel x13, x20, x13, eq
    ldr w15, [x11, #IRI_X]
    ldr w9, [x13, #IRM_NSUBS]
    cmp w15, w9
    b.hs Lbk_ff_badsub
    ldr x13, [x13, #IRM_SUBS]
    ldr x13, [x13, x15, lsl #3]
    ldr w15, [x13, #IRM_SUBNPARAMS]
    cmp x15, x14
    csel x14, x15, x14, hi
2:
    ldr w12, [x11, #IRI_DST]
    cmn w12, #1                     // IR_NONE: defines nothing
    b.eq Lbk_ff_next
    // first definition of the segment fixes its base
    cmn x10, #1
    csel x10, x12, x10, eq
    cmp x12, x10
    b.lo Lbk_ff_order
    // W = max(W, t - base + 1)
    sub x13, x12, x10
    add x13, x13, #1
    cmp x13, x28
    csel x28, x13, x28, hi
Lbk_ff_next:
    add x11, x11, #IRI_SIZE
    b Lbk_ff_loop
Lbk_ff_done:
    bl Lbk_in_fn_cells              // w0 = L (reads x20, x25, x27)
    mov w2, w0
    mov x1, x28
    mov x3, x14
    mov x0, #0
    b Lbk_ff_ret
Lbk_ff_order:
    adrp x0, Lbk_in_err_order@PAGE
    add x0, x0, Lbk_in_err_order@PAGEOFF
    b Lbk_ff_ret
Lbk_ff_badsub:
    adrp x0, Lbk_in_err_sub@PAGE
    add x0, x0, Lbk_in_err_sub@PAGEOFF
Lbk_ff_ret:
    ldp x27, x28, [sp, #48]
    ldp x22, x25, [sp, #32]
    ldp x20, x21, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

// ---------------------------------------------------------------------
// _bk_arm64_unit_layout -- the activation block layout of a SUB unit
// (DESIGN.md 5.3.1 "Activation block"), as LAY_WORDS u32 words:
//   LAY_PARAMOFF = 8*NSLOTS, LAY_SDOFF = align16(PARAMOFF + 8*SUBNPARAMS),
//   LAY_NSD = 286 + NSTEMPS + the caps of the non-parameter string arrays,
//   LAY_DESCOFF = SDOFF + 16*NSD, LAY_NDESC, LAY_SIZE = align16(end);
//   per letter L (IR_NONE when the array has no block storage):
//   LAY_NDESC_L / LAY_SDESC_L = block offset of the descriptor of the
//   numeric / string array (DESCOFF + 32*d(L), numeric arrays first),
//   LAY_NDATA_L / LAY_SDATA_L = block offset of its elements.
// In:  x0 = const unit Module*, x1 = u32[LAY_WORDS] result
// Out: x0 = 0 on success, else a reason (dims > 2, block over 4 GiB)
// Leaf, no frame; clobbers x0-x17.
// ---------------------------------------------------------------------
    .globl _bk_arm64_unit_layout
    .p2align 2
_bk_arm64_unit_layout:
    mov x16, x0                     // unit
    mov x17, x1                     // result words
    // parameter pointers after the numeric slots
    ldr w9, [x16, #IRM_NSLOTS]
    lsl x9, x9, #3
    str w9, [x17, #4*LAY_PARAMOFF]
    // SD records after them, 16-byte aligned
    ldr w10, [x16, #IRM_SUBNPARAMS]
    add x10, x9, x10, lsl #3
    add x10, x10, #15
    and x10, x10, #~15              // x10 = SDOFF
    str w10, [x17, #4*LAY_SDOFF]
    // 286 string variables, the unit's string temp cells, then the
    // elements of each non-parameter string array in letter order
    ldr w11, [x16, #IRM_NSTEMPS]
    add x11, x11, #NUM_STRING_SLOTS // x11 = SD records so far
    mov x12, #0
Lbk_ul_sdata:
    add x13, x16, #IRM_SARRAYS
    add x13, x13, x12, lsl #4
    mov w0, #-1                     // IR_NONE: no block storage
    ldr w14, [x13, #IRA_DIMS]
    cbz w14, 1f
    ldr w15, [x13, #IRA_FLAGS]
    tst w15, #IRA_FLAG_PARAM
    b.ne 1f
    cmp w14, #2
    b.hi Lbk_ul_dims
    add x0, x10, x11, lsl #4        // its first SD record
    ldr w1, [x13, #IRA_B1]
    add x1, x1, #1
    ldr w2, [x13, #IRA_B2]
    add x2, x2, #1
    mul x1, x1, x2                  // cap = (b1+1)*(b2+1)
    add x11, x11, x1
1:
    add x3, x17, #4*LAY_SDATA_L
    str w0, [x3, x12, lsl #2]
    add x12, x12, #1
    cmp x12, #NUM_LETTERS
    b.lo Lbk_ul_sdata
    str w11, [x17, #4*LAY_NSD]
    // descriptors after the SD records
    add x9, x10, x11, lsl #4        // x9 = DESCOFF
    str w9, [x17, #4*LAY_DESCOFF]
    mov x11, #0                     // x11 = descriptors so far
    // numeric arrays first, letter order
    mov x12, #0
Lbk_ul_ndesc:
    add x13, x16, #IRM_ARRAYS
    add x13, x13, x12, lsl #4
    mov w0, #-1
    ldr w14, [x13, #IRA_DIMS]
    cbz w14, 1f
    ldr w15, [x13, #IRA_FLAGS]
    tst w15, #IRA_FLAG_PARAM
    b.ne 1f
    cmp w14, #2
    b.hi Lbk_ul_dims
    add x0, x9, x11, lsl #5         // DESCOFF + 32*d(L)
    add x11, x11, #1
1:
    add x3, x17, #4*LAY_NDESC_L
    str w0, [x3, x12, lsl #2]
    add x12, x12, #1
    cmp x12, #NUM_LETTERS
    b.lo Lbk_ul_ndesc
    // then the string arrays, letter order
    mov x12, #0
Lbk_ul_sdesc:
    add x3, x17, #4*LAY_SDATA_L
    ldr w0, [x3, x12, lsl #2]
    cmn w0, #1
    b.eq 1f
    add x0, x9, x11, lsl #5
    add x11, x11, #1
1:
    add x3, x17, #4*LAY_SDESC_L
    str w0, [x3, x12, lsl #2]
    add x12, x12, #1
    cmp x12, #NUM_LETTERS
    b.lo Lbk_ul_sdesc
    str w11, [x17, #4*LAY_NDESC]
    // numeric element storage after the descriptors, letter order
    add x10, x9, x11, lsl #5        // x10 = next free byte
    mov x12, #0
Lbk_ul_ndata:
    add x3, x17, #4*LAY_NDESC_L
    ldr w0, [x3, x12, lsl #2]
    cmn w0, #1
    b.eq 1f
    add x13, x16, #IRM_ARRAYS
    add x13, x13, x12, lsl #4
    mov x0, x10
    ldr w1, [x13, #IRA_B1]
    add x1, x1, #1
    ldr w2, [x13, #IRA_B2]
    add x2, x2, #1
    mul x1, x1, x2
    add x10, x10, x1, lsl #3        // 8 * cap
1:
    add x3, x17, #4*LAY_NDATA_L
    str w0, [x3, x12, lsl #2]
    add x12, x12, #1
    cmp x12, #NUM_LETTERS
    b.lo Lbk_ul_ndata
    // SIZE = align16(end), a u32
    add x10, x10, #15
    and x10, x10, #~15
    lsr x9, x10, #32
    cbnz x9, Lbk_ul_big
    str w10, [x17, #4*LAY_SIZE]
    mov x0, #0
    ret
Lbk_ul_dims:
    adrp x0, Lbk_in_err_dims@PAGE
    add x0, x0, Lbk_in_err_dims@PAGEOFF
    ret
Lbk_ul_big:
    adrp x0, Lbk_in_err_big@PAGE
    add x0, x0, Lbk_in_err_big@PAGEOFF
    ret

// ---------------------------------------------------------------------
// Lbk_unit_cost -- SUBL_COST of a SUB unit in 8-byte words (DESIGN.md
// 5.3.1 "Unit cost"):
//   frame(f)  = W(f) + L(f) + V(f) + RT_FRAME_EXTRA_WORDS
//   fchain(g) = frame(g) + max(0, max over the callees h of g: fchain(h))
//   chain(u)  = max(0, max over the present FN functions g: fchain(g))
//   COST(u)   = SIZE/8 + frame(SUB body) + chain(u)
// fchain is found by relaxation over the unit's 26 FN functions (at most
// 26 rounds change it, since FN calls never recurse; a 27th change means
// a recursive call: an internal error).
// In:  x0 = const unit Module*, x1 = SIZE (bytes)
// Out: x0 = 0 on success, else a reason; x1 = COST
// Clobbers: x0-x17
// Callee-saved used: x19 = unit, x20 = SIZE, x21 = function index g,
//                    x22 = round, x23 = "changed" flag, x24 = Function*,
//                    x25 = instruction cursor, x26 = end of instructions,
//                    x27 = largest callee fchain, x28 = &frame[0]
// Frame: 96 bytes + 448 (frame[27], fchain[27] as u64 at sp, sp+216)
// ---------------------------------------------------------------------
.equ BK_UC_FCH, 8 * NUM_FUNCS       // fchain[] after frame[]
    .p2align 2
Lbk_unit_cost:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    sub sp, sp, #(16 * NUM_FUNCS + 15) & ~15
    mov x28, sp
    mov x19, x0
    mov x20, x1
    // ---- frame(f) of every present function (0 = absent) ---------------
    mov x21, #0
Lbk_uc_frames:
    add x24, x19, #IRM_FUNCS
    mov x9, #IRF_SIZE
    madd x24, x21, x9, x24
    mov x0, #0
    ldr w9, [x24, #IRF_PRESENT]
    cbz w9, 1f
    mov x0, x19
    mov x1, x21
    bl _bk_arm64_func_frame
    cbnz x0, Lbk_uc_ret
    add x0, x1, x2
    add x0, x0, x3
    add x0, x0, #RT_FRAME_EXTRA_WORDS
1:
    str x0, [x28, x21, lsl #3]
    add x9, x28, #BK_UC_FCH
    str x0, [x9, x21, lsl #3]       // fchain starts at frame
    add x21, x21, #1
    cmp x21, #NUM_FUNCS
    b.lo Lbk_uc_frames
    ldr x9, [x28]
    cbz x9, Lbk_uc_nobody           // the SUB body must exist
    // ---- relaxation rounds -----------------------------------------------
    mov x22, #0
Lbk_uc_round:
    mov x23, #0
    mov x21, #FUNC_FN_BASE
Lbk_uc_fn:
    ldr x9, [x28, x21, lsl #3]
    cbz x9, Lbk_uc_fn_next          // absent
    add x24, x19, #IRM_FUNCS
    mov x9, #IRF_SIZE
    madd x24, x21, x9, x24
    ldr x25, [x24, #IRF_INSNS]
    ldr w9, [x24, #IRF_NINSNS]
    add x26, x25, x9, lsl #IRI_SHIFT
    mov x27, #0
Lbk_uc_scan:
    cmp x25, x26
    b.hs Lbk_uc_scanned
    ldrh w9, [x25, #IRI_OP]
    cmp w9, #OP_CALLFN
    b.eq 1f
    cmp w9, #OP_SCALLFN
    b.ne 2f
1:
    // a call of FN letter X of the same unit
    ldr w10, [x25, #IRI_X]
    cmp w10, #NUM_LETTERS
    b.hs Lbk_uc_badcall
    add x10, x10, #FUNC_FN_BASE
    ldr x11, [x28, x10, lsl #3]
    cbz x11, Lbk_uc_badcall         // callee absent
    add x11, x28, #BK_UC_FCH
    ldr x11, [x11, x10, lsl #3]
    cmp x11, x27
    csel x27, x11, x27, hi
2:
    add x25, x25, #IRI_SIZE
    b Lbk_uc_scan
Lbk_uc_scanned:
    // fchain(g) := frame(g) + the largest callee fchain
    ldr x9, [x28, x21, lsl #3]
    add x9, x9, x27
    add x10, x28, #BK_UC_FCH
    ldr x11, [x10, x21, lsl #3]
    cmp x9, x11
    b.eq Lbk_uc_fn_next
    str x9, [x10, x21, lsl #3]
    mov x23, #1
Lbk_uc_fn_next:
    add x21, x21, #1
    cmp x21, #NUM_FUNCS
    b.lo Lbk_uc_fn
    cbz x23, Lbk_uc_settled
    add x22, x22, #1
    cmp x22, #NUM_FUNCS
    b.hs Lbk_uc_badcall             // still changing: recursive FN calls
    b Lbk_uc_round
Lbk_uc_settled:
    // chain = max fchain over the FN functions (0 when there are none)
    mov x27, #0
    mov x21, #FUNC_FN_BASE
    add x10, x28, #BK_UC_FCH
1:
    ldr x11, [x10, x21, lsl #3]
    cmp x11, x27
    csel x27, x11, x27, hi
    add x21, x21, #1
    cmp x21, #NUM_FUNCS
    b.lo 1b
    // COST = SIZE/8 + frame(body) + chain, a u32
    lsr x1, x20, #3
    ldr x9, [x28]
    add x1, x1, x9
    add x1, x1, x27
    lsr x9, x1, #32
    cbnz x9, Lbk_uc_big
    mov x0, #0
    b Lbk_uc_ret
Lbk_uc_nobody:
    adrp x0, Lbk_in_err_kind@PAGE
    add x0, x0, Lbk_in_err_kind@PAGEOFF
    b Lbk_uc_ret
Lbk_uc_badcall:
    adrp x0, Lbk_in_err_fncall@PAGE
    add x0, x0, Lbk_in_err_fncall@PAGEOFF
    b Lbk_uc_ret
Lbk_uc_big:
    adrp x0, Lbk_in_err_big@PAGE
    add x0, x0, Lbk_in_err_big@PAGEOFF
Lbk_uc_ret:
    mov sp, x29
    ldp x27, x28, [sp, #80]
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret

// ---------------------------------------------------------------------
// _bk_arm64_emit_subl -- emit the Lsubl_<u> record and the Lsubt_<u>
// descriptor templates of every SUB unit (DESIGN.md 5.3.1 "Records"),
// into the current section (__DATA,__const, after _bsk_files_count).
// In:  x0 = OutBuf*, x1 = const main Module*
// Out: x0 = 0 on success, else a reason
// Clobbers: x0-x17, d0-d7, d16-d31
// Callee-saved used: x19 = OutBuf*, x20 = main Module*, x21 = unit index
//                    u, x22 = unit Module*, x23 = COST, x24 = parameter
//                    index / letter, x25 = &layout words, x26-x28 saved
//                    but unused
// Frame: 96 bytes + the layout words (4*LAY_WORDS, rounded to 16)
// ---------------------------------------------------------------------
.equ BK_SU_LAY, (4 * LAY_WORDS + 15) & ~15
    .globl _bk_arm64_emit_subl
    .p2align 2
_bk_arm64_emit_subl:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    sub sp, sp, #BK_SU_LAY
    mov x25, sp
    mov x19, x0
    mov x20, x1
    mov x21, #0
Lbk_su_unit:
    ldr w9, [x20, #IRM_NSUBS]
    cmp x21, x9
    b.hs Lbk_su_ok
    ldr x9, [x20, #IRM_SUBS]
    ldr x22, [x9, x21, lsl #3]
    // layout and cost
    mov x0, x22
    mov x1, x25
    bl _bk_arm64_unit_layout
    cbnz x0, Lbk_su_ret
    mov x0, x22
    ldr w1, [x25, #4*LAY_SIZE]
    bl Lbk_unit_cost
    cbnz x0, Lbk_su_ret
    mov x23, x1
    // ".long SIZE, NPARAMS, PARAMOFF, SDOFF" / ".long NSD, DESCOFF, NDESC, COST"
    mov x2, x21
    ldr w3, [x25, #4*LAY_SIZE]
    ldr w4, [x22, #IRM_SUBNPARAMS]
    ldr w5, [x25, #4*LAY_PARAMOFF]
    ldr w6, [x25, #4*LAY_SDOFF]
    FMT Lbk_su_head
    ldr w2, [x25, #4*LAY_NSD]
    ldr w3, [x25, #4*LAY_DESCOFF]
    ldr w4, [x25, #4*LAY_NDESC]
    mov x5, x23
    FMT Lbk_su_long4
    // ".quad Lsubt_<u>" (".quad 0" without descriptors)
    ldr w9, [x25, #4*LAY_NDESC]
    cbz w9, 1f
    mov x2, x21
    FMT Lbk_su_quad_t
    b 2f
1:
    FMT Lbk_su_quad_0
2:
    // SUBL_PDIMS: SUBD_* per parameter, 0 when unused
    FMT Lbk_su_byte
    mov x24, #0
Lbk_su_pdims:
    mov x2, #SUBD_SCALAR
    ldr w9, [x22, #IRM_SUBNPARAMS]
    cmp x24, x9
    b.hs 4f
    add x9, x22, #IRM_SUBPKINDS
    ldrb w9, [x9, x24]
    add x10, x22, #IRM_SUBPARAMS
    ldr w10, [x10, x24, lsl #2]     // slot or letter
    cmp w9, #SUBP_ARR
    b.eq 1f
    cmp w9, #SUBP_SARR
    b.ne 4f                         // SUBP_NUM, SUBP_STR: SUBD_SCALAR
    add x11, x22, #IRM_SARRAYS
    b 2f
1:
    add x11, x22, #IRM_ARRAYS
2:
    cmp w10, #NUM_LETTERS
    b.hs Lbk_su_badparam
    add x11, x11, x10, lsl #4
    ldr w11, [x11, #IRA_DIMS]
    // DIMS 1 / 2 / IRA_DIMS_ANY -> SUBD_LIST / SUBD_TABLE / SUBD_ANY
    mov x2, #SUBD_LIST
    cmp w11, #1
    b.eq 4f
    mov x2, #SUBD_TABLE
    cmp w11, #2
    b.eq 4f
    mov x2, #SUBD_ANY
    cmp w11, #IRA_DIMS_ANY
    b.ne Lbk_su_badparam
4:
    FMT Lbk_su_u
    add x24, x24, #1
    cmp x24, #LIM_SUB_PARAMS
    b.hs 5f
    FMT Lbk_su_sep
    b Lbk_su_pdims
5:
    FMT Lbk_su_nl
    // ---- Lsubt_<u>: the descriptor templates, d(L) order -----------------
    ldr w9, [x25, #4*LAY_NDESC]
    cbz w9, Lbk_su_next
    mov x2, x21
    FMT Lbk_su_t_label
    mov x24, #0
Lbk_su_ntmpl:
    add x9, x25, #4*LAY_NDESC_L
    ldr w9, [x9, x24, lsl #2]
    cmn w9, #1
    b.eq 1f
    add x0, x22, #IRM_ARRAYS
    add x0, x0, x24, lsl #4
    add x1, x25, #4*LAY_NDATA_L
    ldr w1, [x1, x24, lsl #2]
    bl Lbk_su_template
1:
    add x24, x24, #1
    cmp x24, #NUM_LETTERS
    b.lo Lbk_su_ntmpl
    mov x24, #0
Lbk_su_stmpl:
    add x9, x25, #4*LAY_SDESC_L
    ldr w9, [x9, x24, lsl #2]
    cmn w9, #1
    b.eq 1f
    add x0, x22, #IRM_SARRAYS
    add x0, x0, x24, lsl #4
    add x1, x25, #4*LAY_SDATA_L
    ldr w1, [x1, x24, lsl #2]
    bl Lbk_su_template
1:
    add x24, x24, #1
    cmp x24, #NUM_LETTERS
    b.lo Lbk_su_stmpl
Lbk_su_next:
    add x21, x21, #1
    b Lbk_su_unit
Lbk_su_ok:
    mov x0, #0
    b Lbk_su_ret
Lbk_su_badparam:
    adrp x0, Lbk_in_err_param@PAGE
    add x0, x0, Lbk_in_err_param@PAGEOFF
Lbk_su_ret:
    mov sp, x29
    ldp x27, x28, [sp, #80]
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret

// ---------------------------------------------------------------------
// Lbk_su_template -- one RTA template of a Lsubt_ list: ".quad <block
// offset of the elements>" / ".long dims, b1, b2, rowlen, letter, cap"
// (rowlen = b2+1 for a table, 1 for a list; cap = (b1+1)*(b2+1)).
// In:  x0 = IRA entry, x1 = element offset, x19 = OutBuf*, x24 = letter
// Frame: 32 bytes (frame record + saved IRA entry)
// ---------------------------------------------------------------------
    .p2align 2
Lbk_su_template:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x0, [sp, #16]
    mov w2, w1
    ldr w3, [x0, #IRA_DIMS]
    ldr w4, [x0, #IRA_B1]
    ldr w5, [x0, #IRA_B2]
    FMT Lbk_su_t_head
    ldr x9, [sp, #16]
    ldr w10, [x9, #IRA_DIMS]
    ldr w4, [x9, #IRA_B1]
    ldr w5, [x9, #IRA_B2]
    add x4, x4, #1
    add x5, x5, #1
    mov x2, #1                      // rowlen of a list
    cmp w10, #2
    csel x2, x5, x2, eq             // b2 + 1 for a table
    mov x3, x24
    mul x4, x4, x5
    FMT Lbk_su_t_tail
    ldp x29, x30, [sp], #32
    ret

// ======================================================================
// Text templates
// ======================================================================
    .section __TEXT,__cstring,cstring_literals
Lbk_in_name_label:
    .asciz "%s:\n"
Lbk_in_sub_enter_fmt:
    .ascii "    mov x1, x0\n"
    .ascii "    adrp x0, Lsubl_%u@PAGE\n"
    .ascii "    add x0, x0, Lsubl_%u@PAGEOFF\n"
    .ascii "    bl _bsk_sub_enter\n"
    .asciz "    mov x19, x0\n"
Lbk_in_ldr_d0_x16:
    .asciz "    ldr d0, [x16]\n"
Lbk_in_str_d0_x16:
    .asciz "    str d0, [x16]\n"
Lbk_in_add_x19_imm:
    .asciz "    add x%u, x19, #%u\n"
Lbk_in_add_x19_x16:
    .asciz "    add x%u, x19, x16\n"
Lbk_in_vaddr_fmt:
    .asciz "    add x0, x19, #%u\n"
Lbk_in_add_sp_imm:
    .asciz "    add x0, sp, #%u\n"
Lbk_in_add_sp_x16:
    .asciz "    add x0, sp, x16\n"
Lbk_in_bl_sub:
    .asciz "    bl Lsub_%u\n"
Lbk_su_head:
    .ascii "    .p2align 3\n"
    .ascii "Lsubl_%u:\n"
    .asciz "    .long %u, %u, %u, %u\n"
Lbk_su_long4:
    .asciz "    .long %u, %u, %u, %u\n"
Lbk_su_quad_t:
    .asciz "    .quad Lsubt_%u\n"
Lbk_su_quad_0:
    .asciz "    .quad 0\n"
Lbk_su_byte:
    .asciz "    .byte "
Lbk_su_u:
    .asciz "%u"
Lbk_su_sep:
    .asciz ", "
Lbk_su_nl:
    .asciz "\n"
Lbk_su_t_label:
    .asciz "Lsubt_%u:\n"
Lbk_su_t_head:
    .ascii "    .quad %u\n"
    .asciz "    .long %u, %u, %u, "
Lbk_su_t_tail:
    .asciz "%u, %u, %u\n"
// pieces of the label names built by Lbk_in_setup
Lbk_s_lfn:      .asciz "Lfn_"
Lbk_s_lsub:     .asciz "Lsub_"
Lbk_s_fn:       .asciz "_fn_"
Lbk_s_prog:     .asciz "_bsk_program"
Lbk_s_L:        .asciz "_L"
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
    .asciz "    bl %s%L\n"
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
Lbk_in_scell_base:
    .ascii "    adrp x0, _bsk_scells@PAGE\n"
    .asciz "    add x0, x0, _bsk_scells@PAGEOFF\n"
Lbk_in_jeof_fmt:
    .ascii "    cbz w0, 1f\n"
    .ascii "    b %s%u\n"
    .asciz "1:\n"
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
Lbk_in_rt_str_clear: .asciz "_bsk_str_clear"
Lbk_in_rt_str:      .asciz "_bsk_str"
Lbk_in_rt_len:      .asciz "_bsk_len"
Lbk_in_rt_asc:      .asciz "_bsk_asc"
Lbk_in_rt_val:      .asciz "_bsk_val"
Lbk_in_rt_saref2:   .asciz "_bsk_saref2"
Lbk_in_rt_fsel:     .asciz "_bsk_fsel"
Lbk_in_rt_feof:     .asciz "_bsk_feof"
Lbk_in_rt_scratch:  .asciz "_bsk_scratch"
Lbk_in_rt_frestore: .asciz "_bsk_frestore"
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
Lbk_in_rt_linput:   .asciz "_bsk_linput"
Lbk_in_rt_linput_el: .asciz "_bsk_linput_el"
Lbk_in_rt_exit:     .asciz "_bsk_exit"
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
Lbk_in_rt_str_cat: .asciz "_bsk_str_cat"
Lbk_in_rt_seg: .asciz "_bsk_seg"
Lbk_in_rt_pos: .asciz "_bsk_pos"
Lbk_in_rt_sub_leave: .asciz "_bsk_sub_leave"
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
Lbk_in_err_sub:     .asciz "arm64-macos backend: bad SUB unit index"
Lbk_in_err_kind:    .asciz "arm64-macos backend: SUB body outside a SUB unit, or a unit without one"
Lbk_in_err_dims:    .asciz "arm64-macos backend: array with more than 2 dimensions"
Lbk_in_err_big:     .asciz "arm64-macos backend: SUB unit too large"
Lbk_in_err_fncall:  .asciz "arm64-macos backend: bad or recursive FN call in a SUB unit"
Lbk_in_err_param:   .asciz "arm64-macos backend: bad SUB parameter"

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
    .quad 0                         // scell
    .quad Lbk_in_rt_str             // sstr
    .quad Lbk_in_rt_len
    .quad Lbk_in_rt_asc
    .quad Lbk_in_rt_val
    .quad Lbk_in_rt_saref2          // sald2
    .quad 0                         // sparam
    .quad 0                         // sfv
    .quad 0                         // scallfn
    .quad 0                         // sret
    .quad Lbk_in_rt_fsel
    .quad Lbk_in_rt_feof            // jeof
    .quad Lbk_in_rt_scratch
    .quad Lbk_in_rt_frestore
// indexed by relation - REL_EQ: condition that SKIPS the jump
Lbk_in_inverse_cc:
    .quad Lbk_in_cc_ne              // eq -> ne
    .quad Lbk_in_cc_eq              // ne -> eq
    .quad Lbk_in_cc_ge              // lt -> ge
    .quad Lbk_in_cc_gt              // le -> gt
    .quad Lbk_in_cc_le              // gt -> le
    .quad Lbk_in_cc_lt              // ge -> lt

// ---- per-function emission state (ST_*; see the equates at the top) ------
    .zerofill __DATA,__bss,Lbk_st,ST_SIZE,3
