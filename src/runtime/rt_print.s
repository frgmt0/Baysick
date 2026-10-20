// =====================================================================
// src/runtime/rt_print.s -- PRINT column logic and buffered output for
// standard output and (Fifth Edition) the files in write mode.
//
// Defines (global, runtime.inc):
//   _bsk_print_num _bsk_print_str _bsk_print_sv _bsk_print_comma
//   _bsk_print_semi _bsk_print_tab _bsk_print_nl
// Defines (private to the runtime, .private_extern):
//   _bsk_rt_fsel            u32 pending file selection (DESIGN.md 6.8,
//                           6.10): 0 = none, k + 2 = file k for k >= -1
//                           (1 = standard error, 2 = file 0); written by
//                           _bsk_fsel (rt_files.s), taken (read and reset
//                           to 0) on entry by every print and input entry
//                           point
//   _bsk_rt_err_bol         Baysick extensions: end standard error's
//                           pending line before a BASIC message
//   _bsk_rt_finish_output   pending-line newline + flush of stdout (END /
//                           errors); reports whether stdout broke
//   _bsk_rt_write_all       write(2) loop handling short writes / EINTR
//   _bsk_rt_print_bol       newline on stdout if col != 0 (MAT PRINT)
//   _bsk_rt_print_flush     flush the stdout buffer (INPUT diagnostics)
//   _bsk_rt_print_prompt    the INPUT prompt on a terminal (rt_input.s)
//   _bsk_rt_print_home      stdout col = out = 0 after a terminal line
//   Fifth Edition (rt_files.s):
//   _bsk_rt_out_begin       file k enters write mode: buffer, fd, col 0
//   _bsk_rt_out_end         file k: newline if col != 0, then flush
//   _bsk_rt_out_failed      file k: has a write to it failed?
// Uses: _bsk_rt_fmtnum (rt_numfmt.s), _bsk_rt_file_wcheck (rt_files.s,
// Fifth Edition), _bsk_err.
//
// Column model (LANGUAGE.md section 8): `col` is the logical column,
// `out` the number of characters physically written on this line.
// Spaces are lazy: a space only advances `col`; before any other
// character, col - out spaces are written. Hence no trailing blanks.
//
// Output state records (OS_*, below): one for stdout (index 0) and one
// per file number 1..LIM_FILES. Every column rule is one routine taking
// a pointer to such a record, so standard output and every file follow
// exactly the same rules with their own col, out and buffer (DESIGN.md
// 6.8). Bytes go through one append routine (Lrt_print_putc) which is
// the only place that writes a full buffer: immediately after the byte
// that makes the fill count equal to the capacity is stored, the whole
// buffer is written (RT_OUTBUF_SIZE for stdout, RT_FILEBUF_SIZE for a
// file). Otherwise a buffer is written only by an explicit flush.
//
// Broken stdout (LANGUAGE.md section 10): if write(2) to fd 1 fails with
// an error other than EINTR, or writes 0 bytes, stdout is marked broken
// (OS_FAILED of record 0); all further stdout output is discarded and
// _bsk_rt_finish_output reports it, so END / STOP / OUT OF DATA exit
// with status 1 instead of 0.
// Failed file write (LANGUAGE.md 7.21): the file's OS_FAILED is set, its
// buffer emptied and CAN'T WRITE FILE raised -- except while the files
// are being finished at termination (_bsk_rt_out_end with w1 = 0), when
// the failure is only reported to the caller. A flagged file is skipped
// by every later flush.
//
// Standard error (Baysick extensions, LANGUAGE.md 15.3, DESIGN.md 6.10):
// one more output record (Lrt_print_eos, fd 2, its own col / out and an
// RT_OUTBUF_SIZE buffer) selected by the pending selection -1. It is
// unbuffered as seen from the program: every print entry point that put
// a byte into it writes the record before returning (Lrt_print_fin),
// and a full buffer is written at once like any other. Writing it first
// flushes stdout's buffer (so the two streams keep program order on a
// shared file), then writes fd 2; a failed write to fd 2 drops the
// bytes and is otherwise ignored (no flag, no error, no status change).
// A call that only moves col writes nothing to either descriptor.
// SIGPIPE keeps the action the process inherited (no code here).
// =====================================================================
.include "baysick.inc"

.equ RT_EINTR, 4                    // <errno.h> EINTR on Darwin
.equ RT_NUMBUF, 48                  // stack buffer for one number field
                                    // (longest field: "-1.23457E-308 " = 14)

