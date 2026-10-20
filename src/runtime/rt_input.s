// =====================================================================
// src/runtime/rt_input.s -- INPUT, MAT INPUT and (Fifth Edition) INPUT #
// and IF END #: the line readers, field scanning and the three INPUT
// diagnostics (DESIGN.md 6.7, 6.8; LANGUAGE.md 7.14.8, 7.15, 7.21,
// 7.25, 7.26).
//
// Defines (global, runtime.inc):
//   _bsk_input_begin _bsk_input_num _bsk_input_str _bsk_input_str_el
//   _bsk_input_end
//   _bsk_mat_input _bsk_smat_input
// Defines (private to the runtime, .private_extern):
//   _bsk_rt_parsenum   the numeric-field check and conversion (VAL)
//   _bsk_rt_in_linput  Baysick extensions: the next line of LINPUT (rt_ext.s)
//   Fifth Edition (rt_files.s):
//   _bsk_rt_rd_setup   file k's reader: buffers (once), fd, emptied
//   _bsk_rt_rd_reset   file k's reader emptied (RESTORE #, SCRATCH #)
//   _bsk_rt_rd_atend   IF END #k: does reader k hold or get a byte?
// Uses: _bsk_rt_print_prompt/_home/_flush, _bsk_rt_err_bol,
// _bsk_rt_write_all (rt_print.s),
// _bsk_rt_fsel (rt_print.s), _bsk_rt_file_ropen (rt_files.s),
// _bsk_rt_str_setbytes (rt_str.s), _bsk_saref1 (rt_array.s), _bsk_rt_num
// (rt_ed4.s), _bsk_err.
//
// Readers. Standard input and every file number have a reader record
// (RD_*, below; [0] standard input with static buffers, [k] file k with
// buffers malloc'd when the file is first opened for reading). One line
// routine (Lrt_in_getline) and one field routine serve all of them; the
// INPUT dialogue (prompt, diagnostics, END OF INPUT) and the INPUT #
// rules (no prompt, no diagnostics, END OF FILE, INCORRECT FORMAT IN
// FILE) are the only difference, selected by a mode flag.
//
// Chunk rule (LANGUAGE.md 7.21, DESIGN.md 6.8). A reader calls
// read(fd, chunk, RT_INBUF_SIZE) only when it needs a byte and holds no
// unread byte (EINTR retried; any other error or 0 bytes is the end of
// that reader for this request); it keeps the bytes it received until
// they are consumed and never reads ahead otherwise. The end is not
// remembered: the next request that needs a byte reads again, so a
// file read through another number sees what was written to it since.
//
// Lines. A line is assembled into the reader's line buffer of
// LIM_INPUT_LINE + 16 bytes: the bytes up to the next LF; one CR right
// before the LF is removed; a non-empty last line without LF counts. A
// line longer than LIM_INPUT_LINE bytes after the CR removal is INPUT
// LINE TOO LONG (detected as soon as more than LIM_INPUT_LINE + 1 bytes
// precede the LF, or at the LF / end of input). End of input when a line
// is needed: END OF INPUT (dialogue, exit 0) or END OF FILE (INPUT #).
// isatty(0) is asked once, at the first standard-input request; on a
// terminal each standard-input line request first writes the prompt
// (dialogue) or flushes stdout (INPUT #0), and the column state is reset
// after the line was read (_bsk_rt_print_home).
//
// Fields. A field ends at the next comma outside quotes (every `"`
// toggles the quote state); an empty or all-blank (0x20) line has no
// field. Numeric field: after removing every blank, [+|-] mantissa
// [E|e [+|-] digits] with at most 9 mantissa digits and 1..2 exponent
// digits (LANGUAGE.md 4.1); the value is strtod of that blank-free text.
// String field: after its leading blanks either `"` bytes `"` followed by
// blanks only, or unquoted bytes without `"` (and, in MAT INPUT, without
// `&`); the value is the bytes between the quotes / the field without its
// leading blanks.
//
// Each reader keeps a cursor into its current line (RD_FPOS) and whether
// a field is left (RD_FLEFT). MAT INPUT collects the text of all its
// lines (`&` continuation removed) in a growable malloc buffer, one line
// per LF-terminated record, validates every field and counts them, and
// only then stores (a second scan of the same text), so nothing is
// assigned unless the whole input is good (transactional).
//
// Pending file selection (DESIGN.md 6.8): every input entry point takes
// _bsk_rt_fsel (reads it and resets it to none) on entry. None: the
// INPUT dialogue on standard input. File k: the INPUT # rules on reader
// k (k >= 1 must be in read mode and is opened if needed,
// _bsk_rt_file_ropen; k = 0 is standard input). Standard error (-1,
// Baysick extensions) is INVALID FILE NUMBER for every input entry point
// and for LINPUT (_bsk_rt_in_linput, used by rt_ext.s).
// =====================================================================
.include "baysick.inc"

.equ RT_EINTR, 4                    // <errno.h> EINTR on Darwin
.equ RT_IN_LINEBUF, LIM_INPUT_LINE + 16 // line buffer: limit + CR + slack
.equ RT_IN_NUMBUF, 32               // blank-free numeric field text (+NUL)
.equ RT_IN_TTY_NO, 1                // Lrt_in_tty: stdin is not a terminal
.equ RT_IN_TTY_YES, 2               // Lrt_in_tty: stdin is a terminal
.equ RT_IN_TEXT_MIN, 4096           // first size of the MAT INPUT text buffer
.equ RT_IN_DIALOGUE, 0              // mode: INPUT / MAT INPUT dialogue
.equ RT_IN_FILE, 1                  // mode: INPUT # rules

// Reader record (runtime-private, this file only).
.equ RD_FD,     0                   // u32 file descriptor
.equ RD_FLEFT,  4                   // u32 1 if a field is left on the line
.equ RD_CHUNK,  8                   // ptr chunk buffer, RT_INBUF_SIZE bytes
.equ RD_RPOS,   16                  // u64 next unread byte in the chunk
.equ RD_RLEN,   24                  // u64 bytes in the chunk
.equ RD_LINE,   32                  // ptr line buffer, RT_IN_LINEBUF bytes
.equ RD_LLEN,   40                  // u64 length of the current line
.equ RD_FPOS,   48                  // u64 start of the next field
.equ RD_SIZE,   56

// RT_IN_PEEK: w6 = the byte at x5, or 0 once x5 has reached x3 (the end
// of the text being checked). Used by Lrt_in_parsenum; local label 9.
.macro RT_IN_PEEK
    mov w6, #0
    cmp x5, x3
    b.hs 9f
    ldrb w6, [x5]
