// =====================================================================
// src/frontend/fe_compile.s -- frontend entry point and shared state.
//
//   _fe_compile(x0=src, x1=len, x2=Module*) -> x0 = ERR_* (0 ok), x1 = line
//
// Pipeline (docs/DESIGN.md section 1, LANGUAGE.md section 10.1):
//   phase 1  _fe_lines_read: physical lines, compaction, line numbers,
//            replace/delete, sort                       (fe_lines.s)
//   pre-scan _fe_prescan: which lines form multi-line DEF bodies; the
//            line labels of main, then each multi-line function is
//            created with the labels of its body (IR.md 4.1, fe_def.s)
//   phase 2  per program line, ascending: switch to the function that
//            owns it, one `line` instruction, then the statement
//            parse/lowering                            (fe_stmt.s ...)
//   phase 3  whole-program checks in LANGUAGE.md 10.1 order (UNFINISHED
//            DEF, FOR WITHOUT NEXT, NO END, NO DATA, NO STRING DATA,
//            UNDEFINED NUMBER, ILLEGAL TRANSFER, then the function checks
//            of fe_def.s), then letters named only by MAT statements
//            become 10 x 10 tables and the module's FOR count, array and
//            string-list tables are filled in.
//   Sixth Edition: the pre-scan also partitions the lines into program
//            units (fe_sub.s); phase 2 switches the per-unit state when
//            a line of another unit comes; phase 3 adds UNFINISHED SUB
//            after UNFINISHED DEF, runs the function checks over every
//            unit, then the CALL checks, and publishes every unit.
//
// Errors: every frontend function may call _fe_err / _fe_fail, which
// record (code, line) and unwind straight back into _fe_compile by
// restoring the stack pointer saved on entry (a private setjmp/longjmp).
// _fe_compile saved every callee-saved register in its own frame, so the
// abandoned frames need no cleanup; frontend functions hold no resources.
//
// This file also owns all frontend-global state (zero-filled .bss
// symbols named _fe_*), reset at the start of every _fe_compile call, and
// the IR emission helpers _fe_emit / _fe_emit_new / _fe_new_label.
// =====================================================================
.include "baysick.inc"

// Size of one FOR-stack entry (u32 var slot, u32 FOR index k,
// u32 label B, u32 label X). Frontend-private; also used by fe_stmt.s,
// which documents the same layout.
.equ FE_FOR_ENTRY,      16
// One sorted-line entry in _fe_lines: u32 line number, u32 text length,
// u64 pointer to the compacted statement text (after the line number).
.equ FE_LINE_ENTRY,     16
// One frontend array-state entry: u32 dims, u32 b1, u32 b2, u32 flags.
// The same layout is used for the string lists (_fe_sarrays, b2 = 0).
.equ FE_ARR_ENTRY,      16
// Per-letter call records: first line of a call with 0..8 arguments, and
// (index 9) with more than eight (fe_def.s).
.equ FE_ARGC_SLOTS,     10

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _fe_compile -- compile a BASIC source buffer into an IR module.
//   in:  x0 = source bytes, x1 = source length, x2 = Module* (fresh,
//        from _ir_module_new)
//   out: x0 = ERR_* code (ERR_NONE on success), x1 = BASIC line number
//        for the message or 0 when the message has no line number
//   clobbers: x0-x17, d0-d7, d16-d31
//   callee-saved: all of x19-x28 and d8-d15 are saved here (so that an
//        error unwinding from any depth can restore them):
//        x19 = module, x20 = sorted-line table cursor, x21 = line count,
//        x22 = line index i, x23 = main Function*
//   frame: 160 bytes (frame record, x19-x28, d8-d15)
// ---------------------------------------------------------------------
    .globl _fe_compile
    .p2align 2
