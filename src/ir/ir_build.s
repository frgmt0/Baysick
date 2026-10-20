// =====================================================================
// src/ir/ir_build.s -- IR builder API (include/ir.inc, docs/IR.md).
//
// All memory comes from _drv_alloc and is never freed. Growable arrays
// (instructions, labels, strings, data, string data, FILES names, Sixth
// Edition: SUB units) double their capacity by
// allocating a new block and copying; the old block is abandoned.
// Every function follows AAPCS64 and preserves x19-x28, d8-d15.
// =====================================================================
.include "baysick.inc"

.equ Lir_INIT_INSNS,    256         // first instruction block (records)
.equ Lir_INIT_LABELS,   64          // first label block (u32 entries)
.equ Lir_INIT_STRINGS,  16          // first string table block (entries)
.equ Lir_INIT_DATA,     64          // first data block (u64 entries)
.equ Lir_INIT_SUBS,     8           // first SUB unit table block (pointers)

    .section __TEXT,__text,regular,pure_instructions

.macro IR_ADR reg, sym
    adrp \reg, \sym@PAGE
    add \reg, \reg, \sym@PAGEOFF
.endm

// ---------------------------------------------------------------------
// Lir_grow -- private helper: allocate a bigger block and copy.
//   in:  x0 = old block (may be 0), x1 = bytes in use, x2 = new size
//   out: x0 = new zeroed block with the first x1 bytes copied
//   clobbers: x0-x17
//   callee-saved: x19 = old block, x20 = bytes in use, x21 = new block
//   frame: 48 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lir_grow:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov x19, x0
    mov x20, x1
    mov x0, x2
    bl _drv_alloc
    mov x21, x0
    cbz x20, 1f                         // nothing to copy yet
    mov x1, x19
    mov x2, x20
    bl _memcpy
1:
    mov x0, x21
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// _ir_module_new -- a zeroed Module with NSLOTS = SLOT_FOR_BASE.
//   in:  none
//   out: x0 = Module*
//   clobbers: x0-x17   callee-saved: none   frame: 16 bytes
// ---------------------------------------------------------------------
    .globl _ir_module_new
    .p2align 2
