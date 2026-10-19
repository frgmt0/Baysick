// =====================================================================
// src/runtime/rt_main.s -- process entry, program termination and the
// current-line variable shared with compiled code.
//
// Defines: _main, _bsk_end, _bsk_curline   (docs/DESIGN.md section 6)
//
// All other runtime state is initialised statically in the file that
// owns it (print counters and buffer: rt_print.s, RND state: rt_rnd.s,
// DATA cursor: rt_data.s, GOSUB stack: rt_gosub.s), so _main has
// nothing to set up before it transfers control to the program.
// =====================================================================
.include "baysick.inc"

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _main -- process entry point of every compiled BASIC program.
//   Purpose : run the compiled main function _bsk_program; if it ever
//             returns (it should end with _bsk_end), terminate exactly
//             like END.
//   Inputs  : w0 = argc, x1 = argv (ignored; programs read no input)
//   Outputs : never returns
//   Clobbers: everything (control never comes back)
//   Callee-saved used: none
//   Frame   : 16 bytes (frame record only)
// ---------------------------------------------------------------------
    .globl _main
    .p2align 2
_main:
    stp x29, x30, [sp, #-16]!       // frame record
    mov x29, sp
    bl _bsk_program                 // run the BASIC program
    bl _bsk_end                     // fell off the end: behave like END
    // _bsk_end does not return; nothing follows.

// ---------------------------------------------------------------------
// _bsk_end -- END / STOP: normal termination.
//   Purpose : write the pending-line newline (if col != 0), flush the
//             stdout buffer, exit with status EXIT_RUN_OK, or
//             EXIT_RUN_ERROR if writing stdout failed (LANGUAGE.md 10).
//   Inputs  : none
//   Outputs : never returns
//   Clobbers: everything
//   Callee-saved used: none
//   Frame   : 16 bytes (frame record only)
// ---------------------------------------------------------------------
    .globl _bsk_end
    .p2align 2
_bsk_end:
    stp x29, x30, [sp, #-16]!       // frame record (keeps sp aligned)
    mov x29, sp
    bl _bsk_rt_finish_output        // newline if mid-line, then flush
    cmp w0, #0                      // w0 = 1 if stdout broke
    mov w0, #EXIT_RUN_OK            // END and STOP exit 0 ...
    mov w9, #EXIT_RUN_ERROR
    csel w0, w0, w9, eq             // ... or 1 if output was lost
    bl _exit                        // libc exit(3); does not return

// ---------------------------------------------------------------------
// Data shared with compiled code.
// _bsk_curline: u32, BASIC line number of the statement being executed.
// Compiled code stores it at every OP_LINE; _bsk_err prints it.
// ---------------------------------------------------------------------
    .globl _bsk_curline
.zerofill __DATA,__bss,_bsk_curline,4,2