_fe_compile:
    stp x29, x30, [sp, #-160]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    stp d8, d9, [sp, #96]
    stp d10, d11, [sp, #112]
    stp d12, d13, [sp, #128]
    stp d14, d15, [sp, #144]
    // keep the inputs across the state reset
    mov x24, x0                         // source bytes
    mov x25, x1                         // source length
    mov x19, x2                         // module
    // remember where to unwind to on a BASIC compile error
    mov x9, sp
    adrp x10, _fe_unwind_sp@PAGE
    str x9, [x10, _fe_unwind_sp@PAGEOFF]
    bl Lfe_compile_reset
    adrp x9, _fe_module@PAGE
    str x19, [x9, _fe_module@PAGEOFF]
    // the main program is the current program unit (fe_sub.s)
    adrp x9, _fe_unit@PAGE
    str x19, [x9, _fe_unit@PAGEOFF]

    // ---- phase 1: reading -------------------------------------------
    // a file over the size limit is rejected before looking at any line
    mov x9, #LIM_SOURCE_BYTES
    cmp x25, x9
    b.ls 1f
    mov w0, #ERR_PROGRAM_TOO_LONG
    mov w1, #0
    bl _fe_fail
1:
    mov x0, x24
    mov x1, x25
    bl _fe_lines_read                   // fills _fe_lines / _fe_nlines

    // ---- main function; multi-line bodies and line labels (IR.md 4.1)
    mov x0, x19
    mov w1, #FUNC_MAIN
    mov w2, #IR_NONE
    mov w3, #0
    bl _ir_func_begin
    mov x23, x0
    adrp x9, _fe_main@PAGE
    str x23, [x9, _fe_main@PAGEOFF]
    adrp x9, _fe_curfn@PAGE
    str x23, [x9, _fe_curfn@PAGEOFF]
    bl _fe_prescan
    adrp x9, _fe_nlines@PAGE
    ldr w21, [x9, _fe_nlines@PAGEOFF]
    adrp x9, _fe_lines@PAGE
    ldr x20, [x9, _fe_lines@PAGEOFF]

    // ---- phase 2: statements in ascending line order ---------------
    mov w22, #0
Lfe_compile_stmt_loop:
    cmp w22, w21
    b.hs Lfe_compile_stmt_done
    add x10, x20, x22, lsl #4           // &lines[i]
    ldr w11, [x10]                      // line number
    ldr w12, [x10, #4]                  // statement text length
    ldr x13, [x10, #8]                  // statement text
    // publish the current line for errors and the scanner window
    adrp x9, _fe_line@PAGE
    str w11, [x9, _fe_line@PAGEOFF]
    adrp x9, _fe_lineidx@PAGE
    str w22, [x9, _fe_lineidx@PAGEOFF]
    adrp x9, _fe_pos@PAGE
    str x13, [x9, _fe_pos@PAGEOFF]
    add x13, x13, x12
    adrp x9, _fe_end@PAGE
    str x13, [x9, _fe_end@PAGEOFF]
    // the function owning this line becomes current; w0 = its label id
    mov w0, w22
    bl _fe_enter_line
    mov w4, w0                          // X = line label id
    // every line starts with `line <n>`, defining that label
    add x10, x20, x22, lsl #4
    ldr w5, [x10]                       // IMM = BASIC line number
    mov w0, #OP_LINE
    mov w1, #IR_NONE
    mov w2, #IR_NONE
    mov w3, #IR_NONE
    mov w6, #REL_NONE
    bl _fe_emit
    bl _fe_stmt
    add w22, w22, #1
    b Lfe_compile_stmt_loop
Lfe_compile_stmt_done:

    // ---- phase 3: whole-program checks, in LANGUAGE.md 10.1 order ---
    // UNFINISHED DEF: a multi-line DEF still open after the last line
    // (pre-scan: its DEF line), then UNFINISHED SUB: a SUB block still
    // open after the last line (its SUB line)
    adrp x9, _fe_eof_def_line@PAGE
    ldr w1, [x9, _fe_eof_def_line@PAGEOFF]
    cbz w1, 1f
    mov w0, #ERR_UNFINISHED_DEF
    bl _fe_fail
1:
    adrp x9, _fe_eof_sub_line@PAGE
    ldr w1, [x9, _fe_eof_sub_line@PAGEOFF]
    cbz w1, 1f
    mov w0, #ERR_UNFINISHED_SUB
    bl _fe_fail
1:
    // FOR WITHOUT NEXT: an unclosed FOR remains on the stack
    adrp x9, _fe_forsp@PAGE
    ldr w9, [x9, _fe_forsp@PAGEOFF]
    cbz w9, 1f
    mov w0, #ERR_FOR_WITHOUT_NEXT
    mov w1, #0
    bl _fe_fail
1:
    // NO END INSTRUCTION
    adrp x9, _fe_has_end@PAGE
    ldr w9, [x9, _fe_has_end@PAGEOFF]
    cbnz w9, 1f
    mov w0, #ERR_NO_END
    mov w1, #0
    bl _fe_fail
1:
    // NO DATA: a numeric READ target exists but the numeric block is empty
    adrp x9, _fe_has_read@PAGE
    ldr w9, [x9, _fe_has_read@PAGEOFF]
    cbz w9, 1f
    adrp x9, _fe_ndata@PAGE
    ldr w9, [x9, _fe_ndata@PAGEOFF]
    cbnz w9, 1f
    mov w0, #ERR_NO_DATA
    mov w1, #0
    bl _fe_fail
1:
    // NO STRING DATA: likewise for string targets and the string block
    adrp x9, _fe_has_sread@PAGE
    ldr w9, [x9, _fe_has_sread@PAGEOFF]
    cbz w9, 1f
    adrp x9, _fe_nsdata@PAGE
    ldr w9, [x9, _fe_nsdata@PAGEOFF]
    cbnz w9, 1f
    mov w0, #ERR_NO_STRING_DATA
    mov w1, #0
    bl _fe_fail
1:
    // UNDEFINED NUMBER: first jump to a missing line (ascending order)
    adrp x9, _fe_undef_line@PAGE
    ldr w1, [x9, _fe_undef_line@PAGEOFF]
    cbz w1, 1f
    mov w0, #ERR_UNDEFINED_NUMBER
    bl _fe_fail
1:
    // ILLEGAL TRANSFER: first jump into or out of a multi-line DEF body
    adrp x9, _fe_xfer_line@PAGE
    ldr w1, [x9, _fe_xfer_line@PAGEOFF]
    cbz w1, 1f
    mov w0, #ERR_ILLEGAL_TRANSFER
    bl _fe_fail
1:
    // UNDEFINED FUNCTION, INCORRECT NUMBER OF ARGUMENTS, MISMATCHED STRING
    // OPERATION, RECURSIVE FUNCTION over every program unit, then the
    // CALL checks (fe_sub.s)
    bl _fe_sub_check_fns
    bl _fe_sub_check_calls
    // every unit's default shapes, FOR count and array tables
    bl _fe_sub_publish_all
    mov x0, #ERR_NONE
    mov x1, #0
    b Lfe_compile_return

    // ---- letters named only by MAT statements are 10 x 10 tables -----
    bl _fe_mat_finish

    // ---- success: publish FOR count and the array table -------------
    mov x0, x19
    adrp x9, _fe_nfors@PAGE
    ldr w1, [x9, _fe_nfors@PAGEOFF]
    bl _ir_set_fors
    adrp x20, _fe_arrays@PAGE
    add x20, x20, _fe_arrays@PAGEOFF
    mov w22, #0                         // letter
Lfe_compile_arr_loop:
    cmp w22, #NUM_LETTERS
    b.hs Lfe_compile_arr_done
    add x10, x20, x22, lsl #4           // &arrays[letter]
    ldr w2, [x10]                       // dims (0 = unused)
    cbz w2, 1f
    ldr w3, [x10, #4]                   // b1
    ldr w4, [x10, #8]                   // b2
    ldr w5, [x10, #12]                  // flags
    mov x0, x19
    mov w1, w22
    bl _ir_set_array
1:
    add w22, w22, #1
    b Lfe_compile_arr_loop
Lfe_compile_arr_done:
    // ... and the string lists A$( ) .. Z$( ) that the program uses
    adrp x20, _fe_sarrays@PAGE
    add x20, x20, _fe_sarrays@PAGEOFF
    mov w22, #0                         // letter
Lfe_compile_sarr_loop:
    cmp w22, #NUM_LETTERS
    b.hs Lfe_compile_sarr_done
    add x10, x20, x22, lsl #4           // &sarrays[letter]
    ldr w9, [x10]                       // dims (0 = unused, 1 = list, 2 = table)
    cbz w9, 1f
    cmp w9, #2
    b.ne 2f
    // a string table (Fifth Edition): b1, b2, flags
    ldr w2, [x10, #4]
    ldr w3, [x10, #8]
    ldr w4, [x10, #12]
    mov x0, x19
    mov w1, w22
    bl _ir_set_sarray2
    b 1f
2:
    ldr w2, [x10, #4]                   // b1
    ldr w3, [x10, #12]                  // flags
    mov x0, x19
    mov w1, w22
    bl _ir_set_sarray
1:
    add w22, w22, #1
    b Lfe_compile_sarr_loop
Lfe_compile_sarr_done:
    mov x0, #ERR_NONE
    mov x1, #0
    b Lfe_compile_return

// Error exit: reached from _fe_fail with sp restored to this frame.
Lfe_compile_error_exit:
    adrp x9, _fe_err_code@PAGE
    ldr w0, [x9, _fe_err_code@PAGEOFF]
    adrp x9, _fe_err_line@PAGE
    ldr w1, [x9, _fe_err_line@PAGEOFF]
Lfe_compile_return:
    ldp d14, d15, [sp, #144]
    ldp d12, d13, [sp, #128]
    ldp d10, d11, [sp, #112]
    ldp d8, d9, [sp, #96]
    ldp x27, x28, [sp, #80]
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #160
    ret

// ---------------------------------------------------------------------
// Lfe_compile_reset -- zero every frontend-global state variable.
//   Walks Lfe_compile_state_tab (pairs: address, size) and bzero()s each.
//   in: none   out: none
//   clobbers: x0-x17
//   callee-saved: x19 = table cursor, x20 = table end
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lfe_compile_reset:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    adrp x19, Lfe_compile_state_tab@PAGE
    add x19, x19, Lfe_compile_state_tab@PAGEOFF
    adrp x20, Lfe_compile_state_tab_end@PAGE
    add x20, x20, Lfe_compile_state_tab_end@PAGEOFF
Lfe_compile_reset_loop:
    cmp x19, x20
    b.hs Lfe_compile_reset_done
    ldp x0, x1, [x19], #16              // address, size
    bl _bzero
    b Lfe_compile_reset_loop
Lfe_compile_reset_done:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _fe_fail -- record a BASIC compile error and unwind to _fe_compile.
//   in:  w0 = ERR_* code, w1 = line number for the message (0 = none)
//   out: does not return; _fe_compile returns (w0, w1) to its caller
//   clobbers: everything except what _fe_compile restores
//   callee-saved: none (they are restored from _fe_compile's frame)
//   frame: none (abandons the current stack)
// ---------------------------------------------------------------------
    .globl _fe_fail
    .p2align 2
_fe_fail:
    adrp x9, _fe_err_code@PAGE
    str w0, [x9, _fe_err_code@PAGEOFF]
    adrp x9, _fe_err_line@PAGE
    str w1, [x9, _fe_err_line@PAGEOFF]
    // back to _fe_compile's frame: sp as it was right after its prologue
    adrp x9, _fe_unwind_sp@PAGE
    ldr x9, [x9, _fe_unwind_sp@PAGEOFF]
    mov sp, x9
    mov x29, x9
    b Lfe_compile_error_exit

// ---------------------------------------------------------------------
// _fe_err -- compile error at the line currently being compiled.
//   in:  w0 = ERR_* code
//   out: does not return (see _fe_fail)
//   clobbers / callee-saved / frame: as _fe_fail
// ---------------------------------------------------------------------
    .globl _fe_err
    .p2align 2
_fe_err:
    adrp x9, _fe_line@PAGE
    ldr w1, [x9, _fe_line@PAGEOFF]
    b _fe_fail

// ---------------------------------------------------------------------
// _fe_emit -- append one instruction with no destination temp to the
//   current function (_fe_curfn).
//   in:  w0 = opcode, w1 = A, w2 = B, w3 = C, w4 = X (IR_NONE if unused),
//        x5 = IMM (0 if unused), w6 = REL (REL_NONE if unused)
//   out: none
//   clobbers: x0-x17
//   callee-saved: none used
//   frame: 48 bytes (frame record + 32-byte IRI record at sp+16)
// ---------------------------------------------------------------------
    .globl _fe_emit
    .p2align 2
_fe_emit:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    // build the 32-byte record on the stack
    strh w0, [sp, #(16 + IRI_OP)]
    strh w6, [sp, #(16 + IRI_REL)]
    mov w9, #IR_NONE
    str w9, [sp, #(16 + IRI_DST)]
    str w1, [sp, #(16 + IRI_A)]
    str w2, [sp, #(16 + IRI_B)]
    str w3, [sp, #(16 + IRI_C)]
    str w4, [sp, #(16 + IRI_X)]
    str x5, [sp, #(16 + IRI_IMM)]
    // hand it to the builder, which copies it
    adrp x9, _fe_curfn@PAGE
    ldr x0, [x9, _fe_curfn@PAGEOFF]
    add x1, sp, #16
    bl _ir_emit
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// _fe_emit_new -- allocate a new temp in the current function and append
//   one instruction defining it (DST = the new temp).
//   in:  as _fe_emit (w0 op, w1 A, w2 B, w3 C, w4 X, x5 IMM, w6 REL)
//   out: w0 = the new temp number
//   clobbers: x0-x17
//   callee-saved: x19 = new temp number
//   frame: 64 bytes (frame record, x19, 32-byte IRI record at sp+16)
// ---------------------------------------------------------------------
    .globl _fe_emit_new
    .p2align 2
_fe_emit_new:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    str x19, [sp, #48]
    // stash the operands in the record before calling the builder
    strh w0, [sp, #(16 + IRI_OP)]
    strh w6, [sp, #(16 + IRI_REL)]
    str w1, [sp, #(16 + IRI_A)]
    str w2, [sp, #(16 + IRI_B)]
    str w3, [sp, #(16 + IRI_C)]
    str w4, [sp, #(16 + IRI_X)]
    str x5, [sp, #(16 + IRI_IMM)]
    // the temp is numbered at the moment its defining instruction is emitted
    adrp x9, _fe_curfn@PAGE
    ldr x0, [x9, _fe_curfn@PAGEOFF]
    bl _ir_new_temp
    mov w19, w0
    str w19, [sp, #(16 + IRI_DST)]
    adrp x9, _fe_curfn@PAGE
    ldr x0, [x9, _fe_curfn@PAGEOFF]
    add x1, sp, #16
    bl _ir_emit
    mov w0, w19
    ldr x19, [sp, #48]
    ldp x29, x30, [sp], #64
    ret

// ---------------------------------------------------------------------
// _fe_new_label -- allocate an internal label in the current function
//   (main or the multi-line function being lowered, IR.md 4.1).
//   in:  none   out: w0 = new label id
//   clobbers: x0-x17
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .globl _fe_new_label
    .p2align 2
_fe_new_label:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x9, _fe_curfn@PAGE
    ldr x0, [x9, _fe_curfn@PAGEOFF]
    mov w1, #0                          // 0 = internal (not a line label)
    bl _ir_new_label
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Table of every resettable state variable: .quad address, size.
// ---------------------------------------------------------------------
    .section __DATA,__const
    .p2align 3
Lfe_compile_state_tab:
    .quad _fe_pos, 8
    .quad _fe_end, 8
    .quad _fe_module, 8
    .quad _fe_main, 8
    .quad _fe_curfn, 8
    .quad _fe_lines, 8
    .quad _fe_nlines, 8
    .quad _fe_line, 8
    .quad _fe_lineidx, 8
    .quad _fe_depth, 8
    .quad _fe_linefn, 8
    .quad _fe_linelab, 8
    .quad _fe_curowner, 8
    .quad _fe_ctx_kind, 8
    .quad _fe_ctx_letter, 8
    .quad _fe_ctx_nparams, 8
    .quad _fe_ctx_params, LIM_FN_PARAMS * 4
    .quad _fe_arrays, NUM_LETTERS * FE_ARR_ENTRY
    .quad _fe_sarrays, NUM_LETTERS * FE_ARR_ENTRY
    .quad _fe_fn_defline, NUM_LETTERS * 4
    .quad _fe_fn_ref, NUM_LETTERS * 4
    .quad _fe_fn_calls, NUM_LETTERS * 4
    .quad _fe_fn_nparams, NUM_LETTERS * 4
    .quad _fe_fn_argline, NUM_LETTERS * FE_ARGC_SLOTS * 4
    .quad _fe_ml_fn, NUM_LETTERS * 8
    .quad _fe_ml_defline, NUM_LETTERS * 4
    .quad _fe_ml_defidx, NUM_LETTERS * 4
    .quad _fe_ml_endidx, NUM_LETTERS * 4
    .quad _fe_ml_nparams, NUM_LETTERS * 4
    .quad _fe_ml_params, NUM_LETTERS * LIM_FN_PARAMS * 4
    .quad _fe_ml_order, NUM_LETTERS * 4
    .quad _fe_ml_count, 8
    .quad _fe_ml_open, 8
    .quad _fe_pre_seen, 8
    .quad _fe_nfors, 8
    .quad _fe_forsp, 8
    .quad _fe_forbase, 8
    .quad _fe_forstack, LIM_FORS * FE_FOR_ENTRY
    .quad _fe_strbytes, 8
    .quad _fe_ndata, 8
    .quad _fe_nsdata, 8
    .quad _fe_has_read, 8
    .quad _fe_has_sread, 8
    .quad _fe_has_end, 8
    .quad _fe_undef_line, 8
    .quad _fe_xfer_line, 8
    .quad _fe_mat_names, 8
    .quad _fe_ctx_skinds, 8
    .quad _fe_ml_kinds, NUM_LETTERS * 4
    .quad _fe_fn_kinds, NUM_LETTERS * 4
    .quad _fe_smat_names, 8
    .quad _fe_nfiles, 8
    .quad _fe_cur_file, 8
    .quad _fe_calllog, 8
    .quad _fe_ncalls, 8
    .quad _fe_capcalls, 8
    .quad _fe_unit, 8
    .quad _fe_curunit, 8
    .quad _fe_units, 8
    .quad _fe_nunits, 8
    .quad _fe_lineunit, 8
    .quad _fe_mainsave, 8
    .quad _fe_unitforbase, 8
    .quad _fe_totalfors, 8
    .quad _fe_eof_def_line, 8
    .quad _fe_eof_sub_line, 8
    .quad _fe_sublog, 8
    .quad _fe_nsublog, 8
    .quad _fe_capsublog, 8
    .quad _fe_err_code, 8
    .quad _fe_err_line, 8
Lfe_compile_state_tab_end:

// ---------------------------------------------------------------------
// Frontend-global state (zero-filled; reset by Lfe_compile_reset).
// ---------------------------------------------------------------------
    .globl _fe_pos, _fe_end, _fe_module, _fe_main, _fe_curfn
    .globl _fe_lines, _fe_nlines, _fe_line, _fe_lineidx, _fe_depth
    .globl _fe_linefn, _fe_linelab, _fe_curowner
    .globl _fe_ctx_kind, _fe_ctx_letter, _fe_ctx_nparams, _fe_ctx_params
    .globl _fe_arrays, _fe_sarrays
    .globl _fe_fn_defline, _fe_fn_ref, _fe_fn_calls, _fe_fn_nparams
    .globl _fe_fn_argline
    .globl _fe_ml_fn, _fe_ml_defline, _fe_ml_defidx, _fe_ml_endidx
    .globl _fe_ml_nparams, _fe_ml_params, _fe_ml_order, _fe_ml_count
    .globl _fe_ml_open, _fe_pre_seen
    .globl _fe_nfors, _fe_forsp, _fe_forbase, _fe_forstack
    .globl _fe_strbytes, _fe_ndata, _fe_nsdata, _fe_has_read, _fe_has_sread
    .globl _fe_has_end, _fe_undef_line, _fe_xfer_line, _fe_mat_names
    .globl _fe_ctx_skinds, _fe_ml_kinds, _fe_fn_kinds, _fe_smat_names
    .globl _fe_nfiles, _fe_cur_file, _fe_calllog, _fe_ncalls, _fe_capcalls
// scanner window over the current line's compacted statement text
.zerofill __DATA,__bss,_fe_pos,8,3          // ptr: next byte to scan
.zerofill __DATA,__bss,_fe_end,8,3          // ptr: one past the last byte
// IR targets
.zerofill __DATA,__bss,_fe_module,8,3       // Module*
.zerofill __DATA,__bss,_fe_main,8,3         // Function* of main
.zerofill __DATA,__bss,_fe_curfn,8,3        // Function* receiving emitted code
// program lines (phase 1 result) and their owners (pre-scan result)
.zerofill __DATA,__bss,_fe_lines,8,3        // ptr to FE_LINE_ENTRY[nlines], ascending
.zerofill __DATA,__bss,_fe_nlines,8,3       // u32 number of program lines
.zerofill __DATA,__bss,_fe_line,8,3         // u32 line number being compiled
.zerofill __DATA,__bss,_fe_lineidx,8,3      // u32 its index in _fe_lines
.zerofill __DATA,__bss,_fe_linefn,8,3       // ptr to u32[nlines]: owner (0 main, 1+letter)
.zerofill __DATA,__bss,_fe_linelab,8,3      // ptr to u32[nlines]: line label id in the owner
.zerofill __DATA,__bss,_fe_curowner,8,3     // u32 owner of the line being compiled
// expression parsing
.zerofill __DATA,__bss,_fe_depth,8,3        // u32 open '(' count in this statement
// DEF context: kind (FE_CTX_* of fe_def.s: 0 none, 1 single-line DEF
// expression, 2 multi-line body), its letter, parameters (scalar slots)
.zerofill __DATA,__bss,_fe_ctx_kind,8,3
.zerofill __DATA,__bss,_fe_ctx_letter,8,3
.zerofill __DATA,__bss,_fe_ctx_nparams,8,3
.zerofill __DATA,__bss,_fe_ctx_params,LIM_FN_PARAMS*4,3
// arrays and string lists: per letter u32 dims, b1, b2, flags (IRA_FLAG_DIMMED)
.zerofill __DATA,__bss,_fe_arrays,NUM_LETTERS*FE_ARR_ENTRY,3
.zerofill __DATA,__bss,_fe_sarrays,NUM_LETTERS*FE_ARR_ENTRY,3
// functions: per letter DEF line (0 = none), first reference line, callee
// mask, parameter count, first line of a call per argument count
.zerofill __DATA,__bss,_fe_fn_defline,NUM_LETTERS*4,3
.zerofill __DATA,__bss,_fe_fn_ref,NUM_LETTERS*4,3
.zerofill __DATA,__bss,_fe_fn_calls,NUM_LETTERS*4,3
.zerofill __DATA,__bss,_fe_fn_nparams,NUM_LETTERS*4,3
.zerofill __DATA,__bss,_fe_fn_argline,NUM_LETTERS*FE_ARGC_SLOTS*4,3
// multi-line functions found by the pre-scan (per letter): Function*, DEF
// line, DEF line index, FNEND line index, parameters; letters in DEF order
.zerofill __DATA,__bss,_fe_ml_fn,NUM_LETTERS*8,3
.zerofill __DATA,__bss,_fe_ml_defline,NUM_LETTERS*4,3
.zerofill __DATA,__bss,_fe_ml_defidx,NUM_LETTERS*4,3
.zerofill __DATA,__bss,_fe_ml_endidx,NUM_LETTERS*4,3
.zerofill __DATA,__bss,_fe_ml_nparams,NUM_LETTERS*4,3
.zerofill __DATA,__bss,_fe_ml_params,NUM_LETTERS*LIM_FN_PARAMS*4,3
.zerofill __DATA,__bss,_fe_ml_order,NUM_LETTERS*4,3
.zerofill __DATA,__bss,_fe_ml_count,8,3     // u32 entries in _fe_ml_order
.zerofill __DATA,__bss,_fe_ml_open,8,3      // u32 1+letter of a body never closed
.zerofill __DATA,__bss,_fe_pre_seen,8,3     // u32 letters DEFined in main (pre-scan)
// FOR/NEXT matching
.zerofill __DATA,__bss,_fe_nfors,8,3        // u32 FOR statements seen (next k)
.zerofill __DATA,__bss,_fe_forsp,8,3        // u32 open FORs on the stack
.zerofill __DATA,__bss,_fe_forbase,8,3      // u32 stack depth where this body's FORs start
.zerofill __DATA,__bss,_fe_forstack,LIM_FORS*FE_FOR_ENTRY,3
// counters and flags for limits and phase-3 checks
.zerofill __DATA,__bss,_fe_strbytes,8,3     // u32 total string constant bytes (labels)
.zerofill __DATA,__bss,_fe_ndata,8,3        // u32 numeric DATA values so far
.zerofill __DATA,__bss,_fe_nsdata,8,3       // u32 string DATA values so far
.zerofill __DATA,__bss,_fe_has_read,8,3     // u32 1 if any numeric READ / MAT READ target
.zerofill __DATA,__bss,_fe_has_sread,8,3    // u32 1 if any string READ / MAT READ target
.zerofill __DATA,__bss,_fe_has_end,8,3      // u32 1 if the END line was seen
.zerofill __DATA,__bss,_fe_undef_line,8,3   // u32 first line jumping to a missing line
.zerofill __DATA,__bss,_fe_xfer_line,8,3    // u32 first line jumping across a body boundary
// MAT: bit L set if letter L is named by a MAT statement (fe_mat.s)
.zerofill __DATA,__bss,_fe_mat_names,8,3
// Fifth Edition:
// FNK_* bits of the DEF context function, of each multi-line function
// (pre-scan) and of each DEFined letter (phase 2)
.zerofill __DATA,__bss,_fe_ctx_skinds,8,3
.zerofill __DATA,__bss,_fe_ml_kinds,NUM_LETTERS*4,3
.zerofill __DATA,__bss,_fe_fn_kinds,NUM_LETTERS*4,3
// bit L set if L$ is named bare by MAT READ / MAT PRINT (fe_mat.s)
.zerofill __DATA,__bss,_fe_smat_names,8,3
// FILES names declared so far (fe_files.s)
.zerofill __DATA,__bss,_fe_nfiles,8,3
// 1 + the designator temp of the PRINT # / INPUT # being lowered, 0 if none
.zerofill __DATA,__bss,_fe_cur_file,8,3
// FN call log for the phase-3 kind check (fe_sexpr.s): pointer to 8-byte
// entries (u32 line, u16 FNK_* signature, u16 letter), count, capacity
.zerofill __DATA,__bss,_fe_calllog,8,3
.zerofill __DATA,__bss,_fe_ncalls,8,3
.zerofill __DATA,__bss,_fe_capcalls,8,3
// Sixth Edition program units (fe_sub.s): the current unit's Module*
// (swapped per unit), the current unit (0 main, 1 + u), the unit table
// and its size, the line -> unit map, the main program's save area, the
// FOR-stack depth at the start of the current unit (swapped), FOR
// statements of the whole program (TOO MANY LOOPS), the DEF line of a
// multi-line DEF and the SUB line of a SUB block still open after the
// last line (0 = none), and the CALL log (pointer, count, capacity)
    .globl _fe_unit, _fe_curunit, _fe_units, _fe_nunits, _fe_lineunit
    .globl _fe_mainsave, _fe_unitforbase, _fe_totalfors
    .globl _fe_eof_def_line, _fe_eof_sub_line
    .globl _fe_sublog, _fe_nsublog, _fe_capsublog
.zerofill __DATA,__bss,_fe_unit,8,3
.zerofill __DATA,__bss,_fe_curunit,8,3
.zerofill __DATA,__bss,_fe_units,8,3
.zerofill __DATA,__bss,_fe_nunits,8,3
.zerofill __DATA,__bss,_fe_lineunit,8,3
.zerofill __DATA,__bss,_fe_mainsave,8,3
.zerofill __DATA,__bss,_fe_unitforbase,8,3
.zerofill __DATA,__bss,_fe_totalfors,8,3
.zerofill __DATA,__bss,_fe_eof_def_line,8,3
.zerofill __DATA,__bss,_fe_eof_sub_line,8,3
.zerofill __DATA,__bss,_fe_sublog,8,3
.zerofill __DATA,__bss,_fe_nsublog,8,3
.zerofill __DATA,__bss,_fe_capsublog,8,3
// error unwinding
.zerofill __DATA,__bss,_fe_unwind_sp,8,3    // sp of _fe_compile's frame
.zerofill __DATA,__bss,_fe_err_code,8,3     // u32 ERR_* being reported
.zerofill __DATA,__bss,_fe_err_line,8,3     // u32 its line (0 = none)
