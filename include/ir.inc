// =====================================================================
// include/ir.inc -- Baysick IR: opcodes, operand encodings, in-memory
// record layouts, and the IR builder / dumper / verifier API.
//
// CONTRACT FILE. Normative description: docs/IR.md. Any change here must
// be made in docs/IR.md in the same commit, and tests/ir/*.ir regenerated
// only if the textual dump changes intentionally.
// =====================================================================
.ifndef BSK_IR_INC
.equ BSK_IR_INC, 1

.equ IR_VERSION,        1           /* printed as "; baysick-ir 1" */
.equ IR_NONE,           0xFFFFFFFF  /* "no operand" in any u32 operand field */

// ---- Opcodes (u16 IRI_OP) ------------------------------------------------
//                             fields used (see docs/IR.md table)
.equ OP_NOP,        0   /*  - */
.equ OP_LINE,       1   /*  IMM=BASIC line number, X=label id (defines that label) */
.equ OP_LABEL,      2   /*  X=label id (defines an internal label) */
.equ OP_CONST,      3   /*  DST, IMM=IEEE-754 bits */
.equ OP_LDV,        4   /*  DST, X=slot */
.equ OP_STV,        5   /*  X=slot, A=value */
.equ OP_ADD,        6   /*  DST, A, B */
.equ OP_SUB,        7   /*  DST, A, B */
.equ OP_MUL,        8   /*  DST, A, B */
.equ OP_DIV,        9   /*  DST, A, B */
.equ OP_POW,        10  /*  DST, A, B */
.equ OP_NEG,        11  /*  DST, A */
.equ OP_SIN,        12  /*  DST, A */
.equ OP_COS,        13  /*  DST, A */
.equ OP_TAN,        14  /*  DST, A */
.equ OP_ATN,        15  /*  DST, A */
.equ OP_EXP,        16  /*  DST, A */
.equ OP_ABS,        17  /*  DST, A */
.equ OP_LOG,        18  /*  DST, A */
.equ OP_SQR,        19  /*  DST, A */
.equ OP_INT,        20  /*  DST, A */
.equ OP_RND,        21  /*  DST */
.equ OP_ALD1,       22  /*  DST, X=array letter, A=subscript */
.equ OP_ALD2,       23  /*  DST, X=array letter, A=row, B=column */
.equ OP_AST1,       24  /*  X=array letter, A=subscript, B=value */
.equ OP_AST2,       25  /*  X=array letter, A=row, B=column, C=value */
.equ OP_CALLFN,     26  /*  DST, X=function letter 0..25, A=first argument or IR_NONE */
.equ OP_PARAM,      27  /*  DST, IMM=parameter index k (only inside an FN function) */
.equ OP_RET,        28  /*  A    (only inside an FN function) */
.equ OP_JMP,        29  /*  X=label */
.equ OP_JCMP,       30  /*  REL, A, B, X=label */
.equ OP_JFOR,       31  /*  A=value, B=limit, C=step, X=label */
.equ OP_GOSUB,      32  /*  X=target label, IMM=return label id */
.equ OP_RETURN,     33  /*  - */
.equ OP_READ,       34  /*  DST */
.equ OP_PRNUM,      35  /*  A */
.equ OP_PRSTR,      36  /*  X=string id */
.equ OP_PRCOMMA,    37  /*  - */
.equ OP_PRSEMI,     38  /*  - */
.equ OP_PRNL,       39  /*  - */
.equ OP_END,        40  /*  - */
.equ OP_STOP,       41  /*  - */
// MAT opcodes (Second Edition matrix statements, IR.md 3.1). Array letters
// 0..25 are in X (target) and, where listed, in A / B (array operands).
.equ OP_MATREDIM,   42  /*  X=array, A=rows temp, B=cols temp or IR_NONE */
.equ OP_MATREAD,    43  /*  X=array */
.equ OP_MATPRINT,   44  /*  X=array, IMM=MATPR_ZONED or MATPR_PACKED */
.equ OP_MATZER,     45  /*  X=array */
.equ OP_MATCON,     46  /*  X=array */
.equ OP_MATIDN,     47  /*  X=array */
.equ OP_MATCOPY,    48  /*  X=target array, A=source array */
.equ OP_MATADD,     49  /*  X=target array, A=array, B=array */
.equ OP_MATSUB,     50  /*  X=target array, A=array, B=array */
.equ OP_MATMUL,     51  /*  X=target array, A=array, B=array */
.equ OP_MATSCALE,   52  /*  X=target array, A=scalar temp, B=array */
.equ OP_MATTRN,     53  /*  X=target array, A=source array */
.equ OP_MATINV,     54  /*  X=target array, A=source array */
// Third and Fourth Edition opcodes (IR.md 3.2). "sref" temps hold the
// address of a 16-byte string descriptor (SD_*, runtime.inc); every other
// temp holds a double. String list letters 0..25 are in X (in IMM for the
// element form of OP_CHGN2S). The element form of OP_SREAD / OP_INSV /
// OP_CHGN2S (A = IR_NONE) stores into string list element B: the value is
// taken first, the subscript checked at the store (IR.md 3.2).
.equ OP_SLIT,       55  /*  DST sref, X=string id */
.equ OP_SVAR,       56  /*  DST sref, X=string slot 0..285 */
.equ OP_SALD1,      57  /*  DST sref, X=string list letter, A=subscript */
.equ OP_SSET,       58  /*  A=destination sref, B=source sref */
.equ OP_SJCMP,      59  /*  REL, A=sref, B=sref, X=label */
.equ OP_PRSV,       60  /*  A=sref */
.equ OP_PRTAB,      61  /*  A=column */
.equ OP_SREAD,      62  /*  A=destination sref; element form: A=IR_NONE, X=string list, B=subscript */
.equ OP_INBEG,      63  /*  - */
.equ OP_INNUM,      64  /*  DST */
.equ OP_INSV,       65  /*  A=destination sref; element form: A=IR_NONE, X=string list, B=subscript */
.equ OP_INEND,      66  /*  - */
.equ OP_MATINPUT,   67  /*  X=numeric list */
.equ OP_SMATINPUT,  68  /*  X=string list */
.equ OP_SMATREDIM,  69  /*  X=string list, A=length temp */
.equ OP_SMATREAD,   70  /*  X=string list */
.equ OP_SMATPRINT,  71  /*  X=string list, IMM=MATPR_ZONED or MATPR_PACKED */
.equ OP_CHGS2N,     72  /*  X=numeric list, A=source sref */
.equ OP_CHGN2S,     73  /*  X=numeric list, A=destination sref; element form: A=IR_NONE, IMM=string list, B=subscript */
.equ OP_ONSEL,      74  /*  DST, A=selector, IMM=number of line numbers N */
.equ OP_RESTORE,    75  /*  IMM=RESTORE_ALL, RESTORE_NUM or RESTORE_STR */
.equ OP_RANDOMIZE,  76  /*  - */
.equ OP_SGN,        77  /*  DST, A */
.equ OP_COT,        78  /*  DST, A */
.equ OP_NUM,        79  /*  DST */
.equ OP_DET,        80  /*  DST */
.equ OP_FNARG,      81  /*  IMM=argument index k 1..7, A=value (right before its callfn) */
.equ OP_STPARAM,    82  /*  IMM=parameter index k, A=value (multi-line FN only) */
.equ OP_LDFV,       83  /*  DST (multi-line FN only: the function value) */
.equ OP_STFV,       84  /*  A   (multi-line FN only) */

