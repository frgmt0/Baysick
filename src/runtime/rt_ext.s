// =====================================================================
// src/runtime/rt_ext.s -- the Baysick extensions' entry points: LINPUT
// and END / STOP with an exit status (LANGUAGE.md 15.2, 15.4, 15.5;
// DESIGN.md 6.10).
//
// Defines (global, runtime.inc):
//   _bsk_linput _bsk_linput_el _bsk_exit
// Uses: _bsk_rt_in_linput (rt_input.s: the reader's next line, with the
// pending file selection and every line rule), _bsk_rt_str_setbytes
// (rt_str.s), _bsk_saref1 (rt_array.s), _bsk_rt_terminate (rt_main.s:
// the END / STOP sequence), _bsk_err.
//
// The rest of the extensions lives where the rules it changes live:
// standard error's output record and its writes in rt_print.s, the
// designator -1 in _bsk_fsel (rt_files.s), its rejection by the input
// entry points in rt_input.s, code 62 and standard error's pending line
// at a message in rt_error.s.
// =====================================================================
.include "baysick.inc"

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _bsk_linput -- LINPUT target / LINPUT #k, target (LANGUAGE.md 15.2):
//   the reader's next unread line, verbatim (every byte after the CR
//   removal, no field scan), stored into the string with _bsk_str_set
//   semantics. An input entry point: the pending selection is taken on
//   entry (none: the INPUT dialogue's line request, prompt on a
//   terminal, END OF INPUT exit 0; -1: INVALID FILE NUMBER; k = 0 or
//   k >= 1: the INPUT # line request, END OF FILE exit 1).
//   Inputs  : x0 = destination SD
//   Outputs : none
//   Errors  : INVALID FILE NUMBER, ILLEGAL FILE COMMAND, CAN'T OPEN
//             FILE, END OF INPUT, END OF FILE, INPUT LINE TOO LONG,
//             OUT OF ROOM
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = destination
//   Frame   : 32 bytes (frame record + x19)
// ---------------------------------------------------------------------
    .globl _bsk_linput
    .p2align 2
_bsk_linput:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov x19, x0
    bl _bsk_rt_in_linput            // x0 = line bytes, x1 = length
    mov x2, x1
    mov x1, x0
    mov x0, x19
    bl _bsk_rt_str_setbytes         // target := the whole line
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _bsk_linput_el -- LINPUT into a string list element L$(i) (the element
//   form of `linput`, IR.md 3.5): the line is read first, exactly as by
//   _bsk_linput (every error of that first); only then is the subscript
//   checked (SUBSCRIPT ERROR at the store, LANGUAGE.md 15.2), then the
//   element := the line.
//   Inputs  : x0 = string-list descriptor (RTA_*), d0 = subscript i
//   Outputs : none
//   Errors  : those of _bsk_linput; then SUBSCRIPT ERROR (_bsk_saref1);
//             OUT OF ROOM
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = descriptor, then the line bytes,
//             x20 = line length, d8 = subscript
//   Frame   : 48 bytes (frame record + x19, x20 + d8, padded)
// ---------------------------------------------------------------------
    .globl _bsk_linput_el
    .p2align 2
_bsk_linput_el:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str d8, [sp, #32]
    mov x19, x0
    fmov d8, d0
    bl _bsk_rt_in_linput            // x0 = line bytes, x1 = length
    mov x20, x1
    mov x9, x0
    mov x0, x19
    mov x19, x9                     // keep the bytes (the line buffer)
    fmov d0, d8
    bl _bsk_saref1                  // x0 = &L$(i); SUBSCRIPT ERROR here
    mov x1, x19
    mov x2, x20
    bl _bsk_rt_str_setbytes         // element := the line
    ldr d8, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// _bsk_exit -- END e / STOP e (LANGUAGE.md 15.4, DESIGN.md 6.10): k =
//   trunc(x), compared as a double (so a huge value cannot wrap): k < 0
//   or k > LIM_EXIT_STATUS -> EXIT STATUS OUT OF RANGE (exit 1, the
//   ordinary run-time error termination). Otherwise exactly the END
//   sequence (_bsk_rt_terminate: files, stdout's pending newline and
//   flush, standard error's pending newline) and exit(k), or exit(1) if
//   output was lost (a stdout write failed at any time; a file that
//   cannot be finished ends the run as CAN'T WRITE FILE instead).
//   Inputs  : d0 = x (finite)
//   Outputs : never returns
//   Errors  : EXIT STATUS OUT OF RANGE, CAN'T WRITE FILE
//   Clobbers: everything
//   Callee-saved used: none
//   Frame   : 16 bytes (frame record)
// ---------------------------------------------------------------------
    .globl _bsk_exit
    .p2align 2
_bsk_exit:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    frintz d0, d0                   // k = trunc(x), exact
    fcmp d0, #0.0
    b.lt Lrt_ext_exit_range         // k < 0 (or unordered)
    mov w9, #LIM_EXIT_STATUS
    ucvtf d1, w9
    fcmp d0, d1
    b.gt Lrt_ext_exit_range         // k > 255
    fcvtzu w0, d0                   // 0 .. 255 (-0 converts to 0)
    bl _bsk_rt_terminate            // noreturn
Lrt_ext_exit_range:
    mov w0, #ERR_EXIT_RANGE
    bl _bsk_err                     // noreturn
