# Baysick Language Specification

**Status: normative.** This document defines the language accepted by Baysick and the exact
observable behaviour of compiled programs (standard output bytes, standard error bytes, exit
status). Where this document and any other document disagree, this one wins for language
behaviour; `docs/IR.md` wins for IR details; `docs/DESIGN.md` wins for module boundaries and ABI.

Baysick implements **Dartmouth BASIC through the Fourth Edition (1968)**: the language of the
manual of 1 October 1964 ([M64]) — the fifteen statements of the First Edition (first run 1 May
1964), the Second Edition's zero-based subscripts and `;` packing and its **MAT** matrix
statements (§7.14) — extended by the additions of the **Third Edition** (1966: `INPUT`,
`RESTORE`, `SGN`) and the **Fourth Edition** (1967 supplement and January 1968 manual [M68]:
string variables and lists, `CHANGE`, `ON … GO TO`, `TAB`, `RANDOMIZE`, multiple and multi-line
`DEF`, `MAT INPUT`, `NUM`, `DET`, `COT`, multiple assignment, `'` remarks). Sections marked
**Baysick decision:** are places where the historical behaviour is unknown, impractical on a
modern machine, or deliberately extended; each states the choice and why. §14 lists every place
where a later edition *changed* the meaning of a program an earlier edition already accepted,
and which meaning Baysick keeps.

**Edition and language level.** [M64] *is* the Second Edition manual (Dartmouth's
"version 2" manual of October 1964, [W]; bitsavers files the same document as
`dartmouth/dtss/196410_BASIC.pdf`). It documents subscripts from 0 (p. 36–38) and the `;`
packed format (p. 34–35) — both Second Edition changes, already part of Baysick — and, in
chapter IV "Card BASIC" (p. 50–52), the MAT statements. The other CARDBASIC differences of
[M64] §4.2–4.3 (`'` for `"`, `EQU`/`LSS`/… relations, a 5-8 multiple punch for `;`, an unnumbered
data deck after END, the `PAGE` statement, line-printer widths) are artefacts of punched cards and
the line printer, not of the language, and are not implemented (`PAGE` is `ILLEGAL
INSTRUCTION`).

There is exactly **one language level and no `--edition` flag**: every statement, function and
form of every edition up to the Fourth is always accepted. **Baysick decision**, rationale:
every Third and Fourth Edition addition is a text that was an error before (`INPUT`, `ON`,
`A$`, `FNEND`, `IF … GO TO`, `'`, `NUM`, …; §14.1 lists the few error tests whose text became
legal), so every program that compiled before compiles to the same program and prints the same
bytes. Where a later edition **changed the meaning of an already-legal program** — `INT` became
the floor function, `;` packed numbers contiguously, `(-3)↑3` became `-27`, the number format
gained a leading `0`, MAT PRINT printed vectors as columns, MAT INV stopped stopping on singular
matrices, several error texts were reworded — Baysick keeps the earlier meaning that its corpus
already pins, and documents each case in §14.2. A flag selecting the 1968 meanings could not
make 1968 programs print 1968 bytes anyway, because the 1968 *number format* (§14.2, item 4) is
itself different, and no Sea-bootstrap need depends on any of these changes.

**The Third Edition.** No copy of the Third Edition manual (Kemeny and Kurtz, 1966) is publicly
scanned. Its content is known from Kurtz's history [K81] p. 526–527: `INPUT`, `RESTORE`, `SGN`,
the MAT statements in the teletype language with subscripts from 0, the corrected precedence of
unary minus (`-X↑2` = `-(X↑2)`; Baysick already parses it so, §5.1), and `INT` as the floor
function ([K81] p. 523). Every one of these is documented again, in more detail, in [M68], which
is therefore the source of the semantics of all Third Edition features below.

## 0. Sources

| Ref | Source |
|-----|--------|
| [M64] | *BASIC — A Manual for BASIC, the elementary algebraic language designed for use with the Dartmouth Time Sharing System*, Dartmouth College Computation Center, 1 October 1964. Scan: <https://alandix.com/wp-content/uploads/2021/07/BASIC_Oct64.pdf>. Catalog entry: <https://exhibits.library.dartmouth.edu/s/OnSolidGround/item/89>. This is the Second Edition ("version 2") manual, also at <https://www.bitsavers.org/pdf/dartmouth/dtss/196410_BASIC.pdf>; it is the earliest widely available printing and documents the language as implemented in 1964 (the May 1964 First Edition typescript is not publicly scanned). Page numbers below are the manual's own. |
| [M68] | *BASIC*, Fourth Edition, John G. Kemeny and Thomas E. Kurtz, Dartmouth College Computation Center, 1 January 1968. Scan: <https://www.bitsavers.org/pdf/dartmouth/dtss/196801_BASIC_4th_Edition.pdf>. The normative source of every Third and Fourth Edition feature (page numbers are the manual's own; the scan lacks page 26). Used before only for MAT details that [M64]'s one-page summary leaves open. |
| [K81] | Thomas E. Kurtz, "BASIC", in *History of Programming Languages* (R. L. Wexelblat, ed.), Academic Press / ACM, 1981, p. 515–549 (§3.3–3.6, p. 526–531: the Third to Sixth Editions). Primary historical account by the language's co-designer: used for *which edition* introduced a feature, and for the Third Edition, whose manual is not available. |
| [U72] | *User's Guide to the Dartmouth Time-Sharing System*, Dartmouth, September 1972 (<https://www.bitsavers.org/pdf/dartmouth/dtss/197209_Users_Guide_to_the_Dartmouth_Timesharing_System.pdf>), §11.2.3: the Sixth Edition file statements. Used only in `docs/SEA_BOOTSTRAP.md`. |
| [W] | Wikipedia, "Dartmouth BASIC" (edition history; cites [K81]). Secondary source: used only for dates and edition names, not for semantics. |
| [E55] | ECMA-55 *Minimal BASIC* (1978), used only where [M64] is silent, to pick a well-known convention. |

Key facts taken directly from [M64] and therefore *not* Baysick decisions:

* spaces have no significance except inside quoted labels (p. 4–5, "15LETD=A1*A4-A2*A3");
* a number has at most nine digits, optional decimal point and `E` exponent (p. 8);
* a variable is a letter optionally followed by one digit (p. 8);
* `A↑B↑C` means `(A↑B)↑C` (p. 10); `X↑Y` is computed as `|X|↑Y` (p. 9, footnote);
* `LOG(X)` is the natural log of `|X|`, `SQR(X)` the square root of `|X|` (p. 11);
* `INT` chops off the fractional part: `INT(-7.8) = -7` (p. 39);
* `RND` takes an ignored argument and gives the same sequence on every run (p. 39–40);
* lists/tables run from subscript 0 to 10 without `DIM` (p. 38); one letter may name a simple
  variable and a list/table, but not both a list and a table (p. 36);
* FOR: the variable is left at the value of the last passage; a loop not performed leaves it at
  *initial value − step* (p. 29–30);
* print zones are 15 columns, five per line; numbers print with ≤6 significant digits, trailing
  zeros dropped, exact integers without decimal point and up to nine digits in full, numbers
  below 0.1 in `E` form unless all significant digits fit in six decimal places (p. 31–34);
* `;` moves to the next multiple of three columns; a number is not started unless 12 columns
  remain (p. 34–35);
* error message wording and the `<MESSAGE> IN <line>` format (p. 23–24, 53–54);
* a READ with no data left ends the program (p. 7, 27);
* a line typed again replaces the old one; a line number alone deletes the line (p. 21);
* MAT ([M64] §4.4, p. 51–52): `MAT READ A(M,N)`, `MAT PRINT A`, `MAT C = A + B`, `A - B`,
  `A * B`, `ZER(M,N)`, `CON(M,N)`, `IDN(N)`, `TRN(A)`, `INV(A)`, `(K)*A` ("note parentheses");
  dimensions may be formulas; a list in a MAT statement is a column vector and MAT PRINT prints
  vectors as rows; `MAT PRINT A;` prints in the packed format.

Facts taken from [M68] (1968) where [M64] is silent, adopted as Baysick rules: MAT ignores row 0
and column 0 and numbers rows and columns from 1 (p. 54); without DIM a matrix may have up to 10
rows and 10 columns (p. 54); ZER/CON/IDN with or without new dimensions, and `MAT B = A`
(p. 53–58); redimensioning is limited by the storage `(b1+1)·(b2+1)` of the DIM and reinterprets
the stored numbers (p. 55–56); the separator after each matrix in MAT PRINT selects its format
(p. 53, 56); `MAT A = A + B` and `MAT A = (K)*A` are legal (p. 58–59); a dimension mismatch is the
run-time error `DIMENSION ERROR` (p. 73). The Fourth Edition MAT additions `DET`, `NUM` and
`MAT INPUT` are specified in §6, §7.14.6 and §7.14.8. Not adopted from [M68]: the 1968 compile
errors for `MAT A = A * B` / `MAT A = TRN(A)` (Baysick computes them correctly instead,
§7.14.4), and the 1968 meanings listed in §14.2.

Facts taken from [M68] for the Third and Fourth Edition features, and therefore *not* Baysick
decisions (each section below cites its page):

* `INPUT` types a question mark, the user types numbers separated by commas ([M68] p. 50–51);
  its three diagnostics (p. 74); `MAT INPUT V` reads any number of values, a line ending in `&`
  continues on the next line, and `NUM` gives the count (p. 57–58);
* `RESTORE` (p. 52), `RESTORE*` and `RESTORE$` (p. 66–67); numeric and string data are two
  separate blocks (p. 64–66);
* `SGN` (p. 46); `COT` (p. 13); `RND` needs no argument (p. 43); `RANDOMIZE`, also `RANDOM`
  (p. 45); `DET` after `MAT INV` (p. 59–60);
* `ON X GO TO 100, 200, 150`, `ON … THEN`, `IF … GO TO`; an ON value whose integer part is
  out of range is an error (p. 36, 74);
* `LET X = Y3 = A(3,1) = 1` (p. 33); `TAB(n)`: integer part, modulo 75, never moves backwards
  (p. 40–41); `'` starts a remark (p. 52; [K81] p. 529 dates in-line comments to the Fifth
  Edition, but the 1968 manual documents them, so Baysick includes them);
* `DEF` with zero, one or more arguments (p. 46–47); multi-line `DEF` closed by `FNEND`, the
  function name without argument as the result variable, no nesting, no transfers into or out
  of the body (p. 47–48);
* string variables `A$`, `C7$`, string lists `V$( )` but no string tables (p. 63); strings in
  `READ`/`DATA`/`PRINT`/`INPUT`/`MAT READ`/`MAT PRINT`/`MAT INPUT`, `LET` and `IF` (p. 64–66);
  unquoted DATA strings start with a letter (p. 65); comparison in character-code order with
  trailing blanks ignored (p. 65–66); `CHANGE A$ TO A` and `CHANGE A TO A$` with the length in
  element 0 (p. 67–69); the error texts `MISMATCHED STRING OPERATION`, `NO STRING DATA`,
  `INCORRECT NUMBER OF ARGUMENTS`, `UNFINISHED DEF`, `NESTED DEF`, `ON EVALUATED OUT OF RANGE`,
  `OUT OF ROOM` (p. 71–74).

---

## 1. Source files

1.1. A source file is a sequence of bytes. Lines are separated by LF (`0x0A`). A single CR
(`0x0D`) immediately before an LF, or at the very end of the file, is removed. The last line
need not end with LF.

1.2. A *physical line* longer than **255 bytes** (after CR removal) is an error:
`LINE TOO LONG` (no line number). A file larger than **1 048 576 bytes** is an error:
`PROGRAM TOO LONG`.

1.3. Each physical line is first **compacted** (§2). A compacted line that is empty is ignored.

1.4. A non-empty compacted line must start with a decimal digit; the maximal run of digits at
its start is the *line number*. If the line does not start with a digit, or the line number has
more than 5 digits, or its value is 0, the error is `ILLEGAL LINE NUMBER` (no line number in the
message). Valid line numbers are 1–99999. Leading zeros are allowed (`010` is line 10) but count
toward the 5 digits.

1.5. **Editing semantics** ([M64] p. 21). Physical lines are processed in file order:
* number followed by statement text: if a line with that number already exists it is
  **replaced**, otherwise it is added;
* number alone (nothing after the digits): an existing line with that number is **deleted**;
  if none exists, nothing happens. A line whose digits are followed only by a `'` remark (§2.1)
  is *not* a number alone: it is stored with an empty statement text, which is
  `ILLEGAL INSTRUCTION IN n` (§3.1). **Baysick decision:** [M68] p. 52 puts the remark "at the
  end of the line", after a statement; silently deleting a line because it holds only a remark
  would be a trap.

1.6. More than **10 000** stored lines at any moment is `PROGRAM TOO LONG`.

1.7. After all physical lines are processed the program is the set of stored lines **sorted by
line number** ([M64] p. 4). Execution starts at the lowest-numbered line.

## 2. Compaction, case, and characters

