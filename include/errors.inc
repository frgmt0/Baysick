// =====================================================================
// include/errors.inc -- error codes and the canonical message text.
//
// CONTRACT FILE. The numeric codes are returned by the frontend to the
// driver (compile-time) and passed to _bsk_err by compiled code /
// runtime (run-time). The text MUST match docs/LANGUAGE.md section
// "Error messages" byte for byte.
//
// Message output format (see LANGUAGE.md):
//   with a line number:    "<TEXT> IN <line>\n"
//   without a line number: "<TEXT>\n"
// =====================================================================
.ifndef BSK_ERRORS_INC
.equ BSK_ERRORS_INC, 1

// ---- Compile-time errors (codes 1..31 and, Sixth Edition, 57..61) ----
// (Run-time: 32..56 and, Baysick extensions, 62; see ERR_FIRST_RUNTIME.)
.equ ERR_NONE,                  0
.equ ERR_ILLEGAL_CONSTANT,      1   /* "ILLEGAL CONSTANT" */
.equ ERR_ILLEGAL_FORMULA,       2   /* "ILLEGAL FORMULA" */
.equ ERR_ILLEGAL_RELATION,      3   /* "ILLEGAL RELATION" */
.equ ERR_ILLEGAL_LINE_NUMBER,   4   /* "ILLEGAL LINE NUMBER" */
.equ ERR_ILLEGAL_INSTRUCTION,   5   /* "ILLEGAL INSTRUCTION" */
.equ ERR_ILLEGAL_VARIABLE,      6   /* "ILLEGAL VARIABLE" */
.equ ERR_INCORRECT_FORMAT,      7   /* "INCORRECT FORMAT" */
.equ ERR_END_NOT_LAST,          8   /* "END IS NOT LAST" */
.equ ERR_NO_END,                9   /* "NO END INSTRUCTION" */
.equ ERR_NO_DATA,               10  /* "NO DATA" */
.equ ERR_UNDEFINED_FUNCTION,    11  /* "UNDEFINED FUNCTION" */
.equ ERR_UNDEFINED_NUMBER,      12  /* "UNDEFINED NUMBER" */
.equ ERR_PROGRAM_TOO_LONG,      13  /* "PROGRAM TOO LONG" */
.equ ERR_TOO_MUCH_DATA,         14  /* "TOO MUCH DATA" */
.equ ERR_TOO_MANY_LABELS,       15  /* "TOO MANY LABELS" */
.equ ERR_TOO_MANY_LOOPS,        16  /* "TOO MANY LOOPS" */
.equ ERR_NOT_MATCH_WITH_FOR,    17  /* "NOT MATCH WITH FOR" */
.equ ERR_FOR_WITHOUT_NEXT,      18  /* "FOR WITHOUT NEXT" */
.equ ERR_DIMENSION_TOO_LARGE,   19  /* "DIMENSION TOO LARGE" */
.equ ERR_LINE_TOO_LONG,         20  /* "LINE TOO LONG"          (Baysick addition) */
.equ ERR_DUPLICATE_FUNCTION,    21  /* "DUPLICATE FUNCTION"     (Baysick addition) */
.equ ERR_DUPLICATE_DIMENSION,   22  /* "DUPLICATE DIMENSION"    (Baysick addition) */
.equ ERR_RECURSIVE_FUNCTION,    23  /* "RECURSIVE FUNCTION"     (Baysick addition) */
.equ ERR_FORMULA_TOO_COMPLEX,   24  /* "FORMULA TOO COMPLEX"    (Baysick addition) */
// Third and Fourth Edition compile-time errors (LANGUAGE.md 11)
.equ ERR_MISMATCHED_STRING,     25  /* "MISMATCHED STRING OPERATION" (1968 manual text) */
.equ ERR_NO_STRING_DATA,        26  /* "NO STRING DATA"         (1968 manual text) */
.equ ERR_WRONG_NUM_ARGS,        27  /* "INCORRECT NUMBER OF ARGUMENTS" (1968 manual text) */
.equ ERR_UNFINISHED_DEF,        28  /* "UNFINISHED DEF"         (1968 manual text) */
.equ ERR_NESTED_DEF,            29  /* "NESTED DEF"             (1968 manual text) */
.equ ERR_ILLEGAL_TRANSFER,      30  /* "ILLEGAL TRANSFER"       (Baysick addition) */
// Fifth Edition compile-time error (LANGUAGE.md 7.21, 11)
.equ ERR_TOO_MANY_FILES,        31  /* "TOO MANY FILES"         (GE 1970 manual text) */

