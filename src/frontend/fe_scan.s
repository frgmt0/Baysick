// =====================================================================
// src/frontend/fe_scan.s -- the mode-driven scanner (include/tokens.inc)
// over the compacted statement text window [_fe_pos, _fe_end).
//
//   _fe_scan(w0=mode, x1=TOK*) -> w0 = TK_* kind   (advances _fe_pos)
//   _fe_getpos() -> x0, _fe_setpos(x0)               save/restore (peek)
//   _fe_peek(w0=offset) -> w0 byte or 0x100 (beyond the line end)
//   _fe_advance(w0=n), _fe_at_eol() -> w0
//   _fe_scan_digits() -> w0 value, w1 digit count  (line numbers, DIM)
//   _fe_next_op() -> w0 kind                        (operator mode, token dropped)
//   _fe_expect_op(w0=kind, w1=err)                  error unless next op token is kind
//   _fe_expect_eol()                                INCORRECT FORMAT unless at the end
//
// Token record conventions beyond tokens.inc: TOK_PTR is always the
// token start (for TK_STRING the first content byte), TOK_LEN is the
// number of bytes consumed (for TK_STRING the content length). A
// TK_BUILTIN with TOK_LEN = 4 consumed its '('; bare RND, NUM and DET have
// TOK_LEN = 3. TK_VAR and TK_SVAR also set TOK_INDEX = their letter and
// TOK_SLOT = the (string) slot; TK_FN0 sets TOK_INDEX = the FN letter. A
// TK_BAD token consumes nothing. Operand-mode TK_BAD codes: ILLEGAL
// CONSTANT (bad number), ILLEGAL VARIABLE (letter+digit+'(', or
// letter+digit+'$('), ILLEGAL FORMULA (NUM( / DET(, or an unexpected
// byte), INCORRECT FORMAT (unterminated string). Operator mode TK_BAD is
// always INCORRECT FORMAT.
// =====================================================================
.include "baysick.inc"

.equ FE_PEEK_EOL,       0x100       // "byte" returned beyond the line end

// FE_PEEK wreg, off: wreg = byte at x20+off, or FE_PEEK_EOL if that is
// at or beyond x21 (the line end). Clobbers x9. Uses local label 8.
.macro FE_PEEK reg, off
    add x9, x20, #\off
    mov \reg, #FE_PEEK_EOL
    cmp x9, x21
    b.hs 8f
    ldrb \reg, [x9]
8:
.endm

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _fe_scan -- scan one token in the given mode.
//   in:  w0 = SCAN_OPERAND or SCAN_OPERATOR, x1 = TOK record to fill
//   out: w0 = token kind (also TOK_KIND); _fe_pos advanced past it
//   clobbers: x0-x17, d0-d7
//   callee-saved: x19 = TOK*, x20 = token start, x21 = line end,
//        w22 = mode, x23 = position after the token
//   frame: 96 bytes (frame record, x19-x24, 32-byte strtod buffer at sp+64)
// ---------------------------------------------------------------------
    .globl _fe_scan
    .p2align 2