// MAT PRINT layout (IRI_IMM of OP_MATPRINT; also the w1 argument of
// _bsk_mat_print, DESIGN.md 6.5)
.equ MATPR_ZONED,   0   /* "MAT PRINT A," or last item: 15-column zones */
.equ MATPR_PACKED,  1   /* "MAT PRINT A;": packed (';' rule) */

// RESTORE variants (IRI_IMM of OP_RESTORE; also the w0 argument of _bsk_restore)
.equ RESTORE_ALL,   0   /* RESTORE:  both data blocks */
.equ RESTORE_NUM,   1   /* RESTORE*: numeric data block only */
.equ RESTORE_STR,   2   /* RESTORE$: string data block only */

// Fifth Edition opcodes (IR.md 3.3). New temp kind sources: OP_SCELL,
// OP_SALD2, OP_SPARAM and OP_SFV define sref temps. String temp cells
// (X of OP_SCELL) are static string descriptors numbered 0..NSTEMPS-1 per
// module. OP_FSEL selects the file of the ONE print or input opcode that
// must follow it immediately. Existing opcodes extended by the Fifth
// Edition: OP_SMATREDIM may have B = column temp (string table);
// OP_FNARG / OP_CALLFN may carry an sref for a string parameter.
.equ OP_SCELL,      85  /*  DST sref, X=string temp cell 0..NSTEMPS-1 */
.equ OP_SSTR,       86  /*  A=destination sref, B=number: the string A references := STR$(B) */
.equ OP_LEN,        87  /*  DST, A=sref */
.equ OP_ASC,        88  /*  DST, A=sref */
.equ OP_VAL,        89  /*  DST, A=sref */
.equ OP_SALD2,      90  /*  DST sref, X=string table letter, A=row, B=column */
.equ OP_SPARAM,     91  /*  DST sref, IMM=parameter index k (a string parameter of an FN function) */
.equ OP_SFV,        92  /*  DST sref (multi-line string FN only: its value variable FNx$) */
.equ OP_SCALLFN,    93  /*  X=function letter, A=first argument or IR_NONE, B=result sref */
.equ OP_SRET,       94  /*  A=sref (string FN only: return a copy of A) */
.equ OP_FSEL,       95  /*  A=file number (the next opcode is a print or input opcode) */
.equ OP_JEOF,       96  /*  A=file number, X=label: IF END # */
.equ OP_SCRATCH,    97  /*  A=file number */
.equ OP_FRESTORE,   98  /*  A=file number: RESTORE # */

