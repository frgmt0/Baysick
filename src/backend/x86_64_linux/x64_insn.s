// =====================================================================
// src/backend/x86_64_linux/x64_insn.s -- per-function and per-opcode
// code generation for the x86_64-linux backend (docs/DESIGN.md section
// 5.4.4 "Frames and temps" and 5.4.5 "Per-opcode translation").
//
// This file is arm64 code for Apple as (part of the compiler); the text
// it produces is GNU as AT&T x86_64 assembly.
//
// Exports: _bk_x64_emit_func
// Uses:    _bk_x64_fmt (x64_text.s)
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

// W above this would make 8*(W+L) + 8 (L <= 10 local cells) overflow a signed 32-bit x86
// displacement / immediate (the assembler would reject the output).
.equ BK_X64_MAX_W,  0x0FFFFFF0

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
// _bk_x64_emit_func -- emit one IR function (main as bsk_program, or FN
// letter L as .Lfn_<L>) with prologue, body and (FN) epilogue.
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
//                                  (unwind point for Lbk_x64_in_fail)
//   x27 = Function*          x28 = 1 + highest temp defined in the
//                                  current segment (0 if none)
// Frame: 96 bytes (frame record + x19-x28)
// ---------------------------------------------------------------------
    .globl _bk_x64_emit_func
    .p2align 2
