// =====================================================================
// src/frontend/fe_lines.s -- phase 1 (LANGUAGE.md sections 1-2):
// physical lines, CR removal, compaction, line numbers, replace/delete
// editing, sorting; plus line-number lookup for jump targets.
//
//   _fe_lines_read(x0=src, x1=len)       fills _fe_lines / _fe_nlines
//   _fe_line_lookup(w0=line) -> w0       index (= label id) or -1
//
// Storage: a table indexed by line number (1..99999) of pointers to
// records { u64 length; bytes[length] } holding the compacted statement
// text after the line number. Replacing a line just stores a new record
// (the arena never frees). Sorting is a scan of the table in index
// order, producing _fe_lines: FE_LINE_ENTRY (16-byte) records
// { u32 line number, u32 text length, u64 text pointer }.
// =====================================================================
.include "baysick.inc"

.equ FE_LINE_ENTRY,     16          // see fe_compile.s
.equ FE_LINE_BUF,       256         // compaction buffer (>= LIM_PHYS_LINE_LEN)

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _fe_lines_read -- process every physical line in file order.
//   in:  x0 = source bytes, x1 = source length (<= LIM_SOURCE_BYTES)
//   out: _fe_lines, _fe_nlines set; errors (no line number) via _fe_fail:
//        LINE TOO LONG, ILLEGAL LINE NUMBER, PROGRAM TOO LONG (line count)
//   clobbers: x0-x17
//   callee-saved: x19 = start of the current physical line, x20 = end of
//        the source, x21 = line table (by line number), x22 = number of
//        stored lines, x23 = end of the physical line (LF or source end),
//        x24 = start of the next physical line, x25 = compacted length,
//        x26 = line number value, x27 = digits in the line number,
//        x28 = statement text length
//   frame: 352 bytes (frame record, x19-x28, 256-byte compaction buffer
//        at sp+96)
// ---------------------------------------------------------------------
    .globl _fe_lines_read
    .p2align 2
