// =====================================================================
// src/runtime/rt_error.s -- run-time error reporting.
//
// Defines: _bsk_err (docs/DESIGN.md section 6.2, LANGUAGE.md section 10)
//
// The message text comes only from include/errors.inc via
// BSK_EMIT_ERRMSG_TABLE, so it can never diverge from the compiler's.
// =====================================================================
.include "baysick.inc"

// Size of the stack buffer used to build "<MESSAGE> IN <line>\n".
// The longest message is 25 bytes, " IN " is 4, a u32 has at most 10
// digits, plus LF: 40 bytes. 64 leaves room.
.equ RT_ERR_MSGBUF, 64

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _bsk_err -- report a run-time error and terminate.
//   Purpose : Fifth Edition: first finish the files in write mode not
//             yet finished (_bsk_rt_files_finish, DESIGN.md 6.8). Then
//             pending-line newline + flush of stdout, then write
//             "<MESSAGE> IN <_bsk_curline>" + LF to fd 2 and exit.
//             Exit status EXIT_RUN_OK (0) for ERR_OUT_OF_DATA and
//             ERR_END_OF_INPUT, else EXIT_RUN_ERROR (1); those two
//             also exit 1 if writing stdout or a file failed
//             (LANGUAGE.md 10).
//   Inputs  : w0 = ERR_* code; must be a run-time code
//             (ERR_FIRST_RUNTIME..ERR_TABLE_SIZE-1). Any other code (a
//             caller bug) prints nothing and exits with status 1
//             (DESIGN.md 6.2).
//   Outputs : never returns
//   Clobbers: everything
//   Callee-saved used: x19 = error code, x20 = write cursor in the
//             message buffer, x21 = start of the message buffer,
//             x22 = 1 if stdout broke or a file's output was lost,
//             else 0, x23 = 1 if a file's output was lost
//   Frame   : 64 (frame record + x19..x23 save) + RT_ERR_MSGBUF bytes
// ---------------------------------------------------------------------
    .globl _bsk_err
    .p2align 2
_bsk_err:
    stp x29, x30, [sp, #-64]!       // frame record
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]
    sub sp, sp, #RT_ERR_MSGBUF      // message buffer at [sp]
    mov w19, w0                     // keep the code across calls
    mov w23, #0                     // no file output lost (so far)

    // The files in write mode first, in ascending order (a no-op when
    // _bsk_end already finished them); a failure, now or earlier, only
    // forces exit status 1 (LANGUAGE.md 10).
    bl _bsk_rt_files_finish
    mov w23, w0                     // 1 if a file's output was lost

    // stdout next: the error text must appear after all output.
    bl _bsk_rt_finish_output
    mov w22, w0                     // 1 if stdout broke
    orr w22, w22, w23               // output lost anywhere: status 1

    // Look up the message; a code that is not a run-time error prints
    // nothing.
    cmp w19, #ERR_FIRST_RUNTIME
    b.lo Lrt_err_exit
    cmp w19, #ERR_TABLE_SIZE
    b.hs Lrt_err_exit
    adrp x9, Lrt_errmsg@PAGE
    add x9, x9, Lrt_errmsg@PAGEOFF
    ldr x10, [x9, w19, uxtw #3]     // x10 = message pointer or 0
    cbz x10, Lrt_err_exit

    // Copy the NUL-terminated message into the buffer.
    mov x21, sp                     // buffer start
    mov x20, sp                     // write cursor
Lrt_err_copy:
    ldrb w11, [x10], #1
    cbz w11, Lrt_err_in
    strb w11, [x20], #1
    b Lrt_err_copy

    // Append " IN " and the decimal line number.
Lrt_err_in:
    mov w11, #' '
    strb w11, [x20], #1
    mov w11, #'I'
    strb w11, [x20], #1
    mov w11, #'N'
    strb w11, [x20], #1
    mov w11, #' '
    strb w11, [x20], #1
    adrp x9, _bsk_curline@PAGE
    ldr w0, [x9, _bsk_curline@PAGEOFF]  // zero-extended u32 line
    mov x1, x20
    bl _bsk_rt_utoa                 // x0 = digit count
    add x20, x20, x0
    mov w11, #'\n'
    strb w11, [x20], #1

    // write(2, buf, len)
    mov w0, #2
    mov x1, x21
    sub x2, x20, x21
    bl _bsk_rt_write_all

Lrt_err_exit:
    // OUT OF DATA is the normal end of a 1964 program and END OF INPUT
    // the normal end of a filter: exit 0, unless stdout broke (output
    // was lost): then exit 1 like any error.
    mov w0, #EXIT_RUN_ERROR
    mov w9, #EXIT_RUN_OK
    cmp w19, #ERR_OUT_OF_DATA
    csel w0, w9, w0, eq
    cmp w19, #ERR_END_OF_INPUT
    csel w0, w9, w0, eq
    cmp w22, #0
    mov w9, #EXIT_RUN_ERROR
    csel w0, w0, w9, eq             // stdout broken: status 1
    bl _exit                        // does not return

// ---------------------------------------------------------------------
// Message table (pointers indexed by error code) and texts.
// ---------------------------------------------------------------------
    .section __DATA,__const
    BSK_EMIT_ERRMSG_TABLE Lrt_errmsg