// ---- Run-time errors (codes 32..56) ------------------------------------
.equ ERR_SUBSCRIPT,             32  /* "SUBSCRIPT ERROR" */
.equ ERR_ILLEGAL_RETURN,        33  /* "ILLEGAL RETURN" */
.equ ERR_OUT_OF_DATA,           34  /* "OUT OF DATA"   (exit status 0, see LANGUAGE.md) */
.equ ERR_DIVISION_BY_ZERO,      35  /* "DIVISION BY ZERO"       (Baysick addition) */
.equ ERR_ZERO_NEG_POWER,        36  /* "ZERO TO A NEGATIVE POWER" (Baysick addition) */
.equ ERR_LOG_OF_ZERO,           37  /* "LOG OF ZERO"            (Baysick addition) */
.equ ERR_OVERFLOW,              38  /* "OVERFLOW"               (Baysick addition) */
.equ ERR_TOO_MANY_GOSUBS,       39  /* "TOO MANY GOSUBS"        (Baysick addition) */
.equ ERR_DIMENSION_ERROR,       40  /* "DIMENSION ERROR"        (MAT; 1968 manual text) */
.equ ERR_SINGULAR_MATRIX,       41  /* "SINGULAR MATRIX"        (MAT INV; Baysick addition) */
// Third and Fourth Edition run-time errors (LANGUAGE.md 11)
.equ ERR_ON_RANGE,              42  /* "ON EVALUATED OUT OF RANGE" (1968 manual text) */
.equ ERR_END_OF_INPUT,          43  /* "END OF INPUT"  (exit status 0, like OUT OF DATA; Baysick) */
.equ ERR_STRING_TOO_LONG,       44  /* "STRING TOO LONG"        (CHANGE; Baysick addition) */
.equ ERR_ILLEGAL_CHARACTER,     45  /* "ILLEGAL CHARACTER"      (CHANGE; 1968 manual text) */
.equ ERR_INPUT_LINE_TOO_LONG,   46  /* "INPUT LINE TOO LONG"    (Baysick addition) */
.equ ERR_OUT_OF_ROOM,           47  /* "OUT OF ROOM"            (string storage; 1968 manual text) */
// Fifth Edition run-time errors (LANGUAGE.md 6, 7.21-7.26, 11)
.equ ERR_CANT_OPEN_FILE,        48  /* "CAN'T OPEN FILE"        (files; GE 1970 manual text) */
.equ ERR_INVALID_FILE_NUMBER,   49  /* "INVALID FILE NUMBER"    (files; GE 1970 manual text) */
.equ ERR_ILLEGAL_FILE_COMMAND,  50  /* "ILLEGAL FILE COMMAND"   (wrong file mode; GE 1970 manual text) */
.equ ERR_END_OF_FILE,           51  /* "END OF FILE"            (INPUT # past the end; Baysick addition) */
.equ ERR_FILE_FORMAT,           52  /* "INCORRECT FORMAT IN FILE" (bad INPUT # field; GE 1970 manual text) */
.equ ERR_CANT_WRITE_FILE,       53  /* "CAN'T WRITE FILE"       (file write failure; GE 1970 manual text) */
.equ ERR_ILLEGAL_VAL,           54  /* "ILLEGAL 'VAL' ARGUMENT" (VAL; GE 1970 manual text) */
.equ ERR_ASC_EMPTY,             55  /* "ASC OF EMPTY STRING"    (ASC; Baysick addition) */
// Sixth Edition run-time error (LANGUAGE.md 7.27, 11)
.equ ERR_TOO_MANY_CALLS,        56  /* "TOO MANY CALLS"         (SUB depth; Baysick addition) */
// Sixth Edition compile-time errors (LANGUAGE.md 7.27, 10.1, 11). They
// follow the run-time codes so that no existing code moves; the run-time
// codes are exactly ERR_FIRST_RUNTIME .. ERR_END_RUNTIME-1.
.equ ERR_UNDEFINED_SUB,         57  /* "UNDEFINED SUBPROGRAM"   (CALL of a name no SUB has; Baysick addition) */
.equ ERR_DUPLICATE_SUB,         58  /* "DUPLICATE SUBPROGRAM"   (two SUBs of one name; Baysick addition) */
.equ ERR_NESTED_SUB,            59  /* "NESTED SUB"             (SUB inside a SUB or DEF body; Baysick addition) */
.equ ERR_UNFINISHED_SUB,        60  /* "UNFINISHED SUB"         (SUB without SUBEND, FOR open at SUBEND; Baysick addition) */
.equ ERR_ARG_MISMATCH,          61  /* "ARGUMENT MISMATCH"      (array for scalar or vice versa in a CALL; Baysick addition) */

