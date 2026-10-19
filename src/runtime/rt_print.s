// =====================================================================
// src/runtime/rt_print.s -- PRINT column logic and buffered stdout.
//
// Defines (global, runtime.inc):
//   _bsk_print_num _bsk_print_str _bsk_print_comma _bsk_print_semi
//   _bsk_print_nl
// Defines (private to the runtime, .private_extern):
//   _bsk_rt_finish_output   pending-line newline + flush (END / errors);
//                           reports whether stdout broke
//   _bsk_rt_write_all       write(2) loop handling short writes / EINTR
//
// Column model (LANGUAGE.md section 8): `col` is the logical column,
// `out` the number of characters physically written on this line.
// Spaces are lazy: a space only advances `col`; before any other
// character, col - out spaces are written. Hence no trailing blanks.
// Output goes through a RT_OUTBUF_SIZE-byte buffer, flushed when full
// and at termination. No stdio is used.
//
// Broken stdout (LANGUAGE.md section 10): if write(2) to fd 1 fails with
// an error other than EINTR, or writes 0 bytes, stdout is marked broken;
// all further output is discarded and _bsk_rt_finish_output reports it,
// so END / STOP / OUT OF DATA exit with status 1 instead of 0.
// =====================================================================
.include "baysick.inc"

.equ RT_EINTR, 4                    // <errno.h> EINTR on Darwin
.equ RT_NUMBUF, 48                  // stack buffer for one number field
                                    // (longest field: "-1.23457E-308 " = 14)

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
// Lrt_print_flush -- write the buffered bytes to fd 1 and empty the buffer.
//   Purpose : once stdout is broken (_bsk_rt_broken != 0) the bytes are
//             discarded; a failed write marks stdout broken.
//   Inputs  : none
//   Outputs : none
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : 16 bytes (frame record)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_print_flush:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x9, _bsk_rt_fill@PAGE
    ldr x2, [x9, _bsk_rt_fill@PAGEOFF]  // number of buffered bytes
    cbz x2, 1f                          // nothing to write
    str xzr, [x9, _bsk_rt_fill@PAGEOFF] // buffer is empty afterwards
    adrp x10, _bsk_rt_broken@PAGE
    ldr w11, [x10, _bsk_rt_broken@PAGEOFF]
    cbnz w11, 1f                        // stdout broken: discard
    adrp x1, _bsk_rt_buf@PAGE
    add x1, x1, _bsk_rt_buf@PAGEOFF
    mov w0, #1                          // stdout
    bl _bsk_rt_write_all
    cbz w0, 1f                          // written completely
    adrp x10, _bsk_rt_broken@PAGE
    mov w11, #1
    str w11, [x10, _bsk_rt_broken@PAGEOFF] // write failed: stdout broken
1:
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Lrt_print_putc -- append one byte to the stdout buffer.
//   Inputs  : w0 = byte
//   Outputs : none
//   Clobbers: x0-x17, d0-d7, d16-d31 (may flush via libc write)
//   Callee-saved used: none
//   Frame   : none (leaf, except for a tail call to Lrt_print_flush)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_print_putc:
    adrp x9, _bsk_rt_fill@PAGE
    ldr x10, [x9, _bsk_rt_fill@PAGEOFF]
    adrp x11, _bsk_rt_buf@PAGE
    add x11, x11, _bsk_rt_buf@PAGEOFF
    strb w0, [x11, x10]                 // buf[fill] = byte
    add x10, x10, #1
    str x10, [x9, _bsk_rt_fill@PAGEOFF]
    cmp x10, #RT_OUTBUF_SIZE
    b.hs Lrt_print_flush                // full: flush (tail call)
    ret

