// =====================================================================
// src/backend/x86_64_linux/x64_insn.s -- per-function and per-opcode
// code generation for the x86_64-linux backend (docs/DESIGN.md section
// 5.4.4 "Frames and temps", 5.4.5 "Per-opcode translation" and, Sixth
// Edition, 5.4.6 "SUB units").
//
// This file is arm64 code for Apple as (part of the compiler); the text
// it produces is GNU as AT&T x86_64 assembly.
//
// Exports: _bk_x64_emit_func, _bk_x64_func_shape
// Uses:    _bk_x64_fmt (x64_text.s);
//          _bk_x64_unit_layout, _bk_x64_unit_param, _bk_x64_unit_desc_index
//          (x64_sub.s)
//
// Temp slots: a temp is never read after the next `line` (IR.md 1), so
// slots are reused per line: slot(t) = t - base, base = the first temp
// defined after the most recent `line` (start of function counts as a
// `line`). W = the largest number of temps one such segment needs.
// Temp slot s is "8*s(%rsp)", local cell k "8*(W+k)(%rsp)" (parameters, then
// for a multi-line function the value variable and the saved run-time line),
// global cell x "8*x(%rbx)".
// =====================================================================
.include "baysick.inc"

// W above this would make 8*(W+L+V) + 8 (L <= 10 local cells, V <= 16
// argument-vector slots) overflow a signed 32-bit x86 displacement /
// immediate (the assembler would reject the output).
.equ BK_X64_MAX_W,  0x0FFFFFE0

// Label key of %B (_bk_x64_fmt, x64_text.s builds it the same way): the
// function index in the low 5 bits, SUB unit index + 1 above them.
.equ BK_X64_KEY_UNIT_SHIFT, 5

// _bk_x64_emit_func's frame: the saved registers, then per-function state
// that the file-local helpers read through x26 (= sp after the prologue).
.equ BK_X64_FS_MAIN,     96         // the main Module* (string pool, SUB units)
.equ BK_X64_FS_UNIT,     104        // SUB unit index + 1; 0 in the main module
.equ BK_X64_FS_KEY,      112        // label key of this function (%B)
.equ BK_X64_FS_V,        120        // V: argument-vector slots (DESIGN.md 5.4.4)
.equ BK_X64_FS_L,        128        // L: local cells
.equ BK_X64_FS_PARAMOFF, 136        // unit only: block offset of the parameter pointers
.equ BK_X64_FS_SDOFF,    144        // unit only: block offset of the SD records
.equ BK_X64_FS_DESCOFF,  152        // unit only: block offset of the descriptors
.equ BK_X64_FRAME,       160

// ---------------------------------------------------------------------
// FMT label -- append the format string `label` via _bk_x64_fmt with
// x0 = OutBuf* (x19); arguments must already be in x2..x7.
// Clobbers x0, x1 and everything _bk_x64_fmt clobbers.
// ---------------------------------------------------------------------
.macro FMT label
    mov x0, x19
    adrp x1, \label@PAGE
    add x1, x1, \label@PAGEOFF
    bl _bk_x64_fmt
.endm

// FAIL label -- abort the function emission with reason string `label`.
.macro FAIL label
    adrp x0, \label@PAGE
    add x0, x0, \label@PAGEOFF
    b Lbk_x64_in_fail
.endm

// CALLRT label -- emit "    call <runtime symbol named by label>".
.macro CALLRT label
    adrp x2, \label@PAGE
    add x2, x2, \label@PAGEOFF
    FMT Lbk_x64_in_call_fmt
.endm

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _bk_x64_emit_func -- emit one IR function with prologue, body and (FN)
// epilogue: main as bsk_program, FN letter L as .Lfn_<L>; in a SUB unit u
// (Sixth Edition, DESIGN.md 5.4.6) the SUB body as .Lsub_<u> and FN L of the
// unit as .Lsub_<u>_fn_<L>.
// In:  x0 = OutBuf*, x1 = const Module* the function belongs to (the main
//      module or a SUB unit), x2 = function index (FUNC_MAIN = the SUB body
//      in a unit, or FUNC_FN_BASE + letter); the function must be present;
//      x3 = the main Module* (= x1 for the main module's functions)
// Out: x0 = 0 on success, else pointer to a NUL-terminated reason
// Clobbers: x0-x17, d0-d7, d16-d31
// Callee-saved used (this is also the private state that the file-local
// helpers below read):
//   x19 = OutBuf*            x20 = Module* (main module or SUB unit)
//   x21 = current IRI record x22 = end of the instruction array
//   x23 = W (temp slots)     x24 = base temp of the current segment,
//                                  or -1 before the first definition
//   x25 = function index     x26 = sp right after the prologue
//                                  (unwind point for Lbk_x64_in_fail; the
//                                  BK_X64_FS_* state lies above it)
//   x27 = Function*          x28 = 1 + highest temp defined in the
//                                  current segment (0 if none)
// Frame: BK_X64_FRAME = 160 bytes (frame record + x19-x28 + BK_X64_FS_*)
// ---------------------------------------------------------------------
    .globl _bk_x64_emit_func
    .p2align 2