// Baysick extensions (LANGUAGE.md 15, 11):
// codes from ERR_EXT_FIRST on, after every edition's codes, so that no
// existing code moves. The extensions' run-time codes are exactly
// ERR_EXT_FIRST_RUNTIME .. ERR_EXT_END_RUNTIME-1; they have no
// compile-time code of their own.
.equ ERR_EXIT_RANGE,            62  /* "EXIT STATUS OUT OF RANGE" (END/STOP status not in 0..LIM_EXIT_STATUS; Baysick extension) */

.equ ERR_FIRST_RUNTIME,         32
.equ ERR_END_RUNTIME,           57  /* one past the last run-time code of the editions */
.equ ERR_EXT_FIRST,             62  /* first code of the Baysick extensions */
.equ ERR_EXT_FIRST_RUNTIME,     62  /* first run-time code of the Baysick extensions */
.equ ERR_EXT_END_RUNTIME,       63  /* one past the last run-time code of the Baysick extensions */
.equ ERR_TABLE_SIZE,            63  /* valid indices 0..62; the unused entry 0 is 0 */

// ---------------------------------------------------------------------
// BSK_EMIT_ERRMSG_TABLE name
//   Emits, in the CURRENT section (Mach-O: __DATA,__const; ELF:
//   .section .data.rel.ro,"aw",@progbits), an 8-byte aligned
//   table `name` of ERR_TABLE_SIZE .quad pointers, indexed by error
//   code, each pointing to a NUL-terminated message (0 for unused codes),
//   followed by the strings. The driver (src/driver/diag.s) and both
//   runtimes (src/runtime/rt_error.s, src/runtime_x86_64_linux/rt_error.s)
//   instantiate it, so the texts can never diverge. `name` is emitted as a
//   local (non-.globl) label; the instantiating file adds .globl if it
//   wants to.
// ---------------------------------------------------------------------
.macro BSK_EMIT_ERRMSG_TABLE name
    .p2align 3
\name:
    .quad 0
    .quad \name\()_m1,  \name\()_m2,  \name\()_m3,  \name\()_m4
    .quad \name\()_m5,  \name\()_m6,  \name\()_m7,  \name\()_m8
    .quad \name\()_m9,  \name\()_m10, \name\()_m11, \name\()_m12
    .quad \name\()_m13, \name\()_m14, \name\()_m15, \name\()_m16
    .quad \name\()_m17, \name\()_m18, \name\()_m19, \name\()_m20
    .quad \name\()_m21, \name\()_m22, \name\()_m23, \name\()_m24
    .quad \name\()_m25, \name\()_m26, \name\()_m27, \name\()_m28
    .quad \name\()_m29, \name\()_m30, \name\()_m31
    .quad \name\()_m32, \name\()_m33, \name\()_m34, \name\()_m35
    .quad \name\()_m36, \name\()_m37, \name\()_m38, \name\()_m39
    .quad \name\()_m40, \name\()_m41, \name\()_m42, \name\()_m43
    .quad \name\()_m44, \name\()_m45, \name\()_m46, \name\()_m47
    .quad \name\()_m48, \name\()_m49, \name\()_m50, \name\()_m51
    .quad \name\()_m52, \name\()_m53, \name\()_m54, \name\()_m55
    .quad \name\()_m56, \name\()_m57, \name\()_m58, \name\()_m59
    .quad \name\()_m60, \name\()_m61, \name\()_m62
