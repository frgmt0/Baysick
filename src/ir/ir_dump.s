// =====================================================================
// src/ir/ir_dump.s -- canonical text dump of a Module (docs/IR.md 5).
//
//   _ir_dump(x0=Module*, x1=OutBuf*)   appends the dump
//
// Instructions are printed from a per-opcode template (Lird_formats):
// literal text, plus '%' directives that print an operand:
//   %D %A %B %C   "t<n>" for the DST / A / B / C temp
//   %V            variable slot in X ("A", "X7", "%lim3", "%step3")
//   %L  %M        label in X / in IMM ("@<line>" or "L<id>")
//   %R            array letter in X        %F   "FN" + letter in X
//   %S            "s<n>" string id in X    %N   IMM as unsigned decimal
//   %K            "0x" + 16 hex digits of IMM + " ; " + %.17g value
//   %Q            relation name of REL ("eq" ... "ge")
// =====================================================================
.include "baysick.inc"

    .section __TEXT,__text,regular,pure_instructions

.macro IRD_ADR reg, sym
    adrp \reg, \sym@PAGE
    add \reg, \reg, \sym@PAGEOFF
.endm

// ob_puts(x19 OutBuf, literal)
.macro IRD_PUTS lit
    mov x0, x19
    IRD_ADR x1, \lit
    bl _ob_puts
.endm

// ob_putu(x19 OutBuf, value register)
.macro IRD_PUTU reg
    mov x0, x19
    mov x1, \reg
    bl _ob_putu
.endm

// ob_putc(x19 OutBuf, immediate character)
.macro IRD_PUTC ch
    mov x0, x19
    mov w1, #\ch
    bl _ob_putc
.endm

// ---------------------------------------------------------------------
// _ir_dump -- append the canonical text dump of a module.
//   in:  x0 = Module*, x1 = OutBuf*
//   out: none
//   clobbers: x0-x17, d0-d7, d16-d31
//   callee-saved: x19 = OutBuf*, x20 = Module*, x21 = loop index,
//                 x22 = count / current record, x23 = Function*,
//                 x24 = instruction cursor, x25 = instructions left
//   frame: 80 bytes
// ---------------------------------------------------------------------
    .globl _ir_dump
    .p2align 2
