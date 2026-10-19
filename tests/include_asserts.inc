// tests/include_asserts.inc -- layout assertions on the contract include
// files, shared by tests/include_check.s (Apple as, arm64 Mach-O) and
// tests/include_check_x86_64.s (GNU as, x86_64 ELF). Arch-neutral: only
// directives and expressions, `//` comments only at the start of a line
// (see the comment rule in docs/DESIGN.md section 3.4).
// The including file must have included baysick.inc first.
// Every condition is fully parenthesised: GNU as would read a bare
// `NAME == x` macro argument as the keyword argument `NAME=`.

.macro ASSERT cond, msg
.if !(\cond)
.error "\msg"
.endif
.endm

ASSERT ((IRM_ARRAYS + NUM_LETTERS*IRA_SIZE) == IRM_FUNCS), "IRM: arrays must end where funcs begin"
ASSERT ((IRM_FUNCS + NUM_FUNCS*IRF_SIZE) == IRM_SIZE),     "IRM: funcs must end at IRM_SIZE"
ASSERT ((1 << IRI_SHIFT) == IRI_SIZE),                     "IRI_SHIFT mismatch"
ASSERT ((IRI_IMM + 8) == IRI_SIZE),                        "IRI layout"
ASSERT ((IRF_RESERVED + 8) == IRF_SIZE),                   "IRF layout"
ASSERT ((IRS_LEN + 8) == IRS_SIZE),                        "IRS layout"
ASSERT ((IRA_FLAGS + 4) == IRA_SIZE),                      "IRA layout"
ASSERT ((RTA_CAP + 4) == RTA_SIZE),                        "RTA layout"
ASSERT ((MV_LD + 8) == MV_SIZE),                           "MV layout"
ASSERT ((KV_INV + 8) == KV_SIZE),                          "KV layout"
ASSERT ((KV_GEMM + 8*7) == KV_INV),                        "KV slots are consecutive pointers"
ASSERT (RT_MAT_SCRATCH_ELEMS >= LIM_ARRAY_ELEMS),          "MAT scratch holds any array"
ASSERT ((RT_KERN_INV_MAXN*RT_KERN_INV_MAXN) >= LIM_ARRAY_ELEMS), "INV workspace holds any square array"
ASSERT ((OP_MATINV - OP_MATREDIM) == 12),                  "MAT opcodes are contiguous"
ASSERT (OP_MATREDIM == (OP_STOP + 1)),                     "MAT opcodes follow OP_STOP"
ASSERT (MATPR_PACKED == (MATPR_ZONED + 1)),                "MATPR values"
ASSERT (MF_COUNT == (MF_INV + 1)),                         "MF_COUNT"
ASSERT ((BKD_RUNTIME_NAME + 8) == BKD_SIZE),               "BKD layout"
ASSERT ((TOK_ERR + 8) == TOK_SIZE),                        "TOK layout"
ASSERT ((OB_CAP + 8) == OB_SIZE),                          "OB layout"
ASSERT (SLOT_FOR_BASE == NUM_SCALAR_SLOTS),                "FOR slots must follow scalar slots"
ASSERT (NUM_SCALAR_SLOTS == NUM_LETTERS*SLOT_PER_LETTER),  "scalar slot count"
ASSERT (OP_COUNT == (OP_MATINV + 1)),                      "OP_COUNT"
ASSERT (KW_COUNT == (KW_MAT + 1)),                         "KW_COUNT"
ASSERT ((OP_INT - OP_SIN) == 8),                           "builtin opcodes must be contiguous"
ASSERT ((BI_INT - BI_SIN) == (OP_INT - OP_SIN)),           "builtin ids parallel builtin opcodes"
ASSERT (TK_COUNT == (TK_BAD + 1)),                         "TK_COUNT"
ASSERT (ERR_TABLE_SIZE == (ERR_SINGULAR_MATRIX + 1)),      "ERR_TABLE_SIZE"
ASSERT ((IRM_FUNCS % 8) == 0),                             "IRM_FUNCS alignment"
ASSERT (PH_SDK < PH_LIMIT),                                "placeholders below PH_LIMIT"
