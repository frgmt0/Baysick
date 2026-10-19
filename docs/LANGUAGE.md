# Baysick Language Specification

**Status: normative.** This document defines the language accepted by Baysick and the exact
observable behaviour of compiled programs (standard output bytes, standard error bytes, exit
status). Where this document and any other document disagree, this one wins for language
behaviour; `docs/IR.md` wins for IR details; `docs/DESIGN.md` wins for module boundaries and ABI.

Baysick implements **Dartmouth BASIC, First Edition** (first run 1 May 1964). Sections marked
**Baysick decision:** are places where the 1964 behaviour is unknown, impractical on a modern
machine, or deliberately extended; each states the choice and why.

## 0. Sources

| Ref | Source |
|-----|--------|
| [M64] | *BASIC — A Manual for BASIC, the elementary algebraic language designed for use with the Dartmouth Time Sharing System*, Dartmouth College Computation Center, 1 October 1964. Scan: <https://alandix.com/wp-content/uploads/2021/07/BASIC_Oct64.pdf>. Catalog entry: <https://exhibits.library.dartmouth.edu/s/OnSolidGround/item/89>. This is the earliest widely available printing of the First Edition manual; it documents the language as implemented in 1964 (the May 1964 typescript is not publicly scanned). Page numbers below are the manual's own. |
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
* a line typed again replaces the old one; a line number alone deletes the line (p. 21).

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

3.1. The statement text must begin with one of the fifteen keywords, tested **in this order** as
a prefix of the statement text:

`LET PRINT END READ DATA GOTO IF FOR NEXT GOSUB RETURN DEF DIM REM STOP`

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
ends with `OUT OF DATA IN n` on stderr and **exit status 0** (§10). A program containing READ but
no DATA values → compile error `NO DATA`.

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
ascending line order (DIM or use).

Errors: not a single letter → `ILLEGAL VARIABLE`; other syntax → `INCORRECT FORMAT`; bound with
more than 7 digits or more than **1 000 000** elements → `DIMENSION TOO LARGE IN n`; second DIM of
the same letter → `DUPLICATE DIMENSION IN n`; dimensionality conflict → `ILLEGAL VARIABLE IN n`.

**Subscripts at run time:** a subscript value `s` is converted to the integer
`floor(s + 0.5)` (round half up, as [E55]); it must lie in `0..bound`, else
`SUBSCRIPT ERROR IN n`. Elements are stored row-major.

### 7.12 REM
`REM` followed by anything. No effect.

### 7.13 STOP
`STOP` with nothing after it. Terminates the run exactly like END ([M64] p. 45).

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
   array dimensionality conflicts, `FORMULA TOO COMPLEX`).
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

1964 messages not used by Baysick: `CUT PROGRAM OR DIMS` (storage is not limited the 1964 way).

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