// ---------------------------------------------------------------------
// Lrt_print_newline -- the "newline" action: write LF, col = out = 0.
//   Inputs  : none
//   Outputs : none
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : 16 bytes (frame record)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_print_newline:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov w0, #'\n'
    bl Lrt_print_putc
    adrp x9, _bsk_rt_col@PAGE
    str xzr, [x9, _bsk_rt_col@PAGEOFF]  // col = 0
    adrp x9, _bsk_rt_out@PAGE
    str xzr, [x9, _bsk_rt_out@PAGEOFF]  // out = 0
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Lrt_print_emit -- the "emit(c)" action of LANGUAGE.md section 8.
//   Purpose : a space only advances col; any other byte is preceded by
//             col - out real spaces, then written; col += 1; out = col.
//   Inputs  : w0 = byte
//   Outputs : none
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = the byte, x20 = spaces still to write
//   Frame   : 32 bytes (frame record + x19, x20)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_print_emit:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    and w19, w0, #0xFF              // the byte
    adrp x9, _bsk_rt_col@PAGE
    ldr x10, [x9, _bsk_rt_col@PAGEOFF]
    cmp w19, #' '
    b.ne Lrt_print_emit_real
    add x10, x10, #1                // lazy space: col += 1 only
    str x10, [x9, _bsk_rt_col@PAGEOFF]
    b Lrt_print_emit_done
Lrt_print_emit_real:
    adrp x11, _bsk_rt_out@PAGE
    ldr x11, [x11, _bsk_rt_out@PAGEOFF]
    sub x20, x10, x11               // pending spaces = col - out
Lrt_print_emit_pad:
    cbz x20, Lrt_print_emit_char
    mov w0, #' '
    bl Lrt_print_putc
    sub x20, x20, #1
    b Lrt_print_emit_pad
Lrt_print_emit_char:
    mov w0, w19
    bl Lrt_print_putc               // the byte itself
    adrp x9, _bsk_rt_col@PAGE
    ldr x10, [x9, _bsk_rt_col@PAGEOFF]
    add x10, x10, #1                // col += 1
    str x10, [x9, _bsk_rt_col@PAGEOFF]
    adrp x11, _bsk_rt_out@PAGE
    str x10, [x11, _bsk_rt_out@PAGEOFF] // out = col
Lrt_print_emit_done:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _bsk_print_str -- PRINT a string item (label).
//   Purpose : emit every byte; never truncated or wrapped.
//   Inputs  : x0 = pointer to the bytes, x1 = length (may be 0)
//   Outputs : none
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = cursor, x20 = end pointer
//   Frame   : 32 bytes (frame record + x19, x20)
// ---------------------------------------------------------------------
    .globl _bsk_print_str
    .p2align 2
_bsk_print_str:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0                     // cursor
    add x20, x0, x1                 // end
Lrt_print_str_loop:
    cmp x19, x20
    b.hs Lrt_print_str_done
    ldrb w0, [x19], #1              // next byte
    bl Lrt_print_emit
    b Lrt_print_str_loop
Lrt_print_str_done:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _bsk_print_num -- PRINT a number item.
//   Purpose : format the field F (LANGUAGE.md section 9); if fewer than
//             PRINT_MIN_ROOM columns remain before PRINT_LINE_WIDTH,
//             newline first; then emit every character of F.
//   Inputs  : d0 = value (finite)
//   Outputs : none
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = cursor in the field, x20 = end of field
//   Frame   : 32 bytes (frame record + x19, x20) + RT_NUMBUF field buffer
// ---------------------------------------------------------------------
    .globl _bsk_print_num
    .p2align 2
_bsk_print_num:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    sub sp, sp, #RT_NUMBUF          // field buffer at [sp]
    mov x0, sp
    bl _bsk_rt_fmtnum               // x0 = field length
    mov x19, sp                     // cursor
    add x20, sp, x0                 // end of field
    // Room check: newline if 75 - col < 12, i.e. col > 63 (col may
    // exceed 75 after a long label; the unsigned test covers that).
    adrp x9, _bsk_rt_col@PAGE
    ldr x10, [x9, _bsk_rt_col@PAGEOFF]
    cmp x10, #(PRINT_LINE_WIDTH - PRINT_MIN_ROOM)
    b.ls Lrt_print_num_loop
    bl Lrt_print_newline