// Output state record (runtime-private, this file only).
.equ OS_COL,    0                   // u64 logical column
.equ OS_OUT,    8                   // u64 characters written on this line
.equ OS_FILL,   16                  // u64 bytes in the buffer
.equ OS_BUF,    24                  // ptr buffer (0 = none allocated yet)
.equ OS_CAP,    32                  // u64 buffer capacity in bytes
.equ OS_FD,     40                  // u32 file descriptor
.equ OS_FAILED, 44                  // u32 1 once a write failed (stdout: broken)
.equ OS_SIZE,   48
.equ RT_PR_NOS, LIM_FILES + 1       // records: stdout, files 1..LIM_FILES

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _bsk_rt_write_all -- write a whole byte range to a file descriptor.
//   Purpose : call write(2) until every byte is written; retry on
//             EINTR; give up on any other error or on a write that
//             makes no progress (returns 0), reporting failure to the
//             caller (nothing is printed: there is no better channel).
//   Inputs  : w0 = fd, x1 = pointer, x2 = length
//   Outputs : w0 = 0 if every byte was written, 1 on failure
//   Clobbers: x0-x17, d0-d7, d16-d31 (calls libc)
//   Callee-saved used: x19 = fd, x20 = cursor, x21 = bytes remaining
//   Frame   : 48 bytes (frame record + x19..x21; x21 slot padded)
// ---------------------------------------------------------------------
    .private_extern _bsk_rt_write_all
    .p2align 2
_bsk_rt_write_all:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov w19, w0                     // fd
    mov x20, x1                     // next byte to write
    mov x21, x2                     // bytes left
Lrt_print_wa_loop:
    cbz x21, Lrt_print_wa_ok        // everything written
    mov w0, w19
    mov x1, x20
    mov x2, x21
    bl _write
    cmp x0, #0
    b.lt Lrt_print_wa_err           // -1: inspect errno
    b.eq Lrt_print_wa_fail          // 0 bytes: no progress, give up
    add x20, x20, x0                // advance past the bytes written
    sub x21, x21, x0
    b Lrt_print_wa_loop
Lrt_print_wa_err:
    bl ___error                     // x0 = &errno
    ldr w9, [x0]
    cmp w9, #RT_EINTR
    b.eq Lrt_print_wa_loop          // interrupted: try again
Lrt_print_wa_fail:
    mov w0, #1                      // real error: report failure
    b Lrt_print_wa_done
Lrt_print_wa_ok:
    mov w0, #0                      // all bytes written
