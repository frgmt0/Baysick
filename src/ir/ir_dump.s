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
//   %I            letter in IMM (the string list of `chgn2s`'s element form)
//   %S            "s<n>" string id in X    %N   IMM as unsigned decimal
//   %K            "0x" + 16 hex digits of IMM + " ; " + %.17g value
//   %Q            relation name of REL ("eq" ... "ge")
//   %a  %b        array letter in A / in B (MAT opcodes, IR.md 3.1)
//   %P            MAT PRINT mode in IMM: "zoned" or "packed"
//   %E            RESTORE variant in IMM: "all", "num" or "str"
//   %c            string temp cell in X: "%s<n>" (Fifth Edition)
// Six opcodes have a second template chosen by an operand: `matredim`
// with B = IR_NONE, `param` with IMM = 0 ("param", not "param 0"),
// `callfn` with A = IR_NONE (a call without arguments), and the element
// form (A = IR_NONE) of `sread`, `insv` and `chgn2s` (IR.md 3.2). With
// the Fifth Edition three more do: `sparam` with IMM = 0,
// `scallfn` with A = IR_NONE and `smatredim` with a column temp in B
// (a string table, IR.md 3.3).
// The dump also has the `sarray` and `sdata` lines and the three FN
// header forms (IR.md 5); the Fifth Edition adds the
// `dims=2` sarray form, the `stemps` and `file` lines and the "$" of a
// string function name and of a string parameter.
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
    // ---- string arrays A$..Z$ (used ones only): lists, Fifth Edition tables ----
    mov x21, #0