// Fifth Edition contract staging switch (DESIGN.md 2.2). 0: the counts and
// layouts the current (Fourth Edition) modules are built with. 1: the
// Fifth Edition contract. Build with `make BSK_ED5=1` during the
// implementation phase; the integration step deletes the switch and keeps
// only the BSK_ED5_CONTRACT=1 values. Every other constant is
// unconditional. (Also defined, identically guarded, in tokens.inc.)
.ifndef BSK_ED5_CONTRACT
.equ BSK_ED5_CONTRACT, 0
.endif

.if BSK_ED5_CONTRACT
.equ OP_COUNT,      99
.else
.equ OP_COUNT,      85
.endif

// ---- Relation codes (u16 IRI_REL, OP_JCMP only; 0 otherwise) ------------
.equ REL_NONE,      0
.equ REL_EQ,        1   /* = */
.equ REL_NE,        2   /* <> */
.equ REL_LT,        3   /* < */
.equ REL_LE,        4   /* <= */
.equ REL_GT,        5   /* > */
.equ REL_GE,        6   /* >= */

// ---- Variable slots ---------------------------------------------------------
//   scalar slot = letter*11 + (digit+1, or 0 for a bare letter)  -> 0..285
//   FOR k limit  = SLOT_FOR_BASE + 2*k
//   FOR k step   = SLOT_FOR_BASE + 2*k + 1
//   module slot count = SLOT_FOR_BASE + 2*nfors
//   string slot  = letter*11 + (digit+1, or 0)  -> 0..285 (A$ .. Z9$, OP_SVAR;
//                  a separate space: string slot n is NOT scalar slot n)
.equ SLOT_PER_LETTER,   11
.equ SLOT_FOR_BASE,     286

// ---- Function indices (position in IRM_FUNCS) -----------------------------
.equ FUNC_MAIN,         0           /* FNx is at index 1 + (x - 'A') */
.equ FUNC_FN_BASE,      1
.equ FUNC_KIND_MAIN,    0
.equ FUNC_KIND_FN,      1           /* single-line DEF */
.equ FUNC_KIND_FNML,    2           /* multi-line DEF ... FNEND (LANGUAGE.md 7.10) */

// ---- Function kinds of the Fifth Edition (u32 per function in IRM_FNKINDS) ---
//   bit k (k = 0..7): parameter k is a string parameter (its IRF_PARAMS entry
//                     is then a STRING slot 0..285, e.g. X$)
//   FNK_STRING:       the function is a string function FNx$ (LANGUAGE.md 7.10)
.equ FNK_SPARAM0,       1           /* bit for parameter 0; parameter k is FNK_SPARAM0 << k */
.equ FNK_SPARAMS_MASK,  0xFF        /* all string-parameter bits */
.equ FNK_STRING,        0x100       /* string-valued function */

// ---- String temp cells (OP_SCELL) ------------------------------------------
//   Static 16-byte string descriptors (SD_*), zero-filled (empty strings),
//   numbered 0..IRM_NSTEMPS-1 in the order the frontend allocates them
//   (IR.md 4.1). Text form %s<n>.

// ---- IR instruction record (IRI_*), 32 bytes, 8-byte aligned -------------
.equ IRI_OP,        0   /* u16 opcode */
.equ IRI_REL,       2   /* u16 relation code (OP_JCMP), else 0 */
.equ IRI_DST,       4   /* u32 destination temp, or IR_NONE */
.equ IRI_A,         8   /* u32 operand temp, or IR_NONE */
.equ IRI_B,         12  /* u32 operand temp, or IR_NONE */
.equ IRI_C,         16  /* u32 operand temp, or IR_NONE */
.equ IRI_X,         20  /* u32 aux: slot / label / array letter / string id / fn letter, or IR_NONE */
                        // MAT opcodes also hold array letters in IRI_A / IRI_B (IR.md 3.1)