_fe_lines_read:
    stp x29, x30, [sp, #-352]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    mov x19, x0
    add x20, x0, x1
    // line table: one pointer per possible line number 0..99999 (zeroed)
    movz x0, #((LIM_LINE_NUMBER + 1) & 0xFFFF)
    movk x0, #((LIM_LINE_NUMBER + 1) >> 16), lsl #16
    lsl x0, x0, #3
    bl _drv_alloc
    mov x21, x0
    mov x22, #0

Lfe_lines_read_line:
    cmp x19, x20
    b.hs Lfe_lines_read_sort            // no bytes left: done
    // find the end of this physical line (LF or end of file)
    mov x23, x19
1:
    cmp x23, x20
    b.hs 2f
    ldrb w9, [x23]
    cmp w9, #10
    b.eq 2f
    add x23, x23, #1
    b 1b
2:
    // the next line starts after the LF (or at the end of the source)
    mov x24, x23
    cmp x23, x20
    b.hs 3f
    add x24, x23, #1
3:
    // a single CR before the LF / at the end of the file is removed
    sub x10, x23, x19                   // physical length
    cbz x10, 4f
    ldrb w9, [x23, #-1]
    cmp w9, #13
    b.ne 4f
    sub x10, x10, #1
4:
    cmp x10, #LIM_PHYS_LINE_LEN
    b.ls Lfe_lines_read_compact
    mov w0, #ERR_LINE_TOO_LONG
    mov w1, #0
    bl _fe_fail

Lfe_lines_read_compact:
    // compaction (LANGUAGE.md 2.1): x11 = source cursor, x12 = its end,
    // x13 = output cursor, w14 = in-string flag, w8 = 1 once a remark
    // (an apostrophe outside a string) cut the line short
    mov x11, x19
    add x12, x19, x10
    add x13, sp, #96
    mov w14, #0
    mov w8, #0
Lfe_lines_read_cloop:
    cmp x11, x12
    b.hs Lfe_lines_read_cdone
    ldrb w9, [x11], #1
    // '"' toggles in-string and is kept
    cmp w9, #'"'
    b.ne 1f
    eor w14, w14, #1
    b Lfe_lines_read_cstore
1:
    // inside a string every byte is kept unchanged
    cbnz w14, Lfe_lines_read_cstore
    // an apostrophe outside a string starts a remark: it and the rest of
    // the line are dropped ([M68] p. 52)
    cmp w9, #0x27
    b.eq Lfe_lines_read_remark
    // spaces and tabs vanish outside strings
    cmp w9, #' '
    b.eq Lfe_lines_read_cloop
    cmp w9, #9
    b.eq Lfe_lines_read_cloop
    // lower-case letters are folded to upper case
    sub w15, w9, #'a'
    cmp w15, #25
    b.hi 2f
    sub w9, w9, #('a' - 'A')
    b Lfe_lines_read_cstore
2:
    // UTF-8 E2 86 91 (U+2191 UPWARDS ARROW) becomes '^'
    cmp w9, #0xE2
    b.ne Lfe_lines_read_cstore
    add x15, x11, #2
    cmp x15, x12
    b.hi Lfe_lines_read_cstore          // fewer than two bytes follow
    ldrb w16, [x11]
    cmp w16, #0x86
    b.ne Lfe_lines_read_cstore
    ldrb w16, [x11, #1]
    cmp w16, #0x91
    b.ne Lfe_lines_read_cstore
    add x11, x11, #2
    mov w9, #'^'
Lfe_lines_read_cstore:
    strb w9, [x13], #1
    b Lfe_lines_read_cloop
Lfe_lines_read_remark:
    mov w8, #1
Lfe_lines_read_cdone:
    add x9, sp, #96
    sub x25, x13, x9                    // compacted length
    cbz x25, Lfe_lines_read_next        // empty compacted line: ignored

    // ---- line number: maximal run of leading digits -------------------
    add x13, sp, #96
    mov x26, #0
    mov x27, #0
Lfe_lines_read_digit:
    cmp x27, x25
    b.hs Lfe_lines_read_digits_done
    ldrb w9, [x13, x27]
    sub w9, w9, #'0'
    cmp w9, #9
    b.hi Lfe_lines_read_digits_done
    // accumulate only while the value can still be valid (no overflow)
    cmp x27, #LIM_LINE_DIGITS
    b.hs 1f
    mov x10, #10
    madd x26, x26, x10, x9
1:
    add x27, x27, #1
    b Lfe_lines_read_digit
Lfe_lines_read_digits_done:
    // no digit at the start, more than 5 digits, or the value 0
    cbz x27, Lfe_lines_read_badnum
    cmp x27, #LIM_LINE_DIGITS
    b.hi Lfe_lines_read_badnum
    cbz x26, Lfe_lines_read_badnum
    sub x28, x25, x27                   // statement text length
    add x9, x21, x26, lsl #3            // &table[line]
    cbnz x28, Lfe_lines_read_store
    // digits followed only by a remark: stored with an empty statement
    // text (ILLEGAL INSTRUCTION later), not a deletion (LANGUAGE.md 1.5)
    cbnz w8, Lfe_lines_read_store
    // ---- number alone: delete the line if it exists -------------------
    ldr x10, [x9]
    cbz x10, Lfe_lines_read_next
    str xzr, [x9]
    sub x22, x22, #1
    b Lfe_lines_read_next

Lfe_lines_read_store:
    // ---- number + text: add (counting it) or replace ------------------
    ldr x10, [x9]
    cbnz x10, 1f
    add x22, x22, #1
    mov x11, #LIM_LINES
    cmp x22, x11
    b.ls 1f
    mov w0, #ERR_PROGRAM_TOO_LONG
    mov w1, #0
    bl _fe_fail
1:
    // record = u64 length + the bytes
    add x0, x28, #8
    bl _drv_alloc
    str x28, [x0]
    add x9, x21, x26, lsl #3
    str x0, [x9]                        // table[line] = record
    add x0, x0, #8
    add x1, sp, #96
    add x1, x1, x27                     // text after the line number
    mov x2, x28
    bl _memcpy

Lfe_lines_read_next:
    mov x19, x24
    b Lfe_lines_read_line

Lfe_lines_read_badnum:
    mov w0, #ERR_ILLEGAL_LINE_NUMBER
    mov w1, #0
    bl _fe_fail

Lfe_lines_read_sort:
    // ---- sorted line array: scan the table in line-number order -------
    lsl x0, x22, #4
    add x0, x0, #FE_LINE_ENTRY          // never a zero-size request
    bl _drv_alloc
    adrp x9, _fe_lines@PAGE
    str x0, [x9, _fe_lines@PAGEOFF]
    adrp x9, _fe_nlines@PAGE
    str w22, [x9, _fe_nlines@PAGEOFF]
    mov x10, x0                         // output cursor
    mov x11, #1                         // line number
    movz x12, #((LIM_LINE_NUMBER + 1) & 0xFFFF)
    movk x12, #((LIM_LINE_NUMBER + 1) >> 16), lsl #16
Lfe_lines_read_sloop:
    cmp x11, x12
    b.hs Lfe_lines_read_done
    ldr x9, [x21, x11, lsl #3]
    cbz x9, 1f
    // entry = { line, length, text }
    ldr x13, [x9]
    add x14, x9, #8
    str w11, [x10]
    str w13, [x10, #4]
    str x14, [x10, #8]
    add x10, x10, #FE_LINE_ENTRY
1:
    add x11, x11, #1
    b Lfe_lines_read_sloop
Lfe_lines_read_done:
    ldp x27, x28, [sp, #80]
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #352
    ret

// ---------------------------------------------------------------------
// _fe_line_lookup -- binary search for a program line.
//   in:  w0 = BASIC line number
//   out: w0 = its index in _fe_lines (which is its label id), or -1
//   clobbers: x0, x9-x15
//   callee-saved: none (leaf)
//   frame: none
// ---------------------------------------------------------------------
    .globl _fe_line_lookup
    .p2align 2
_fe_line_lookup:
    adrp x9, _fe_lines@PAGE
    ldr x9, [x9, _fe_lines@PAGEOFF]
    adrp x10, _fe_nlines@PAGE
    ldr w10, [x10, _fe_nlines@PAGEOFF]  // hi (exclusive)
    mov w11, #0                         // lo
Lfe_line_lookup_loop:
    cmp w11, w10
    b.hs Lfe_line_lookup_missing
    add w12, w11, w10
    lsr w12, w12, #1                    // mid
    add x13, x9, x12, lsl #4
    ldr w14, [x13]                      // line number at mid
    cmp w14, w0
    b.eq Lfe_line_lookup_found
    b.hi 1f
    add w11, w12, #1                    // target is above mid
    b Lfe_line_lookup_loop
1:
    mov w10, w12                        // target is below mid
    b Lfe_line_lookup_loop
Lfe_line_lookup_found:
    mov w0, w12
    ret
Lfe_line_lookup_missing:
    mov w0, #-1
    ret