_bk_x64_emit_func:
    stp x29, x30, [sp, #-BK_X64_FRAME]!
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
    str x3, [x26, #BK_X64_FS_MAIN]
    // unit field: SUB unit index + 1, 0 for the main module's functions
    mov x9, #0
    cmp x1, x3
    b.eq 1f
    ldr w9, [x1, #IRM_UNITIDX]
    add x9, x9, #1
1:
    str x9, [x26, #BK_X64_FS_UNIT]
    // label key = function index + (unit field << 5)
    lsl x10, x9, #BK_X64_KEY_UNIT_SHIFT
    add x10, x10, x25
    str x10, [x26, #BK_X64_FS_KEY]
    // x27 = &funcs[index]
    add x27, x20, #IRM_FUNCS
    mov x9, #IRF_SIZE
    madd x27, x25, x9, x27
    // x21 = first instruction, x22 = one past the last
    ldr x21, [x27, #IRF_INSNS]
    ldr w9, [x27, #IRF_NINSNS]
    add x22, x21, x9, lsl #IRI_SHIFT

    // ---- frame shape: W (temp slots), V (argument vector), L (cells) ----
    mov x0, x20
    ldr x1, [x26, #BK_X64_FS_MAIN]
    mov x2, x25
    bl _bk_x64_func_shape
    cbz x3, 1f
    mov x0, x3
    b Lbk_x64_in_fail
1:
    mov x23, x0
    str x1, [x26, #BK_X64_FS_V]
    str x2, [x26, #BK_X64_FS_L]
    // every displacement must fit a signed 32-bit field
    mov x9, #BK_X64_MAX_W
    cmp x23, x9
    b.hi Lbk_x64_in_bad_frame
    // ---- a SUB unit: the block offsets its operands are addressed by ----
    ldr x9, [x26, #BK_X64_FS_UNIT]
    cbz x9, 1f
    mov x0, x20
    bl _bk_x64_unit_layout
    cbnz x0, Lbk_x64_in_fail
    str x1, [x26, #BK_X64_FS_PARAMOFF]
    str x2, [x26, #BK_X64_FS_SDOFF]
    str x3, [x26, #BK_X64_FS_DESCOFF]
1:

    // ---- function label ------------------------------------------------
    ldr x9, [x26, #BK_X64_FS_UNIT]
    cbnz x9, 3f
    cbnz x25, 1f
    FMT Lbk_x64_in_main_label
    b 2f
1:
    sub x2, x25, #FUNC_FN_BASE
    FMT Lbk_x64_in_fn_label
    b 2f
3:
    // SUB unit u = field - 1: its body, or one of its FN functions
    sub x2, x9, #1
    cbnz x25, 4f
    FMT Lbk_x64_in_sub_label
    b 2f
4:
    sub x3, x25, #FUNC_FN_BASE
    FMT Lbk_x64_in_unit_fn_label
2:
    // ---- prologue: frame, %rbx, temp area, local cells, vector, base ----
    // F = align16(8*(W+L+V) + 8) - 8: %rsp stays 16-byte aligned at calls
    // and the temps, the L local cells and the V argument-vector slots fit
    // (DESIGN.md 5.4.4)
    ldr x0, [x26, #BK_X64_FS_L]
    ldr x1, [x26, #BK_X64_FS_V]
    add x9, x23, x0
    add x9, x9, x1
    lsl x9, x9, #3
    add x9, x9, #8 + 15
    and x9, x9, #~15
    sub x2, x9, #8
    FMT Lbk_x64_in_prologue
    // %rbx: the main module's functions address .Lbsk_vars; a SUB body
    // gets its activation block from bsk_sub_enter; an FN function of a
    // unit keeps the caller's %rbx (the current activation block)
    ldr x9, [x26, #BK_X64_FS_UNIT]
    cbnz x9, 3f
    FMT Lbk_x64_in_rbx_vars
    b 2f
3:
    cbnz x25, 2f
    sub x2, x9, #1
    FMT Lbk_x64_in_sub_enter
2:
    // FN functions spill their arguments, multi-line ones also set up the
    // value variable and save the caller's run-time line
    cbz x25, 1f
    bl Lbk_x64_in_cells_init
1:

    // ---- pass 2: translate every instruction ----------------------------
    mov x24, #-1
    mov x28, #0
Lbk_x64_in_loop:
    cmp x21, x22
    b.hs Lbk_x64_in_ok
    ldrh w9, [x21, #IRI_OP]
    cmp w9, #OP_COUNT
    b.hs Lbk_x64_in_bad_op
    // dispatch through the relative jump table
    adr x10, Lbk_x64_in_table
    ldrsw x11, [x10, x9, lsl #2]
    add x10, x10, x11
    br x10
Lbk_x64_in_next:
    add x21, x21, #IRI_SIZE
    b Lbk_x64_in_loop

Lbk_x64_in_ok:
    mov x0, #0
    b Lbk_x64_in_return
Lbk_x64_in_bad_op:
    FAIL Lbk_x64_in_err_op
Lbk_x64_in_bad_frame:
    FAIL Lbk_x64_in_err_frame
// Lbk_x64_in_fail -- non-local error exit, reachable by a plain branch
// from this function or from any of the file-local helpers below at any
// call depth: x0 = reason; restores sp/x29 to this function's frame.
Lbk_x64_in_fail:
    mov sp, x26
    mov x29, x26
Lbk_x64_in_return:
    ldp x27, x28, [sp, #80]
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #BK_X64_FRAME
    ret

// ======================================================================
// Opcode cases. Entered by `br` from the dispatcher with x21 = record;
// each one ends with `b Lbk_x64_in_next`. Operands are always read
// (Lbk_x64_in_use_off) before the destination is defined
// (Lbk_x64_in_def_off), matching the IR's definition order.
// ======================================================================

Lbk_x64_in_op_nop:
    b Lbk_x64_in_next

Lbk_x64_in_op_line:
    // ".Lbsk_L<id>:" then store the BASIC line number into bsk_curline
    ldr x2, [x26, #BK_X64_FS_KEY]   // label key
    ldr w3, [x21, #IRI_X]
    ldr x4, [x21, #IRI_IMM]
    lsr x9, x4, #32
    cbnz x9, Lbk_x64_in_line_range
    FMT Lbk_x64_in_line_fmt
    // a new temp segment starts here
    mov x24, #-1
    mov x28, #0
    b Lbk_x64_in_next
Lbk_x64_in_line_range:
    FAIL Lbk_x64_in_err_line

Lbk_x64_in_op_label:
    ldr x2, [x26, #BK_X64_FS_KEY]   // label key
    ldr w3, [x21, #IRI_X]
    FMT Lbk_x64_in_label_def
    b Lbk_x64_in_next

Lbk_x64_in_op_const:
    // movabsq $bits, %rax / movq %rax, S(DST)
    ldr w0, [x21, #IRI_DST]
    bl Lbk_x64_in_def_off
    mov x3, x0
    ldr x2, [x21, #IRI_IMM]
    FMT Lbk_x64_in_const_fmt
    b Lbk_x64_in_next

Lbk_x64_in_op_ldv:
    // %xmm0 = global cell X (in a SUB unit, a numeric parameter X reads the
    // caller's double through its pointer P(k)); store
    bl Lbk_x64_in_global_off
    str x0, [sp, #-16]!
    ldr w0, [x21, #IRI_X]
    mov x1, #SUBP_NUM
    bl Lbk_x64_in_param_off
    cmn x0, #1
    b.eq 1f
    add sp, sp, #16
    mov x2, x0
    FMT Lbk_x64_in_ldv_param_fmt
    b Lbk_x64_in_store_dst
1:
    ldr x2, [sp], #16
    FMT Lbk_x64_in_ldv_fmt
    b Lbk_x64_in_store_dst

Lbk_x64_in_op_stv:
    // global cell X = A (in a SUB unit, a numeric parameter X writes the
    // caller's double through its pointer P(k))
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_x64_in_load
    bl Lbk_x64_in_global_off
    str x0, [sp, #-16]!
    ldr w0, [x21, #IRI_X]
    mov x1, #SUBP_NUM
    bl Lbk_x64_in_param_off
    cmn x0, #1
    b.eq 1f
    add sp, sp, #16
    mov x2, x0
    FMT Lbk_x64_in_stv_param_fmt
    b Lbk_x64_in_next
1:
    ldr x2, [sp], #16
    FMT Lbk_x64_in_stv_fmt
    b Lbk_x64_in_next

Lbk_x64_in_op_arith:
    // add/sub/mul: %xmm0 = A op B, inline overflow check, store
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_x64_in_load
    ldr w0, [x21, #IRI_B]
    bl Lbk_x64_in_use_off
    mov x3, x0
    ldrh w9, [x21, #IRI_OP]
    sub w9, w9, #OP_ADD
    adrp x10, Lbk_x64_in_arith_names@PAGE
    add x10, x10, Lbk_x64_in_arith_names@PAGEOFF
    ldr x2, [x10, x9, lsl #3]
    FMT Lbk_x64_in_memop_fmt
    mov x2, #ERR_OVERFLOW
    FMT Lbk_x64_in_ovf_check
    b Lbk_x64_in_store_dst

Lbk_x64_in_op_div:
    bl Lbk_x64_in_load_ab
    CALLRT Lbk_x64_in_rt_div
    b Lbk_x64_in_store_dst

Lbk_x64_in_op_pow:
    bl Lbk_x64_in_load_ab
    CALLRT Lbk_x64_in_rt_pow
    b Lbk_x64_in_store_dst

Lbk_x64_in_op_neg:
    // sign-bit flip through %rax: never errors, keeps -0 distinct
    ldr w0, [x21, #IRI_A]
    bl Lbk_x64_in_use_off
    str x0, [sp, #-16]!
    ldr w0, [x21, #IRI_DST]
    bl Lbk_x64_in_def_off
    mov x3, x0
    ldr x2, [sp], #16
    FMT Lbk_x64_in_neg_fmt
    b Lbk_x64_in_next

Lbk_x64_in_op_builtin:
    // sin..int: %xmm0 = A; call bsk_<name>; store
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_x64_in_load
    ldrh w9, [x21, #IRI_OP]
    sub w9, w9, #OP_SIN
    adrp x10, Lbk_x64_in_builtin_names@PAGE
    add x10, x10, Lbk_x64_in_builtin_names@PAGEOFF
    ldr x2, [x10, x9, lsl #3]
    FMT Lbk_x64_in_call_fmt
    b Lbk_x64_in_store_dst

Lbk_x64_in_op_rnd:
    CALLRT Lbk_x64_in_rt_rnd
    b Lbk_x64_in_store_dst

Lbk_x64_in_op_ald1:
    // %rdi = &.Ldesc_<L>; %xmm0 = A; %rax = bsk_aref1; %xmm0 = (%rax)
    bl Lbk_x64_in_desc_addr
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_x64_in_load
    CALLRT Lbk_x64_in_rt_aref1
    FMT Lbk_x64_in_ld_elem
    b Lbk_x64_in_store_dst

Lbk_x64_in_op_ald2:
    bl Lbk_x64_in_desc_addr
    bl Lbk_x64_in_load_ab
    CALLRT Lbk_x64_in_rt_aref2
    FMT Lbk_x64_in_ld_elem
    b Lbk_x64_in_store_dst

Lbk_x64_in_op_ast1:
    // %rax = element address of A; %xmm0 = B; (%rax) = %xmm0
    bl Lbk_x64_in_desc_addr
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_x64_in_load
    CALLRT Lbk_x64_in_rt_aref1
    ldr w0, [x21, #IRI_B]
    mov x1, #0
    bl Lbk_x64_in_load
    FMT Lbk_x64_in_st_elem
    b Lbk_x64_in_next

Lbk_x64_in_op_ast2:
    // %rax = element address of (A, B); %xmm0 = C; (%rax) = %xmm0
    bl Lbk_x64_in_desc_addr
    bl Lbk_x64_in_load_ab
    CALLRT Lbk_x64_in_rt_aref2
    ldr w0, [x21, #IRI_C]
    mov x1, #0
    bl Lbk_x64_in_load
    FMT Lbk_x64_in_st_elem
    b Lbk_x64_in_next

Lbk_x64_in_op_callfn:
    // %xmm0 = A (nothing for a call without arguments); call .Lfn_<L>; store
    ldr w0, [x21, #IRI_A]
    cmn w0, #1                      // IR_NONE: no first argument
    b.eq 1f
    bl Lbk_x64_in_load_arg0
1:
    ldr w2, [x21, #IRI_X]
    cmp w2, #NUM_LETTERS
    b.hs Lbk_x64_in_bad_letter
    bl Lbk_x64_in_emit_callfn
    b Lbk_x64_in_store_dst

Lbk_x64_in_op_param:
    // %xmm0 = parameter k (local cell k)
    cbz x25, Lbk_x64_in_bad_place
    // parameter k lives in local cell k; k must name a parameter
    bl Lbk_x64_in_nparams
    ldr x1, [x21, #IRI_IMM]
    cmp x1, x0
    b.hs Lbk_x64_in_bad_param
    add x2, x23, x1
    lsl x2, x2, #3
    FMT Lbk_x64_in_ld_rsp
    b Lbk_x64_in_store_dst

Lbk_x64_in_op_ret:
    // %xmm0 = A, then the epilogue
    cbz x25, Lbk_x64_in_bad_place
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_x64_in_load
    // a multi-line function restores the caller's run-time line first
    ldr w9, [x27, #IRF_KIND]
    cmp w9, #FUNC_KIND_FNML
    b.ne 1f
    mov x0, #1
    bl Lbk_x64_in_cell_np
    lsl x2, x0, #3
    FMT Lbk_x64_in_ret_line
1:
    FMT Lbk_x64_in_epilogue
    b Lbk_x64_in_next

Lbk_x64_in_op_jmp:
    ldr x2, [x26, #BK_X64_FS_KEY]   // label key
    ldr w3, [x21, #IRI_X]
    FMT Lbk_x64_in_jmp_label
    b Lbk_x64_in_next

Lbk_x64_in_op_jcmp:
    // ucomisd B, %xmm0 (A); unsigned condition jumps straight to X
    ldrh w9, [x21, #IRI_REL]
    sub w9, w9, #REL_EQ
    cmp w9, #REL_GE - REL_EQ
    b.hi Lbk_x64_in_bad_rel
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_x64_in_load
    ldr w0, [x21, #IRI_B]
    bl Lbk_x64_in_use_off
    mov x3, x0
    adrp x2, Lbk_x64_in_ucomisd@PAGE
    add x2, x2, Lbk_x64_in_ucomisd@PAGEOFF
    FMT Lbk_x64_in_memop_fmt
    adrp x10, Lbk_x64_in_jcc_names@PAGE
    add x10, x10, Lbk_x64_in_jcc_names@PAGEOFF

// common tail of jcmp / sjcmp: x10 = table of condition mnemonics indexed
// by relation - REL_EQ; emits "    j<cc> <label base><X>"
Lbk_x64_in_jcc_emit:
    ldrh w9, [x21, #IRI_REL]
    sub w9, w9, #REL_EQ
    ldr x2, [x10, x9, lsl #3]
    ldr x3, [x26, #BK_X64_FS_KEY]   // label key
    ldr w4, [x21, #IRI_X]
    FMT Lbk_x64_in_jcc_fmt
    b Lbk_x64_in_next

Lbk_x64_in_op_jfor:
    // v = A, l = B, s = C; jump to X if the loop is exhausted
    ldr w0, [x21, #IRI_A]
    bl Lbk_x64_in_use_off
    str x0, [sp, #-16]!
    ldr w0, [x21, #IRI_B]
    bl Lbk_x64_in_use_off
    str x0, [sp, #8]
    ldr w0, [x21, #IRI_C]
    bl Lbk_x64_in_use_off
    mov x4, x0
    ldp x2, x3, [sp], #16
    FMT Lbk_x64_in_jfor_fmt1
    // second half: both exits branch to the loop-exit label X
    ldr x2, [x26, #BK_X64_FS_KEY]   // label key
    ldr w3, [x21, #IRI_X]
    ldr x4, [x26, #BK_X64_FS_KEY]   // label key
    mov x5, x3
    FMT Lbk_x64_in_jfor_fmt2
    b Lbk_x64_in_next

Lbk_x64_in_op_gosub:
    // push the address of the return label, jump to the target (labels of
    // the current function: main or, Sixth Edition, a SUB body)
    ldr x3, [x21, #IRI_IMM]
    lsr x9, x3, #32
    cbnz x9, Lbk_x64_in_bad_label
    ldr w5, [x21, #IRI_X]
    ldr x2, [x26, #BK_X64_FS_KEY]   // label key
    mov x4, x2
    FMT Lbk_x64_in_gosub_fmt
    b Lbk_x64_in_next

Lbk_x64_in_op_return:
    FMT Lbk_x64_in_return_fmt
    b Lbk_x64_in_next

Lbk_x64_in_op_read:
    CALLRT Lbk_x64_in_rt_read
    b Lbk_x64_in_store_dst

Lbk_x64_in_op_prnum:
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_x64_in_load
    CALLRT Lbk_x64_in_rt_prnum
    b Lbk_x64_in_next

Lbk_x64_in_op_prstr:
    // %rdi = &.Lstr_<id>, %esi = length, call bsk_print_str
    ldr w2, [x21, #IRI_X]
    ldr x11, [x26, #BK_X64_FS_MAIN]  // the string pool is the main module's
    ldr w9, [x11, #IRM_NSTRINGS]
    cmp w2, w9
    b.hs Lbk_x64_in_bad_string
    ldr x10, [x11, #IRM_STRINGS]
    add x10, x10, x2, lsl #4
    ldr w3, [x10, #IRS_LEN]
    FMT Lbk_x64_in_prstr_fmt
    b Lbk_x64_in_next

Lbk_x64_in_op_prcomma:
    CALLRT Lbk_x64_in_rt_prcomma
    b Lbk_x64_in_next

Lbk_x64_in_op_prsemi:
    CALLRT Lbk_x64_in_rt_prsemi
    b Lbk_x64_in_next

Lbk_x64_in_op_prnl:
    CALLRT Lbk_x64_in_rt_prnl
    b Lbk_x64_in_next

Lbk_x64_in_op_end:
    // END and STOP: normal termination
    CALLRT Lbk_x64_in_rt_end
    b Lbk_x64_in_next

// ---- MAT statements (DESIGN.md 5.4.5): array letters in X / A / B --------
Lbk_x64_in_op_matredim:
    // %rdi = &.Ldesc_<X>; %xmm0 = A; with B: %xmm1 = B, bsk_mat_redim2,
    // else bsk_mat_redim1
    bl Lbk_x64_in_desc_addr
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_x64_in_load
    ldr w0, [x21, #IRI_B]
    cmn w0, #1                      // IR_NONE: a column vector
    b.eq 1f
    mov x1, #1
    bl Lbk_x64_in_load
    CALLRT Lbk_x64_in_rt_mat_redim2
    b Lbk_x64_in_next
1:
    CALLRT Lbk_x64_in_rt_mat_redim1
    b Lbk_x64_in_next

Lbk_x64_in_op_mat1:
    // READ / ZER / CON / IDN: %rdi = &.Ldesc_<X>; call bsk_mat_<op>
    bl Lbk_x64_in_desc_addr
    bl Lbk_x64_in_mat_call
    b Lbk_x64_in_next

Lbk_x64_in_op_matprint:
    // %rdi = &.Ldesc_<X>; %esi = IMM (MATPR_*); call bsk_mat_print
    bl Lbk_x64_in_desc_addr
    ldr x2, [x21, #IRI_IMM]
    cmp x2, #MATPR_PACKED
    b.hi Lbk_x64_in_bad_mode
    FMT Lbk_x64_in_matprint_fmt
    b Lbk_x64_in_next

Lbk_x64_in_op_mat2:
    // COPY / TRN / INV: %rdi = &.Ldesc_<X>, %rsi = &.Ldesc_<A>
    bl Lbk_x64_in_desc_addr
    ldr w0, [x21, #IRI_A]
    adrp x1, Lbk_x64_in_reg_rsi@PAGE
    add x1, x1, Lbk_x64_in_reg_rsi@PAGEOFF
    bl Lbk_x64_in_desc_reg
    bl Lbk_x64_in_mat_call
    b Lbk_x64_in_next

Lbk_x64_in_op_mat3:
    // ADD / SUB / MUL: %rdi = X, %rsi = A, %rdx = B
    bl Lbk_x64_in_desc_addr
    ldr w0, [x21, #IRI_A]
    adrp x1, Lbk_x64_in_reg_rsi@PAGE
    add x1, x1, Lbk_x64_in_reg_rsi@PAGEOFF
    bl Lbk_x64_in_desc_reg
    ldr w0, [x21, #IRI_B]
    adrp x1, Lbk_x64_in_reg_rdx@PAGE
    add x1, x1, Lbk_x64_in_reg_rdx@PAGEOFF
    bl Lbk_x64_in_desc_reg
    bl Lbk_x64_in_mat_call
    b Lbk_x64_in_next

Lbk_x64_in_op_matscale:
    // %rdi = &.Ldesc_<X>, %rsi = &.Ldesc_<B>, %xmm0 = temp A
    bl Lbk_x64_in_desc_addr
    ldr w0, [x21, #IRI_B]
    adrp x1, Lbk_x64_in_reg_rsi@PAGE
    add x1, x1, Lbk_x64_in_reg_rsi@PAGEOFF
    bl Lbk_x64_in_desc_reg
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_x64_in_load
    bl Lbk_x64_in_mat_call
    b Lbk_x64_in_next

// ---- Third and Fourth Edition opcodes (DESIGN.md 5.4.5) ----------------------
Lbk_x64_in_op_slit:
    // %rax = &.Lsd_<id>; store
    ldr w2, [x21, #IRI_X]
    ldr x11, [x26, #BK_X64_FS_MAIN]  // the string pool is the main module's
    ldr w9, [x11, #IRM_NSTRINGS]
    cmp w2, w9
    b.hs Lbk_x64_in_bad_string
    FMT Lbk_x64_in_slit_fmt
    b Lbk_x64_in_store_dst_rax

Lbk_x64_in_op_svar:
    // %rax = &.Lbsk_svars + 16*slot; store. In a SUB unit: a string
    // parameter is the caller's SD record (pointer P(k)), any other string
    // variable lies at SDOFF + 16*slot in the activation block
    ldr w9, [x21, #IRI_X]
    cmp w9, #(NUM_LETTERS * SLOT_PER_LETTER)
    b.hs Lbk_x64_in_bad_slot
    mov w0, w9
    mov x1, #SUBP_STR
    bl Lbk_x64_in_param_off
    cmn x0, #1
    b.eq 1f
    mov x2, x0
    FMT Lbk_x64_in_movq_rbx_rax
    b Lbk_x64_in_store_dst_rax
1:
    ldr w9, [x21, #IRI_X]
    mov x10, #SD_SIZE
    mul x2, x9, x10
    ldr x9, [x26, #BK_X64_FS_UNIT]
    cbnz x9, 2f
    FMT Lbk_x64_in_svar_fmt
    b Lbk_x64_in_store_dst_rax
2:
    ldr x9, [x26, #BK_X64_FS_SDOFF]
    add x2, x2, x9
    adrp x3, Lbk_x64_in_reg_rax@PAGE
    add x3, x3, Lbk_x64_in_reg_rax@PAGEOFF
    FMT Lbk_x64_in_leaq_rbx_reg
    b Lbk_x64_in_store_dst_rax

Lbk_x64_in_op_sald1:
    // %rdi = &.Lsdesc_<L>; %xmm0 = A; %rax = bsk_saref1; store
    bl Lbk_x64_in_sdesc_addr
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_x64_in_load
    CALLRT Lbk_x64_in_rt_saref1
    b Lbk_x64_in_store_dst_rax

Lbk_x64_in_op_sset:
    // %rdi = A, %rsi = B; call bsk_str_set
    bl Lbk_x64_in_load_sab
    CALLRT Lbk_x64_in_rt_str_set
    b Lbk_x64_in_next

Lbk_x64_in_op_sjcmp:
    // %rdi = A, %rsi = B; bsk_str_cmp; cmpl $0, %eax; signed j<cc> X
    ldrh w9, [x21, #IRI_REL]
    sub w9, w9, #REL_EQ
    cmp w9, #REL_GE - REL_EQ
    b.hi Lbk_x64_in_bad_rel
    bl Lbk_x64_in_load_sab
    CALLRT Lbk_x64_in_rt_str_cmp
    FMT Lbk_x64_in_cmp0_fmt
    adrp x10, Lbk_x64_in_sjcc_names@PAGE
    add x10, x10, Lbk_x64_in_sjcc_names@PAGEOFF
    b Lbk_x64_in_jcc_emit

Lbk_x64_in_op_prsv:
    adrp x2, Lbk_x64_in_rt_print_sv@PAGE
    add x2, x2, Lbk_x64_in_rt_print_sv@PAGEOFF
    b Lbk_x64_in_sunary

Lbk_x64_in_op_sread:
    // plain form: %rdi = A; call bsk_sread. Element form (A = IR_NONE):
    // call bsk_sread_el (Lbk_x64_in_selem)
    ldr w9, [x21, #IRI_A]
    cmn w9, #1
    b.ne 1f
    adrp x2, Lbk_x64_in_rt_sread_el@PAGE
    add x2, x2, Lbk_x64_in_rt_sread_el@PAGEOFF
    b Lbk_x64_in_selem
1:
    adrp x2, Lbk_x64_in_rt_sread@PAGE
    add x2, x2, Lbk_x64_in_rt_sread@PAGEOFF
    b Lbk_x64_in_sunary

Lbk_x64_in_op_insv:
    // plain form: %rdi = A; call bsk_input_str. Element form
    // (A = IR_NONE): call bsk_input_str_el (Lbk_x64_in_selem)
    ldr w9, [x21, #IRI_A]
    cmn w9, #1
    b.ne 1f
    adrp x2, Lbk_x64_in_rt_input_str_el@PAGE
    add x2, x2, Lbk_x64_in_rt_input_str_el@PAGEOFF
    b Lbk_x64_in_selem
1:
    adrp x2, Lbk_x64_in_rt_input_str@PAGE
    add x2, x2, Lbk_x64_in_rt_input_str@PAGEOFF
    b Lbk_x64_in_sunary

Lbk_x64_in_op_linput:
    // Baysick extension, plain form: %rdi = A; call bsk_linput. Element
    // form (A = IR_NONE): %rdi = &.Lsdesc_<X> (or the SUB unit's addressing,
    // Lbk_x64_in_sdesc_addr), %xmm0 = B; call bsk_linput_el
    ldr w9, [x21, #IRI_A]
    cmn w9, #1
    b.ne 1f
    adrp x2, Lbk_x64_in_rt_linput_el@PAGE
    add x2, x2, Lbk_x64_in_rt_linput_el@PAGEOFF
    b Lbk_x64_in_selem
1:
    adrp x2, Lbk_x64_in_rt_linput@PAGE
    add x2, x2, Lbk_x64_in_rt_linput@PAGEOFF
    b Lbk_x64_in_sunary

Lbk_x64_in_op_exit:
    // Baysick extension: %xmm0 = A (the status); call bsk_exit (no return)
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_x64_in_load
    CALLRT Lbk_x64_in_rt_exit
    b Lbk_x64_in_next

// common tail of the element form of sread / insv / linput: x2 = runtime symbol;
// %rdi = &.Lsdesc_<X>, %xmm0 = B (the subscript); call
Lbk_x64_in_selem:
    str x2, [sp, #-16]!
    bl Lbk_x64_in_sdesc_addr
    ldr w0, [x21, #IRI_B]
    mov x1, #0
    bl Lbk_x64_in_load
    ldr x2, [sp], #16
    FMT Lbk_x64_in_call_fmt
    b Lbk_x64_in_next

// common tail of prsv / sread / insv / linput: x2 = runtime symbol; %rdi = A; call
Lbk_x64_in_sunary:
    str x2, [sp, #-16]!
    ldr w0, [x21, #IRI_A]
    adrp x1, Lbk_x64_in_reg_rdi@PAGE
    add x1, x1, Lbk_x64_in_reg_rdi@PAGEOFF
    bl Lbk_x64_in_loadq
    ldr x2, [sp], #16
    FMT Lbk_x64_in_call_fmt
    b Lbk_x64_in_next

Lbk_x64_in_op_prtab:
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_x64_in_load
    CALLRT Lbk_x64_in_rt_print_tab
    b Lbk_x64_in_next

Lbk_x64_in_op_inbeg:
    CALLRT Lbk_x64_in_rt_input_begin
    b Lbk_x64_in_next

Lbk_x64_in_op_inend:
    CALLRT Lbk_x64_in_rt_input_end
    b Lbk_x64_in_next

Lbk_x64_in_op_randomize:
    CALLRT Lbk_x64_in_rt_randomize
    b Lbk_x64_in_next

Lbk_x64_in_op_innum:
    CALLRT Lbk_x64_in_rt_input_num
    b Lbk_x64_in_store_dst

Lbk_x64_in_op_num:
    CALLRT Lbk_x64_in_rt_num
    b Lbk_x64_in_store_dst

Lbk_x64_in_op_det:
    CALLRT Lbk_x64_in_rt_det
    b Lbk_x64_in_store_dst

Lbk_x64_in_op_sgncot:
    // sgn / cot: %xmm0 = A; call bsk_sgn | bsk_cot; store
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_x64_in_load
    ldrh w9, [x21, #IRI_OP]
    sub w9, w9, #OP_SGN
    adrp x10, Lbk_x64_in_sgn_names@PAGE
    add x10, x10, Lbk_x64_in_sgn_names@PAGEOFF
    ldr x2, [x10, x9, lsl #3]
    FMT Lbk_x64_in_call_fmt
    b Lbk_x64_in_store_dst

Lbk_x64_in_op_matinput:
    bl Lbk_x64_in_desc_addr
    CALLRT Lbk_x64_in_rt_mat_input
    b Lbk_x64_in_next

Lbk_x64_in_op_smatinput:
    bl Lbk_x64_in_sdesc_addr
    CALLRT Lbk_x64_in_rt_smat_input
    b Lbk_x64_in_next

Lbk_x64_in_op_smatread:
    bl Lbk_x64_in_sdesc_addr
    CALLRT Lbk_x64_in_rt_smat_read
    b Lbk_x64_in_next

Lbk_x64_in_op_smatredim:
    // %rdi = &.Lsdesc_<X>; %xmm0 = A; call bsk_mat_redim1
    bl Lbk_x64_in_sdesc_addr
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_x64_in_load
    ldr w0, [x21, #IRI_B]
    cmn w0, #1                      // IR_NONE: a list
    b.eq 1f
    mov x1, #1
    bl Lbk_x64_in_load
    CALLRT Lbk_x64_in_rt_mat_redim2
    b Lbk_x64_in_next
1:
    CALLRT Lbk_x64_in_rt_mat_redim1
    b Lbk_x64_in_next

Lbk_x64_in_op_smatprint:
    // %rdi = &.Lsdesc_<X>; %esi = IMM (MATPR_*); call bsk_smat_print
    bl Lbk_x64_in_sdesc_addr
    ldr x2, [x21, #IRI_IMM]
    cmp x2, #MATPR_PACKED
    b.hi Lbk_x64_in_bad_mode
    FMT Lbk_x64_in_smatprint_fmt
    b Lbk_x64_in_next

Lbk_x64_in_op_chgs2n:
    // %rdi = &.Ldesc_<X>; %rsi = A; call bsk_change_s2n
    bl Lbk_x64_in_desc_addr
    ldr w0, [x21, #IRI_A]
    adrp x1, Lbk_x64_in_reg_rsi@PAGE
    add x1, x1, Lbk_x64_in_reg_rsi@PAGEOFF
    bl Lbk_x64_in_loadq
    CALLRT Lbk_x64_in_rt_change_s2n
    b Lbk_x64_in_next

Lbk_x64_in_op_chgn2s:
    // %rdi = A; %rsi = &.Ldesc_<X>; call bsk_change_n2s. Element form
    // (A = IR_NONE): %rdi = &.Lsdesc_<IMM>; %xmm0 = B; %rsi =
    // &.Ldesc_<X>; call bsk_change_n2s_el
    ldr w9, [x21, #IRI_A]
    cmn w9, #1
    b.ne 1f
    ldr x2, [x21, #IRI_IMM]
    lsr x9, x2, #32
    cbnz x9, Lbk_x64_in_bad_imm     // the letter is the low word only
    bl Lbk_x64_in_sdesc_letter
    ldr w0, [x21, #IRI_B]
    mov x1, #0
    bl Lbk_x64_in_load
    ldr w0, [x21, #IRI_X]
    adrp x1, Lbk_x64_in_reg_rsi@PAGE
    add x1, x1, Lbk_x64_in_reg_rsi@PAGEOFF
    bl Lbk_x64_in_desc_reg
    CALLRT Lbk_x64_in_rt_change_n2s_el
    b Lbk_x64_in_next
1:
    ldr w0, [x21, #IRI_A]
    adrp x1, Lbk_x64_in_reg_rdi@PAGE
    add x1, x1, Lbk_x64_in_reg_rdi@PAGEOFF
    bl Lbk_x64_in_loadq
    ldr w0, [x21, #IRI_X]
    adrp x1, Lbk_x64_in_reg_rsi@PAGE
    add x1, x1, Lbk_x64_in_reg_rsi@PAGEOFF
    bl Lbk_x64_in_desc_reg
    CALLRT Lbk_x64_in_rt_change_n2s
    b Lbk_x64_in_next

Lbk_x64_in_op_onsel:
    // %xmm0 = A; %edi = N; call bsk_on; store
    ldr x2, [x21, #IRI_IMM]
    lsr x9, x2, #32
    cbnz x9, Lbk_x64_in_bad_imm
    cbz x2, Lbk_x64_in_bad_imm
    str x2, [sp, #-16]!
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_x64_in_load
    ldr x2, [sp], #16
    FMT Lbk_x64_in_onsel_fmt
    b Lbk_x64_in_store_dst

Lbk_x64_in_op_restore:
    // %edi = RESTORE_*; call bsk_restore
    ldr x2, [x21, #IRI_IMM]
    cmp x2, #RESTORE_STR
    b.hi Lbk_x64_in_bad_imm
    FMT Lbk_x64_in_restore_fmt
    b Lbk_x64_in_next

Lbk_x64_in_op_fnarg:
    // argument k (1..7) of the callfn that follows goes to %xmm<k>
    ldr x1, [x21, #IRI_IMM]
    sub x9, x1, #1
    cmp x9, #6
    b.hi Lbk_x64_in_bad_imm
    mov x12, x1
    bl Lbk_x64_in_callee_fnk
    lsr w9, w0, w12
    ldr w0, [x21, #IRI_A]
    mov x1, x12
    tbz w9, #0, 1f
    // string parameter k: the sref goes to R(k)
    adrp x10, Lbk_x64_in_argregs@PAGE
    add x10, x10, Lbk_x64_in_argregs@PAGEOFF
    ldr x1, [x10, x12, lsl #3]
    bl Lbk_x64_in_loadq
    b Lbk_x64_in_next
1:
    bl Lbk_x64_in_load
    b Lbk_x64_in_next

Lbk_x64_in_op_stparam:
    // parameter k := A (multi-line function)
    bl Lbk_x64_in_need_ml
    bl Lbk_x64_in_nparams
    ldr x1, [x21, #IRI_IMM]
    cmp x1, x0
    b.hs Lbk_x64_in_bad_param
    ldr w0, [x21, #IRI_A]
    mov x2, x1
    str x2, [sp, #-16]!
    mov x1, #0
    bl Lbk_x64_in_load
    ldr x1, [sp], #16
    add x2, x23, x1
    lsl x2, x2, #3
    FMT Lbk_x64_in_st_cell_fmt
    b Lbk_x64_in_next

Lbk_x64_in_op_ldfv:
    // %xmm0 = the value variable (local cell NP); store
    bl Lbk_x64_in_need_ml
    mov x0, #0
    bl Lbk_x64_in_cell_np
    lsl x2, x0, #3
    FMT Lbk_x64_in_ld_cell_fmt
    b Lbk_x64_in_store_dst

Lbk_x64_in_op_stfv:
    // the value variable := A
    bl Lbk_x64_in_need_ml
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_x64_in_load
    mov x0, #0
    bl Lbk_x64_in_cell_np
    lsl x2, x0, #3
    FMT Lbk_x64_in_st_cell_fmt
    b Lbk_x64_in_next

// ---- Fifth Edition opcodes (DESIGN.md 5.4.5) ---------------------------------
Lbk_x64_in_op_scell:
    // %rax = &.Lbsk_scells + 16*X (in a SUB unit: its cell X in the
    // activation block); store
    ldr w0, [x21, #IRI_X]
    ldr w10, [x20, #IRM_NSTEMPS]
    cmp w0, w10
    b.hs Lbk_x64_in_bad_slot
    adrp x1, Lbk_x64_in_reg_rax@PAGE
    add x1, x1, Lbk_x64_in_reg_rax@PAGEOFF
    bl Lbk_x64_in_cell_reg
    b Lbk_x64_in_store_dst_rax

Lbk_x64_in_op_sstr:
    // %rdi = A (the destination sref); %xmm0 = B; call bsk_str
    ldr w0, [x21, #IRI_A]
    adrp x1, Lbk_x64_in_reg_rdi@PAGE
    add x1, x1, Lbk_x64_in_reg_rdi@PAGEOFF
    bl Lbk_x64_in_loadq
    ldr w0, [x21, #IRI_B]
    mov x1, #0
    bl Lbk_x64_in_load
    CALLRT Lbk_x64_in_rt_str
    b Lbk_x64_in_next

Lbk_x64_in_op_slen:
    // len / asc / val: %rdi = A; call bsk_len | bsk_asc | bsk_val; store
    ldr w0, [x21, #IRI_A]
    adrp x1, Lbk_x64_in_reg_rdi@PAGE
    add x1, x1, Lbk_x64_in_reg_rdi@PAGEOFF
    bl Lbk_x64_in_loadq
    ldrh w9, [x21, #IRI_OP]
    sub w9, w9, #OP_LEN
    adrp x10, Lbk_x64_in_len_names@PAGE
    add x10, x10, Lbk_x64_in_len_names@PAGEOFF
    ldr x2, [x10, x9, lsl #3]
    FMT Lbk_x64_in_call_fmt
    b Lbk_x64_in_store_dst

Lbk_x64_in_op_sald2:
    // %rdi = &.Lsdesc_<X>; %xmm0 = A; %xmm1 = B; %rax = bsk_saref2; store
    bl Lbk_x64_in_sdesc_addr
    bl Lbk_x64_in_load_ab
    CALLRT Lbk_x64_in_rt_saref2
    b Lbk_x64_in_store_dst_rax

Lbk_x64_in_op_sparam:
    // %rax = string parameter k (local cell k); store
    cbz x25, Lbk_x64_in_bad_place
    bl Lbk_x64_in_nparams
    ldr x1, [x21, #IRI_IMM]
    cmp x1, x0
    b.hs Lbk_x64_in_bad_param
    add x2, x23, x1
    lsl x2, x2, #3
    FMT Lbk_x64_in_ld_rax_cell
    b Lbk_x64_in_store_dst_rax

Lbk_x64_in_op_sfv:
    // %rax = the result descriptor (local cell NP) of a multi-line string FN
    bl Lbk_x64_in_need_ml
    mov x0, #0
    bl Lbk_x64_in_cell_np
    lsl x2, x0, #3
    FMT Lbk_x64_in_ld_rax_cell
    b Lbk_x64_in_store_dst_rax

Lbk_x64_in_op_scallfn:
    // first argument A (nothing if IR_NONE) by the callee's parameter 0 kind;
    // %rax = B (the result sref); call .Lfn_<X>; nothing is stored
    ldr w0, [x21, #IRI_A]
    cmn w0, #1
    b.eq 1f
    bl Lbk_x64_in_load_arg0
1:
    ldr w0, [x21, #IRI_B]
    adrp x1, Lbk_x64_in_reg_rax@PAGE
    add x1, x1, Lbk_x64_in_reg_rax@PAGEOFF
    bl Lbk_x64_in_loadq
    ldr w2, [x21, #IRI_X]
    cmp w2, #NUM_LETTERS
    b.hs Lbk_x64_in_bad_letter
    bl Lbk_x64_in_emit_callfn
    b Lbk_x64_in_next

Lbk_x64_in_op_sret:
    // bsk_str_set(result descriptor, A); a multi-line function restores the
    // caller's run-time line; epilogue
    cbz x25, Lbk_x64_in_bad_place
    mov x0, x25
    bl Lbk_x64_in_fnk
    tbz w0, #8, Lbk_x64_in_bad_kind     // FNK_STRING
    bl Lbk_x64_in_nparams
    lsl x2, x0, #3
    add x2, x2, x23, lsl #3
    adrp x3, Lbk_x64_in_reg_rdi@PAGE
    add x3, x3, Lbk_x64_in_reg_rdi@PAGEOFF
    FMT Lbk_x64_in_movq_ld
    ldr w0, [x21, #IRI_A]
    adrp x1, Lbk_x64_in_reg_rsi@PAGE
    add x1, x1, Lbk_x64_in_reg_rsi@PAGEOFF
    bl Lbk_x64_in_loadq
    CALLRT Lbk_x64_in_rt_str_set
    ldr w9, [x27, #IRF_KIND]
    cmp w9, #FUNC_KIND_FNML
    b.ne 1f
    mov x0, #1
    bl Lbk_x64_in_cell_np
    lsl x2, x0, #3
    FMT Lbk_x64_in_ret_line
1:
    FMT Lbk_x64_in_epilogue
    b Lbk_x64_in_next

Lbk_x64_in_op_fsel:
    // %xmm0 = A; call bsk_fsel
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_x64_in_load
    CALLRT Lbk_x64_in_rt_fsel
    b Lbk_x64_in_next

Lbk_x64_in_op_jeof:
    // %xmm0 = A; call bsk_feof; testl %eax, %eax; jne X
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_x64_in_load
    CALLRT Lbk_x64_in_rt_feof
    ldr x2, [x26, #BK_X64_FS_KEY]   // label key
    ldr w3, [x21, #IRI_X]
    FMT Lbk_x64_in_jeof_fmt
    b Lbk_x64_in_next

Lbk_x64_in_op_fileop:
    // scratch / frestore: %xmm0 = A; call bsk_scratch | bsk_frestore
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_x64_in_load
    ldrh w9, [x21, #IRI_OP]
    sub w9, w9, #OP_SCRATCH
    adrp x10, Lbk_x64_in_file_names@PAGE
    add x10, x10, Lbk_x64_in_file_names@PAGEOFF
    ldr x2, [x10, x9, lsl #3]
    FMT Lbk_x64_in_call_fmt
    b Lbk_x64_in_next

// ---- Sixth Edition opcodes (DESIGN.md 5.4.5; in a SUB unit 5.4.6) ----------
Lbk_x64_in_op_scat:
    // %rdi = A (destination sref), %rsi = B; call bsk_str_cat
    bl Lbk_x64_in_load_sab
    CALLRT Lbk_x64_in_rt_str_cat
    b Lbk_x64_in_next

Lbk_x64_in_op_sseg:
    // %rdi = &cell X; DST := %rdi; %rsi = A; %xmm0 = B; %xmm1 = C; bsk_seg
    ldr w9, [x21, #IRI_X]
    ldr w10, [x20, #IRM_NSTEMPS]
    cmp w9, w10
    b.hs Lbk_x64_in_bad_slot
    // the operands A, B, C are read before DST is defined
    sub sp, sp, #32
    ldr w0, [x21, #IRI_A]
    bl Lbk_x64_in_use_off
    str x0, [sp]
    ldr w0, [x21, #IRI_B]
    bl Lbk_x64_in_use_off
    str x0, [sp, #8]
    ldr w0, [x21, #IRI_C]
    bl Lbk_x64_in_use_off
    str x0, [sp, #16]
    ldr w0, [x21, #IRI_DST]
    bl Lbk_x64_in_def_off
    str x0, [sp, #24]
    // the cell's address, kept as the result reference
    ldr w0, [x21, #IRI_X]
    adrp x1, Lbk_x64_in_reg_rdi@PAGE
    add x1, x1, Lbk_x64_in_reg_rdi@PAGEOFF
    bl Lbk_x64_in_cell_reg
    ldr x2, [sp, #24]
    FMT Lbk_x64_in_st_rdi_fmt
    ldr x2, [sp]
    ldr x3, [sp, #8]
    ldr x4, [sp, #16]
    FMT Lbk_x64_in_sseg_fmt
    add sp, sp, #32
    b Lbk_x64_in_next

Lbk_x64_in_op_pos:
    // %rdi = A, %rsi = B, %xmm0 = C; call bsk_pos; store
    bl Lbk_x64_in_load_sab
    ldr w0, [x21, #IRI_C]
    mov x1, #0
    bl Lbk_x64_in_load
    CALLRT Lbk_x64_in_rt_pos
    b Lbk_x64_in_store_dst

Lbk_x64_in_op_vaddr:
    // %rax = &V(X) (in a SUB unit, a numeric parameter's pointer P(k)); store
    ldr w9, [x21, #IRI_X]
    cmp w9, #(NUM_LETTERS * SLOT_PER_LETTER)
    b.hs Lbk_x64_in_bad_slot
    mov w0, w9
    mov x1, #SUBP_NUM
    bl Lbk_x64_in_param_off
    cmn x0, #1
    b.eq 1f
    mov x2, x0
    FMT Lbk_x64_in_movq_rbx_rax
    b Lbk_x64_in_store_dst_rax
1:
    ldr w9, [x21, #IRI_X]
    lsl x2, x9, #3
    adrp x3, Lbk_x64_in_reg_rax@PAGE
    add x3, x3, Lbk_x64_in_reg_rax@PAGEOFF
    FMT Lbk_x64_in_leaq_rbx_reg
    b Lbk_x64_in_store_dst_rax

Lbk_x64_in_op_aaddr1:
    // %rdi = descriptor of X; %xmm0 = A; %rax = bsk_aref1; store %rax
    bl Lbk_x64_in_desc_addr
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_x64_in_load
    CALLRT Lbk_x64_in_rt_aref1
    b Lbk_x64_in_store_dst_rax

Lbk_x64_in_op_aaddr2:
    // %rdi = descriptor of X; %xmm0 = A; %xmm1 = B; %rax = bsk_aref2; store
    bl Lbk_x64_in_desc_addr
    bl Lbk_x64_in_load_ab
    CALLRT Lbk_x64_in_rt_aref2
    b Lbk_x64_in_store_dst_rax

Lbk_x64_in_op_taddr:
    // %rax = the address of A's own temp slot (the by-value cell); store
    ldr w0, [x21, #IRI_A]
    bl Lbk_x64_in_use_off
    mov x2, x0
    FMT Lbk_x64_in_taddr_fmt
    b Lbk_x64_in_store_dst_rax

Lbk_x64_in_op_aref:
    // %rax = descriptor of numeric array X; store
    ldr w0, [x21, #IRI_X]
    mov x1, #0
    b 1f
Lbk_x64_in_op_saref:
    // %rax = descriptor of string array X; store
    ldr w0, [x21, #IRI_X]
    mov x1, #1
1:
    adrp x2, Lbk_x64_in_reg_rax@PAGE
    add x2, x2, Lbk_x64_in_reg_rax@PAGEOFF
    bl Lbk_x64_in_arr_operand
    b Lbk_x64_in_store_dst_rax

Lbk_x64_in_op_subarg:
    // argument-vector slot k (1 .. LIM_SUB_PARAMS-1, below V) := A
    ldr x9, [x21, #IRI_IMM]
    sub x10, x9, #1
    cmp x10, #LIM_SUB_PARAMS - 2
    b.hi Lbk_x64_in_bad_imm
    ldr x10, [x26, #BK_X64_FS_V]
    cmp x9, x10
    b.hs Lbk_x64_in_bad_imm
    b Lbk_x64_in_vec_store

Lbk_x64_in_op_callsub:
    // argument 0 (unless A = IR_NONE) into vector slot 0; %rdi = &vector;
    // call .Lsub_<X>; nothing is stored
    ldr w9, [x21, #IRI_X]
    ldr x10, [x26, #BK_X64_FS_MAIN]
    ldr w10, [x10, #IRM_NSUBS]
    cmp w9, w10
    b.hs Lbk_x64_in_bad_unit
    ldr w0, [x21, #IRI_A]
    cmn w0, #1
    b.eq 1f
    ldr x10, [x26, #BK_X64_FS_V]
    cbz x10, Lbk_x64_in_bad_imm     // a unit without parameters
    mov x9, #0
    bl Lbk_x64_in_vec_slot
1:
    // the vector starts at local slot W + L
    ldr x10, [x26, #BK_X64_FS_L]
    add x2, x23, x10
    lsl x2, x2, #3
    ldr w3, [x21, #IRI_X]
    FMT Lbk_x64_in_callsub_fmt
    b Lbk_x64_in_next

Lbk_x64_in_op_subret:
    // SUBEND: end the activation, then the epilogue (SUB body only)
    ldr w9, [x27, #IRF_KIND]
    cmp w9, #FUNC_KIND_SUB
    b.ne Lbk_x64_in_bad_kind
    CALLRT Lbk_x64_in_rt_sub_leave
    FMT Lbk_x64_in_epilogue
    b Lbk_x64_in_next

// common tail of subarg: x9 = k; argument-vector slot k := A
Lbk_x64_in_vec_store:
    bl Lbk_x64_in_vec_slot
    b Lbk_x64_in_next

Lbk_x64_in_bad_unit:
    FAIL Lbk_x64_in_err_unit

// Lbk_x64_in_load_arg0 -- load argument 0 of a callfn / scallfn (temp in w0)
// by the callee's parameter 0 kind: a string parameter takes the sref in
// %rdi, a numeric one the number in %xmm0.
// In:  w0 = temp, x21 = current record.  Frame: 16 bytes
    .p2align 2
Lbk_x64_in_load_arg0:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    str x0, [sp, #-16]!
    bl Lbk_x64_in_callee_fnk
    ldr x9, [sp], #16
    mov x10, x0
    mov x0, x9
    tbnz w10, #0, 1f                // FNK_SPARAM0
    mov x1, #0
    bl Lbk_x64_in_load
    b 2f
1:
    adrp x1, Lbk_x64_in_reg_rdi@PAGE
    add x1, x1, Lbk_x64_in_reg_rdi@PAGEOFF
    bl Lbk_x64_in_loadq
2:
    ldp x29, x30, [sp], #16
    ret

// common tail: store %xmm0 into the DST temp's slot
Lbk_x64_in_store_dst:
    ldr w0, [x21, #IRI_DST]
    bl Lbk_x64_in_def_off
    mov x2, x0
    FMT Lbk_x64_in_st_rsp
    b Lbk_x64_in_next

// common tail: store %rax (an sref or a pointer) into the DST temp's slot
Lbk_x64_in_store_dst_rax:
    ldr w0, [x21, #IRI_DST]
    bl Lbk_x64_in_def_off
    mov x2, x0
    FMT Lbk_x64_in_st_rax
    b Lbk_x64_in_next

Lbk_x64_in_bad_letter:
    FAIL Lbk_x64_in_err_letter
Lbk_x64_in_bad_place:
    FAIL Lbk_x64_in_err_place
Lbk_x64_in_bad_rel:
    FAIL Lbk_x64_in_err_rel
Lbk_x64_in_bad_label:
    FAIL Lbk_x64_in_err_label
Lbk_x64_in_bad_string:
    FAIL Lbk_x64_in_err_string
Lbk_x64_in_bad_slot:
    FAIL Lbk_x64_in_err_slot
Lbk_x64_in_bad_mode:
    FAIL Lbk_x64_in_err_mode
Lbk_x64_in_bad_param:
    FAIL Lbk_x64_in_err_param
Lbk_x64_in_bad_kind:
    FAIL Lbk_x64_in_err_kind
Lbk_x64_in_bad_imm:
    FAIL Lbk_x64_in_err_imm

// ---- dispatch table: entry k = Lbk_x64_in_op_<opcode k> - table --------
    .p2align 2
Lbk_x64_in_table:
    .long Lbk_x64_in_op_nop - Lbk_x64_in_table          // OP_NOP      0
    .long Lbk_x64_in_op_line - Lbk_x64_in_table         // OP_LINE     1
    .long Lbk_x64_in_op_label - Lbk_x64_in_table        // OP_LABEL    2
    .long Lbk_x64_in_op_const - Lbk_x64_in_table        // OP_CONST    3
    .long Lbk_x64_in_op_ldv - Lbk_x64_in_table          // OP_LDV      4
    .long Lbk_x64_in_op_stv - Lbk_x64_in_table          // OP_STV      5
    .long Lbk_x64_in_op_arith - Lbk_x64_in_table        // OP_ADD      6
    .long Lbk_x64_in_op_arith - Lbk_x64_in_table        // OP_SUB      7
    .long Lbk_x64_in_op_arith - Lbk_x64_in_table        // OP_MUL      8
    .long Lbk_x64_in_op_div - Lbk_x64_in_table          // OP_DIV      9
    .long Lbk_x64_in_op_pow - Lbk_x64_in_table          // OP_POW      10
    .long Lbk_x64_in_op_neg - Lbk_x64_in_table          // OP_NEG      11
    .long Lbk_x64_in_op_builtin - Lbk_x64_in_table      // OP_SIN      12
    .long Lbk_x64_in_op_builtin - Lbk_x64_in_table      // OP_COS      13
    .long Lbk_x64_in_op_builtin - Lbk_x64_in_table      // OP_TAN      14
    .long Lbk_x64_in_op_builtin - Lbk_x64_in_table      // OP_ATN      15
    .long Lbk_x64_in_op_builtin - Lbk_x64_in_table      // OP_EXP      16
    .long Lbk_x64_in_op_builtin - Lbk_x64_in_table      // OP_ABS      17
    .long Lbk_x64_in_op_builtin - Lbk_x64_in_table      // OP_LOG      18
    .long Lbk_x64_in_op_builtin - Lbk_x64_in_table      // OP_SQR      19
    .long Lbk_x64_in_op_builtin - Lbk_x64_in_table      // OP_INT      20
    .long Lbk_x64_in_op_rnd - Lbk_x64_in_table          // OP_RND      21
    .long Lbk_x64_in_op_ald1 - Lbk_x64_in_table         // OP_ALD1     22
    .long Lbk_x64_in_op_ald2 - Lbk_x64_in_table         // OP_ALD2     23
    .long Lbk_x64_in_op_ast1 - Lbk_x64_in_table         // OP_AST1     24
    .long Lbk_x64_in_op_ast2 - Lbk_x64_in_table         // OP_AST2     25
    .long Lbk_x64_in_op_callfn - Lbk_x64_in_table       // OP_CALLFN   26
    .long Lbk_x64_in_op_param - Lbk_x64_in_table        // OP_PARAM    27
    .long Lbk_x64_in_op_ret - Lbk_x64_in_table          // OP_RET      28
    .long Lbk_x64_in_op_jmp - Lbk_x64_in_table          // OP_JMP      29
    .long Lbk_x64_in_op_jcmp - Lbk_x64_in_table         // OP_JCMP     30
    .long Lbk_x64_in_op_jfor - Lbk_x64_in_table         // OP_JFOR     31
    .long Lbk_x64_in_op_gosub - Lbk_x64_in_table        // OP_GOSUB    32
    .long Lbk_x64_in_op_return - Lbk_x64_in_table       // OP_RETURN   33
    .long Lbk_x64_in_op_read - Lbk_x64_in_table         // OP_READ     34
    .long Lbk_x64_in_op_prnum - Lbk_x64_in_table        // OP_PRNUM    35
    .long Lbk_x64_in_op_prstr - Lbk_x64_in_table        // OP_PRSTR    36
    .long Lbk_x64_in_op_prcomma - Lbk_x64_in_table      // OP_PRCOMMA  37
    .long Lbk_x64_in_op_prsemi - Lbk_x64_in_table       // OP_PRSEMI   38
    .long Lbk_x64_in_op_prnl - Lbk_x64_in_table         // OP_PRNL     39
    .long Lbk_x64_in_op_end - Lbk_x64_in_table          // OP_END      40
    .long Lbk_x64_in_op_end - Lbk_x64_in_table          // OP_STOP     41
    .long Lbk_x64_in_op_matredim - Lbk_x64_in_table     // OP_MATREDIM 42
    .long Lbk_x64_in_op_mat1 - Lbk_x64_in_table         // OP_MATREAD  43
    .long Lbk_x64_in_op_matprint - Lbk_x64_in_table     // OP_MATPRINT 44
    .long Lbk_x64_in_op_mat1 - Lbk_x64_in_table         // OP_MATZER   45
    .long Lbk_x64_in_op_mat1 - Lbk_x64_in_table         // OP_MATCON   46
    .long Lbk_x64_in_op_mat1 - Lbk_x64_in_table         // OP_MATIDN   47
    .long Lbk_x64_in_op_mat2 - Lbk_x64_in_table         // OP_MATCOPY  48
    .long Lbk_x64_in_op_mat3 - Lbk_x64_in_table         // OP_MATADD   49
    .long Lbk_x64_in_op_mat3 - Lbk_x64_in_table         // OP_MATSUB   50
    .long Lbk_x64_in_op_mat3 - Lbk_x64_in_table         // OP_MATMUL   51
    .long Lbk_x64_in_op_matscale - Lbk_x64_in_table     // OP_MATSCALE 52
    .long Lbk_x64_in_op_mat2 - Lbk_x64_in_table         // OP_MATTRN   53
    .long Lbk_x64_in_op_mat2 - Lbk_x64_in_table         // OP_MATINV   54
    .long Lbk_x64_in_op_slit - Lbk_x64_in_table         // OP_SLIT      55
    .long Lbk_x64_in_op_svar - Lbk_x64_in_table         // OP_SVAR      56
    .long Lbk_x64_in_op_sald1 - Lbk_x64_in_table        // OP_SALD1     57
    .long Lbk_x64_in_op_sset - Lbk_x64_in_table         // OP_SSET      58
    .long Lbk_x64_in_op_sjcmp - Lbk_x64_in_table        // OP_SJCMP     59
    .long Lbk_x64_in_op_prsv - Lbk_x64_in_table         // OP_PRSV      60
    .long Lbk_x64_in_op_prtab - Lbk_x64_in_table        // OP_PRTAB     61
    .long Lbk_x64_in_op_sread - Lbk_x64_in_table        // OP_SREAD     62
    .long Lbk_x64_in_op_inbeg - Lbk_x64_in_table        // OP_INBEG     63
    .long Lbk_x64_in_op_innum - Lbk_x64_in_table        // OP_INNUM     64
    .long Lbk_x64_in_op_insv - Lbk_x64_in_table         // OP_INSV      65
    .long Lbk_x64_in_op_inend - Lbk_x64_in_table        // OP_INEND     66
    .long Lbk_x64_in_op_matinput - Lbk_x64_in_table     // OP_MATINPUT  67
    .long Lbk_x64_in_op_smatinput - Lbk_x64_in_table    // OP_SMATINPUT 68
    .long Lbk_x64_in_op_smatredim - Lbk_x64_in_table    // OP_SMATREDIM 69
    .long Lbk_x64_in_op_smatread - Lbk_x64_in_table     // OP_SMATREAD  70
    .long Lbk_x64_in_op_smatprint - Lbk_x64_in_table    // OP_SMATPRINT 71
    .long Lbk_x64_in_op_chgs2n - Lbk_x64_in_table       // OP_CHGS2N    72
    .long Lbk_x64_in_op_chgn2s - Lbk_x64_in_table       // OP_CHGN2S    73
    .long Lbk_x64_in_op_onsel - Lbk_x64_in_table        // OP_ONSEL     74
    .long Lbk_x64_in_op_restore - Lbk_x64_in_table      // OP_RESTORE   75
    .long Lbk_x64_in_op_randomize - Lbk_x64_in_table    // OP_RANDOMIZE 76
    .long Lbk_x64_in_op_sgncot - Lbk_x64_in_table       // OP_SGN       77
    .long Lbk_x64_in_op_sgncot - Lbk_x64_in_table       // OP_COT       78
    .long Lbk_x64_in_op_num - Lbk_x64_in_table          // OP_NUM       79
    .long Lbk_x64_in_op_det - Lbk_x64_in_table          // OP_DET       80
    .long Lbk_x64_in_op_fnarg - Lbk_x64_in_table        // OP_FNARG     81
    .long Lbk_x64_in_op_stparam - Lbk_x64_in_table      // OP_STPARAM   82
    .long Lbk_x64_in_op_ldfv - Lbk_x64_in_table         // OP_LDFV      83
    .long Lbk_x64_in_op_stfv - Lbk_x64_in_table         // OP_STFV      84
    .long Lbk_x64_in_op_scell - Lbk_x64_in_table        // OP_SCELL     85
    .long Lbk_x64_in_op_sstr - Lbk_x64_in_table         // OP_SSTR      86
    .long Lbk_x64_in_op_slen - Lbk_x64_in_table         // OP_LEN       87
    .long Lbk_x64_in_op_slen - Lbk_x64_in_table         // OP_ASC       88
    .long Lbk_x64_in_op_slen - Lbk_x64_in_table         // OP_VAL       89
    .long Lbk_x64_in_op_sald2 - Lbk_x64_in_table        // OP_SALD2     90
    .long Lbk_x64_in_op_sparam - Lbk_x64_in_table       // OP_SPARAM    91
    .long Lbk_x64_in_op_sfv - Lbk_x64_in_table          // OP_SFV       92
    .long Lbk_x64_in_op_scallfn - Lbk_x64_in_table      // OP_SCALLFN   93
    .long Lbk_x64_in_op_sret - Lbk_x64_in_table         // OP_SRET      94
    .long Lbk_x64_in_op_fsel - Lbk_x64_in_table         // OP_FSEL      95
    .long Lbk_x64_in_op_jeof - Lbk_x64_in_table         // OP_JEOF      96
    .long Lbk_x64_in_op_fileop - Lbk_x64_in_table       // OP_SCRATCH   97
    .long Lbk_x64_in_op_fileop - Lbk_x64_in_table       // OP_FRESTORE  98
    .long Lbk_x64_in_op_scat - Lbk_x64_in_table         // OP_SCAT      99
    .long Lbk_x64_in_op_sseg - Lbk_x64_in_table         // OP_SSEG      100
    .long Lbk_x64_in_op_pos - Lbk_x64_in_table          // OP_POS       101
    .long Lbk_x64_in_op_vaddr - Lbk_x64_in_table        // OP_VADDR     102
    .long Lbk_x64_in_op_aaddr1 - Lbk_x64_in_table       // OP_AADDR1    103
    .long Lbk_x64_in_op_aaddr2 - Lbk_x64_in_table       // OP_AADDR2    104
    .long Lbk_x64_in_op_taddr - Lbk_x64_in_table        // OP_TADDR     105
    .long Lbk_x64_in_op_aref - Lbk_x64_in_table         // OP_AREF      106
    .long Lbk_x64_in_op_saref - Lbk_x64_in_table        // OP_SAREF     107
    .long Lbk_x64_in_op_subarg - Lbk_x64_in_table       // OP_SUBARG    108
    .long Lbk_x64_in_op_callsub - Lbk_x64_in_table      // OP_CALLSUB   109
    .long Lbk_x64_in_op_subret - Lbk_x64_in_table       // OP_SUBRET    110
    .long Lbk_x64_in_op_linput - Lbk_x64_in_table       // OP_LINPUT    111
    .long Lbk_x64_in_op_exit - Lbk_x64_in_table         // OP_EXIT      112
Lbk_x64_in_table_end:
.if (Lbk_x64_in_table_end - Lbk_x64_in_table) != 4 * OP_COUNT
    .error "x64_insn.s dispatch table does not cover OP_COUNT opcodes"
.endif
.if (OP_SLIT != OP_MATINV + 1) || (OP_STFV != OP_SLIT + 29) || (OP_COT != OP_SGN + 1)
    .error "x64_insn.s dispatch table assumes the opcode order of ir.inc"
.endif
.if (OP_SCELL != OP_STFV + 1) || (OP_ASC != OP_LEN + 1) || (OP_VAL != OP_LEN + 2) || (OP_FRESTORE != OP_SCRATCH + 1) || (OP_FRESTORE != OP_SCELL + 13)
    .error "x64_insn.s Fifth Edition dispatch entries assume the opcode order of ir.inc"
.endif
.if (OP_SUB != OP_ADD + 1) || (OP_MUL != OP_ADD + 2) || (OP_INT != OP_SIN + 8)
    .error "x64_insn.s name tables assume consecutive opcodes"
.endif
.if (REL_EQ != 1) || (REL_NE != 2) || (REL_LT != 3) || (REL_LE != 4) || (REL_GT != 5) || (REL_GE != 6)
    .error "x64_insn.s jump condition table assumes REL_EQ..REL_GE = 1..6"
.endif

// ======================================================================
// File-local helpers. Private convention: they read the state registers
// of _bk_x64_emit_func (x19-x28, see its header) and preserve x19-x28;
// they clobber x0-x17, d0-d7, d16-d31. On invalid IR they branch to
// Lbk_x64_in_fail (which unwinds to _bk_x64_emit_func's frame).
// ======================================================================

// ---------------------------------------------------------------------
// Lbk_x64_in_use_off -- byte offset of a temp being READ.
// In:  w0 = temp
// Out: x0 = 8 * (t - base)
// Checks: t is a temp defined earlier in the current line segment.
// Leaf, no frame.
// ---------------------------------------------------------------------
    .p2align 2
Lbk_x64_in_use_off:
    mov w0, w0                      // zero-extend the u32 temp
    cmn x24, #1
    b.eq Lbk_x64_in_use_bad         // nothing defined in this segment
    cmp x0, x24
    b.lo Lbk_x64_in_use_bad         // defined before the last `line`
    cmp x0, x28
    b.hs Lbk_x64_in_use_bad         // not defined yet (or IR_NONE)
    sub x0, x0, x24
    lsl x0, x0, #3
    ret
Lbk_x64_in_use_bad:
    FAIL Lbk_x64_in_err_temp

// ---------------------------------------------------------------------
// Lbk_x64_in_def_off -- byte offset of a temp being DEFINED; the first
// definition after a `line` fixes the segment base.
// In:  w0 = temp
// Out: x0 = 8 * (t - base); x24/x28 updated
// Leaf, no frame.
// ---------------------------------------------------------------------
    .p2align 2
Lbk_x64_in_def_off:
    mov w0, w0
    cmn w0, #1
    b.eq Lbk_x64_in_def_bad         // IR_NONE as a destination
    cmn x24, #1
    csel x24, x0, x24, eq
    cmp x0, x24
    b.lo Lbk_x64_in_def_bad
    // slot must lie inside the temp area computed in pass 1
    sub x9, x0, x24
    cmp x9, x23
    b.hs Lbk_x64_in_def_bad
    // top = max(top, t + 1)
    add x10, x0, #1
    cmp x10, x28
    csel x28, x10, x28, hi
    lsl x0, x9, #3
    ret
Lbk_x64_in_def_bad:
    FAIL Lbk_x64_in_err_temp

// ---------------------------------------------------------------------
// Lbk_x64_in_load -- emit "    movsd S(t), %xmm<n>".
// In:  w0 = temp (being read), x1 = xmm register number (0..2)
// Frame: 32 bytes (frame record + saved register number)
// ---------------------------------------------------------------------
    .p2align 2
Lbk_x64_in_load:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x1, [sp, #16]
    bl Lbk_x64_in_use_off
    mov x2, x0
    ldr x3, [sp, #16]
    FMT Lbk_x64_in_ld_rsp_n
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lbk_x64_in_load_ab -- load temp A into %xmm0 and temp B into %xmm1.
// In:  x21 = current record
// Frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lbk_x64_in_load_ab:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_x64_in_load
    ldr w0, [x21, #IRI_B]
    mov x1, #1
    bl Lbk_x64_in_load
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Lbk_x64_in_nparams -- NPARAMS of the current function.
// Out: x0 = IRF_NPARAMS (0 for main).
// Leaf, no frame.
// ---------------------------------------------------------------------
    .p2align 2
Lbk_x64_in_nparams:
    ldr w0, [x27, #IRF_NPARAMS]
    ret

// ---------------------------------------------------------------------
// _bk_x64_func_shape -- the frame shape of one IR function (DESIGN.md
// 5.3 / 5.4.4; the same definitions as the arm64 backend, so the SUB unit
// cost of 5.3.1 is target-independent):
//   W = the largest number of temps defined between two `line`s (slot(t) =
//       t - base, base = the first temp defined after the latest `line`);
//   V = the largest SUBNPARAMS of the units its `callsub`s call (0 without);
//   L = NP + 2 for a multi-line function (parameters, value variable or
//       result descriptor, saved run-time line); NP + 1 for a single-line
//       string function (parameters, result descriptor); else max(1, NP).
// In:  x0 = Module* the function belongs to, x1 = the main Module* (its
//      IRM_SUBS), x2 = function index (present)
// Out: x0 = W, x1 = V, x2 = L, x3 = 0, or x3 = reason (temps out of order,
//      callsub of an unknown unit)
// Clobbers: x0-x17.  Leaf, no frame.
// ---------------------------------------------------------------------
    .globl _bk_x64_func_shape
    .p2align 2
_bk_x64_func_shape:
    // x9 = Function*, x10 = function index
    mov x10, x2
    add x9, x0, #IRM_FUNCS
    mov x11, #IRF_SIZE
    madd x9, x10, x11, x9
    // x11 = cursor, x12 = end of the instruction array
    ldr x11, [x9, #IRF_INSNS]
    ldr w12, [x9, #IRF_NINSNS]
    add x12, x11, x12, lsl #IRI_SHIFT
    mov x13, #0                     // W
    mov x14, #-1                    // segment base, -1 = none yet
    mov x15, #0                     // V
Lbk_x64_shape_loop:
    cmp x11, x12
    b.hs Lbk_x64_shape_done
    ldrh w16, [x11, #IRI_OP]
    cmp w16, #OP_LINE
    b.ne 1f
    // a `line` starts a new temp segment
    mov x14, #-1
    b Lbk_x64_shape_next
1:
    // callsub X: V = max(V, SUBNPARAMS of unit X of the main module)
    cmp w16, #OP_CALLSUB
    b.ne 2f
    ldr w17, [x11, #IRI_X]
    ldr w16, [x1, #IRM_NSUBS]
    cmp w17, w16
    b.hs Lbk_x64_shape_bad_unit
    ldr x16, [x1, #IRM_SUBS]
    ldr x16, [x16, x17, lsl #3]
    ldr w16, [x16, #IRM_SUBNPARAMS]
    cmp x16, x15
    csel x15, x16, x15, hi
2:
    ldr w16, [x11, #IRI_DST]
    cmn w16, #1                     // IR_NONE: defines nothing
    b.eq Lbk_x64_shape_next
    // the first definition of the segment fixes its base
    cmn x14, #1
    csel x14, x16, x14, eq
    cmp x16, x14
    b.lo Lbk_x64_shape_order
    // W = max(W, t - base + 1)
    sub x17, x16, x14
    add x17, x17, #1
    cmp x17, x13
    csel x13, x17, x13, hi
Lbk_x64_shape_next:
    add x11, x11, #IRI_SIZE
    b Lbk_x64_shape_loop
Lbk_x64_shape_done:
    // L from the kind, NPARAMS and the function's FNK_STRING bit
    ldr w16, [x9, #IRF_NPARAMS]
    ldr w17, [x9, #IRF_KIND]
    cmp w17, #FUNC_KIND_FNML
    b.ne 1f
    add x2, x16, #2                 // multi-line: NP + 2
    b 3f
1:
    add x17, x0, #IRM_FNKINDS
    ldr w17, [x17, x10, lsl #2]
    tst w17, #FNK_STRING
    b.eq 2f
    add x2, x16, #1                 // single-line string function: NP + 1
    b 3f
2:
    cmp x16, #1                     // otherwise max(1, NP)
    mov x17, #1
    csel x2, x17, x16, lo
3:
    mov x0, x13
    mov x1, x15
    mov x3, #0
    ret
Lbk_x64_shape_order:
    adrp x3, Lbk_x64_in_err_order@PAGE
    add x3, x3, Lbk_x64_in_err_order@PAGEOFF
    ret
Lbk_x64_shape_bad_unit:
    adrp x3, Lbk_x64_in_err_unit@PAGE
    add x3, x3, Lbk_x64_in_err_unit@PAGEOFF
    ret

// ---------------------------------------------------------------------
// Lbk_x64_in_cell_np -- slot index of local cell NP + n.
// In:  x0 = n.  Out: x0 = W + NP + n (the byte offset is 8 times that).
// Frame: 32 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lbk_x64_in_cell_np:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x0, [sp, #16]
    bl Lbk_x64_in_nparams
    ldr x9, [sp, #16]
    add x0, x0, x9
    add x0, x0, x23
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lbk_x64_in_need_ml -- fail unless the current function is a multi-line FN.
// Leaf, no frame.
// ---------------------------------------------------------------------
    .p2align 2
Lbk_x64_in_need_ml:
    ldr w9, [x27, #IRF_KIND]
    cmp w9, #FUNC_KIND_FNML
    b.ne Lbk_x64_in_bad_kind
    ret

// ---------------------------------------------------------------------
// Lbk_x64_in_fnk -- FNK_* bits of a function.
// In:  x0 = function index (FUNC_FN_BASE + letter; 0 = main)
// Out: w0 = the bits of IRM_FNKINDS
// Clobbers: x9.  Leaf, no frame.
// ---------------------------------------------------------------------
    .p2align 2
Lbk_x64_in_fnk:
    add x9, x20, #IRM_FNKINDS
    ldr w0, [x9, x0, lsl #2]
    ret

// ---------------------------------------------------------------------
// Lbk_x64_in_callee_fnk -- FNK_* bits of the function called by the call
// that the current record belongs to: for a callfn / scallfn the record's X;
// for a fnarg the X of the callfn / scallfn that follows its run of fnargs.
// In:  x21 = current record
// Out: w0 = bits.  Fails if no call follows or the letter is bad.
// Frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lbk_x64_in_callee_fnk:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x11, x21
Lbk_x64_in_cf_scan:
    ldrh w9, [x11, #IRI_OP]
    cmp w9, #OP_FNARG
    b.ne 1f
    add x11, x11, #IRI_SIZE
    cmp x11, x22
    b.lo Lbk_x64_in_cf_scan
    b Lbk_x64_in_bad_kind
1:
    cmp w9, #OP_CALLFN
    b.eq 2f
    cmp w9, #OP_SCALLFN
    b.eq 2f
    b Lbk_x64_in_bad_kind
2:
    ldr w0, [x11, #IRI_X]
    cmp w0, #NUM_LETTERS
    b.hs Lbk_x64_in_bad_letter
    add x0, x0, #FUNC_FN_BASE
    bl Lbk_x64_in_fnk
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Lbk_x64_in_cells_init -- prologue part of an FN function: spill the
// arguments (numeric: %xmm<k> -> local cell k; string parameter: its
// integer register R(k) -> local cell k; k < NP). A string function then
// stores its result descriptor (%rax) in cell NP; a multi-line function
// otherwise clears its value variable (cell NP). A multi-line function then
// saves the caller's run-time line (cell NP+1) and, if it is a string
// function, clears its value (bsk_str_clear on the result descriptor).
// Frame: 32 bytes (frame record + the loop counter + string-function flag)
// ---------------------------------------------------------------------
    .p2align 2
Lbk_x64_in_cells_init:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str xzr, [sp, #16]              // k
Lbk_x64_in_ci_loop:
    bl Lbk_x64_in_nparams
    ldr x2, [sp, #16]
    cmp x2, x0
    b.hs Lbk_x64_in_ci_args_done
    mov x0, x25
    bl Lbk_x64_in_fnk
    ldr x2, [sp, #16]
    lsr w9, w0, w2
    add x3, x23, x2
    lsl x3, x3, #3
    tbnz w9, #0, Lbk_x64_in_ci_sparam
    // "movsd %xmm<k>, 8*(W+k)(%rsp)"
    FMT Lbk_x64_in_arg_save
    b Lbk_x64_in_ci_next
Lbk_x64_in_ci_sparam:
    // "movq R(k), 8*(W+k)(%rsp)"
    adrp x10, Lbk_x64_in_argregs@PAGE
    add x10, x10, Lbk_x64_in_argregs@PAGEOFF
    ldr x2, [x10, x2, lsl #3]
    FMT Lbk_x64_in_sarg_save
Lbk_x64_in_ci_next:
    ldr x2, [sp, #16]
    add x2, x2, #1
    str x2, [sp, #16]
    b Lbk_x64_in_ci_loop
Lbk_x64_in_ci_args_done:
    mov x0, x25
    bl Lbk_x64_in_fnk
    and w0, w0, #FNK_STRING
    str x0, [sp, #24]               // nonzero: string function
    cbz x0, 1f
    // result descriptor arrives in %rax: cell NP := %rax
    mov x0, #0
    bl Lbk_x64_in_cell_np
    lsl x2, x0, #3
    FMT Lbk_x64_in_st_rax
    b 2f
1:
    ldr w9, [x27, #IRF_KIND]
    cmp w9, #FUNC_KIND_FNML
    b.ne Lbk_x64_in_ci_done
    mov x0, #0
    bl Lbk_x64_in_cell_np
    lsl x2, x0, #3
    FMT Lbk_x64_in_fv_init          // value variable := 0
2:
    ldr w9, [x27, #IRF_KIND]
    cmp w9, #FUNC_KIND_FNML
    b.ne Lbk_x64_in_ci_done
    mov x0, #1
    bl Lbk_x64_in_cell_np
    lsl x2, x0, #3
    FMT Lbk_x64_in_line_save        // saved run-time line
    ldr x9, [sp, #24]
    cbz x9, Lbk_x64_in_ci_done
    // multi-line string function: its value starts empty
    mov x0, #0
    bl Lbk_x64_in_cell_np
    lsl x2, x0, #3
    FMT Lbk_x64_in_sfv_clear
Lbk_x64_in_ci_done:
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lbk_x64_in_loadq -- emit "    movq S(t), %<reg>" (an sref / pointer).
// In:  w0 = temp (being read), x1 = register name ("rdi", "rsi")
// Frame: 32 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lbk_x64_in_loadq:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x1, [sp, #16]
    bl Lbk_x64_in_use_off
    mov x2, x0
    ldr x3, [sp, #16]
    FMT Lbk_x64_in_movq_ld
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lbk_x64_in_load_sab -- load srefs A into %rdi and B into %rsi.
// In:  x21 = current record
// Frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lbk_x64_in_load_sab:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    ldr w0, [x21, #IRI_A]
    adrp x1, Lbk_x64_in_reg_rdi@PAGE
    add x1, x1, Lbk_x64_in_reg_rdi@PAGEOFF
    bl Lbk_x64_in_loadq
    ldr w0, [x21, #IRI_B]
    adrp x1, Lbk_x64_in_reg_rsi@PAGE
    add x1, x1, Lbk_x64_in_reg_rsi@PAGEOFF
    bl Lbk_x64_in_loadq
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Array operand wrappers around Lbk_x64_in_arr_operand:
// Lbk_x64_in_sdesc_addr   -- the string array named by the record's X into %rdi
// Lbk_x64_in_sdesc_letter -- the string array letter in w2 (the IMM of
//                            chgn2s's element form) into %rdi
// Lbk_x64_in_desc_addr    -- the numeric array named by the record's X into %rdi
// Lbk_x64_in_desc_reg     -- the numeric array letter in w0 into the register
//                            named by x1 ("rsi", "rdx", ...)
// In:  x21 = current record / w2 / w0, x1 as above
// Tail calls, no frame of their own.
// ---------------------------------------------------------------------
    .p2align 2
Lbk_x64_in_sdesc_addr:
    ldr w2, [x21, #IRI_X]
Lbk_x64_in_sdesc_letter:
    mov w0, w2
    mov x1, #1
    adrp x2, Lbk_x64_in_reg_rdi@PAGE
    add x2, x2, Lbk_x64_in_reg_rdi@PAGEOFF
    b Lbk_x64_in_arr_operand
Lbk_x64_in_desc_addr:
    ldr w0, [x21, #IRI_X]
    mov x1, #0
    adrp x2, Lbk_x64_in_reg_rdi@PAGE
    add x2, x2, Lbk_x64_in_reg_rdi@PAGEOFF
    b Lbk_x64_in_arr_operand
Lbk_x64_in_desc_reg:
    mov x2, x1
    mov x1, #0
    b Lbk_x64_in_arr_operand

// ---------------------------------------------------------------------
// Lbk_x64_in_arr_operand -- emit the instruction that puts the RTA_*
// descriptor address of an array into a register (DESIGN.md 5.4.5, and
// 5.4.6 in a SUB unit):
//   main module:     "leaq .Ldesc_<L>(%rip), %<reg>" / ".Lsdesc_<L>"
//   unit, own array: "leaq <DESCOFF + 32*d(L)>(%rbx), %<reg>"
//   unit, parameter: "movq <P(k)>(%rbx), %<reg>" (the caller's descriptor)
// In:  w0 = letter, x1 = 0 numeric / 1 string array, x2 = register name
// Checks: the letter names an array in use (a parameter array must be a
// parameter of the unit).
// Frame: 48 bytes (frame record, letter, kind, register name)
// ---------------------------------------------------------------------
    .p2align 2
Lbk_x64_in_arr_operand:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    mov w0, w0                      // zero-extend the u32 letter
    cmp x0, #NUM_LETTERS
    b.hs Lbk_x64_in_desc_bad
    stp x0, x1, [sp, #16]
    str x2, [sp, #32]
    // x9 = the IRA entry of the letter (numeric or string array table)
    add x9, x20, #IRM_ARRAYS
    cbz x1, 1f
    add x9, x20, #IRM_SARRAYS
1:
    add x9, x9, x0, lsl #4
    ldr w10, [x9, #IRA_DIMS]
    cbz w10, Lbk_x64_in_desc_bad
    ldr x11, [x26, #BK_X64_FS_UNIT]
    cbnz x11, Lbk_x64_in_ao_unit
    // main module: the static descriptor
    mov x2, x0
    ldr x3, [sp, #32]
    cbnz x1, 2f
    FMT Lbk_x64_in_desc_reg_fmt
    b Lbk_x64_in_ao_done
2:
    FMT Lbk_x64_in_sdesc_reg_fmt
    b Lbk_x64_in_ao_done
Lbk_x64_in_ao_unit:
    ldr w11, [x9, #IRA_FLAGS]
    tst w11, #IRA_FLAG_PARAM
    b.eq 3f
    // a parameter array: its pointer P(k) holds the caller's descriptor
    mov x10, #SUBP_ARR
    mov x11, #SUBP_SARR
    cmp x1, #0
    csel x1, x11, x10, ne
    bl Lbk_x64_in_param_off
    cmn x0, #1
    b.eq Lbk_x64_in_desc_bad
    mov x2, x0
    ldr x3, [sp, #32]
    FMT Lbk_x64_in_movq_rbx_reg
    b Lbk_x64_in_ao_done
3:
    // an array of the unit: its descriptor d(L) in the activation block
    mov x0, x20
    ldp x1, x2, [sp, #16]
    bl _bk_x64_unit_desc_index
    ldr x9, [x26, #BK_X64_FS_DESCOFF]
    add x2, x9, x0, lsl #5
    ldr x3, [sp, #32]
    FMT Lbk_x64_in_leaq_rbx_reg
Lbk_x64_in_ao_done:
    ldp x29, x30, [sp], #48
    ret
Lbk_x64_in_desc_bad:
    FAIL Lbk_x64_in_err_letter

// ---------------------------------------------------------------------
// Lbk_x64_in_param_off -- in a SUB unit, the block offset P(k) = PARAMOFF
// + 8k of the parameter k whose IRM_SUBPARAMS entry is the value w0 and
// whose kind is w1 (SUBP_*); -1 if there is none or the current function
// is not in a SUB unit.
// In:  w0 = slot / letter, w1 = SUBP_* kind
// Out: x0 = P(k) or -1
// Frame: 16 bytes (only in a unit)
// ---------------------------------------------------------------------
    .p2align 2
Lbk_x64_in_param_off:
    ldr x9, [x26, #BK_X64_FS_UNIT]
    cbz x9, 1f
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov w2, w1
    mov w1, w0
    mov x0, x20
    bl _bk_x64_unit_param           // x0 = k or -1
    ldp x29, x30, [sp], #16
    cmn x0, #1
    b.eq 2f
    ldr x9, [x26, #BK_X64_FS_PARAMOFF]
    add x0, x9, x0, lsl #3
2:
    ret
1:
    mov x0, #-1
    ret

// ---------------------------------------------------------------------
// Lbk_x64_in_cell_reg -- emit the address of string temp cell X into a
// register: "leaq .Lbsk_scells+<16*X>(%rip), %<reg>" in the main module,
// "leaq <SDOFF + 4576 + 16*X>(%rbx), %<reg>" in a SUB unit.
// In:  x0 = cell X (already checked against NSTEMPS), x1 = register name
// Frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lbk_x64_in_cell_reg:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x3, x1
    lsl x2, x0, #4                  // 16*X (SD_SIZE bytes per cell)
    ldr x9, [x26, #BK_X64_FS_UNIT]
    cbnz x9, 1f
    FMT Lbk_x64_in_scell_reg_fmt
    b 2f
1:
    // the unit's cells follow its 286 string variables in the block
    ldr x9, [x26, #BK_X64_FS_SDOFF]
    add x2, x2, x9
    mov x9, #(NUM_LETTERS * SLOT_PER_LETTER * SD_SIZE)
    add x2, x2, x9
    FMT Lbk_x64_in_leaq_rbx_reg
2:
    ldp x29, x30, [sp], #16
    ret
.if SD_SIZE != 16
    .error "x64_insn.s scales string cells by 16 (SD_SIZE)"
.endif

// ---------------------------------------------------------------------
// Lbk_x64_in_global_off -- byte offset 8*X of the global cell named by
// the current record's X field (V(x) = 8*x(%rbx)).
// In:  x21 = current record
// Out: x0 = 8 * X
// Checks: X < NSLOTS.
// Leaf, no frame.
// ---------------------------------------------------------------------
    .p2align 2
Lbk_x64_in_global_off:
    ldr w0, [x21, #IRI_X]
    ldr w9, [x20, #IRM_NSLOTS]
    cmp w0, w9
    b.hs Lbk_x64_in_global_bad
    lsl x0, x0, #3
    ret
Lbk_x64_in_global_bad:
    FAIL Lbk_x64_in_err_slot

// ---------------------------------------------------------------------
// Lbk_x64_in_emit_callfn -- emit the call of FN letter w2 of the current
// program unit: "call .Lfn_<L>" in the main module, "call .Lsub_<u>_fn_<L>"
// in SUB unit u (a unit's FN calls stay inside the unit).
// In:  w2 = letter (checked by the caller)
// Frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lbk_x64_in_emit_callfn:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    ldr x9, [x26, #BK_X64_FS_UNIT]
    cbnz x9, 1f
    FMT Lbk_x64_in_call_fn
    b 2f
1:
    mov x3, x2
    sub x2, x9, #1
    FMT Lbk_x64_in_call_unit_fn
2:
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Lbk_x64_in_vec_slot -- argument-vector slot k := the reference in temp A:
// "movq S(A), %rax" / "movq %rax, <8*(W+L+k)>(%rsp)" (DESIGN.md 5.4.5
// subarg / callsub).
// In:  x9 = k (< V, checked by the caller), x21 = current record (A)
// Frame: 32 bytes (frame record + k)
// ---------------------------------------------------------------------
    .p2align 2
Lbk_x64_in_vec_slot:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x9, [sp, #16]
    ldr w0, [x21, #IRI_A]
    bl Lbk_x64_in_use_off
    mov x2, x0
    // slot W + L + k
    ldr x9, [sp, #16]
    ldr x10, [x26, #BK_X64_FS_L]
    add x3, x23, x10
    add x3, x3, x9
    lsl x3, x3, #3
    FMT Lbk_x64_in_vec_fmt
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lbk_x64_in_mat_call -- emit "    call bsk_mat_<op>" for the current MAT
// record (name from Lbk_x64_in_mat_names, indexed by opcode - OP_MATREAD).
// In:  x21 = current record
// Frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lbk_x64_in_mat_call:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    ldrh w9, [x21, #IRI_OP]
    sub x9, x9, #OP_MATREAD
    adrp x10, Lbk_x64_in_mat_names@PAGE
    add x10, x10, Lbk_x64_in_mat_names@PAGEOFF
    ldr x2, [x10, x9, lsl #3]
    FMT Lbk_x64_in_call_fmt
    ldp x29, x30, [sp], #16
    ret

// ======================================================================
// Text templates (GNU as AT&T; "%%" is a literal '%' for _bk_x64_fmt)
// ======================================================================
    .section __TEXT,__cstring,cstring_literals
Lbk_x64_in_main_label:
    .asciz "bsk_program:\n"
Lbk_x64_in_fn_label:
    .ascii "    .p2align 4\n"
    .asciz ".Lfn_%L:\n"
Lbk_x64_in_prologue:
    .ascii "    pushq %%rbp\n"
    .ascii "    movq %%rsp, %%rbp\n"
    .ascii "    pushq %%rbx\n"
    .asciz "    subq $%u, %%rsp\n"
Lbk_x64_in_rbx_vars:
    .asciz "    leaq .Lbsk_vars(%%rip), %%rbx\n"
Lbk_x64_in_sub_label:
    .ascii "    .p2align 4\n"
    .asciz ".Lsub_%u:\n"
Lbk_x64_in_unit_fn_label:
    .ascii "    .p2align 4\n"
    .asciz ".Lsub_%u_fn_%L:\n"
Lbk_x64_in_sub_enter:
    .ascii "    movq %%rdi, %%rsi\n"
    .ascii "    leaq .Lsubl_%u(%%rip), %%rdi\n"
    .ascii "    call bsk_sub_enter\n"
    .asciz "    movq %%rax, %%rbx\n"
Lbk_x64_in_arg_save:
    .asciz "    movsd %%xmm%u, %u(%%rsp)\n"
Lbk_x64_in_sarg_save:
    .asciz "    movq %%%s, %u(%%rsp)\n"
Lbk_x64_in_sfv_clear:
    .ascii "    movq %u(%%rsp), %%rdi\n"
    .asciz "    call bsk_str_clear\n"
Lbk_x64_in_fv_init:
    .asciz "    movq $0, %u(%%rsp)\n"
Lbk_x64_in_line_save:
    .ascii "    movl bsk_curline(%%rip), %%eax\n"
    .asciz "    movq %%rax, %u(%%rsp)\n"
Lbk_x64_in_ret_line:
    .ascii "    movq %u(%%rsp), %%rax\n"
    .asciz "    movl %%eax, bsk_curline(%%rip)\n"
Lbk_x64_in_epilogue:
    .ascii "    movq -8(%%rbp), %%rbx\n"
    .ascii "    leave\n"
    .asciz "    ret\n"
Lbk_x64_in_label_def:
    .asciz "%B%u:\n"
Lbk_x64_in_line_fmt:
    .ascii "%B%u:\n"
    .asciz "    movl $%u, bsk_curline(%%rip)\n"
Lbk_x64_in_const_fmt:
    .ascii "    movabsq $%x, %%rax\n"
    .asciz "    movq %%rax, %u(%%rsp)\n"
Lbk_x64_in_ldv_fmt:
    .asciz "    movsd %u(%%rbx), %%xmm0\n"
Lbk_x64_in_stv_fmt:
    .asciz "    movsd %%xmm0, %u(%%rbx)\n"
Lbk_x64_in_ldv_param_fmt:
    .ascii "    movq %u(%%rbx), %%rax\n"
    .asciz "    movsd (%%rax), %%xmm0\n"
Lbk_x64_in_stv_param_fmt:
    .ascii "    movq %u(%%rbx), %%rax\n"
    .asciz "    movsd %%xmm0, (%%rax)\n"
Lbk_x64_in_ld_rsp:
    .asciz "    movsd %u(%%rsp), %%xmm0\n"
Lbk_x64_in_ld_rsp_n:
    .asciz "    movsd %u(%%rsp), %%xmm%u\n"
Lbk_x64_in_st_rsp:
    .asciz "    movsd %%xmm0, %u(%%rsp)\n"
Lbk_x64_in_memop_fmt:
    .asciz "    %s %u(%%rsp), %%xmm0\n"
Lbk_x64_in_ovf_check:
    .ascii "    movq %%xmm0, %%rax\n"
    .ascii "    btrq $63, %%rax\n"
    .ascii "    movabsq $0x7FF0000000000000, %%rcx\n"
    .ascii "    cmpq %%rcx, %%rax\n"
    .ascii "    jb 1f\n"
    .ascii "    movl $%u, %%edi\n"
    .ascii "    call bsk_err\n"
    .asciz "1:\n"
Lbk_x64_in_neg_fmt:
    .ascii "    movq %u(%%rsp), %%rax\n"
    .ascii "    btcq $63, %%rax\n"
    .asciz "    movq %%rax, %u(%%rsp)\n"
Lbk_x64_in_call_fmt:
    .asciz "    call %s\n"
Lbk_x64_in_call_fn:
    .asciz "    call .Lfn_%L\n"
Lbk_x64_in_call_unit_fn:
    .asciz "    call .Lsub_%u_fn_%L\n"
Lbk_x64_in_st_rdi_fmt:
    .asciz "    movq %%rdi, %u(%%rsp)\n"
Lbk_x64_in_sseg_fmt:
    .ascii "    movq %u(%%rsp), %%rsi\n"
    .ascii "    movsd %u(%%rsp), %%xmm0\n"
    .ascii "    movsd %u(%%rsp), %%xmm1\n"
    .asciz "    call bsk_seg\n"
Lbk_x64_in_taddr_fmt:
    .asciz "    leaq %u(%%rsp), %%rax\n"
Lbk_x64_in_vec_fmt:
    .ascii "    movq %u(%%rsp), %%rax\n"
    .asciz "    movq %%rax, %u(%%rsp)\n"
Lbk_x64_in_callsub_fmt:
    .ascii "    leaq %u(%%rsp), %%rdi\n"
    .asciz "    call .Lsub_%u\n"
Lbk_x64_in_rt_str_cat:  .asciz "bsk_str_cat"
Lbk_x64_in_rt_pos:      .asciz "bsk_pos"
Lbk_x64_in_rt_sub_leave: .asciz "bsk_sub_leave"
Lbk_x64_in_sdesc_reg_fmt:
    .asciz "    leaq .Lsdesc_%L(%%rip), %%%s\n"
Lbk_x64_in_desc_reg_fmt:
    .asciz "    leaq .Ldesc_%L(%%rip), %%%s\n"
Lbk_x64_in_matprint_fmt:
    .asciz "    movl $%u, %%esi\n    call bsk_mat_print\n"
Lbk_x64_in_reg_rsi:     .asciz "rsi"
Lbk_x64_in_reg_rdx:     .asciz "rdx"
Lbk_x64_in_ld_elem:
    .asciz "    movsd (%%rax), %%xmm0\n"
Lbk_x64_in_st_elem:
    .asciz "    movsd %%xmm0, (%%rax)\n"
Lbk_x64_in_jmp_label:
    .asciz "    jmp %B%u\n"
Lbk_x64_in_jcc_fmt:
    .asciz "    %s %B%u\n"
Lbk_x64_in_jfor_fmt1:
    .ascii "    movsd %u(%%rsp), %%xmm0\n"
    .ascii "    movsd %u(%%rsp), %%xmm1\n"
    .ascii "    xorpd %%xmm2, %%xmm2\n"
    .ascii "    ucomisd %u(%%rsp), %%xmm2\n"
    .asciz "    ja 2f\n"
Lbk_x64_in_jfor_fmt2:
    .ascii "    ucomisd %%xmm1, %%xmm0\n"
    .ascii "    ja %B%u\n"
    .ascii "    jmp 3f\n"
    .ascii "2:\n"
    .ascii "    ucomisd %%xmm1, %%xmm0\n"
    .ascii "    jb %B%u\n"
    .asciz "3:\n"
Lbk_x64_in_gosub_fmt:
    .ascii "    leaq %B%u(%%rip), %%rdi\n"
    .ascii "    call bsk_gosub_push\n"
    .asciz "    jmp %B%u\n"
Lbk_x64_in_return_fmt:
    .ascii "    call bsk_gosub_pop\n"
    .asciz "    jmp *%%rax\n"
Lbk_x64_in_prstr_fmt:
    .ascii "    leaq .Lstr_%u(%%rip), %%rdi\n"
    .ascii "    movl $%u, %%esi\n"
    .asciz "    call bsk_print_str\n"

Lbk_x64_in_movq_ld:
    .asciz "    movq %u(%%rsp), %%%s\n"
Lbk_x64_in_st_rax:
    .asciz "    movq %%rax, %u(%%rsp)\n"
Lbk_x64_in_slit_fmt:
    .asciz "    leaq .Lsd_%u(%%rip), %%rax\n"
Lbk_x64_in_svar_fmt:
    .asciz "    leaq .Lbsk_svars+%u(%%rip), %%rax\n"
Lbk_x64_in_movq_rbx_reg:
    .asciz "    movq %u(%%rbx), %%%s\n"
Lbk_x64_in_movq_rbx_rax:
    .asciz "    movq %u(%%rbx), %%rax\n"
Lbk_x64_in_cmp0_fmt:
    .asciz "    cmpl $0, %%eax\n"
Lbk_x64_in_smatprint_fmt:
    .asciz "    movl $%u, %%esi\n    call bsk_smat_print\n"
Lbk_x64_in_onsel_fmt:
    .asciz "    movl $%u, %%edi\n    call bsk_on\n"
Lbk_x64_in_restore_fmt:
    .asciz "    movl $%u, %%edi\n    call bsk_restore\n"
Lbk_x64_in_ld_cell_fmt:
    .asciz "    movsd %u(%%rsp), %%xmm0\n"
Lbk_x64_in_st_cell_fmt:
    .asciz "    movsd %%xmm0, %u(%%rsp)\n"
Lbk_x64_in_reg_rdi:     .asciz "rdi"
Lbk_x64_in_reg_rax:     .asciz "rax"
Lbk_x64_in_reg_rcx:     .asciz "rcx"
Lbk_x64_in_reg_r8:      .asciz "r8"
Lbk_x64_in_reg_r9:      .asciz "r9"
Lbk_x64_in_reg_r10:     .asciz "r10"
Lbk_x64_in_reg_r11:     .asciz "r11"
Lbk_x64_in_scell_reg_fmt:
    .asciz "    leaq .Lbsk_scells+%u(%%rip), %%%s\n"
Lbk_x64_in_leaq_rbx_reg:
    .asciz "    leaq %u(%%rbx), %%%s\n"
Lbk_x64_in_ld_rax_cell:
    .asciz "    movq %u(%%rsp), %%rax\n"
Lbk_x64_in_jeof_fmt:
    .ascii "    testl %%eax, %%eax\n"
    .asciz "    jne %B%u\n"
Lbk_x64_in_rt_saref2:   .asciz "bsk_saref2"
Lbk_x64_in_rt_str:      .asciz "bsk_str"
Lbk_x64_in_rt_len:      .asciz "bsk_len"
Lbk_x64_in_rt_asc:      .asciz "bsk_asc"
Lbk_x64_in_rt_val:      .asciz "bsk_val"
Lbk_x64_in_rt_fsel:     .asciz "bsk_fsel"
Lbk_x64_in_rt_feof:     .asciz "bsk_feof"
Lbk_x64_in_rt_scratch:  .asciz "bsk_scratch"
Lbk_x64_in_rt_frestore: .asciz "bsk_frestore"

// runtime entry points (DESIGN.md 6.4.2 ELF names)
Lbk_x64_in_rt_saref1:   .asciz "bsk_saref1"
Lbk_x64_in_rt_str_set:  .asciz "bsk_str_set"
Lbk_x64_in_rt_str_cmp:  .asciz "bsk_str_cmp"
Lbk_x64_in_rt_print_sv: .asciz "bsk_print_sv"
Lbk_x64_in_rt_print_tab: .asciz "bsk_print_tab"
Lbk_x64_in_rt_sread:    .asciz "bsk_sread"
Lbk_x64_in_rt_sread_el: .asciz "bsk_sread_el"
Lbk_x64_in_rt_input_begin: .asciz "bsk_input_begin"
Lbk_x64_in_rt_input_num: .asciz "bsk_input_num"
Lbk_x64_in_rt_input_str: .asciz "bsk_input_str"
Lbk_x64_in_rt_input_str_el: .asciz "bsk_input_str_el"
Lbk_x64_in_rt_linput: .asciz "bsk_linput"
Lbk_x64_in_rt_linput_el: .asciz "bsk_linput_el"
Lbk_x64_in_rt_exit: .asciz "bsk_exit"
Lbk_x64_in_rt_input_end: .asciz "bsk_input_end"
Lbk_x64_in_rt_mat_input: .asciz "bsk_mat_input"
Lbk_x64_in_rt_smat_input: .asciz "bsk_smat_input"
Lbk_x64_in_rt_smat_read: .asciz "bsk_smat_read"
Lbk_x64_in_rt_change_s2n: .asciz "bsk_change_s2n"
Lbk_x64_in_rt_change_n2s: .asciz "bsk_change_n2s"
Lbk_x64_in_rt_change_n2s_el: .asciz "bsk_change_n2s_el"
Lbk_x64_in_rt_randomize: .asciz "bsk_randomize"
Lbk_x64_in_rt_sgn:      .asciz "bsk_sgn"
Lbk_x64_in_rt_cot:      .asciz "bsk_cot"
Lbk_x64_in_rt_num:      .asciz "bsk_num"
Lbk_x64_in_rt_det:      .asciz "bsk_det"
Lbk_x64_in_jl:          .asciz "jl"
Lbk_x64_in_jle:         .asciz "jle"
Lbk_x64_in_jg:          .asciz "jg"
Lbk_x64_in_jge:         .asciz "jge"
Lbk_x64_in_rt_div:      .asciz "bsk_div"
Lbk_x64_in_rt_pow:      .asciz "bsk_pow"
Lbk_x64_in_rt_rnd:      .asciz "bsk_rnd"
Lbk_x64_in_rt_aref1:    .asciz "bsk_aref1"
Lbk_x64_in_rt_aref2:    .asciz "bsk_aref2"
Lbk_x64_in_rt_read:     .asciz "bsk_read"
Lbk_x64_in_rt_prnum:    .asciz "bsk_print_num"
Lbk_x64_in_rt_prcomma:  .asciz "bsk_print_comma"
Lbk_x64_in_rt_prsemi:   .asciz "bsk_print_semi"
Lbk_x64_in_rt_prnl:     .asciz "bsk_print_nl"
Lbk_x64_in_rt_end:      .asciz "bsk_end"
Lbk_x64_in_rt_sin:      .asciz "bsk_sin"
Lbk_x64_in_rt_cos:      .asciz "bsk_cos"
Lbk_x64_in_rt_tan:      .asciz "bsk_tan"
Lbk_x64_in_rt_atn:      .asciz "bsk_atn"
Lbk_x64_in_rt_exp:      .asciz "bsk_exp"
Lbk_x64_in_rt_abs:      .asciz "bsk_abs"
Lbk_x64_in_rt_log:      .asciz "bsk_log"
Lbk_x64_in_rt_sqr:      .asciz "bsk_sqr"
Lbk_x64_in_rt_int:      .asciz "bsk_int"
Lbk_x64_in_rt_mat_redim1: .asciz "bsk_mat_redim1"
Lbk_x64_in_rt_mat_redim2: .asciz "bsk_mat_redim2"
Lbk_x64_in_rt_mat_read: .asciz "bsk_mat_read"
Lbk_x64_in_rt_mat_zer:  .asciz "bsk_mat_zer"
Lbk_x64_in_rt_mat_con:  .asciz "bsk_mat_con"
Lbk_x64_in_rt_mat_idn:  .asciz "bsk_mat_idn"
Lbk_x64_in_rt_mat_copy: .asciz "bsk_mat_copy"
Lbk_x64_in_rt_mat_add:  .asciz "bsk_mat_add"
Lbk_x64_in_rt_mat_sub:  .asciz "bsk_mat_sub"
Lbk_x64_in_rt_mat_mul:  .asciz "bsk_mat_mul"
Lbk_x64_in_rt_mat_scale: .asciz "bsk_mat_scale"
Lbk_x64_in_rt_mat_trn:  .asciz "bsk_mat_trn"
Lbk_x64_in_rt_mat_inv:  .asciz "bsk_mat_inv"
Lbk_x64_in_addsd:       .asciz "addsd"
Lbk_x64_in_subsd:       .asciz "subsd"
Lbk_x64_in_mulsd:       .asciz "mulsd"
Lbk_x64_in_ucomisd:     .asciz "ucomisd"
Lbk_x64_in_je:          .asciz "je"
Lbk_x64_in_jne:         .asciz "jne"
Lbk_x64_in_jb:          .asciz "jb"
Lbk_x64_in_jbe:         .asciz "jbe"
Lbk_x64_in_ja:          .asciz "ja"
Lbk_x64_in_jae:         .asciz "jae"

// internal-error reasons
Lbk_x64_in_err_order:   .asciz "x86_64-linux backend: temps not defined in increasing order"
Lbk_x64_in_err_op:      .asciz "x86_64-linux backend: unknown IR opcode"
Lbk_x64_in_err_temp:    .asciz "x86_64-linux backend: temp used outside its line segment"
Lbk_x64_in_err_line:    .asciz "x86_64-linux backend: line number out of range"
Lbk_x64_in_err_letter:  .asciz "x86_64-linux backend: bad array or function letter"
Lbk_x64_in_err_place:   .asciz "x86_64-linux backend: param/ret outside an FN function"
Lbk_x64_in_err_rel:     .asciz "x86_64-linux backend: bad relation code"
Lbk_x64_in_err_label:   .asciz "x86_64-linux backend: bad label id"
Lbk_x64_in_err_string:  .asciz "x86_64-linux backend: bad string id"
Lbk_x64_in_err_slot:    .asciz "x86_64-linux backend: bad variable slot"
Lbk_x64_in_err_mode:    .asciz "x86_64-linux backend: bad MAT PRINT mode"
Lbk_x64_in_err_param:   .asciz "x86_64-linux backend: parameter index out of range"
Lbk_x64_in_err_kind:    .asciz "x86_64-linux backend: multi-line FN opcode outside a multi-line FN function"
Lbk_x64_in_err_imm:     .asciz "x86_64-linux backend: immediate operand out of range"
Lbk_x64_in_err_frame:   .asciz "x86_64-linux backend: too many temps for a 32-bit frame"
Lbk_x64_in_err_unit:    .asciz "x86_64-linux backend: bad SUB unit index"

// ---- name tables (pointers) ---------------------------------------------
    .section __DATA,__const
    .p2align 3
// indexed by opcode - OP_ADD
Lbk_x64_in_arith_names:
    .quad Lbk_x64_in_addsd, Lbk_x64_in_subsd, Lbk_x64_in_mulsd
// indexed by opcode - OP_MATREAD (OP_MATPRINT, entry 1, has its own case)
Lbk_x64_in_mat_names:
    .quad Lbk_x64_in_rt_mat_read, 0, Lbk_x64_in_rt_mat_zer
    .quad Lbk_x64_in_rt_mat_con, Lbk_x64_in_rt_mat_idn, Lbk_x64_in_rt_mat_copy
    .quad Lbk_x64_in_rt_mat_add, Lbk_x64_in_rt_mat_sub, Lbk_x64_in_rt_mat_mul
    .quad Lbk_x64_in_rt_mat_scale, Lbk_x64_in_rt_mat_trn, Lbk_x64_in_rt_mat_inv
// indexed by opcode - OP_SIN
Lbk_x64_in_builtin_names:
    .quad Lbk_x64_in_rt_sin, Lbk_x64_in_rt_cos, Lbk_x64_in_rt_tan
    .quad Lbk_x64_in_rt_atn, Lbk_x64_in_rt_exp, Lbk_x64_in_rt_abs
    .quad Lbk_x64_in_rt_log, Lbk_x64_in_rt_sqr, Lbk_x64_in_rt_int
// indexed by relation - REL_EQ: signed jump taken when the string relation
// holds after "cmpl $0, %eax" (bsk_str_cmp returns -1 / 0 / +1)
Lbk_x64_in_sjcc_names:
    .quad Lbk_x64_in_je             // eq
    .quad Lbk_x64_in_jne            // ne
    .quad Lbk_x64_in_jl             // lt
    .quad Lbk_x64_in_jle            // le
    .quad Lbk_x64_in_jg             // gt
    .quad Lbk_x64_in_jge            // ge
// integer argument registers R(k) of a call between generated functions
Lbk_x64_in_argregs:
    .quad Lbk_x64_in_reg_rdi, Lbk_x64_in_reg_rsi, Lbk_x64_in_reg_rdx, Lbk_x64_in_reg_rcx
    .quad Lbk_x64_in_reg_r8, Lbk_x64_in_reg_r9, Lbk_x64_in_reg_r10, Lbk_x64_in_reg_r11
// indexed by opcode - OP_LEN
Lbk_x64_in_len_names:
    .quad Lbk_x64_in_rt_len, Lbk_x64_in_rt_asc, Lbk_x64_in_rt_val
// indexed by opcode - OP_SCRATCH
Lbk_x64_in_file_names:
    .quad Lbk_x64_in_rt_scratch, Lbk_x64_in_rt_frestore
// indexed by opcode - OP_SGN
Lbk_x64_in_sgn_names:
    .quad Lbk_x64_in_rt_sgn, Lbk_x64_in_rt_cot
// indexed by relation - REL_EQ: unsigned jump taken when the relation
// holds after "ucomisd B, %xmm0" (A in %xmm0)
Lbk_x64_in_jcc_names:
    .quad Lbk_x64_in_je             // eq
    .quad Lbk_x64_in_jne            // ne
    .quad Lbk_x64_in_jb             // lt
    .quad Lbk_x64_in_jbe            // le
    .quad Lbk_x64_in_ja             // gt
    .quad Lbk_x64_in_jae            // ge
.if (OP_SSEG != OP_SCAT + 1) || (OP_SUBRET != OP_SCAT + 11) || (OP_SCAT != OP_FRESTORE + 1)
    .error "x64_insn.s Sixth Edition dispatch entries assume opcodes 99..110 in contract order"
.endif
.if (SUBP_NUM == SUBP_STR) || (SUBP_ARR == SUBP_SARR)
    .error "x64_insn.s parameter lookups need distinct SUBP_* kinds"
.endif