Lrt_print_wa_done:
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// Lrt_print_flush -- write the buffered bytes of an output state and
//   empty its buffer.
//   Purpose : once the state has failed (stdout broken, file write
//             failed) the bytes are discarded. A failed write sets
//             OS_FAILED; for a file (not record 0) it then raises CAN'T
//             WRITE FILE unless Lrt_print_noraise is set (termination).
//             Standard error's record (Lrt_print_eos): stdout's buffer
//             is flushed first, then the bytes go to fd 2; a failure is
//             ignored (its OS_FAILED stays 0).
//   Inputs  : x0 = output state record
//   Outputs : w0 = the record's OS_FAILED after the flush (0 or 1)
//   Errors  : CAN'T WRITE FILE (files only, see above)
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = record
//   Frame   : 32 bytes (frame record + x19)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_print_flush:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov x19, x0
    ldr x2, [x19, #OS_FILL]         // number of buffered bytes
    cbz x2, Lrt_print_flush_done    // nothing to write
    adrp x9, Lrt_print_eos@PAGE
    add x9, x9, Lrt_print_eos@PAGEOFF
    cmp x19, x9
    b.eq Lrt_print_flush_err        // standard error: its own rule
    str xzr, [x19, #OS_FILL]        // buffer is empty afterwards
    ldr w9, [x19, #OS_FAILED]
    cbnz w9, Lrt_print_flush_done   // broken / failed: discard
    ldr w0, [x19, #OS_FD]
    ldr x1, [x19, #OS_BUF]
    bl _bsk_rt_write_all
    cbz w0, Lrt_print_flush_done    // written completely
    mov w9, #1
    str w9, [x19, #OS_FAILED]       // this output is broken from now on
    adrp x9, Lrt_print_os@PAGE
    add x9, x9, Lrt_print_os@PAGEOFF
    cmp x19, x9
    b.eq Lrt_print_flush_done       // stdout: silently broken
    adrp x9, Lrt_print_noraise@PAGE
    ldr w9, [x9, Lrt_print_noraise@PAGEOFF]
    cbnz w9, Lrt_print_flush_done   // termination: only report it
    mov w0, #ERR_CANT_WRITE_FILE
    bl _bsk_err                     // noreturn
Lrt_print_flush_err:
    // Standard error: every buffered stdout byte is written before the
    // first byte goes to fd 2 (a stdout failure marks stdout broken, as
    // always), then the stderr bytes; a failure drops them silently.
    adrp x0, Lrt_print_os@PAGE
    add x0, x0, Lrt_print_os@PAGEOFF
    bl Lrt_print_flush              // stdout first (never raises)
    ldr x2, [x19, #OS_FILL]
    str xzr, [x19, #OS_FILL]        // stderr buffer empty afterwards
    mov w0, #2
    ldr x1, [x19, #OS_BUF]
    bl _bsk_rt_write_all            // result ignored (LANGUAGE.md 15.3)
Lrt_print_flush_done:
    ldr w0, [x19, #OS_FAILED]
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lrt_print_putc -- append one byte to an output buffer; the byte that
//   fills the buffer writes it (Lrt_print_flush) at once.
//   Inputs  : x0 = output state record, w1 = byte
//   Outputs : none
//   Errors  : CAN'T WRITE FILE (a file's full buffer cannot be written)
//   Clobbers: x0-x17, d0-d7, d16-d31 (may flush via libc write)
//   Callee-saved used: none
//   Frame   : none (leaf, except for a tail call to Lrt_print_flush)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_print_putc:
    ldr x10, [x0, #OS_FILL]
    ldr x11, [x0, #OS_BUF]
    strb w1, [x11, x10]             // buf[fill] = byte
    add x10, x10, #1
    str x10, [x0, #OS_FILL]
    ldr x11, [x0, #OS_CAP]
    cmp x10, x11
    b.hs Lrt_print_flush            // full: write it now (tail call)
    ret

// ---------------------------------------------------------------------
// Lrt_print_newline -- the "newline" action: write LF, col = out = 0.
//   Inputs  : x0 = output state record
//   Outputs : none
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = record
//   Frame   : 32 bytes (frame record + x19)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_print_newline:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov x19, x0
    mov w1, #'\n'
    bl Lrt_print_putc
    str xzr, [x19, #OS_COL]         // col = 0
    str xzr, [x19, #OS_OUT]         // out = 0
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lrt_print_emit -- the "emit(c)" action of LANGUAGE.md section 8.
//   Purpose : a space only advances col; any other byte is preceded by
//             col - out real spaces, then written; col += 1; out = col.
//   Inputs  : x0 = output state record, w1 = byte
//   Outputs : none
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = the byte, x20 = spaces still to write,
//             x21 = record
//   Frame   : 48 bytes (frame record + x19..x21, padded)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_print_emit:
    and w1, w1, #0xFF               // the byte
    ldr x10, [x0, #OS_COL]
    cmp w1, #' '
    b.ne 1f
    add x10, x10, #1                // lazy space: col += 1 only (leaf)
    str x10, [x0, #OS_COL]
    ret
1:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov w19, w1
    mov x21, x0
    ldr x11, [x21, #OS_OUT]
    sub x20, x10, x11               // pending spaces = col - out
Lrt_print_emit_pad:
    cbz x20, Lrt_print_emit_char
    mov x0, x21
    mov w1, #' '
    bl Lrt_print_putc
    sub x20, x20, #1
    b Lrt_print_emit_pad
Lrt_print_emit_char:
    mov x0, x21
    mov w1, w19
    bl Lrt_print_putc               // the byte itself
    ldr x10, [x21, #OS_COL]
    add x10, x10, #1                // col += 1
    str x10, [x21, #OS_COL]
    str x10, [x21, #OS_OUT]         // out = col
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// Lrt_print_take -- take the pending file selection (DESIGN.md 6.8,
//   6.10): read _bsk_rt_fsel and reset it to "none"; none or file 0
//   selects standard output; -1 selects standard error's record (no
//   mode check: always writable); file k >= 1 must be in write mode
//   (_bsk_rt_file_wcheck: ILLEGAL FILE COMMAND) and selects file k's
//   record.
//   Inputs  : none
//   Outputs : x0 = output state record
//   Errors  : ILLEGAL FILE COMMAND
//   Clobbers: x0-x17, d0-d7, d16-d31 (only x0, x9-x11 when no file
//             k >= 1 is selected)
//   Callee-saved used: x19 = k
//   Frame   : 32 bytes (frame record + x19) when a file is selected
// ---------------------------------------------------------------------
    .p2align 2
Lrt_print_take:
    adrp x0, Lrt_print_os@PAGE
    add x0, x0, Lrt_print_os@PAGEOFF    // stdout's record
    adrp x9, _bsk_rt_fsel@PAGE
    ldr w10, [x9, _bsk_rt_fsel@PAGEOFF] // 0 none, else k + 2
    cbz w10, 1f
    str wzr, [x9, _bsk_rt_fsel@PAGEOFF] // taken: back to "none"
    cmp w10, #1
    b.eq 2f                             // -1: standard error
    subs w10, w10, #2                   // k
    b.eq 1f                             // file 0: standard output
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov w19, w10
    mov w0, w10
    bl _bsk_rt_file_wcheck              // ILLEGAL FILE COMMAND unless write mode
    adrp x0, Lrt_print_os@PAGE
    add x0, x0, Lrt_print_os@PAGEOFF
    mov x9, #OS_SIZE
    madd x0, x19, x9, x0                // &record[k]
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
1:
    ret
2:
    adrp x0, Lrt_print_eos@PAGE
    add x0, x0, Lrt_print_eos@PAGEOFF   // standard error's record
    ret

// ---------------------------------------------------------------------
// Lrt_print_fin -- end of a print entry point (DESIGN.md 6.10): if the
//   record is standard error's, the bytes this call put into its buffer
//   are written now (stdout flushed first; nothing at all happens when
//   the call wrote no byte). Any other record: nothing.
//   Inputs  : x0 = output state record used by the call
//   Outputs : none
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : none (leaf, or a tail call to Lrt_print_flush)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_print_fin:
    adrp x9, Lrt_print_eos@PAGE
    add x9, x9, Lrt_print_eos@PAGEOFF
    cmp x0, x9
    b.eq Lrt_print_flush            // standard error: write it (tail call)
    ret

// ---------------------------------------------------------------------
// Lrt_print_bytes -- a string item: emit every byte; never truncated or
//   wrapped.
//   Inputs  : x0 = output state record, x1 = pointer, x2 = length
//   Outputs : none
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = cursor, x20 = end pointer, x21 = record
//   Frame   : 48 bytes (frame record + x19..x21, padded)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_print_bytes:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov x21, x0
    mov x19, x1                     // cursor
    add x20, x1, x2                 // end
Lrt_print_bytes_loop:
    cmp x19, x20
    b.hs Lrt_print_bytes_done
    mov x0, x21
    ldrb w1, [x19], #1              // next byte
    bl Lrt_print_emit
    b Lrt_print_bytes_loop
Lrt_print_bytes_done:
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// _bsk_print_str -- PRINT a string item (label).
//   Inputs  : x0 = pointer to the bytes, x1 = length (may be 0)
//   Outputs : none
//   Errors  : ILLEGAL FILE COMMAND, CAN'T WRITE FILE (a selected file)
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = pointer, x20 = length, x21 = output state
//   Frame   : 48 bytes (frame record + x19..x21, padded)
// ---------------------------------------------------------------------
    .globl _bsk_print_str
    .p2align 2
_bsk_print_str:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov x19, x0
    mov x20, x1
    bl Lrt_print_take               // x0 = output state
    mov x21, x0
    mov x1, x19
    mov x2, x20
    bl Lrt_print_bytes
    mov x0, x21
    bl Lrt_print_fin                // standard error: written now
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// _bsk_print_sv -- PRINT a string variable, element or temp cell: the
//   §8 string item (each byte through the lazy-space column logic).
//   Inputs  : x0 = SD
//   Outputs : none
//   Errors  : ILLEGAL FILE COMMAND, CAN'T WRITE FILE (a selected file)
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : none (tail call)
// ---------------------------------------------------------------------
    .globl _bsk_print_sv
    .p2align 2
_bsk_print_sv:
    ldr w1, [x0, #SD_LEN]
    ldr x0, [x0, #SD_PTR]
    b _bsk_print_str                // takes the selection itself

// ---------------------------------------------------------------------
// _bsk_print_num -- PRINT a number item.
//   Purpose : format the field F (LANGUAGE.md section 9); if fewer than
//             PRINT_MIN_ROOM columns remain before PRINT_LINE_WIDTH,
//             newline first; then emit every character of F.
//   Inputs  : d0 = value (finite)
//   Outputs : none
//   Errors  : ILLEGAL FILE COMMAND, CAN'T WRITE FILE (a selected file)
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = cursor in the field, x20 = end of field,
//             x21 = output state, d8 = the value until it is formatted
//   Frame   : 48 bytes (frame record + x19..x21 + d8) + RT_NUMBUF field
//             buffer
// ---------------------------------------------------------------------
    .globl _bsk_print_num
    .p2align 2
_bsk_print_num:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    str d8, [sp, #40]
    sub sp, sp, #RT_NUMBUF          // field buffer at [sp]
    fmov d8, d0
    bl Lrt_print_take               // selection first, before anything
    mov x21, x0
    fmov d0, d8
    mov x0, sp
    bl _bsk_rt_fmtnum               // x0 = field length
    mov x19, sp                     // cursor
    add x20, sp, x0                 // end of field
    // Room check: newline if 75 - col < 12, i.e. col > 63 (col may
    // exceed 75 after a long label; the unsigned test covers that).
    ldr x10, [x21, #OS_COL]
    cmp x10, #(PRINT_LINE_WIDTH - PRINT_MIN_ROOM)
    b.ls Lrt_print_num_loop
    mov x0, x21
    bl Lrt_print_newline
Lrt_print_num_loop:
    cmp x19, x20
    b.hs Lrt_print_num_done
    mov x0, x21
    ldrb w1, [x19], #1
    bl Lrt_print_emit
    b Lrt_print_num_loop
Lrt_print_num_done:
    mov x0, x21
    bl Lrt_print_fin                // standard error: written now
    add sp, sp, #RT_NUMBUF
    ldr d8, [sp, #40]
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// _bsk_print_comma -- PRINT ',' : next zone strictly to the right.
//   Purpose : col = (col / 15 + 1) * 15; newline if col >= 75.
//   Inputs  : none
//   Outputs : none
//   Errors  : ILLEGAL FILE COMMAND, CAN'T WRITE FILE (a selected file)
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = output state
//   Frame   : 32 bytes (frame record + x19)
// ---------------------------------------------------------------------
    .globl _bsk_print_comma
    .p2align 2
_bsk_print_comma:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    bl Lrt_print_take               // x0 = output state
    mov x19, x0
    ldr x10, [x0, #OS_COL]
    mov x11, #PRINT_ZONE_WIDTH
    udiv x10, x10, x11              // current zone index
    add x10, x10, #1                // next zone
    mul x10, x10, x11               // its first column
    str x10, [x0, #OS_COL]
    cmp x10, #PRINT_LINE_WIDTH
    b.lo 1f                         // still on this line
    bl Lrt_print_newline
1:
    mov x0, x19
    bl Lrt_print_fin                // standard error: the LF, if any
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _bsk_print_semi -- PRINT ';' after a number: next multiple of 3
//   strictly to the right; no newline is forced.
//   It writes no byte, so a selected standard error needs no write.
//   Inputs  : none
//   Outputs : none
//   Errors  : ILLEGAL FILE COMMAND (a selected file)
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : 16 bytes (frame record)
// ---------------------------------------------------------------------
    .globl _bsk_print_semi
    .p2align 2
_bsk_print_semi:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl Lrt_print_take               // x0 = output state
    ldr x10, [x0, #OS_COL]
    mov x11, #PRINT_PACK_WIDTH
    udiv x10, x10, x11              // floor(col / 3)
    add x10, x10, #1
    mul x10, x10, x11               // next multiple of 3
    str x10, [x0, #OS_COL]
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// _bsk_print_tab -- PRINT TAB(x) (LANGUAGE.md 8, DESIGN.md 6.7).
//   Purpose : m = fmod(trunc(x), 75) (both exact), m += 75 if m < 0;
//             if col < m then col = m (lazy; TAB never starts a line).
//             It writes no byte (standard error: nothing to write).
//   Inputs  : d0 = x (finite)
//   Outputs : none
//   Errors  : ILLEGAL FILE COMMAND (a selected file)
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = output state, d8 = x until the selection
//             is taken
//   Frame   : 32 bytes (frame record + x19 + d8)
// ---------------------------------------------------------------------
    .globl _bsk_print_tab
    .p2align 2
_bsk_print_tab:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    str d8, [sp, #24]
    fmov d8, d0
    bl Lrt_print_take               // selection first
    mov x19, x0
    frintz d0, d8                   // k = trunc(x)
    mov w9, #TAB_MODULUS
    ucvtf d1, w9
    bl _fmod                        // m = fmod(k, 75): |m| < 75, sign of k
    fcmp d0, #0.0
    b.ge 1f
    mov w9, #TAB_MODULUS
    ucvtf d1, w9
    fadd d0, d0, d1                 // negative: m + 75 (exact)
1:
    fcvtzu x0, d0                   // 0 .. 74 (-0 converts to 0)
    ldr x10, [x19, #OS_COL]
    cmp x10, x0
    b.hs 2f                         // already at or past m: ignored
    str x0, [x19, #OS_COL]          // move forward to m (lazy)
2:
    ldr d8, [sp, #24]
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _bsk_print_nl -- end of a PRINT without a trailing separator.
//   Inputs  : none
//   Outputs : none
//   Errors  : ILLEGAL FILE COMMAND, CAN'T WRITE FILE (a selected file)
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = output state
//   Frame   : 32 bytes (frame record + x19)
// ---------------------------------------------------------------------
    .globl _bsk_print_nl
    .p2align 2
_bsk_print_nl:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    bl Lrt_print_take               // x0 = output state
    mov x19, x0
    bl Lrt_print_newline
    mov x0, x19
    bl Lrt_print_fin                // standard error: written now
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _bsk_rt_print_bol -- start of a MAT PRINT item (DESIGN.md 6.5):
//   newline on stdout if its col != 0, so the matrix starts on a new
//   line.
//   Inputs  : none
//   Outputs : none
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : none (tail call or return)
// ---------------------------------------------------------------------
    .private_extern _bsk_rt_print_bol
    .p2align 2
_bsk_rt_print_bol:
    adrp x0, Lrt_print_os@PAGE
    add x0, x0, Lrt_print_os@PAGEOFF
    ldr x10, [x0, #OS_COL]
    cbnz x10, Lrt_print_newline     // mid-line: newline (tail call)
    ret

// ---------------------------------------------------------------------
// _bsk_rt_print_flush -- write the buffered stdout bytes now (before an
//   INPUT diagnostic on stderr, so the two streams stay in order, and
//   before a terminal line is read by INPUT # / IF END #0).
//   Inputs  : none
//   Outputs : none
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : none (tail call)
// ---------------------------------------------------------------------
    .private_extern _bsk_rt_print_flush
    .p2align 2
_bsk_rt_print_flush:
    adrp x0, Lrt_print_os@PAGE
    add x0, x0, Lrt_print_os@PAGEOFF
    b Lrt_print_flush

// ---------------------------------------------------------------------
// _bsk_rt_print_prompt -- the INPUT prompt on a terminal (LANGUAGE.md
//   7.15, DESIGN.md 6.7): write stdout's pending lazy spaces
//   (col - out), then "?" and a space; col = out = col + 2; flush.
//   Inputs  : none
//   Outputs : none
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = spaces still to write, x20 = stdout record
//   Frame   : 32 bytes (frame record + x19, x20)
// ---------------------------------------------------------------------
    .private_extern _bsk_rt_print_prompt
    .p2align 2
_bsk_rt_print_prompt:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    adrp x20, Lrt_print_os@PAGE
    add x20, x20, Lrt_print_os@PAGEOFF
    ldr x10, [x20, #OS_COL]
    ldr x11, [x20, #OS_OUT]
    sub x19, x10, x11               // pending lazy spaces
Lrt_print_prompt_pad:
    cbz x19, Lrt_print_prompt_q
    mov x0, x20
    mov w1, #' '
    bl Lrt_print_putc
    sub x19, x19, #1
    b Lrt_print_prompt_pad
Lrt_print_prompt_q:
    mov x0, x20
    mov w1, #'?'
    bl Lrt_print_putc
    mov x0, x20
    mov w1, #' '
    bl Lrt_print_putc               // this space is written, not lazy
    ldr x10, [x20, #OS_COL]
    add x10, x10, #2                // col = col + 2
    str x10, [x20, #OS_COL]
    str x10, [x20, #OS_OUT]         // out = col
    mov x0, x20
    bl Lrt_print_flush              // the user must see the prompt
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _bsk_rt_print_home -- after a line was read from a terminal the cursor
//   is at the start of a line: stdout col = out = 0 (nothing written).
//   Inputs  : none
//   Outputs : none
//   Clobbers: x9
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .private_extern _bsk_rt_print_home
    .p2align 2
_bsk_rt_print_home:
    adrp x9, Lrt_print_os@PAGE
    add x9, x9, Lrt_print_os@PAGEOFF
    str xzr, [x9, #OS_COL]
    str xzr, [x9, #OS_OUT]
    ret

// ---------------------------------------------------------------------
// _bsk_rt_finish_output -- termination step for END, STOP, OUT OF DATA
//   and every run-time error: newline if stdout's col != 0, then flush
//   stdout.
//   Inputs  : none
//   Outputs : w0 = 1 if stdout is broken (some output was lost; the
//             caller exits with status 1), else 0
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = stdout record
//   Frame   : 32 bytes (frame record + x19)
// ---------------------------------------------------------------------
    .private_extern _bsk_rt_finish_output
    .p2align 2
_bsk_rt_finish_output:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    adrp x19, Lrt_print_os@PAGE
    add x19, x19, Lrt_print_os@PAGEOFF
    ldr x10, [x19, #OS_COL]
    cbz x10, 1f                     // at column 0: no pending line
    mov x0, x19
    bl Lrt_print_newline
1:
    mov x0, x19
    bl Lrt_print_flush              // w0 = 0 ok, 1 = output lost
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _bsk_rt_err_bol -- standard error's pending line (LANGUAGE.md 15.3,
//   15.5 step 3; DESIGN.md 6.10): before a BASIC message (run-time
//   error, OUT OF DATA, END OF INPUT, the INPUT and MAT INPUT
//   diagnostics) and at every termination, a LF is written to fd 2 if
//   standard error's col != 0, and col = out = 0. Like every stderr
//   write, stdout's buffer is flushed before the LF and a failure is
//   ignored. The record never holds a byte between two calls, so at
//   col = 0 nothing is written anywhere.
//   Inputs  : none
//   Outputs : none
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = standard error's record
//   Frame   : 32 bytes (frame record + x19)
// ---------------------------------------------------------------------
    .private_extern _bsk_rt_err_bol
    .p2align 2
_bsk_rt_err_bol:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    adrp x19, Lrt_print_eos@PAGE
    add x19, x19, Lrt_print_eos@PAGEOFF
    ldr x10, [x19, #OS_COL]
    cbz x10, 1f                     // at column 0: no pending line
    mov x0, x19
    bl Lrt_print_newline            // LF into the buffer, col = out = 0
1:
    mov x0, x19
    bl Lrt_print_flush              // stdout first, then fd 2 (if any)
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lrt_print_fileos -- the output state record of file k.
//   Inputs  : w0 = k (1 .. LIM_FILES)
//   Outputs : x0 = record
//   Clobbers: x9
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_print_fileos:
    mov w9, #OS_SIZE
    umull x9, w0, w9                // k * OS_SIZE
    adrp x0, Lrt_print_os@PAGE
    add x0, x0, Lrt_print_os@PAGEOFF
    add x0, x0, x9
    ret

// ---------------------------------------------------------------------
// _bsk_rt_out_begin -- file k enters write mode (SCRATCH #k, after its
//   open succeeded, LANGUAGE.md 7.22): its output buffer is allocated at
//   the first SCRATCH (malloc(RT_FILEBUF_SIZE), reused later); the
//   buffer is emptied (unwritten output of an earlier write mode is
//   discarded), col = out = 0, the "write failed" flag is cleared and
//   fd is recorded.
//   Inputs  : w0 = k (1 .. LIM_FILES), w1 = fd open for writing
//   Outputs : none
//   Errors  : OUT OF ROOM (malloc failed; fd is closed first)
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = record, x20 = fd
//   Frame   : 32 bytes (frame record + x19, x20)
// ---------------------------------------------------------------------
    .private_extern _bsk_rt_out_begin
    .p2align 2
_bsk_rt_out_begin:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov w20, w1
    bl Lrt_print_fileos
    mov x19, x0
    ldr x9, [x19, #OS_BUF]
    cbnz x9, 1f                     // allocated by an earlier SCRATCH
    mov x0, #RT_FILEBUF_SIZE
    bl _malloc
    cbz x0, Lrt_print_oom
    str x0, [x19, #OS_BUF]
    mov x9, #RT_FILEBUF_SIZE
    str x9, [x19, #OS_CAP]
1:
    str xzr, [x19, #OS_FILL]        // buffer empty
    str xzr, [x19, #OS_COL]         // the file's own column state
    str xzr, [x19, #OS_OUT]
    str w20, [x19, #OS_FD]
    str wzr, [x19, #OS_FAILED]      // a new SCRATCH clears the flag
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
Lrt_print_oom:
    mov w0, w20
    bl _close                       // the new file's fd is not leaked
    mov w0, #ERR_OUT_OF_ROOM
    bl _bsk_err                     // noreturn

// ---------------------------------------------------------------------
// _bsk_rt_out_end -- finish the output of file k (write mode): if its
//   "write failed" flag is set nothing is done (the file is skipped);
//   else a newline if col != 0, then the buffered bytes are written.
//   Used by RESTORE #k (w1 = 1: a failure raises CAN'T WRITE FILE, as
//   at every other moment of the run) and at termination (w1 = 0: a
//   failure is only reported, the caller goes on with the other files).
//   Inputs  : w0 = k (1 .. LIM_FILES), w1 = 1 raise / 0 report only
//   Outputs : w0 = 1 if the file's output failed (now or earlier),
//             else 0
//   Errors  : CAN'T WRITE FILE (w1 = 1 only)
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = record
//   Frame   : 32 bytes (frame record + x19)
// ---------------------------------------------------------------------
    .private_extern _bsk_rt_out_end
    .p2align 2
_bsk_rt_out_end:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    eor w9, w1, #1                  // noraise = !raise
    adrp x10, Lrt_print_noraise@PAGE
    str w9, [x10, Lrt_print_noraise@PAGEOFF]
    bl Lrt_print_fileos
    mov x19, x0
    ldr w9, [x19, #OS_FAILED]
    cbnz w9, 2f                     // flagged: skipped by every flush
    ldr x10, [x19, #OS_COL]
    cbz x10, 1f                     // no pending line
    mov x0, x19
    bl Lrt_print_newline            // (may write a full buffer)
1:
    mov x0, x19
    bl Lrt_print_flush
2:
    adrp x10, Lrt_print_noraise@PAGE
    str wzr, [x10, Lrt_print_noraise@PAGEOFF]   // raising again
    ldr w0, [x19, #OS_FAILED]
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _bsk_rt_out_failed -- has a write to file k failed?
//   Inputs  : w0 = k (1 .. LIM_FILES)
//   Outputs : w0 = the file's "write failed" flag (0 or 1)
//   Clobbers: x0, x9
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .private_extern _bsk_rt_out_failed
    .p2align 2
_bsk_rt_out_failed:
    mov w9, #OS_SIZE
    umull x9, w0, w9
    adrp x0, Lrt_print_os@PAGE
    add x0, x0, Lrt_print_os@PAGEOFF
    add x0, x0, x9                  // &record[k]
    ldr w0, [x0, #OS_FAILED]
    ret

// ---------------------------------------------------------------------
// State.
//   Lrt_print_os      RT_PR_NOS output state records: [0] standard
//                     output (buffer _bsk_rt_buf, fd 1), [k] file k
//                     (buffer malloc'd at its first SCRATCH)
//   _bsk_rt_buf       RT_OUTBUF_SIZE bytes of stdout buffer
//   Lrt_print_noraise u32 1 while _bsk_rt_out_end finishes a file at
//                     termination (a failed write is only reported)
//   _bsk_rt_fsel      u32 pending file selection, 0 = none, k + 2
//   Lrt_print_eos     standard error's output record (Baysick
//                     extensions): buffer Lrt_print_ebuf, fd 2
//   Lrt_print_ebuf    RT_OUTBUF_SIZE bytes of standard-error buffer
// ---------------------------------------------------------------------
    .section __DATA,__data
    .p2align 3
Lrt_print_os:
    .quad 0                         // OS_COL
    .quad 0                         // OS_OUT
    .quad 0                         // OS_FILL
    .quad _bsk_rt_buf               // OS_BUF
    .if (. - Lrt_print_os) != OS_BUF + 8
        .error "stdout record: OS_COL..OS_BUF offsets disagree with the positional layout"
    .endif
    .quad RT_OUTBUF_SIZE            // OS_CAP
    .if (. - Lrt_print_os) != OS_FD
        .error "stdout record: OS_FD is not the sixth field"
    .endif
    .long 1                         // OS_FD: standard output
    .long 0                         // OS_FAILED: not broken
    .if (. - Lrt_print_os) != OS_SIZE
        .error "stdout record: size disagrees with OS_SIZE"
    .endif
    .space OS_SIZE * (RT_PR_NOS - 1)    // files: zero = no buffer yet
Lrt_print_eos:
    .quad 0                         // OS_COL
    .quad 0                         // OS_OUT
    .quad 0                         // OS_FILL
    .quad Lrt_print_ebuf            // OS_BUF
    .if (. - Lrt_print_eos) != OS_BUF + 8
        .error "stderr record: OS_COL..OS_BUF offsets disagree with the positional layout"
    .endif
    .quad RT_OUTBUF_SIZE            // OS_CAP
    .if (. - Lrt_print_eos) != OS_FD
        .error "stderr record: OS_FD is not the sixth field"
    .endif
    .long 2                         // OS_FD: standard error
    .long 0                         // OS_FAILED: never set (failures ignored)
    .if (. - Lrt_print_eos) != OS_SIZE
        .error "stderr record: size disagrees with OS_SIZE"
    .endif

.zerofill __DATA,__bss,_bsk_rt_buf,RT_OUTBUF_SIZE,4
.zerofill __DATA,__bss,Lrt_print_ebuf,RT_OUTBUF_SIZE,4
.zerofill __DATA,__bss,Lrt_print_noraise,4,2
    .private_extern _bsk_rt_fsel
.zerofill __DATA,__bss,_bsk_rt_fsel,4,2

.if (OS_FD != 40) || (OS_SIZE != 48)
    .error "rt_print.s: the static stdout record assumes this OS_* layout"
.endif
