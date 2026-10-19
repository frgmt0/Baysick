// tests/include_check.s -- assembled by `make check-includes`.
// Proves the contract include files parse with Apple `as`, are safe to
// include twice, and that the documented record layouts are consistent.
.include "baysick.inc"
.include "baysick.inc"          // guards: second include must be a no-op

.macro ASSERT cond, msg
.if !(\cond)
.error "\msg"
.endif
.endm

ASSERT (IRM_ARRAYS + NUM_LETTERS*IRA_SIZE) == IRM_FUNCS, "IRM: arrays must end where funcs begin"
ASSERT (IRM_FUNCS + NUM_FUNCS*IRF_SIZE) == IRM_SIZE,     "IRM: funcs must end at IRM_SIZE"
ASSERT (1 << IRI_SHIFT) == IRI_SIZE,                     "IRI_SHIFT mismatch"
ASSERT (IRI_IMM + 8) == IRI_SIZE,                        "IRI layout"
ASSERT (IRF_RESERVED + 8) == IRF_SIZE,                   "IRF layout"
ASSERT (IRS_LEN + 8) == IRS_SIZE,                        "IRS layout"
ASSERT (IRA_FLAGS + 4) == IRA_SIZE,                      "IRA layout"
ASSERT (RTA_PAD + 4) == RTA_SIZE,                        "RTA layout"
ASSERT (BKD_RUNTIME_NAME + 8) == BKD_SIZE,               "BKD layout"
ASSERT (TOK_ERR + 8) == TOK_SIZE,                        "TOK layout"
ASSERT (OB_CAP + 8) == OB_SIZE,                          "OB layout"
ASSERT SLOT_FOR_BASE == NUM_SCALAR_SLOTS,                "FOR slots must follow scalar slots"
ASSERT NUM_SCALAR_SLOTS == NUM_LETTERS*SLOT_PER_LETTER,  "scalar slot count"
ASSERT OP_COUNT == (OP_STOP + 1),                        "OP_COUNT"
ASSERT (OP_INT - OP_SIN) == 8,                           "builtin opcodes must be contiguous"
ASSERT (BI_INT - BI_SIN) == (OP_INT - OP_SIN),           "builtin ids parallel builtin opcodes"
ASSERT TK_COUNT == (TK_BAD + 1),                         "TK_COUNT"
ASSERT KW_COUNT == (KW_STOP + 1),                        "KW_COUNT"
ASSERT ERR_TABLE_SIZE == (ERR_TOO_MANY_GOSUBS + 1),      "ERR_TABLE_SIZE"
ASSERT (IRM_FUNCS % 8) == 0,                             "IRM_FUNCS alignment"
ASSERT PH_SDK < PH_LIMIT,                                "placeholders below PH_LIMIT"

    .section __DATA,__const
    BSK_EMIT_ERRMSG_TABLE errtab
ASSERT (errtab_m1 - errtab) == ERR_TABLE_SIZE*8,         "error message table size"

    .section __TEXT,__text
    .p2align 2
    ret
