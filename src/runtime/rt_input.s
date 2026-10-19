// =====================================================================
// src/runtime/rt_input.s -- INPUT and MAT INPUT: the standard-input line
// reader, field scanning and the three INPUT diagnostics (DESIGN.md 6.7,
// LANGUAGE.md 7.14.8, 7.15).
//
// Defines (global, runtime.inc):
//   _bsk_input_begin _bsk_input_num _bsk_input_str _bsk_input_str_el
//   _bsk_input_end
//   _bsk_mat_input _bsk_smat_input
// Uses: _bsk_rt_print_prompt/_home/_flush, _bsk_rt_write_all (rt_print.s),
// _bsk_rt_str_setbytes (rt_str.s), _bsk_saref1 (rt_array.s), _bsk_rt_num (rt_ed4.s), _bsk_err.
//
// Lines. Standard input is read lazily with read(0, buf, RT_INBUF_SIZE)
// into a static buffer (EINTR retried; any other error or 0 bytes = end
// of input, remembered). A line is assembled into a static buffer of
// LIM_INPUT_LINE + 1 bytes: the bytes up to the next LF; one CR right
// before the LF is removed; a non-empty last line without LF counts. A
// line longer than LIM_INPUT_LINE bytes after the CR removal is INPUT
// LINE TOO LONG (detected as soon as more than LIM_INPUT_LINE + 1 bytes
// precede the LF, or at the LF / end of input). End of input when a line
// is needed is END OF INPUT (exit 0). isatty(0) is asked once, at the
// first line request; on a terminal each line request first writes the
// prompt (_bsk_rt_print_prompt) and the column state is reset after the
// line was read (_bsk_rt_print_home).
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
// INPUT keeps a cursor into the current line (Lrt_in_fpos) and whether a
// field is left (Lrt_in_fleft). MAT INPUT collects the text of all its
// lines (`&` continuation removed) in a growable malloc buffer, one line
// per LF-terminated record, validates every field and counts them, and
// only then stores (a second scan of the same text), so nothing is
// assigned unless the whole input is good (transactional).
// =====================================================================
.include "baysick.inc"

.equ RT_EINTR, 4                    // <errno.h> EINTR on Darwin
.equ RT_IN_LINEBUF, LIM_INPUT_LINE + 16 // line buffer: limit + CR + slack
.equ RT_IN_NUMBUF, 32               // blank-free numeric field text (+NUL)
.equ RT_IN_TTY_NO, 1                // Lrt_in_tty: stdin is not a terminal
.equ RT_IN_TTY_YES, 2               // Lrt_in_tty: stdin is a terminal
.equ RT_IN_TEXT_MIN, 4096           // first size of the MAT INPUT text buffer

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
// Lrt_in_getline -- read the next input line into Lrt_in_line.
//   Purpose : the line reader of the header (prompt on a terminal, CR
//             removal, length limit, END OF INPUT); afterwards the INPUT
//             field cursor is at the start of the line and Lrt_in_fleft
//             says whether the line has a field (not empty/all blank).
//   Inputs  : none
//   Outputs : Lrt_in_line / Lrt_in_llen hold the line
//   Errors  : END OF INPUT (exit 0), INPUT LINE TOO LONG
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = line length so far, x20 = line buffer,
//             x21 = start of the unread bytes, x22 = their count
//   Frame   : 64 bytes (frame record + x19..x22 + "LF found" at
//             [sp,#48])
// ---------------------------------------------------------------------
    .p2align 2
Lrt_in_getline:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    // Terminal or not: asked once, at the first line request.
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
    b.ne 2f
    bl _bsk_rt_print_prompt         // pending spaces, "? ", flush
2:
    mov x19, #0                     // line length
    adrp x20, Lrt_in_line@PAGE
    add x20, x20, Lrt_in_line@PAGEOFF
