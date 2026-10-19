# Baysick Language Specification

**Status: normative.** This document defines the language accepted by Baysick and the exact
observable behaviour of compiled programs (standard output bytes, standard error bytes, exit
status). Where this document and any other document disagree, this one wins for language
behaviour; `docs/IR.md` wins for IR details; `docs/DESIGN.md` wins for module boundaries and ABI.

Baysick implements **Dartmouth BASIC, Second Edition** as documented in the manual of
1 October 1964 ([M64]): the fifteen statements of the First Edition (first run 1 May 1964), the
Second Edition's zero-based subscripts and `;` packing, and the Second Edition's **MAT** matrix
statements (§7.14). Sections marked **Baysick decision:** are places where the 1964 behaviour is
unknown, impractical on a modern machine, or deliberately extended; each states the choice and
why.

**Edition and language level.** [M64] *is* the Second Edition manual (Dartmouth's
"version 2" manual of October 1964, [W]; bitsavers files the same document as
`dartmouth/dtss/196410_BASIC.pdf`). It documents subscripts from 0 (p. 36–38) and the `;`
packed format (p. 34–35) — both Second Edition changes, already part of Baysick — and, in
chapter IV "Card BASIC" (p. 50–52), the MAT statements. There is therefore exactly one language
level and **no `--edition` flag**: MAT is always accepted. **Baysick decision**, rationale: a
statement beginning with `MAT` was `ILLEGAL INSTRUCTION` before, so every program that compiled
before compiles to the same program and prints the same bytes; a flag would only select between
two spellings of the same error. The other CARDBASIC differences of [M64] §4.2–4.3 (`'` for `"`,
`EQU`/`LSS`/… relations, a 5-8 multiple punch for `;`, an unnumbered data deck after END, the
`PAGE` statement, line-printer widths) are artefacts of punched cards and the line printer, not of
the language, and are not implemented (`PAGE` is `ILLEGAL INSTRUCTION`).

## 0. Sources