Lrt_print_num_loop:
    cmp x19, x20
    b.hs Lrt_print_num_done
    ldrb w0, [x19], #1
    bl Lrt_print_emit
    b Lrt_print_num_loop
Lrt_print_num_done:
    add sp, sp, #RT_NUMBUF
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _bsk_print_comma -- PRINT ',' : next zone strictly to the right.
//   Purpose : col = (col / 15 + 1) * 15; newline if col >= 75.
//   Inputs  : none
//   Outputs : none
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : 16 bytes (frame record)
// ---------------------------------------------------------------------
    .globl _bsk_print_comma
    .p2align 2
_bsk_print_comma:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x9, _bsk_rt_col@PAGE
    ldr x10, [x9, _bsk_rt_col@PAGEOFF]
    mov x11, #PRINT_ZONE_WIDTH
    udiv x10, x10, x11              // current zone index
    add x10, x10, #1                // next zone
    mul x10, x10, x11               // its first column
    str x10, [x9, _bsk_rt_col@PAGEOFF]
    cmp x10, #PRINT_LINE_WIDTH
    b.lo 1f                         // still on this line
    bl Lrt_print_newline
1:
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// _bsk_print_semi -- PRINT ';' after a number: next multiple of 3
//   strictly to the right; no newline is forced.
//   Inputs  : none
//   Outputs : none
//   Clobbers: x9-x11
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .globl _bsk_print_semi
    .p2align 2
_bsk_print_semi:
    adrp x9, _bsk_rt_col@PAGE
    ldr x10, [x9, _bsk_rt_col@PAGEOFF]
    mov x11, #PRINT_PACK_WIDTH
    udiv x10, x10, x11              // floor(col / 3)
    add x10, x10, #1
    mul x10, x10, x11               // next multiple of 3
    str x10, [x9, _bsk_rt_col@PAGEOFF]
    ret

// ---------------------------------------------------------------------
// _bsk_print_nl -- end of a PRINT without a trailing separator.
//   Inputs  : none
//   Outputs : none
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : none (tail call)
// ---------------------------------------------------------------------
    .globl _bsk_print_nl
    .p2align 2
_bsk_print_nl:
    b Lrt_print_newline

// ---------------------------------------------------------------------
// _bsk_rt_finish_output -- termination step for END, STOP, OUT OF DATA
//   and every run-time error: newline if col != 0, then flush stdout.
//   Inputs  : none
//   Outputs : w0 = 1 if stdout is broken (some output was lost; the
//             caller exits with status 1), else 0
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : 16 bytes (frame record)
// ---------------------------------------------------------------------
    .private_extern _bsk_rt_finish_output
    .p2align 2
_bsk_rt_finish_output:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x9, _bsk_rt_col@PAGE
    ldr x10, [x9, _bsk_rt_col@PAGEOFF]
    cbz x10, 1f                     // at column 0: no pending line
    bl Lrt_print_newline
1:
    bl Lrt_print_flush
    adrp x9, _bsk_rt_broken@PAGE
    ldr w0, [x9, _bsk_rt_broken@PAGEOFF] // 0 = ok, 1 = output lost
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// State (file-local, zero-initialised):
//   _bsk_rt_col   u64 logical column
//   _bsk_rt_out   u64 characters physically written on this line
//   _bsk_rt_fill  u64 bytes in the stdout buffer
//   _bsk_rt_buf   RT_OUTBUF_SIZE bytes of stdout buffer
//   _bsk_rt_broken u32 1 once a write to stdout failed, else 0
// ---------------------------------------------------------------------
.zerofill __DATA,__bss,_bsk_rt_col,8,3
.zerofill __DATA,__bss,_bsk_rt_out,8,3
.zerofill __DATA,__bss,_bsk_rt_fill,8,3
.zerofill __DATA,__bss,_bsk_rt_buf,RT_OUTBUF_SIZE,4
.zerofill __DATA,__bss,_bsk_rt_broken,4,2