Lrt_in_getline_more:
    // Unread bytes in the read buffer?
    adrp x9, Lrt_in_rpos@PAGE
    ldr x10, [x9, Lrt_in_rpos@PAGEOFF]
    adrp x11, Lrt_in_rlen@PAGE
    ldr x11, [x11, Lrt_in_rlen@PAGEOFF]
    cmp x10, x11
    b.lo Lrt_in_getline_scan
    adrp x9, Lrt_in_eof@PAGE
    ldr w9, [x9, Lrt_in_eof@PAGEOFF]
    cbnz w9, Lrt_in_getline_eof     // end of input already seen
Lrt_in_getline_read:
    mov w0, #0                      // stdin
    adrp x1, Lrt_in_rbuf@PAGE
    add x1, x1, Lrt_in_rbuf@PAGEOFF
    mov x2, #RT_INBUF_SIZE
    bl _read
    cmp x0, #0
    b.gt Lrt_in_getline_got
    b.eq Lrt_in_getline_seteof      // 0 bytes: end of input
    bl ___error                     // -1: EINTR is retried
    ldr w9, [x0]
    cmp w9, #RT_EINTR
    b.eq Lrt_in_getline_read
Lrt_in_getline_seteof:
    adrp x9, Lrt_in_eof@PAGE        // any other error = end of input
    mov w10, #1
    str w10, [x9, Lrt_in_eof@PAGEOFF]
    b Lrt_in_getline_eof
Lrt_in_getline_got:
    adrp x9, Lrt_in_rpos@PAGE
    str xzr, [x9, Lrt_in_rpos@PAGEOFF]
    adrp x9, Lrt_in_rlen@PAGE
    str x0, [x9, Lrt_in_rlen@PAGEOFF]
    mov x10, #0
    mov x11, x0
