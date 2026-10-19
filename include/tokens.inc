// =====================================================================
// include/tokens.inc -- frontend scanner token kinds and keyword ids.
//
// CONTRACT FILE (frontend-internal, pinned so the lexer and parser files
// inside src/frontend/ and docs agree). See docs/DESIGN.md "Frontend".
//
// The scanner works on a COMPACTED line (spaces/tabs removed outside
// string literals, letters upper-cased outside literals, UTF-8 U+2191
// "↑" rewritten to '^'). It is mode driven:
//   operand mode  -> TK_NUMBER TK_STRING TK_VAR TK_ARRAY TK_FN
//                    TK_BUILTIN TK_LPAREN TK_PLUS TK_MINUS ... TK_BAD
//   operator mode -> arithmetic/relational/punctuation tokens, the
//                    keywords THEN TO STEP, TK_EOL, or TK_BAD
// =====================================================================
.ifndef BSK_TOKENS_INC
.equ BSK_TOKENS_INC, 1

// ---- Scanner modes ----------------------------------------------------
.equ SCAN_OPERAND,      0
.equ SCAN_OPERATOR,     1

// ---- Token kinds ------------------------------------------------------
.equ TK_EOL,            0   /* end of compacted line */
.equ TK_NUMBER,         1   /* numeric constant; value in TOK_VALUE (double bits) */
.equ TK_STRING,         2   /* "..." ; TOK_PTR/TOK_LEN = contents without quotes */
.equ TK_VAR,            3   /* simple variable; TOK_SLOT = scalar slot (0..285) */
.equ TK_ARRAY,          4   /* letter immediately followed by '('; TOK_INDEX = letter 0..25 ('(' consumed) */
.equ TK_FN,             5   /* FNx immediately followed by '('; TOK_INDEX = 0..25 ('(' consumed) */
.equ TK_BUILTIN,        6   /* builtin name; TOK_INDEX = BI_*; '(' consumed unless bare RND */
.equ TK_LPAREN,         7
.equ TK_RPAREN,         8
.equ TK_COMMA,          9
.equ TK_SEMI,           10
.equ TK_PLUS,           11
.equ TK_MINUS,          12
.equ TK_STAR,           13
.equ TK_SLASH,          14
.equ TK_POW,            15  /* '^' (also from UTF-8 '↑') */
.equ TK_EQ,             16  /* '=' */
.equ TK_NE,             17  /* '<>' */
.equ TK_LT,             18  /* '<' */
.equ TK_LE,             19  /* '<=' */
.equ TK_GT,             20  /* '>' */
.equ TK_GE,             21  /* '>=' */
.equ TK_THEN,           22  /* keyword THEN (operator mode only) */
.equ TK_TO,             23  /* keyword TO   (operator mode only) */
.equ TK_STEP,           24  /* keyword STEP (operator mode only) */
.equ TK_BAD,            25  /* anything else; TOK_ERR holds the error code to report */
.equ TK_COUNT,          26

// ---- Token record (filled by the scanner), 40 bytes --------------------
.equ TOK_KIND,          0   /* u32 TK_* */
.equ TOK_INDEX,         4   /* u32 letter / builtin / fn index */
.equ TOK_SLOT,          8   /* u32 scalar slot for TK_VAR */
.equ TOK_LEN,           12  /* u32 string length */
.equ TOK_PTR,           16  /* ptr  string contents / token start */
.equ TOK_VALUE,         24  /* u64 IEEE-754 bits for TK_NUMBER */
.equ TOK_ERR,           32  /* u32 ERR_* for TK_BAD (ILLEGAL CONSTANT, ILLEGAL FORMULA, ...) */
.equ TOK_SIZE,          40

// ---- Builtin function ids (TOK_INDEX for TK_BUILTIN), source order ------
.equ BI_SIN,            0
.equ BI_COS,            1
.equ BI_TAN,            2
.equ BI_ATN,            3
.equ BI_EXP,            4
.equ BI_ABS,            5
.equ BI_LOG,            6
.equ BI_SQR,            7
.equ BI_INT,            8
.equ BI_RND,            9
.equ BI_COUNT,          10

// ---- Statement keyword ids (matched as prefixes of the compacted text
//      after the line number, in exactly this order) --------------------
.equ KW_LET,            0
.equ KW_PRINT,          1
.equ KW_END,            2
.equ KW_READ,           3
.equ KW_DATA,           4
.equ KW_GOTO,           5
.equ KW_IF,             6
.equ KW_FOR,            7
.equ KW_NEXT,           8
.equ KW_GOSUB,          9
.equ KW_RETURN,         10
.equ KW_DEF,            11
.equ KW_DIM,            12
.equ KW_REM,            13
.equ KW_STOP,           14
.equ KW_MAT,            15  /* Second Edition matrix statements (LANGUAGE.md 7.14) */

.equ KW_COUNT,          16

// ---- MAT sub-keywords (after "MAT", in this order) and MAT function ids --
// "MAT" is followed by READ, PRINT, or an assignment "letter =" whose
// right-hand side may start with one of these three-letter names:
.equ MF_ZER,            0   /* ZER [ (r [, c]) ] */
.equ MF_CON,            1   /* CON [ (r [, c]) ] */
.equ MF_IDN,            2   /* IDN [ (n) ] */
.equ MF_TRN,            3   /* TRN ( letter ) */
.equ MF_INV,            4   /* INV ( letter ) */
.equ MF_COUNT,          5

.endif
