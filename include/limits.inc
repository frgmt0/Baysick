// =====================================================================
// include/limits.inc -- Baysick hard limits and exit codes.
//
// CONTRACT FILE. Shared by every module. Change only together with
// docs/LANGUAGE.md (section "Limits") and docs/DESIGN.md.
// Guarded so it may be included more than once.
// =====================================================================
.ifndef BSK_LIMITS_INC
.equ BSK_LIMITS_INC, 1

// ---- Source program limits (checked by the frontend) ----------------
.equ LIM_SOURCE_BYTES,      1048576   /* max size of a .bas file -> PROGRAM TOO LONG */
.equ LIM_PHYS_LINE_LEN,     255       /* max bytes per physical line (excl. CR/LF) -> LINE TOO LONG */
.equ LIM_LINES,             10000     /* max stored program lines -> PROGRAM TOO LONG */
.equ LIM_LINE_NUMBER,       99999     /* line numbers are 1..99999 (1..5 digits) */
.equ LIM_LINE_DIGITS,       5         /* >5 digits -> ILLEGAL LINE NUMBER */
.equ LIM_NUM_DIGITS,        9         /* max mantissa digits in a constant -> ILLEGAL CONSTANT */
.equ LIM_EXP_DIGITS,        2         /* max exponent digits in a constant -> ILLEGAL CONSTANT */
.equ LIM_DATA_VALUES,       100000    /* max DATA numbers in a program -> TOO MUCH DATA */
.equ LIM_SDATA_VALUES,      100000    /* max DATA strings in a program -> TOO MUCH DATA */
.equ LIM_LABEL_BYTES,       65536     /* max total bytes of string constants outside DATA -> TOO MANY LABELS */
.equ LIM_FN_PARAMS,         8         /* max DEF parameters -> INCORRECT FORMAT */
.equ LIM_FORS,              1000      /* max FOR statements in a program -> TOO MANY LOOPS */
.equ LIM_EXPR_DEPTH,        32        /* max nesting of '(' (grouping, args, subscripts) -> FORMULA TOO COMPLEX */
.equ LIM_DIM_DIGITS,        7         /* max digits in a DIM bound -> DIMENSION TOO LARGE */
.equ LIM_ARRAY_ELEMS,       1000000   /* max elements in one array -> DIMENSION TOO LARGE */
.equ LIM_DEFAULT_BOUND,     10        /* default upper bound of each subscript without DIM */
.equ LIM_FILES,             8         /* max file names in all FILES statements (file numbers 1..8) -> TOO MANY FILES */
.equ LIM_FILE_NAME,         255       /* max bytes of one FILES name (implied by LIM_PHYS_LINE_LEN) */
.equ LIM_SUB_PARAMS,        16        /* max SUB parameters / CALL arguments -> INCORRECT FORMAT (Sixth Edition) */

// ---- Language-fixed sizes --------------------------------------------
.equ NUM_LETTERS,           26
.equ NUM_SCALAR_SLOTS,      286       /* 26 letters x (bare + digits 0..9) */
.equ NUM_FUNCS,             27        /* main + FNA..FNZ */
.equ NUM_STRING_SLOTS,      286       /* string variables A$..Z9$, same numbering as scalar slots */

// ---- Runtime limits ----------------------------------------------------
.equ LIM_GOSUB_DEPTH,       1024      /* pending GOSUBs -> TOO MANY GOSUBS */
.equ LIM_CALL_DEPTH,        1024      /* active SUB activations -> TOO MANY CALLS (Sixth Edition) */
.equ LIM_CALL_WORDS,        2097152   /* summed SUBL_COST of active activations -> TOO MANY CALLS (Sixth Edition) */
.equ LIM_STRING_LEN,        65536     /* max bytes in a string value -> STRING TOO LONG */
.equ LIM_INPUT_LINE,        65536     /* max bytes in an input line (excl. CR LF) -> INPUT LINE TOO LONG */
.equ LIM_CHAR_CODE,         255       /* CHANGE codes are 0..255 -> ILLEGAL CHARACTER */

// ---- Compiler process exit codes ---------------------------------------
.equ EXIT_OK,               0         /* compiled (and linked, unless -S/--emit-ir) */
.equ EXIT_COMPILE_ERROR,    1         /* BASIC program has an error (message on stderr) */
.equ EXIT_USAGE,            2         /* bad command line, cannot read input / write output */
.equ EXIT_TOOLCHAIN,        3         /* as / ld / xcrun failed or could not be started */
.equ EXIT_INTERNAL,         4         /* out of memory, IR verifier failure, internal bug */

// ---- Compiled-program exit codes ---------------------------------------
.equ EXIT_RUN_OK,           0         /* END, STOP, OUT OF DATA or END OF INPUT */
.equ EXIT_RUN_ERROR,        1         /* any other run-time error */

.endif