Lrt_in_getline_scan:
    // x10 = rpos, x11 = rlen: look for the LF in the unread bytes.
    adrp x21, Lrt_in_rbuf@PAGE
    add x21, x21, Lrt_in_rbuf@PAGEOFF
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
    str x0, [sp, #48]               // keep "LF found" across memcpy
    add x0, x20, x19
    mov x1, x21
    mov x2, x22
    bl _memcpy                      // append to the line
    ldr x9, [sp, #48]
    add x19, x19, x22
    adrp x10, Lrt_in_rpos@PAGE
    ldr x11, [x10, Lrt_in_rpos@PAGEOFF]
    add x11, x11, x22
    cbz x9, 2f
    add x11, x11, #1                // consume the LF too
    str x11, [x10, Lrt_in_rpos@PAGEOFF]
    b Lrt_in_getline_lf
2:
    str x11, [x10, Lrt_in_rpos@PAGEOFF] // buffer used up: read more
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
    adrp x9, Lrt_in_llen@PAGE
    str x19, [x9, Lrt_in_llen@PAGEOFF]
    adrp x9, Lrt_in_fpos@PAGE
    str xzr, [x9, Lrt_in_fpos@PAGEOFF]  // INPUT cursor at the start
    mov x0, x20
    mov x1, x19
    bl Lrt_in_allblank
    eor w0, w0, #1                  // a field is left unless all blank
    adrp x9, Lrt_in_fleft@PAGE
    str w0, [x9, Lrt_in_fleft@PAGEOFF]
    adrp x9, Lrt_in_tty@PAGE
    ldr w10, [x9, Lrt_in_tty@PAGEOFF]
    cmp w10, #RT_IN_TTY_YES
    b.ne 1f
    bl _bsk_rt_print_home           // the terminal is at a new line
1:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret
Lrt_in_getline_end:
    mov w0, #ERR_END_OF_INPUT
    bl _bsk_err                     // newline, flush, message, exit 0
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
// Lrt_in_parsenum -- validate and convert a numeric field.
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
    .p2align 2
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
// Lrt_in_diag -- write one INPUT diagnostic: flush stdout, then
//   write(2, msg, len); failures are ignored (LANGUAGE.md 7.15).
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
// Lrt_in_nextfield -- INPUT: the next field of the current line for one
//   target, with the NOT ENOUGH INPUT rule: while no field is left,
//   write `NOT ENOUGH INPUT -- ADD MORE` and read a new line.
//   Inputs  : none
//   Outputs : x0 = field pointer, x1 = field length
//   Errors  : END OF INPUT, INPUT LINE TOO LONG (Lrt_in_getline)
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : 16 bytes (frame record)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_in_nextfield:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
1:
    adrp x9, Lrt_in_fleft@PAGE
    ldr w9, [x9, Lrt_in_fleft@PAGEOFF]
    cbnz w9, 2f
    RT_IN_DIAG more                 // no field left on this line
    bl Lrt_in_getline
    b 1b
2:
    adrp x0, Lrt_in_line@PAGE
    add x0, x0, Lrt_in_line@PAGEOFF
    adrp x9, Lrt_in_fpos@PAGE
    ldr x1, [x9, Lrt_in_fpos@PAGEOFF]
    adrp x9, Lrt_in_llen@PAGE
    ldr x2, [x9, Lrt_in_llen@PAGEOFF]
    bl Lrt_in_field                 // x0/x1 field, x2 next pos, x3 more
    adrp x9, Lrt_in_fpos@PAGE
    str x2, [x9, Lrt_in_fpos@PAGEOFF]
    adrp x9, Lrt_in_fleft@PAGE
    str w3, [x9, Lrt_in_fleft@PAGEOFF]
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// _bsk_input_begin -- INPUT: read the statement's first line.
//   Inputs  : none
//   Outputs : none
//   Errors  : END OF INPUT (exit 0), INPUT LINE TOO LONG
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : none (tail call)
// ---------------------------------------------------------------------
    .globl _bsk_input_begin
    .p2align 2
_bsk_input_begin:
    b Lrt_in_getline

// ---------------------------------------------------------------------
// _bsk_input_num -- INPUT: the value of the next field for a numeric
//   target. No field left -> NOT ENOUGH INPUT, new line; an invalid
//   field -> INPUT DATA NOT IN CORRECT FORMAT, the rest of the line is
//   discarded, new line; repeated until a valid field is found.
//   Inputs  : none
//   Outputs : d0 = value
//   Errors  : END OF INPUT, INPUT LINE TOO LONG
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : 16 bytes (frame record)
// ---------------------------------------------------------------------
    .globl _bsk_input_num
    .p2align 2
_bsk_input_num:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
1:
    bl Lrt_in_nextfield
    bl Lrt_in_parsenum              // w0 valid, d0 value
    cbnz w0, 2f
    RT_IN_DIAG retype
    bl Lrt_in_getline               // retype: a new line for this target
    b 1b
2:
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Lrt_in_strvalue -- INPUT: the value of the next valid field for a
//   string target; diagnostics as _bsk_input_num (NOT ENOUGH INPUT, new
//   line; invalid -> RETYPE, new line; repeated).
//   Inputs  : none
//   Outputs : x1 = value bytes (inside the line buffer), x2 = length
//   Errors  : END OF INPUT, INPUT LINE TOO LONG
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : 16 bytes (frame record)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_in_strvalue:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
1:
    bl Lrt_in_nextfield
    mov w2, #0                      // `&` is an ordinary byte here
    bl Lrt_in_parsestr              // w0 valid, x1/x2 value
    cbnz w0, 2f
    RT_IN_DIAG retype
    bl Lrt_in_getline
    b 1b
2:
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// _bsk_input_str -- INPUT: the next field for a string target, stored
//   into dst with _bsk_str_set semantics; diagnostics as _bsk_input_num.
//   Inputs  : x0 = destination SD
//   Outputs : none
//   Errors  : END OF INPUT, INPUT LINE TOO LONG, OUT OF ROOM
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
    bl Lrt_in_strvalue              // x1/x2 value
    mov x0, x19
    bl _bsk_rt_str_setbytes         // dst := the value (from the line)
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _bsk_input_str_el -- INPUT into a string list element L$(i) (the
//   element form of `insv`, IR.md 3.2): the field is taken first, with
//   every diagnostic and retype of _bsk_input_str; only when the value
//   is assigned is the subscript checked (LANGUAGE.md 7.1, 7.15), then
//   the element := the value.
//   Inputs  : x0 = string-list descriptor (RTA_*), d0 = subscript i
//   Outputs : none
//   Errors  : END OF INPUT, INPUT LINE TOO LONG; then SUBSCRIPT ERROR
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
//   current line -> `TOO MUCH INPUT -- EXCESS IGNORED`.
//   Inputs  : none
//   Outputs : none
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : 16 bytes (frame record)
// ---------------------------------------------------------------------
    .globl _bsk_input_end
    .p2align 2
_bsk_input_end:
    adrp x9, Lrt_in_fleft@PAGE
    ldr w9, [x9, Lrt_in_fleft@PAGEOFF]
    cbz w9, 1f
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    RT_IN_DIAG excess
    ldp x29, x30, [sp], #16
1:
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
    bl Lrt_in_getline
    // Find the last non-blank byte and whether it is an `&` outside
    // quotes: x0 = line, x1 = length, x2 = index, x3 = last non-blank
    // index + 1 (0: none), w4 = in quotes, w5 = 1 if that byte is an
    // `&` outside quotes.
    adrp x0, Lrt_in_line@PAGE
    add x0, x0, Lrt_in_line@PAGEOFF
    adrp x9, Lrt_in_llen@PAGE
    ldr x1, [x9, Lrt_in_llen@PAGEOFF]
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
// The three diagnostics (texts from include/errors.inc).
// ---------------------------------------------------------------------
    .section __TEXT,__const
    BSK_EMIT_INPUT_MSGS Lrt_in_msg

// ---------------------------------------------------------------------
// State (zero-initialised):
//   Lrt_in_tty    u32  0 not asked yet, RT_IN_TTY_NO, RT_IN_TTY_YES
//   Lrt_in_eof    u32  1 once read(0) reported the end (or an error)
//   Lrt_in_rpos   u64  next unread byte in Lrt_in_rbuf
//   Lrt_in_rlen   u64  bytes in Lrt_in_rbuf
//   Lrt_in_llen   u64  length of the current line
//   Lrt_in_fpos   u64  INPUT: start of the next field in the line
//   Lrt_in_fleft  u32  INPUT: 1 if a field is left on the line
//   Lrt_in_text   ptr  MAT INPUT text buffer (malloc'd, reused)
//   Lrt_in_tcap   u64  its capacity
//   Lrt_in_tlen   u64  bytes collected by the current MAT INPUT
//   Lrt_in_rbuf   RT_INBUF_SIZE bytes read from stdin
//   Lrt_in_line   the current line (RT_IN_LINEBUF bytes)
// ---------------------------------------------------------------------
.zerofill __DATA,__bss,Lrt_in_tty,4,2
.zerofill __DATA,__bss,Lrt_in_eof,4,2
.zerofill __DATA,__bss,Lrt_in_fleft,4,2
.zerofill __DATA,__bss,Lrt_in_rpos,8,3
.zerofill __DATA,__bss,Lrt_in_rlen,8,3
.zerofill __DATA,__bss,Lrt_in_llen,8,3
.zerofill __DATA,__bss,Lrt_in_fpos,8,3
.zerofill __DATA,__bss,Lrt_in_text,8,3
.zerofill __DATA,__bss,Lrt_in_tcap,8,3
.zerofill __DATA,__bss,Lrt_in_tlen,8,3
.zerofill __DATA,__bss,Lrt_in_rbuf,RT_INBUF_SIZE,4
.zerofill __DATA,__bss,Lrt_in_line,RT_IN_LINEBUF,4