_ir_module_new:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x0, #IRM_SIZE
    bl _drv_alloc
    // no FOR statements yet: only the scalar slots
    mov w9, #SLOT_FOR_BASE
    str w9, [x0, #IRM_NSLOTS]
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// _ir_func_begin -- (re)initialise function record `index` as present.
//   in:  x0 = Module*, w1 = function index 0..26 (0 = main, 1+L = FN L),
//        w2 = parameter slot or IR_NONE, w3 = DEF line or 0
//   out: x0 = Function*
//   The record starts as the one-parameter form:
//   NPARAMS = 1 and PARAMS[0] = w2 (or NPARAMS = 0 for IR_NONE), the other
//   PARAMS IR_NONE, ENDLINE 0; _ir_func_set may change these afterwards.
//   clobbers: x0, x9-x11 (leaf except for the out-of-range fatal error)
// ---------------------------------------------------------------------
    .globl _ir_func_begin
    .p2align 2
_ir_func_begin:
    cmp w1, #NUM_FUNCS
    b.hs Lir_func_begin_bad
    // f = module + IRM_FUNCS + index * IRF_SIZE
    mov w9, #IRF_SIZE
    umaddl x0, w1, w9, x0
    add x0, x0, #IRM_FUNCS
    // kind and letter: main for index 0, FN (index-1) otherwise
    mov w10, #FUNC_KIND_MAIN
    mov w11, #0
    cbz w1, 1f
    mov w10, #FUNC_KIND_FN
    sub w11, w1, #FUNC_FN_BASE
1:
    mov w9, #1
    str w9, [x0, #IRF_PRESENT]
    str w10, [x0, #IRF_KIND]
    str w11, [x0, #IRF_FNIDX]
    str w2, [x0, #IRF_PARAM]
    // empty body: no temps, instructions or labels
    str wzr, [x0, #IRF_NTEMPS]
    str wzr, [x0, #IRF_NINSNS]
    str xzr, [x0, #IRF_INSNS]
    str wzr, [x0, #IRF_CAPINSNS]
    str wzr, [x0, #IRF_NLABELS]
    str xzr, [x0, #IRF_LABELS]
    str wzr, [x0, #IRF_CAPLABELS]
    str w3, [x0, #IRF_DEFLINE]
    // parameter list: the one-parameter form (or none) until _ir_func_set
    cmn w2, #1                          // IR_NONE == 0xFFFFFFFF
    cset w9, ne
    str w9, [x0, #IRF_NPARAMS]
    str wzr, [x0, #IRF_ENDLINE]
    // PARAMS[0] = w2, PARAMS[1..] = IR_NONE
    mov w9, #IR_NONE
    str w2, [x0, #IRF_PARAMS]
    mov x10, #1
2:
    add x11, x0, x10, lsl #2
    str w9, [x11, #IRF_PARAMS]
    add x10, x10, #1
    cmp x10, #LIM_FN_PARAMS
    b.lo 2b
    ret
Lir_func_begin_bad:
    IR_ADR x0, Lir_m_badfunc
    b _drv_fatal

// ---------------------------------------------------------------------
// _ir_new_temp -- allocate the next temp of a function.
//   in:  x0 = Function*
//   out: w0 = temp number
//   clobbers: x0, x9 (leaf)
// ---------------------------------------------------------------------
    .globl _ir_new_temp
    .p2align 2
_ir_new_temp:
    ldr w9, [x0, #IRF_NTEMPS]
    add w10, w9, #1
    str w10, [x0, #IRF_NTEMPS]
    mov w0, w9
    ret

// ---------------------------------------------------------------------
// _ir_new_label -- append a label to a function's label table.
//   in:  x0 = Function*, w1 = BASIC line number, or 0 for internal
//   out: w0 = label id
//   clobbers: x0-x17
//   callee-saved: x19 = Function*, x20 = line number
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .globl _ir_new_label
    .p2align 2
_ir_new_label:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    mov w20, w1
    ldr w9, [x19, #IRF_NLABELS]
    ldr w10, [x19, #IRF_CAPLABELS]
    cmp w9, w10
    b.lo 1f
    // full: double the capacity (first block Lir_INIT_LABELS)
    lsl w11, w10, #1
    mov w12, #Lir_INIT_LABELS
    cmp w10, #0
    csel w11, w12, w11, eq
    str w11, [x19, #IRF_CAPLABELS]
    ldr x0, [x19, #IRF_LABELS]
    lsl x1, x9, #2                      // bytes in use
    lsl x2, x11, #2                     // new size
    bl Lir_grow
    str x0, [x19, #IRF_LABELS]
1:
    // LABELS[n] = line; return n
    ldr x10, [x19, #IRF_LABELS]
    ldr w9, [x19, #IRF_NLABELS]
    str w20, [x10, x9, lsl #2]
    add w11, w9, #1
    str w11, [x19, #IRF_NLABELS]
    mov w0, w9
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _ir_emit -- append a copy of a 32-byte instruction record.
//   in:  x0 = Function*, x1 = IRI record
//   out: x0 = stored copy (valid until the next emit into this function)
//   clobbers: x0-x17
//   callee-saved: x19 = Function*, x20 = source record
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .globl _ir_emit
    .p2align 2
_ir_emit:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    mov x20, x1
    ldr w9, [x19, #IRF_NINSNS]
    ldr w10, [x19, #IRF_CAPINSNS]
    cmp w9, w10
    b.lo 1f
    // full: double the capacity (first block Lir_INIT_INSNS)
    lsl w11, w10, #1
    mov w12, #Lir_INIT_INSNS
    cmp w10, #0
    csel w11, w12, w11, eq
    str w11, [x19, #IRF_CAPINSNS]
    ldr x0, [x19, #IRF_INSNS]
    lsl x1, x9, #IRI_SHIFT
    lsl x2, x11, #IRI_SHIFT
    bl Lir_grow
    str x0, [x19, #IRF_INSNS]
1:
    // copy the record into slot n
    ldr x10, [x19, #IRF_INSNS]
    ldr w9, [x19, #IRF_NINSNS]
    add x0, x10, x9, lsl #IRI_SHIFT
    ldp q0, q1, [x20]
    stp q0, q1, [x0]
    add w9, w9, #1
    str w9, [x19, #IRF_NINSNS]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _ir_add_string -- append a string constant outside DATA (PRINT label,
// LET / IF / CHANGE constant); the bytes are copied.
//   in:  x0 = Module*, x1 = bytes, w2 = length
//   out: w0 = string id
//   clobbers: x0-x17 (tail call of Lir_add_bytes)
// ---------------------------------------------------------------------
    .globl _ir_add_string
    .p2align 2
_ir_add_string:
    // NSTRINGS / CAPSTRINGS and the STRINGS pointer
    add x3, x0, #IRM_STRINGS
    add x4, x0, #IRM_CAPSTRINGS
    add x0, x0, #IRM_NSTRINGS
    b Lir_add_bytes

// ---------------------------------------------------------------------
// _ir_add_sdata -- append one string DATA value (bytes are copied).
//   in:  x0 = Module*, x1 = bytes, w2 = length
//   out: w0 = string DATA index
//   clobbers: x0-x17 (tail call of Lir_add_bytes)
// ---------------------------------------------------------------------
    .globl _ir_add_sdata
    .p2align 2
_ir_add_sdata:
    // NSDATA / CAPSDATA and the SDATA pointer
    add x3, x0, #IRM_SDATA
    add x4, x0, #IRM_CAPSDATA
    add x0, x0, #IRM_NSDATA
    b Lir_add_bytes

// ---------------------------------------------------------------------
// Lir_add_bytes -- private helper: append an IRS_* entry {copy, len} to
// a growable table of the module.
//   in:  x0 = address of the table's u32 count, x1 = bytes, w2 = length,
//        x3 = address of the table's entry pointer,
//        x4 = address of the table's u32 capacity
//   out: w0 = index of the new entry
//   clobbers: x0-x17
//   callee-saved: x19 = &count, x20 = bytes, x21 = length,
//                 x22 = arena copy, x23 = &table pointer, x24 = &capacity
//   frame: 64 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lir_add_bytes:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    mov x19, x0
    mov x20, x1
    mov w21, w2
    mov x23, x3
    mov x24, x4
    // private copy of the bytes
    mov x0, x21
    bl _drv_alloc
    mov x22, x0
    cbz x21, 1f
    mov x1, x20
    mov x2, x21
    bl _memcpy
1:
    ldr w9, [x19]                       // count
    ldr w10, [x24]                      // capacity
    cmp w9, w10
    b.lo 2f
    // full: double the table (first block Lir_INIT_STRINGS entries)
    lsl w11, w10, #1
    mov w12, #Lir_INIT_STRINGS
    cmp w10, #0
    csel w11, w12, w11, eq
    str w11, [x24]
    ldr x0, [x23]
    mov x12, #IRS_SIZE
    mul x1, x9, x12
    mul x2, x11, x12
    bl Lir_grow
    str x0, [x23]
2:
    // entry n = { ptr, len }
    ldr x10, [x23]
    ldr w9, [x19]
    mov x12, #IRS_SIZE
    madd x10, x9, x12, x10
    str x22, [x10, #IRS_PTR]
    str w21, [x10, #IRS_LEN]
    add w11, w9, #1
    str w11, [x19]
    mov w0, w9
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

// ---------------------------------------------------------------------
// _ir_add_data -- append one DATA value.
//   in:  x0 = Module*, x1 = IEEE-754 bits
//   out: w0 = data index
//   clobbers: x0-x17
//   callee-saved: x19 = Module*, x20 = bits
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .globl _ir_add_data
    .p2align 2
_ir_add_data:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    mov x20, x1
    ldr w9, [x19, #IRM_NDATA]
    ldr w10, [x19, #IRM_CAPDATA]
    cmp w9, w10
    b.lo 1f
    // full: double the block
    lsl w11, w10, #1
    mov w12, #Lir_INIT_DATA
    cmp w10, #0
    csel w11, w12, w11, eq
    str w11, [x19, #IRM_CAPDATA]
    ldr x0, [x19, #IRM_DATA]
    lsl x1, x9, #3
    lsl x2, x11, #3
    bl Lir_grow
    str x0, [x19, #IRM_DATA]
1:
    ldr x10, [x19, #IRM_DATA]
    ldr w9, [x19, #IRM_NDATA]
    str x20, [x10, x9, lsl #3]
    add w11, w9, #1
    str w11, [x19, #IRM_NDATA]
    mov w0, w9
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _ir_set_array -- set the array table entry of one letter.
//   in:  x0 = Module*, w1 = letter 0..25, w2 = dims (0/1/2), w3 = b1,
//        w4 = b2, w5 = flags (IRA_FLAG_*)
//   out: none
//   clobbers: x0, x9 (leaf except for the out-of-range fatal error)
// ---------------------------------------------------------------------
    .globl _ir_set_array
    .p2align 2
_ir_set_array:
    cmp w1, #NUM_LETTERS
    b.hs Lir_set_array_bad
    // entry = module + IRM_ARRAYS + letter * IRA_SIZE
    mov w9, #IRA_SIZE
    umaddl x0, w1, w9, x0
    add x0, x0, #IRM_ARRAYS
    str w2, [x0, #IRA_DIMS]
    str w3, [x0, #IRA_B1]
    str w4, [x0, #IRA_B2]
    str w5, [x0, #IRA_FLAGS]
    ret
Lir_set_array_bad:
    IR_ADR x0, Lir_m_badletter
    b _drv_fatal

// ---------------------------------------------------------------------
// _ir_set_fors -- set the FOR count and NSLOTS = SLOT_FOR_BASE + 2*n.
//   in:  x0 = Module*, w1 = number of FOR statements
//   out: none
//   clobbers: x9 (leaf)
// ---------------------------------------------------------------------
    .globl _ir_set_fors
    .p2align 2
_ir_set_fors:
    str w1, [x0, #IRM_NFORS]
    mov w9, #SLOT_FOR_BASE
    add w9, w9, w1, lsl #1
    str w9, [x0, #IRM_NSLOTS]
    ret

// ---------------------------------------------------------------------
// _ir_set_sarray -- declare string list letter$ (DIMS = 1, B2 = 0).
//   in:  x0 = Module*, w1 = letter 0..25, w2 = b1 (upper bound),
//        w3 = flags (IRA_FLAG_*)
//   out: none
//   clobbers: x0, x9 (leaf except for the out-of-range fatal error)
// ---------------------------------------------------------------------
    .globl _ir_set_sarray
    .p2align 2
_ir_set_sarray:
    cmp w1, #NUM_LETTERS
    b.hs Lir_set_array_bad
    // entry = module + IRM_SARRAYS + letter * IRA_SIZE
    mov w9, #IRA_SIZE
    umaddl x0, w1, w9, x0
    add x0, x0, #IRM_SARRAYS
    mov w9, #1                          // a string list is always 1-D
    str w9, [x0, #IRA_DIMS]
    str w2, [x0, #IRA_B1]
    str wzr, [x0, #IRA_B2]
    str w3, [x0, #IRA_FLAGS]
    ret

// ---------------------------------------------------------------------
// _ir_func_set -- set the kind, parameter list and FNEND line of a
// function created by _ir_func_begin (IR.md 4.4).
//   in:  x0 = Function*, w1 = FUNC_KIND_*, w2 = nparams 0..LIM_FN_PARAMS,
//        x3 = u32[nparams] parameter slots (unread if nparams = 0),
//        w4 = FNEND line (FUNC_KIND_FNML) or 0
//   out: none (KIND, NPARAMS, PARAMS with the rest IR_NONE,
//        PARAM = PARAMS[0] or IR_NONE, ENDLINE)
//   clobbers: x0, x9-x12 (leaf except for the out-of-range fatal error)
// ---------------------------------------------------------------------
    .globl _ir_func_set
    .p2align 2
_ir_func_set:
    cmp w2, #LIM_FN_PARAMS
    b.hi Lir_func_set_bad
    str w1, [x0, #IRF_KIND]
    str w2, [x0, #IRF_NPARAMS]
    str w4, [x0, #IRF_ENDLINE]
    // PARAMS[k] = slots[k] for k < nparams, IR_NONE after
    mov x9, #0
1:
    mov w10, #IR_NONE
    cmp w9, w2
    b.hs 2f
    ldr w10, [x3, x9, lsl #2]
2:
    add x11, x0, x9, lsl #2
    str w10, [x11, #IRF_PARAMS]
    add x9, x9, #1
    cmp x9, #LIM_FN_PARAMS
    b.lo 1b
    // the one-parameter view: PARAM = PARAMS[0] (IR_NONE without parameters)
    ldr w10, [x0, #IRF_PARAMS]
    str w10, [x0, #IRF_PARAM]
    ret
Lir_func_set_bad:
    IR_ADR x0, Lir_m_badnparams
    b _drv_fatal

// ---------------------------------------------------------------------
// _ir_new_stemp -- allocate the next string temp cell of the module
// (Fifth Edition, IR.md 4.1: cells are numbered module-wide from 0).
//   in:  x0 = Module*
//   out: w0 = cell number (IRM_NSTEMPS before the increment)
//   clobbers: x0, x9, x10 (leaf)
// ---------------------------------------------------------------------
    .globl _ir_new_stemp
    .p2align 2
_ir_new_stemp:
    ldr w9, [x0, #IRM_NSTEMPS]
    add w10, w9, #1
    str w10, [x0, #IRM_NSTEMPS]
    mov w0, w9
    ret

// ---------------------------------------------------------------------
// _ir_add_file -- append one FILES name (Fifth Edition, IR.md 2); the
// bytes are copied. The caller has checked LIM_FILES.
//   in:  x0 = Module*, x1 = bytes, w2 = length
//   out: w0 = file number (1 for the first name)
//   clobbers: x0-x17
//   callee-saved: none (frame record only)
//   frame: 16 bytes
// ---------------------------------------------------------------------
    .globl _ir_add_file
    .p2align 2
_ir_add_file:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    // NFILES / CAPFILES and the FILES pointer
    add x3, x0, #IRM_FILES
    add x4, x0, #IRM_CAPFILES
    add x0, x0, #IRM_NFILES
    bl Lir_add_bytes
    // table entry n is file number n + 1
    add w0, w0, #1
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// _ir_set_sarray2 -- declare string table letter$ (Fifth Edition):
// DIMS = 2, B1, B2, FLAGS.
//   in:  x0 = Module*, w1 = letter 0..25, w2 = b1, w3 = b2,
//        w4 = flags (IRA_FLAG_*)
//   out: none
//   clobbers: x0, x9 (leaf except for the out-of-range fatal error)
// ---------------------------------------------------------------------
    .globl _ir_set_sarray2
    .p2align 2
_ir_set_sarray2:
    cmp w1, #NUM_LETTERS
    b.hs Lir_set_array_bad
    // entry = module + IRM_SARRAYS + letter * IRA_SIZE
    mov w9, #IRA_SIZE
    umaddl x0, w1, w9, x0
    add x0, x0, #IRM_SARRAYS
    mov w9, #2                          // a string table is 2-D
    str w9, [x0, #IRA_DIMS]
    str w2, [x0, #IRA_B1]
    str w3, [x0, #IRA_B2]
    str w4, [x0, #IRA_FLAGS]
    ret

// ---------------------------------------------------------------------
// _ir_set_fnkind -- set the FNK_* word of an FN function (Fifth
// Edition): IRM_FNKINDS[index] := bits. The word of main stays 0, and
// _ir_func_begin does not change it (a new module has every word 0).
//   in:  x0 = Module*, w1 = function index 1..26, w2 = FNK_* bits
//   out: none
//   clobbers: x0 (leaf except for the out-of-range fatal error)
// ---------------------------------------------------------------------
    .globl _ir_set_fnkind
    .p2align 2
_ir_set_fnkind:
    // only FN functions (index 1..26) have a kind word to set
    cbz w1, Lir_set_fnkind_bad
    cmp w1, #NUM_FUNCS
    b.hs Lir_set_fnkind_bad
    add x0, x0, #IRM_FNKINDS
    str w2, [x0, w1, uxtw #2]
    ret
Lir_set_fnkind_bad:
    IR_ADR x0, Lir_m_badfunc
    b _drv_fatal

// ---------------------------------------------------------------------
// _ir_new_sub -- create the next SUB unit of a program (Sixth Edition,
// IR.md 2.2, 4.1): a zeroed Module (NSLOTS = SLOT_FOR_BASE) with
// PARENT = main, UNITIDX = the main module's old NSUBS, a copy of the
// name, SUBLINE, no parameters (SUBPARAMS IR_NONE), appended to the main
// module's IRM_SUBS table.
//   in:  x0 = main Module*, x1 = name bytes, w2 = name length,
//        w3 = line of the SUB statement
//   out: x0 = the new unit's Module*
//   clobbers: x0-x17
//   callee-saved: x19 = main Module*, x20 = name bytes, x21 = name
//                 length, x22 = SUB line, x23 = unit Module*
//   frame: 64 bytes
// ---------------------------------------------------------------------
    .globl _ir_new_sub
    .p2align 2
_ir_new_sub:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]
    mov x19, x0
    mov x20, x1
    mov w21, w2
    mov w22, w3
    // the unit: a fresh module of its own
    bl _ir_module_new
    mov x23, x0
    str x19, [x23, #IRM_PARENT]
    ldr w9, [x19, #IRM_NSUBS]
    str w9, [x23, #IRM_UNITIDX]
    str w22, [x23, #IRM_SUBLINE]
    // no parameters until _ir_sub_set: every SUBPARAMS entry IR_NONE
    mov w9, #IR_NONE
    mov x10, #0
1:
    add x11, x23, x10, lsl #2
    str w9, [x11, #IRM_SUBPARAMS]
    add x10, x10, #1
    cmp x10, #LIM_SUB_PARAMS
    b.lo 1b
    // private copy of the name's bytes
    mov x0, x21
    bl _drv_alloc
    str x0, [x23, #IRM_SUBNAME]
    str w21, [x23, #IRM_SUBNAMELEN]
    cbz x21, 2f
    mov x1, x20
    mov x2, x21
    bl _memcpy
2:
    // room for one more pointer in the main module's IRM_SUBS
    ldr w9, [x19, #IRM_NSUBS]
    ldr w10, [x19, #IRM_CAPSUBS]
    cmp w9, w10
    b.lo 3f
    // full: double the table (first block Lir_INIT_SUBS entries)
    lsl w11, w10, #1
    mov w12, #Lir_INIT_SUBS
    cmp w10, #0
    csel w11, w12, w11, eq
    str w11, [x19, #IRM_CAPSUBS]
    ldr x0, [x19, #IRM_SUBS]
    lsl x1, x9, #3                      // bytes in use
    lsl x2, x11, #3                     // new size
    bl Lir_grow
    str x0, [x19, #IRM_SUBS]
3:
    // SUBS[n] = unit; NSUBS = n + 1
    ldr x10, [x19, #IRM_SUBS]
    ldr w9, [x19, #IRM_NSUBS]
    str x23, [x10, x9, lsl #3]
    add w9, w9, #1
    str w9, [x19, #IRM_NSUBS]
    mov x0, x23
    ldr x23, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

// ---------------------------------------------------------------------
// _ir_sub_set -- record the parameters and the SUBEND line of a unit
// (IR.md 2.2, 4.1).
//   in:  x0 = unit Module*, w1 = nparams 0..LIM_SUB_PARAMS,
//        x2 = u32[nparams] slots / letters, x3 = u8[nparams] SUBP_* kinds
//        (both unread if nparams = 0), w4 = SUBEND line
//   out: none (SUBNPARAMS, SUBPARAMS with the rest IR_NONE, SUBPKINDS
//        with the rest 0, SUBENDLINE)
//   clobbers: x0, x9-x12 (leaf except for the out-of-range fatal error)
// ---------------------------------------------------------------------
    .globl _ir_sub_set
    .p2align 2
_ir_sub_set:
    cmp w1, #LIM_SUB_PARAMS
    b.hi Lir_sub_set_bad
    str w1, [x0, #IRM_SUBNPARAMS]
    str w4, [x0, #IRM_SUBENDLINE]
    // entry k: the caller's values for k < nparams, IR_NONE / 0 after
    mov x9, #0
1:
    mov w10, #IR_NONE
    mov w11, #0
    cmp w9, w1
    b.hs 2f
    ldr w10, [x2, x9, lsl #2]
    ldrb w11, [x3, x9]
2:
    add x12, x0, x9, lsl #2
    str w10, [x12, #IRM_SUBPARAMS]
    add x12, x0, x9
    strb w11, [x12, #IRM_SUBPKINDS]
    add x9, x9, #1
    cmp x9, #LIM_SUB_PARAMS
    b.lo 1b
    ret
Lir_sub_set_bad:
    IR_ADR x0, Lir_m_badsubparams
    b _drv_fatal

// ---------------------------------------------------------------------
// _ir_set_param_array -- enter an array parameter of a unit (IR.md 2.2):
// arrays (numeric) or sarrays (string) entry of the letter := DIMS,
// B1 = B2 = 0, FLAGS = IRA_FLAG_PARAM.
//   in:  x0 = unit Module*, w1 = letter 0..25, w2 = dims 1, 2 or
//        IRA_DIMS_ANY, w3 = 0 numeric array / 1 string array
//   out: none
//   clobbers: x0, x9 (leaf except for the out-of-range fatal error)
// ---------------------------------------------------------------------
    .globl _ir_set_param_array
    .p2align 2
_ir_set_param_array:
    cmp w1, #NUM_LETTERS
    b.hs Lir_set_array_bad
    // entry = module + IRM_ARRAYS (or IRM_SARRAYS) + letter * IRA_SIZE
    mov w9, #IRA_SIZE
    umaddl x0, w1, w9, x0
    add x9, x0, #IRM_ARRAYS
    add x0, x0, #IRM_SARRAYS
    cmp w3, #0
    csel x0, x9, x0, eq
    str w2, [x0, #IRA_DIMS]
    str wzr, [x0, #IRA_B1]
    str wzr, [x0, #IRA_B2]
    mov w9, #IRA_FLAG_PARAM
    str w9, [x0, #IRA_FLAGS]
    ret

    .section __TEXT,__cstring,cstring_literals
Lir_m_badfunc:
    .asciz "ir: function index out of range"
Lir_m_badletter:
    .asciz "ir: array letter out of range"
Lir_m_badnparams:
    .asciz "ir: too many function parameters"
Lir_m_badsubparams:
    .asciz "ir: too many SUB parameters"