.equ IRI_IMM,       24  /* u64 constant bits / BASIC line number / return label id / MATPR_* / RESTORE_* / k / N / string list (chgn2s element form), else 0 */
.equ IRI_SIZE,      32
.equ IRI_SHIFT,     5   /* log2(IRI_SIZE) */

// ---- String table entry (IRS_*), 16 bytes ---------------------------------
.equ IRS_PTR,       0   /* ptr to bytes (not NUL-terminated; arena-owned copy) */
.equ IRS_LEN,       8   /* u32 length in bytes */
.equ IRS_SIZE,      16

// ---- Array table entry (IRA_*), 16 bytes, one per letter A..Z -------------
.equ IRA_DIMS,      0   /* u32 0 = array unused, 1 = list, 2 = table */
.equ IRA_B1,        4   /* u32 upper bound of first subscript (default 10) */
.equ IRA_B2,        8   /* u32 upper bound of second subscript (0 for lists) */
.equ IRA_FLAGS,     12  /* u32 bit 0 = bounds set by a DIM statement */
                        // String arrays (IRM_SARRAYS): DIMS 1 = string list,
                        // 2 = string table (Fifth Edition), B2 0 for lists.
                        // B1/B2 are the INITIAL bounds; MAT may change the
                        // run-time shape within (B1+1)*(B2+1) elements.
.equ IRA_SIZE,      16
.equ IRA_FLAG_DIMMED, 1

// ---- Function record (IRF_*), 96 bytes -----------------------------------
.equ IRF_PRESENT,   0   /* u32 1 if this function exists */
.equ IRF_KIND,      4   /* u32 FUNC_KIND_* */
.equ IRF_FNIDX,     8   /* u32 letter 0..25 for FN, 0 for main */
.equ IRF_PARAM,     12  /* u32 slot of the first parameter (FN), IR_NONE for main or no parameters */
.equ IRF_NTEMPS,    16  /* u32 number of temps t0..t(n-1) */
.equ IRF_NINSNS,    20  /* u32 number of instructions */
.equ IRF_INSNS,     24  /* ptr to IRI_SIZE records */
.equ IRF_CAPINSNS,  32  /* u32 capacity (builder private) */
.equ IRF_NLABELS,   36  /* u32 number of labels */
.equ IRF_LABELS,    40  /* ptr to u32[nlabels]: BASIC line number for line labels, 0 for internal */
.equ IRF_CAPLABELS, 48  /* u32 capacity (builder private) */
.equ IRF_DEFLINE,   52  /* u32 line number of the DEF statement (FN), 0 for main */
.equ IRF_NPARAMS,   56  /* u32 number of parameters 0..LIM_FN_PARAMS (0 for main) */
.equ IRF_ENDLINE,   60  /* u32 line number of the FNEND (FUNC_KIND_FNML), else 0 */
.equ IRF_PARAMS,    64  /* u32[LIM_FN_PARAMS] parameter slots in order; unused entries IR_NONE */
.equ IRF_SIZE,      96