9:
.endm

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// Lrt_in_istty -- is standard input a terminal? isatty(0) is asked once,
//   at the first standard-input request, and remembered.
//   Inputs  : none
//   Outputs : w0 = 1 for a terminal, else 0
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : 16 bytes (frame record)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_in_istty:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x9, Lrt_in_tty@PAGE
    ldr w10, [x9, Lrt_in_tty@PAGEOFF]
    cbnz w10, 1f
    mov w0, #0
    bl _isatty                      // 1 for a terminal
    cmp w0, #0
    mov w10, #RT_IN_TTY_NO
    mov w11, #RT_IN_TTY_YES
    csel w10, w11, w10, ne
    adrp x9, Lrt_in_tty@PAGE
    str w10, [x9, Lrt_in_tty@PAGEOFF]
1:
    cmp w10, #RT_IN_TTY_YES
    cset w0, eq
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Lrt_in_refill -- the chunk read of a reader that holds no unread byte:
//   read(fd, chunk, RT_INBUF_SIZE), EINTR retried.
//   Inputs  : x0 = reader record
//   Outputs : w0 = 1 if bytes arrived (RD_RPOS = 0, RD_RLEN = count),
//             0 at the end (0 bytes or an error; RD_RPOS = RD_RLEN = 0)
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = reader
//   Frame   : 32 bytes (frame record + x19)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_in_refill:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov x19, x0
    str xzr, [x19, #RD_RPOS]        // nothing unread from now on
    str xzr, [x19, #RD_RLEN]
1:
    ldr w0, [x19, #RD_FD]
    ldr x1, [x19, #RD_CHUNK]
    mov x2, #RT_INBUF_SIZE
    bl _read
    cmp x0, #0
    b.gt 2f
    b.eq 3f                         // 0 bytes: the end
    bl ___error                     // -1: EINTR is retried
    ldr w9, [x0]
    cmp w9, #RT_EINTR
    b.eq 1b
3:
    mov w0, #0                      // any other error = the end
    b 4f
2:
    str x0, [x19, #RD_RLEN]         // the new chunk, from its first byte
    mov w0, #1
4:
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lrt_in_getline -- read the next line of a reader into its line buffer.
//   Purpose : the line rules of the header (prompt / flush on a
//             terminal, CR removal, length limit, end of input);
//             afterwards the reader's field cursor is at the start of
//             the line and RD_FLEFT says whether the line has a field
//             (not empty/all blank).
//   Inputs  : x0 = reader record, w1 = RT_IN_DIALOGUE or RT_IN_FILE
//   Outputs : RD_LINE / RD_LLEN hold the line
//   Errors  : END OF INPUT (dialogue, exit 0) / END OF FILE (file
//             rules), INPUT LINE TOO LONG
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = line length so far, x20 = line buffer,
//             x21 = start of the unread bytes, x22 = their count,
//             x23 = reader, x24 = mode
//   Frame   : 80 bytes (frame record + x19..x24 + "LF found" at
//             [sp,#64])
// ---------------------------------------------------------------------
    .p2align 2
Lrt_in_getline:
    stp x29, x30, [sp, #-80]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    mov x23, x0
    mov w24, w1
    // Standard input on a terminal: the dialogue writes its prompt,
    // INPUT #0 only flushes stdout so the user sees all output.
    adrp x9, Lrt_in_rd@PAGE
    add x9, x9, Lrt_in_rd@PAGEOFF
    cmp x23, x9
    b.ne 2f                         // a file: no terminal handling
    bl Lrt_in_istty
    cbz w0, 2f
    cbnz w24, 1f
    bl _bsk_rt_print_prompt         // pending spaces, "? ", flush
    b 2f
1:
    bl _bsk_rt_print_flush
2:
    mov x19, #0                     // line length
    ldr x20, [x23, #RD_LINE]
Lrt_in_getline_more:
    // Unread bytes in the chunk? Else one chunk read.
    ldr x10, [x23, #RD_RPOS]
    ldr x11, [x23, #RD_RLEN]
    cmp x10, x11
    b.lo Lrt_in_getline_scan
    mov x0, x23
    bl Lrt_in_refill
    cbz w0, Lrt_in_getline_eof      // the end of this reader
    mov x10, #0
    ldr x11, [x23, #RD_RLEN]
Lrt_in_getline_scan:
    // x10 = rpos, x11 = rlen: look for the LF in the unread bytes.
    ldr x21, [x23, #RD_CHUNK]
    add x21, x21, x10               // first unread byte
    sub x22, x11, x10               // unread count
    mov x0, x21
    mov w1, #'\n'
    mov x2, x22
    bl _memchr                      // x0 = the LF or NULL
    cbz x0, 1f
    sub x22, x0, x21                // bytes before the LF
1:
    // More than LIM_INPUT_LINE + 1 bytes before the LF can never become
    // a legal line (at most one CR is removed): stop now.
    add x9, x19, x22
    mov x10, #LIM_INPUT_LINE
    add x10, x10, #1
    cmp x9, x10
    b.hi Lrt_in_getline_toolong
    str x0, [sp, #64]               // keep "LF found" across memcpy
    add x0, x20, x19
    mov x1, x21
    mov x2, x22
    bl _memcpy                      // append to the line
    ldr x9, [sp, #64]
    add x19, x19, x22
    ldr x11, [x23, #RD_RPOS]
    add x11, x11, x22
    cbz x9, 2f
    add x11, x11, #1                // consume the LF too
    str x11, [x23, #RD_RPOS]
    b Lrt_in_getline_lf
2:
    str x11, [x23, #RD_RPOS]        // chunk used up: read more
    b Lrt_in_getline_more
Lrt_in_getline_lf:
    // One CR immediately before the LF is removed.
    cbz x19, Lrt_in_getline_done
    sub x9, x19, #1
    ldrb w10, [x20, x9]
    cmp w10, #'\r'
    b.ne 1f
    mov x19, x9
1:
    mov x10, #LIM_INPUT_LINE
    cmp x19, x10
    b.hi Lrt_in_getline_toolong
    b Lrt_in_getline_done
Lrt_in_getline_eof:
    // End of input: a non-empty unterminated last line still counts.
    cbz x19, Lrt_in_getline_end
    mov x10, #LIM_INPUT_LINE
    cmp x19, x10
    b.hi Lrt_in_getline_toolong
Lrt_in_getline_done:
    str x19, [x23, #RD_LLEN]
    str xzr, [x23, #RD_FPOS]        // field cursor at the start
    mov x0, x20
    mov x1, x19
    bl Lrt_in_allblank
    eor w0, w0, #1                  // a field is left unless all blank
    str w0, [x23, #RD_FLEFT]
    adrp x9, Lrt_in_rd@PAGE
    add x9, x9, Lrt_in_rd@PAGEOFF
    cmp x23, x9
    b.ne 1f
    adrp x9, Lrt_in_tty@PAGE
    ldr w10, [x9, Lrt_in_tty@PAGEOFF]
    cmp w10, #RT_IN_TTY_YES
    b.ne 1f
    bl _bsk_rt_print_home           // the terminal is at a new line
1:
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #80
    ret
Lrt_in_getline_end:
    mov w0, #ERR_END_OF_INPUT       // dialogue: newline, flush, exit 0
    mov w9, #ERR_END_OF_FILE        // INPUT #: exit 1
    cmp w24, #RT_IN_DIALOGUE
    csel w0, w0, w9, eq
    bl _bsk_err
Lrt_in_getline_toolong:
    mov w0, #ERR_INPUT_LINE_TOO_LONG
    bl _bsk_err

// ---------------------------------------------------------------------
// Lrt_in_allblank -- is a byte range empty or all blanks (0x20)?
//   Inputs  : x0 = pointer, x1 = length
//   Outputs : w0 = 1 if every byte is a blank (or the range is empty),
//             else 0
//   Clobbers: x0, x1, w9
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_in_allblank:
    cbz x1, 2f
    ldrb w9, [x0], #1
    cmp w9, #' '
    b.ne 1f
    sub x1, x1, #1
    b Lrt_in_allblank
1:
    mov w0, #0
    ret
2:
    mov w0, #1
    ret

// ---------------------------------------------------------------------
// Lrt_in_field -- the next field of a line.
//   Purpose : from base + pos, scan to the next comma outside quotes
//             (every `"` toggles the quote state) or to the end.
//   Inputs  : x0 = line base, x1 = pos (start of the field), x2 = line
//             length
//   Outputs : x0 = field start, x1 = field length, x2 = position after
//             the field's comma (or the line length), x3 = 1 if the field
//             ended at a comma (another field follows), else 0
//   Clobbers: x0-x7
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_in_field:
    add x4, x0, x1                  // field start
    add x5, x0, x2                  // line end
    mov x6, x4                      // cursor
    mov w7, #0                      // inside quotes?
Lrt_in_field_loop:
    cmp x6, x5
    b.hs Lrt_in_field_eol
    ldrb w3, [x6]
    cmp w3, #'"'
    b.ne 1f
    eor w7, w7, #1                  // a quote opens or closes
    b 2f
1:
    cmp w3, #','
    b.ne 2f
    cbz w7, Lrt_in_field_comma      // a comma outside quotes ends it
2:
    add x6, x6, #1
    b Lrt_in_field_loop
Lrt_in_field_comma:
    sub x1, x6, x4                  // length
    add x6, x6, #1                  // skip the comma
    sub x2, x6, x0                  // new position
    mov x0, x4
    mov x3, #1                      // a field follows
    ret
Lrt_in_field_eol:
    sub x1, x6, x4
    mov x0, x4                      // x2 = line length already
    mov x3, #0                      // last field of the line
    ret

// ---------------------------------------------------------------------
// _bsk_rt_parsenum, Lrt_in_parsenum -- validate and convert a numeric
//   field (also the whole argument of VAL, rt_ed5.s).
//   Purpose : copy the field without its blanks (at most RT_IN_NUMBUF-1
//             bytes, more cannot be valid), check
//             [+|-] mantissa [E|e [+|-] digits] (1..9 mantissa digits,
//             1..2 exponent digits), then strtod the text.
//   Inputs  : x0 = field pointer, x1 = field length
//   Outputs : w0 = 1 and d0 = value if valid, else w0 = 0
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : 48 bytes (frame record + RT_IN_NUMBUF text at [sp,#16])
// ---------------------------------------------------------------------
    .private_extern _bsk_rt_parsenum
    .p2align 2
_bsk_rt_parsenum:
Lrt_in_parsenum:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    add x2, sp, #16                 // text buffer
    mov x3, x2                      // write cursor
    add x4, x2, #(RT_IN_NUMBUF - 1) // room for the text, NUL after
    add x1, x0, x1                  // field end
Lrt_in_parsenum_copy:
    cmp x0, x1
    b.hs Lrt_in_parsenum_check
    ldrb w5, [x0], #1
    cmp w5, #' '
    b.eq Lrt_in_parsenum_copy       // blanks are removed
    cmp x3, x4
    b.hs Lrt_in_parsenum_bad        // too long to be a constant
    strb w5, [x3], #1
    b Lrt_in_parsenum_copy
Lrt_in_parsenum_check:
    strb wzr, [x3]                  // NUL for strtod
    // Grammar check on [x2, x3): x5 = cursor, w6 = current byte (0 at
    // the end; a NUL inside the text then fails the final end test).
    mov x5, x2
    mov w7, #0                      // mantissa digits
    RT_IN_PEEK
    cmp w6, #'+'
    b.eq 1f
    cmp w6, #'-'
    b.ne 2f
1:
    add x5, x5, #1                  // optional sign
2:
    RT_IN_PEEK                      // integer digits
    sub w8, w6, #'0'
    cmp w8, #9
    b.hi 3f
    add w7, w7, #1
    add x5, x5, #1
    b 2b
3:
    cmp w6, #'.'
    b.ne 5f
    add x5, x5, #1
4:
    RT_IN_PEEK                      // fraction digits
    sub w8, w6, #'0'
    cmp w8, #9
    b.hi 5f
    add w7, w7, #1
    add x5, x5, #1
    b 4b
5:
    cbz w7, Lrt_in_parsenum_bad     // no mantissa digit
    cmp w7, #LIM_NUM_DIGITS
    b.hi Lrt_in_parsenum_bad        // more than 9 digits
    cmp w6, #'E'
    b.eq 6f
    cmp w6, #'e'
    b.ne Lrt_in_parsenum_end
6:
    add x5, x5, #1                  // exponent
    RT_IN_PEEK
    cmp w6, #'+'
    b.eq 7f
    cmp w6, #'-'
    b.ne 8f
7:
    add x5, x5, #1
8:
    mov w7, #0                      // exponent digits
10:
    RT_IN_PEEK
    sub w8, w6, #'0'
    cmp w8, #9
    b.hi 11f
    add w7, w7, #1
    add x5, x5, #1
    b 10b
11:
    cbz w7, Lrt_in_parsenum_bad     // E without digits
    cmp w7, #LIM_EXP_DIGITS
    b.hi Lrt_in_parsenum_bad        // more than 2 exponent digits
Lrt_in_parsenum_end:
    cmp x5, x3
    b.ne Lrt_in_parsenum_bad        // something follows the constant
    mov x0, x2
    mov x1, #0
    bl _strtod                      // d0 = nearest double
    mov w0, #1
    ldp x29, x30, [sp], #48
    ret
Lrt_in_parsenum_bad:
    mov w0, #0
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// Lrt_in_parsestr -- validate a string field and find its value.
//   Inputs  : x0 = field pointer, x1 = field length, w2 = 1 if `&` is
//             not allowed in an unquoted field (MAT INPUT), else 0
//   Outputs : w0 = 1 if valid, else 0; x1 = value pointer, x2 = value
//             length (when valid)
//   Clobbers: x0-x6
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_in_parsestr:
    add x3, x0, x1                  // field end
1:
    cmp x0, x3                      // skip the leading blanks
    b.hs Lrt_in_parsestr_unq
    ldrb w4, [x0]
    cmp w4, #' '
    b.ne 2f
    add x0, x0, #1
    b 1b
2:
    cmp w4, #'"'
    b.ne Lrt_in_parsestr_unq
    // Quoted: the value runs to the next quote; only blanks may follow.
    add x5, x0, #1                  // value start
    mov x6, x5
3:
    cmp x6, x3
    b.hs Lrt_in_parsestr_bad        // no closing quote
    ldrb w4, [x6]
    cmp w4, #'"'
    b.eq 4f
    add x6, x6, #1
    b 3b
4:
    sub x2, x6, x5                  // value length
    mov x1, x5
    add x6, x6, #1                  // after the closing quote
5:
    cmp x6, x3
    b.hs Lrt_in_parsestr_ok
    ldrb w4, [x6], #1
    cmp w4, #' '
    b.ne Lrt_in_parsestr_bad        // text after the closing quote
    b 5b
Lrt_in_parsestr_unq:
    // Unquoted: no `"` (and no `&` in MAT INPUT); value = the rest.
    mov x1, x0
    sub x5, x3, x0                  // value length
6:
    cmp x0, x3
    b.hs 7f
    ldrb w4, [x0], #1
    cmp w4, #'"'
    b.eq Lrt_in_parsestr_bad
    cmp w4, #'&'
    b.ne 6b
    cbnz w2, Lrt_in_parsestr_bad
    b 6b
7:
    mov x2, x5
Lrt_in_parsestr_ok:
    mov w0, #1
    ret
Lrt_in_parsestr_bad:
    mov w0, #0
    ret

// ---------------------------------------------------------------------
// Lrt_in_diag -- write one INPUT diagnostic: flush stdout, end standard
//   error's pending PRINT #-1 line (_bsk_rt_err_bol, LANGUAGE.md 15.3),
//   then write(2, msg, len); failures are ignored (LANGUAGE.md 7.15).
//   Inputs  : x0 = message (with its LF), x1 = length
//   Outputs : none
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = message, x20 = length
//   Frame   : 32 bytes (frame record + x19, x20)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_in_diag:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    mov x20, x1
    bl _bsk_rt_print_flush          // stdout first: keep the order
    bl _bsk_rt_err_bol              // a message starts a stderr line
    mov w0, #2
    mov x1, x19
    mov x2, x20
    bl _bsk_rt_write_all            // result ignored
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// RT_IN_DIAG which: Lrt_in_diag with the message `which` (retype, more,
// excess) of BSK_EMIT_INPUT_MSGS.
.macro RT_IN_DIAG which
    adrp x0, Lrt_in_msg_\which@PAGE
    add x0, x0, Lrt_in_msg_\which@PAGEOFF
    mov x1, #(Lrt_in_msg_\which\()_end - Lrt_in_msg_\which)
    bl Lrt_in_diag
.endm

// ---------------------------------------------------------------------
// Lrt_in_nextfield -- the next field of a reader's current line for one
//   target. While no field is left: in the dialogue, write `NOT ENOUGH
//   INPUT -- ADD MORE` and read a new line; with the INPUT # rules, read
//   the next line silently.
//   Inputs  : x0 = reader record, w1 = mode
//   Outputs : x0 = field pointer, x1 = field length
//   Errors  : END OF INPUT / END OF FILE, INPUT LINE TOO LONG
//             (Lrt_in_getline)
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = reader, x20 = mode
//   Frame   : 32 bytes (frame record + x19, x20)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_in_nextfield:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    mov w20, w1
1:
    ldr w9, [x19, #RD_FLEFT]
    cbnz w9, 2f
    cbnz w20, 3f                    // INPUT #: no diagnostic
    RT_IN_DIAG more                 // no field left on this line
3:
    mov x0, x19
    mov w1, w20
    bl Lrt_in_getline
    b 1b
2:
    ldr x0, [x19, #RD_LINE]
    ldr x1, [x19, #RD_FPOS]
    ldr x2, [x19, #RD_LLEN]
    bl Lrt_in_field                 // x0/x1 field, x2 next pos, x3 more
    str x2, [x19, #RD_FPOS]
    str w3, [x19, #RD_FLEFT]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lrt_in_take -- take the pending file selection (DESIGN.md 6.8, 6.10):
//   read _bsk_rt_fsel and reset it to none. None: the dialogue on
//   standard input's reader. -1 (standard error, an output stream):
//   INVALID FILE NUMBER. File k: the INPUT # rules on reader k; for
//   k >= 1 the file must be in read mode and is opened if needed
//   (_bsk_rt_file_ropen); k = 0 is standard input's reader.
//   Inputs  : none
//   Outputs : x0 = reader record, w1 = mode
//   Errors  : INVALID FILE NUMBER, ILLEGAL FILE COMMAND, CAN'T OPEN
//             FILE, OUT OF ROOM
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = k
//   Frame   : 32 bytes (frame record + x19)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_in_take:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov w1, #RT_IN_DIALOGUE
    mov w19, #0                     // reader 0: standard input
    adrp x9, _bsk_rt_fsel@PAGE
    ldr w10, [x9, _bsk_rt_fsel@PAGEOFF] // 0 none, else k + 2
    cbz w10, 1f
    str wzr, [x9, _bsk_rt_fsel@PAGEOFF] // taken: back to "none"
    cmp w10, #1
    b.eq Lrt_in_take_stderr             // -1: not readable
    sub w19, w10, #2                    // k
    cbz w19, 2f                         // #0: standard input, file rules
    mov w0, w19
    bl _bsk_rt_file_ropen               // read mode, open if needed
2:
    mov w1, #RT_IN_FILE
1:
    adrp x0, Lrt_in_rd@PAGE
    add x0, x0, Lrt_in_rd@PAGEOFF
    mov x9, #RD_SIZE
    madd x0, x19, x9, x0                // &reader[k]
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
Lrt_in_take_stderr:
    mov w0, #ERR_INVALID_FILE_NUMBER    // INPUT #-1, LINPUT #-1
    bl _bsk_err                         // noreturn

// ---------------------------------------------------------------------
// _bsk_rt_in_linput -- the line of LINPUT / LINPUT # (LANGUAGE.md 15.2,
//   DESIGN.md 6.10): take the pending selection (Lrt_in_take: none =
//   the INPUT dialogue's line request on standard input, with the
//   prompt on a terminal and END OF INPUT; -1 = INVALID FILE NUMBER;
//   k = 0 or k >= 1 = the INPUT # line request, END OF FILE), then read
//   the reader's next unread line. A partly scanned current line (an
//   INPUT in progress that called a function from a target subscript)
//   is thereby discarded: the line buffer is overwritten and afterwards
//   the reader has no field left, so the next field request reads the
//   following line, exactly as after _bsk_input_end.
//   Inputs  : none
//   Outputs : x0 = the line's bytes (in the reader's line buffer, valid
//             until the reader's next line request), x1 = its length
//             (after the CR removal; at most LIM_INPUT_LINE)
//   Errors  : INVALID FILE NUMBER, ILLEGAL FILE COMMAND, CAN'T OPEN
//             FILE, OUT OF ROOM (Lrt_in_take); END OF INPUT / END OF
//             FILE, INPUT LINE TOO LONG (Lrt_in_getline)
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = reader
//   Frame   : 32 bytes (frame record + x19)
// ---------------------------------------------------------------------
    .private_extern _bsk_rt_in_linput
    .p2align 2
_bsk_rt_in_linput:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    bl Lrt_in_take                  // x0 reader, w1 mode
    mov x19, x0
    str wzr, [x19, #RD_FLEFT]       // the rest of a partly read line is gone
    bl Lrt_in_getline               // the next unread line (x0, w1 kept)
    str wzr, [x19, #RD_FLEFT]       // consumed whole: no field left
    ldr x0, [x19, #RD_LINE]
    ldr x1, [x19, #RD_LLEN]
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _bsk_input_begin -- INPUT / INPUT #: read the statement's first line.
//   Inputs  : none
//   Outputs : none
//   Errors  : END OF INPUT (exit 0) / END OF FILE, INPUT LINE TOO LONG;
//             ILLEGAL FILE COMMAND, CAN'T OPEN FILE, OUT OF ROOM (a file)
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : 16 bytes (frame record)
// ---------------------------------------------------------------------
    .globl _bsk_input_begin
    .p2align 2
_bsk_input_begin:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl Lrt_in_take                  // x0 reader, w1 mode
    bl Lrt_in_getline
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// _bsk_input_num -- INPUT / INPUT #: the value of the next field for a
//   numeric target. Dialogue: no field left -> NOT ENOUGH INPUT, new
//   line; an invalid field -> INPUT DATA NOT IN CORRECT FORMAT, the rest
//   of the line is discarded, new line; repeated until a valid field is
//   found. INPUT #: further lines are read silently while no field is
//   left; an invalid field is INCORRECT FORMAT IN FILE.
//   Inputs  : none
//   Outputs : d0 = value
//   Errors  : END OF INPUT / END OF FILE, INPUT LINE TOO LONG,
//             INCORRECT FORMAT IN FILE; the file errors of Lrt_in_take
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = reader, x20 = mode
//   Frame   : 32 bytes (frame record + x19, x20)
// ---------------------------------------------------------------------
    .globl _bsk_input_num
    .p2align 2
_bsk_input_num:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    bl Lrt_in_take
    mov x19, x0
    mov w20, w1
1:
    mov x0, x19
    mov w1, w20
    bl Lrt_in_nextfield
    bl Lrt_in_parsenum              // w0 valid, d0 value
    cbnz w0, 2f
    cbnz w20, Lrt_in_badfile        // INPUT #: nobody can retype
    RT_IN_DIAG retype
    mov x0, x19
    mov w1, w20
    bl Lrt_in_getline               // retype: a new line for this target
    b 1b
2:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

Lrt_in_badfile:
    mov w0, #ERR_FILE_FORMAT        // INCORRECT FORMAT IN FILE
    bl _bsk_err

// ---------------------------------------------------------------------
// Lrt_in_strvalue -- the value of the next valid field for a string
//   target; diagnostics and file rules as _bsk_input_num.
//   Inputs  : x0 = reader record, w1 = mode
//   Outputs : x1 = value bytes (inside the reader's line buffer),
//             x2 = length
//   Errors  : END OF INPUT / END OF FILE, INPUT LINE TOO LONG,
//             INCORRECT FORMAT IN FILE
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = reader, x20 = mode
//   Frame   : 32 bytes (frame record + x19, x20)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_in_strvalue:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    mov w20, w1
1:
    mov x0, x19
    mov w1, w20
    bl Lrt_in_nextfield
    mov w2, #0                      // `&` is an ordinary byte here
    bl Lrt_in_parsestr              // w0 valid, x1/x2 value
    cbnz w0, 2f
    cbnz w20, Lrt_in_badfile        // INPUT #: nobody can retype
    RT_IN_DIAG retype
    mov x0, x19
    mov w1, w20
    bl Lrt_in_getline
    b 1b
2:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _bsk_input_str -- INPUT / INPUT #: the next field for a string target,
//   stored into dst with _bsk_str_set semantics; diagnostics and file
//   rules as _bsk_input_num.
//   Inputs  : x0 = destination SD
//   Outputs : none
//   Errors  : those of _bsk_input_num, OUT OF ROOM
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = destination
//   Frame   : 32 bytes (frame record + x19)
// ---------------------------------------------------------------------
    .globl _bsk_input_str
    .p2align 2
_bsk_input_str:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov x19, x0
    bl Lrt_in_take                  // x0 reader, w1 mode
    bl Lrt_in_strvalue              // x1/x2 value
    mov x0, x19
    bl _bsk_rt_str_setbytes         // dst := the value (from the line)
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _bsk_input_str_el -- INPUT / INPUT # into a string list element L$(i)
//   (the element form of `insv`, IR.md 3.2): the field is taken first,
//   with every diagnostic and retype of _bsk_input_str (or the file
//   errors); only when the value is assigned is the subscript checked
//   (LANGUAGE.md 7.1, 7.15, 7.25), then the element := the value.
//   Inputs  : x0 = string-list descriptor (RTA_*), d0 = subscript i
//   Outputs : none
//   Errors  : those of _bsk_input_str; then SUBSCRIPT ERROR
//             (_bsk_saref1); OUT OF ROOM
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = descriptor, then the value bytes,
//             x20 = value length, d8 = subscript
//   Frame   : 48 bytes (frame record + x19, x20 + d8)
// ---------------------------------------------------------------------
    .globl _bsk_input_str_el
    .p2align 2
_bsk_input_str_el:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str d8, [sp, #32]
    mov x19, x0
    fmov d8, d0
    bl Lrt_in_take                  // x0 reader, w1 mode
    bl Lrt_in_strvalue              // x1/x2 value (in the line buffer)
    mov x20, x2
    mov x0, x19
    mov x19, x1
    fmov d0, d8
    bl _bsk_saref1                  // x0 = &L$(i); SUBSCRIPT ERROR here
    mov x1, x19
    mov x2, x20
    bl _bsk_rt_str_setbytes         // element := the value
    ldr d8, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// _bsk_input_end -- INPUT after the last target: fields left on the
//   current line -> `TOO MUCH INPUT -- EXCESS IGNORED`. INPUT #: the
//   rest of the line is discarded silently.
//   Inputs  : none
//   Outputs : none
//   Errors  : the file errors of Lrt_in_take
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : 16 bytes (frame record)
// ---------------------------------------------------------------------
    .globl _bsk_input_end
    .p2align 2
_bsk_input_end:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl Lrt_in_take                  // x0 reader, w1 mode
    ldr w9, [x0, #RD_FLEFT]
    cbz w9, 1f                      // the line is used up
    str wzr, [x0, #RD_FLEFT]        // the rest is discarded
    cbnz w1, 1f                     // INPUT #: silently
    RT_IN_DIAG excess
1:
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Lrt_in_tappend -- append a line segment and an LF to the MAT INPUT
//   text buffer (grown with realloc: doubled, at least RT_IN_TEXT_MIN).
//   Inputs  : x0 = pointer, x1 = length
//   Outputs : none
//   Errors  : OUT OF ROOM
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = segment, x20 = length, x21 = needed size
//   Frame   : 48 bytes (frame record + x19..x21 + the new capacity at
//             [sp,#40])
// ---------------------------------------------------------------------
    .p2align 2
Lrt_in_tappend:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov x19, x0
    mov x20, x1
    adrp x9, Lrt_in_tlen@PAGE
    ldr x10, [x9, Lrt_in_tlen@PAGEOFF]
    add x21, x10, x20
    add x21, x21, #1                // needed: text + segment + LF
    adrp x9, Lrt_in_tcap@PAGE
    ldr x11, [x9, Lrt_in_tcap@PAGEOFF]
    cmp x21, x11
    b.ls 2f                         // fits
    lsl x11, x11, #1                // new capacity: double ...
    mov x12, #RT_IN_TEXT_MIN
    cmp x11, x12
    csel x11, x12, x11, lo          // ... at least RT_IN_TEXT_MIN ...
    cmp x11, x21
    csel x11, x21, x11, lo          // ... and at least what is needed
    str x11, [sp, #40]
    adrp x9, Lrt_in_text@PAGE
    ldr x0, [x9, Lrt_in_text@PAGEOFF]   // NULL the first time
    mov x1, x11
    bl _realloc
    cbz x0, Lrt_in_oom
    adrp x9, Lrt_in_text@PAGE
    str x0, [x9, Lrt_in_text@PAGEOFF]
    ldr x11, [sp, #40]
    adrp x9, Lrt_in_tcap@PAGE
    str x11, [x9, Lrt_in_tcap@PAGEOFF]  // capacity of the new buffer
2:
    adrp x9, Lrt_in_text@PAGE
    ldr x0, [x9, Lrt_in_text@PAGEOFF]
    adrp x9, Lrt_in_tlen@PAGE
    ldr x10, [x9, Lrt_in_tlen@PAGEOFF]
    add x0, x0, x10                 // append position
    mov x1, x19
    mov x2, x20
    bl _memcpy                      // x0 = destination
    mov w9, #'\n'
    strb w9, [x0, x20]              // end of this line's text
    adrp x9, Lrt_in_tlen@PAGE
    str x21, [x9, Lrt_in_tlen@PAGEOFF]
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
Lrt_in_oom:
    // realloc failed in Lrt_in_tappend: the program ends.
    mov w0, #ERR_OUT_OF_ROOM
    bl _bsk_err

// ---------------------------------------------------------------------
// Lrt_in_matscan -- one pass over the collected MAT INPUT text.
//   Purpose : every field of every line (all-blank lines have none), in
//             order, is validated for the list's kind; pass 1 (store = 0)
//             counts them and fails on the first invalid one; pass 2
//             (store = 1, after pass 1 succeeded and the list's bound was
//             set) stores field k into element k.
//   Inputs  : x0 = list descriptor, w1 = 0 numeric / 1 string list,
//             w2 = store flag
//   Outputs : x0 = number of fields, or -1 if a field is invalid
//   Errors  : OUT OF ROOM (pass 2, strings)
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = descriptor, x20 = kind, x21 = store flag,
//             x22 = start of the current line, x23 = end of the text,
//             x24 = length of the current line, x25 = fields so far,
//             x26 = position in the line, x27 = 1 if another field
//             follows on the line
//   Frame   : 96 bytes (frame record + x19..x28)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_in_matscan:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    mov x19, x0
    mov w20, w1
    mov w21, w2
    adrp x9, Lrt_in_text@PAGE
    ldr x22, [x9, Lrt_in_text@PAGEOFF]
    adrp x9, Lrt_in_tlen@PAGE
    ldr x23, [x9, Lrt_in_tlen@PAGEOFF]
    add x23, x22, x23               // end of the text
    mov x25, #0
Lrt_in_matscan_line:
    cmp x22, x23
    b.hs Lrt_in_matscan_done
    mov x0, x22
    mov w1, #'\n'
    sub x2, x23, x22
    bl _memchr                      // every line ends with an LF
    sub x24, x0, x22                // line length
    mov x0, x22
    mov x1, x24
    bl Lrt_in_allblank
    cbnz w0, Lrt_in_matscan_next    // no fields on this line
    mov x26, #0
Lrt_in_matscan_field:
    mov x0, x22
    mov x1, x26
    mov x2, x24
    bl Lrt_in_field                 // x0/x1 field, x2 next, x3 more
    mov x26, x2
    mov x27, x3
    add x25, x25, #1                // field number = element index
    cbnz w20, Lrt_in_matscan_str
    bl Lrt_in_parsenum              // w0 valid, d0 value
    cbz w0, Lrt_in_matscan_bad
    cbz w21, Lrt_in_matscan_after
    ldr x9, [x19, #RTA_DATA]
    str d0, [x9, x25, lsl #3]       // element k of the list
    b Lrt_in_matscan_after
Lrt_in_matscan_str:
    mov w2, #1                      // `&` not allowed unquoted
    bl Lrt_in_parsestr              // w0 valid, x1/x2 value
    cbz w0, Lrt_in_matscan_bad
    cbz w21, Lrt_in_matscan_after
    ldr x0, [x19, #RTA_DATA]
.if (SD_SIZE != 16)
    .error "rt_input.s shifts the element index by 4: SD_SIZE must be 16"
.endif
    add x0, x0, x25, lsl #4         // SD of element k (SD_SIZE 16)
    bl _bsk_rt_str_setbytes
Lrt_in_matscan_after:
    cbnz x27, Lrt_in_matscan_field  // another field on this line
Lrt_in_matscan_next:
    add x22, x22, x24
    add x22, x22, #1                // past the LF
    b Lrt_in_matscan_line
Lrt_in_matscan_bad:
    mov x25, #-1
Lrt_in_matscan_done:
    mov x0, x25
    ldp x27, x28, [sp, #80]
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret

// ---------------------------------------------------------------------
// Lrt_in_matin -- MAT INPUT of a list (LANGUAGE.md 7.14.8).
//   Purpose : 1. read lines while the last non-blank byte outside quotes
//             is `&` (the `&`, and one comma before it with only blanks
//             between, end the line's text; what follows them is
//             dropped); 2. any invalid field -> RETYPE diagnostic,
//             discard everything, back to 1; 3. n fields: n = 0 -> NUM
//             = 0, list unchanged; n + 1 > RTA_CAP -> DIMENSION ERROR;
//             else RTA_B1 = n, elements 1..n stored, NUM = n.
//   Inputs  : x0 = list descriptor, w1 = 0 numeric / 1 string list
//   Outputs : none
//   Errors  : END OF INPUT, INPUT LINE TOO LONG, DIMENSION ERROR,
//             OUT OF ROOM
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = descriptor, x20 = kind, x21 = n
//   Frame   : 48 bytes (frame record + x19..x21 + "continued" at
//             [sp,#40])
// ---------------------------------------------------------------------
    .p2align 2
Lrt_in_matin:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov x19, x0
    mov w20, w1
Lrt_in_matin_restart:
    adrp x9, Lrt_in_tlen@PAGE
    str xzr, [x9, Lrt_in_tlen@PAGEOFF]  // nothing collected yet
Lrt_in_matin_line:
    adrp x0, Lrt_in_rd@PAGE
    add x0, x0, Lrt_in_rd@PAGEOFF     // standard input's reader
    mov w1, #RT_IN_DIALOGUE
    bl Lrt_in_getline
    // Find the last non-blank byte and whether it is an `&` outside
    // quotes: x0 = line, x1 = length, x2 = index, x3 = last non-blank
    // index + 1 (0: none), w4 = in quotes, w5 = 1 if that byte is an
    // `&` outside quotes.
    adrp x9, Lrt_in_rd@PAGE
    add x9, x9, Lrt_in_rd@PAGEOFF
    ldr x0, [x9, #RD_LINE]
    ldr x1, [x9, #RD_LLEN]
    mov x2, #0
    mov x3, #0
    mov w4, #0
    mov w5, #0
1:
    cmp x2, x1
    b.hs 4f
    ldrb w6, [x0, x2]
    add x2, x2, #1
    cmp w6, #' '
    b.eq 1b                         // blanks change nothing
    mov x3, x2                      // last non-blank so far
    mov w5, #0
    cmp w6, #'"'
    b.ne 2f
    eor w4, w4, #1
    b 1b
2:
    cmp w6, #'&'
    b.ne 1b
    cbnz w4, 1b                     // an `&` inside quotes is data
    mov w5, #1
    b 1b
4:
    cbz w5, 5f                      // not continued: the whole line
    sub x1, x3, #1                  // the text ends before the `&` ...
    mov x2, x1
3:
    cbz x2, 5f
    sub x2, x2, #1
    ldrb w6, [x0, x2]
    cmp w6, #' '
    b.eq 3b                         // (blanks ignored)
    cmp w6, #','
    b.ne 5f
    mov x1, x2                      // ... or before one comma before it
5:
    str x5, [sp, #40]               // keep "continued" across the call
    bl Lrt_in_tappend
    ldr x5, [sp, #40]
    cbnz w5, Lrt_in_matin_line      // `&`: read the next line too
    // Pass 1: validate and count.
    mov x0, x19
    mov w1, w20
    mov w2, #0
    bl Lrt_in_matscan
    tbz x0, #63, 6f
    RT_IN_DIAG retype               // a bad field: start again
    b Lrt_in_matin_restart
6:
    mov x21, x0                     // n
    cbz x21, Lrt_in_matin_num       // no values: NUM = 0, list unchanged
    ldr w9, [x19, #RTA_CAP]
    cmp x21, x9
    b.hs Lrt_in_matin_dimerr        // n + 1 > storage
    str w21, [x19, #RTA_B1]         // the list's bound becomes n
    // Pass 2: store elements 1..n.
    mov x0, x19
    mov w1, w20
    mov w2, #1
    bl Lrt_in_matscan
Lrt_in_matin_num:
    ucvtf d0, x21
    adrp x9, _bsk_rt_num@PAGE
    str d0, [x9, _bsk_rt_num@PAGEOFF]   // NUM := n
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
Lrt_in_matin_dimerr:
    mov w0, #ERR_DIMENSION_ERROR
    bl _bsk_err

// ---------------------------------------------------------------------
// _bsk_mat_input / _bsk_smat_input -- MAT INPUT of a numeric / string
//   list (Lrt_in_matin).
//   Inputs  : x0 = list descriptor
//   Outputs : none
//   Errors  : see Lrt_in_matin
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : none (tail calls)
// ---------------------------------------------------------------------
    .globl _bsk_mat_input
    .p2align 2
_bsk_mat_input:
    mov w1, #0
    b Lrt_in_matin

    .globl _bsk_smat_input
    .p2align 2
_bsk_smat_input:
    mov w1, #1
    b Lrt_in_matin


// ---------------------------------------------------------------------
// Lrt_in_reader -- the reader record of file number k.
//   Inputs  : w0 = k (0 .. LIM_FILES)
//   Outputs : x0 = record
//   Clobbers: x9
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_in_reader:
    mov w9, #RD_SIZE
    umull x9, w0, w9                // k * RD_SIZE
    adrp x0, Lrt_in_rd@PAGE
    add x0, x0, Lrt_in_rd@PAGEOFF
    add x0, x0, x9
    ret

// ---------------------------------------------------------------------
// _bsk_rt_rd_reset -- empty file k's reader (RESTORE #k, SCRATCH #k):
//   no unread chunk bytes, no current line, no field left. The buffers
//   are kept for reuse.
//   Inputs  : w0 = k (1 .. LIM_FILES)
//   Outputs : none
//   Clobbers: x0, x9
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .private_extern _bsk_rt_rd_reset
    .p2align 2
_bsk_rt_rd_reset:
    mov w9, #RD_SIZE
    umull x9, w0, w9
    adrp x0, Lrt_in_rd@PAGE
    add x0, x0, Lrt_in_rd@PAGEOFF
    add x0, x0, x9                  // &reader[k]
    str xzr, [x0, #RD_RPOS]
    str xzr, [x0, #RD_RLEN]
    str xzr, [x0, #RD_LLEN]
    str xzr, [x0, #RD_FPOS]
    str wzr, [x0, #RD_FLEFT]
    ret

// ---------------------------------------------------------------------
// _bsk_rt_rd_setup -- file k was opened for reading on fd: its reader's
//   buffers are malloc'd the first time (an RT_INBUF_SIZE chunk and an
//   RT_IN_LINEBUF line, reused after RESTORE #), the reader is emptied
//   and reads fd from now on.
//   Inputs  : w0 = k (1 .. LIM_FILES), w1 = fd
//   Outputs : none
//   Errors  : OUT OF ROOM (malloc failed; fd is closed first)
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = reader, x20 = fd, x21 = k
//   Frame   : 48 bytes (frame record + x19..x21, padded)
// ---------------------------------------------------------------------
    .private_extern _bsk_rt_rd_setup
    .p2align 2
_bsk_rt_rd_setup:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov w21, w0
    mov w20, w1
    bl Lrt_in_reader
    mov x19, x0
    ldr x9, [x19, #RD_CHUNK]
    cbnz x9, 1f                     // allocated at an earlier open
    mov x0, #RT_INBUF_SIZE
    bl _malloc
    cbz x0, Lrt_in_rd_oom
    str x0, [x19, #RD_CHUNK]
    mov x0, #LIM_INPUT_LINE
    add x0, x0, #(RT_IN_LINEBUF - LIM_INPUT_LINE)  // RT_IN_LINEBUF bytes
    bl _malloc
    cbz x0, Lrt_in_rd_oom
    str x0, [x19, #RD_LINE]
1:
    str w20, [x19, #RD_FD]
    mov w0, w21
    bl _bsk_rt_rd_reset             // nothing read yet
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
Lrt_in_rd_oom:
    mov w0, w20
    bl _close                       // the new file's fd is not leaked
    mov w0, #ERR_OUT_OF_ROOM
    bl _bsk_err                     // noreturn

// ---------------------------------------------------------------------
// _bsk_rt_rd_atend -- IF END # on reader k (LANGUAGE.md 7.26, DESIGN.md
//   6.8): at its end when it holds no unread byte and a chunk read
//   returns no byte. A chunk that arrives is kept for the next INPUT #.
//   For standard input (k = 0) on a terminal stdout is flushed before
//   the read.
//   Inputs  : w0 = k (0 .. LIM_FILES); file k >= 1 is open for reading
//   Outputs : w0 = 1 at the end, else 0
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = reader, x20 = k
//   Frame   : 32 bytes (frame record + x19, x20)
// ---------------------------------------------------------------------
    .private_extern _bsk_rt_rd_atend
    .p2align 2
_bsk_rt_rd_atend:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov w20, w0
    bl Lrt_in_reader
    mov x19, x0
    ldr x10, [x19, #RD_RPOS]
    ldr x11, [x19, #RD_RLEN]
    mov w0, #0
    cmp x10, x11
    b.lo 2f                         // unread bytes: another line follows
    cbnz w20, 1f                    // a file: just read
    bl Lrt_in_istty
    cbz w0, 1f
    bl _bsk_rt_print_flush          // the terminal user sees all output
1:
    mov x0, x19
    bl Lrt_in_refill                // w0 = 1 if bytes arrived
    eor w0, w0, #1                  // at the end when none did
2:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// The three diagnostics (texts from include/errors.inc).
// ---------------------------------------------------------------------
    .section __TEXT,__const
    BSK_EMIT_INPUT_MSGS Lrt_in_msg

// ---------------------------------------------------------------------
// State.
//   Lrt_in_rd     LIM_FILES + 1 reader records (RD_*): [0] standard
//                 input (fd 0, static buffers Lrt_in_rbuf / Lrt_in_line),
//                 [k] file k (buffers malloc'd at its first open)
//   Lrt_in_tty    u32  0 not asked yet, RT_IN_TTY_NO, RT_IN_TTY_YES
//   Lrt_in_text   ptr  MAT INPUT text buffer (malloc'd, reused)
//   Lrt_in_tcap   u64  its capacity
//   Lrt_in_tlen   u64  bytes collected by the current MAT INPUT
//   Lrt_in_rbuf   RT_INBUF_SIZE bytes read from stdin
//   Lrt_in_line   standard input's current line (RT_IN_LINEBUF bytes)
// ---------------------------------------------------------------------
    .section __DATA,__data
    .p2align 3
Lrt_in_rd:
    .long 0                         // RD_FD: standard input
    .long 0                         // RD_FLEFT
    .quad Lrt_in_rbuf               // RD_CHUNK
    .quad 0                         // RD_RPOS
    .quad 0                         // RD_RLEN
    .quad Lrt_in_line               // RD_LINE
    .quad 0                         // RD_LLEN
    .quad 0                         // RD_FPOS
    .space RD_SIZE * LIM_FILES      // files: zero = no buffers yet

.zerofill __DATA,__bss,Lrt_in_tty,4,2
.zerofill __DATA,__bss,Lrt_in_text,8,3
.zerofill __DATA,__bss,Lrt_in_tcap,8,3
.zerofill __DATA,__bss,Lrt_in_tlen,8,3
.zerofill __DATA,__bss,Lrt_in_rbuf,RT_INBUF_SIZE,4
.zerofill __DATA,__bss,Lrt_in_line,RT_IN_LINEBUF,4

.if (RD_LINE != 32) || (RD_SIZE != 56)
    .error "rt_input.s: the static standard-input reader assumes this RD_* layout"
.endif