Lird_sarray_loop:
    mov x9, #IRA_SIZE
    madd x22, x21, x9, x20
    add x22, x22, #IRM_SARRAYS          // x22 = sarray entry
    ldr w9, [x22, #IRA_DIMS]
    cbz w9, Lird_sarray_next
    IRD_PUTS Lird_s_sarray
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
    // a string table (Fifth Edition) also shows b2
    ldr w9, [x22, #IRA_DIMS]
    cmp w9, #1
    b.eq 1f
    IRD_PUTS Lird_s_b2
    ldr w9, [x22, #IRA_B2]
    IRD_PUTU x9
1:
    IRD_PUTC '\n'
Lird_sarray_next:
    add x21, x21, #1
    cmp x21, #NUM_LETTERS
    b.lo Lird_sarray_loop
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
    // ---- string data: sdata d<n> "<bytes>" ----
    mov x21, #0
Lird_sdata_loop:
    ldr w9, [x20, #IRM_NSDATA]
    cmp x21, x9
    b.hs Lird_sdata_done
    ldr x10, [x20, #IRM_SDATA]
    mov x11, #IRS_SIZE
    madd x22, x21, x11, x10             // x22 = string DATA entry
    IRD_PUTS Lird_s_sdatad
    IRD_PUTU x21
    IRD_PUTS Lird_s_quote_open
    // raw bytes as stored
    mov x0, x19
    ldr x1, [x22, #IRS_PTR]
    ldr w2, [x22, #IRS_LEN]
    bl _ob_putn
    IRD_PUTS Lird_s_quote_close
    add x21, x21, #1
    b Lird_sdata_loop
Lird_sdata_done:
    // ---- stemps <n>, only if there are string temp cells ----
    ldr w9, [x20, #IRM_NSTEMPS]
    cbz w9, Lird_stemps_done
    IRD_PUTS Lird_s_stemps
    ldr w9, [x20, #IRM_NSTEMPS]
    IRD_PUTU x9
    IRD_PUTC '\n'
Lird_stemps_done:
    // ---- FILES names: file #<n> "<bytes>", n from 1 ----
    mov x21, #0
Lird_file_loop:
    ldr w9, [x20, #IRM_NFILES]
    cmp x21, x9
    b.hs Lird_files_done
    ldr x10, [x20, #IRM_FILES]
    mov x11, #IRS_SIZE
    madd x22, x21, x11, x10             // x22 = FILES entry
    IRD_PUTS Lird_s_file
    add x9, x21, #1                     // file number
    IRD_PUTU x9
    IRD_PUTS Lird_s_quote_open
    // raw bytes of the name
    mov x0, x19
    ldr x1, [x22, #IRS_PTR]
    ldr w2, [x22, #IRS_LEN]
    bl _ob_putn
    IRD_PUTS Lird_s_quote_close
    add x21, x21, #1
    b Lird_file_loop
Lird_files_done:
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
    // "func FN<letter>" + the parameter part
    IRD_PUTS Lird_s_func_fn
    add x9, x21, #('A' - FUNC_FN_BASE)
    mov x0, x19
    mov w1, w9
    bl _ob_putc
    // a string function FNx$ (FNK_STRING, IR.md 5 FNAME)
    add x9, x20, #IRM_FNKINDS
    ldr w9, [x9, x21, lsl #2]
    tst w9, #FNK_STRING
    b.eq 7f
    IRD_PUTC '$'
7:
    ldr w9, [x23, #IRF_KIND]
    cmp w9, #FUNC_KIND_FNML
    b.eq 5f
    ldr w9, [x23, #IRF_NPARAMS]
    cmp w9, #1
    b.ne 6f
    // single-line, one parameter: " param=<var>"
    IRD_PUTS Lird_s_param
    mov x0, x19
    ldr w1, [x23, #IRF_PARAM]
    bl Lird_var
    // "$" for a string parameter (bit 0 of the function's kind word)
    add x9, x20, #IRM_FNKINDS
    ldr w9, [x9, x21, lsl #2]
    tbz w9, #0, 4f
    IRD_PUTC '$'
    b 4f
5:
    // multi-line: " params=<list> def=<n> fnend=<n>"
    mov x0, x19
    mov x1, x23
    mov w2, #0
    add x9, x20, #IRM_FNKINDS
    ldr w2, [x9, x21, lsl #2]
    bl Lird_plist
    IRD_PUTS Lird_s_def
    ldr w9, [x23, #IRF_DEFLINE]
    IRD_PUTU x9
    IRD_PUTS Lird_s_fnend
    ldr w9, [x23, #IRF_ENDLINE]
    IRD_PUTU x9
    b 4f
6:
    // single-line with 0 or 2..8 parameters: " params=<list>"
    mov x0, x19
    mov x1, x23
    mov w2, #0
    add x9, x20, #IRM_FNKINDS
    ldr w2, [x9, x21, lsl #2]
    bl Lird_plist
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
    // one-argument matredim (B == IR_NONE) uses the short template
    cmp w9, #OP_MATREDIM
    b.ne 5f
    ldr w11, [x21, #IRI_B]
    cmn w11, #1                         // IR_NONE == 0xFFFFFFFF
    b.ne 5f
    IRD_ADR x22, Lird_f_matredim1
5:
    // `param` with k = 0 prints no index
    cmp w9, #OP_PARAM
    b.ne 6f
    ldr x11, [x21, #IRI_IMM]
    cbnz x11, 6f
    IRD_ADR x22, Lird_f_param0
6:
    // `callfn` without arguments (A == IR_NONE)
    cmp w9, #OP_CALLFN
    b.ne 7f
    ldr w11, [x21, #IRI_A]
    cmn w11, #1
    b.ne 7f
    IRD_ADR x22, Lird_f_callfn0
7:
    // element form of sread / insv / chgn2s (A == IR_NONE)
    ldr w11, [x21, #IRI_A]
    cmn w11, #1
    b.ne 8f
    cmp w9, #OP_SREAD
    b.ne 1f
    IRD_ADR x22, Lird_f_sread_el
    b 8f
1:
    cmp w9, #OP_INSV
    b.ne 2f
    IRD_ADR x22, Lird_f_insv_el
    b 8f
2:
    cmp w9, #OP_CHGN2S
    b.ne 8f
    IRD_ADR x22, Lird_f_chgn2s_el
8:
    // `sparam` with k = 0 prints no index
    cmp w9, #OP_SPARAM
    b.ne 1f
    ldr x11, [x21, #IRI_IMM]
    cbnz x11, 1f
    IRD_ADR x22, Lird_f_sparam0
1:
    // `scallfn` without arguments (A == IR_NONE)
    cmp w9, #OP_SCALLFN
    b.ne 2f
    ldr w11, [x21, #IRI_A]
    cmn w11, #1
    b.ne 2f
    IRD_ADR x22, Lird_f_scallfn0
2:
    // `smatredim` of a string table: the column temp in B
    cmp w9, #OP_SMATREDIM
    b.ne 3f
    ldr w11, [x21, #IRI_B]
    cmn w11, #1
    b.eq 3f
    IRD_ADR x22, Lird_f_smatredim2
3:
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
    cmp w9, #'a'
    b.eq Lird_fmt_a
    cmp w9, #'b'
    b.eq Lird_fmt_b
    cmp w9, #'P'
    b.eq Lird_fmt_P
    cmp w9, #'E'
    b.eq Lird_fmt_E
    cmp w9, #'I'
    b.eq Lird_fmt_I
    cmp w9, #'c'
    b.eq Lird_fmt_c
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
Lird_fmt_letter:
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
Lird_fmt_I:
    ldr w9, [x21, #IRI_IMM]             // low word: the letter 0..25
    b Lird_fmt_letter
Lird_fmt_a:
    ldr w9, [x21, #IRI_A]
    b Lird_fmt_letter
Lird_fmt_b:
    ldr w9, [x21, #IRI_B]
    b Lird_fmt_letter
Lird_fmt_P:
    // "zoned" for IMM == MATPR_ZONED, otherwise "packed"
    ldr x9, [x21, #IRI_IMM]
    IRD_ADR x1, Lird_s_zoned
    IRD_ADR x10, Lird_s_packed
    cmp x9, #MATPR_ZONED
    csel x1, x1, x10, eq
    mov x0, x19
    bl _ob_puts
    b Lird_fmt_loop
Lird_fmt_E:
    // RESTORE variant name; an invalid one (unverified module) as a number
    ldr x9, [x21, #IRI_IMM]
    cmp x9, #RESTORE_STR
    b.hi Lird_fmt_N
    IRD_ADR x1, Lird_restnames
    add x1, x1, x9, lsl #2              // 4-byte records "all" "num" "str"
    mov x0, x19
    bl _ob_puts
    b Lird_fmt_loop
Lird_fmt_c:
    // string temp cell "%s<n>"
    IRD_PUTC '%'
    b Lird_fmt_S
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
// Lird_plist -- print " params=" and the parameter list of a function:
// "-" without parameters, else the PARAMS slot names joined by ",", each
// followed by "$" if it is a string parameter (bit k of the kind word).
//   in:  x0 = OutBuf*, x1 = Function*, w2 = FNK_* kind word (0: all
//        parameters numeric)
//   out: none
//   clobbers: x0-x17
//   callee-saved: x19 = OutBuf*, x20 = Function*, x21 = index k,
//                 x22 = NPARAMS, x23 = kind word
//   frame: 64 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lird_plist:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]
    mov x19, x0
    mov x20, x1
    mov w23, w2
    IRD_PUTS Lird_s_params
    ldr w22, [x20, #IRF_NPARAMS]
    cbnz w22, 1f
    IRD_PUTC '-'
    b 3f
1:
    mov x21, #0
2:
    // ',' before every parameter but the first
    cbz x21, 4f
    IRD_PUTC ','
4:
    add x9, x20, x21, lsl #2
    ldr w1, [x9, #IRF_PARAMS]
    mov x0, x19
    bl Lird_var
    // string parameter k: "$"
    lsr w9, w23, w21
    tbz w9, #0, 5f
    IRD_PUTC '$'
5:
    add x21, x21, #1
    cmp x21, x22
    b.lo 2b
3:
    ldr x23, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
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
Lird_s_params:      .asciz " params="
Lird_s_def:         .asciz " def="
Lird_s_fnend:       .asciz " fnend="
Lird_s_sarray:      .asciz "sarray "
Lird_s_sdatad:      .asciz "sdata d"
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
Lird_s_zoned:       .asciz "zoned"
Lird_s_packed:      .asciz "packed"
Lird_s_stemps:      .asciz "stemps "
Lird_s_file:        .asciz "file #"

    .section __TEXT,__const
Lird_relnames:      // REL_EQ .. REL_GE, 3 bytes each
    .asciz "eq"
    .asciz "ne"
    .asciz "lt"
    .asciz "le"
    .asciz "gt"
    .asciz "ge"
Lird_restnames:     // RESTORE_ALL .. RESTORE_STR, 4 bytes each
    .asciz "all"
    .asciz "num"
    .asciz "str"

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
Lird_f_callfn0: .asciz "%D = callfn %F"
Lird_f_param:   .asciz "%D = param %N"
Lird_f_param0:  .asciz "%D = param"
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

Lird_f_matredim: .asciz "matredim %R, %A, %B"
Lird_f_matredim1: .asciz "matredim %R, %A"
Lird_f_matread:  .asciz "matread %R"
Lird_f_matprint: .asciz "matprint %R, %P"
Lird_f_matzer:   .asciz "matzer %R"
Lird_f_matcon:   .asciz "matcon %R"
Lird_f_matidn:   .asciz "matidn %R"
Lird_f_matcopy:  .asciz "matcopy %R, %a"
Lird_f_matadd:   .asciz "matadd %R, %a, %b"
Lird_f_matsub:   .asciz "matsub %R, %a, %b"
Lird_f_matmul:   .asciz "matmul %R, %a, %b"
Lird_f_matscale: .asciz "matscale %R, %A, %b"
Lird_f_mattrn:   .asciz "mattrn %R, %a"
Lird_f_matinv:   .asciz "matinv %R, %a"

Lird_f_slit:      .asciz "%D = slit %S"
Lird_f_svar:      .asciz "%D = svar %V$"
Lird_f_sald1:     .asciz "%D = sald1 %R$, %A"
Lird_f_sset:      .asciz "sset %A, %B"
Lird_f_sjcmp:     .asciz "sjcmp %Q, %A, %B, %L"
Lird_f_prsv:      .asciz "prsv %A"
Lird_f_prtab:     .asciz "prtab %A"
Lird_f_sread:     .asciz "sread %A"
Lird_f_sread_el:  .asciz "sread %R$, %B"
Lird_f_inbeg:     .asciz "inbeg"
Lird_f_innum:     .asciz "%D = innum"
Lird_f_insv:      .asciz "insv %A"
Lird_f_insv_el:   .asciz "insv %R$, %B"
Lird_f_inend:     .asciz "inend"
Lird_f_matinput:  .asciz "matinput %R"
Lird_f_smatinput: .asciz "smatinput %R$"
Lird_f_smatredim: .asciz "smatredim %R$, %A"
Lird_f_smatread:  .asciz "smatread %R$"
Lird_f_smatprint: .asciz "smatprint %R$, %P"
Lird_f_chgs2n:    .asciz "chgs2n %R, %A"
Lird_f_chgn2s:    .asciz "chgn2s %R, %A"
Lird_f_chgn2s_el: .asciz "chgn2s %R, %I$, %B"
Lird_f_onsel:     .asciz "%D = onsel %A, %N"
Lird_f_restore:   .asciz "restore %E"
Lird_f_randomize: .asciz "randomize"
Lird_f_sgn:       .asciz "%D = sgn %A"
Lird_f_cot:       .asciz "%D = cot %A"
Lird_f_num:       .asciz "%D = num"
Lird_f_det:       .asciz "%D = det"
Lird_f_fnarg:     .asciz "fnarg %N, %A"
Lird_f_stparam:   .asciz "stparam %N, %A"
Lird_f_ldfv:      .asciz "%D = ldfv"
Lird_f_stfv:      .asciz "stfv %A"

Lird_f_scell:      .asciz "%D = scell %c"
Lird_f_sstr:       .asciz "sstr %A, %B"
Lird_f_len:        .asciz "%D = len %A"
Lird_f_asc:        .asciz "%D = asc %A"
Lird_f_val:        .asciz "%D = val %A"
Lird_f_sald2:      .asciz "%D = sald2 %R$, %A, %B"
Lird_f_sparam:     .asciz "%D = sparam %N"
Lird_f_sparam0:    .asciz "%D = sparam"
Lird_f_sfv:        .asciz "%D = sfv"
Lird_f_scallfn:    .asciz "scallfn %B, %F, %A"
Lird_f_scallfn0:   .asciz "scallfn %B, %F"
Lird_f_sret:       .asciz "sret %A"
Lird_f_fsel:       .asciz "fsel %A"
Lird_f_jeof:       .asciz "jeof %A, %L"
Lird_f_scratch:    .asciz "scratch %A"
Lird_f_frestore:   .asciz "frestore %A"
Lird_f_smatredim2: .asciz "smatredim %R$, %A, %B"

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
    .quad Lird_f_matredim, Lird_f_matread, Lird_f_matprint, Lird_f_matzer
    .quad Lird_f_matcon, Lird_f_matidn, Lird_f_matcopy, Lird_f_matadd
    .quad Lird_f_matsub, Lird_f_matmul, Lird_f_matscale, Lird_f_mattrn
    .quad Lird_f_matinv
    .quad Lird_f_slit, Lird_f_svar, Lird_f_sald1, Lird_f_sset
    .quad Lird_f_sjcmp, Lird_f_prsv, Lird_f_prtab, Lird_f_sread
    .quad Lird_f_inbeg, Lird_f_innum, Lird_f_insv, Lird_f_inend
    .quad Lird_f_matinput, Lird_f_smatinput, Lird_f_smatredim, Lird_f_smatread
    .quad Lird_f_smatprint, Lird_f_chgs2n, Lird_f_chgn2s, Lird_f_onsel
    .quad Lird_f_restore, Lird_f_randomize, Lird_f_sgn, Lird_f_cot
    .quad Lird_f_num, Lird_f_det, Lird_f_fnarg, Lird_f_stparam
    .quad Lird_f_ldfv, Lird_f_stfv
    // Fifth Edition opcodes (IR.md 3.3)
    .quad Lird_f_scell, Lird_f_sstr, Lird_f_len, Lird_f_asc
    .quad Lird_f_val, Lird_f_sald2, Lird_f_sparam, Lird_f_sfv
    .quad Lird_f_scallfn, Lird_f_sret, Lird_f_fsel, Lird_f_jeof
    .quad Lird_f_scratch, Lird_f_frestore
Lird_formats_end:

// the template table must have exactly one entry per opcode
.if (Lird_formats_end - Lird_formats) != (8 * OP_COUNT)
.error "ir_dump: template table does not match OP_COUNT"
.endif