_ir_dump:
    stp x29, x30, [sp, #-80]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    str x25, [sp, #64]
    mov x20, x0
    mov x19, x1
    // ---- header ----
    IRD_PUTS Lird_s_header
    mov x9, #IR_VERSION
    IRD_PUTU x9
    IRD_PUTC '\n'
    // ---- module line; count present functions first ----
    mov x22, #0
    mov x21, #0
    add x9, x20, #IRM_FUNCS
1:
    ldr w10, [x9, #IRF_PRESENT]
    cmp w10, #0
    cinc x22, x22, ne
    add x9, x9, #IRF_SIZE
    add x21, x21, #1
    cmp x21, #NUM_FUNCS
    b.lo 1b
    IRD_PUTS Lird_s_slots
    ldr w9, [x20, #IRM_NSLOTS]
    IRD_PUTU x9
    IRD_PUTS Lird_s_fors
    ldr w9, [x20, #IRM_NFORS]
    IRD_PUTU x9
    IRD_PUTS Lird_s_funcs
    IRD_PUTU x22
    IRD_PUTS Lird_s_strings
    ldr w9, [x20, #IRM_NSTRINGS]
    IRD_PUTU x9
    IRD_PUTS Lird_s_data
    ldr w9, [x20, #IRM_NDATA]
    IRD_PUTU x9
    IRD_PUTC '\n'
    // ---- arrays A..Z (used ones only) ----
    mov x21, #0
Lird_array_loop:
    mov x9, #IRA_SIZE
    madd x22, x21, x9, x20
    add x22, x22, #IRM_ARRAYS           // x22 = array entry
    ldr w9, [x22, #IRA_DIMS]
    cbz w9, Lird_array_next
    IRD_PUTS Lird_s_array
    add x9, x21, #'A'
    mov x0, x19
    mov w1, w9
    bl _ob_putc
    IRD_PUTS Lird_s_dims
    ldr w9, [x22, #IRA_DIMS]
    IRD_PUTU x9
    IRD_PUTS Lird_s_b1
    ldr w9, [x22, #IRA_B1]
    IRD_PUTU x9
    // lists stop after b1; tables also show b2
    ldr w9, [x22, #IRA_DIMS]
    cmp w9, #1
    b.eq 2f
    IRD_PUTS Lird_s_b2
    ldr w9, [x22, #IRA_B2]
    IRD_PUTU x9
2:
    IRD_PUTC '\n'
Lird_array_next:
    add x21, x21, #1
    cmp x21, #NUM_LETTERS
    b.lo Lird_array_loop
    // ---- strings ----
    mov x21, #0
Lird_string_loop:
    ldr w9, [x20, #IRM_NSTRINGS]
    cmp x21, x9
    b.hs Lird_strings_done
    ldr x10, [x20, #IRM_STRINGS]
    mov x11, #IRS_SIZE
    madd x22, x21, x11, x10             // x22 = string entry
    IRD_PUTS Lird_s_string
    IRD_PUTU x21
    IRD_PUTS Lird_s_quote_open
    // raw bytes of the literal
    mov x0, x19
    ldr x1, [x22, #IRS_PTR]
    ldr w2, [x22, #IRS_LEN]
    bl _ob_putn
    IRD_PUTS Lird_s_quote_close
    add x21, x21, #1
    b Lird_string_loop
Lird_strings_done:
    // ---- data ----
    mov x21, #0
Lird_data_loop:
    ldr w9, [x20, #IRM_NDATA]
    cmp x21, x9
    b.hs Lird_data_done
    IRD_PUTS Lird_s_datad
    IRD_PUTU x21
    IRD_PUTC ' '
    ldr x10, [x20, #IRM_DATA]
    ldr x1, [x10, x21, lsl #3]
    mov x0, x19
    bl Lird_const
    IRD_PUTC '\n'
    add x21, x21, #1
    b Lird_data_loop
Lird_data_done:
    // ---- functions: main, then FNA..FNZ ----
    mov x21, #0
Lird_func_loop:
    mov x9, #IRF_SIZE
    madd x23, x21, x9, x20
    add x23, x23, #IRM_FUNCS            // x23 = Function*
    ldr w9, [x23, #IRF_PRESENT]
    cbz w9, Lird_func_next
    cbnz x21, 3f
    IRD_PUTS Lird_s_func_main
    b 4f
3:
    // "func FN<letter> param=<var>"
    IRD_PUTS Lird_s_func_fn
    add x9, x21, #('A' - FUNC_FN_BASE)
    mov x0, x19
    mov w1, w9
    bl _ob_putc
    IRD_PUTS Lird_s_param
    mov x0, x19
    ldr w1, [x23, #IRF_PARAM]
    bl Lird_var
4:
    IRD_PUTS Lird_s_temps
    ldr w9, [x23, #IRF_NTEMPS]
    IRD_PUTU x9
    IRD_PUTS Lird_s_labels
    ldr w9, [x23, #IRF_NLABELS]
    IRD_PUTU x9
    IRD_PUTC '\n'
    // instructions, each "  <text>\n"
    ldr x24, [x23, #IRF_INSNS]
    ldr w25, [x23, #IRF_NINSNS]
Lird_insn_loop:
    cbz w25, Lird_insn_done
    IRD_PUTS Lird_s_indent
    mov x0, x19
    mov x1, x23
    mov x2, x24
    bl Lird_insn
    IRD_PUTC '\n'
    add x24, x24, #IRI_SIZE
    sub w25, w25, #1
    b Lird_insn_loop
Lird_insn_done:
    IRD_PUTS Lird_s_endfunc
Lird_func_next:
    add x21, x21, #1
    cmp x21, #NUM_FUNCS
    b.lo Lird_func_loop
    ldr x25, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #80
    ret

// ---------------------------------------------------------------------
// Lird_insn -- print one instruction's text form (no indent, no LF).
//   in:  x0 = OutBuf*, x1 = Function*, x2 = IRI record
//   out: none
//   clobbers: x0-x17, d0-d7, d16-d31
//   callee-saved: x19 = OutBuf*, x20 = Function*, x21 = record,
//                 x22 = template cursor
//   frame: 48 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lird_insn:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov x19, x0
    mov x20, x1
    mov x21, x2
    ldrh w9, [x21, #IRI_OP]
    cmp w9, #OP_COUNT
    b.hs Lird_insn_badop
    // template for this opcode
    IRD_ADR x10, Lird_formats
    ldr x22, [x10, x9, lsl #3]
Lird_fmt_loop:
    ldrb w1, [x22], #1
    cbz w1, Lird_insn_ret
    cmp w1, #'%'
    b.eq Lird_fmt_directive
    mov x0, x19
    bl _ob_putc
    b Lird_fmt_loop
Lird_fmt_directive:
    ldrb w9, [x22], #1
    cmp w9, #'D'
    b.eq Lird_fmt_D
    cmp w9, #'A'
    b.eq Lird_fmt_A
    cmp w9, #'B'
    b.eq Lird_fmt_B
    cmp w9, #'C'
    b.eq Lird_fmt_C
    cmp w9, #'V'
    b.eq Lird_fmt_V
    cmp w9, #'L'
    b.eq Lird_fmt_L
    cmp w9, #'M'
    b.eq Lird_fmt_M
    cmp w9, #'R'
    b.eq Lird_fmt_R
    cmp w9, #'F'
    b.eq Lird_fmt_F
    cmp w9, #'S'
    b.eq Lird_fmt_S
    cmp w9, #'N'
    b.eq Lird_fmt_N
    cmp w9, #'K'
    b.eq Lird_fmt_K
    // only '%Q' is left (the templates are fixed)
    ldrh w1, [x21, #IRI_REL]
    mov x0, x19
    bl Lird_rel
    b Lird_fmt_loop
Lird_fmt_D:
    ldr w9, [x21, #IRI_DST]
    b Lird_fmt_temp
Lird_fmt_A:
    ldr w9, [x21, #IRI_A]
    b Lird_fmt_temp
Lird_fmt_B:
    ldr w9, [x21, #IRI_B]
    b Lird_fmt_temp
Lird_fmt_C:
    ldr w9, [x21, #IRI_C]
Lird_fmt_temp:
    // "t<n>"
    str x9, [sp, #-16]!
    IRD_PUTC 't'
    ldr x9, [sp], #16
    IRD_PUTU x9
    b Lird_fmt_loop
Lird_fmt_V:
    mov x0, x19
    ldr w1, [x21, #IRI_X]
    bl Lird_var
    b Lird_fmt_loop
Lird_fmt_L:
    ldr w2, [x21, #IRI_X]
    b Lird_fmt_label
Lird_fmt_M:
    ldr x2, [x21, #IRI_IMM]
Lird_fmt_label:
    mov x0, x19
    mov x1, x20
    bl Lird_label
    b Lird_fmt_loop
Lird_fmt_R:
    ldr w9, [x21, #IRI_X]
    add w1, w9, #'A'
    mov x0, x19
    bl _ob_putc
    b Lird_fmt_loop
Lird_fmt_F:
    IRD_PUTS Lird_s_fn
    ldr w9, [x21, #IRI_X]
    add w1, w9, #'A'
    mov x0, x19
    bl _ob_putc
    b Lird_fmt_loop
Lird_fmt_S:
    IRD_PUTC 's'
    ldr w9, [x21, #IRI_X]
    IRD_PUTU x9
    b Lird_fmt_loop
Lird_fmt_N:
    ldr x9, [x21, #IRI_IMM]
    IRD_PUTU x9
    b Lird_fmt_loop
Lird_fmt_K:
    mov x0, x19
    ldr x1, [x21, #IRI_IMM]
    bl Lird_const
    b Lird_fmt_loop
Lird_insn_badop:
    // not a valid opcode (only reachable for unverified modules)
    mov x22, x9
    IRD_PUTS Lird_s_badop
    IRD_PUTU x22
Lird_insn_ret:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// Lird_const -- print "0x<16 HEX> ; <%.17g>" for IEEE-754 bits.
//   in:  x0 = OutBuf*, x1 = bits
//   out: none
//   clobbers: x0-x17, d0-d7, d16-d31
//   callee-saved: x19 = OutBuf*, x20 = bits
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lird_const:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    mov x20, x1
    IRD_PUTS Lird_s_0x
    mov x0, x19
    mov x1, x20
    bl _ob_puthex16
    IRD_PUTS Lird_s_semi
    fmov d0, x20
    mov x0, x19
    bl _ob_putg17
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lird_var -- print a variable slot name.
//   slot < SLOT_FOR_BASE: letter (+ digit); else "%lim<k>" / "%step<k>".
//   in:  x0 = OutBuf*, w1 = slot
//   out: none
//   clobbers: x0-x17
//   callee-saved: x19 = OutBuf*, x20 = slot / remainder
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lird_var:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    mov w20, w1
    cmp w20, #SLOT_FOR_BASE
    b.hs Lird_var_for
    // letter = slot / 11, digit+1 = slot % 11 (0 = bare letter)
    mov w9, #SLOT_PER_LETTER
    udiv w10, w20, w9
    msub w20, w10, w9, w20
    add w1, w10, #'A'
    mov x0, x19
    bl _ob_putc
    cbz w20, Lird_var_done
    add w1, w20, #('0' - 1)
    mov x0, x19
    bl _ob_putc
    b Lird_var_done
Lird_var_for:
    // k = (slot - base) / 2; even = limit, odd = step
    sub w20, w20, #SLOT_FOR_BASE
    tbnz w20, #0, 1f
    IRD_PUTS Lird_s_lim
    b 2f
1:
    IRD_PUTS Lird_s_step
2:
    lsr w9, w20, #1
    IRD_PUTU x9
Lird_var_done:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lird_label -- print a label reference: "@<line>" if the label is a
// line label (LABELS[id] != 0), else "L<id>".
//   in:  x0 = OutBuf*, x1 = Function*, x2 = label id
//   out: none
//   clobbers: x0-x17
//   callee-saved: x19 = OutBuf*, x20 = label id
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lird_label:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    mov x20, x2
    ldr w9, [x1, #IRF_NLABELS]
    cmp x20, x9
    b.hs 1f                             // out of range: show the id
    ldr x10, [x1, #IRF_LABELS]
    ldr w11, [x10, x20, lsl #2]
    cbz w11, 1f
    // line label
    str x11, [sp, #-16]!
    IRD_PUTC '@'
    ldr x11, [sp], #16
    IRD_PUTU x11
    b 2f
1:
    IRD_PUTC 'L'
    IRD_PUTU x20
2:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lird_rel -- print a relation name.
//   in:  x0 = OutBuf*, w1 = REL_* code
//   out: none
//   clobbers: x0-x17
//   callee-saved: x19 = OutBuf*, x20 = code
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lird_rel:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    mov w20, w1
    sub w9, w20, #REL_EQ
    cmp w9, #(REL_GE - REL_EQ)
    b.hi 1f
    // names are 3-byte "xx\0" records in REL_EQ..REL_GE order
    IRD_ADR x1, Lird_relnames
    mov w10, #3
    umaddl x1, w9, w10, x1
    mov x0, x19
    bl _ob_puts
    b 2f
1:
    // invalid code (unverified module): "rel<n>"
    IRD_PUTS Lird_s_rel
    IRD_PUTU x20
2:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

    .section __TEXT,__cstring,cstring_literals
Lird_s_header:      .asciz "; baysick-ir "
Lird_s_slots:       .asciz "module slots="
Lird_s_fors:        .asciz " fors="
Lird_s_funcs:       .asciz " funcs="
Lird_s_strings:     .asciz " strings="
Lird_s_data:        .asciz " data="
Lird_s_array:       .asciz "array "
Lird_s_dims:        .asciz " dims="
Lird_s_b1:          .asciz " b1="
Lird_s_b2:          .asciz " b2="
Lird_s_string:      .asciz "string s"
Lird_s_quote_open:  .asciz " \""
Lird_s_quote_close: .asciz "\"\n"
Lird_s_datad:       .asciz "data d"
Lird_s_func_main:   .asciz "func main"
Lird_s_func_fn:     .asciz "func FN"
Lird_s_param:       .asciz " param="
Lird_s_temps:       .asciz " temps="
Lird_s_labels:      .asciz " labels="
Lird_s_indent:      .asciz "  "
Lird_s_endfunc:     .asciz "endfunc\n"
Lird_s_fn:          .asciz "FN"
Lird_s_0x:          .asciz "0x"
Lird_s_semi:        .asciz " ; "
Lird_s_lim:         .asciz "%lim"
Lird_s_step:        .asciz "%step"
Lird_s_rel:         .asciz "rel"
Lird_s_badop:       .asciz "op "

    .section __TEXT,__const
Lird_relnames:      // REL_EQ .. REL_GE, 3 bytes each
    .asciz "eq"
    .asciz "ne"
    .asciz "lt"
    .asciz "le"
    .asciz "gt"
    .asciz "ge"

// instruction templates, indexed by opcode (docs/IR.md section 3)
Lird_f_nop:     .asciz "nop"
Lird_f_line:    .asciz "line %N"
Lird_f_label:   .asciz "label %L"
Lird_f_const:   .asciz "%D = const %K"
Lird_f_ldv:     .asciz "%D = ldv %V"
Lird_f_stv:     .asciz "stv %V, %A"
Lird_f_add:     .asciz "%D = add %A, %B"
Lird_f_sub:     .asciz "%D = sub %A, %B"
Lird_f_mul:     .asciz "%D = mul %A, %B"
Lird_f_div:     .asciz "%D = div %A, %B"
Lird_f_pow:     .asciz "%D = pow %A, %B"
Lird_f_neg:     .asciz "%D = neg %A"
Lird_f_sin:     .asciz "%D = sin %A"
Lird_f_cos:     .asciz "%D = cos %A"
Lird_f_tan:     .asciz "%D = tan %A"
Lird_f_atn:     .asciz "%D = atn %A"
Lird_f_exp:     .asciz "%D = exp %A"
Lird_f_abs:     .asciz "%D = abs %A"
Lird_f_log:     .asciz "%D = log %A"
Lird_f_sqr:     .asciz "%D = sqr %A"
Lird_f_int:     .asciz "%D = int %A"
Lird_f_rnd:     .asciz "%D = rnd"
Lird_f_ald1:    .asciz "%D = ald1 %R, %A"
Lird_f_ald2:    .asciz "%D = ald2 %R, %A, %B"
Lird_f_ast1:    .asciz "ast1 %R, %A, %B"
Lird_f_ast2:    .asciz "ast2 %R, %A, %B, %C"
Lird_f_callfn:  .asciz "%D = callfn %F, %A"
Lird_f_param:   .asciz "%D = param"
Lird_f_ret:     .asciz "ret %A"
Lird_f_jmp:     .asciz "jmp %L"
Lird_f_jcmp:    .asciz "jcmp %Q, %A, %B, %L"
Lird_f_jfor:    .asciz "jfor %A, %B, %C, %L"
Lird_f_gosub:   .asciz "gosub %L, %M"
Lird_f_return:  .asciz "return"
Lird_f_read:    .asciz "%D = read"
Lird_f_prnum:   .asciz "prnum %A"
Lird_f_prstr:   .asciz "prstr %S"
Lird_f_prcomma: .asciz "prcomma"
Lird_f_prsemi:  .asciz "prsemi"
Lird_f_prnl:    .asciz "prnl"
Lird_f_end:     .asciz "end"
Lird_f_stop:    .asciz "stop"

    .section __DATA,__const
    .p2align 3
Lird_formats:
    .quad Lird_f_nop, Lird_f_line, Lird_f_label, Lird_f_const
    .quad Lird_f_ldv, Lird_f_stv, Lird_f_add, Lird_f_sub
    .quad Lird_f_mul, Lird_f_div, Lird_f_pow, Lird_f_neg
    .quad Lird_f_sin, Lird_f_cos, Lird_f_tan, Lird_f_atn
    .quad Lird_f_exp, Lird_f_abs, Lird_f_log, Lird_f_sqr
    .quad Lird_f_int, Lird_f_rnd, Lird_f_ald1, Lird_f_ald2
    .quad Lird_f_ast1, Lird_f_ast2, Lird_f_callfn, Lird_f_param
    .quad Lird_f_ret, Lird_f_jmp, Lird_f_jcmp, Lird_f_jfor
    .quad Lird_f_gosub, Lird_f_return, Lird_f_read, Lird_f_prnum
    .quad Lird_f_prstr, Lird_f_prcomma, Lird_f_prsemi, Lird_f_prnl
    .quad Lird_f_end, Lird_f_stop
Lird_formats_end:

// the template table must have exactly one entry per opcode
.if (Lird_formats_end - Lird_formats) != (8 * OP_COUNT)
.error "ir_dump: template table does not match OP_COUNT"
.endif
