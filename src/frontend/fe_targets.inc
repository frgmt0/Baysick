// =====================================================================
// src/frontend/fe_targets.inc -- frontend-private target descriptor kinds
// (descriptor filled by _fe_target in fe_stmt.s; numeric kinds = number
// of subscripts). Included by fe_stmt.s, fe_input.s and fe_ext.s so the
// kinds are defined once. Not part of the cross-module binary contract.
// GNU-as-compatible: "//" comments only at the start of a line.
// =====================================================================
.equ FE_TGT_SCALAR,     0
.equ FE_TGT_LIST,       1
.equ FE_TGT_TABLE,      2
.equ FE_TGT_FN,         3           /* LET FNx = ... inside FNx's body */
.equ FE_TGT_STRING,     4           /* A$ (+8 = sref) or A$(i) (+8 = subscript) */
.equ FE_TGT_SIZE,       16
