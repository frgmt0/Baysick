// =====================================================================
// src/ir/ir_verify.s -- IR verifier (docs/IR.md section 6).
//
//   _ir_verify(x0=Module*) -> x0 = 0 if valid, else a pointer to a
//                             NUL-terminated reason (static buffer,
//                             overwritten by the next failing call)
//
// Checks, in order: module header (NSLOTS, reserved field, table
// pointers), the array table and the string-list table, the record fields of every present function (main must exist:
// kind, letter, parameter list, DEF / FNEND lines), then per function:
// last instruction, label definitions (pass 1), each instruction (pass 2): opcode
// range, placement for the function kind, the `fnarg` rule, temp operands
// (defined earlier, each temp written once, of the kind the field
// requires: number or sref), REL, IMM and X per the opcode's field usage
// (the element form of `sread` / `insv` / `chgn2s`, A = IR_NONE, has its
// own field usage, Lirv_spec_el_*).
// The reason names the function and instruction index when it has one.
// =====================================================================
.include "baysick.inc"

// ---- per-opcode field usage (Lirv_spec: 4 bytes per opcode) ----------
// byte 0: temp operands used: bit0 DST, bit1 A, bit2 B, bit3 C;
//         temp kinds: bit4 DST is an sref, bit5 A is an sref, bit6 B is
//         an sref (clear: a number); bit7 A may be IR_NONE (callfn)
.equ Lirv_T_D,      1
.equ Lirv_T_A,      2
.equ Lirv_T_B,      4
.equ Lirv_T_C,      8
.equ Lirv_S_D,      0x10
.equ Lirv_S_A,      0x20
.equ Lirv_S_B,      0x40
.equ Lirv_T_AOPT,   0x80
// byte 1: meaning of X (low nibble)
.equ Lirv_X_NONE,   0
.equ Lirv_X_SLOT,   1
.equ Lirv_X_LDEF,   2           // label defined by this instruction
.equ Lirv_X_LREF,   3           // label referenced
.equ Lirv_X_ARR1,   4           // numeric list (DIMS = 1)
.equ Lirv_X_ARR2,   5           // numeric table (DIMS = 2)
.equ Lirv_X_FN,     6
.equ Lirv_X_STR,    7
.equ Lirv_X_ARRM,   8           // MAT target: array with either dimensionality
.equ Lirv_X_SSLOT,  9           // string variable slot 0..285
.equ Lirv_X_SLIST,  10          // string list letter (sarray DIMS = 1)
// flags above the low nibble of byte 1 (the X kind), MAT field kinds, IR.md 3.1
.equ Lirv_XF_AARR,  0x10        // IRI_A holds an array letter, not a temp
.equ Lirv_XF_BARR,  0x20        // IRI_B holds an array letter, not a temp
.equ Lirv_XF_BOPT,  0x40        // IRI_B is a temp or IR_NONE (matredim)
// byte 2: meaning of IMM (low nibble), flags in the high nibble
.equ Lirv_I_ZERO,   0
.equ Lirv_I_ANY,    1           // any bits (const; fnarg: the fnarg rule checks it)
.equ Lirv_I_LINE,   2
.equ Lirv_I_LREF,   3
.equ Lirv_I_MODE,   4           // MATPR_ZONED or MATPR_PACKED
.equ Lirv_I_RESTORE, 5          // RESTORE_ALL .. RESTORE_STR
.equ Lirv_I_COUNT,  6           // >= 1 (onsel)
.equ Lirv_I_PARAM,  7           // < NPARAMS of the function (param, stparam)
.equ Lirv_I_SLIST,  8           // string list letter (sarray DIMS = 1): chgn2s element form
.equ Lirv_I_REL,    0x10        // REL holds a relation code
.equ Lirv_I_ADEST,  0x20        // the A sref is written: never a slit
// byte 3: placement, the set of function kinds that may contain the opcode
// (bit FUNC_KIND_*), IR.md 3 placement table
.equ Lirv_P_MAIN,   (1 << FUNC_KIND_MAIN)
.equ Lirv_P_FN,     (1 << FUNC_KIND_FN) | (1 << FUNC_KIND_FNML)
.equ Lirv_P_FNML,   (1 << FUNC_KIND_FNML)
.equ Lirv_P_STMT,   (1 << FUNC_KIND_MAIN) | (1 << FUNC_KIND_FNML)
.equ Lirv_P_ANY,    Lirv_P_STMT | Lirv_P_FN
// temp-kind bytes (x22 array): 0 = not yet defined
.equ Lirv_K_NUM,    1           // a number
.equ Lirv_K_SREF,   2           // sref to a variable or list element (svar, sald1)
.equ Lirv_K_SLIT,   3           // sref to a string constant (slit)
.equ Lirv_MSGBUF_SIZE, 192      // failure reason buffer
// frame slot of the number of `fnarg` instructions waiting for their callfn
.equ Lirv_FR_FNARGS, 96

.macro SPEC temps, x, imm, place
    .byte \temps, \x, \imm, \place
.endm

    .section __TEXT,__text,regular,pure_instructions

.macro IRV_ADR reg, sym
    adrp \reg, \sym@PAGE
    add \reg, \reg, \sym@PAGEOFF
.endm

// Fail with reason \msg for the current instruction / function / module.
.macro FAIL_I msg
    IRV_ADR x0, \msg
    b Lirv_fail_insn
.endm
.macro FAIL_F msg
    IRV_ADR x0, \msg
    b Lirv_fail_func
.endm
.macro FAIL_M msg
    IRV_ADR x0, \msg
    b Lirv_fail_module
.endm