_fe_scan:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    mov x19, x1
    mov w22, w0
    adrp x9, _fe_pos@PAGE
    ldr x20, [x9, _fe_pos@PAGEOFF]
    adrp x9, _fe_end@PAGE
    ldr x21, [x9, _fe_end@PAGEOFF]
    // clear the token; PTR = token start
    str wzr, [x19, #TOK_KIND]
    str wzr, [x19, #TOK_INDEX]
    str wzr, [x19, #TOK_SLOT]
    str wzr, [x19, #TOK_LEN]
    str x20, [x19, #TOK_PTR]
    str xzr, [x19, #TOK_VALUE]
    str wzr, [x19, #TOK_ERR]
    mov x23, x20

    FE_PEEK w10, 0
    cmp w10, #FE_PEEK_EOL
    b.ne 1f
    mov w0, #TK_EOL
    b Lfe_scan_finish
1:
    sub w11, w10, #'A'                  // letter index if 0..25
    cmp w22, #SCAN_OPERAND
    b.ne Lfe_scan_opmode
    // ---- operand mode: numbers, strings, names ------------------------
    sub w12, w10, #'0'
    cmp w12, #9
    b.ls Lfe_scan_number
    cmp w10, #'.'
    b.eq Lfe_scan_number
    cmp w10, #'"'
    b.eq Lfe_scan_string
    cmp w11, #25
    b.ls Lfe_scan_name
    b Lfe_scan_punct
Lfe_scan_opmode:
    // ---- operator mode: only THEN / TO / STEP / GOTO start with a letter
    cmp w11, #25
    b.ls Lfe_scan_keyword

Lfe_scan_punct:
    // single / double character punctuation, shared by both modes
    add x23, x20, #1
    mov w0, #TK_LPAREN
    cmp w10, #'('
    b.eq Lfe_scan_finish
    mov w0, #TK_RPAREN
    cmp w10, #')'
    b.eq Lfe_scan_finish
    mov w0, #TK_COMMA
    cmp w10, #','
    b.eq Lfe_scan_finish
    mov w0, #TK_SEMI
    cmp w10, #';'
    b.eq Lfe_scan_finish
    mov w0, #TK_PLUS
    cmp w10, #'+'
    b.eq Lfe_scan_finish
    mov w0, #TK_MINUS
    cmp w10, #'-'
    b.eq Lfe_scan_finish
    mov w0, #TK_STAR
    cmp w10, #'*'
    b.eq Lfe_scan_finish
    mov w0, #TK_SLASH
    cmp w10, #'/'
    b.eq Lfe_scan_finish
    mov w0, #TK_POW
    cmp w10, #'^'
    b.eq Lfe_scan_finish
    mov w0, #TK_EQ
    cmp w10, #'='
    b.eq Lfe_scan_finish
    cmp w10, #'<'
    b.eq Lfe_scan_less
    cmp w10, #'>'
    b.eq Lfe_scan_greater
    b Lfe_scan_bad_default
Lfe_scan_less:
    // '<' then '=' or '>' (longest match first)
    FE_PEEK w12, 1
    mov w0, #TK_LT
    cmp w12, #'='
    b.ne 1f
    mov w0, #TK_LE
    add x23, x20, #2
1:
    cmp w12, #'>'
    b.ne Lfe_scan_finish
    mov w0, #TK_NE
    add x23, x20, #2
    b Lfe_scan_finish
Lfe_scan_greater:
    FE_PEEK w12, 1
    mov w0, #TK_GT
    cmp w12, #'='
    b.ne Lfe_scan_finish
    mov w0, #TK_GE
    add x23, x20, #2
    b Lfe_scan_finish

Lfe_scan_bad_default:
    // unexpected byte: the error depends on what the parser wanted
    mov w1, #ERR_ILLEGAL_FORMULA
    cmp w22, #SCAN_OPERAND
    b.eq Lfe_scan_bad
    mov w1, #ERR_INCORRECT_FORMAT
Lfe_scan_bad:
    // w1 = error code; a bad token consumes nothing
    str w1, [x19, #TOK_ERR]
    mov x23, x20
    mov w0, #TK_BAD
    b Lfe_scan_finish

// ---- numeric constant (LANGUAGE.md 4.1) -------------------------------
//   x11 = cursor, w12 = mantissa digits, w13 = digits before the point,
//   w14 = digits after the point / exponent digits
Lfe_scan_number:
    mov x11, x20
    mov w12, #0
1:
    // integer digits
    cmp x11, x21
    b.hs 2f
    ldrb w9, [x11]
    sub w9, w9, #'0'
    cmp w9, #9
    b.hi 2f
    add w12, w12, #1
    add x11, x11, #1
    b 1b
2:
    mov w13, w12
    // optional fraction
    cmp x11, x21
    b.hs Lfe_scan_num_mant_done
    ldrb w9, [x11]
    cmp w9, #'.'
    b.ne Lfe_scan_num_mant_done
    add x11, x11, #1
    mov w14, #0
3:
    cmp x11, x21
    b.hs 4f
    ldrb w9, [x11]
    sub w9, w9, #'0'
    cmp w9, #9
    b.hi 4f
    add w12, w12, #1
    add w14, w14, #1
    add x11, x11, #1
    b 3b
4:
    // a '.' with no digit on either side is a stray point
    orr w9, w13, w14
    cbz w9, Lfe_scan_num_bad
Lfe_scan_num_mant_done:
    cmp w12, #LIM_NUM_DIGITS
    b.hi Lfe_scan_num_bad
    // exponent only if 'E' is followed by a digit, or a sign and a digit
    cmp x11, x21
    b.hs Lfe_scan_num_end
    ldrb w9, [x11]
    cmp w9, #'E'
    b.ne Lfe_scan_num_end
    add x15, x11, #1                    // first exponent digit candidate
    cmp x15, x21
    b.hs Lfe_scan_num_end
    ldrb w9, [x15]
    cmp w9, #'+'
    b.eq 5f
    cmp w9, #'-'
    b.ne 6f
5:
    add x15, x15, #1                    // skip the sign
    cmp x15, x21
    b.hs Lfe_scan_num_end
    ldrb w9, [x15]
6:
    sub w9, w9, #'0'
    cmp w9, #9
    b.hi Lfe_scan_num_end               // 'E' belongs to the next token
    // count exponent digits
    mov x11, x15
    mov w14, #0
7:
    cmp x11, x21
    b.hs 9f
    ldrb w9, [x11]
    sub w9, w9, #'0'
    cmp w9, #9
    b.hi 9f
    add w14, w14, #1
    add x11, x11, #1
    b 7b
9:
    cmp w14, #LIM_EXP_DIGITS
    b.hi Lfe_scan_num_bad
Lfe_scan_num_end:
    // a '.' right after a complete constant (1.2.3) is illegal
    cmp x11, x21
    b.hs 1f
    ldrb w9, [x11]
    cmp w9, #'.'
    b.eq Lfe_scan_num_bad
1:
    mov x23, x11
    // copy the text into a NUL-terminated buffer (at most 14 bytes) so
    // strtod sees exactly this constant and nothing after it
    add x10, sp, #64
    mov x12, x20
2:
    cmp x12, x23
    b.hs 3f
    ldrb w9, [x12], #1
    strb w9, [x10], #1
    b 2b
3:
    strb wzr, [x10]
    add x0, sp, #64
    mov x1, #0
    bl _strtod
    fmov x9, d0
    str x9, [x19, #TOK_VALUE]
    mov w0, #TK_NUMBER
    b Lfe_scan_finish
Lfe_scan_num_bad:
    mov w1, #ERR_ILLEGAL_CONSTANT
    b Lfe_scan_bad

// ---- string literal ----------------------------------------------------
Lfe_scan_string:
    add x11, x20, #1
1:
    cmp x11, x21
    b.hs Lfe_scan_string_open
    ldrb w9, [x11]
    cmp w9, #'"'
    b.eq 2f
    add x11, x11, #1
    b 1b
2:
    // contents between the quotes
    add x12, x20, #1
    str x12, [x19, #TOK_PTR]
    sub x13, x11, x12
    str w13, [x19, #TOK_LEN]
    add x23, x11, #1
    mov w0, #TK_STRING
    str w0, [x19, #TOK_KIND]
    b Lfe_scan_store_pos
Lfe_scan_string_open:
    // runs to the end of the line: unterminated
    mov w1, #ERR_INCORRECT_FORMAT
    b Lfe_scan_bad

// ---- operand-position names (LANGUAGE.md 5.2 step 3) --------------------
//   w10..w13 = the next four bytes c0..c3 (FE_PEEK_EOL past the end)
Lfe_scan_name:
    FE_PEEK w11, 1
    FE_PEEK w12, 2
    FE_PEEK w13, 3
    // builtin name: three letters, then '(' (or bare RND)
    adrp x14, Lfe_scan_builtins@PAGE
    add x14, x14, Lfe_scan_builtins@PAGEOFF
    mov w15, #0                         // builtin index
Lfe_scan_bi_loop:
    cmp w15, #BI_COUNT
    b.hs Lfe_scan_fn
    add x16, x14, x15, lsl #2           // 4 bytes per name
    ldrb w9, [x16]
    cmp w9, w10
    b.ne 1f
    ldrb w9, [x16, #1]
    cmp w9, w11
    b.ne 1f
    ldrb w9, [x16, #2]
    cmp w9, w12
    b.ne 1f
    // name matches
    str w15, [x19, #TOK_INDEX]
    mov w0, #TK_BUILTIN
    cmp w15, #BI_NUM
    b.hs Lfe_scan_bi_noarg              // NUM, DET: never an argument
    // builtin call if '(' follows
    add x23, x20, #4
    cmp w13, #'('
    b.eq Lfe_scan_finish
    // without '(' only RND is still a builtin (bare RND)
    add x23, x20, #3
    cmp w15, #BI_RND
    b.eq Lfe_scan_finish
    str wzr, [x19, #TOK_INDEX]
    b Lfe_scan_fn                       // names are unique: stop looking
Lfe_scan_bi_noarg:
    // NUM / DET (LANGUAGE.md 5.2 step 3.3): a '(' after them is a formula error
    add x23, x20, #3
    cmp w13, #'('
    b.ne Lfe_scan_finish
    mov w1, #ERR_ILLEGAL_FORMULA
    b Lfe_scan_bad
1:
    add w15, w15, #1
    b Lfe_scan_bi_loop
Lfe_scan_fn:
    // F N letter: user function, which needs '('
    cmp w10, #'F'
    b.ne Lfe_scan_var
    cmp w11, #'N'
    b.ne Lfe_scan_var
    sub w14, w12, #'A'
    cmp w14, #25
    b.hi Lfe_scan_var
    str w14, [x19, #TOK_INDEX]
    cmp w13, #'('
    b.ne 1f
    add x23, x20, #4
    mov w0, #TK_FN
    b Lfe_scan_finish
1:
    // FNx without '(': a call without arguments, or the value variable
    // inside FNx's own multi-line body (the parser decides)
    add x23, x20, #3
    mov w0, #TK_FN0
    b Lfe_scan_finish
Lfe_scan_var:
    // letter [digit], then '$' (string) or '(' (array) may follow
    sub w14, w10, #'A'
    str w14, [x19, #TOK_INDEX]
    mov w15, #SLOT_PER_LETTER
    mul w15, w14, w15                   // slot of the bare letter
    sub w16, w11, #'0'
    cmp w16, #9
    b.hi Lfe_scan_var_nodigit
    // letter + digit: slot letter*11 + digit + 1
    add w15, w15, w16
    add w15, w15, #1
    str w15, [x19, #TOK_SLOT]
    cmp w12, #'$'
    b.eq Lfe_scan_var_dsvar
    // letter + digit + '(' is an illegal variable
    cmp w12, #'('
    b.eq Lfe_scan_var_illegal
    add x23, x20, #2
    mov w0, #TK_VAR
    b Lfe_scan_finish
Lfe_scan_var_dsvar:
    // C7$ is a string variable; C7$( an illegal string list name
    cmp w13, #'('
    b.eq Lfe_scan_var_illegal
    add x23, x20, #3
    mov w0, #TK_SVAR
    b Lfe_scan_finish
Lfe_scan_var_illegal:
    mov w1, #ERR_ILLEGAL_VARIABLE
    b Lfe_scan_bad
Lfe_scan_var_nodigit:
    str w15, [x19, #TOK_SLOT]
    cmp w11, #'$'
    b.ne 2f
    // A$ string variable, or A$( string list ('(' consumed)
    add x23, x20, #2
    mov w0, #TK_SVAR
    cmp w12, #'('
    b.ne Lfe_scan_finish
    add x23, x20, #3
    mov w0, #TK_SARRAY
    b Lfe_scan_finish
2:
    cmp w11, #'('
    b.ne 1f
    add x23, x20, #2                    // array: '(' consumed
    mov w0, #TK_ARRAY
    b Lfe_scan_finish
1:
    add x23, x20, #1
    mov w0, #TK_VAR
    b Lfe_scan_finish

// ---- operator-position keywords THEN TO STEP GOTO (LANGUAGE.md 3.3) ------------
Lfe_scan_keyword:
    FE_PEEK w11, 1
    FE_PEEK w12, 2
    FE_PEEK w13, 3
    cmp w10, #'T'
    b.ne Lfe_scan_kw_step
    // THEN
    cmp w11, #'H'
    b.ne 1f
    cmp w12, #'E'
    b.ne Lfe_scan_kw_bad
    cmp w13, #'N'
    b.ne Lfe_scan_kw_bad
    add x23, x20, #4
    mov w0, #TK_THEN
    b Lfe_scan_finish
1:
    // TO
    cmp w11, #'O'
    b.ne Lfe_scan_kw_bad
    add x23, x20, #2
    mov w0, #TK_TO
    b Lfe_scan_finish
Lfe_scan_kw_step:
    cmp w10, #'S'
    b.ne Lfe_scan_kw_goto
    cmp w11, #'T'
    b.ne Lfe_scan_kw_bad
    cmp w12, #'E'
    b.ne Lfe_scan_kw_bad
    cmp w13, #'P'
    b.ne Lfe_scan_kw_bad
    add x23, x20, #4
    mov w0, #TK_STEP
    b Lfe_scan_finish
Lfe_scan_kw_goto:
    // GOTO (IF ... GOTO, ON ... GOTO; "GO TO" is compacted to GOTO)
    cmp w10, #'G'
    b.ne Lfe_scan_kw_bad
    cmp w11, #'O'
    b.ne Lfe_scan_kw_bad
    cmp w12, #'T'
    b.ne Lfe_scan_kw_bad
    cmp w13, #'O'
    b.ne Lfe_scan_kw_bad
    add x23, x20, #4
    mov w0, #TK_GOTO
    b Lfe_scan_finish
Lfe_scan_kw_bad:
    mov w1, #ERR_INCORRECT_FORMAT
    b Lfe_scan_bad

// ---- common exit: w0 = kind, x23 = new position ------------------------
Lfe_scan_finish:
    str w0, [x19, #TOK_KIND]
    sub x9, x23, x20
    str w9, [x19, #TOK_LEN]             // bytes consumed
Lfe_scan_store_pos:
    adrp x9, _fe_pos@PAGE
    str x23, [x9, _fe_pos@PAGEOFF]
    ldr w0, [x19, #TOK_KIND]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #96
    ret

// ---------------------------------------------------------------------
// _fe_getpos -- current scanner position.
//   in: none   out: x0 = _fe_pos   clobbers: x9   leaf, no frame
// ---------------------------------------------------------------------
    .globl _fe_getpos
    .p2align 2
_fe_getpos:
    adrp x9, _fe_pos@PAGE
    ldr x0, [x9, _fe_pos@PAGEOFF]
    ret

// ---------------------------------------------------------------------
// _fe_setpos -- rewind/advance the scanner to a saved position.
//   in: x0 = position   out: none   clobbers: x9   leaf, no frame
// ---------------------------------------------------------------------
    .globl _fe_setpos
    .p2align 2
_fe_setpos:
    adrp x9, _fe_pos@PAGE
    str x0, [x9, _fe_pos@PAGEOFF]
    ret

// ---------------------------------------------------------------------
// _fe_peek -- look at a byte ahead of the scanner position.
//   in:  w0 = offset from _fe_pos
//   out: w0 = the byte, or FE_PEEK_EOL (0x100) if beyond the line end
//   clobbers: x9-x11   leaf, no frame
// ---------------------------------------------------------------------
    .globl _fe_peek
    .p2align 2
_fe_peek:
    adrp x9, _fe_pos@PAGE
    ldr x10, [x9, _fe_pos@PAGEOFF]
    adrp x9, _fe_end@PAGE
    ldr x11, [x9, _fe_end@PAGEOFF]
    add x10, x10, w0, uxtw
    cmp x10, x11
    b.hs 1f
    ldrb w0, [x10]
    ret
1:
    mov w0, #FE_PEEK_EOL
    ret

// ---------------------------------------------------------------------
// _fe_advance -- skip bytes.
//   in: w0 = number of bytes   out: none   clobbers: x9, x10   leaf
// ---------------------------------------------------------------------
    .globl _fe_advance
    .p2align 2
_fe_advance:
    adrp x9, _fe_pos@PAGE
    ldr x10, [x9, _fe_pos@PAGEOFF]
    add x10, x10, w0, uxtw
    str x10, [x9, _fe_pos@PAGEOFF]
    ret

// ---------------------------------------------------------------------
// _fe_at_eol -- is the scanner at the end of the statement text?
//   in: none   out: w0 = 1 at the end, else 0   clobbers: x9-x11   leaf
// ---------------------------------------------------------------------
    .globl _fe_at_eol
    .p2align 2
_fe_at_eol:
    adrp x9, _fe_pos@PAGE
    ldr x10, [x9, _fe_pos@PAGEOFF]
    adrp x9, _fe_end@PAGE
    ldr x11, [x9, _fe_end@PAGEOFF]
    cmp x10, x11
    cset w0, hs
    ret

// ---------------------------------------------------------------------
// _fe_scan_digits -- consume a run of decimal digits.
//   in:  none
//   out: w0 = value of the digits (accumulated over the first 9 digits
//        only, so it never overflows; callers check the count first),
//        w1 = number of digits consumed (0 if none)
//   clobbers: x9-x13   leaf, no frame
// ---------------------------------------------------------------------
    .globl _fe_scan_digits
    .p2align 2
_fe_scan_digits:
    adrp x9, _fe_pos@PAGE
    ldr x10, [x9, _fe_pos@PAGEOFF]
    adrp x11, _fe_end@PAGE
    ldr x11, [x11, _fe_end@PAGEOFF]
    mov w0, #0
    mov w1, #0
    mov w13, #10
Lfe_scan_digits_loop:
    cmp x10, x11
    b.hs Lfe_scan_digits_done
    ldrb w12, [x10]
    sub w12, w12, #'0'
    cmp w12, #9
    b.hi Lfe_scan_digits_done
    // value = value*10 + digit, for at most LIM_NUM_DIGITS digits
    cmp w1, #LIM_NUM_DIGITS
    b.hs 1f
    madd w0, w0, w13, w12
1:
    add w1, w1, #1
    add x10, x10, #1
    b Lfe_scan_digits_loop
Lfe_scan_digits_done:
    str x10, [x9, _fe_pos@PAGEOFF]
    ret

// ---------------------------------------------------------------------
// _fe_next_op -- scan one operator-mode token, keeping only its kind.
//   in: none   out: w0 = TK_* kind (_fe_pos advanced past the token)
//   clobbers: x0-x17, d0-d7
//   callee-saved: none used
//   frame: 64 bytes (frame record + 40-byte token at sp+16)
// ---------------------------------------------------------------------
    .globl _fe_next_op
    .p2align 2
_fe_next_op:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    mov w0, #SCAN_OPERATOR
    add x1, sp, #16
    bl _fe_scan
    ldp x29, x30, [sp], #64
    ret

// ---------------------------------------------------------------------
// _fe_expect_op -- require a given operator-mode token.
//   in:  w0 = required TK_* kind, w1 = ERR_* to report otherwise
//   out: returns only if the token matched (it is consumed)
//   clobbers: x0-x17, d0-d7
//   callee-saved: x19 = required kind, x20 = error code
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .globl _fe_expect_op
    .p2align 2
_fe_expect_op:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov w19, w0
    mov w20, w1
    bl _fe_next_op
    cmp w0, w19
    b.eq 1f
    mov w0, w20
    bl _fe_err
1:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _fe_expect_eol -- the statement must end here (LANGUAGE.md 7).
//   in: none   out: returns only at the end of the text; else
//   INCORRECT FORMAT
//   clobbers: x0-x17
//   callee-saved: none used
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .globl _fe_expect_eol
    .p2align 2
_fe_expect_eol:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl _fe_at_eol
    cbnz w0, 1f
    mov w0, #ERR_INCORRECT_FORMAT
    bl _fe_err
1:
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Builtin names in BI_* order, 4 bytes each (3 letters + padding).
// ---------------------------------------------------------------------
    .section __TEXT,__const
    .p2align 2
Lfe_scan_builtins:
    .ascii "SIN", "\0"
    .ascii "COS", "\0"
    .ascii "TAN", "\0"
    .ascii "ATN", "\0"
    .ascii "EXP", "\0"
    .ascii "ABS", "\0"
    .ascii "LOG", "\0"
    .ascii "SQR", "\0"
    .ascii "INT", "\0"
    .ascii "RND", "\0"
    .ascii "SGN", "\0"
    .ascii "COT", "\0"
    .ascii "NUM", "\0"
    .ascii "DET", "\0"