// ---- Module record (IRM_*), 3488 bytes (3624 with BSK_ED5_CONTRACT) -------
.equ IRM_NFORS,     0   /* u32 number of FOR statements */
.equ IRM_NSLOTS,    4   /* u32 = SLOT_FOR_BASE + 2*nfors */
.equ IRM_NSTRINGS,  8   /* u32 */
.equ IRM_CAPSTRINGS,12  /* u32 (builder private) */
.equ IRM_NDATA,     16  /* u32 number of DATA values */
.equ IRM_CAPDATA,   20  /* u32 (builder private) */
.equ IRM_STRINGS,   24  /* ptr to IRS_SIZE entries */
.equ IRM_DATA,      32  /* ptr to u64 IEEE-754 bits */
.equ IRM_RESERVED,  40  /* u64 must be 0 */
.equ IRM_ARRAYS,    48  /* 26 x IRA_SIZE, inline */
.equ IRM_FUNCS,     464 /* 27 x IRF_SIZE, inline (index 0 = main, 1+L = FN letter L) */
.equ IRM_SARRAYS,   3056 /* 26 x IRA_SIZE, inline: string lists A$..Z$ (DIMS 0 unused, 1 list; B2 0) */
.equ IRM_NSDATA,    3472 /* u32 number of string DATA values */
.equ IRM_CAPSDATA,  3476 /* u32 (builder private) */
.equ IRM_SDATA,     3480 /* ptr to IRS_SIZE entries (string DATA values, program order) */
// Fifth Edition additions. The names are defined at both switch values, but
// the fields exist only in a 3624-byte module (BSK_ED5_CONTRACT=1). With
// BSK_ED5_CONTRACT=0 a module is 3488 bytes and no module may read or write
// these offsets (they lie past its end).
.equ IRM_NSTEMPS,   3488 /* u32 number of string temp cells (OP_SCELL X < NSTEMPS) */
.equ IRM_NFILES,    3492 /* u32 number of FILES names 0..LIM_FILES (file numbers 1..NFILES) */
.equ IRM_FILES,     3496 /* ptr to IRS_SIZE entries: FILES names in file-number order (entry 0 = #1) */
.equ IRM_CAPFILES,  3504 /* u32 (builder private) */
.equ IRM_RESERVED5, 3508 /* u32 must be 0 */
.equ IRM_FNKINDS,   3512 /* 27 x u32, inline: FNK_* bits per function index (0 for main) */
.if BSK_ED5_CONTRACT
.equ IRM_SIZE,      3624 /* 3512 + 27*4 = 3620, rounded up to a multiple of 8 */
.else
.equ IRM_SIZE,      3488
.endif

// ---------------------------------------------------------------------------
// IR builder API (implemented in src/ir/ir_build.s). AAPCS64. All memory
// comes from the driver arena (_drv_alloc); nothing is ever freed. Every
// function preserves x19-x28, d8-d15 and returns via x30.
//
//  _ir_module_new()                        -> x0 = Module* (zeroed, NSLOTS=286)
//  _ir_func_begin(x0=Module*, w1=func index 0..26, w2=param slot or IR_NONE,
//                 w3=DEF line or 0)        -> x0 = Function* (marks PRESENT)
//  _ir_new_temp(x0=Function*)              -> w0 = new temp number
//  _ir_new_label(x0=Function*, w1=line number or 0) -> w0 = new label id
//  _ir_emit(x0=Function*, x1=ptr to a 32-byte IRI record) -> x0 = ptr to the
//                                          stored copy (valid until next emit)
//  _ir_add_string(x0=Module*, x1=bytes, w2=len) -> w0 = string id (bytes copied)
//  _ir_add_data(x0=Module*, x1=u64 bits)   -> w0 = data index
//  _ir_set_array(x0=Module*, w1=letter, w2=dims, w3=b1, w4=b2, w5=flags)
//  _ir_set_fors(x0=Module*, w1=nfors)      (also sets NSLOTS)
//
// Third/Fourth Edition additions:
//  _ir_add_sdata(x0=Module*, x1=bytes, w2=len) -> w0 = string DATA index
//                                          (bytes copied)
//  _ir_set_sarray(x0=Module*, w1=letter, w2=b1, w3=flags)
//                                          string list: DIMS=1, B1, B2=0, FLAGS
//  _ir_func_set(x0=Function*, w1=FUNC_KIND_*, w2=nparams 0..8,
//               x3=ptr to u32[nparams] parameter slots, w4=FNEND line or 0)
//                                          sets KIND, NPARAMS, PARAMS (rest
//                                          IR_NONE), PARAM (= slot 0 or
//                                          IR_NONE) and ENDLINE
//
// Fifth Edition additions (BSK_ED5_CONTRACT layouts):
//  _ir_new_stemp(x0=Module*)             -> w0 = new string temp cell number
//                                          (IRM_NSTEMPS += 1)
//  _ir_add_file(x0=Module*, x1=bytes, w2=len) -> w0 = file number 1..
//                                          (bytes copied; the caller checks
//                                          LIM_FILES first)
//  _ir_set_sarray2(x0=Module*, w1=letter, w2=b1, w3=b2, w4=flags)
//                                          string table: DIMS=2, B1, B2, FLAGS
//  _ir_set_fnkind(x0=Module*, w1=func index 1..26, w2=FNK_* bits)
//                                          IRM_FNKINDS[index] := bits
//
// IR dumper (src/ir/ir_dump.s):
//  _ir_dump(x0=Module*, x1=OutBuf*)         appends the canonical text dump
//
// IR verifier (src/ir/ir_verify.s):
//  _ir_verify(x0=Module*) -> x0 = 0 if valid, else ptr to a NUL-terminated
//                            reason string (static storage)
// ---------------------------------------------------------------------------

.endif