2.1. Compaction walks the physical line left to right with a flag *in-string*, initially false:
* `"` toggles in-string and is kept;
* inside a string every byte is kept unchanged;
* outside a string: space (`0x20`) and TAB (`0x09`) are **removed**; ASCII `a`–`z` are converted
  to `A`–`Z`; the UTF-8 sequence `E2 86 91` (U+2191 UPWARDS ARROW `↑`) is replaced by `^`; an
  apostrophe `'` (`0x27`) ends the compaction: it and every byte after it are **removed** (a
  remark, [M68] p. 52: "Everything following the ' is ignored by BASIC"); every other byte is
  kept.

2.2. Hence `G O TO 10`, `GOTO10` and `go to 10` are the same statement, and `PRINT "a  b"` keeps
its lower-case letters and spaces. An unterminated string simply runs to the end of the line
(compaction never fails; the parser reports the error). An apostrophe inside a string is part of
the string ([M68] p. 52: "if the line ended in a string … BASIC will think that the apostrophe
is part of the string"), so `PRINT "IT'S"` prints `IT'S`, and `10 PRINT X ' THE ANSWER` is
`PRINT X`. In a `REM` statement the remark rule changes nothing visible (REM ignores its text).
Unquoted strings in `DATA` (§7.5) are compacted like everything else: `DATA New York` is the
string `NEWYORK`; quote a string to keep its spaces and lower case. **Baysick decision:** [M68]
p. 65 only says that leading blanks of an unquoted DATA string are ignored; keeping the inner
blanks would require a second, uncompacted copy of every DATA line, and [M68] p. 65 already
recommends "If in doubt about the use of strings, it is safest to enclose the string in
quotes". Quoted DATA strings, INPUT and MAT INPUT keep every byte (§7.5, §7.15).

2.3. All further rules in this document apply to the **compacted** text of the line after its
line number (the *statement text*).

## 3. Statements and keyword recognition

3.1. The statement text must begin with one of the twenty-two keywords, tested **in this
order** as a prefix of the statement text:

`LET PRINT END READ DATA GOTO IF FOR NEXT GOSUB RETURN DEF DIM REM STOP MAT INPUT RESTORE ON
RANDOMIZE CHANGE FNEND`

The keyword `RANDOMIZE` also matches the shorter spelling `RANDOM` ([M68] p. 45: "RANDOMIZE (or
more briefly RANDOM)"): the text is tested for `RANDOMIZE` first, then for `RANDOM`. Apart from
that pair no keyword is a prefix of another, so the order only matters for documentation. The
first match determines the statement; the remaining text is parsed by that statement's grammar
(§7). If none matches (including an empty statement text, §1.5): `ILLEGAL INSTRUCTION IN n`.

3.2. `REM` ignores everything after it (including unbalanced quotes).

3.3. **Context keywords.** `THEN`, `TO`, `STEP` and `GOTO` are recognised *only* at a point
where an expression could end (operator position, §5.3). `FN`, the builtin names and `TAB` are
recognised only where an operand (or a PRINT item) may start. Because spaces are gone, this is
the only rule that makes text like `IFX=TTHEN10` (`IF X = T THEN 10`), `FORX=ATOBSTEPC` and
`ONXGOTO10,20` unambiguous.

## 4. Lexical elements

### 4.1 Numeric constants

```
constant  := mantissa [ exponent ]
mantissa  := digits [ "." [ digits ] ] | "." digits
exponent  := "E" [ "+" | "-" ] digits            (only if the E is followed by a digit,
                                                   or by a sign and a digit)
```

* At most **9 digits** in the mantissa (all digits, including leading and trailing zeros:
  `.000123456789` is illegal, [M64] p. 8) → else `ILLEGAL CONSTANT`.
* At most **2 digits** in the exponent → else `ILLEGAL CONSTANT`.
* A `.` immediately after a complete constant (`1.2.3`), or a `.` not followed by a digit and not
  preceded by one, → `ILLEGAL CONSTANT`.
* `E` not followed by a digit (or sign+digit) is **not** part of the constant; it starts the
  next token (the variable `E`): `2*E` is two times E, `1E3` is 1000, `E3` is the variable E3
  ([M64] p. 8).
* The value is the IEEE-754 double nearest to the decimal value (round-half-even), exactly what
  C `strtod` produces. All constants are therefore finite (|value| ≤ 999999999E99).
* Constants are unsigned; a sign in an expression is an operator (§5). In `DATA` a leading sign
  is part of the datum (§7.5).

### 4.2 Variables, lists, tables, functions

* **Simple variable**: a letter, or a letter followed by one digit: `A`, `X0`, `K9`. 286 names.
* **List** (1-D array) / **table** (2-D array): named by a single letter followed by `(`.
  A letter used as an array name is independent of the simple variable with the same letter
  ([M64] p. 36): `A` and `A(3)` are different storage. The same letter may not be used as both a
  list and a table: `ILLEGAL VARIABLE IN n` (reported at the first line, in ascending line order,
  whose use or DIM conflicts with the dimensionality fixed by an earlier line).
* `X1(3)` (letter+digit followed by `(`) → `ILLEGAL VARIABLE IN n`.
* **User function**: `FN` followed by a letter: `FNA` … `FNZ`.
* **Builtin function names** (three letters): `SIN COS TAN COT ATN EXP ABS LOG SQR INT SGN RND`
  (with an argument; `RND` also without) and `NUM DET` (never with an argument).
* All numeric variables and array elements start at **0**.

### 4.3 String constants

`"` … `"` containing any bytes except `"` and LF. No escape sequences. String constants appear
in PRINT (where [M64] calls them labels), in LET, IF and CHANGE statements (§7.1, §7.7, §7.19)
and in DATA (§7.5). Total bytes of all string constants outside DATA statements > **65 536** →
`TOO MANY LABELS IN n` (n = the line whose constant crosses the limit). String constants in DATA
are string data, not labels, and do not count.

### 4.4 String variables and string lists

* **String variable** ([M68] p. 63: "Any ordinary variable followed by a $ (dollar sign) will
  stand for a string. For example A$ or C7$"): a simple-variable name immediately followed by
  `$`: `A$`, `C7$`, `Z9$`. 286 names, independent of the numeric variables (`A` and `A$` are
  different storage).
* **String list** ([M68] p. 63: "A vector variable followed by $, e.g. V$( ), will denote a list
  of strings"): a letter, `$`, `(`: `V$(7)`. String lists are one-dimensional only ("but *not*
  'string' matrices"): a second subscript (`V$(1,2)`, also in DIM and MAT READ) → `ILLEGAL
  VARIABLE IN n`. A string list is independent of the numeric list or table, the numeric
  variable and the string variable of the same letter. Subscripts follow the numeric rules
  (§7.11): bound 10 without DIM, rounded half up, `SUBSCRIPT ERROR` outside `0..bound`.
* `X1$(3)` (letter + digit + `$` + `(`) → `ILLEGAL VARIABLE IN n`, like `X1(3)`.
* A string value is a sequence of **0 to 65 536 bytes** (`LIM_STRING_LEN`); any byte value
  0–255 may occur. All string variables and string list elements start as the **empty string**.
* A **string reference** is a string constant, a string variable or a string list element. The
  Fourth Edition has no string operators and no string-valued functions (the `&`, `SEG$` and
  `LEN` of later editions, `docs/SEA_BOOTSTRAP.md`), so a string reference is the only form of a
  "string expression".

### 4.5 Strings and numbers do not mix

Wherever the grammar needs a numeric expression, a string reference is
`MISMATCHED STRING OPERATION IN n` ([M68] p. 72: "The machine has been asked to combine two
strings algebraically, to compare a string and a number, or to assign a number to a string
variable or vice versa"); wherever it needs a string reference, a numeric expression is the
same error. Precisely, in operand position (§5.2) the text `"`, *letter* [*digit*] `$` or
*letter* `$(` starts a string reference; met where a numeric operand is required (inside any
expression, after a sign or an operator, as a subscript, argument, FOR bound, ON selector, TAB
argument, MAT dimension or scalar), it is `MISMATCHED STRING OPERATION`. Outside PRINT, a
string reference followed by an arithmetic operator `+ - * / ^` is `MISMATCHED STRING OPERATION`
too (`LET A$ = B$ + C$`, `IF A$ + "S" = B$ THEN 10`). In PRINT a string item may be followed
directly by any other item (§7.2), so `PRINT "X" + 1` keeps its Second Edition meaning (the label,
then the number `+1`) and `PRINT A$ - 1` prints A$ and then `-1`; `PRINT A$ * 2` is
`ILLEGAL FORMULA` (an item cannot start with `*`). The individual statements (§7) state where
string references are allowed.

**Baysick decision (string length):** [M68] states no maximum string length; it only warns
(p. 75) that "if the user plans to use strings of more than 60 characters, it is best to add a
vacuous DIM A$(1000) statement, to assure sufficient space", a GE-635 storage-allocation hint.
Baysick allocates string storage as needed (DESIGN.md §6.7) and fixes the maximum at 65 536
bytes: far more than any line of text a program reads or writes (and the same as the longest
input line, §7.15), small enough that a `CHANGE` vector of every string fits a list
(`DIM A(65536)`).

## 5. Expressions

### 5.1 Grammar

```
expression := [ "+" | "-" ] term { ( "+" | "-" ) term }
term       := factor { ( "*" | "/" ) factor }
factor     := primary { "^" primary }                     ("^" also written "↑")
primary    := constant
            | simple-variable
            | letter "(" expression [ "," expression ] ")"          array element
            | "FN" letter [ "(" expression { "," expression } ")" ]  user function (§7.10)
            | builtin "(" expression ")"                             builtin call
            | "RND" | "NUM" | "DET"                                  (bare, see §6)
            | "(" expression ")"
```

* Precedence: `^` highest, then `* /`, then `+ -`; each level is **left-associative**
  ([M64] p. 10: "A↑B↑C means (A↑B)↑C"). So `2^3^2 = 64`.
* A sign is allowed **only at the start of an expression** (which includes the start of a
  parenthesised sub-expression, a function argument and a subscript), as in [E55].
  `-A^2*B` is `-((A^2)*B)`; `2*-3` and `2^-1` are `ILLEGAL FORMULA`; write `2*(-3)`.
  Unary `+` is accepted and has no effect. **Baysick decision:** [M64] does not say whether
  `2*-3` was accepted; the ECMA-55 rule is the conservative choice.
* Nesting depth: each `(` (grouping, subscript list, function argument) increases the depth;
  more than **32** open at once → `FORMULA TOO COMPLEX IN n`.

### 5.2 Operand recognition (operand position)

At a point where an operand is required, the parser looks at the compacted text:

1. `(` → parenthesised expression; the matching `)` is required (`ILLEGAL FORMULA` if missing).
2. digit, or `.` → constant (§4.1).
3. letter:
   1. if the next three characters are a builtin name taking an argument (`SIN COS TAN COT ATN
      EXP ABS LOG SQR INT SGN RND`) and the fourth is `(` → builtin call;
   2. else if they are `RND` (not followed by `(`) → bare `RND`;
   3. else if they are `NUM` or `DET` → that function; if a `(` follows → `ILLEGAL FORMULA`
      (they take no argument);
   4. else if the next characters are `F`,`N`,letter → user function: with an argument list if
      `(` follows, else a call without arguments (§7.10; inside the body of a multi-line DEF of
      that same function, the function's result variable instead);
   5. else if the letter, plus a following digit if any, is followed by `$` → a string
      reference: `MISMATCHED STRING OPERATION` here (§4.5);
   6. else the letter, plus a following digit if any, is a variable name; if the letter (with no
      digit) is followed by `(` it is an array element; a letter+digit followed by `(` is
      `ILLEGAL VARIABLE`.
4. `"` → a string constant: `MISMATCHED STRING OPERATION` (§4.5).
5. anything else (operator, `)`, `,`, end of line, `$`) → `ILLEGAL FORMULA IN n`.

Builtin argument lists contain exactly one expression; a user function's argument list contains
one or more (their number is checked against the DEF after the whole program is read, §7.10); an
array subscript list contains one or two. Anything else before the `)` is `ILLEGAL FORMULA`
(`FNA()` too: an operand is required after the `(`). These recognitions cannot change the
meaning of any program that compiled before: in every case (`NUM`, `DET`, `SGN(`, `COT(`, `FNA`
without `(`, `A$`, `"` in an expression) the text used to be a compile error.

### 5.3 Operator position

After an operand the parser looks for `^ * / + -` to continue the expression. Anything else
ends the expression and is handed back to the statement grammar, which accepts only what it
expects at that point: `)`, `,`, `;`, a relation (`= <> < <= > >=`), the keywords `THEN TO
STEP GOTO`, or end of line. Because a letter cannot follow an operand inside an expression, a
letter in operator position can only begin a context keyword.

### 5.4 Arithmetic

All values are IEEE-754 binary64 ("double"). Operations are the IEEE operations with
round-to-nearest-even, **except**:

| Operation | Rule |
|-----------|------|
| `A / B`   | `B = 0` (either sign) → run-time error `DIVISION BY ZERO`. |
| `A ^ B`   | If `A = 0`: `B < 0` → `ZERO TO A NEGATIVE POWER`; `B = 0` → 1; `B > 0` → 0. Otherwise the result is C `pow(fabs(A), B)` ([M64] p. 9: "works with the absolute value of the left argument"; so `(-2)^3 = 8`). |
| overflow  | If the result of `+ - * / ^` or of any builtin is ±infinity or NaN → run-time error `OVERFLOW`. |
| underflow | Results that underflow become subnormal or zero silently. |
| unary `-` | Exact sign flip (`-0` is a value but prints as `0`). |

**Baysick decision:** [M64] lists no arithmetic run-time errors at all; the GE-225 hardware
substituted values. Because IEEE doubles would otherwise produce `inf`/`nan` that the 1964 number
printer cannot represent, Baysick stops with an error instead. The messages for division and
overflow use 1960s-Dartmouth-style wording.

Comparison (§7.7) uses IEEE ordered comparison; since NaN can never be produced (it would have
raised `OVERFLOW`), all six relations behave as in mathematics.

## 6. Builtin functions

| Function | Result | Errors |
|----------|--------|--------|
| `SIN(X)` `COS(X)` `TAN(X)` | libm `sin cos tan` of X radians | OVERFLOW if not finite |
| `ATN(X)` | libm `atan(X)`, radians in (−π/2, π/2) | — (result always finite) |
| `EXP(X)` | libm `exp(X)` | OVERFLOW (e.g. `EXP(710)`) |
| `ABS(X)` | `|X|` | — |
| `LOG(X)` | libm `log(|X|)` ([M64] p. 11) | `X = 0` → `LOG OF ZERO` |
| `SQR(X)` | libm `sqrt(|X|)` ([M64] p. 11) | — |
| `INT(X)` | X with the fraction chopped off, toward zero: `INT(-7.8) = -7` ([M64] p. 39) (C `trunc`); see §14.2 for the Third Edition's floor | — |
| `RND(X)`, `RND` | next pseudo-random number, see below; the argument is evaluated (for its errors) and ignored | — |
| `COT(X)` | `1 / tan(X)` ([M68] p. 13): libm `tan`, then one IEEE division | `tan(X) = ±0` → `DIVISION BY ZERO`; OVERFLOW if not finite |
| `SGN(X)` | `1` if X > 0, `0` if X = 0 (either sign of zero), `-1` if X < 0 ([M68] p. 46) | — |
| `NUM` | the number of values the most recent `MAT INPUT` accepted (§7.14.8); 0 before the first ([M68] p. 57) | — |
| `DET` | the determinant of the matrix most recently inverted by `MAT … = INV(…)` (§7.14.6); 0 before the first inversion ([M68] p. 59) | OVERFLOW if that determinant is not finite |

**RND generator. Baysick decision** ([M64] only requires a fixed, repeatable sequence in (0,1)):
the Park–Miller "minimal standard" Lehmer generator. State `s` is an integer, initially
`s = 1964` at program start. Each call does

```
s := (16807 * s) mod 2147483647          (exact 64-bit integer arithmetic)
RND := s / 2147483647.0                   (one IEEE division)
```

The first three values are `.015371`, `.340216`, `8.85279E-3` as printed. Values are always
strictly between 0 and 1. The sequence is identical on every run unless the program executes
`RANDOMIZE` (§7.18), which replaces `s` by an unpredictable value; the arithmetic after that is
unchanged.

`LOG OF ZERO` is a **Baysick decision** ([M64] says nothing; `log(0)` is −∞ in IEEE).
Transcendental functions come from the host libm, so results may differ in the last binary
digit between platforms; tests avoid printing values within one ulp of a formatting boundary.

## 7. Statements

Notation: `n` is the line number of the statement. Every statement must consume its whole
statement text; leftover text where the grammar expects end of line → `INCORRECT FORMAT IN n`.

### 7.1 LET
```
LET target { "=" target } "=" value
target     := numeric-target | string-target
numeric-target := simple-variable | letter "(" expression [ "," expression ] ")"
                | "FN" letter                       (only in that function's multi-line DEF body)
string-target  := simple-variable "$" | letter "$" "(" expression ")"
value      := expression          (numeric targets)
            | string-reference    (string targets: "…", A$, A$(i))
```
`LET` is required ([M64] Appendix C). Several targets receive the same value ([M68] p. 33:
`LET X = Y3 = A(3,1) = 1`). Parsing: after `LET` (and after each `=`), if the text there is a
target immediately followed by `=`, it is another target; otherwise the rest is the value. All
targets must be of one kind; a string target among numeric ones, a numeric value for string
targets or a string reference for numeric targets → `MISMATCHED STRING OPERATION`. A missing
value for string targets (`LET A$ =` with nothing after the `=`) → `ILLEGAL FORMULA`; anything
else that is not a string reference there (`LET A$ = 5`, `LET A$ = B`) →
`MISMATCHED STRING OPERATION` (§4.5). Missing or illegal first target → `ILLEGAL VARIABLE`;
missing `=` → `INCORRECT FORMAT`; `LET FNA = …` outside the multi-line body of FNA →
`ILLEGAL VARIABLE`; a string reference followed by more text → `INCORRECT FORMAT`, except an arithmetic operator → `MISMATCHED STRING OPERATION` (§4.5).

**Evaluation order:** the subscripts of every target, targets left to right; then the value;
then the stores, targets left to right (each subscript checked at its store). So
`LET I = A(I) = 5` stores into `A` at the *old* `I`. A string store copies the bytes: after
`LET A$ = B$` the two variables are independent. The `FN` target and simple variables that are
parameters of the enclosing multi-line DEF are that function's local cells (§7.10).

### 7.2 PRINT
```
PRINT [ item-list ]
item-list := element { element }
element   := string-reference | "TAB" "(" expression ")" | expression | "," | ";"
```
Constraints: an expression must be followed by `,`, `;` or end of line (otherwise
`INCORRECT FORMAT`). A string reference or a TAB item may be followed directly by another item
with no separator (`PRINT "X ="X`, [M64] p. 32; `PRINT A$B$`). Consecutive separators are
allowed (`PRINT 1,,3`). An unterminated string constant → `INCORRECT FORMAT`. At the start of an
element, `TAB(` is the TAB item (the name `TAB` is recognised only there); a string reference is
a string item (§4.4); anything else is an expression. Output rules: §8.

### 7.3 END
`END` with nothing after it. Exactly one END, and it must be the **highest-numbered line**
([M64] p. 7, 30). An END on a line that is not the last → `END IS NOT LAST IN n` (this also
catches two ENDs). No END at all → `NO END INSTRUCTION`. A multi-line DEF still open at the END
line (its FNEND missing) → `UNFINISHED DEF IN n`, n = the DEF line (§7.10; checked after
`END IS NOT LAST`). Executing END terminates normally (§10).

### 7.4 READ
```
READ target { "," target }
```
(targets as in §7.1, without the `FN` target). Each numeric target receives the next value of
the **numeric data block**, each string target the next value of the **string data block**
(§7.5; [M68] p. 64: "Numbers will be assigned only to numerical variables, and strings only to
string-variables"). Targets are processed left to right; for array targets the subscripts are
evaluated immediately before that element's value is taken. If the block a target needs has no
value left, the program ends with `OUT OF DATA IN n` on stderr and **exit status 0** (§10). A
program containing a numeric READ target or a numeric MAT READ but no numeric DATA values →
compile error `NO DATA`; a string READ target or a MAT READ of a string list but no string DATA
values → compile error `NO STRING DATA` ([M68] p. 71).

### 7.5 DATA
```
DATA datum { "," datum }
datum := [ "+" | "-" ] constant                 numeric datum
       | '"' { byte except '"' } '"'            string datum (quoted)
       | letter { byte except ',' and '"' }     string datum (unquoted)
```
DATA is not executable. Before the run, all data from all DATA statements, in ascending line
order and left-to-right, form two data blocks ([M64] p. 27; [M68] p. 66: "Numeric and string
DATA are kept in two separate blocks, and these act independently of each other"): the numeric
block of the numeric data and the string block of the string data. A string datum is
recognised "by the fact that [it starts] with a letter. If a string does not start with a
letter, it must be enclosed in quotes" ([M68] p. 65). An unquoted string datum is taken from the
compacted text (§2: no spaces, upper case) and ends before the next `,` or at end of line.
Bad constant → `ILLEGAL CONSTANT`; anything else malformed (empty datum, a sign not followed by
a constant, a `"` inside an unquoted datum, text after a closing quote, an unterminated quote) →
`INCORRECT FORMAT`. More than **100 000** numeric values, or more than **100 000** string values
→ `TOO MUCH DATA IN n`.

### 7.6 GOTO
```
GOTO line-number            (written "GO TO" by convention; spaces are irrelevant)
line-number := digits
```
No digits → `INCORRECT FORMAT`; more than 5 digits → `ILLEGAL LINE NUMBER IN n`. A target that
is not a line of the program → `UNDEFINED NUMBER IN n`. Targets may be any line, including REM,
DATA, DEF and DIM lines (which do nothing when executed, [M64] p. 45; reaching a multi-line DEF
line continues after its FNEND, §7.10), except that a jump between a multi-line DEF body and the
rest of the program → `ILLEGAL TRANSFER IN n` (§7.10).

### 7.7 IF … THEN
```
IF comparison ( "THEN" | "GOTO" ) line-number
comparison := expression relation expression
            | string-reference relation string-reference
relation := "=" | "<>" | "<" | "<=" | ">" | ">="
```
`IF X > 5 GO TO 200` is the same as `IF X > 5 THEN 200` ([M68] p. 36). The comparison is a
string comparison when the text after `IF` starts with a string reference (§4.4); then the right
side must be a string reference too, else `MISMATCHED STRING OPERATION` (likewise a numeric left
side with a string right side). The relation is matched longest-first (`<=`, `<>`, `>=` before
`<`, `>`, `=`). No valid relation after the first operand → `ILLEGAL RELATION IN n`. Missing
`THEN`/`GOTO` → `INCORRECT FORMAT`; the line number as in GOTO (§7.6). Evaluation: left operand,
right operand, compare; if true, jump. `=<`, `=>`, `><` are not relations.

**String comparison** ([M68] p. 65–66: "The relation "<" is interpreted as "earlier in
alphabetic order" … In any comparison trailing blanks in a string are ignored. Thus "YES" =
"YES   ""): remove every trailing space (byte `0x20`) from both strings; then compare them byte
by byte as unsigned numbers (character codes, §7.19); the first differing byte decides; if one
string is a proper prefix of the other, the shorter is smaller; equal length and bytes → equal.
So `"A" < "B"`, `"Z" < "a"`, `"AB" < "ABC"`, `"" = "   "`, `" A" < "A"` (a leading blank counts),
and `"10" < "9"`.

### 7.8 FOR and NEXT
```
FOR simple-variable "=" expression "TO" expression [ "STEP" expression ]
NEXT simple-variable
```
Array elements are not allowed as loop variables (`ILLEGAL VARIABLE`); a string variable or
string list element as loop variable (`FOR A$ = …`, `FOR A$(1) = …`, also `NEXT A$`) →
`MISMATCHED STRING OPERATION`; a string reference as a bound or step →
`MISMATCHED STRING OPERATION` (§4.5). Inside a multi-line DEF body (§7.10) the loop variable may
be one of the function's parameters (its local cell).

**Multi-line functions.** The FOR/NEXT matching below is done separately for the main program
and for each multi-line DEF body (§7.10): a NEXT inside a body can only close a FOR of the same
body, a NEXT outside every body only a FOR outside every body. A FOR of a body still open at its
FNEND → `UNFINISHED DEF IN n` (n = the FNEND line); a NEXT in a body with no FOR of that body open →
`NOT MATCH WITH FOR IN n`.

**Static matching.** FOR and NEXT are paired at compile time, in ascending line order, like
brackets: a NEXT closes the most recent unclosed FOR and must name the same variable, else
`NOT MATCH WITH FOR IN n` (also for a NEXT with no open FOR). An unclosed FOR at the end →
`FOR WITHOUT NEXT` (no line number, as printed in [M64] p. 23). More than **1000** FOR statements
→ `TOO MANY LOOPS IN n`. Loops using the same variable may nest.

**Semantics** (exactly reproducing [M64] p. 29–30). Each FOR statement *k* owns two hidden
cells LIMIT*k* and STEP*k*.

```
FOR v = a TO b STEP c:
    A := value of a;  B := value of b;  C := value of c (1 if STEP omitted)   -- in this order
    LIMITk := B;  STEPk := C
    if exhausted(A, B, C):  v := A - C;  go to the statement after the matching NEXT
    v := A;  continue with the next statement (the loop body)

NEXT v (matching FOR k):
    T := v + STEPk
    if exhausted(T, LIMITk, STEPk):  go to the statement after this NEXT  (v is NOT changed)
    v := T;  go to the statement after FOR k

exhausted(x, limit, step) := (step >= 0 and x > limit) or (step < 0 and x < limit)
```

Consequences (all tested): the limit and step are evaluated once; after normal completion the
variable holds the **last value used** (`FOR X=8 TO 3 STEP -1` leaves 3); a loop that is not
performed leaves *initial − step* (`FOR Z=2 TO -2` leaves 1); `STEP 0` with `a ≤ b` loops forever;
assigning the loop variable in the body changes the next test; jumping out of a loop is allowed.
Jumping into a loop body and reaching its NEXT uses whatever LIMIT*k*/STEP*k* hold (initially 0).
The `v + STEPk` addition is checked for OVERFLOW like any other.

**Baysick decision:** [M64] does not say in which order the three expressions are evaluated;
Baysick uses textual order, all before `v` is assigned.

### 7.9 GOSUB and RETURN
```
GOSUB line-number
RETURN
```
GOSUB pushes the position after itself and jumps (target rules as GOTO). RETURN pops and
continues there. RETURN with nothing pushed → `ILLEGAL RETURN IN n` ([M64] p. 54). More than
**1024** pending GOSUBs → `TOO MANY GOSUBS IN n`.

**Baysick decision:** [M64] p. 43 warns that a GOSUB inside a subroutine "just won't work"
(the 1964 system kept a single return address). Baysick uses a return stack so nested and
repeated GOSUBs work; programs that were valid in 1964 behave identically. [M68] §2.3 (p. 48–49)
allows nested GOSUBs, which agrees.

`GOSUB` or `RETURN` inside a multi-line DEF body → `ILLEGAL TRANSFER IN n` (§7.10).

### 7.10 DEF and FNEND
```
DEF "FN" letter [ "(" parameter { "," parameter } ")" ] "=" expression     single-line
DEF "FN" letter [ "(" parameter { "," parameter } ")" ]                    multi-line header
FNEND                                                                      end of a multi-line body
parameter := simple-variable
```
Defines function FN*x* with 0 to 8 parameters ([M68] p. 46–47: "Each function defined may have
zero, one, two, or more variables", e.g. `DEF FNB(X,Y) = 3*X*Y - Y↑3`, `DEF FNA = 3.1416*R↑2`). A header whose
parameter list (if any) is followed by end of line starts a **multi-line** definition; one
followed by `=` is a **single-line** definition; anything else → `INCORRECT FORMAT`. DEF may
appear anywhere ([M64] p. 41); it is processed at compile time. Parameters must be distinct
simple variables: a missing, string, array or repeated parameter (`DEF FNA()`, `DEF FNA(X$)`,
`DEF FNA(X,X)`) → `ILLEGAL VARIABLE`; more than **8** (`LIM_FN_PARAMS`) → `INCORRECT FORMAT`,
reported as soon as a ninth parameter starts, whatever it is (`DEF FNA(A,B,C,D,E,F,G,H,1)` too);
`DEF FN` not followed by a letter, or a missing `)` → `INCORRECT FORMAT`.

**Calls.** `FNx` without `(` calls FN*x* with no arguments; `FNx(e1, …, ek)` with k arguments.
The arguments are evaluated left to right before the call. After the whole program is read, a
call whose number of arguments differs from the DEF's number of parameters →
`INCORRECT NUMBER OF ARGUMENTS IN n` ([M68] p. 71), n = the line of the call (for calls inside a
single-line DEF, the DEF line). Use of an FN that is never defined → `UNDEFINED FUNCTION IN n`.

**Single-line functions.** Inside the expression each parameter name denotes the corresponding
argument; every other variable is the global one (a parameter does **not** alter the global
variable of the same name). The body may call other FN functions and builtins. A run-time error
inside the expression reports the line of the statement that called it.

**Multi-line functions** ([M68] p. 47–48). The **body** is every line after the DEF line up to
and including the next `FNEND` line. The function's value is computed by executing the body,
starting at its first line, until FNEND is reached; FNEND returns the current value of the
**result variable**, which is `FNx` written without `(` inside the body ([M68] p. 47–48: "The
expression 'FNM' without an argument serves as a temporary variable for the computation of the
function value") and is 0 at the start of every call. In the
body:

* the parameter names denote the function's own copies of the arguments (assignable: `LET`,
  `READ`, `INPUT`, a FOR variable); all other variables are global;
* `LET FNx = e` (also as one target of a multiple LET) assigns the result variable, and `FNx` in an
  expression reads it; `FNx(…)` in its own body is a recursive call (below);
* any statement may appear except: `DEF` → `NESTED DEF IN n` ([M68] p. 72); `GOSUB`, `RETURN` →
  `ILLEGAL TRANSFER IN n`; `END` (§7.3: END must be the last line, and a DEF still open there →
  `UNFINISHED DEF IN n`, n = the DEF line);
* a GOTO, IF or ON in the body may only name lines of the same body, and a statement outside every
  body may only name lines outside every body ([M68] p. 48: "there must not be a transfer
  from inside the DEF to outside its range, nor vice-versa"): otherwise → `ILLEGAL TRANSFER IN n` (n = the line of the
  jump). The DEF line itself belongs to the main program; the FNEND line belongs to the body, so
  `GOTO` the FNEND line returns.
* run-time errors report the body line being executed; after the call returns, the calling
  statement's line is current again.

When the main program reaches a multi-line DEF line it continues at the first line after that
DEF's FNEND (the body is executed only through calls). `FNEND` outside a body →
`ILLEGAL INSTRUCTION IN n`; text after FNEND → `INCORRECT FORMAT IN n`. A DEF whose FNEND is
missing at the end of the program → `UNFINISHED DEF IN n` (n = the DEF line). Outside the body of
FN*x*, `LET FNx = …` → `ILLEGAL VARIABLE`.

Other errors: a second DEF for the same letter → `DUPLICATE FUNCTION IN n`; a function that can
reach itself through calls (in single-line expressions or multi-line bodies) →
`RECURSIVE FUNCTION IN n` (n = its DEF line).

**Baysick decisions:** (a) recursion is rejected for both kinds: [M68] does not say whether a
function may call itself; a single-line function cannot contain a conditional, so its recursion
could never end, and rejecting it for multi-line functions too keeps one rule and gives every
function exactly one activation at a time. (b) A duplicate DEF is rejected rather than silently
replaced. (c) [M68] states the transfer restriction but no message; Baysick reports
`ILLEGAL TRANSFER`. (d) At most 8 parameters: [M68] states no limit; eight cover every example
and fit the argument registers of both targets.

### 7.11 DIM
```
DIM decl { "," decl }
decl := letter "(" integer [ "," integer ] ")"
      | letter "$" "(" integer ")"         string list (§4.4)
integer := digits                          (no sign, point or exponent)
```
A string list is always one-dimensional (`DIM A$(3,4)` → `ILLEGAL VARIABLE`); its storage is
`b1+1` strings; `DIM A$(…)` and `DIM A(…)` declare different arrays, so both may appear. A
second DIM of the same string list → `DUPLICATE DIMENSION`. The `DIM A$(1000)` that [M68] p. 75
recommends for long strings is legal and simply declares a list of 1001 strings.
Sets the upper bound of each subscript (lower bound is always 0). DIM is a compile-time
declaration: it applies to the whole program regardless of where it appears ([M64] p. 38;
Baysick decision for "regardless of position"). Arrays not mentioned in a DIM have bound 10 in
each subscript. The dimensionality (list/table) of a letter is fixed by its first appearance in
ascending line order (DIM or use); a `MAT READ X(e)` / `MAT READ X(e,f)` target counts as a use
as a list / table, every other MAT reference names the whole array and fixes nothing. A letter
whose dimensionality is still unknown after the whole program (it appears only as a bare name in
MAT statements) is a **table with bounds 10, 10** ([M68] p. 54: "matrices up to 10 rows and 10
columns").

The bounds given by DIM (or the default 10) are the *initial* bounds and fix the array's
**storage**: `(b1+1)·(b2+1)` elements for a table, `b1+1` for a list. MAT statements may change
the *current* bounds within that storage (redimensioning, §7.14.3).

Errors: not a single letter → `ILLEGAL VARIABLE`; other syntax → `INCORRECT FORMAT`; bound with
more than 7 digits or more than **1 000 000** elements → `DIMENSION TOO LARGE IN n`; second DIM of
the same letter → `DUPLICATE DIMENSION IN n`; dimensionality conflict → `ILLEGAL VARIABLE IN n`.

**Subscripts at run time:** a subscript value `s` is converted to the integer
`floor(s + 0.5)` (round half up, as [E55]); it must lie in `0..bound`, where *bound* is the
**current** bound (the DIM/default bound until a MAT statement redimensions the array), else
`SUBSCRIPT ERROR IN n`. Elements are stored row-major with the current row length: element
`(i, j)` of a table whose current second bound is `c` is storage element `i·(c+1) + j`; element
`i` of a list is storage element `i`.

### 7.12 REM
`REM` followed by anything. No effect.

### 7.13 STOP
`STOP` with nothing after it. Terminates the run exactly like END ([M64] p. 45).

### 7.14 MAT (matrix statements)

The Second Edition's matrix statements ([M64] §4.4, p. 51–52; details from [M68] §2.6 where
labelled). Every MAT statement operates on whole arrays.

#### 7.14.1 Matrices and vectors

* A **table** whose current bounds (§7.11) are `r, c` is the `r × c` matrix of its elements
  `(i, j)`, `1 ≤ i ≤ r`, `1 ≤ j ≤ c`. Row 0 and column 0 are not part of the matrix: MAT
  statements never read or assign them ([M68] p. 54: "the MAT instructions ignore these").
  **Baysick decision:** [M64] p. 51 says CARDBASIC matrices "must start with component 1
  (not 0)" because CARDBASIC arrays had no element 0; Baysick keeps element 0 (its arrays are
  the teletype language's, [M64] p. 38) and adopts the [M68] convention.
* A **list** whose current bound is `n` is the `n × 1` matrix (column vector) of its elements
  `1 … n` ([M64] p. 52: "MAT READ A(7) will read a 7-component column vector"). Element 0 is not
  part of it. A list can only hold matrices with one column.
* A matrix with a zero dimension (only possible through `DIM X(0)`, `DIM X(0, n)` or
  `DIM X(n, 0)`) cannot be used: a MAT statement that needs its current shape (any operand; the
  target of MAT READ, ZER, CON or IDN without dimensions; a MAT PRINT item) stops with
  `DIMENSION ERROR`.

#### 7.14.2 Grammar and compile-time errors

On the compacted statement text (spaces are insignificant, §2):

```
mat-statement := "MAT" ( mat-read | mat-print | mat-input | mat-assign )
mat-read      := "READ" mat-target { "," mat-target }
mat-target    := name [ "(" expression [ "," expression ] ")" ]
               | sname [ "(" expression ")" ]                 string list (§4.4)
mat-print     := "PRINT" pname { sep pname } [ sep ]         sep := "," | ";"
pname         := name | sname
mat-input     := "INPUT" ( name | sname )                     (§7.14.8)
mat-assign    := name "=" rhs
rhs           := name                                         copy
               | name ( "+" | "-" | "*" ) name                sum, difference, product
               | "(" expression ")" "*" name                  scalar multiple
               | ( "ZER" | "CON" ) [ "(" expression [ "," expression ] ")" ]
               | "IDN" [ "(" expression ")" ]
               | ( "TRN" | "INV" ) "(" name ")"
name          := letter                                       not followed by a digit or "$"
sname         := letter "$"
```

Recognition: after `MAT`, text starting with `READ` is a MAT READ, else text starting with
`PRINT` is a MAT PRINT, else text starting with `INPUT` is a MAT INPUT, else it is an assignment (so `MAT R = …` and `MAT P = …` are
assignments). In `rhs`, the names `ZER`, `CON`, `IDN` are recognised first, then `TRN` and `INV`
when immediately followed by `(`, then `(`, then a name. Only one operation is allowed per
statement ([M68] p. 58: `MAT D = A + B - C` "is illegal"), and the constant multiple needs its
parentheses ([M64] p. 52: "note parentheses").

| Error | When |
|-------|------|
| `ILLEGAL VARIABLE` | a name is required and the text there is not a letter (`MAT = A`, `MAT READ`, `MAT PRINT A,,B`), or is a letter followed by a digit (`MAT C = A1 + B`); a `MAT READ` target's dimensionality conflicts with the letter's (§4.2, e.g. `DIM A(5)` and `MAT READ A(2,2)`) |
| `INCORRECT FORMAT` | `=` missing after the target; a right-hand side not of the forms above (`MAT C = 2*A`, `MAT C = SIN(A)`, `MAT D = A + B - C`, `MAT C = (2)A`, `MAT C = TRN A`, `MAT C = A(1)`, `MAT C =` with an empty right-hand side); `)` missing after the name in TRN/INV; anything other than `,`, `;` or end of line after a MAT PRINT name (`MAT PRINT A(1)`); text left over at the end; `MATRIX = 1` (an assignment to `R` whose `=` is missing) |
| `ILLEGAL FORMULA` | inside a dimension list or IDN's argument list exactly as in a subscript list (§5.2): a missing `)`, a third dimension, a second argument to IDN; inside `( expression )` of the scalar multiple as for a parenthesised expression; any other §5 error in an expression |
| `FORMULA TOO COMPLEX`, `ILLEGAL CONSTANT` | as in any expression (the `(` of a dimension list, of IDN's argument and of the scalar multiple count toward the depth limit, §5.1) |
| `NO DATA` | a numeric MAT READ (or READ) target present, no numeric DATA values (§7.4) |
| `NO STRING DATA` | a string MAT READ (or READ) target present, no string DATA values (§7.4) |
| `MISMATCHED STRING OPERATION` | a string list (`A$`) anywhere in a MAT assignment (`MAT A$ = B$`, `MAT A$ = ZER`, `MAT C = A$ + B`): only MAT READ, MAT PRINT and MAT INPUT handle string lists ([M68] p. 64) |
| `ILLEGAL VARIABLE` (string list) | a string list given two dimensions (`MAT READ A$(2,3)`); a string MAT READ target or MAT INPUT target with digit (`A1$`) |

#### 7.14.3 Dimensions and redimensioning

**Dimension arguments** (MAT READ targets, ZER, CON, IDN) are evaluated left to right when the
statement executes and converted like subscripts (§7.11): `d = floor(x + 0.5)`. A value with
`x < 0.5` (so `d < 1`) → `DIMENSION ERROR`. `ZER(r)` / `CON(r)` / `MAT READ X(r)` mean the shape
`r × 1`; `IDN(n)` means `n × n`.

**Redimensioning** a target X to a shape `r × c` (`r, c ≥ 1`) requires, with *S* the storage of X
(§7.11: `(b1+1)·(b2+1)` elements of the DIM or default bounds):

* X a list: `c = 1` and `r + 1 ≤ S`;
* X a table: `(r + 1)·(c + 1) ≤ S` ([M68] p. 56: "although the zero rows and columns are ignored
  in MAT instructions they play a role in determining dimension limits");

otherwise `DIMENSION ERROR`. The effect is only that the current bounds become `r` (list) or
`r, c` (table, row length `c + 1`). **No stored number is moved, cleared or converted**: the
storage is reinterpreted with the new row length, exactly the "relocation" of [M68] p. 56 (after
`LET M(1,0) = 1` and `MAT READ M(2,2)` on a 10 × 10 table, `M(1,0)` is 0, because it is now
storage element 3). Elements in row 0 and column 0 under the new shape hold whatever that
storage held. Ordinary subscripts are checked against the current bounds afterwards.

Redimensioning happens in: MAT READ with dimensions; ZER, CON, IDN with arguments; and every
assignment of a computed result (copy, `+`, `-`, `*`, `(K)*`, TRN, INV), which gives the target
the result's shape. `ZER`, `CON`, `IDN` and `MAT READ X` without dimensions use X's current
shape. Example ([M68] p. 55): with `DIM M(20,7)` (storage 21·8 = 168), `MAT M = ZER(15,7)` fits
(16·8 = 128) but `MAT M = ZER(16,10)` (17·11 = 187) stops with `DIMENSION ERROR`.

#### 7.14.4 Statements

**MAT READ** `X1, X2, …`: for each target in order: its dimension arguments are evaluated and
the target is redimensioned (if it has them), then its elements receive the next DATA values row
by row — `(1,1) … (1,c), (2,1) …` — or `1 … n` for a list. A string list `X$` (§4.4) is
redimensioned exactly like a numeric list (`X$(r)` needs `r + 1 ≤ b1 + 1` of its DIM, else
`DIMENSION ERROR`; a current bound 0 without dimensions → `DIMENSION ERROR`) and its elements
`1 … n` receive the next values of the **string** data block ([M68] p. 66, the sorting program:
`MAT READ L$(N)`). Running out of data ends the program
exactly like READ (`OUT OF DATA IN n`, exit 0; §7.4); the elements read before stay stored.

**MAT PRINT**: §7.14.5.

**ZER, CON**: dimension arguments (if any) evaluated and the target redimensioned; then every
element of the target's matrix is set to 0 (ZER) or 1 (CON).
**IDN**: the argument (if any) evaluated and the target redimensioned to `n × n`; the target's
current shape must be square (else `DIMENSION ERROR`); then diagonal elements are set to 1 and
the others to 0.

**Assignments with operands**, in this order:

1. The scalar expression of `(K)*A`, if any, is evaluated.
2. Every operand must have a usable shape (§7.14.1) and the operands must conform, else
   `DIMENSION ERROR`:

   | Form | Requirement | Result shape |
   |------|-------------|--------------|
   | `MAT B = A` | — | shape of A |
   | `MAT C = A + B`, `MAT C = A - B` | A and B have the same shape | that shape |
   | `MAT C = A * B` | columns of A = rows of B | rows of A × columns of B |
   | `MAT C = (K)*A` | — | shape of A |
   | `MAT C = TRN(A)` | — | columns of A × rows of A |
   | `MAT C = INV(A)` | A square | shape of A |

   A list operand is `n × 1`, so `MAT W = A * V` (A `m × n`, V a list of n) gives an `m × 1`
   result that fits a list, and `MAT T = TRN(V)` gives a `1 × n` table.
3. The target must be able to take the result shape (§7.14.3), else `DIMENSION ERROR`.
4. The result is computed from the operands' values **as if into a separate temporary**:
   the target may also be an operand (`MAT A = A * A`, `MAT A = TRN(A)`, `MAT B = INV(B)`,
   `MAT A = A + B` all give the mathematically intended result). Element arithmetic: `+`, `-`
   and `(K)*` are one IEEE operation per element (`a + b`, `a − b`, `K·a`); copy and TRN copy
   values exactly; the product is defined in §7.14.7; INV in §7.14.6.
5. If any result element is ±infinity or NaN → `OVERFLOW` (§5.4).
6. The target is redimensioned to the result shape and receives the result.

Only elements of the target's (new) matrix are assigned; row 0, column 0 and scalar variables
are never changed by a MAT statement. A run-time error leaves the program stopped, so a partly
assigned target is never observable.

**Baysick decision (aliasing):** [M64] says nothing; [M68] p. 59 warns that `MAT A = A * B`
"will result in nonsense", and its error list (p. 72) rejects `MAT A = A * B` and
`MAT A = TRN(A)` at compile time (`ILLEGAL MAT MULTIPLE`, `ILLEGAL MAT TRANSPOSE`). Baysick
computes them correctly instead; every program the 1968 system accepted behaves identically.

#### 7.14.5 MAT PRINT layout

MAT PRINT uses the §8 column logic and the §9 number format. Each item is printed **zoned** if
the separator right after it is `,` or there is none, **packed** if it is `;` ([M68] p. 53, 56:
`MAT PRINT A, B; C` prints A and C "in the regular format" and B "closely packed"; [M64] p. 52).
For each item, in order:

1. If it is not the first item of the statement: newline (so one empty line separates two
   matrices of the same statement).
2. If `col ≠ 0`: newline (a matrix always starts on a new line).
3. A table `r × c`: for each row `i = 1 … r`: for each `j = 1 … c`, a §8 number item for element
   `(i, j)` (including the "fewer than 12 columns left" rule), followed — if `j < c` — by the §8
   `,` rule (zoned) or the §8 `;`-after-a-number rule (packed); after the row, newline.
   A list of n elements is printed as **one row** of n numbers ([M64] p. 52: "MAT PRINT prints
   all vectors as row-vectors, for convenience").

   A **string list** `X$` of current bound n is printed as one row of the string items
   `X$(1) … X$(n)` (§8 string item), each followed — if it is not the last — by the §8 `,` rule
   (zoned) or nothing (packed: [M68] p. 64, "MAT PRINT M$; will cause the members of the list to
   be printed without spaces between them"); after the row, newline. A current bound 0 →
   `DIMENSION ERROR`.

A statement therefore always ends at column 0; a trailing separator selects the format of the
last item and does not continue the line. Zoned rows hold five numbers per line and continue on
the next line ([M68] p. 56: "five components to a line"); every row starts on a new line.

Example — the [M68] p. 60 program `MATRIX` (A is `2 × 3`, B is `3 × 3`):

```
40 MAT C = A + A
50 MAT PRINT C;
60 MAT C = A*B
70 PRINT
75 PRINT "A*B =",
80 MAT PRINT C
```

prints (`·` = space; nothing is printed after the last visible character of a line):

```
·2·····4·····6
·8·····10····12

A*B·=
-2·············-2·············-3
-2·············-5·············-9
```

**Baysick decisions:** (a) [M68] p. 60 shows the rows of one matrix on consecutive lines; how
the matrices of one statement were separated is not shown; Baysick separates them with one empty
line. (b) In the same run the packed row reads ` 2  4  6` — a number field that ends exactly on a
multiple of three is followed directly by the next. Baysick applies its §8 `;` rule ("next
multiple of three strictly to the right", which reproduces [M64] p. 35 exactly) to MAT PRINT as
well, so packed fields are spaced as in PRINT. (c) [M68] prints a list as a column unless a
separator follows it; Baysick follows [M64] (always a row).

#### 7.14.6 INV

`MAT C = INV(A)` computes the inverse of the `n × n` matrix A by **Gauss–Jordan elimination with
partial pivoting**, exactly as follows (W is a working copy of A, X starts as the identity; both
`n × n`; all values doubles):

```
m   := max |A(i,j)|                    over all i, j
tol := (n · 2^-52) · m                 (n · 2^-52 is exact; one rounding)
for p = 1 .. n:
    r := p;  best := |W(p,p)|
    for i = p+1 .. n:
        if |W(i,p)| > best:  r := i;  best := |W(i,p)|
    if best <= tol:  stop with SINGULAR MATRIX
    if r ≠ p:  exchange rows p and r of W, and rows p and r of X
    d := W(p,p)
    if d is ±infinity or NaN:  stop with OVERFLOW
    for j = p+1 .. n:  W(p,j) := W(p,j) / d
    for j = 1 .. n:    X(p,j) := X(p,j) / d
    for i = 1 .. n, i ≠ p:
        f := W(i,p)
        for j = p+1 .. n:  W(i,j) := W(i,j) - f·W(p,j)
        for j = 1 .. n:    X(i,j) := X(i,j) - f·X(p,j)
result := X                            (then the §7.14.4 OVERFLOW check)
```

Every operation is one IEEE-754 double operation rounded to nearest: `/` is a true division (not
a multiplication by `1/d`), and `f·W(p,j)` is rounded before the subtraction (**no fused
multiply-add**). Ties in the pivot search go to the smallest row index. Columns `1 … p` of W are
never read after step p. The result is therefore **bit-identical on every target and kernel
variant**, except that the sign of a zero result element is unspecified (an implementation may
skip an update only when that cannot change the status or any finite element of the result, for
example the product `f·y` with an exact zero `y` of a column of X that no pivot row has touched
yet. If `f` is ±infinity or NaN, such a skipped product would be NaN, so the skip is allowed only
because that column is later updated with the same non-finite `f` and the NaN or infinity still
reaches the result and the §7.14.4 OVERFLOW check).

**Baysick decision (singular matrices):** [M64] gives neither the method nor the behaviour for a
singular matrix. [M68] p. 59–60 does not stop and sets `DET` to 0 — but `DET` is not part of the
Second Edition, so a program could not detect the failure; Baysick stops with
`SINGULAR MATRIX IN n` (exit 1). The tolerance is relative to the largest element so that a
singular matrix whose elimination leaves only rounding residue is still reported: for
`1,2,3 / 4,5,6 / 7,8,9` the last pivot is about −7.8·10⁻¹⁶ against `tol` ≈ 6.0·10⁻¹⁵. The price:
an invertible matrix whose pivots fall below `n·2⁻⁵²` times its largest element (e.g.
`1E-20, 0 / 0, 1`) is reported singular too. For the 1968 manual's 4 × 4 Hilbert example
(p. 61–62, test `mat_inv_hilbert`) Baysick prints `16.`, `-120.`, `240.`, … (the exact inverse
is integral; the trailing point shows the computed values are not exactly integers), where the
1968 run shows `16.0001`, `-120.001`, `240.003`, …; the difference reflects the precision of the
1968 machine's arithmetic (an inference: [M68] does not describe its algorithm).

**DET** ([M68] p. 59–60). While inverting, the same elimination computes the determinant of A:

```
det := 1                               before step p = 1
at step p, after the row exchange (if any) and before the divisions:
    if r ≠ p:  det := -det
    det := det · d                       (d = W(p,p), one IEEE multiplication)
```

When `MAT C = INV(A)` completes (no `SINGULAR MATRIX`, no `OVERFLOW`), `det` becomes the value of
the function `DET` (§6); it stays until the next successful inversion. `DET` is 0 before the
first. The value is bit-identical on every target and kernel variant (pinned operations, like
the inverse). If `det` overflowed to ±infinity (or became NaN), the inversion itself still
succeeds, and evaluating `DET` stops with `OVERFLOW`; an underflow to 0 is silent. For
`1,2 / 3,4` the pivots are 3 (after exchanging rows 1 and 2, so `det = -3`) and
`2 − 1·(4/3)` = 0.66666666666666674 (the double nearest 4/3 is slightly low), and
`-3 · 0.66666666666666674` rounds to exactly `-2`, so `PRINT DET` prints `-2`. [M68] p. 59 only
says that DET "will equal the determinant of A"; the product of the pivots is the standard
by-product of the elimination and is pinned here so that it is reproducible.
**Baysick decision (singular matrices and DET):** [M68] p. 59–60: "attempting to invert a
singular matrix will not cause the program to stop, but DET is set equal to 0"; Baysick keeps the
Second Edition behaviour (`SINGULAR MATRIX`, §14.2), so `DET` is never 0 because of a failed
inversion.

#### 7.14.7 Matrix product and reproducibility

`MAT C = A * B` sets `C(i,j) = Σ_k A(i,k)·B(k,j)`. The sum is evaluated in an **unspecified
order** and may use fused multiply-add: each element is the exact sum rounded with at most k
roundings, so `|ĉ − c| ≤ γ_k · Σ_k |A(i,k)·B(k,j)|` with `γ_k = k·u / (1 − k·u)`, `u = 2⁻⁵³`. For
a given target and kernel variant (DESIGN.md §6.6) the result is a deterministic function of the
operand values and shapes — never of addresses, alignment, timing or earlier statements.
Consequently:

* when every product and every partial sum is exactly representable (for example integers with
  `Σ_k |A(i,k)·B(k,j)| ≤ 2⁵³`, or such values scaled by a common power of two), the product is
  exact and identical on every target and variant — the test corpus uses only such products;
* otherwise results may differ in the last bits between targets or variants (and so, rarely,
  in the sixth printed digit or in `16` versus `16.`); whether `OVERFLOW` is raised for a
  product whose partial sums come within a factor k of the overflow threshold may also differ.

**Every other MAT result** (MAT READ, MAT PRINT, ZER, CON, IDN, copy, TRN, `+`, `-`, `(K)*`,
INV) is bit-identical on every target and variant (INV: up to the sign of zero elements).
**Baysick decision:** the product is the only operation whose speed depends on reassociation
(register blocking and FMA), and the only one whose rounding is not a discrete decision; INV's
pivot choices and singularity test are discrete, so INV is pinned.

#### 7.14.8 MAT INPUT

```
MAT INPUT name            numeric list
MAT INPUT letter "$"      string list
```

Reads a list of any length from standard input ([M68] p. 57–58: "The number of components in the
vector need not be specified"). The name must be a list: a letter whose dimensionality is a table
→ `ILLEGAL VARIABLE`; dimensions given (`MAT INPUT V(5)`) → `INCORRECT FORMAT`. A letter used
only in MAT INPUT (and other bare MAT references) is a **list** (MAT INPUT counts as a use as a
list, like a one-dimension MAT READ target, §7.11), so `MAT INPUT V` alone gives a list of bound
10.

Execution (input lines and fields as in §7.15):

1. Read a line. If its last non-blank byte outside quotes is `&`, the line is continued: the
   line's text ends before the `&`, or, if the last non-blank byte before the `&` is a comma,
   before that comma, so blanks between that comma and the `&` are dropped and `1,2,&`,
   `1,2, &` and `1,2 &` all end with the field `2` — and read another line (on a terminal,
   prompting again with `?`), repeatedly ([M68] p. 57: "by ending the line of input with & (before carriage return) the
   machine will ask for more input on the next line"). The fields of all these lines, in order,
   are the input (a field cannot span a line break).
2. If any field is not in correct format for the list's kind (a numeric field, or a string field
   — an unquoted string field may not contain `&`, [M68] p. 65), write
   `INPUT DATA NOT IN CORRECT FORMAT -- RETYPE IT`, discard everything read by this statement and
   start again at step 1. **Nothing is assigned before all fields are good.**
3. Let n be the number of fields (an empty or all-blank line contributes none). If `n = 0`: `NUM`
   becomes 0 and the list is not changed ([M68] p. 58: "zero numbers may be inputted … the user
   can stop by simply pushing 'carriage return'"). Otherwise, if `n + 1` exceeds the list's
   storage (§7.11: `b1 + 1` of its DIM, default 11): `DIMENSION ERROR`. Otherwise the list's
   current bound becomes n, elements `1 … n` receive the fields in order (numbers converted as in
   §7.15), and `NUM` becomes n ([M68] p. 57: "After the input the function NUM will equal the
   number of components and V(1), V(2), …, V(NUM) will be the numbers inputted"). Element 0 is
   not changed.

End of input while a line is needed → `END OF INPUT` (§7.15). `TOO MUCH INPUT` and
`NOT ENOUGH INPUT` never occur in MAT INPUT. **Baysick decisions:** the statement is
transactional (step 2), so a retyped line never leaves a half-assigned list; MAT INPUT of a
table (which [M68] does not describe) is not accepted.

### 7.15 INPUT

```
INPUT target { "," target }
```
(targets as in READ, §7.4). INPUT "acts as a READ statement but does not draw numbers from a DATA
statement" ([M68] p. 50): the values come from **standard input**, one line at a time.

**Terminal or not.** At the first input operation of the run the runtime determines once whether
standard input is a terminal (`isatty(0)`). On a terminal, before reading each line it writes the
prompt: the pending spaces of the output line (§8) and then `?` and a space, to stdout, which is
then flushed ([M68] p. 51: `YOUR VALUES OF X, Y, AND Z ARE?` after a PRINT ending in `;`; without
the `;` "the question mark would have been printed on the next line"); the prompt advances `col`
and `out` by 2. After the line has been read the terminal's cursor is at the start of a new line,
so `col = out = 0`. When standard input is **not** a terminal (a file or a pipe — every test of
the corpus) nothing is written and the column state is unchanged. **Baysick decision:** a program
whose output is piped must not have prompts mixed into it; on a terminal the 1968 dialogue is
reproduced.

**Lines.** A line is the bytes up to the next LF (not included); one CR immediately before the LF
is removed; a last line without LF counts as a line if it is not empty. A line longer than
**65 536** bytes (after CR removal) → run-time error `INPUT LINE TOO LONG` (exit 1). If standard
input is at its end when a line is needed: if `col ≠ 0` a newline is written, stdout is flushed,
`END OF INPUT IN n` is written to stderr and the program ends with **exit status 0** (§10), like
`OUT OF DATA`.

**Fields.** A line is split into fields at every comma that is not inside a quoted string. A line
that is empty or contains only blanks (spaces, `0x20`) has **no** fields. A field is valid for:

* a **numeric** target if, after removing every blank, it is `[ "+" | "-" ] constant` with the
  §4.1 constant syntax (at most 9 mantissa digits and 2 exponent digits; `e` accepted for `E`);
  its value is the double nearest the decimal value (`strtod`), negated for `-`. `1E99`, `-.5`,
  `+ 3` are valid; an empty field, `1/2`, `"3"`, `X`, `1E100`, `1234567890` are not;
* a **string** target if it is (after leading blanks) a **quoted** string — `"`, any bytes but `"`,
  `"`, then only blanks up to the comma or end of line; the value is the bytes between the quotes
  — or an **unquoted** string not containing `"`: the value is the field with its leading blanks
  removed ([M68] p. 65: "leading blanks are ignored unless the string, including the blanks, is
  enclosed in quotes"; "a string containing a comma must be enclosed in quotes"). An unquoted
  field may be empty (`A,,B` gives an empty string as the second value).

**Execution.** The statement reads its first line, then for each target in order: its subscripts
are evaluated (as in READ), then the next field is taken:

* no field left on the current line → write `NOT ENOUGH INPUT -- ADD MORE` to stderr, read a new
  line and take its first field;
* the field is not valid for the target → write `INPUT DATA NOT IN CORRECT FORMAT -- RETYPE IT`
  to stderr, discard the rest of the line, read a new line and take its first field for the same
  target (values already assigned stay assigned);
* otherwise the value is assigned.

After the last target, if fields remain on the current line, `TOO MUCH INPUT -- EXCESS IGNORED`
is written to stderr. The three messages are [M68] p. 74's texts; they are diagnostics, not
errors: the program continues and its exit status is unaffected. Each is one line on stderr
(stdout is flushed first), without `IN n`. Every line ends with LF, so two INPUT statements never
share a line.

Errors: no target → `ILLEGAL VARIABLE`; other syntax as READ.

**Baysick decisions:** (a) the format of numbers typed is the constant format of programs (§4.1)
— [M68] states none; (b) unquoted string fields keep trailing blanks (only leading ones are
mentioned; trailing blanks never print, §8, and never affect comparisons, §7.7); (c) a bad field
does not undo the values the statement already assigned; (d) end of input ends the program
successfully, like `OUT OF DATA`: a program reading until its input ends is the normal case for a
filter, and an interactive user typing end-of-file means "stop".

### 7.16 RESTORE
```
RESTORE        both data blocks
RESTORE*       numeric data block only
RESTORE$       string data block only
```
The next READ (or MAT READ) of the restored block starts again at its first value ([M68] p. 52,
66–67). Anything else after the keyword → `INCORRECT FORMAT`.

### 7.17 ON … GO TO
```
ON expression ( "GOTO" | "THEN" ) line-number { "," line-number }
```
([M68] p. 36.) The expression is evaluated and its integer part `k = trunc(x)` taken; if
`1 ≤ k ≤ N` (N line numbers) the program jumps to the k-th line number, else run-time error
`ON EVALUATED OUT OF RANGE IN n` (exit 1; [M68] p. 74: "The integer part of the variable in the ON
instruction is less than one or greater than the number of line numbers listed. The program
stops."). Each line number follows the GOTO rules (§7.6; `UNDEFINED NUMBER`, `ILLEGAL TRANSFER`).
Missing `GOTO`/`THEN` → `INCORRECT FORMAT`; a missing line number (`ON X GOTO 10,`) →
`INCORRECT FORMAT`. `ON … GOSUB` is not Fourth Edition (`INCORRECT FORMAT`).

### 7.18 RANDOMIZE
`RANDOMIZE` (or `RANDOM`) with nothing after it ([M68] p. 45: it "resets the random numbers in a
random way"). Each execution replaces the RND state (§6) by `s = 1 + (v mod 2147483646)`, where
`v` is 64 bits from the operating system's entropy source (`getentropy`), or, if that fails, the
current time in seconds (`time`). Without RANDOMIZE the sequence is the fixed one ([M68] p. 45:
"If the instruction is absent, then the 'official list' of random numbers is obtained in the
usual order"). Text after the keyword → `INCORRECT FORMAT`.

### 7.19 CHANGE
```
CHANGE string-reference "TO" letter            string to list
CHANGE letter "TO" string-target               list to string
```
([M68] p. 67–69.) The letter names a **numeric list** (CHANGE fixes its dimensionality as a list,
§7.11; a table → `ILLEGAL VARIABLE`); string-target is a string variable or string list element.

* **String to list**: with n the length of the string (bytes): if `n` exceeds the list's current
  bound → `SUBSCRIPT ERROR`; else `L(0) = n` and `L(i)` = the code (0–255) of byte i, for
  `i = 1 … n`. Elements after n are not changed. ([M68] p. 67: "the vector A [has] as its zero
  component the number of characters in the string A$"; `A(1)` is 65 for `A`.)
* **List to string**: `n = floor(L(0) + 0.5)`; `n < 0` or `n` greater than the list's current
  bound → `SUBSCRIPT ERROR`; `n > 65 536` → `STRING TOO LONG`; each code `c = floor(L(i) + 0.5)`,
  `i = 1 … n`, must be in 0–255, else `ILLEGAL CHARACTER`; then the string of those n bytes is
  assigned ([M68] p. 69: "we must give the number of characters which are to be in the string as
  the zero component of the vector"). A string list element target `A$(i)` is a target as in
  §7.1: its subscript i is evaluated before the list is converted, but checked only at the store,
  after the conversion's own checks above, so `CHANGE L TO A$(99)` with an illegal code in L
  gives `ILLEGAL CHARACTER`, not `SUBSCRIPT ERROR`.

Recognition: after `CHANGE`, a string reference (§4.4) starts the first form; else a letter
followed by `TO` starts the second. Errors: `TO` missing → `INCORRECT FORMAT`; a string where the
list must be or a list where the string must be (`CHANGE A TO B`, `CHANGE A$ TO B$`) →
`MISMATCHED STRING OPERATION`; a string constant where the string target must be
(`CHANGE A TO "X"`: not a variable) → `ILLEGAL VARIABLE`; the list name followed by a digit or
`(` → `ILLEGAL VARIABLE`; text left over → `INCORRECT FORMAT`.

**Codes.** A string is a sequence of bytes and the code of a character is its byte value: ASCII
for 0–127 — which is the [M68] p. 68 table (32 = space, 33 = `!`, …, 65 = `A`, …, 90 = `Z`; 128
codes 0–127) — and 128–255 for other bytes. **Baysick decision:** codes up to 255 so that every
byte read from input can be converted and written back unchanged; `ILLEGAL CHARACTER` (a
compile-time message of [M68] p. 71) is reused for a code that is not a byte.

### 7.20 FNEND
See §7.10.

## 8. PRINT output

The runtime keeps two counters for the current output line: `col`, the logical column
(0-based), and `out`, the number of characters physically written on this line. Spaces are
**lazy**: emitting a space only increments `col`; before any non-space character is written,
`col − out` spaces are written first. Consequently Baysick never writes trailing spaces (a
teletype shows none either).

* **emit(c)**: if `c` is a space: `col += 1`. Otherwise write `col − out` spaces, write `c`,
  `col += 1`, `out = col`.
* **newline**: write LF; `col = out = 0`.
* **string item** (a string constant, a string variable or a string list element, §7.2): emit
  each byte of its value — any byte, including control characters, is written unchanged (a byte
  that is not a space counts as one column). Strings are never truncated or wrapped, even past
  column 75. **Baysick decision:** [M64] p. 34 says text past the 75th column "may be lost";
  Baysick keeps it.
* **TAB item** `TAB(x)`: `k = trunc(x)`; `m = k mod 75`, taken in 0 … 74 (`m = k − 75·floor(k/75)`);
  if `col < m` then `col = m`; otherwise nothing ([M68] p. 40–41: the integer part "is treated
  modulo 75, to obtain a value from 0 through 74 … The teletype is then moved forward to this
  position-- unless it has already passed this position, in which case the TAB is ignored").
  Like every space, the movement is lazy. TAB never starts a new line.
* **number item**: format the value as the field *F* (§9). If `75 − col < 12`, do a newline first
  ([M64] p. 34: "BASIC checks to see if there are 12 or more spaces at the end of a line before
  printing a number there"). Then emit every character of *F*.
* **`,`**: `col = (floor(col / 15) + 1) * 15` (the next zone start strictly to the right); if
  then `col >= 75`, newline.
* **`;` after a number** (the element immediately before the `;` in the same PRINT is an
  expression): `col = (floor(col / 3) + 1) * 3` (next multiple of three strictly to the right).
  No newline is forced. Together with the trailing space of *F* this reproduces [M64] p. 35
  exactly (11 three-digit, 8 six-digit or 6 nine-digit numbers per line).
* **`;` anywhere else** (after a string item, after a TAB item, after another separator, or
  first in the list): no movement ([M68] p. 64: "with alphanumeric output the semi-colon causes
  close packing whether that output is in quotes or is the value of a variable"). **Baysick decision:** [M64] defines `;` only after "answers"; packing labels is the
  useful reading.
* **end of the PRINT statement**: if the last element is not `,` or `;`, newline. `PRINT` alone
  prints an empty line.
* The column state persists across PRINT statements (a trailing separator continues the line).
* MAT PRINT (§7.14.5) prints through these same rules.
* **At program termination** (END, STOP, OUT OF DATA, END OF INPUT, or any run-time error): if
  `col ≠ 0`, a newline is written to stdout; then stdout is flushed.
* INPUT on a terminal writes its prompt through this state and resets it after the line is read
  (§7.15). Run-time error text goes to stderr after
  this flush.

**Baysick decision (zones):** "next zone strictly to the right" means a label of exactly 15
characters followed by `,` skips a zone. The 1964 output samples show numbers following labels
with extra blanks that cannot be derived from the manual's rules; Baysick prints the field *F*
directly after the label.

## 9. Number format

Given a double `x` (always finite), the printed field *F* is `sign + body + " "` where `sign` is
`-` if `x < 0` and a space otherwise (so `-0` prints as ` 0 `), and `body` is computed from
`a = |x|`:

1. `a = 0` → body `0`.
2. `a` is an integer (`a == trunc(a)`) and `a < 1 000 000 000` → the decimal digits of `a`, no
   point ([M64] p. 34 rule 4: integers up to nine digits are printed in full).
3. Otherwise round `a` to 6 significant digits, **correctly rounded from the exact binary value,
   ties to even** (exactly what C `snprintf("%.5e", a)` yields). Call the digits
   `d1 d2 d3 d4 d5 d6` (`d1 ≠ 0`) and the decimal exponent `e`, so the rounded value is
   `d1.d2d3d4d5d6 × 10^e`. Let `k` be the number of digits after removing trailing zero digits
   from `d1…d6` (k ≥ 1).
   * **Fixed form** is used if `-1 <= e <= 5`, or if `e < -1` and `e - k + 1 >= -6` (all
     significant digits fall within the first six decimal places, [M64] p. 34 rule 3).
     Fixed form: write the digits `d1…dk` with the decimal point placed after `e+1` digits
     (padding with zeros after the point when `e < -1`); **no leading `0` before the point**;
     trailing zeros after the point are dropped; **the point is kept even when no digit follows
     it** (a non-integer that rounds to a whole number prints as `1.` — [M64] p. 25 shows `1.`).
   * **E form** otherwise (`e >= 6`, or too small): `d1 "." d2d3d4d5d6 "E" s digits(|e|)` with
     **all six digits kept**, `s` = `+` or `-`, exponent without leading zeros, no spaces
     (`1.23457E+9`, `3.45600E-2`). **Baysick decision:** [M64] p. 34 writes `3.45600 E-2` with a
     space; Baysick omits it so a number is one unbroken token, and always writes the exponent
     sign.

Examples (field shown between brackets; `·` = space):

| value | field | value | field |
|-------|-------|-------|-------|
| 0 | `[·0·]` | -0 | `[·0·]` |
| 5 | `[·5·]` | -1234567 | `[-1234567·]` |
| 999999999 | `[·999999999·]` | 1E9 | `[·1.00000E+9·]` |
| .5 | `[·.5·]` | -.5 | `[-.5·]` |
| 1/3 | `[·.333333·]` | 100/3 | `[·33.3333·]` |
| 2.5E6 | `[·2500000·]` | 999999.4 | `[·999999.·]` |
| 999999.5 | `[·1.00000E+6·]` | 1234567.5 | `[·1.23457E+6·]` |
| .9999995 | `[·1.·]` | 123456.5 | `[·123456.·]` (tie → even) |
| 123457.5 | `[·123458.·]` | 1157.625 | `[·1157.62·]` (tie → even) |
| .05 | `[·.05·]` | .012345 | `[·.012345·]` |
| .0123456 | `[·1.23456E-2·]` | .000001 | `[·.000001·]` |
| .0000015 | `[·1.50000E-6·]` | -2.35E-4 | `[-.000235·]` |
| 1E-7 | `[·1.00000E-7·]` | 6.02E23 | `[·6.02000E+23·]` |
| 2^53 | `[·9.00720E+15·]` | SQR(2)*SQR(2) | `[·2.·]` |

## 10. Program termination, streams, exit status

| Event | stdout | stderr | exit status |
|-------|--------|--------|-------------|
| END or STOP executed | pending-line newline (§8), flush | — | 0 |
| READ with no data left | pending-line newline, flush | `OUT OF DATA IN n` + LF | **0** |
| INPUT or MAT INPUT needs a line, stdin at its end | pending-line newline, flush | `END OF INPUT IN n` + LF | **0** |
| any other run-time error | pending-line newline, flush | `<MESSAGE> IN n` + LF | 1 |
| INPUT diagnostic (§7.15), program continues | flush | `<MESSAGE>` + LF | — |

`n` is the line number of the statement being executed (for errors inside a single-line FN
expression, the calling statement; inside a multi-line DEF body, the body line, §7.10).
**Baysick decision:** running out of data is the normal way 1964 programs finished ([M64] p. 7:
"the program is assumed to be done"), so it exits 0, but the message is still written to stderr
so it is visible; running out of input is treated the same way (§7.15).

**Streams.** Programs read standard input only through INPUT and MAT INPUT (§7.15), lazily: a
program that executes neither never reads it, so its behaviour does not depend on stdin. Input is
read with `read(0, …)` into a runtime buffer; bytes after the last line consumed are never
interpreted. Standard output is written only by PRINT, MAT PRINT, the INPUT prompt (terminal
only) and the termination newline; standard error only by BASIC error messages and the three
INPUT diagnostics. A read error on stdin (other than `EINTR`) is treated as end of input.

**Baysick decision:** if writing stdout fails (any `write` error other than `EINTR`, or a write
that transfers 0 bytes), the runtime silently discards all further stdout output and the
program's exit status becomes **1** even after END, STOP or OUT OF DATA (a run-time error
still exits 1 and its stderr message is still written); nothing extra is printed. Rationale:
output was lost, so success must not be reported, and stderr stays reserved for BASIC errors.
(A closed pipe normally raises `SIGPIPE`, which ends the process before this applies.)

### 10.1 Compiler diagnostics

The compiler stops at the **first** error, determined in this order:

1. **Reading** (physical lines in file order): `PROGRAM TOO LONG` (file size), `LINE TOO LONG`,
   `ILLEGAL LINE NUMBER`, `PROGRAM TOO LONG` (line count).
2. **Statements** in ascending line-number order; within a statement, left to right. All
   per-statement errors (syntax, constants, `END IS NOT LAST`, `NOT MATCH WITH FOR`,
   `TOO MANY LOOPS`, `TOO MUCH DATA`, `TOO MANY LABELS`, DIM errors, `DUPLICATE FUNCTION`,
   array dimensionality conflicts, `FORMULA TOO COMPLEX`, MAT syntax errors of §7.14.2,
   `MISMATCHED STRING OPERATION`, `NESTED DEF`, `ILLEGAL TRANSFER` for GOSUB/RETURN in a body,
   `UNFINISHED DEF` at an END or at a FNEND with an open FOR).
3. **Whole program**, in this order: `UNFINISHED DEF` (a DEF still open after the last line;
   reported at the DEF line); `FOR WITHOUT NEXT`; `NO END INSTRUCTION`; `NO DATA`;
   `NO STRING DATA`; `UNDEFINED NUMBER` (first offending reference in ascending line order, a
   line's references left to right); `ILLEGAL TRANSFER` (first jump between a multi-line DEF body
   and the rest of the program, same order); `UNDEFINED FUNCTION` (first reference in ascending
   line order, single-line DEF expressions included at their DEF line);
   `INCORRECT NUMBER OF ARGUMENTS` (first call, same order, whose argument count differs from its
   DEF); `RECURSIVE FUNCTION` (lowest letter A…Z that can reach itself; reported at its DEF
   line).

The message is written to **stderr** as exactly `<MESSAGE> IN <n>` + LF, or `<MESSAGE>` + LF for
messages without a line number, with **no prefix**, and the compiler exits with status **1**
without producing any output file. (Format from [M64] p. 23–24: `ILLEGAL FORMULA IN 70`.)

Command-line, file and toolchain problems are not BASIC errors; they are reported as
`baysick: ...` (see `docs/DESIGN.md` §CLI) with exit status 2, 3 or 4.

## 11. Error messages

Compile-time ("IN n" column says whether a line number is printed):

| Code | Message | IN n | Raised when |
|-----:|---------|:----:|-------------|
| 1 | `ILLEGAL CONSTANT` | yes | >9 mantissa digits, >2 exponent digits, stray `.` (§4.1) |
| 2 | `ILLEGAL FORMULA` | yes | operand expected but not found; missing `)`; wrong builtin argument count; `NUM(`/`DET(`; `FNA()` |
| 3 | `ILLEGAL RELATION` | yes | IF without a valid relation after the first expression |
| 4 | `ILLEGAL LINE NUMBER` | no / yes | bad line number at start of a line (no); jump target with >5 digits (yes) |
| 5 | `ILLEGAL INSTRUCTION` | yes | statement text starts with no keyword (also an empty statement, §1.5); FNEND outside a DEF |
| 6 | `ILLEGAL VARIABLE` | yes | variable required but missing/invalid; `X1(…)`, `X1$(…)`; list/table conflict; two subscripts on a string list; bad or repeated DEF parameter; `LET FNA` outside its body |
| 7 | `INCORRECT FORMAT` | yes | missing `=`, `TO`, `THEN`/`GOTO`, line number, `)` in DEF/DIM; unterminated string; trailing text; > 8 DEF parameters; bad DATA string |
| 8 | `END IS NOT LAST` | yes | END on a line that is not the highest-numbered |
| 9 | `NO END INSTRUCTION` | no | program has no END |
| 10 | `NO DATA` | no | numeric READ/MAT READ target present, no numeric DATA values |
| 11 | `UNDEFINED FUNCTION` | yes | FN letter never DEFined |
| 12 | `UNDEFINED NUMBER` | yes | GOTO/IF/GOSUB target line does not exist |
| 13 | `PROGRAM TOO LONG` | no | file > 1 MiB or > 10 000 lines |
| 14 | `TOO MUCH DATA` | yes | > 100 000 numeric or > 100 000 string DATA values |
| 15 | `TOO MANY LABELS` | yes | > 65 536 bytes of string constants outside DATA |
| 16 | `TOO MANY LOOPS` | yes | > 1000 FOR statements |
| 17 | `NOT MATCH WITH FOR` | yes | NEXT with wrong variable or no open FOR (of the same body, §7.8) |
| 18 | `FOR WITHOUT NEXT` | no | FOR never closed |
| 19 | `DIMENSION TOO LARGE` | yes | DIM bound > 7 digits or > 1 000 000 elements |
| 20 | `LINE TOO LONG` | no | physical line > 255 bytes (Baysick) |
| 21 | `DUPLICATE FUNCTION` | yes | second DEF of a letter (Baysick) |
| 22 | `DUPLICATE DIMENSION` | yes | second DIM of a letter (Baysick) |
| 23 | `RECURSIVE FUNCTION` | yes | FN can reach itself (Baysick) |
| 24 | `FORMULA TOO COMPLEX` | yes | parenthesis depth > 32 (Baysick) |
| 25 | `MISMATCHED STRING OPERATION` | yes | a string where a number is required or vice versa (§4.5) ([M68] p. 72) |
| 26 | `NO STRING DATA` | no | string READ/MAT READ target present, no string DATA values ([M68] p. 71) |
| 27 | `INCORRECT NUMBER OF ARGUMENTS` | yes | FN call with a different number of arguments than its DEF ([M68] p. 71) |
| 28 | `UNFINISHED DEF` | yes | multi-line DEF without FNEND (n = DEF line); FOR open at FNEND (n = FNEND line) ([M68] p. 72) |
| 29 | `NESTED DEF` | yes | DEF inside a multi-line DEF body ([M68] p. 72) |
| 30 | `ILLEGAL TRANSFER` | yes | GOSUB/RETURN in a multi-line DEF body; a jump into or out of a body (Baysick) |

Run-time:

| Code | Message | Exit | Raised when |
|-----:|---------|:----:|-------------|
| 32 | `SUBSCRIPT ERROR` | 1 | rounded subscript outside `0..bound` |
| 33 | `ILLEGAL RETURN` | 1 | RETURN with no pending GOSUB |
| 34 | `OUT OF DATA` | 0 | READ with the data block exhausted |
| 35 | `DIVISION BY ZERO` | 1 | divisor is ±0 (Baysick) |
| 36 | `ZERO TO A NEGATIVE POWER` | 1 | `0 ^ b`, `b < 0` (Baysick) |
| 37 | `LOG OF ZERO` | 1 | `LOG(0)` (Baysick) |
| 38 | `OVERFLOW` | 1 | non-finite arithmetic or builtin result (Baysick) |
| 39 | `TOO MANY GOSUBS` | 1 | 1025th pending GOSUB (Baysick) |
| 40 | `DIMENSION ERROR` | 1 | MAT: operands do not conform, a dimension argument below 1, a result or new shape that does not fit the target's storage, a list given more than one column, a matrix with a zero dimension, IDN of a non-square matrix (§7.14; text from [M68] p. 73) |
| 41 | `SINGULAR MATRIX` | 1 | MAT INV: a pivot not larger than the tolerance (§7.14.6) (Baysick) |
| 42 | `ON EVALUATED OUT OF RANGE` | 1 | ON: integer part below 1 or above the number of line numbers ([M68] p. 74) |
| 43 | `END OF INPUT` | 0 | INPUT/MAT INPUT needs a line, stdin is at its end (§7.15) (Baysick) |
| 44 | `STRING TOO LONG` | 1 | CHANGE list to string with more than 65 536 characters (Baysick) |
| 45 | `ILLEGAL CHARACTER` | 1 | CHANGE list to string: a code outside 0–255 (text from [M68] p. 71) |
| 46 | `INPUT LINE TOO LONG` | 1 | an input line longer than 65 536 bytes (Baysick) |
| 47 | `OUT OF ROOM` | 1 | string storage could not be allocated ([M68] p. 74) |

INPUT diagnostics (stderr, no `IN n`, program continues; [M68] p. 74; §7.15):
`INPUT DATA NOT IN CORRECT FORMAT -- RETYPE IT`, `NOT ENOUGH INPUT -- ADD MORE`,
`TOO MUCH INPUT -- EXCESS IGNORED`.

1964 messages not used by Baysick: `CUT PROGRAM OR DIMS` (storage is not limited the 1964 way).
1968 messages not used by Baysick ([M68] p. 70–74): `ILLEGAL FORMAT`, `NO NUMERIC DATA`,
`UNDEFINED LINE NUMBER`, `NEXT WITHOUT FOR`, `EXPRESSION TOO COMPLICATED`, `RETURN BEFORE GOSUB`,
`GOSUB NESTED TOO DEEPLY` (rewordings of messages Baysick already prints in their 1964 form,
§14.2); `ILLEGAL LINE REFERENCE`, `FORS NESTED TOO DEEPLY`, `TOO MANY CONSTANTS`,
`SYSTEM ERROR`, `USELESS LOOP IN`, `TIME UP -- LOOPING IN` (not applicable); the continuing
arithmetic warnings `ABSOLUTE VALUE RAISED TO POWER`, `UNDERFLOW`, `EXP TOO LARGE`,
`LOG OF NEGATIVE NUMBER`, `SQUARE ROOT OF A NEGATIVE NUMBER` (Baysick keeps its §5.4/§6 rules).
MAT syntax errors use the existing compile-time messages (§7.14.2); the [M68] messages
`ILLEGAL MAT FUNCTION`, `ILLEGAL MAT TRANSPOSE`, `ILLEGAL MAT MULTIPLE` and
`INCORRECT NUMBER OF SUBSCRIPTS` are not used.

## 12. Limits

| Limit | Value | Error |
|-------|-------|-------|
| source file | 1 048 576 bytes | PROGRAM TOO LONG |
| physical line | 255 bytes | LINE TOO LONG |
| program lines | 10 000 | PROGRAM TOO LONG |
| line numbers | 1–99999 | ILLEGAL LINE NUMBER |
| constant | 9 mantissa digits, 2 exponent digits | ILLEGAL CONSTANT |
| DATA values | 100 000 numeric + 100 000 string | TOO MUCH DATA |
| string constant bytes outside DATA (total) | 65 536 | TOO MANY LABELS |
| string length | 65 536 bytes | STRING TOO LONG (CHANGE) |
| input line | 65 536 bytes | INPUT LINE TOO LONG |
| DEF parameters | 8 | INCORRECT FORMAT |
| character codes | 0–255 | ILLEGAL CHARACTER |
| FOR statements | 1000 | TOO MANY LOOPS |
| parenthesis depth | 32 | FORMULA TOO COMPLEX |
| elements per array | 1 000 000 | DIMENSION TOO LARGE |
| MAT matrix shape | within the array's storage (§7.14.3); square matrices up to 999 × 999 | DIMENSION ERROR |
| pending GOSUBs | 1024 | TOO MANY GOSUBS |

The 1964 limits ([M64] Appendix B: 300 data, 26 FORs, 1500 array elements, …) are relaxed
because they reflected GE-225 core memory, not the language.

## 13. Summary of Baysick decisions

1. Exponent operator also spelled `^` and UTF-8 `↑`; lower case folded outside strings.
2. A sign only at the start of an expression (ECMA-55).
3. IEEE doubles; DIVISION BY ZERO, ZERO TO A NEGATIVE POWER, LOG OF ZERO and OVERFLOW are fatal.
4. RND = Park–Miller minimal standard, seed 1964.
5. FOR evaluates initial, limit, step in textual order.
6. GOSUB uses a 1024-deep return stack (nested GOSUB works).
7. DEF: duplicates and recursion are compile errors; DIM position-independent.
8. Subscripts rounded half up.
9. Lazy spaces: no trailing blanks; labels never truncated; `;` after a label does not move.
10. Comma goes to the next zone strictly to the right.
11. Number format details: E form keeps six digits, no space before `E`, signed exponent;
    ties to even.
12. OUT OF DATA exits 0 with a stderr message.
13. First compile error only, in a defined order; messages exactly as in §11.
14. Relaxed storage limits (§12); `LINE TOO LONG`, `DUPLICATE …`, `RECURSIVE FUNCTION`,
    `FORMULA TOO COMPLEX`, `TOO MANY GOSUBS` are Baysick messages.
15. `^` uses `pow(|a|, b)`, so integer powers are exact where IEEE allows (the GE-225 printed
    `4.` for `2↑2`; Baysick prints `4`).
16. One language level, no `--edition` flag: MAT and every Third and Fourth Edition addition are
    always accepted; CARDBASIC card/printer conventions (`PAGE`, `EQU`, `'` for `"`, data decks)
    are not implemented.
17. MAT follows [M68] where [M64] is silent: row/column 0 ignored, default 10 × 10, ZER/CON/IDN
    with or without dimensions, `MAT B = A`, redimensioning within the DIM storage by
    reinterpretation, per-item MAT PRINT format, `DIMENSION ERROR`; letters used only in MAT are
    10 × 10 tables.
18. MAT PRINT prints a list as one row ([M64]), separates the matrices of one statement by an
    empty line, and spaces packed numbers with the §8 `;` rule.
19. MAT results are computed as if into a temporary, so the target may be an operand.
20. INV: pinned Gauss–Jordan with partial pivoting; `SINGULAR MATRIX` (fatal) when a pivot is
    ≤ `n·2⁻⁵²·max|a|`; no `DET`.
21. Matrix product: unspecified summation order, FMA allowed, deterministic per target and
    kernel variant; every other MAT result is bit-identical everywhere.
22. Where the Third or Fourth Edition changed the meaning of an already-legal program, the
    earlier meaning is kept (§14.2).
23. Strings: at most 65 536 bytes, any byte value; storage allocated as needed (`OUT OF ROOM` if
    impossible); comparison by unsigned byte value after removing trailing spaces.
24. Unquoted DATA strings are compacted (spaces removed, upper case); quoted ones are exact.
25. INPUT: prompt `? ` only when stdin is a terminal; number syntax = program constants; unquoted
    strings keep trailing blanks; a bad field keeps earlier values; end of input exits 0 with
    `END OF INPUT IN n`; lines up to 65 536 bytes.
26. MAT INPUT is transactional and accepts lists only.
27. Multi-line DEF: recursion rejected, at most 8 parameters, GOSUB/RETURN and jumps across the
    body boundary are `ILLEGAL TRANSFER`; parameters are local and assignable in the body.
28. CHANGE codes are bytes 0–255; `ILLEGAL CHARACTER` / `STRING TOO LONG` / `SUBSCRIPT ERROR`
    for impossible conversions.
29. RANDOMIZE seeds from `getentropy` (fallback `time`); without it RND is the fixed sequence.
30. `DET` is the pinned product of the INV pivots; a singular matrix still stops the program.

## 14. Edition differences

### 14.1 Texts that were errors and are now programs

Every Third and Fourth Edition addition gives meaning to text that the Second Edition grammar
rejected, so no program that compiled before changes. The error tests whose text became legal:

| Text | Before | Now |
|------|--------|-----|
| `IF X = 1 GOTO 10` | `INCORRECT FORMAT` | IF with GO TO ([M68] p. 36) |

(`tests/errors/c_incorrect_format_if.bas` therefore now uses `IF X = 1` with nothing after the
relation, which is still `INCORRECT FORMAT`; IF … GO TO is tested as a program.) Other texts that
used to be errors and are now legal: a statement starting with `INPUT`, `RESTORE`, `ON`,
`RANDOMIZE`/`RANDOM`, `CHANGE`, `FNEND`; `$` after a variable; `"` in an expression position of
LET or IF; `SGN(`, `COT(`, `NUM`, `DET`; `FNA` without `(`; a DEF with zero or several parameters
or without `=`; a DATA item starting with a letter or `"`; several `=` in LET; `TAB(` in PRINT;
`'` outside a string (formerly kept, so `PRINT 1 'X` was an `INCORRECT FORMAT`).

### 14.2 Meanings changed by later editions (Baysick keeps the earlier one)

| # | Program text | Second Edition (Baysick) | Third/Fourth Edition | Source |
|--:|--------------|--------------------------|----------------------|--------|
| 1 | `INT(-7.8)` | `-7` (truncation, [M64] p. 39) | `-8` (floor) | [K81] p. 523; [M68] p. 42 |
| 2 | `PRINT 1;2;3` | fields advanced to the next multiple of 3 ([M64] p. 34–35, §8) | packed contiguously | [M68] p. 38 |
| 3 | `(-3)^3` | `27` (`|a|^b`, [M64] p. 9) | `-27` (integer powers of negative numbers) | [M68] p. 73 |
| 4 | number format | no leading `0`, integers to 9 digits, `E` form without space (§9) | integers over 8 digits in E form; samples show `0.` | [M68] p. 40–41 |
| 5 | `MAT PRINT V` (V a list) | one row ([M64] p. 52) | a column (a row only with `,` or `;` after it) | [M68] p. 57 |
| 6 | `MAT B = INV(A)`, A singular | stops: `SINGULAR MATRIX` (§7.14.6) | continues, `DET` = 0 | [M68] p. 59–60 |
| 7 | error texts | `INCORRECT FORMAT`, `NO DATA`, `UNDEFINED NUMBER`, `NOT MATCH WITH FOR`, `ILLEGAL RETURN`, `TOO MANY GOSUBS`, `FORMULA TOO COMPLEX` | `ILLEGAL FORMAT`, `NO NUMERIC DATA`, `UNDEFINED LINE NUMBER`, `NEXT WITHOUT FOR`, `RETURN BEFORE GOSUB`, `GOSUB NESTED TOO DEEPLY`, `EXPRESSION TOO COMPLICATED` | [M68] p. 70–73 |
| 8 | `1/0`, `0^-1`, `LOG(0)`, overflow | fatal errors (§5.4) | warning, a substitute value, continue | [M68] p. 73–74 |

**Rationale (Baysick decision).** Each row is a behaviour the existing corpus pins and that
programs written for the earlier editions rely on; the Fourth Edition changed it silently (rows
1–6, 8) or reworded it (row 7). Keeping one meaning per text means a program never changes
behaviour because a later feature exists, and nothing in the Fourth Edition's new features needs
the changed meanings (`docs/SEA_BOOTSTRAP.md`). A program that needs the floor of a negative
number tests `IF X < INT(X)` and subtracts 1; a program wanting contiguous output prints strings
(`CHANGE` builds a string from character codes).
