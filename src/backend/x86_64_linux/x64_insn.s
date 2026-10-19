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
// Temp slot s is "8*s(%rsp)", the FN argument slot "8*W(%rsp)", global
// cell x "8*x(%rbx)".
// =====================================================================
.include "baysick.inc"

// W above this would make 8*W + 16 overflow a signed 32-bit x86
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
    // ---- prologue: frame, %rbx, temp area, globals base ----------------
    // F = align16(8*W + 16) - 8: %rsp stays 16-byte aligned at calls
    lsl x9, x23, #3
    add x9, x9, #16 + 15
    and x9, x9, #~15
    sub x2, x9, #8
    FMT Lbk_x64_in_prologue
    // FN functions spill their argument (%xmm0) to 8*W(%rsp)
    cbz x25, 1f
    lsl x2, x23, #3
    FMT Lbk_x64_in_arg_save
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
    ldr w2, [x21, #IRI_X]
    ldr x3, [x21, #IRI_IMM]
    lsr x9, x3, #32
    cbnz x9, Lbk_x64_in_line_range
    FMT Lbk_x64_in_line_fmt
    // a new temp segment starts here
    mov x24, #-1
    mov x28, #0
    b Lbk_x64_in_next
Lbk_x64_in_line_range:
    FAIL Lbk_x64_in_err_line

Lbk_x64_in_op_label:
    ldr w2, [x21, #IRI_X]
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
    // %xmm0 = A; call .Lfn_<L>; store
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_x64_in_load
    ldr w2, [x21, #IRI_X]
    cmp w2, #NUM_LETTERS
    b.hs Lbk_x64_in_bad_letter
    FMT Lbk_x64_in_call_fn
    b Lbk_x64_in_store_dst

Lbk_x64_in_op_param:
    // %xmm0 = the argument slot 8*W(%rsp)
    cbz x25, Lbk_x64_in_bad_place
    lsl x2, x23, #3
    FMT Lbk_x64_in_ld_rsp
    b Lbk_x64_in_store_dst

Lbk_x64_in_op_ret:
    // %xmm0 = A, then the epilogue
    cbz x25, Lbk_x64_in_bad_place
    ldr w0, [x21, #IRI_A]
    mov x1, #0
    bl Lbk_x64_in_load
    FMT Lbk_x64_in_epilogue
    b Lbk_x64_in_next

Lbk_x64_in_op_jmp:
    ldr w2, [x21, #IRI_X]
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
    ldrh w9, [x21, #IRI_REL]
    sub w9, w9, #REL_EQ
    adrp x10, Lbk_x64_in_jcc_names@PAGE
    add x10, x10, Lbk_x64_in_jcc_names@PAGEOFF
    ldr x2, [x10, x9, lsl #3]
    ldr w3, [x21, #IRI_X]
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
    ldr w5, [x21, #IRI_X]
    mov x6, x5
    FMT Lbk_x64_in_jfor_fmt
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

// common tail: store %xmm0 into the DST temp's slot
Lbk_x64_in_store_dst:
    ldr w0, [x21, #IRI_DST]
    bl Lbk_x64_in_def_off
    mov x2, x0
    FMT Lbk_x64_in_st_rsp
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
Lbk_x64_in_table_end:
.if (Lbk_x64_in_table_end - Lbk_x64_in_table) != 4 * OP_COUNT
    .error "x64_insn.s dispatch table does not cover OP_COUNT opcodes"
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
    .asciz "    movsd %%xmm0, %u(%%rsp)\n"
Lbk_x64_in_epilogue:
    .ascii "    movq -8(%%rbp), %%rbx\n"
    .ascii "    leave\n"
    .asciz "    ret\n"
Lbk_x64_in_label_def:
    .asciz ".Lbsk_L%u:\n"
Lbk_x64_in_line_fmt:
    .ascii ".Lbsk_L%u:\n"
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
Lbk_x64_in_ld_elem:
    .asciz "    movsd (%%rax), %%xmm0\n"
Lbk_x64_in_st_elem:
    .asciz "    movsd %%xmm0, (%%rax)\n"
Lbk_x64_in_jmp_label:
    .asciz "    jmp .Lbsk_L%u\n"
Lbk_x64_in_jcc_fmt:
    .asciz "    %s .Lbsk_L%u\n"
Lbk_x64_in_jfor_fmt:
    .ascii "    movsd %u(%%rsp), %%xmm0\n"
    .ascii "    movsd %u(%%rsp), %%xmm1\n"
    .ascii "    xorpd %%xmm2, %%xmm2\n"
    .ascii "    ucomisd %u(%%rsp), %%xmm2\n"
    .ascii "    ja 2f\n"
    .ascii "    ucomisd %%xmm1, %%xmm0\n"
    .ascii "    ja .Lbsk_L%u\n"
    .ascii "    jmp 3f\n"
    .ascii "2:\n"
    .ascii "    ucomisd %%xmm1, %%xmm0\n"
    .ascii "    jb .Lbsk_L%u\n"
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

// runtime entry points (DESIGN.md 6.4.2 ELF names)
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
Lbk_x64_in_err_frame:   .asciz "x86_64-linux backend: too many temps for a 32-bit frame"

// ---- name tables (pointers) ---------------------------------------------
    .section __DATA,__const
    .p2align 3
// indexed by opcode - OP_ADD
Lbk_x64_in_arith_names:
    .quad Lbk_x64_in_addsd, Lbk_x64_in_subsd, Lbk_x64_in_mulsd
// indexed by opcode - OP_SIN
Lbk_x64_in_builtin_names:
    .quad Lbk_x64_in_rt_sin, Lbk_x64_in_rt_cos, Lbk_x64_in_rt_tan
    .quad Lbk_x64_in_rt_atn, Lbk_x64_in_rt_exp, Lbk_x64_in_rt_abs
    .quad Lbk_x64_in_rt_log, Lbk_x64_in_rt_sqr, Lbk_x64_in_rt_int
// indexed by relation - REL_EQ: unsigned jump taken when the relation
// holds after "ucomisd B, %xmm0" (A in %xmm0)
Lbk_x64_in_jcc_names:
    .quad Lbk_x64_in_je             // eq
    .quad Lbk_x64_in_jne            // ne
    .quad Lbk_x64_in_jb             // lt
    .quad Lbk_x64_in_jbe            // le
    .quad Lbk_x64_in_ja             // gt
    .quad Lbk_x64_in_jae            // ge
