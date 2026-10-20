// =====================================================================
// src/runtime/rt_main.s -- process entry, program termination and the
// current-line variable shared with compiled code.
//
// Defines: _main, _bsk_end, _bsk_curline   (docs/DESIGN.md section 6)
// Defines (private): _bsk_rt_terminate, the END / STOP sequence shared
// with _bsk_exit (rt_ext.s, Baysick extensions)
//
// All other runtime state is initialised statically in the file that
// owns it (print counters and buffer: rt_print.s, RND state: rt_rnd.s,
// DATA cursor: rt_data.s, GOSUB stack: rt_gosub.s), so _main has
// nothing to set up before it transfers control to the program except
// the matrix kernel selection (_bsk_kern_init, rt_kinit.s) and the
// program stack (DESIGN.md 6.9). SUB call state: rt_sub.s.
// =====================================================================
.include "baysick.inc"

// macOS values of the constants used to build the program stack
// (<unistd.h>, <sys/mman.h>).
.equ RT_SC_PAGESIZE,    29          /* sysconf(_SC_PAGESIZE) */
.equ RT_PROT_NONE,      0
.equ RT_PROT_RW,        3           /* PROT_READ | PROT_WRITE */
.equ RT_MAP_PRIVANON,   0x1002      /* MAP_PRIVATE | MAP_ANON */

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _main -- process entry point of every compiled BASIC program.
//   Purpose : select the matrix kernels (_bsk_kern_init, DESIGN.md
//             6.6.2); build the program stack (DESIGN.md 6.9): G =
//             sysconf(_SC_PAGESIZE), mmap(NULL, RT_PROGRAM_STACK_BYTES
//             + G, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANON, -1, 0),
//             mprotect(base, G, PROT_NONE) for the guard page; then run
//             the compiled main function _bsk_program with sp = base + G
//             + RT_PROGRAM_STACK_BYTES; if it ever returns (it should
//             end with _bsk_end), terminate exactly like END. A failure
//             of sysconf, mmap or mprotect is OUT OF ROOM IN 0 before
//             any line runs. The stack is never freed.
//   Inputs  : w0 = argc, x1 = argv (ignored)
//   Outputs : never returns
//   Clobbers: everything (control never comes back)
//   Callee-saved used: x19 = G (page size), x20 = mapping base
//   Frame   : 32 bytes (frame record + x19, x20) on the process stack;
//             x29 keeps pointing at it while the program runs
// ---------------------------------------------------------------------
    .globl _main
    .p2align 2
_main:
    stp x29, x30, [sp, #-32]!       // frame record
    mov x29, sp
    stp x19, x20, [sp, #16]
    bl _bsk_kern_init               // select the matrix kernel variant

    // G = the host page size (16 KiB on arm64 macOS).
    mov w0, #RT_SC_PAGESIZE
    bl _sysconf
    cmp x0, #0
    b.le Lrt_main_oom               // -1: no page size (never on macOS)
    mov x19, x0

    // The stack and its guard page in one private anonymous mapping.
    mov x0, #0                      // addr: anywhere
    mov x1, #RT_PROGRAM_STACK_BYTES
    add x1, x1, x19                 // size + G
    mov w2, #RT_PROT_RW
    mov w3, #RT_MAP_PRIVANON
    mov w4, #-1                     // fd: none
    mov x5, #0                      // offset
    bl _mmap
    cmn x0, #1
    b.eq Lrt_main_oom               // MAP_FAILED
    mov x20, x0

    // The lowest G bytes become the guard page.
    mov x1, x19
    mov w2, #RT_PROT_NONE
    bl _mprotect                    // x0 = base still
    cbnz w0, Lrt_main_oom

    // sp := base + G + RT_PROGRAM_STACK_BYTES (page-aligned, so 16-byte
    // aligned), then run the program there.
    add x9, x20, x19
    mov x10, #RT_PROGRAM_STACK_BYTES
    add x9, x9, x10
    and x9, x9, #~15
    mov sp, x9
    bl _bsk_program                 // run the BASIC program
    bl _bsk_end                     // fell off the end: behave like END
    // _bsk_end does not return; nothing follows.
Lrt_main_oom:
    mov w0, #ERR_OUT_OF_ROOM        // _bsk_curline is still 0
    bl _bsk_err                     // noreturn

// ---------------------------------------------------------------------
// _bsk_end -- END / STOP: normal termination with exit status 0
//   (LANGUAGE.md 10). Exactly _bsk_exit with status 0 (DESIGN.md 6.2,
//   6.10): the shared sequence _bsk_rt_terminate.
//   Inputs  : none
//   Outputs : never returns
//   Clobbers: everything
//   Callee-saved used: none
//   Frame   : none (tail call)
// ---------------------------------------------------------------------
    .globl _bsk_end
    .p2align 2
_bsk_end:
    mov w0, #EXIT_RUN_OK            // END and STOP exit 0 ...
    b _bsk_rt_terminate             // ... unless output was lost

// ---------------------------------------------------------------------
// _bsk_rt_terminate -- the termination sequence of END and STOP, with
//   or without a status (LANGUAGE.md 10, 15.4, 15.5; DESIGN.md 6.10).
//   Purpose : 1. finish the files in write mode (_bsk_rt_files_finish,
//             DESIGN.md 6.8); if that fails, the run ends as the error
//             CAN'T WRITE FILE at this END / STOP line instead
//             (_bsk_err repeats the remaining steps, exit 1);
//             2. stdout's pending-line newline (if col != 0) and flush;
//             3. standard error's pending-line newline (_bsk_rt_err_bol);
//             4. exit with the status, or EXIT_RUN_ERROR if a stdout
//             write failed at any time, the flush of step 2 included.
//   Inputs  : w0 = exit status, 0 .. LIM_EXIT_STATUS (already checked)
//   Outputs : never returns
//   Clobbers: everything
//   Callee-saved used: x19 = status, x20 = 1 if stdout broke
//   Frame   : 32 bytes (frame record + x19, x20)
// ---------------------------------------------------------------------
    .private_extern _bsk_rt_terminate
    .p2align 2
_bsk_rt_terminate:
    stp x29, x30, [sp, #-32]!       // frame record (keeps sp aligned)
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov w19, w0                     // the status chosen by the program
    // The files in write mode first, in ascending order; a failure
    // ends the run as CAN'T WRITE FILE at this END / STOP line (the
    // remaining files were still finished; stdout follows in _bsk_err).
    bl _bsk_rt_files_finish
    cbz w0, 1f
    mov w0, #ERR_CANT_WRITE_FILE
    bl _bsk_err                     // noreturn
1:
    bl _bsk_rt_finish_output        // newline if mid-line, then flush
    mov w20, w0                     // 1 if stdout broke (at any time)
    bl _bsk_rt_err_bol              // standard error's pending line
    cmp w20, #0
    mov w9, #EXIT_RUN_ERROR
    csel w0, w19, w9, eq            // the status, or 1 if output was lost
    bl _exit                        // libc exit(3); does not return

// ---------------------------------------------------------------------
// Data shared with compiled code.
// _bsk_curline: u32, BASIC line number of the statement being executed.
// Compiled code stores it at every OP_LINE; _bsk_err prints it.
// ---------------------------------------------------------------------
    .globl _bsk_curline
.zerofill __DATA,__bss,_bsk_curline,4,2