\name\()_m1:  .asciz "ILLEGAL CONSTANT"
\name\()_m2:  .asciz "ILLEGAL FORMULA"
\name\()_m3:  .asciz "ILLEGAL RELATION"
\name\()_m4:  .asciz "ILLEGAL LINE NUMBER"
\name\()_m5:  .asciz "ILLEGAL INSTRUCTION"
\name\()_m6:  .asciz "ILLEGAL VARIABLE"
\name\()_m7:  .asciz "INCORRECT FORMAT"
\name\()_m8:  .asciz "END IS NOT LAST"
\name\()_m9:  .asciz "NO END INSTRUCTION"
\name\()_m10: .asciz "NO DATA"
\name\()_m11: .asciz "UNDEFINED FUNCTION"
\name\()_m12: .asciz "UNDEFINED NUMBER"
\name\()_m13: .asciz "PROGRAM TOO LONG"
\name\()_m14: .asciz "TOO MUCH DATA"
\name\()_m15: .asciz "TOO MANY LABELS"
\name\()_m16: .asciz "TOO MANY LOOPS"
\name\()_m17: .asciz "NOT MATCH WITH FOR"
\name\()_m18: .asciz "FOR WITHOUT NEXT"
\name\()_m19: .asciz "DIMENSION TOO LARGE"
\name\()_m20: .asciz "LINE TOO LONG"
\name\()_m21: .asciz "DUPLICATE FUNCTION"
\name\()_m22: .asciz "DUPLICATE DIMENSION"
\name\()_m23: .asciz "RECURSIVE FUNCTION"
\name\()_m24: .asciz "FORMULA TOO COMPLEX"
\name\()_m25: .asciz "MISMATCHED STRING OPERATION"
\name\()_m26: .asciz "NO STRING DATA"
\name\()_m27: .asciz "INCORRECT NUMBER OF ARGUMENTS"
\name\()_m28: .asciz "UNFINISHED DEF"
\name\()_m29: .asciz "NESTED DEF"
\name\()_m30: .asciz "ILLEGAL TRANSFER"
\name\()_m31: .asciz "TOO MANY FILES"
\name\()_m32: .asciz "SUBSCRIPT ERROR"
\name\()_m33: .asciz "ILLEGAL RETURN"
\name\()_m34: .asciz "OUT OF DATA"
\name\()_m35: .asciz "DIVISION BY ZERO"
\name\()_m36: .asciz "ZERO TO A NEGATIVE POWER"
\name\()_m37: .asciz "LOG OF ZERO"
\name\()_m38: .asciz "OVERFLOW"
\name\()_m39: .asciz "TOO MANY GOSUBS"
\name\()_m40: .asciz "DIMENSION ERROR"
\name\()_m41: .asciz "SINGULAR MATRIX"
\name\()_m42: .asciz "ON EVALUATED OUT OF RANGE"
\name\()_m43: .asciz "END OF INPUT"
\name\()_m44: .asciz "STRING TOO LONG"
\name\()_m45: .asciz "ILLEGAL CHARACTER"
\name\()_m46: .asciz "INPUT LINE TOO LONG"
\name\()_m47: .asciz "OUT OF ROOM"
\name\()_m48: .asciz "CAN'T OPEN FILE"
\name\()_m49: .asciz "INVALID FILE NUMBER"
\name\()_m50: .asciz "ILLEGAL FILE COMMAND"
\name\()_m51: .asciz "END OF FILE"
\name\()_m52: .asciz "INCORRECT FORMAT IN FILE"
\name\()_m53: .asciz "CAN'T WRITE FILE"
\name\()_m54: .asciz "ILLEGAL 'VAL' ARGUMENT"
\name\()_m55: .asciz "ASC OF EMPTY STRING"
\name\()_m56: .asciz "TOO MANY CALLS"
\name\()_m57: .asciz "UNDEFINED SUBPROGRAM"
\name\()_m58: .asciz "DUPLICATE SUBPROGRAM"
\name\()_m59: .asciz "NESTED SUB"
\name\()_m60: .asciz "UNFINISHED SUB"
\name\()_m61: .asciz "ARGUMENT MISMATCH"
\name\()_m62: .asciz "EXIT STATUS OUT OF RANGE"
    .p2align 3
.endm

// ---------------------------------------------------------------------
// BSK_EMIT_INPUT_MSGS name
//   Emits, in the CURRENT section, the three INPUT diagnostics of
//   LANGUAGE.md 7.15 as NUL-terminated strings WITH their final LF,
//   labelled name_retype, name_more, name_excess (local labels; the
//   length to write is name_retype_end - name_retype, etc., i.e. it
//   includes the LF and excludes the NUL). Instantiated by both runtimes
//   (rt_input.s), so the texts can never diverge from the documentation.
// ---------------------------------------------------------------------
.macro BSK_EMIT_INPUT_MSGS name
\name\()_retype: .ascii "INPUT DATA NOT IN CORRECT FORMAT -- RETYPE IT\n"
\name\()_retype_end: .byte 0
\name\()_more:   .ascii "NOT ENOUGH INPUT -- ADD MORE\n"
\name\()_more_end: .byte 0
\name\()_excess: .ascii "TOO MUCH INPUT -- EXCESS IGNORED\n"
\name\()_excess_end: .byte 0
.endm

.endif