| Ref | Source |
|-----|--------|
| [M64] | *BASIC — A Manual for BASIC, the elementary algebraic language designed for use with the Dartmouth Time Sharing System*, Dartmouth College Computation Center, 1 October 1964. Scan: <https://alandix.com/wp-content/uploads/2021/07/BASIC_Oct64.pdf>. Catalog entry: <https://exhibits.library.dartmouth.edu/s/OnSolidGround/item/89>. This is the Second Edition ("version 2") manual, also at <https://www.bitsavers.org/pdf/dartmouth/dtss/196410_BASIC.pdf>; it is the earliest widely available printing and documents the language as implemented in 1964 (the May 1964 First Edition typescript is not publicly scanned). Page numbers below are the manual's own. |
| [M68] | *BASIC*, 4th Edition, Dartmouth College Computation Center, January 1968. Scan: <https://www.bitsavers.org/pdf/dartmouth/dtss/196801_BASIC_4th_Edition.pdf>. §2.6 "Matrices" (p. 53–62) and §2.8 "Error Messages" (p. 70–74). Used for MAT details that [M64]'s one-page summary leaves open; every use is labelled. |
| [W] | Wikipedia, "Dartmouth BASIC" (edition history; cites Kurtz, "BASIC", *History of Programming Languages I*, ACM 1981, p. 526, for the October 1964 Second Edition and CARDBASIC's MAT). Secondary source: used only for dates and edition names, not for semantics. |
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
run-time error `DIMENSION ERROR` (p. 73). Not adopted from [M68]: `DET` and `NUM` (they do not
exist in [M64]), `MAT INPUT` (no INPUT in this edition), and the 1968 compile errors for
`MAT A = A * B` / `MAT A = TRN(A)` (Baysick computes them correctly instead, §7.14.4).

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
  if none exists, nothing happens.

1.6. More than **10 000** stored lines at any moment is `PROGRAM TOO LONG`.

1.7. After all physical lines are processed the program is the set of stored lines **sorted by
line number** ([M64] p. 4). Execution starts at the lowest-numbered line.

## 2. Compaction, case, and characters

2.1. Compaction walks the physical line left to right with a flag *in-string*, initially false:
* `"` toggles in-string and is kept;
* inside a string every byte is kept unchanged;
* outside a string: space (`0x20`) and TAB (`0x09`) are **removed**; ASCII `a`–`z` are converted
  to `A`–`Z`; the UTF-8 sequence `E2 86 91` (U+2191 UPWARDS ARROW `↑`) is replaced by `^`; every
  other byte is kept.

2.2. Hence `G O TO 10`, `GOTO10` and `go to 10` are the same statement, and `PRINT "a  b"` keeps
its lower-case letters and spaces. An unterminated string simply runs to the end of the line
(compaction never fails; the parser reports the error).

2.3. All further rules in this document apply to the **compacted** text of the line after its
line number (the *statement text*).

## 3. Statements and keyword recognition

3.1. The statement text must begin with one of the sixteen keywords, tested **in this order** as
a prefix of the statement text:

`LET PRINT END READ DATA GOTO IF FOR NEXT GOSUB RETURN DEF DIM REM STOP MAT`

No keyword is a prefix of another, so the order only matters for documentation. The first match
determines the statement; the remaining text is parsed by that statement's grammar (§7). If none
matches: `ILLEGAL INSTRUCTION IN n`.

3.2. `REM` ignores everything after it (including unbalanced quotes).

3.3. **Context keywords.** `THEN`, `TO` and `STEP` are recognised *only* at a point where an
expression could end (operator position, §5.3). `FN` and the builtin names are recognised only
where an operand may start (operand position). Because spaces are gone, this is the only rule
that makes text like `IFX=TTHEN10` (`IF X = T THEN 10`) and `FORX=ATOBSTEPC` unambiguous.

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
* **Builtin function names** (three letters): `SIN COS TAN ATN EXP ABS LOG SQR INT RND`.
* All variables and array elements start at **0**.

### 4.3 Strings (labels)

`"` … `"` containing any bytes except `"` and LF. No escape sequences. Strings appear only in
PRINT. Total bytes of all string literals in the program > **65 536** → `TOO MANY LABELS IN n`
(n = the line whose literal crosses the limit).

## 5. Expressions

### 5.1 Grammar

```
expression := [ "+" | "-" ] term { ( "+" | "-" ) term }
term       := factor { ( "*" | "/" ) factor }
factor     := primary { "^" primary }                     ("^" also written "↑")
primary    := constant
            | simple-variable
            | letter "(" expression [ "," expression ] ")"          array element
            | "FN" letter "(" expression ")"                         user function
            | builtin "(" expression ")"                             builtin call
            | "RND"                                                  (bare, see §6)
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
   1. if the next three characters are a builtin name and the fourth is `(` → builtin call;
   2. else if they are `RND` (not followed by `(`) → bare `RND`;
   3. else if the next characters are `F`,`N`,letter → user function; it must be followed by
      `(` (else `ILLEGAL FORMULA`);
   4. else the letter, plus a following digit if any, is a variable name; if the letter (with no
      digit) is followed by `(` it is an array element; a letter+digit followed by `(` is
      `ILLEGAL VARIABLE`.
4. anything else (operator, `)`, `,`, end of line, `"`) → `ILLEGAL FORMULA IN n`.

Function argument lists contain exactly one expression; an array subscript list contains one or
two. Anything else before the `)` is `ILLEGAL FORMULA`.

### 5.3 Operator position

After an operand the parser looks for `^ * / + -` to continue the expression. Anything else
ends the expression and is handed back to the statement grammar, which accepts only what it
expects at that point: `)`, `,`, `;`, a relation (`= <> < <= > >=`), the keywords `THEN TO
STEP`, or end of line. Because a letter cannot follow an operand inside an expression, a letter
in operator position can only begin a context keyword.

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
| `INT(X)` | X with the fraction chopped off, toward zero: `INT(-7.8) = -7` ([M64] p. 39) (C `trunc`) | — |
| `RND(X)`, `RND` | next pseudo-random number, see below; the argument is evaluated (for its errors) and ignored | — |

**RND generator. Baysick decision** ([M64] only requires a fixed, repeatable sequence in (0,1)):
the Park–Miller "minimal standard" Lehmer generator. State `s` is an integer, initially
`s = 1964` at program start. Each call does

```
s := (16807 * s) mod 2147483647          (exact 64-bit integer arithmetic)
RND := s / 2147483647.0                   (one IEEE division)
```

The first three values are `.015371`, `.340216`, `8.85279E-3` as printed. Values are always
strictly between 0 and 1. The sequence is identical on every run.

`LOG OF ZERO` is a **Baysick decision** ([M64] says nothing; `log(0)` is −∞ in IEEE).
Transcendental functions come from the host libm, so results may differ in the last binary
digit between platforms; tests avoid printing values within one ulp of a formatting boundary.

## 7. Statements

Notation: `n` is the line number of the statement. Every statement must consume its whole
statement text; leftover text where the grammar expects end of line → `INCORRECT FORMAT IN n`.

### 7.1 LET
```
LET target "=" expression
target := simple-variable | letter "(" expression [ "," expression ] ")"
```
`LET` is required ([M64] Appendix C). Missing/illegal target → `ILLEGAL VARIABLE`; missing
`=` → `INCORRECT FORMAT`. **Evaluation order:** subscripts of the target (left to right), then
the right-hand side, then the store (subscript checked at the store).

### 7.2 PRINT
```
PRINT [ item-list ]
item-list := element { element }
element   := string | expression | "," | ";"
```
Constraints: an expression must be followed by `,`, `;` or end of line (otherwise
`INCORRECT FORMAT`). A string may be followed directly by another item with no separator
(`PRINT "X ="X`, [M64] p. 32). Consecutive separators are allowed (`PRINT 1,,3`). An
unterminated string → `INCORRECT FORMAT`. Output rules: §8.

### 7.3 END
`END` with nothing after it. Exactly one END, and it must be the **highest-numbered line**
([M64] p. 7, 30). An END on a line that is not the last → `END IS NOT LAST IN n` (this also
catches two ENDs). No END at all → `NO END INSTRUCTION`. Executing END terminates normally
(§10).

### 7.4 READ
```
READ target { "," target }
```
Each target receives the next DATA value (§7.5) in order. For array targets the subscripts are
evaluated immediately before that element's value is taken. If no value remains, the program
ends with `OUT OF DATA IN n` on stderr and **exit status 0** (§10). A program containing READ or
MAT READ but no DATA values → compile error `NO DATA`.

### 7.5 DATA
```
DATA datum { "," datum }
datum := [ "+" | "-" ] constant
```
DATA is not executable. Before the run, all data from all DATA statements, in ascending line
order and left-to-right, form one data block ([M64] p. 27). Bad constant → `ILLEGAL CONSTANT`;
anything else malformed (empty datum, variable) → `INCORRECT FORMAT`. More than **100 000** data
values → `TOO MUCH DATA IN n`.

### 7.6 GOTO
```
GOTO line-number            (written "GO TO" by convention; spaces are irrelevant)
line-number := digits
```
No digits → `INCORRECT FORMAT`; more than 5 digits → `ILLEGAL LINE NUMBER IN n`. A target that
is not a line of the program → `UNDEFINED NUMBER IN n`. Targets may be any line, including REM,
DATA, DEF and DIM lines (which do nothing when executed, [M64] p. 45).

### 7.7 IF … THEN
```
IF expression relation expression THEN line-number
relation := "=" | "<>" | "<" | "<=" | ">" | ">="
```
The relation is matched longest-first (`<=`, `<>`, `>=` before `<`, `>`, `=`). No valid relation
after the first expression → `ILLEGAL RELATION IN n`. Missing `THEN` → `INCORRECT FORMAT`.
Evaluation: left expression, right expression, compare; if true, jump. `=<`, `=>`, `><` are not
relations.

### 7.8 FOR and NEXT
```
FOR simple-variable "=" expression "TO" expression [ "STEP" expression ]
NEXT simple-variable
```
Array elements are not allowed as loop variables (`ILLEGAL VARIABLE`).

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
repeated GOSUBs work; programs that were valid in 1964 behave identically.

### 7.10 DEF
```
DEF "FN" letter "(" simple-variable ")" "=" expression
```
Defines function FN*x* of one argument. DEF may appear anywhere ([M64] p. 41); it is processed at
compile time and does nothing when executed. Inside the expression the parameter name denotes the
argument; every other variable is the global one (the parameter does **not** alter the global
variable of the same name). The body may call other FN functions and builtins.

Errors: malformed header → `INCORRECT FORMAT` (parameter not a simple variable →
`ILLEGAL VARIABLE`); a second DEF for the same letter → `DUPLICATE FUNCTION IN n`; use of an FN
that is never defined → `UNDEFINED FUNCTION IN n`; a function that can reach itself through calls
→ `RECURSIVE FUNCTION IN n` (n = its DEF line). **Baysick decision:** since a DEF body cannot
contain a conditional, any recursion would never terminate, so it is rejected; duplicate DEF is
rejected rather than silently replaced.

A run-time error inside a function body reports the line of the statement that called it.

### 7.11 DIM
```
DIM decl { "," decl }
decl := letter "(" integer [ "," integer ] ")"
integer := digits                          (no sign, point or exponent)
```
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
mat-statement := "MAT" ( mat-read | mat-print | mat-assign )
mat-read      := "READ" mat-target { "," mat-target }
mat-target    := name [ "(" expression [ "," expression ] ")" ]
mat-print     := "PRINT" name { sep name } [ sep ]           sep := "," | ";"
mat-assign    := name "=" rhs
rhs           := name                                         copy
               | name ( "+" | "-" | "*" ) name                sum, difference, product
               | "(" expression ")" "*" name                  scalar multiple
               | ( "ZER" | "CON" ) [ "(" expression [ "," expression ] ")" ]
               | "IDN" [ "(" expression ")" ]
               | ( "TRN" | "INV" ) "(" name ")"
name          := letter                                       not followed by a digit
```

Recognition: after `MAT`, text starting with `READ` is a MAT READ, else text starting with
`PRINT` is a MAT PRINT, else it is an assignment (so `MAT R = …` and `MAT P = …` are
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
| `NO DATA` | MAT READ (or READ) present, no DATA values (§7.4) |

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
by row — `(1,1) … (1,c), (2,1) …` — or `1 … n` for a list. Running out of data ends the program
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
skip an update only when its product `f·y` is actually zero, i.e. one factor is zero and the other
is finite. `f = 0` with `y = ±infinity` (or NaN) gives NaN and must not be skipped: it is performed,
and the NaN reaches the §7.14.4 OVERFLOW check like any other non-finite result).

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

## 8. PRINT output

The runtime keeps two counters for the current output line: `col`, the logical column
(0-based), and `out`, the number of characters physically written on this line. Spaces are
**lazy**: emitting a space only increments `col`; before any non-space character is written,
`col − out` spaces are written first. Consequently Baysick never writes trailing spaces (a
teletype shows none either).

* **emit(c)**: if `c` is a space: `col += 1`. Otherwise write `col − out` spaces, write `c`,
  `col += 1`, `out = col`.
* **newline**: write LF; `col = out = 0`.
* **string item**: emit each byte. Strings are never truncated or wrapped, even past column 75.
  **Baysick decision:** [M64] p. 34 says text past the 75th column "may be lost"; Baysick keeps it.
* **number item**: format the value as the field *F* (§9). If `75 − col < 12`, do a newline first
  ([M64] p. 34: "BASIC checks to see if there are 12 or more spaces at the end of a line before
  printing a number there"). Then emit every character of *F*.
* **`,`**: `col = (floor(col / 15) + 1) * 15` (the next zone start strictly to the right); if
  then `col >= 75`, newline.
* **`;` after a number** (the element immediately before the `;` in the same PRINT is an
  expression): `col = (floor(col / 3) + 1) * 3` (next multiple of three strictly to the right).
  No newline is forced. Together with the trailing space of *F* this reproduces [M64] p. 35
  exactly (11 three-digit, 8 six-digit or 6 nine-digit numbers per line).
* **`;` anywhere else** (after a string, after another separator, or first in the list): no
  movement. **Baysick decision:** [M64] defines `;` only after "answers"; packing labels is the
  useful reading.
* **end of the PRINT statement**: if the last element is not `,` or `;`, newline. `PRINT` alone
  prints an empty line.
* The column state persists across PRINT statements (a trailing separator continues the line).
* MAT PRINT (§7.14.5) prints through these same rules.
* **At program termination** (END, STOP, OUT OF DATA, or any run-time error): if `col ≠ 0`, a
  newline is written to stdout; then stdout is flushed. Run-time error text goes to stderr after
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
| any other run-time error | pending-line newline, flush | `<MESSAGE> IN n` + LF | 1 |

`n` is the line number of the statement being executed (for errors inside an FN body, the
calling statement). **Baysick decision:** running out of data is the normal way 1964 programs
finished ([M64] p. 7: "the program is assumed to be done"), so it exits 0, but the message is
still written to stderr so it is visible. Programs never read stdin.

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
   array dimensionality conflicts, `FORMULA TOO COMPLEX`, MAT syntax errors of §7.14.2).
3. **Whole program**, in this order: `FOR WITHOUT NEXT`; `NO END INSTRUCTION`; `NO DATA`;
   `UNDEFINED NUMBER` (first offending reference in ascending line order); `UNDEFINED FUNCTION`
   (first reference in ascending line order, DEF bodies included at their DEF line);
   `RECURSIVE FUNCTION` (lowest letter A…Z that can reach itself; reported at its DEF line).

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
| 2 | `ILLEGAL FORMULA` | yes | operand expected but not found; missing `)`; wrong argument count; FN without `(` |
| 3 | `ILLEGAL RELATION` | yes | IF without a valid relation after the first expression |
| 4 | `ILLEGAL LINE NUMBER` | no / yes | bad line number at start of a line (no); jump target with >5 digits (yes) |
| 5 | `ILLEGAL INSTRUCTION` | yes | statement text starts with no keyword |
| 6 | `ILLEGAL VARIABLE` | yes | variable required but missing/invalid; `X1(…)`; list/table conflict |
| 7 | `INCORRECT FORMAT` | yes | missing `=`, `TO`, `THEN`, line number, `(`/`)` in DEF/DIM; unterminated string; trailing text |
| 8 | `END IS NOT LAST` | yes | END on a line that is not the highest-numbered |
| 9 | `NO END INSTRUCTION` | no | program has no END |
| 10 | `NO DATA` | no | READ present, no DATA values |
| 11 | `UNDEFINED FUNCTION` | yes | FN letter never DEFined |
| 12 | `UNDEFINED NUMBER` | yes | GOTO/IF/GOSUB target line does not exist |
| 13 | `PROGRAM TOO LONG` | no | file > 1 MiB or > 10 000 lines |
| 14 | `TOO MUCH DATA` | yes | > 100 000 DATA values |
| 15 | `TOO MANY LABELS` | yes | > 65 536 bytes of string literals |
| 16 | `TOO MANY LOOPS` | yes | > 1000 FOR statements |
| 17 | `NOT MATCH WITH FOR` | yes | NEXT with wrong variable or no open FOR |
| 18 | `FOR WITHOUT NEXT` | no | FOR never closed |
| 19 | `DIMENSION TOO LARGE` | yes | DIM bound > 7 digits or > 1 000 000 elements |
| 20 | `LINE TOO LONG` | no | physical line > 255 bytes (Baysick) |
| 21 | `DUPLICATE FUNCTION` | yes | second DEF of a letter (Baysick) |
| 22 | `DUPLICATE DIMENSION` | yes | second DIM of a letter (Baysick) |
| 23 | `RECURSIVE FUNCTION` | yes | FN can reach itself (Baysick) |
| 24 | `FORMULA TOO COMPLEX` | yes | parenthesis depth > 32 (Baysick) |

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

1964 messages not used by Baysick: `CUT PROGRAM OR DIMS` (storage is not limited the 1964 way).
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
| DATA values | 100 000 | TOO MUCH DATA |
| string literal bytes (total) | 65 536 | TOO MANY LABELS |
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
16. One language level, no `--edition` flag: MAT is always accepted; CARDBASIC card/printer
    conventions (`PAGE`, `EQU`, `'`, data decks) are not implemented.
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