_bk_x64_emit_func:
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
Lbk_x64_in_w_loop:
    cmp x11, x22
    b.hs Lbk_x64_in_w_done
    ldrh w12, [x11, #IRI_OP]
    cmp w12, #OP_LINE
    b.ne 1f
    // a `line` starts a new segment
    mov x10, #-1
    b Lbk_x64_in_w_next
1:
    ldr w12, [x11, #IRI_DST]
    cmn w12, #1                     // IR_NONE: defines nothing
    b.eq Lbk_x64_in_w_next
    // first definition of the segment fixes its base
    cmn x10, #1
    csel x10, x12, x10, eq
    cmp x12, x10
    b.lo Lbk_x64_in_w_order
    // W = max(W, t - base + 1)
    sub x13, x12, x10
    add x13, x13, #1
    cmp x13, x23
    csel x23, x13, x23, hi
Lbk_x64_in_w_next:
    add x11, x11, #IRI_SIZE
    b Lbk_x64_in_w_loop
Lbk_x64_in_w_order:
    FAIL Lbk_x64_in_err_order
Lbk_x64_in_w_done:
    // every displacement must fit a signed 32-bit field
    mov x9, #BK_X64_MAX_W
    cmp x23, x9
    b.hi Lbk_x64_in_bad_frame

    // ---- function label ------------------------------------------------
    cbnz x25, 1f
    FMT Lbk_x64_in_main_label
    b 2f
1:
    sub x2, x25, #FUNC_FN_BASE
    FMT Lbk_x64_in_fn_label
2:
    // ---- prologue: frame, %rbx, temp area, local cells, globals base ----
    // F = align16(8*(W+L) + 8) - 8: %rsp stays 16-byte aligned at calls and
    // the temps plus the L local cells fit (DESIGN.md 5.4.4)
    bl Lbk_x64_in_ncells            // x0 = L
    add x9, x23, x0
    lsl x9, x9, #3
    add x9, x9, #8 + 15
    and x9, x9, #~15
    sub x2, x9, #8
    FMT Lbk_x64_in_prologue
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
    ldp x29, x30, [sp], #96
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
    mov x2, x25
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
    mov x2, x25
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
    // %xmm0 = global cell X; store
    bl Lbk_x64_in_global_off
    mov x2, x0
    FMT Lbk_x64_in_ldv_fmt
    b Lbk_x64_in_store_dst

Lbk_x64_in_op_stv:
    // global cell X = A
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_x64_in_load
    bl Lbk_x64_in_global_off
    mov x2, x0
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
    mov x1, #0
    bl Lbk_x64_in_load
1:
    ldr w2, [x21, #IRI_X]
    cmp w2, #NUM_LETTERS
    b.hs Lbk_x64_in_bad_letter
    FMT Lbk_x64_in_call_fn
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
    mov x2, x25
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
    mov x3, x25
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
    mov x2, x25
    ldr w3, [x21, #IRI_X]
    mov x4, x25
    mov x5, x3
    FMT Lbk_x64_in_jfor_fmt2
    b Lbk_x64_in_next

Lbk_x64_in_op_gosub:
    // push the address of the return label, jump to the target
    ldr x2, [x21, #IRI_IMM]
    lsr x9, x2, #32
    cbnz x9, Lbk_x64_in_bad_label
    ldr w3, [x21, #IRI_X]
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
    ldr w9, [x20, #IRM_NSTRINGS]
    cmp w2, w9
    b.hs Lbk_x64_in_bad_string
    ldr x10, [x20, #IRM_STRINGS]
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
    ldr w9, [x20, #IRM_NSTRINGS]
    cmp w2, w9
    b.hs Lbk_x64_in_bad_string
    FMT Lbk_x64_in_slit_fmt
    b Lbk_x64_in_store_dst_rax

Lbk_x64_in_op_svar:
    // %rax = &.Lbsk_svars + 16*slot; store
    ldr w9, [x21, #IRI_X]
    cmp w9, #(NUM_LETTERS * SLOT_PER_LETTER)
    b.hs Lbk_x64_in_bad_slot
    mov x10, #SD_SIZE
    mul x2, x9, x10
    FMT Lbk_x64_in_svar_fmt
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

// common tail of the element form of sread / insv: x2 = runtime symbol;
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

// common tail of prsv / sread / insv: x2 = runtime symbol; %rdi = A; call
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
    ldr w0, [x21, #IRI_A]
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
Lbk_x64_in_table_end:
.if (Lbk_x64_in_table_end - Lbk_x64_in_table) != 4 * OP_COUNT
    .error "x64_insn.s dispatch table does not cover OP_COUNT opcodes"
.endif
.if (OP_SLIT != OP_MATINV + 1) || (OP_STFV != OP_SLIT + 29) || (OP_COT != OP_SGN + 1)
    .error "x64_insn.s dispatch table assumes the opcode order of ir.inc"
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
// Lbk_x64_in_ncells -- L, the number of 8-byte local cells of the current
// function: NP + 2 for a multi-line function (parameters, value variable,
// saved run-time line), else max(1, NP).
// Out: x0 = L.  Frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lbk_x64_in_ncells:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl Lbk_x64_in_nparams
    ldr w9, [x27, #IRF_KIND]
    cmp w9, #FUNC_KIND_FNML
    b.ne 1f
    add x0, x0, #2
    b 2f
1:
    cmp x0, #1
    mov x9, #1
    csel x0, x9, x0, lo
2:
    ldp x29, x30, [sp], #16
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
// Lbk_x64_in_cells_init -- prologue part of an FN function: spill the
// arguments (%xmm<k> -> local cell k, k < NP); a multi-line function then
// clears its value variable (cell NP) and saves the caller's run-time line
// (cell NP+1).
// Frame: 32 bytes (frame record + the loop counter)
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
    // "movsd %xmm<k>, 8*(W+k)(%rsp)"
    add x3, x23, x2
    lsl x3, x3, #3
    FMT Lbk_x64_in_arg_save
    ldr x2, [sp, #16]
    add x2, x2, #1
    str x2, [sp, #16]
    b Lbk_x64_in_ci_loop
Lbk_x64_in_ci_args_done:
    ldr w9, [x27, #IRF_KIND]
    cmp w9, #FUNC_KIND_FNML
    b.ne Lbk_x64_in_ci_done
    mov x0, #0
    bl Lbk_x64_in_cell_np
    lsl x2, x0, #3
    FMT Lbk_x64_in_fv_init          // value variable := 0
    mov x0, #1
    bl Lbk_x64_in_cell_np
    lsl x2, x0, #3
    FMT Lbk_x64_in_line_save        // saved run-time line
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
// Lbk_x64_in_sdesc_addr -- emit "    leaq .Lsdesc_<L>(%rip), %rdi" for the
// string list named by the current record's X field.
// Lbk_x64_in_sdesc_letter -- the same for the letter in w2 (the IMM of
// chgn2s's element form).
// In:  x21 = current record (sdesc_addr) / w2 = letter (sdesc_letter)
// Checks: the letter names a string list in use.
// Frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lbk_x64_in_sdesc_addr:
    ldr w2, [x21, #IRI_X]
Lbk_x64_in_sdesc_letter:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    cmp w2, #NUM_LETTERS
    b.hs Lbk_x64_in_sdesc_bad
    add x9, x20, #IRM_SARRAYS
    add x9, x9, x2, lsl #4
    ldr w9, [x9, #IRA_DIMS]
    cbz w9, Lbk_x64_in_sdesc_bad
    FMT Lbk_x64_in_sdesc_fmt
    ldp x29, x30, [sp], #16
    ret
Lbk_x64_in_sdesc_bad:
    FAIL Lbk_x64_in_err_letter

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
// Lbk_x64_in_desc_addr -- emit "    leaq .Ldesc_<L>(%rip), %rdi" for the
// array named by the current record's X field.
// In:  x21 = current record
// Checks: X is a letter of an array in use.
// Frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lbk_x64_in_desc_addr:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    ldr w2, [x21, #IRI_X]
    cmp w2, #NUM_LETTERS
    b.hs Lbk_x64_in_desc_bad
    add x9, x20, #IRM_ARRAYS
    add x9, x9, x2, lsl #4
    ldr w9, [x9, #IRA_DIMS]
    cbz w9, Lbk_x64_in_desc_bad
    FMT Lbk_x64_in_desc_fmt
    ldp x29, x30, [sp], #16
    ret
Lbk_x64_in_desc_bad:
    FAIL Lbk_x64_in_err_letter

// ---------------------------------------------------------------------
// Lbk_x64_in_desc_reg -- emit "    leaq .Ldesc_<L>(%rip), %<reg>" for an
// array letter held in an operand field.
// In:  w0 = array letter, x1 = register name ("rsi", "rdx")
// Checks: the letter names an array in use.
// Frame: 16 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lbk_x64_in_desc_reg:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x3, x1
    mov w2, w0
    cmp w2, #NUM_LETTERS
    b.hs Lbk_x64_in_desc_bad
    add x9, x20, #IRM_ARRAYS
    add x9, x9, x2, lsl #4
    ldr w9, [x9, #IRA_DIMS]
    cbz w9, Lbk_x64_in_desc_bad
    FMT Lbk_x64_in_desc_reg_fmt
    ldp x29, x30, [sp], #16
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
    .ascii "    subq $%u, %%rsp\n"
    .asciz "    leaq .Lbsk_vars(%%rip), %%rbx\n"
Lbk_x64_in_arg_save:
    .asciz "    movsd %%xmm%u, %u(%%rsp)\n"
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
Lbk_x64_in_desc_fmt:
    .asciz "    leaq .Ldesc_%L(%%rip), %%rdi\n"
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
    .ascii "    leaq .Lbsk_L%u(%%rip), %%rdi\n"
    .ascii "    call bsk_gosub_push\n"
    .asciz "    jmp .Lbsk_L%u\n"
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
Lbk_x64_in_sdesc_fmt:
    .asciz "    leaq .Lsdesc_%L(%%rip), %%rdi\n"
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