// Check that the u32 in \reg names a declared array (letter < 26, DIMS != 0,
// either dimensionality, IR.md 6 rule 4). Clobbers w11, w12.
.macro CHK_ARR reg
    cmp \reg, #NUM_LETTERS
    b.hs Lirv_e_array
    mov w11, #IRA_SIZE
    umaddl x11, \reg, w11, x19
    ldr w11, [x11, #(IRM_ARRAYS + IRA_DIMS)]
    cbz w11, Lirv_e_array
.endm

// Check the temp operand at record offset \off, used if bit \bit of the
// spec's temp mask (w26) is set: then it must be < NTEMPS, already
// defined, and an sref if bit \sbit of w26 is set, else a number
// (\sbit < 0: always a number); otherwise the field must be IR_NONE.
// Leaves the field in w9.
// Clobbers w9-w11.
.macro CHK_USE off, bit, sbit
    ldr w9, [x27, #\off]
    tbz w26, #\bit, 1f
    ldr w10, [x21, #IRF_NTEMPS]
    cmp w9, w10
    b.hs Lirv_e_temp_range
    ldrb w10, [x22, x9]
    cbz w10, Lirv_e_temp_undef
    cmp w10, #Lirv_K_NUM
.if \sbit >= 0
    // 1 if the temp is an sref (svar / sald1 / slit), 0 for a number
    cset w10, ne
    ubfx w11, w26, #\sbit, #1
    cmp w10, w11
.endif
    b.ne Lirv_e_temp_kind
    b 2f
1:
    cmn w9, #1                          // IR_NONE == 0xFFFFFFFF
    b.ne Lirv_e_unused
2:
.endm

// ---------------------------------------------------------------------
// _ir_verify -- check a module against docs/IR.md section 6.
//   in:  x0 = Module*
//   out: x0 = 0 if valid, else reason string
//   clobbers: x0-x17
//   callee-saved: x19 = Module*, x20 = function index, x21 = Function*,
//                 x22 = temp-kind bytes, x23 = label-defined bytes,
//                 x24 = instruction cursor, x25 = instruction index,
//                 x26 = spec word of the current opcode,
//                 x27 = current record, x28 = instruction count
//   frame: 112 bytes (+32 while formatting a failure); [sp, #96] holds
//          the number of pending `fnarg` instructions
// ---------------------------------------------------------------------
    .globl _ir_verify
    .p2align 2
_ir_verify:
    stp x29, x30, [sp, #-112]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    mov x19, x0
    // ---- module header ----
    ldr w9, [x19, #IRM_NFORS]
    ldr w10, [x19, #IRM_NSLOTS]
    mov x11, #SLOT_FOR_BASE
    add x11, x11, x9, lsl #1            // 64-bit: cannot wrap
    cmp x10, x11
    b.ne Lirv_e_nslots
    ldr x9, [x19, #IRM_RESERVED]
    cbnz x9, Lirv_e_mreserved
    ldr w9, [x19, #IRM_NSTRINGS]
    cbz w9, 1f
    ldr x10, [x19, #IRM_STRINGS]
    cbz x10, Lirv_e_nostrings
1:
    ldr w9, [x19, #IRM_NDATA]
    cbz w9, 2f
    ldr x10, [x19, #IRM_DATA]
    cbz x10, Lirv_e_nodata
2:
    ldr w9, [x19, #IRM_NSDATA]
    cbz w9, 3f
    ldr x10, [x19, #IRM_SDATA]
    cbz x10, Lirv_e_nosdata
3:
    // ---- arrays: dims 0..2, (B1+1)*(B2+1) <= LIM_ARRAY_ELEMS ----
    add x9, x19, #IRM_ARRAYS
    mov x10, #NUM_LETTERS
    movz x14, #(LIM_ARRAY_ELEMS & 0xFFFF)
    movk x14, #(LIM_ARRAY_ELEMS >> 16), lsl #16
Lirv_array_loop:
    ldr w11, [x9, #IRA_DIMS]
    cbz w11, Lirv_array_next
    cmp w11, #2
    b.hi Lirv_e_dims
    ldr w12, [x9, #IRA_B1]
    ldr w13, [x9, #IRA_B2]
    // bound each factor first so the product cannot overflow
    cmp x12, x14
    b.hs Lirv_e_arrsize
    cmp x13, x14
    b.hs Lirv_e_arrsize
    add x12, x12, #1
    add x13, x13, #1
    mul x12, x12, x13
    cmp x12, x14
    b.hi Lirv_e_arrsize
Lirv_array_next:
    add x9, x9, #IRA_SIZE
    subs x10, x10, #1
    b.ne Lirv_array_loop
    // ---- string lists: dims 0 / 1, B2 = 0, B1+1 <= LIM_ARRAY_ELEMS ----
    add x9, x19, #IRM_SARRAYS
    mov x10, #NUM_LETTERS
Lirv_sarray_loop:
    ldr w11, [x9, #IRA_DIMS]
    cbz w11, Lirv_sarray_next
    cmp w11, #1
    b.ne Lirv_e_sdims
    ldr w12, [x9, #IRA_B2]
    cbnz w12, Lirv_e_sdims
    ldr w12, [x9, #IRA_B1]
    cmp x12, x14                        // B1 + 1 <= limit  <=>  B1 < limit
    b.hs Lirv_e_sarrsize
Lirv_sarray_next:
    add x9, x9, #IRA_SIZE
    subs x10, x10, #1
    b.ne Lirv_sarray_loop
    // ---- main must exist ----
    ldr w9, [x19, #(IRM_FUNCS + IRF_PRESENT)]
    cbz w9, Lirv_e_nomain

    // ====== function records (all first: callfn reads the callee's) ======
    mov x20, #0
Lirv_rec_loop:
    mov x9, #IRF_SIZE
    madd x21, x20, x9, x19
    add x21, x21, #IRM_FUNCS
    ldr w9, [x21, #IRF_PRESENT]
    cbz w9, Lirv_rec_next
    cmp w9, #1
    b.ne Lirv_e_present
    // record fields of main / FN functions
    ldr w9, [x21, #IRF_KIND]
    ldr w10, [x21, #IRF_FNIDX]
    ldr w11, [x21, #IRF_PARAM]
    cbnz x20, 3f
    // main: kind MAIN, letter 0, no parameter, no DEF / FNEND line
    cmp w9, #FUNC_KIND_MAIN
    b.ne Lirv_e_kind
    cbnz w10, Lirv_e_fnidx
    cmn w11, #1
    b.ne Lirv_e_mainparam
    ldr w12, [x21, #IRF_DEFLINE]
    cbnz w12, Lirv_e_maindef
    ldr w12, [x21, #IRF_NPARAMS]
    cbnz w12, Lirv_e_mainparam
    ldr w12, [x21, #IRF_ENDLINE]
    cbnz w12, Lirv_e_endline
    b 4f
3:
    // FN function at index 1+L: letter L
    sub x12, x20, #FUNC_FN_BASE
    cmp x10, x12
    b.ne Lirv_e_fnidx
    // single-line: ENDLINE 0; multi-line: ENDLINE > DEFLINE
    ldr w12, [x21, #IRF_ENDLINE]
    cmp w9, #FUNC_KIND_FN
    b.ne 44f
    cbnz w12, Lirv_e_endline
    b 4f
44:
    cmp w9, #FUNC_KIND_FNML
    b.ne Lirv_e_kind
    ldr w13, [x21, #IRF_DEFLINE]
    cmp w12, w13
    b.ls Lirv_e_endline
4:
    // parameter list: NPARAMS <= 8; PARAMS[k] a scalar slot for k < NPARAMS,
    // IR_NONE after; PARAM (w11) = PARAMS[0]
    ldr w12, [x21, #IRF_NPARAMS]
    cmp w12, #LIM_FN_PARAMS
    b.hi Lirv_e_nparams
    mov x13, #0
41:
    add x14, x21, x13, lsl #2
    ldr w14, [x14, #IRF_PARAMS]
    cmp x13, x12
    b.hs 42f
    cmp w14, #NUM_SCALAR_SLOTS
    b.hs Lirv_e_param
    b 43f
42:
    cmn w14, #1
    b.ne Lirv_e_param
43:
    add x13, x13, #1
    cmp x13, #LIM_FN_PARAMS
    b.lo 41b
    ldr w14, [x21, #IRF_PARAMS]
    cmp w11, w14
    b.ne Lirv_e_param0
Lirv_rec_next:
    add x20, x20, #1
    cmp x20, #NUM_FUNCS
    b.lo Lirv_rec_loop

    // ================= per function: instructions =================
    mov x20, #0
Lirv_func_loop:
    mov x9, #IRF_SIZE
    madd x21, x20, x9, x19
    add x21, x21, #IRM_FUNCS
    ldr w9, [x21, #IRF_PRESENT]
    cbz w9, Lirv_func_next
    // at least one instruction; main ends with end, FN functions with ret
    ldr w28, [x21, #IRF_NINSNS]
    cbz w28, Lirv_e_empty
    ldr x24, [x21, #IRF_INSNS]
    cbz x24, Lirv_e_empty
    sub x9, x28, #1
    add x9, x24, x9, lsl #IRI_SHIFT
    ldrh w9, [x9, #IRI_OP]
    mov w10, #OP_END
    mov w11, #OP_RET
    cmp x20, #0
    csel w10, w10, w11, eq
    cmp w9, w10
    b.ne Lirv_e_lastop
    ldr w9, [x21, #IRF_NLABELS]
    cbz w9, 5f
    ldr x10, [x21, #IRF_LABELS]
    cbz x10, Lirv_e_nolabels
5:
    // kinds of temps and defined-flags of labels (zeroed arena memory)
    ldr w0, [x21, #IRF_NTEMPS]
    bl _drv_alloc
    mov x22, x0
    ldr w0, [x21, #IRF_NLABELS]
    bl _drv_alloc
    mov x23, x0

    // ---- pass 1: label definitions ----
    mov x25, #0
Lirv_p1_loop:
    cmp x25, x28
    b.hs Lirv_p1_done
    add x27, x24, x25, lsl #IRI_SHIFT
    ldrh w9, [x27, #IRI_OP]
    cmp w9, #OP_LINE
    b.eq 6f
    cmp w9, #OP_LABEL
    b.ne Lirv_p1_next
6:
    // X < NLABELS and not defined before
    ldr w10, [x27, #IRI_X]
    ldr w11, [x21, #IRF_NLABELS]
    cmp w10, w11
    b.hs Lirv_e_label_range
    ldrb w11, [x23, x10]
    cbnz w11, Lirv_e_label_twice
    mov w11, #1
    strb w11, [x23, x10]
    // LABELS[X] must be the line number for `line`, 0 for `label`
    ldr x11, [x21, #IRF_LABELS]
    ldr w11, [x11, x10, lsl #2]
    ldr x12, [x27, #IRI_IMM]
    cmp w9, #OP_LINE
    b.eq 7f
    cbnz w11, Lirv_e_label_kind
    b Lirv_p1_next
7:
    cmp x11, x12
    b.ne Lirv_e_label_kind
Lirv_p1_next:
    add x25, x25, #1
    b Lirv_p1_loop
Lirv_p1_done:
    // every label id is defined
    ldr w9, [x21, #IRF_NLABELS]
    mov x10, #0
8:
    cmp x10, x9
    b.hs 9f
    ldrb w11, [x23, x10]
    add x10, x10, #1
    cbnz w11, 8b
    b Lirv_e_label_undef
9:

    // ---- pass 2: every instruction ----
    str xzr, [sp, #Lirv_FR_FNARGS]      // no fnarg pending
    mov x25, #0
Lirv_p2_loop:
    cmp x25, x28
    b.hs Lirv_func_next
    add x27, x24, x25, lsl #IRI_SHIFT
    ldrh w9, [x27, #IRI_OP]
    cmp w9, #OP_COUNT
    b.hs Lirv_e_opcode
    IRV_ADR x10, Lirv_spec
    ldr w26, [x10, x9, lsl #2]
    // element form of sread / insv / chgn2s (A = IR_NONE, IR.md 3.2):
    // B = subscript temp, the string list letter in X (sread, insv) or
    // in IMM (chgn2s)
    ldr w10, [x27, #IRI_A]
    cmn w10, #1
    b.ne 61f
    cmp w9, #OP_CHGN2S
    b.eq 62f
    cmp w9, #OP_SREAD
    b.eq 60f
    cmp w9, #OP_INSV
    b.ne 61f
60:
    IRV_ADR x10, Lirv_spec_el_s
    ldr w26, [x10]
    b 61f
62:
    IRV_ADR x10, Lirv_spec_el_c
    ldr w26, [x10]
61:
    // placement (byte 3): bit KIND of the function must be set
    lsr w10, w26, #24
    ldr w11, [x21, #IRF_KIND]
    lsr w10, w10, w11
    tbz w10, #0, Lirv_e_place
    // fnarg rule (IR.md 3.2): fnarg 1, 2, ... immediately before a callfn
    ldr x13, [sp, #Lirv_FR_FNARGS]
    cmp w9, #OP_FNARG
    b.eq 50f
    cmp w9, #OP_CALLFN
    b.eq 11f                            // the count is checked with X
    cbnz x13, Lirv_e_fnarg_seq
    b 11f
50:
    // IMM must be the next argument number, at most LIM_FN_PARAMS - 1
    ldr x10, [x27, #IRI_IMM]
    add x13, x13, #1
    cmp x10, x13
    b.ne Lirv_e_fnarg_num
    cmp x13, #(LIM_FN_PARAMS - 1)
    b.hi Lirv_e_fnarg_num
    str x13, [sp, #Lirv_FR_FNARGS]
11:
    // temp operands: read operands first, then the destination
    // MAT opcodes: A / B may hold array letters (or an optional temp in B)
    ubfx w10, w26, #8, #8
    tbz w10, #4, 30f
    ldr w9, [x27, #IRI_A]
    CHK_ARR w9
    b 31f
30:
    // callfn without arguments: A = IR_NONE
    tbz w26, #7, 35f
    ldr w9, [x27, #IRI_A]
    cmn w9, #1
    b.eq 31f
35:
    CHK_USE IRI_A, 1, 5
    // a written sref (sset / sread / insv / chgn2s) never names a constant
    ubfx w11, w26, #16, #8
    tbz w11, #5, 31f
    ldrb w10, [x22, x9]
    cmp w10, #Lirv_K_SLIT
    b.eq Lirv_e_slitdest
31:
    ubfx w10, w26, #8, #8
    tbz w10, #5, 32f
    ldr w9, [x27, #IRI_B]
    CHK_ARR w9
    b 34f
32:
    tbz w10, #6, 33f
    ldr w9, [x27, #IRI_B]
    cmn w9, #1                          // matredim: B may be IR_NONE
    b.eq 34f
33:
    CHK_USE IRI_B, 2, 6
34:
    // C is always a number (jfor, ast2)
    CHK_USE IRI_C, 3, -1
    ldr w9, [x27, #IRI_DST]
    tbz w26, #0, 12f
    ldr w10, [x21, #IRF_NTEMPS]
    cmp w9, w10
    b.hs Lirv_e_temp_range
    ldrb w10, [x22, x9]
    cbnz w10, Lirv_e_temp_twice
    // kind of the new temp: slit, other sref, or number
    mov w10, #Lirv_K_NUM
    tbz w26, #4, 36f
    ldrh w11, [x27, #IRI_OP]
    mov w10, #Lirv_K_SREF
    mov w12, #Lirv_K_SLIT
    cmp w11, #OP_SLIT
    csel w10, w12, w10, eq
36:
    strb w10, [x22, x9]
    b 13f
12:
    cmn w9, #1
    b.ne Lirv_e_unused
13:
    // relation (jcmp, sjcmp)
    ldrh w9, [x27, #IRI_REL]
    ubfx w10, w26, #16, #8
    tbz w10, #4, 14f
    sub w11, w9, #REL_EQ
    cmp w11, #(REL_GE - REL_EQ)
    b.hi Lirv_e_rel
    b 15f
14:
    cbnz w9, Lirv_e_unused
15:
    // IMM (byte 2, low nibble)
    and w10, w10, #0xF
    ldr x9, [x27, #IRI_IMM]
    cmp w10, #Lirv_I_ZERO
    b.ne 16f
    cbnz x9, Lirv_e_unused
    b Lirv_imm_done
16:
    cmp w10, #Lirv_I_LINE
    b.ne 17f
    cbz x9, Lirv_e_line
    movz x11, #(LIM_LINE_NUMBER & 0xFFFF)
    movk x11, #(LIM_LINE_NUMBER >> 16), lsl #16
    cmp x9, x11
    b.hi Lirv_e_line
    b Lirv_imm_done
17:
    cmp w10, #Lirv_I_LREF
    b.ne 24f
    ldr w11, [x21, #IRF_NLABELS]
    cmp x9, x11
    b.hs Lirv_e_label_range
    b Lirv_imm_done
24:
    cmp w10, #Lirv_I_MODE
    b.ne 26f
    cmp x9, #MATPR_PACKED
    b.hi Lirv_e_matmode
    b Lirv_imm_done
26:
    cmp w10, #Lirv_I_RESTORE
    b.ne 27f
    cmp x9, #RESTORE_STR
    b.hi Lirv_e_restore
    b Lirv_imm_done
27:
    cmp w10, #Lirv_I_COUNT
    b.ne 28f
    cbz x9, Lirv_e_onsel
    b Lirv_imm_done
28:
    cmp w10, #Lirv_I_SLIST
    b.ne 29f
    // a string list letter in range and declared (sarray DIMS = 1)
    cmp x9, #NUM_LETTERS
    b.hs Lirv_e_slist
    mov w11, #IRA_SIZE
    umaddl x11, w9, w11, x19
    ldr w11, [x11, #(IRM_SARRAYS + IRA_DIMS)]
    cmp w11, #1
    b.ne Lirv_e_slist
    b Lirv_imm_done
29:
    cmp w10, #Lirv_I_PARAM
    b.ne Lirv_imm_done                  // Lirv_I_ANY: any bits
    ldr w11, [x21, #IRF_NPARAMS]
    cmp x9, x11
    b.hs Lirv_e_paramidx
Lirv_imm_done:
    // X (byte 1)
    ubfx w10, w26, #8, #4
    ldr w9, [x27, #IRI_X]
    cmp w10, #Lirv_X_NONE
    b.ne 18f
    cmn w9, #1
    b.ne Lirv_e_unused
    b Lirv_p2_next
18:
    cmp w10, #Lirv_X_SLOT
    b.ne 19f
    ldr w11, [x19, #IRM_NSLOTS]
    cmp w9, w11
    b.hs Lirv_e_slot
    b Lirv_p2_next
19:
    cmp w10, #Lirv_X_LDEF
    b.eq Lirv_p2_next                   // checked in pass 1
    cmp w10, #Lirv_X_LREF
    b.ne 20f
    ldr w11, [x21, #IRF_NLABELS]
    cmp w9, w11
    b.hs Lirv_e_label_range
    b Lirv_p2_next
20:
    cmp w10, #Lirv_X_ARR1
    b.eq 21f
    cmp w10, #Lirv_X_ARR2
    b.ne 22f
21:
    // array letter in range, used, with this dimensionality
    cmp w9, #NUM_LETTERS
    b.hs Lirv_e_array
    mov w11, #IRA_SIZE
    umaddl x11, w9, w11, x19
    ldr w11, [x11, #(IRM_ARRAYS + IRA_DIMS)]
    sub w12, w10, #(Lirv_X_ARR1 - 1)    // 1 for lists, 2 for tables
    cmp w11, w12
    b.ne Lirv_e_array
    b Lirv_p2_next
22:
    cmp w10, #Lirv_X_ARRM
    b.ne 25f
    CHK_ARR w9
    b Lirv_p2_next
25:
    cmp w10, #Lirv_X_FN
    b.ne 23f
    // callfn target: a present FN function
    cmp w9, #NUM_LETTERS
    b.hs Lirv_e_callfn
    add w11, w9, #FUNC_FN_BASE
    mov w12, #IRF_SIZE
    umaddl x11, w11, w12, x19
    add x11, x11, #IRM_FUNCS            // x11 = callee
    ldr w12, [x11, #IRF_PRESENT]
    cbz w12, Lirv_e_callfn
    // arguments: none if A = IR_NONE (then no fnarg), else 1 + fnargs
    ldr x13, [sp, #Lirv_FR_FNARGS]
    str xzr, [sp, #Lirv_FR_FNARGS]
    ldr w12, [x27, #IRI_A]
    cmn w12, #1
    b.ne 29f
    cbnz x13, Lirv_e_argcount
    b 37f
29:
    add x13, x13, #1
37:
    ldr w12, [x11, #IRF_NPARAMS]
    cmp x13, x12
    b.ne Lirv_e_argcount
    b Lirv_p2_next
23:
    cmp w10, #Lirv_X_SSLOT
    b.ne 38f
    // string variable slot
    cmp w9, #NUM_STRING_SLOTS
    b.hs Lirv_e_sslot
    b Lirv_p2_next
38:
    cmp w10, #Lirv_X_SLIST
    b.ne 39f
    // string list letter in range and declared (sarray DIMS = 1)
    cmp w9, #NUM_LETTERS
    b.hs Lirv_e_slist
    mov w11, #IRA_SIZE
    umaddl x11, w9, w11, x19
    ldr w11, [x11, #(IRM_SARRAYS + IRA_DIMS)]
    cmp w11, #1
    b.ne Lirv_e_slist
    b Lirv_p2_next
39:
    // Lirv_X_STR: string id < NSTRINGS
    ldr w11, [x19, #IRM_NSTRINGS]
    cmp w9, w11
    b.hs Lirv_e_string
Lirv_p2_next:
    add x25, x25, #1
    b Lirv_p2_loop

Lirv_func_next:
    add x20, x20, #1
    cmp x20, #NUM_FUNCS
    b.lo Lirv_func_loop
    mov x0, #0                          // valid
    b Lirv_return

// ---- instruction-level failures ----
Lirv_e_temp_range:  FAIL_I Lirv_m_temp_range
Lirv_e_temp_undef:  FAIL_I Lirv_m_temp_undef
Lirv_e_temp_twice:  FAIL_I Lirv_m_temp_twice
Lirv_e_temp_kind:   FAIL_I Lirv_m_temp_kind
Lirv_e_slitdest:    FAIL_I Lirv_m_slitdest
Lirv_e_unused:      FAIL_I Lirv_m_unused
Lirv_e_opcode:      FAIL_I Lirv_m_opcode
Lirv_e_place:       FAIL_I Lirv_m_place
Lirv_e_rel:         FAIL_I Lirv_m_rel
Lirv_e_line:        FAIL_I Lirv_m_line
Lirv_e_slot:        FAIL_I Lirv_m_slot
Lirv_e_array:       FAIL_I Lirv_m_array
Lirv_e_matmode:     FAIL_I Lirv_m_matmode
Lirv_e_callfn:      FAIL_I Lirv_m_callfn
Lirv_e_string:      FAIL_I Lirv_m_string
Lirv_e_label_range: FAIL_I Lirv_m_label_range
Lirv_e_label_twice: FAIL_I Lirv_m_label_twice
Lirv_e_label_kind:  FAIL_I Lirv_m_label_kind
Lirv_e_fnarg_seq:   FAIL_I Lirv_m_fnarg_seq
Lirv_e_fnarg_num:   FAIL_I Lirv_m_fnarg_num
Lirv_e_argcount:    FAIL_I Lirv_m_argcount
Lirv_e_restore:     FAIL_I Lirv_m_restore
Lirv_e_onsel:       FAIL_I Lirv_m_onsel
Lirv_e_paramidx:    FAIL_I Lirv_m_paramidx
Lirv_e_sslot:       FAIL_I Lirv_m_sslot
Lirv_e_slist:       FAIL_I Lirv_m_slist
// ---- function-level failures ----
Lirv_e_present:     FAIL_F Lirv_m_present
Lirv_e_kind:        FAIL_F Lirv_m_kind
Lirv_e_fnidx:       FAIL_F Lirv_m_fnidx
Lirv_e_mainparam:   FAIL_F Lirv_m_mainparam
Lirv_e_maindef:     FAIL_F Lirv_m_maindef
Lirv_e_param:       FAIL_F Lirv_m_param
Lirv_e_empty:       FAIL_F Lirv_m_empty
Lirv_e_lastop:      FAIL_F Lirv_m_lastop
Lirv_e_nolabels:    FAIL_F Lirv_m_nolabels
Lirv_e_label_undef: FAIL_F Lirv_m_label_undef
Lirv_e_endline:     FAIL_F Lirv_m_endline
Lirv_e_nparams:     FAIL_F Lirv_m_nparams
Lirv_e_param0:      FAIL_F Lirv_m_param0
// ---- module-level failures ----
Lirv_e_nslots:      FAIL_M Lirv_m_nslots
Lirv_e_mreserved:   FAIL_M Lirv_m_mreserved
Lirv_e_nostrings:   FAIL_M Lirv_m_nostrings
Lirv_e_nodata:      FAIL_M Lirv_m_nodata
Lirv_e_dims:        FAIL_M Lirv_m_dims
Lirv_e_arrsize:     FAIL_M Lirv_m_arrsize
Lirv_e_nomain:      FAIL_M Lirv_m_nomain
Lirv_e_nosdata:     FAIL_M Lirv_m_nosdata
Lirv_e_sdims:       FAIL_M Lirv_m_sdims
Lirv_e_sarrsize:    FAIL_M Lirv_m_sarrsize

Lirv_fail_insn:
    // "<reason> (in <func>, instruction <n>)"
    mov x9, x0
    bl Lirv_funcname
    sub sp, sp, #32
    stp x9, x0, [sp]                    // variadic: reason, function name
    str x25, [sp, #16]                  // instruction index
    IRV_ADR x2, Lirv_fmt_insn
    b Lirv_fail_format
Lirv_fail_func:
    // "<reason> (in <func>)"
    mov x9, x0
    bl Lirv_funcname
    sub sp, sp, #32
    stp x9, x0, [sp]
    IRV_ADR x2, Lirv_fmt_func
    b Lirv_fail_format
Lirv_fail_module:
    // "<reason>"
    sub sp, sp, #32
    str x0, [sp]
    IRV_ADR x2, Lirv_fmt_module
Lirv_fail_format:
    IRV_ADR x0, Lirv_msgbuf
    mov x1, #Lirv_MSGBUF_SIZE
    bl _snprintf
    add sp, sp, #32
    IRV_ADR x0, Lirv_msgbuf
Lirv_return:
    ldp x27, x28, [sp, #80]
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #112
    ret

// ---------------------------------------------------------------------
// Lirv_funcname -- name of function index x20 ("main" or "FN<L>").
//   Private convention: in x20 = function index; out x0 = name (static);
//   clobbers x0, x10, x11 only (x9 is preserved for the caller). Leaf.
// ---------------------------------------------------------------------
    .p2align 2
Lirv_funcname:
    cbnz x20, 1f
    IRV_ADR x0, Lirv_s_main
    ret
1:
    // "FN" + letter, in a static buffer
    IRV_ADR x0, Lirv_fnname
    mov w10, #'F'
    strb w10, [x0]
    mov w10, #'N'
    strb w10, [x0, #1]
    add w10, w20, #('A' - FUNC_FN_BASE)
    strb w10, [x0, #2]
    strb wzr, [x0, #3]
    ret

    .section __TEXT,__const
// field usage per opcode, docs/IR.md section 3 (temps, X, IMM|REL, placement):
// E opcodes Lirv_P_ANY, S and T opcodes Lirv_P_STMT (main and multi-line
// FN), gosub / return / end Lirv_P_MAIN, param / ret Lirv_P_FN,
// stparam / ldfv / stfv Lirv_P_FNML
    .p2align 2
Lirv_spec:
    SPEC 0, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_ANY                       // nop
    SPEC 0, Lirv_X_LDEF, Lirv_I_LINE, Lirv_P_STMT                      // line
    SPEC 0, Lirv_X_LDEF, Lirv_I_ZERO, Lirv_P_STMT                      // label
    SPEC Lirv_T_D, Lirv_X_NONE, Lirv_I_ANY, Lirv_P_ANY                 // const
    SPEC Lirv_T_D, Lirv_X_SLOT, Lirv_I_ZERO, Lirv_P_ANY                // ldv
    SPEC Lirv_T_A, Lirv_X_SLOT, Lirv_I_ZERO, Lirv_P_STMT               // stv
    SPEC Lirv_T_D|Lirv_T_A|Lirv_T_B, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_ANY  // add
    SPEC Lirv_T_D|Lirv_T_A|Lirv_T_B, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_ANY  // sub
    SPEC Lirv_T_D|Lirv_T_A|Lirv_T_B, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_ANY  // mul
    SPEC Lirv_T_D|Lirv_T_A|Lirv_T_B, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_ANY  // div
    SPEC Lirv_T_D|Lirv_T_A|Lirv_T_B, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_ANY  // pow
    SPEC Lirv_T_D|Lirv_T_A, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_ANY       // neg
    SPEC Lirv_T_D|Lirv_T_A, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_ANY       // sin
    SPEC Lirv_T_D|Lirv_T_A, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_ANY       // cos
    SPEC Lirv_T_D|Lirv_T_A, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_ANY       // tan
    SPEC Lirv_T_D|Lirv_T_A, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_ANY       // atn
    SPEC Lirv_T_D|Lirv_T_A, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_ANY       // exp
    SPEC Lirv_T_D|Lirv_T_A, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_ANY       // abs
    SPEC Lirv_T_D|Lirv_T_A, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_ANY       // log
    SPEC Lirv_T_D|Lirv_T_A, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_ANY       // sqr
    SPEC Lirv_T_D|Lirv_T_A, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_ANY       // int
    SPEC Lirv_T_D, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_ANY                // rnd
    SPEC Lirv_T_D|Lirv_T_A, Lirv_X_ARR1, Lirv_I_ZERO, Lirv_P_ANY       // ald1
    SPEC Lirv_T_D|Lirv_T_A|Lirv_T_B, Lirv_X_ARR2, Lirv_I_ZERO, Lirv_P_ANY  // ald2
    SPEC Lirv_T_A|Lirv_T_B, Lirv_X_ARR1, Lirv_I_ZERO, Lirv_P_STMT      // ast1
    SPEC Lirv_T_A|Lirv_T_B|Lirv_T_C, Lirv_X_ARR2, Lirv_I_ZERO, Lirv_P_STMT  // ast2
    SPEC Lirv_T_D|Lirv_T_A|Lirv_T_AOPT, Lirv_X_FN, Lirv_I_ZERO, Lirv_P_ANY  // callfn
    SPEC Lirv_T_D, Lirv_X_NONE, Lirv_I_PARAM, Lirv_P_FN                // param
    SPEC Lirv_T_A, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_FN                 // ret
    SPEC 0, Lirv_X_LREF, Lirv_I_ZERO, Lirv_P_STMT                      // jmp
    SPEC Lirv_T_A|Lirv_T_B, Lirv_X_LREF, Lirv_I_ZERO|Lirv_I_REL, Lirv_P_STMT  // jcmp
    SPEC Lirv_T_A|Lirv_T_B|Lirv_T_C, Lirv_X_LREF, Lirv_I_ZERO, Lirv_P_STMT    // jfor
    SPEC 0, Lirv_X_LREF, Lirv_I_LREF, Lirv_P_MAIN                      // gosub
    SPEC 0, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_MAIN                      // return
    SPEC Lirv_T_D, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_STMT               // read
    SPEC Lirv_T_A, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_STMT               // prnum
    SPEC 0, Lirv_X_STR, Lirv_I_ZERO, Lirv_P_STMT                       // prstr
    SPEC 0, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_STMT                      // prcomma
    SPEC 0, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_STMT                      // prsemi
    SPEC 0, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_STMT                      // prnl
    SPEC 0, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_MAIN                      // end
    SPEC 0, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_STMT                      // stop
    SPEC Lirv_T_A|Lirv_T_B, Lirv_X_ARRM|Lirv_XF_BOPT, Lirv_I_ZERO, Lirv_P_STMT  // matredim
    SPEC 0, Lirv_X_ARRM, Lirv_I_ZERO, Lirv_P_STMT                      // matread
    SPEC 0, Lirv_X_ARRM, Lirv_I_MODE, Lirv_P_STMT                      // matprint
    SPEC 0, Lirv_X_ARRM, Lirv_I_ZERO, Lirv_P_STMT                      // matzer
    SPEC 0, Lirv_X_ARRM, Lirv_I_ZERO, Lirv_P_STMT                      // matcon
    SPEC 0, Lirv_X_ARRM, Lirv_I_ZERO, Lirv_P_STMT                      // matidn
    SPEC 0, Lirv_X_ARRM|Lirv_XF_AARR, Lirv_I_ZERO, Lirv_P_STMT         // matcopy
    SPEC 0, Lirv_X_ARRM|Lirv_XF_AARR|Lirv_XF_BARR, Lirv_I_ZERO, Lirv_P_STMT  // matadd
    SPEC 0, Lirv_X_ARRM|Lirv_XF_AARR|Lirv_XF_BARR, Lirv_I_ZERO, Lirv_P_STMT  // matsub
    SPEC 0, Lirv_X_ARRM|Lirv_XF_AARR|Lirv_XF_BARR, Lirv_I_ZERO, Lirv_P_STMT  // matmul
    SPEC Lirv_T_A, Lirv_X_ARRM|Lirv_XF_BARR, Lirv_I_ZERO, Lirv_P_STMT  // matscale
    SPEC 0, Lirv_X_ARRM|Lirv_XF_AARR, Lirv_I_ZERO, Lirv_P_STMT         // mattrn
    SPEC 0, Lirv_X_ARRM|Lirv_XF_AARR, Lirv_I_ZERO, Lirv_P_STMT         // matinv
    // Third and Fourth Edition opcodes (IR.md 3.2)
    SPEC Lirv_T_D|Lirv_S_D, Lirv_X_STR, Lirv_I_ZERO, Lirv_P_STMT       // slit
    SPEC Lirv_T_D|Lirv_S_D, Lirv_X_SSLOT, Lirv_I_ZERO, Lirv_P_STMT     // svar
    SPEC Lirv_T_D|Lirv_S_D|Lirv_T_A, Lirv_X_SLIST, Lirv_I_ZERO, Lirv_P_STMT  // sald1
    SPEC Lirv_T_A|Lirv_S_A|Lirv_T_B|Lirv_S_B, Lirv_X_NONE, Lirv_I_ZERO|Lirv_I_ADEST, Lirv_P_STMT  // sset
    SPEC Lirv_T_A|Lirv_S_A|Lirv_T_B|Lirv_S_B, Lirv_X_LREF, Lirv_I_ZERO|Lirv_I_REL, Lirv_P_STMT    // sjcmp
    SPEC Lirv_T_A|Lirv_S_A, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_STMT      // prsv
    SPEC Lirv_T_A, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_STMT               // prtab
    SPEC Lirv_T_A|Lirv_S_A, Lirv_X_NONE, Lirv_I_ZERO|Lirv_I_ADEST, Lirv_P_STMT  // sread
    SPEC 0, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_STMT                      // inbeg
    SPEC Lirv_T_D, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_STMT               // innum
    SPEC Lirv_T_A|Lirv_S_A, Lirv_X_NONE, Lirv_I_ZERO|Lirv_I_ADEST, Lirv_P_STMT  // insv
    SPEC 0, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_STMT                      // inend
    SPEC 0, Lirv_X_ARR1, Lirv_I_ZERO, Lirv_P_STMT                      // matinput
    SPEC 0, Lirv_X_SLIST, Lirv_I_ZERO, Lirv_P_STMT                     // smatinput
    SPEC Lirv_T_A, Lirv_X_SLIST, Lirv_I_ZERO, Lirv_P_STMT              // smatredim
    SPEC 0, Lirv_X_SLIST, Lirv_I_ZERO, Lirv_P_STMT                     // smatread
    SPEC 0, Lirv_X_SLIST, Lirv_I_MODE, Lirv_P_STMT                     // smatprint
    SPEC Lirv_T_A|Lirv_S_A, Lirv_X_ARR1, Lirv_I_ZERO, Lirv_P_STMT      // chgs2n
    SPEC Lirv_T_A|Lirv_S_A, Lirv_X_ARR1, Lirv_I_ZERO|Lirv_I_ADEST, Lirv_P_STMT  // chgn2s
    SPEC Lirv_T_D|Lirv_T_A, Lirv_X_NONE, Lirv_I_COUNT, Lirv_P_STMT     // onsel
    SPEC 0, Lirv_X_NONE, Lirv_I_RESTORE, Lirv_P_STMT                   // restore
    SPEC 0, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_STMT                      // randomize
    SPEC Lirv_T_D|Lirv_T_A, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_ANY       // sgn
    SPEC Lirv_T_D|Lirv_T_A, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_ANY       // cot
    SPEC Lirv_T_D, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_ANY                // num
    SPEC Lirv_T_D, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_ANY                // det
    SPEC Lirv_T_A, Lirv_X_NONE, Lirv_I_ANY, Lirv_P_ANY                 // fnarg
    SPEC Lirv_T_A, Lirv_X_NONE, Lirv_I_PARAM, Lirv_P_FNML              // stparam
    SPEC Lirv_T_D, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_FNML               // ldfv
    SPEC Lirv_T_A, Lirv_X_NONE, Lirv_I_ZERO, Lirv_P_FNML               // stfv
Lirv_spec_end:
// element forms (A = IR_NONE, IR.md 3.2): B = subscript (a number)
Lirv_spec_el_s:
    SPEC Lirv_T_B, Lirv_X_SLIST, Lirv_I_ZERO, Lirv_P_STMT              // sread / insv L$, tB
Lirv_spec_el_c:
    SPEC Lirv_T_B, Lirv_X_ARR1, Lirv_I_SLIST, Lirv_P_STMT              // chgn2s L, M$, tB

.if (Lirv_spec_end - Lirv_spec) != (4 * OP_COUNT)
.error "ir_verify: spec table does not match OP_COUNT"
.endif

    .section __TEXT,__cstring,cstring_literals
Lirv_fmt_insn:      .asciz "ir verify: %s (in %s, instruction %lu)"
Lirv_fmt_func:      .asciz "ir verify: %s (in %s)"
Lirv_fmt_module:    .asciz "ir verify: %s"
Lirv_s_main:        .asciz "main"
Lirv_m_temp_range:  .asciz "temp operand out of range"
Lirv_m_temp_undef:  .asciz "temp used before its definition"
Lirv_m_temp_twice:  .asciz "temp defined twice"
Lirv_m_temp_kind:   .asciz "temp of the wrong kind (number / string reference)"
Lirv_m_slitdest:    .asciz "string constant used as a destination"
Lirv_m_unused:      .asciz "unused operand field is not IR_NONE/0"
Lirv_m_opcode:      .asciz "invalid opcode"
Lirv_m_place:       .asciz "instruction not allowed in this kind of function"
Lirv_m_rel:         .asciz "invalid relation code"
Lirv_m_line:        .asciz "line number out of range"
Lirv_m_slot:        .asciz "variable slot out of range"
Lirv_m_array:       .asciz "array not declared with this dimensionality"
Lirv_m_matmode:     .asciz "matprint mode is not 0 or 1"
Lirv_m_callfn:      .asciz "callfn target is not a present FN function"
Lirv_m_string:      .asciz "string id out of range"
Lirv_m_label_range: .asciz "label id out of range"
Lirv_m_label_twice: .asciz "label defined twice"
Lirv_m_label_kind:  .asciz "label table entry does not match its definition"
Lirv_m_present:     .asciz "PRESENT is not 0 or 1"
Lirv_m_kind:        .asciz "wrong function kind"
Lirv_m_fnidx:       .asciz "wrong function letter"
Lirv_m_mainparam:   .asciz "main has a parameter"
Lirv_m_maindef:     .asciz "main has a DEF line"
Lirv_m_param:       .asciz "FN parameter is not a scalar slot"
Lirv_m_empty:       .asciz "function has no instructions"
Lirv_m_lastop:      .asciz "main must end with end, FN functions with ret"
Lirv_m_nolabels:    .asciz "label table missing"
Lirv_m_label_undef: .asciz "label never defined"
Lirv_m_nslots:      .asciz "NSLOTS != 286 + 2*NFORS"
Lirv_m_mreserved:   .asciz "reserved module field is not 0"
Lirv_m_nostrings:   .asciz "string table missing"
Lirv_m_nodata:      .asciz "data table missing"
Lirv_m_dims:        .asciz "array with more than 2 dimensions"
Lirv_m_arrsize:     .asciz "array larger than 1000000 elements"
Lirv_m_nomain:      .asciz "main function missing"
Lirv_m_fnarg_seq:   .asciz "fnarg not immediately followed by its callfn"
Lirv_m_fnarg_num:   .asciz "fnarg index is not the next argument number 1..7"
Lirv_m_argcount:    .asciz "callfn argument count differs from the callee's NPARAMS"
Lirv_m_restore:     .asciz "restore variant is not 0, 1 or 2"
Lirv_m_onsel:       .asciz "onsel count is 0"
Lirv_m_paramidx:    .asciz "parameter index not below NPARAMS"
Lirv_m_sslot:       .asciz "string variable slot out of range"
Lirv_m_slist:       .asciz "string list not declared"
Lirv_m_endline:     .asciz "FNEND line wrong for the function kind"
Lirv_m_nparams:     .asciz "more than 8 parameters"
Lirv_m_param0:      .asciz "PARAM is not PARAMS[0]"
Lirv_m_nosdata:     .asciz "string data table missing"
Lirv_m_sdims:       .asciz "string list that is not one-dimensional"
Lirv_m_sarrsize:    .asciz "string list larger than 1000000 elements"

    .section __DATA,__data
Lirv_msgbuf:
    .space Lirv_MSGBUF_SIZE
Lirv_fnname:
    .space 8
