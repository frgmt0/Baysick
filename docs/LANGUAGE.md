# Baysick Language Specification

**Status: normative.** This document defines the language accepted by Baysick and the exact
observable behaviour of compiled programs (standard output bytes, standard error bytes, exit
status). Where this document and any other document disagree, this one wins for language
behaviour; `docs/IR.md` wins for IR details; `docs/DESIGN.md` wins for module boundaries and ABI.

Baysick implements **Dartmouth BASIC through the Fourth Edition (1968) and a scoped part of the
Fifth Edition (1970)**, on both targets: the language of the
manual of 1 October 1964 ([M64]) — the fifteen statements of the First Edition (first run 1 May
1964), the Second Edition's zero-based subscripts and `;` packing and its **MAT** matrix
statements (§7.14) — extended by the additions of the **Third Edition** (1966: `INPUT`,
`RESTORE`, `SGN`) and the **Fourth Edition** (1967 supplement and January 1968 manual [M68]:
string variables and lists, `CHANGE`, `ON … GO TO`, `TAB`, `RANDOMIZE`, multiple and multi-line
`DEF`, `MAT INPUT`, `NUM`, `DET`, `COT`, multiple assignment, `'` remarks), and by a scoped part
of the **Fifth Edition** (1970: sequential files with `FILES`, `PRINT #`, `INPUT #`, `IF END #`,
`SCRATCH #`, `RESTORE #`; the functions `LEN`, `ASC`, `STR$`, `VAL`; `DEF` functions with string
arguments and string values; two-dimensional string arrays), and by a scoped part of the **Sixth
Edition** (1971: the string functions `SEG$` and `POS`, the concatenation operator `&`, and
`CALL`/`SUB`/`SUBEND` subprograms with parameters by reference and no shared variables;
"The Sixth Edition" below; **implemented**, DESIGN.md §2.5). Beyond the editions, Baysick specifies
three **Baysick extensions** that belong to no edition — a verbatim line input `LINPUT`, output
to standard error with `PRINT #-1`, and a chosen exit status with `END e` / `STOP e` (§15; "The
Baysick extensions" below; specified, being implemented, DESIGN.md §2.6). Sections marked
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
form of every edition up to the Fourth, and of the Fifth and Sixth Edition parts above, is always
accepted.
**Baysick decision**, rationale: every Third, Fourth, Fifth and Sixth Edition addition is a text
that was an error before (`INPUT`, `ON`, `FILES`, `LEN(`, `DIM A$(3,4)`, `CALL`, `SUB`, `&`, `SEG$(`,
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

**The Fifth Edition.** The Fifth Edition manual (*BASIC*, Fifth Edition, Kiewit Computation
Center, Dartmouth, September 1970) is **not publicly scanned**: bitsavers.org (`pdf/dartmouth/dtss/`
holds the 1964 and 1968 manuals, the 1972 DTSS user's guide and the 1979–1980 DTSS Inc.
documents), archive.org and Dartmouth's digital exhibits were searched without finding it; the
Rauner Library catalogue lists a paper copy among Kurtz's papers ([R70], record found by web
search, not opened). Its content is known only from Kurtz's short summary [K81] p. 528–529
(listed in `docs/SEA_BOOTSTRAP.md` §1): files named by reference number in a `FILES`
statement; sequential ("terminal format") files read and written with `INPUT` and `PRINT`, with
`IF END` for the end-of-file condition; random-access files; `CHAIN`; overlay subprograms;
two-dimensional string arrays; `DEF` functions with string arguments and values; the functions
`CLK$`, `DAT$`, `LEN`, `USR$`, `STR$`, `VAL`, `ASC`, `TIM`; recursive `DEF`; `CHANGE … BIT`. For the *form* of the file statements Baysick also uses the General
Electric MARK II BASIC manual of November 1970 [G70], a contemporaneous dialect of the
Dartmouth-developed language (its preface: "Under this grant, Dartmouth College developed …
the BASIC language compiler", copyright shared with the Trustees of Dartmouth College), which documents `FILES`, `#` file designators, `PRINT #`, `INPUT #`, `IF END #`,
`SCRATCH #`, `RESTORE #`, `LEN`, `ASC`, `STR$` and `VAL` with error texts. **[G70] is not the
Dartmouth Fifth Edition**: every rule taken from it is labelled with its page and with "[G70]",
and is adopted as a **Baysick decision** because the Dartmouth semantics are unknown. Where
[G70] and [K81] say nothing, the rule is Baysick's own, chosen to be the simplest one consistent
with the Fourth Edition and with the Sixth Edition's `FILE #`/`INPUT #`/`PRINT #` [U72], so that a
later Sixth Edition design can extend it. Nothing in §4.4–§4.6, §6, §7.10, §7.11, §7.14 or
§7.21–§7.26 that concerns a Fifth Edition feature is historical fact unless it cites [K81].

The Fifth Edition features that Baysick does **not** implement, each a Baysick decision:

| Feature [K81 p. 528–529] | Decision and reason |
|--------------------------|---------------------|
| random-access files (`READ #`, `WRITE #`, `LOC`, `LOF`, `RESET`) | not implemented. Their record format is not documented in any available source (in [G70] they are binary files of machine words), so no byte-exact behaviour could be specified, and a compiler needs only sequential text files. `READ #1, X`, `WRITE #1, X`, `RESET #1`, `LOC(1)` and `LOF(1)` remain the compile errors they are in the Fourth Edition (a READ with an illegal target, an unknown keyword, the variable `L` followed by `OC(`) |
| `CHAIN` | not implemented: a compiled Baysick program is one executable; starting another program is the operating system's job. `CHAIN` stays `ILLEGAL INSTRUCTION` |
| overlay "subprograms" sharing all variables | not implemented: the Sixth Edition replaced them by `CALL`/`SUB` [K81 p. 530], which is what a later Baysick edition should implement |
| `USR$` | not implemented: it returned the DTSS user number, which does not exist on a Unix host |
| `CHANGE … BIT` | not implemented: its bit-string semantics are not documented anywhere available; `CHANGE A$ TO B BIT 7` stays `INCORRECT FORMAT` |
| recursive `DEF` | not implemented: `RECURSIVE FUNCTION` stays a compile error (§7.10); the Sixth Edition removed recursion again [K81 p. 529], and a function active at most once per activation of its program unit is what lets string parameters and values live without a stack of strings (DESIGN.md §6.8) |
| `TIM`, `CLK$`, `DAT$` | not implemented: their values depend on the clock, so no test can pin their output byte for byte; `TIM` is the variable `T` followed by `IM` (an error, as before) |
| the `FILE` statement (run-time binding of a name to a file number) | not implemented in this edition: [K81] attributes run-time binding to the Sixth Edition (p. 530; [U72] §11.2.3), and a Sixth Edition design adds it on top of §7.21 without changing any program |

**The Sixth Edition.** The Sixth Edition manual (*BASIC*, Sixth Edition, D. G. Mather and S. V. F.
Waite, eds., Kiewit Computation Center, Dartmouth, 1971; switched over on 21 September 1971,
[K81] p. 530) is **not publicly scanned**: bitsavers.org, archive.org, HathiTrust and Dartmouth's
digital collections were searched without finding it, nor Garland's formal specification
(*Dartmouth BASIC, a specification*, Kiewit TM028, 1973, cited by [K81] p. 549). The 1972 DTSS
user's guide [U72] does not describe the language; it refers to the Sixth Edition manual. What is
known comes from the designers' histories [K81] p. 530–531 and [B85] p. 29–37, and from programs of
the period ([C74], [B80]):

* subprograms "connect to the calling program only through the calling sequence. The statements
  used are CALL, SUB, and SUBEND. Parameters are specified by reference" [K81 p. 530]; arguments
  are "matched at each CALL for correct type and number", there are no global variables, and
  subprograms "can be separately compiled and collected into libraries" [K81 p. 530];
* their form: `110 CALL "SUM": a, b, c` and `150 SUB "SUM": x, y, z` … `170 SUBEND` — the name is a
  **quoted string** and a **colon** precedes the arguments [B85 p. 35]; `CALL "SUB1":I,J,K,V1,…`
  and `SUB "SUB1":L,M,N,…` … `SUBEND` after the main program's `END` [C74]; `SUB "DATCON":D$,B$`
  [B80 p. 55]; the internal variables "were distinct from those in the main program" [B85 p. 35];
* "these subprograms could call themselves recursively" [B85 p. 37], while `DEF` functions
  were "prohibited from being recursive" from the Sixth Edition on [K81 p. 529];
* "The SEG$ function provides a substring, while the "&" causes string concatenation. The POS
  function can locate a given string expression in a string" [K81 p. 531]; `SEG$(S$, 5, 6)` is
  "the fifth and sixth characters" [B85 p. 29–30] — the third argument is the **last position**,
  not a length (also `seg$(f$,3,6)` and `seg$(d$,7,8) & b$` in a 1977 program, [B80] p. 56).

Every other detail — argument rounding and ranges of `SEG$` and `POS`, the number of `POS`
arguments, where `&` may appear, how array parameters are written, local `DEF`, `GOSUB` and `FOR`
in a subprogram, placement, limits and every error message — is a **Baysick decision**, chosen as
the simplest rule consistent with the Fifth Edition and with these sources, and labelled so where
it is stated. The Sixth Edition features Baysick does **not** implement, each a Baysick decision:

| Feature [K81 p. 530–531] | Decision and reason |
|--------------------------|---------------------|
| run-time `FILE #n: "name"` (binding names to numbers at run time; `FILES` "dropped completely") | not implemented, deferred again: `FILES` (§7.21) stays, so no program changes meaning; a compiler written in Baysick reads its source on standard input and writes fixed-name files ([B80] p. 55 shows the form `file #1: "dates"`, but its semantics — closing and rebinding a number, the file-type test functions of [K81] p. 530 — are a design of their own that no Sea-bootstrap need requires, `docs/SEA_BOOTSTRAP.md`) |
| image formatting (`PRINT USING`-like images in a string expression, [K81] p. 531) | not implemented: no source gives the image syntax of 1971 ([B85] p. 24–25 shows a later `PRINT USING`), and `STR$`, `SEG$`, `&` and `TAB` build any fixed layout |
| `MAT A = A*B` legal | nothing to do: Baysick has computed `MAT A = A*B` correctly since its Second Edition design (§7.14.4, aliasing decision) |
| separate compilation, libraries (`LIBRARY "file"`, [B80] p. 54), overlays | not implemented: a Baysick program is one source file compiled to one executable; its SUBs live in that file after (or between) the main program's lines (§7.27). Because a SUB connects only through its calling sequence, compiling SUBs separately later would need no language change |
| `CALL A$` (a computed subprogram name) | not implemented: [B85] p. 35 says only that quoted names "paved the way" for it; names are constants |
| removal of `FILES`, the old overlay subprograms, `CHANGE … BIT`, the Fifth Edition items left out above | unchanged: Baysick keeps every earlier statement (one language level), and the items left out of the Fifth Edition stay out |
| the on-line debugger, `MARGIN`, random-access file typing, other "minor changes" [K81 p. 530] | not implemented: not part of the language a program's output depends on, or not documented |

**The Baysick extensions.** Three features that no Dartmouth edition up to the Sixth provides, and
that a compiler written in Baysick needs (`docs/SEA_BOOTSTRAP.md` §2 rows 2 and 17), are specified
as Baysick's own additions in §15, kept apart from the editions: `LINPUT` reads the next line of
standard input or of a file verbatim, with `IF END #` as its end test (§15.2); `PRINT #-1` writes
to standard error with every PRINT rule and its own column state (§15.3); `END e` and `STOP e`
end the program with the exit status e (§15.4). None of them has a historical source (only the
name `LINPUT` is attested, by [W], unverified), so every rule of §15 is a Baysick decision. They
are part of the one language level: always accepted, with no flag. Their run-time error code
(62) follows the codes of every edition (§11).

## 0. Sources

| Ref | Source |
|-----|--------|
| [M64] | *BASIC — A Manual for BASIC, the elementary algebraic language designed for use with the Dartmouth Time Sharing System*, Dartmouth College Computation Center, 1 October 1964. Scan: <https://alandix.com/wp-content/uploads/2021/07/BASIC_Oct64.pdf>. Catalog entry: <https://exhibits.library.dartmouth.edu/s/OnSolidGround/item/89>. This is the Second Edition ("version 2") manual, also at <https://www.bitsavers.org/pdf/dartmouth/dtss/196410_BASIC.pdf>; it is the earliest widely available printing and documents the language as implemented in 1964 (the May 1964 First Edition typescript is not publicly scanned). Page numbers below are the manual's own. |
| [M68] | *BASIC*, Fourth Edition, John G. Kemeny and Thomas E. Kurtz, Dartmouth College Computation Center, 1 January 1968. Scan: <https://www.bitsavers.org/pdf/dartmouth/dtss/196801_BASIC_4th_Edition.pdf>. The normative source of every Third and Fourth Edition feature (page numbers are the manual's own; the scan lacks page 26). Used before only for MAT details that [M64]'s one-page summary leaves open. |
| [K81] | Thomas E. Kurtz, "BASIC", in *History of Programming Languages* (R. L. Wexelblat, ed.), Academic Press / ACM, 1981, p. 515–549 (§3.3–3.6, p. 526–531: the Third to Sixth Editions). Primary historical account by the language's co-designer: used for *which edition* introduced a feature, and for the Third Edition, whose manual is not available. Copy: <https://www.labouseur.com/courses/tpl/History%20of%20BASIC-kurtz.pdf>. |
| [B85] | John G. Kemeny and Thomas E. Kurtz, *Back to BASIC*, Addison-Wesley, 1985, chapter 2 (p. 29–37: `&`, `SEG$`, `POS`; the Fifth and Sixth Edition subprograms, `CALL "SUM": a, b, c`, recursion). Text: <https://archive.org/download/BackToBASIC-KemenyKurtz/BackToBASIC-KemenyKurtz_djvu.txt>. The designers' later account; used for the Sixth Edition only, where [K81] is silent. |
| [B80] | J. Bull, *The Dartmouth Time Sharing System*, Ellis Horwood, 1980, p. 54–56: DTSS library subprograms `SUB "DATCON":D$,B$` … `SUBEND`, and a 1977 program using `call "datcon": d$,f$`, `seg$(f$,3,6)` and `seg$(d$,7,8) & b$`. Text: <https://archive.org/download/bitsavers_dartmouthduthTimeSharingSystem1980_10306903/The_Dartmouth_Time-Sharing_System_1980_djvu.txt>. Period usage only (the program is SBASIC, a later dialect). |
| [C74] | Project CONDUIT, report of 1974 (ERIC ED093340), section on converting FORTRAN to DTSS BASIC: `CALL "SUB1":I,J,K,V1,…` and `SUB "SUB1":L,M,N,…` … `SUBEND` after the main program's `END`. Text: <https://archive.org/download/micro_IA41153119_0227/micro_IA41153119_0227_djvu.txt>. Period usage of the Sixth Edition form. |
| [U72] | *User's Guide to the Dartmouth Time-Sharing System*, Dartmouth, September 1972 (<https://www.bitsavers.org/pdf/dartmouth/dtss/197209_Users_Guide_to_the_Dartmouth_Timesharing_System.pdf>), §11.2.3: the Sixth Edition file statements. Cited in "The Fifth Edition" and §7.22, and in `docs/SEA_BOOTSTRAP.md`. It does not describe the language and refers to the Sixth Edition manual. |
| [R71] | *BASIC*, Sixth Edition, D. G. Mather and S. V. F. Waite (eds.), Kiewit Computation Center, Dartmouth College, 1971. Not scanned anywhere found (see "The Sixth Edition"); cited only to record that it exists and was not available. |
| [G70] | *BASIC Language Reference Manual*, General Electric Information Service Department, publication 711224B, revised November 1970 (the MARK II time-sharing dialect). Scan: <https://www.bitsavers.org/pdf/ge/MarkI_Timesharing/711224B_BASICLanguageReferenceManual_Nov1970.pdf> (mirror: <https://ftp.mirrorservice.org/sites/www.bitsavers.org/pdf/ge/MarkI_Timesharing/711224B_BASICLanguageReferenceManual_Nov1970.pdf>). Page numbers are the manual's own. Not a Dartmouth manual: used only for the form of the Fifth Edition file statements and functions and for error texts, each use a Baysick decision (see "The Fifth Edition" above). |
| [R70] | *BASIC*, Fifth Edition, Kiewit Computation Center, Dartmouth College, September 1970. Not scanned; a paper copy is listed in the Rauner Special Collections Library catalogue (<https://archives-manuscripts.dartmouth.edu/repositories/2/archival_objects/412980>, found by web search; the page itself could not be opened, so the listing is **unverified**). Cited only to record that the manual exists and was not available. |
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

Facts taken from [K81] p. 528–529 for the Fifth Edition (the *existence* of each feature; every
detail of syntax and semantics is a Baysick decision, §4.4–§4.6, §6, §7.10–§7.11, §7.14,
§7.21–§7.26):

* files are named by reference number in a `FILES` statement; sequential files are read with
  `INPUT` and written with `PRINT`; `IF END` tests for the end of a file;
* string arrays may have two dimensions; `DEF` functions may have string arguments and string
  values;
* `LEN`, `ASC`, `STR$` ("the printed form of a number but without leading or trailing spaces")
  and `VAL` exist.

Forms adopted from [G70] (each a Baysick decision): `FILES name; name; …` with names separated by
`;` and at most eight files (p. 60, `TOO MANY FILES`, p. 86); a file designator `#` followed by
an expression whose integer part (truncated) selects the file (p. 60); designator 0 is the
terminal (p. 71: `PRINT #0`); files start in read mode, `SCRATCH #n` empties a file and puts it
in write mode, `RESTORE #n` puts it back in read mode at its beginning (p. 62, 74–75); `PRINT #`
writes like PRINT (p. 71); `INPUT #` reads line by line, takes missing items from the next line
and ignores excess items silently (p. 65); `IF END #n THEN line` (p. 78); the run-time error texts
`CAN'T OPEN FILE`, `CAN'T WRITE FILE`, `ILLEGAL FILE COMMAND`, `INVALID FILE NUMBER`,
`INCORRECT FORMAT IN FILE` and `ILLEGAL 'VAL' ARGUMENT` (p. 87–88, without the file name).

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
line number** ([M64] p. 4). Execution starts at the lowest-numbered line of the main program
(Sixth Edition: SUB blocks, §7.27, are not part of it; without them this is the lowest line).

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

3.1. The statement text must begin with one of the twenty-eight keywords, tested **in this
order** as a prefix of the statement text:

`LET PRINT END READ DATA GOTO IF FOR NEXT GOSUB RETURN DEF DIM REM STOP MAT INPUT RESTORE ON
RANDOMIZE CHANGE FNEND FILES SCRATCH CALL SUBEND SUB LINPUT`

(`FILES` and `SCRATCH` are the Fifth Edition keywords, §7.21–§7.22; the other file statements
start with `PRINT`, `INPUT`, `IF` and `RESTORE`. `CALL`, `SUBEND` and `SUB` are the Sixth Edition
keywords, §7.27. `LINPUT` is the keyword of a Baysick extension, §15.2; no other keyword is a
prefix of it — `LET` is not, `L` being followed by `E` — and it is a prefix of none.)

The keyword `RANDOMIZE` also matches the shorter spelling `RANDOM` ([M68] p. 45: "RANDOMIZE (or
more briefly RANDOM)"): the text is tested for `RANDOMIZE` first, then for `RANDOM`. Likewise
`SUB` is a prefix of `SUBEND`, which is tested first. Apart from these two pairs no keyword is a
prefix of another, so the order only matters for documentation. The
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
  (with an argument; `RND` also without) and `NUM DET` (never with an argument); Fifth Edition:
  `LEN ASC VAL` (a string argument, a numeric value) and `STR$` (a numeric argument, a string
  value), always with an argument (§6).
* **String function** (Fifth Edition): `FN` followed by a letter and `$`: `FNA$` … `FNZ$`
  (§7.10). A letter names at most one function, numeric or string.
* All numeric variables and array elements start at **0**.

### 4.3 String constants

`"` … `"` containing any bytes except `"` and LF. No escape sequences. String constants appear
in PRINT (where [M64] calls them labels), in LET, IF and CHANGE statements (§7.1, §7.7, §7.19)
and in DATA (§7.5); in the Fifth Edition in every string expression (§4.6). `""` is the empty
string. Total bytes of all string constants outside DATA statements > **65 536** →
`TOO MANY LABELS IN n` (n = the line whose constant crosses the limit). String constants in DATA
are string data, not labels, and do not count.

### 4.4 String variables and string lists

* **String variable** ([M68] p. 63: "Any ordinary variable followed by a $ (dollar sign) will
  stand for a string. For example A$ or C7$"): a simple-variable name immediately followed by
  `$`: `A$`, `C7$`, `Z9$`. 286 names, independent of the numeric variables (`A` and `A$` are
  different storage).
* **String list** ([M68] p. 63: "A vector variable followed by $, e.g. V$( ), will denote a list
  of strings"): a letter, `$`, `(`: `V$(7)`. In the Fourth Edition string arrays were
  one-dimensional only ([M68] p. 63: "but *not* 'string' matrices").
* **String table** (Fifth Edition, [K81] p. 529: two-dimensional string arrays): a letter, `$`,
  `(` with two subscripts: `T$(2,3)`. A letter's string array is a list or a table, never both:
  the rule of §4.2 for numeric arrays applies to the string arrays separately (`ILLEGAL VARIABLE
  IN n` at the first conflicting line, in ascending line order, DIM or use). A string array is
  independent of the numeric array, the numeric variable and the string variable of the same
  letter. Subscripts follow the numeric rules (§7.11): bounds 10 (and 10, 10) without DIM,
  rounded half up, `SUBSCRIPT ERROR` outside `0..bound`; element `(i, j)` of a table whose
  current second bound is `c` is storage element `i·(c+1) + j`. A string array whose
  dimensionality is still unknown after the whole program (it appears only as a bare name in
  MAT READ or MAT PRINT, or — Sixth Edition — as `L$()` in CALL arguments) is a **list** with
  bound 10 — unlike a numeric array, which becomes a
  table (§7.11) — so every Fourth Edition program keeps its meaning (**Baysick decision**).
* `X1$(3)` (letter + digit + `$` + `(`) → `ILLEGAL VARIABLE IN n`, like `X1(3)`.
* A string value is a sequence of **0 to 65 536 bytes** (`LIM_STRING_LEN`); any byte value
  0–255 may occur. All string variables and string list elements start as the **empty string**.
* A **string reference** is a string constant, a string variable or a string array element
  (list or table). In the Fourth Edition it is the only form of a "string expression"; the
  Fifth Edition adds the string-valued functions of §4.6, and the Sixth Edition the function
  `SEG$` and the concatenation operator `&` (§4.6, §6.2).

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

**Fifth Edition: string expressions.** Everything above applies with "string reference" read as
"string expression" (§4.6): in operand position the text `STR$(` and `FN` *letter* `$` (Sixth
Edition: also `SEG$(`) also start a string expression, so `LET X = STR$(5)`, `LET X = 1 + FNA$(2)` and `IF LEN(A$) = FNB$ THEN 10`
are `MISMATCHED STRING OPERATION`; a string expression followed by an arithmetic operator outside
PRINT is the same error (`LET A$ = STR$(1) + "X"`). Conversely `LEN`, `ASC` and `VAL` need a
string expression as argument: `LEN(5)`, `ASC(X)`, `VAL(A$ + 1)` are
`MISMATCHED STRING OPERATION`.

**Sixth Edition: `&`.** `&` joins two string expressions (§4.6). Its operands must be string
operands: a numeric operand after `&` (`A$ & 1`, `A$ & X`, `A$ & (1)`) is
`MISMATCHED STRING OPERATION`; anything else that cannot start an operand (`A$ &`, `A$ & )`) is
`ILLEGAL FORMULA`. `&` is recognised only right after a string operand (the scanner's operator
position after a string, §5.3): after a numeric operand it is not an operator, and the statement
grammar sees it as leftover text (`LET X = 1 & 2` → `INCORRECT FORMAT`, `PRINT 1 & "A"` →
`INCORRECT FORMAT` (§7.2), `IF X & Y = 1 THEN 10` → `ILLEGAL RELATION`). A string expression
containing `&` is still a string expression, so the rules above apply to it as a whole
(`LET X = A$ & B$` and `LET A$ = B$ & C$ + D$` are `MISMATCHED STRING OPERATION`).

### 4.6 String expressions (Fifth and Sixth Editions)

```
string-expression := string-primary { "&" string-primary }             Sixth Edition: &
string-primary    := string-reference
                   | "STR$" "(" expression ")"                         §6
                   | "SEG$" "(" string-expression "," expression "," expression ")"   §6.2, Sixth Edition
                   | "FN" letter "$" [ "(" argument { "," argument } ")" ]   §7.10
string-reference  := string-constant | string-variable
                   | letter "$" "(" expression [ "," expression ] ")"  list or table element
argument          := string-expression | expression
```

**Concatenation** (Sixth Edition; [K81] p. 531: "the "&" causes string concatenation"; its use
inside a LET value: [B80] p. 56). `a & b` is the bytes of `a` followed by the bytes of `b`; `&`
is the only string operator, so there is no precedence to decide, and a chain `a & b & c` is
joined left to right (the result does not depend on the grouping). There are no parentheses in
string expressions: `(` always starts a numeric operand. **Baysick decisions:** (a) `&` may appear
in every string expression, so everywhere one is allowed: a string LET value, a PRINT or PRINT #
item, each side of an IF comparison, the source of CHANGE, a string DEF body, an argument of a
user function, of `LEN`, `ASC`, `VAL`, `SEG$`, `POS` and of CALL (§7.27); (b) a result longer
than 65 536 bytes is the run-time error `STRING TOO LONG IN n` (the CHANGE error, now also raised
by `&`); (c) the operands are evaluated **left to right, each to its value**: in `A$ & FNX$(1)` the
value of `A$` is taken before FNX$ runs, so a change of `A$` inside FNX$ does not change the
result.

A string expression may appear wherever the Fourth Edition allowed a string reference as a
*value*: the value of a string LET (§7.1), a PRINT item (§7.2, §7.24), each side of a string
comparison in IF (§7.7), the source of `CHANGE … TO list` (§7.19), the body of a single-line
string DEF (§7.10), an argument of a user function (§7.10) and the argument of `LEN`, `ASC`,
`VAL` (§6); in the Sixth Edition also the string arguments of `SEG$` and `POS` (§6.2) and a
string argument of CALL (§7.27). A *target* (LET, READ, INPUT, INPUT #, CHANGE … TO, a string DEF's value variable)
is still a string variable or string array element (or `FNx$` in its own body), never a function
call: `LET STR$(1) = "X"` → `ILLEGAL VARIABLE`.

Inside the body of a multi-line string function FN*x*`$`, the text `FNx$` not followed by `(` is
that function's value variable (§7.10), exactly as `FNx` is for a numeric function.

Every string expression has a value that is a string of 0 to 65 536 bytes. A function's result
is a **copy**: after `LET A$ = FNA$(1)`, `LET B$ = STR$(X)`, `LET C$ = SEG$(D$, 1, 2)` or
`LET E$ = F$ & G$`, nothing the program does later changes `A$` … `E$` except an assignment to
them. `CHANGE` (§7.19) still builds strings from character codes; `&` and `SEG$` make most such
uses unnecessary ([K81] p. 531: "Together, these functions allow all string operations").


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
            | ( "LEN" | "ASC" | "VAL" ) "(" string-expression ")"   Fifth Edition (§6, §4.6)
            | "POS" "(" string-expression "," string-expression [ "," expression ] ")"   Sixth Edition (§6.2)
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
      EXP ABS LOG SQR INT SGN RND`, and in the Fifth Edition `LEN ASC VAL`) and the fourth is
      `(` → builtin call (for `LEN ASC VAL` the argument is a string expression, §4.6; Sixth
      Edition: `POS(` → a POS call, §6.2);
      if the next four characters are `STR$` and the fifth is `(` → `STR$` call, a string
      expression: `MISMATCHED STRING OPERATION` here (§4.5); likewise `SEG$(` (Sixth Edition)
      → a `SEG$` call, a string expression: `MISMATCHED STRING OPERATION` here;
   2. else if they are `RND` (not followed by `(`) → bare `RND`;
   3. else if they are `NUM` or `DET` → that function; if a `(` follows → `ILLEGAL FORMULA`
      (they take no argument);
   4. else if the next characters are `F`,`N`,letter,`$` → a string function (§7.10), a string
      expression: `MISMATCHED STRING OPERATION` here (§4.5);
   5. else if the next characters are `F`,`N`,letter → user function: with an argument list if
      `(` follows, else a call without arguments (§7.10; inside the body of a multi-line DEF of
      that same function, the function's result variable instead). Fifth Edition: "that same
      function" is the *numeric* function FN*x*; inside the body of the string function
      FN*x*`$`, `FNx` is an ordinary call of the numeric function FN*x*, and since a letter names
      only one function (§7.10.1) that call is always rejected after the whole program is read
      (`MISMATCHED STRING OPERATION` by the kind check, or an earlier phase-3 error, §10.1);
   6. else if the letter, plus a following digit if any, is followed by `$` → a string
      reference: `MISMATCHED STRING OPERATION` here (§4.5);
   7. else the letter, plus a following digit if any, is a variable name; if the letter (with no
      digit) is followed by `(` it is an array element; a letter+digit followed by `(` is
      `ILLEGAL VARIABLE`.
4. `"` → a string constant: `MISMATCHED STRING OPERATION` (§4.5).
5. anything else (operator, `)`, `,`, end of line, `$`) → `ILLEGAL FORMULA IN n`.

Builtin argument lists contain exactly one expression; a user function's argument list contains
one or more (their number is checked against the DEF after the whole program is read, §7.10); an
array subscript list contains one or two. Anything else before the `)` is `ILLEGAL FORMULA`
(`FNA()` too: an operand is required after the `(`). These recognitions cannot change the
meaning of any program that compiled before: in every case (`NUM`, `DET`, `SGN(`, `COT(`, `FNA`
without `(`, `A$`, `"` in an expression; Fifth Edition: `LEN(`, `ASC(`, `VAL(`, `STR$(`, `FNA$`;
Sixth Edition: `POS(`, `SEG$(`) the text used to be a compile error. `POS` takes two or three
arguments and `SEG$` exactly three, separated by commas; any other count is `ILLEGAL FORMULA`
(a missing `,` or `)` where one is required, as for the other builtins).

Where a **string expression** is required (§4.6), the same text is read with the string rules:
`"` → constant; `STR$(` → STR$ call (one numeric expression, then `)`); `SEG$(` → SEG$ call (a
string expression, `,`, two numeric expressions separated by `,`, then `)`); `FN` letter `$` → string
function call (with `(`: one or more arguments, each a string expression if its text starts like
one — `"`, `STR$(`, `SEG$(`, `FN` letter `$`, letter [digit] `$` — else a numeric expression); letter
[digit] `$` → string variable, or with `(` (no digit) a string array element with one or two
subscripts; anything else → `MISMATCHED STRING OPERATION` if it starts a numeric operand, else
`ILLEGAL FORMULA` (as for a missing value, §7.1). `STR$` without `(` is not a string expression
(the variable `S` followed by `TR$`), nor is `SEG$` without `(`. After each string primary, `&`
continues the string expression with another string primary (§4.5 for the errors).

### 5.3 Operator position

After an operand the parser looks for `^ * / + -` to continue the expression (after a string
operand: for `&`, §4.6). Anything else ends the expression and is handed back to the statement grammar, which accepts only what it
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
| `LEN(S$)` | the number of bytes of the string (trailing blanks count) | — |
| `ASC(S$)` | the code (0–255, §7.19) of the first byte of the string | empty string → `ASC OF EMPTY STRING` |
| `VAL(S$)` | the number the string denotes, by the INPUT number rule (§6.1) | not a number → `ILLEGAL 'VAL' ARGUMENT` |
| `STR$(X)` | a **string**: the printed form of X without leading or trailing spaces (§6.1) | — |
| `SEG$(S$, M, N)` | a **string**: the bytes of S$ from position M through position N, clamped to the string (§6.2) | — |
| `POS(S$, T$)`, `POS(S$, T$, M)` | the first position, at M or after, where T$ occurs in S$; 0 if none (§6.2) | — |

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

### 6.1 LEN, ASC, VAL, STR$ (Fifth Edition)

[K81] p. 529 names the four functions and describes only STR$ ("the printed form of a number but
without leading or trailing spaces"). Everything else below is a **Baysick decision**; [G70]
p. 37–39 has the same four names with the same purposes.

* **`LEN(s)`** is the length of the value of the string expression `s` in bytes, 0 … 65 536. It
  counts trailing blanks (which comparisons ignore, §7.7): `LEN("AB  ")` = 4.
* **`ASC(s)`** is the code of the first byte of `s`, an integer 0 … 255 (the code table of §7.19:
  `ASC("A")` = 65, `ASC(" ")` = 32). If `s` is empty: run-time error
  `ASC OF EMPTY STRING IN n` (exit 1). **Baysick decision:** the argument is a string
  expression, not a bare character as in [G70] p. 37 (`ASC(R)`, `ASC(LF)`): in Baysick `ASC(R)`
  would be ambiguous with the variable `R`, and a string argument gives the same codes for every
  printable character (`ASC("R")`) plus every byte a program reads; `CHANGE` (§7.19) remains the
  way to get all codes of a string.
* **`VAL(s)`** is the number written in `s`, read exactly like a numeric INPUT field (§7.15):
  every blank (`0x20`) is removed, and what remains must be `[ "+" | "-" ] constant` with the
  §4.1 constant syntax (at most 9 mantissa digits, at most 2 exponent digits, `e` accepted for
  `E`); the value is the double nearest the decimal value (`strtod`), negated for `-`. Otherwise
  — an empty or all-blank string, `"1/2"`, `"X"`, `"1E100"`, `"1234567890"`, `"1,2"`, a TAB
  byte — run-time error `ILLEGAL 'VAL' ARGUMENT IN n` (exit 1; text from [G70] p. 88).
  `VAL(" - 1.5 E3")` = −1500, `VAL("1 2")` = 12. **Baysick decision:** one number syntax for
  program constants, INPUT fields, INPUT # fields and VAL.
* **`STR$(x)`** is the string `sign + body`, where `body` is the §9 body of x and `sign` is `-`
  if x < 0 and empty otherwise — the §9 field *F* without its leading blank (for x ≥ 0) and
  without its trailing blank. So `STR$(5)` = `"5"`, `STR$(-0)` = `"0"`, `STR$(.5)` = `".5"`,
  `STR$(-1234567)` = `"-1234567"`, `STR$(1/3)` = `".333333"`, `STR$(2/3)` = `".666667"`,
  `STR$(999999.4)` = `"999999."`, `STR$(1E9)` = `"1.00000E+9"`, `STR$(-2.35E-4)` = `"-.000235"`,
  `STR$(6.02E23)` = `"6.02000E+23"`. Its length is 1 to 13 bytes (`"-1.79769E+308"`). A STR$ result has at
  most 9 mantissa digits, so `VAL(STR$(x))` succeeds whenever the decimal exponent of x is
  between −99 and 99 (a 3-digit exponent — STR$ produces one for every |x| that rounds to six
digits at 1E100 or above, i.e. from about 9.999995E99 up, and for every |x| that rounds below
1E-99, i.e. below about 9.999995E-100 — is
  `ILLEGAL 'VAL' ARGUMENT`), and then equals x whenever x prints exactly (integers below 10⁹,
  numbers with at most six significant digits).

The arguments are evaluated once, before the function is applied; the string argument may be any
string expression (`LEN(STR$(X))`, `VAL(FNA$(1))`, `ASC(L$(I, J))`).

### 6.2 SEG$ and POS (Sixth Edition)

[K81] p. 531 names the two functions ("The SEG$ function provides a substring … The POS function
can locate a given string expression in a string"), and [B85] p. 29–30 fixes the meaning of
SEG$'s arguments: `SEG$(S$, 5, 6)` is "the fifth and sixth characters" — a first and a **last**
position, not a length. Everything else below is a **Baysick decision**. Positions count bytes
from 1, as `CHANGE` numbers them (§7.19).

**Position arguments** are numeric expressions rounded like subscripts (§7.11): the value x
becomes `floor(x + 0.5)`. The rounding and every comparison below are done exactly on the real
values (no conversion can wrap: `SEG$(A$, -1E30, 1E30)` is all of A$).

* **`SEG$(s, m, n)`**, with L the length of s and m', n' the rounded positions: let
  `first = max(m', 1)` and `last = min(n', L)`. If `first > last` the value is the empty string;
  otherwise it is the `last − first + 1` bytes of s at positions `first … last`. There is no
  error: a range that reaches outside the string is cut to the string, and an empty or inverted
  range gives the empty string. `SEG$("HELLO", 2, 3)` = `"EL"`, `SEG$("HELLO", 0, 2)` = `"HE"`,
  `SEG$("HELLO", 4, 99)` = `"LO"`, `SEG$("HELLO", 3, 2)` = `""`, `SEG$("HELLO", 6, 9)` = `""`,
  `SEG$("HELLO", 2.5, 3.49)` = `"L"` (3 through 3), `SEG$("", 1, 1)` = `""`. Trailing blanks are
  bytes like any other: `SEG$("AB  ", 3, 4)` is two blanks (`LEN` 2). A `SEG$` call is a value,
  not a variable: as the target of LET or of CHANGE … TO it is `ILLEGAL VARIABLE`
  (`LET SEG$(A$, 1, 2) = "X"`, `CHANGE L TO SEG$(A$, 1, 2)`).
* **`POS(s, t, m)`**, with L and K the lengths of s and t and m' the rounded start: let
  `start = max(m', 1)`. The value is the smallest integer p with `start ≤ p ≤ L − K + 1` such that
  the K bytes of s at positions `p … p + K − 1` equal the bytes of t; **0** if there is none.
  `POS(s, t)` is `POS(s, t, 1)`. Bytes are compared exactly (unsigned, trailing blanks
  significant — unlike `=`, §7.7). `POS("BANANA", "AN")` = 2, `POS("BANANA", "AN", 3)` = 4,
  `POS("BANANA", "AN", 5)` = 0, `POS("BANANA", "A", -3)` = 2, `POS("ABC", "ABCD")` = 0,
  `POS("AB  ", " ")` = 3. An **empty** t occurs at every position 1 … L + 1:
  `POS("BANANA", "")` = 1, `POS("BANANA", "", 7)` = 7, `POS("BANANA", "", 8)` = 0,
  `POS("", "")` = 1.

**Evaluation order:** the arguments are evaluated left to right (the string arguments to their
references, the positions to numbers), then the function reads the bytes of its string arguments.
A position argument that calls a function changing a string variable named by an earlier argument
(`SEG$(A$, FNX(1), 2)` where FNX assigns `A$`) therefore sees the new value — the same rule as a
string comparison in IF (§7.7), whose two sides are read when they are compared.

**Baysick decisions, reasons:** clamping instead of an error makes the common scanner idioms
(`SEG$(L$, P, P)` one past the end, `SEG$(L$, P + 1, LEN(L$))` for the rest of a line) need no
range tests, and `SEG$` with an inverted range is the natural empty string; rounding follows the
subscript rule because positions are indices; the optional third argument of `POS` keeps the
two-argument search short while allowing a scan to continue after a match; an empty pattern
matching at the start position is the only choice consistent with `SEG$(s, p, p − 1) = ""`.

## 7. Statements

Notation: `n` is the line number of the statement. Every statement must consume its whole
statement text; leftover text where the grammar expects end of line → `INCORRECT FORMAT IN n`.

### 7.1 LET
```
LET target { "=" target } "=" value
target     := numeric-target | string-target
numeric-target := simple-variable | letter "(" expression [ "," expression ] ")"
                | "FN" letter                       (only in that function's multi-line DEF body)
string-target  := simple-variable "$" | letter "$" "(" expression [ "," expression ] ")"
                | "FN" letter "$"                   (only in that function's multi-line DEF body)
value      := expression          (numeric targets)
            | string-expression   (string targets: "…", A$, A$(i), A$(i,j), STR$(x), FNA$(…), SEG$(…), a & b, §4.6)
```
(The second subscript of a string target and the `FN` letter `$` target are Fifth Edition.)
`LET` is required ([M64] Appendix C). Several targets receive the same value ([M68] p. 33:
`LET X = Y3 = A(3,1) = 1`). Parsing: after `LET` (and after each `=`), if the text there is a
target immediately followed by `=`, it is another target; otherwise the rest is the value. All
targets must be of one kind; a string target among numeric ones, a numeric value for string
targets or a string reference for numeric targets → `MISMATCHED STRING OPERATION`. A value for
string targets that is not a string expression is diagnosed as §5.2 says for every place that
requires one: `MISMATCHED STRING OPERATION` if the text starts a numeric operand (`LET A$ = 5`,
`LET A$ = B`, `LET A$ = (1)`; §4.5), else `ILLEGAL FORMULA` (`LET A$ =` with nothing after the
`=`, `LET A$ = )`). Missing or illegal first target → `ILLEGAL VARIABLE`;
missing `=` → `INCORRECT FORMAT`; `LET FNA = …` outside the multi-line body of FNA →
`ILLEGAL VARIABLE`, and so is `LET FNA$ = …` outside the multi-line body of FNA$ — in
particular `LET FNA = …` inside the body of the string function FNA$ and `LET FNA$ = …` inside
the body of the numeric function FNA (the value variable of a function has exactly that
function's kind, §7.10.1); a string
expression followed by more text → `INCORRECT FORMAT`, except an arithmetic operator →
`MISMATCHED STRING OPERATION` (§4.5).

**Evaluation order:** the subscripts of every target, targets left to right; then the value;
then the stores, targets left to right (each subscript checked at its store). So
`LET I = A(I) = 5` stores into `A` at the *old* `I`. A string store copies the bytes: after
`LET A$ = B$` the two variables are independent. The `FN` target (`FNx` or `FNx$`) and simple
or string variables that are parameters of the enclosing multi-line DEF are that function's
local cells (§7.10). A string value that is a function call is evaluated after the subscripts of
every target, like any value: in `LET A$(I) = FNA$(1)` a change of `I` inside FNA$ does not move
the target.

### 7.2 PRINT
```
PRINT [ item-list ]
item-list := element { element }
element   := string-expression | "TAB" "(" expression ")" | expression | "," | ";"
```
(`string-expression`, §4.6: a string reference, and in the Fifth Edition also `STR$(…)` and
`FNx$…`; in the Sixth Edition also `SEG$(…)` and concatenations `a & b`, one item; `PRINT #` is
§7.24.)
Constraints: an expression must be followed by `,`, `;` or end of line (otherwise
`INCORRECT FORMAT`). A string item or a TAB item may be followed directly by another item
with no separator (`PRINT "X ="X`, [M64] p. 32; `PRINT A$B$`). Consecutive separators are
allowed (`PRINT 1,,3`). An unterminated string constant → `INCORRECT FORMAT`. At the start of an
element, `TAB(` is the TAB item (the name `TAB` is recognised only there); a text that starts a
string expression (§5.2, §4.6) is a string item; anything else is an expression. Output rules:
§8. A `#` right after `PRINT` makes the statement a PRINT # (§7.24).

### 7.3 END
`END` with nothing after it (Baysick extension: or an expression, the exit status, §15.4). Exactly one END, and it must be the **highest-numbered line**
([M64] p. 7, 30) **of the main program** (Sixth Edition: lines of SUB blocks, §7.27, may follow
it — they are not lines of the main program). An END followed by a line of the main program →
`END IS NOT LAST IN n` (n = the END line; this also catches two ENDs). No END at all →
`NO END INSTRUCTION`. `END IS NOT LAST` is decided when the END line is checked, in phase-2
order (§10.1), from the partition of the pre-scan (§7.27), so a later SUB block — even one whose
SUB line has a syntax error — never makes it fire. A multi-line DEF still open at the END line (its FNEND missing) →
`UNFINISHED DEF IN n`, n = the DEF line (§7.10; checked after `END IS NOT LAST`); a SUB block
still open at the END line → `UNFINISHED SUB IN n`, n = the SUB line (§7.27; checked after
`UNFINISHED DEF`). Executing END terminates normally (§10). Without SUB blocks "the last line of
the main program" is the last line, so every earlier program keeps its meaning.

### 7.4 READ
```
READ target { "," target }
```
(targets as in §7.1, without the `FN` targets; a string target may be a string table element
`A$(i, j)`, Fifth Edition). Each numeric target receives the next value of
the **numeric data block**, each string target the next value of the **string data block**
(§7.5; [M68] p. 64: "Numbers will be assigned only to numerical variables, and strings only to
string-variables"). Targets are processed left to right; for array targets the subscripts are
evaluated immediately before that element's value is taken. If the block a target needs has no
value left, the program ends with `OUT OF DATA IN n` on stderr and **exit status 0** (§10). A
program containing a numeric READ target or a numeric MAT READ but no numeric DATA values →
compile error `NO DATA`; a string READ target or a MAT READ of a string array but no string DATA
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
rest of the program → `ILLEGAL TRANSFER IN n` (§7.10), and so is a jump between two program units
(the main program and the subprograms, §7.27).

### 7.7 IF … THEN
```
IF comparison ( "THEN" | "GOTO" ) line-number
comparison := expression relation expression
            | string-expression relation string-expression          (§4.6)
relation := "=" | "<>" | "<" | "<=" | ">" | ">="
```
`IF X > 5 GO TO 200` is the same as `IF X > 5 THEN 200` ([M68] p. 36). The comparison is a
string comparison when the text after `IF` starts with a string expression (§4.6: a string
reference, `STR$(`, `FN` letter `$`, Sixth Edition `SEG$(`; a string expression may continue
with `&`); then the right side must be a string expression too, else
`MISMATCHED STRING OPERATION` (likewise a numeric left side with a string right side). If the
text after `IF` starts with `END#`, the statement is `IF END #` (§7.26), not a comparison; in the
Fourth Edition `IF END…` could only be an error (`E` followed by `N` is not an expression). The relation is matched longest-first (`<=`, `<>`, `>=` before
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

**Multi-line functions.** The FOR/NEXT matching below is done separately for the main program,
for each subprogram's body (Sixth Edition, §7.27: a FOR open at its SUBEND → `UNFINISHED SUB IN
n`, n = the SUBEND line) and for each multi-line DEF body (§7.10): a NEXT inside a body can only close a FOR of the same
body, a NEXT outside every body only a FOR outside every body. A FOR of a body still open at its
FNEND → `UNFINISHED DEF IN n` (n = the FNEND line); a NEXT in a body with no FOR of that body open →
`NOT MATCH WITH FOR IN n`.

**Static matching.** FOR and NEXT are paired at compile time, in ascending line order, like
brackets: a NEXT closes the most recent unclosed FOR and must name the same variable, else
`NOT MATCH WITH FOR IN n` (also for a NEXT with no open FOR). An unclosed FOR at the end →
`FOR WITHOUT NEXT` (no line number, as printed in [M64] p. 23). More than **1000** FOR statements
→ `TOO MANY LOOPS IN n` (n = the 1001st FOR line). Sixth Edition: FOR and NEXT are matched per
program unit (§7.27), but the 1000 FOR statements are counted over the **whole program**, all
units together, in ascending line order. Loops using the same variable may nest.

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

**Subprograms** (Sixth Edition, §7.27): GOSUB and RETURN work inside a subprogram; each
activation has its own pending GOSUBs (a RETURN with none pending in the current activation →
`ILLEGAL RETURN`, even if the caller has some), and those still pending at SUBEND are dropped.
The limit of 1024 counts the pending GOSUBs of all activations together.

### 7.10 DEF and FNEND
```
DEF "FN" letter [ "(" parameter { "," parameter } ")" ] "=" expression     single-line
DEF "FN" letter [ "(" parameter { "," parameter } ")" ]                    multi-line header
DEF "FN" letter "$" [ "(" parameter { "," parameter } ")" ] "=" string-expression
DEF "FN" letter "$" [ "(" parameter { "," parameter } ")" ]
FNEND                                                                      end of a multi-line body
parameter := simple-variable | simple-variable "$"
```
(The `$` forms — string functions — and string parameters are Fifth Edition, §7.10.1.)
Defines function FN*x* with 0 to 8 parameters ([M68] p. 46–47: "Each function defined may have
zero, one, two, or more variables", e.g. `DEF FNB(X,Y) = 3*X*Y - Y↑3`, `DEF FNA = 3.1416*R↑2`). A header whose
parameter list (if any) is followed by end of line starts a **multi-line** definition; one
followed by `=` is a **single-line** definition; anything else → `INCORRECT FORMAT`. DEF may
appear anywhere ([M64] p. 41); it is processed at compile time. Parameters must be distinct
simple or string variables (`X` and `X$` are distinct): a missing, array or repeated parameter
(`DEF FNA()`, `DEF FNA(X(1))`, `DEF FNA(X,X)`, `DEF FNA(X$,X$)`) → `ILLEGAL VARIABLE` (in the
Fourth Edition a string parameter `DEF FNA(X$)` was `ILLEGAL VARIABLE` too); more than **8** (`LIM_FN_PARAMS`) → `INCORRECT FORMAT`,
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

**Functions of a subprogram** (Sixth Edition, §7.27). A DEF inside a SUB block defines a function
of that subprogram, not of the main program: everything above holds with "the main program" read
as "the subprogram" — the function's variables other than its parameters are the subprogram's
(of the activation that calls it, including the subprogram's parameters), it is called only from
lines of the subprogram, and all checks (`DUPLICATE FUNCTION`, `UNDEFINED FUNCTION`, argument
counts and kinds, `RECURSIVE FUNCTION`) are made per program unit: `DEF FNA` in two units defines
two functions. A function reached again through a CALL (a multi-line `FNA` of subprogram `"S"` executes
`CALL "S"`, and the new activation calls `FNA`) is not recursion of the function: each activation
of a subprogram has its own calls of its functions, so `RECURSIVE FUNCTION` considers only calls
between the functions of one unit, never CALL statements.

**Baysick decisions:** (a) recursion is rejected for both kinds: [M68] does not say whether a
function may call itself; a single-line function cannot contain a conditional, so its recursion
could never end, and rejecting it for multi-line functions too keeps one rule and gives every
function at most one activation at a time in each activation of its program unit (Sixth Edition: a
function of a subprogram can be active once in each of several activations of that subprogram,
§7.27). (b) A duplicate DEF is rejected rather than silently
replaced. (c) [M68] states the transfer restriction but no message; Baysick reports
`ILLEGAL TRANSFER`. (d) At most 8 parameters: [M68] states no limit; eight cover every example
and fit the argument registers of both targets.

#### 7.10.1 String functions and string parameters (Fifth Edition)

[K81] p. 529 says only that the Fifth Edition allowed "DEF functions with string arguments and
values". Every rule below is a **Baysick decision**, chosen as the direct extension of the numeric
rules above.

* **Names.** `FNx$` is the string function of letter x. A letter names one function: a `DEF FNA`
  and a `DEF FNA$` in the same program → `DUPLICATE FUNCTION IN n` (n = the second DEF line,
  ascending line order).
* **Single-line string function** `DEF FNx$(p…) = s`: the body is a string expression (§4.6); a
  numeric expression there → `MISMATCHED STRING OPERATION`, as is a string expression as the body
  of a numeric function (`DEF FNA = "X"`). The value of a call is the value of `s`.
* **Multi-line string function** `DEF FNx$(p…)` … `FNEND`: exactly the rules of multi-line
  functions above, with the **value variable** `FNx$` (written without `(` inside the body) in
  place of `FNx`: it is the **empty string** at the start of every call, `LET FNx$ = s` (also one
  target of a multiple string LET) assigns it, `FNx$` in a string expression reads it, `READ FNx$`,
  `INPUT FNx$` and `CHANGE L TO FNx$` are `ILLEGAL VARIABLE` (only LET assigns a value
  variable; the numeric forms keep their Fourth Edition messages: `READ FNA` is
  `INCORRECT FORMAT`, `CHANGE L TO FNA` is `MISMATCHED STRING OPERATION`), and FNEND returns its
  value. Outside the body of FN*x*`$`,
  `LET FNx$ = …` → `ILLEGAL VARIABLE`.
* **The other kind of the same letter inside a body.** The value variable belongs to one kind
  only. Inside the body of FN*x*`$`, `FNx` (no `$`) is not a variable but an ordinary call of the
  numeric function FN*x* (§5.2), and `LET FNx = …` → `ILLEGAL VARIABLE`; symmetrically, inside
  the body of a numeric FN*x*, `FNx$` is a call of the string function FN*x*`$` and
  `LET FNx$ = …` → `ILLEGAL VARIABLE`. Because a program cannot define both FN*x* and FN*x*`$`
  (`DUPLICATE FUNCTION`, above), such a call always names the letter's one function with the
  wrong kind, so the program is rejected in the whole-program phase (§10.1): by
  `INCORRECT NUMBER OF ARGUMENTS` if its argument count differs from the DEF, else by the kind
  check below (`MISMATCHED STRING OPERATION` at the call's line). A call written in the wrong
  *position* is rejected earlier, while the statement is parsed: `FNx` where a string expression
  is required, or `FNx$` where a number is required, is `MISMATCHED STRING OPERATION` (§4.5).
  `UNDEFINED FUNCTION` cannot occur for such a call (the letter is defined), and
  `RECURSIVE FUNCTION` is never reached (the kind check comes first).
* **String parameters** `X$`, `C7$` (a function may mix numeric and string parameters in any
  order, at most 8 in all): inside the body (single- or multi-line) the name denotes the
  function's own copy of the corresponding argument, a string; in a multi-line body it is
  assignable like a numeric parameter (LET, READ, INPUT, INPUT #, CHANGE … TO). Every other string
  variable is the global one.
* **Calls.** `FNx$` without `(` calls FN*x*`$` with no arguments (outside its own body), and
  `FNx$(a1, …, ak)` with k; a call of a string function is a string expression (§4.6), usable
  wherever one is. Each argument is a string expression or a numeric expression, decided by its
  text (§5.2). The arguments are evaluated **left to right, each to its value** — a string
  argument's value is fixed when it is evaluated, so a later argument that calls a function
  changing a variable used by an earlier argument does not change that earlier argument — and
  then the call is made. Inside the body each parameter starts as a copy of its argument;
  assigning a parameter never changes the caller's variables.
* **Kind checks** (after the whole program is read, in the order of §10.1): a call `FNx$…` of a
  function defined as numeric, a call `FNx…` of a function defined as string, or a call with a
  string argument for a numeric parameter or a numeric argument for a string parameter →
  `MISMATCHED STRING OPERATION IN n` (n = the line of the call; for a call inside a single-line
  DEF, the DEF line). The Fourth Edition reported a string argument while parsing the call
  (`PRINT FNA("A")` with `DEF FNA(X)`); Baysick now reports it in the whole-program phase, with
  the same message and line.
* **Results are copies.** The value of a string function call belongs to the caller: two calls in
  one statement (`IF FNA$(1) = FNA$(2) THEN 50`, `PRINT FNA$(1); FNA$(2)`) give two independent
  values.
* Recursion stays rejected (`RECURSIVE FUNCTION`, decision (a)), through string functions as
  through numeric ones; every function is active at most once per activation of its program
  unit, which is what lets the runtime keep string parameters and values without a stack of
  strings (DESIGN.md §6.8).
  Recursive DEF (a Fifth Edition feature, [K81] p. 529) is therefore **not** implemented (see
  "The Fifth Edition" above).

### 7.11 DIM
```
DIM decl { "," decl }
decl := letter "(" integer [ "," integer ] ")"
      | letter "$" "(" integer [ "," integer ] ")"   string list or table (§4.4)
integer := digits                          (no sign, point or exponent)
```
A string array is a list (one bound; storage `b1+1` strings) or, in the Fifth Edition, a table
(two bounds; storage `(b1+1)·(b2+1)` strings, the same `DIMENSION TOO LARGE` limit of 1 000 000
elements). In the Fourth Edition `DIM A$(3,4)` was `ILLEGAL VARIABLE`. `DIM A$(…)` and
`DIM A(…)` declare different arrays, so both may appear. A second DIM of the same string array
→ `DUPLICATE DIMENSION`; a string DIM whose dimensionality conflicts with an earlier use of that
string array (or a use conflicting with an earlier DIM) → `ILLEGAL VARIABLE` (§4.4). The `DIM A$(1000)` that [M68] p. 75
recommends for long strings is legal and simply declares a list of 1001 strings.
Sets the upper bound of each subscript (lower bound is always 0). DIM is a compile-time
declaration: it applies to the whole program regardless of where it appears ([M64] p. 38;
Baysick decision for "regardless of position"); Sixth Edition: to the whole **program unit** in
which it appears (§7.27) — a DIM in a subprogram dimensions that subprogram's array. Arrays not mentioned in a DIM have bound 10 in
each subscript. The dimensionality (list/table) of a letter is fixed by its first appearance in
ascending line order (DIM or use); a `MAT READ X(e)` / `MAT READ X(e,f)` target counts as a use
as a list / table, every other MAT reference names the whole array and fixes nothing, and so
does a whole-array CALL argument `L()` (Sixth Edition, §7.27). A letter
whose dimensionality is still unknown after the whole program (it appears only as a bare name in
MAT statements or as `L()` in CALL arguments) is a **table with bounds 10, 10** ([M68] p. 54: "matrices up to 10 rows and 10
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
`STOP` with nothing after it (Baysick extension: or an expression, the exit status, §15.4).
Terminates the run exactly like END ([M64] p. 45).

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
               | sname [ "(" expression [ "," expression ] ")" ]   string list or table (§4.4)
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
| `MISMATCHED STRING OPERATION` | a string array (`A$`) anywhere in a MAT assignment (`MAT A$ = B$`, `MAT A$ = ZER`, `MAT C = A$ + B`): only MAT READ, MAT PRINT and MAT INPUT handle string arrays ([M68] p. 64) |
| `ILLEGAL VARIABLE` (string array) | a string MAT READ target whose dimensionality conflicts with the letter's string array (§4.4: `DIM A$(5)` and `MAT READ A$(2,3)`); a string MAT READ, MAT PRINT or MAT INPUT name with a digit (`A1$`); MAT INPUT of a string table (as for numeric tables, §7.14.8). In the Fourth Edition every two-dimension string target (`MAT READ A$(2,3)`) was `ILLEGAL VARIABLE` |

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
`MAT READ L$(N)`). A **string table** `X$` (Fifth Edition) is redimensioned exactly like a numeric
table (`X$(r, c)` needs `(r+1)·(c+1)` within its storage; the stored strings are reinterpreted,
never moved or cleared) and its elements `(1,1) … (1,c), (2,1) …` receive the next values of the
string data block; a current shape with a zero dimension → `DIMENSION ERROR`. **Baysick
decision** ([K81] gives no MAT details for string tables): string tables follow the numeric table
rules wherever MAT READ and MAT PRINT apply. Running out of data ends the program
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
   `DIMENSION ERROR`. A **string table** of current shape `r × c` (Fifth Edition) is printed as
   `r` such rows, row `i` holding `X$(i,1) … X$(i,c)`, each row starting on a new line; a zero
   dimension → `DIMENSION ERROR`.

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
10. The same holds for a string array `V$`: `MAT INPUT V$` of a string table → `ILLEGAL
VARIABLE` (**Baysick decision**, Fifth Edition: MAT INPUT stays list-only for both kinds). MAT
INPUT always reads standard input; there is no `MAT INPUT #` and no `MAT PRINT #` (`MAT PRINT #1`
is `ILLEGAL VARIABLE`, a name is required after PRINT, as before; **Baysick decision**: [K81]
mentions only INPUT and PRINT for files).

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
(targets as in READ, §7.4, including string table elements; `INPUT #` is §7.25). INPUT "acts as a READ statement but does not draw numbers from a DATA
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
(stdout is flushed first; Baysick extension: a pending standard-error line of `PRINT #-1` is
ended first, §15.3), without `IN n`. Every line ends with LF, so two INPUT statements never
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
RESTORE # expression       a file (Fifth Edition, §7.23)
```
The next READ (or MAT READ) of the restored block starts again at its first value ([M68] p. 52,
66–67). A `#` after the keyword makes the statement a RESTORE # (§7.23). Anything else after the
keyword → `INCORRECT FORMAT`.

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
CHANGE string-expression "TO" letter           string to list
CHANGE letter "TO" string-target               list to string
```
(Fifth Edition: the source may be any string expression, §4.6, e.g. `CHANGE STR$(X) TO L`; the
target may be a string table element `A$(i, j)`, which is handled like a list element below.)
([M68] p. 67–69.) The letter names a **numeric list** (CHANGE fixes its dimensionality as a list,
§7.11; a table → `ILLEGAL VARIABLE`); string-target is a string variable or string array element.

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

Recognition: after `CHANGE`, a string expression (§4.6) starts the first form; else a letter
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

### 7.21 FILES, file numbers and the file model (Fifth Edition)

```
FILES name { ";" name }
name := '"' { byte except '"' } '"'          quoted: the bytes between the quotes
      | { byte except ";" and '"' }          unquoted: taken from the compacted text (§2)
```

[K81] p. 528–529: files are named by reference number in a `FILES` statement and sequential
files are read with INPUT and written with PRINT, with IF END for the end-of-file condition. The
statement forms below follow [G70] (p. 60–62, 65, 71, 74–75, 78); all details are **Baysick
decisions** (see "The Fifth Edition" at the top).

**Declaration.** FILES is not executable: like DATA (§7.5) it is processed before the run, and
reaching it does nothing. All names of all FILES statements, in ascending line order and left to
right, receive the **file numbers** 1, 2, 3, … ([G70] p. 60: "FILES name 1; name 2; … ;name n";
"Multiple FILES statements are permitted"). A FILES statement may appear anywhere, also in a
multi-line DEF body and (Sixth Edition) in a subprogram, whose FILES names number the program's
files like every other (§7.27: files are shared by all program units). More than **8** names in all (`LIM_FILES`) → `TOO MANY FILES IN n`, reported as soon as a
ninth name starts — at the position where a name is expected (after `FILES` or after a `;`),
whatever follows there, even an empty or malformed name, exactly like the ninth DEF parameter
(§7.10) — n = the line of that position; [G70] p. 60, 86: "You can reference as many as eight files at the
same time in any program"). A name is **empty** (`FILES`, `FILES ;A`, `FILES A;`, `FILES ""`),
contains a byte 0, has text other than `;` or end of line after its closing quote, or has an
unterminated quote → `INCORRECT FORMAT IN n`. Because a physical line has at most 255 bytes, a
name has at most 249 (`LIM_FILE_NAME` = 255 bounds it). Two numbers may name the same file; each
number then has its own position and mode (no other check is made).

**Names and host paths.** The bytes of a name are the host file's **path, unchanged**: Baysick
does no further interpretation (no `~`, no globbing, no environment variables, no added
extension). A relative path is relative to the **working directory of the process**, which a
program never changes; an absolute path (`/tmp/x`) is used as it is. An **unquoted** name is
compacted like all program text outside quotes (§2.1): blanks are removed and lower-case letters
become upper case (`FILES data.txt` names `DATA.TXT`), and a `'` ends it (a remark). A
**quoted** name keeps every byte (`FILES "data.txt"; "my file"`). Whether `DATA` and `data` are
the same file is the host file system's business (on macOS by default yes, on Linux no); portable
programs and the test corpus use the exact spelling. **Baysick decision:** host paths are the
only names a Unix program has; quoting gives access to every legal path, and unquoted names keep
the Dartmouth look (`FILES INPUT; RESULT`).

**File number expressions.** Every file statement names its file by `#` followed by a numeric
expression, the **designator** ([G70] p. 60: "an integer, variable, subscripted variable, or an
arithmetic expression"). Its value x is evaluated when the statement executes and truncated
toward zero, k = trunc(x) ([G70] p. 60: "the value is truncated to an integer"); 0 ≤ k ≤ N (N =
the number of FILES names; Baysick extension: −1 ≤ k ≤ N for `PRINT #`, §15.3) is required, else
run-time error `INVALID FILE NUMBER IN n` (exit 1; [G70] p. 88). A string expression as designator → `MISMATCHED STRING OPERATION` (compile time).

**File 0 is the terminal** ([G70] p. 71: "The statement PRINT #0 … directs the system to print
the results at your terminal"): `PRINT #0` writes standard output exactly like PRINT (same column
state), and `INPUT #0` and `IF END #0` read **standard input** with the file rules of §7.25–§7.26
(no prompt, no retype dialogue, an end-of-file test). This is how a program reads its standard
input to the end and still continues: `IF END #0 THEN 900` before each `INPUT #0`. Standard input
has one reader: INPUT, MAT INPUT, INPUT #0 and IF END #0 share it, and each INPUT-like statement
starts at the beginning of the next unread line. File 0 is always open and always readable and
writable; `SCRATCH #0` and `RESTORE #0` → `INVALID FILE NUMBER`.

**Modes** ([G70] p. 62: "All sequential files … are considered as being in either the read mode or
the write mode. … Initially, the FILES statement results in all files being set to read mode").
File k ≥ 1 is at every moment in one of three states:

| State | Entered by | INPUT #k, IF END #k | PRINT #k |
|-------|------------|---------------------|----------|
| read, not open | start of the run; RESTORE #k | open the host file for reading (`open(path, O_RDONLY)`), position at its first byte, then as "read, open"; failure → `CAN'T OPEN FILE` | `ILLEGAL FILE COMMAND` |
| read, open | the first INPUT #k or IF END #k in read mode | reads from the current position | `ILLEGAL FILE COMMAND` |
| write | SCRATCH #k | INPUT #k → `ILLEGAL FILE COMMAND`; IF END #k is false | appends to the file's output |

So a file is opened **lazily**: a program never fails because of a name it does not use, and a
file that is only written (SCRATCH, then PRINT #) need not exist before. `CAN'T OPEN FILE IN n`
(exit 1, [G70] p. 87) covers every failure to open: a missing file, a missing directory in the
path, no permission, and a path that names a directory. `ILLEGAL FILE COMMAND IN n` (exit 1,
[G70] p. 88: "You have tried to write to a file that has not been set to the write mode, or read
from a file that has not been set to the read mode").

**There is no append mode.** SCRATCH always empties the file; a program that wants to extend a
file reads it and writes it again. **Baysick decision:** [G70] p. 77 has APPEND for binary files
only, and [K81] mentions no append for the Fifth Edition.

**Output of a file in write mode** is buffered (`RT_FILEBUF_SIZE` = 4096 bytes per file, DESIGN.md
§6.8) and reaches the host file only at these moments: as soon as the buffer becomes full — when
the byte that fills it (the 4096th unwritten byte) is added, all 4096 bytes are written at once,
so the host file grows in exact 4096-byte steps while the program runs — at RESTORE #k (§7.23),
and at program termination (§10). (SCRATCH #k of a file already in write mode discards its
unwritten output instead, §7.22.)

**Readers.** Each file in read mode, and standard input, is read in chunks: whenever its reader
needs a byte and holds no unread byte, it makes one `read` request of up to **65 536** bytes
(`RT_INBUF_SIZE`), and it keeps the bytes it received until they are consumed. A file read
through another number therefore sees the bytes that had reached the host file at the moment of
each of its chunk reads: bytes already in its chunk are kept even if the file is later
truncated or rewritten, and bytes written later are seen only by a later chunk read (made when
the reader has consumed every byte it holds; RESTORE # and SCRATCH # of the reading number empty
its reader). A reader never remembers end of input, standard input included: every request that
needs a byte while the reader holds none makes a fresh `read` request, and a request that
receives 0 bytes or an error is at the end of input for that request only (so a later INPUT,
INPUT # or IF END # reads again, and a terminal user may type more after an end-of-file). A write that fails (any `write` error other than `EINTR`, or a write that
transfers 0 bytes) → `CAN'T WRITE FILE IN n` (exit 1; [G70] p. 87), n = the line of the statement
whose output or flush failed (at termination, §10).

**Input lines of a file** are the §7.15 input lines: the bytes up to the next LF (not included),
one CR immediately before the LF removed, a last line without LF a line if it is not empty, a
line longer than 65 536 bytes → `INPUT LINE TOO LONG` (exit 1). A read error (other than `EINTR`)
is treated as the end of the file.

**Baysick extensions (§15).** This file model is extended, outside the Fifth Edition, by `LINPUT`
(§15.2: the next line of file k or of standard input, k = 0, read by the same reader with the
same `IF END` condition and assigned verbatim) and by the designator **−1**, standard error,
which only `PRINT #` accepts (§15.3: every other file statement still reports `INVALID FILE
NUMBER` for it). So the designator range is −1 … N for `PRINT #` and 0 … N for every other file
statement. No FILES name is reserved, so no host path loses its meaning.

### 7.22 SCRATCH

```
SCRATCH "#" expression
```

([G70] p. 75: "When a file is scratched, all data elements contained in the file are erased";
Dartmouth's Sixth Edition has `SCRATCH #` too, [U72] §11.2.3.) For file k ≥ 1 (§7.21): if the
file is open (read or write mode) it is closed — in write mode its unwritten output is discarded,
because the file is emptied anyway — then the host file is opened for writing, **created if it
does not exist and truncated to length 0 if it does** (`open(path, O_WRONLY | O_CREAT | O_TRUNC,
0666)`, the process umask applies), and the file is in write mode with its own column state at
`col = out = 0` (§8). Failure → `CAN'T OPEN FILE IN n`. The open comes first: only after it
succeeds is the file's output buffer allocated (once per file, at its first SCRATCH), and if
that fails → `OUT OF ROOM IN n`, the host file having been created or truncated already. k = 0 → `INVALID FILE NUMBER`. Missing
`#` or text after the expression → `INCORRECT FORMAT`.

### 7.23 RESTORE #

```
RESTORE "#" expression
```

([G70] p. 74: "the RESTORE statement resets a sequential file to the read mode", with the
position at the beginning.) For file k ≥ 1: in write mode, if the file's `col ≠ 0` a newline is
written to it (as at termination, §8), its buffered output is written (failure → `CAN'T WRITE
FILE`) and it is closed; in read mode, an open file is closed. The file is then "read, not open":
the next INPUT #k or IF END #k opens it again and reads from its first byte. k = 0 →
`INVALID FILE NUMBER`. The statements `RESTORE`, `RESTORE*` and `RESTORE$` (§7.16) are not
affected and do not affect files.

### 7.24 PRINT #

```
PRINT "#" expression [ "," item-list ]
```

([G70] p. 71: "PRINT #file designator, output list"; [K81] p. 529: sequential files are written
with PRINT.) The item list is exactly that of PRINT (§7.2), with the same constraints and errors;
`PRINT #k` alone (or `PRINT #k,` with nothing after the comma) writes an empty line. For k = 0
the statement is PRINT. (Baysick extension: for k = −1 it writes standard error with its own
column state, §15.3.) For k ≥ 1 the file must be in write mode (§7.21, else `ILLEGAL FILE
COMMAND`) and the output follows **all of §8 with the file's own state**: each file has its own
`col` and `out` counters and lazy spaces, its own zones (`,`), `;` and TAB columns and its own
75-column rules (a number starts a new line of that file if fewer than 12 columns remain; a `,`
that reaches column 75 ends that file's line). Printing to one file never changes the column of
another file or of standard output. No trailing blank is ever written to a file.

**Order of evaluation:** the designator is evaluated first; then, for each item in order, its
value (which may call a function whose body prints to standard output or another file) and then
its output. The file number (`INVALID FILE NUMBER`) and the mode (`ILLEGAL FILE COMMAND`) are
checked immediately before each output of the statement — the first time after the first item's
value has been evaluated, or before the newline of a `PRINT #k` without items. A PRINT # whose
item list produces no output at all (`PRINT #9,;`: a leading `;` moves nothing and the trailing
`;` suppresses the newline) therefore does nothing, and its file number and mode are never
checked; this is intended. After the
designator only `,` or end of line may follow (`PRINT #1 X` → `INCORRECT FORMAT`).

### 7.25 INPUT #

```
INPUT "#" expression "," target { "," target }
```

(targets as in INPUT, §7.15; [G70] p. 65: "INPUT #file designator, input list"; [K81] p. 529:
sequential files are read with INPUT.) The values come from the lines of file k (k = 0: standard
input) with the **field rules of §7.15** (fields separated by commas outside quotes, a line of
blanks has no field, numeric fields in the constant syntax, quoted and unquoted string fields),
but **without a prompt and without a dialogue**:

1. For k ≥ 1 the file must be in read mode (else `ILLEGAL FILE COMMAND`); it is opened if
   necessary (`CAN'T OPEN FILE`). The statement reads the next line of the file. If there is
   none: `END OF FILE IN n` (exit 1).
2. For each target in order: its subscripts are evaluated (as in READ), then the next field is
   taken. If no field is left on the current line, the next line is read silently and its first
   field taken ([G70] p. 65: "If six data items are required … and only five items are on the
   line …, the next line will be accessed"); if there is no next line: `END OF FILE IN n`. A field
   that is not valid for the target → `INCORRECT FORMAT IN FILE IN n` (exit 1; [G70] p. 88).
   Otherwise the value is assigned (string array elements: the subscript is checked at the
   store, after the field is taken, as in §7.15). For k ≥ 1 every field (and the line read of
   step 1 and the discard of step 3) rechecks the file as in step 1: it must still be in read
   mode (else `ILLEGAL FILE COMMAND`) and is opened if necessary. So a function in a target's
   subscript that executes `RESTORE #k` makes the next field reopen the file and read its first
   line, and one that executes `SCRATCH #k` makes the next field `ILLEGAL FILE COMMAND`.
3. After the last target the rest of the current line is discarded silently ([G70] p. 65: "The
   fifth data item will be ignored").

Values assigned before an error stay assigned (the program stops anyway). The three INPUT
diagnostics of §7.15 are never written for INPUT #, and `END OF INPUT` never occurs (k = 0 reads
standard input with these rules: its end is `END OF FILE`, exit 1). On a terminal, INPUT #0
writes no prompt, but stdout is flushed before each line is read and `col = out = 0` after it, as
for INPUT (§7.15). **Baysick decisions:** a file
has nobody to retype a field, so a bad field stops the program; reading past the end without an
`IF END` test is a program error (exit 1), unlike `END OF INPUT` (exit 0, §7.15), which ends a
filter whose input simply ran out.

Syntax errors: a missing `,` after the designator → `INCORRECT FORMAT` — this includes
`INPUT #1` at the end of the line, and `INPUT #1 A`; a `,` with no target after it (`INPUT #1,`)
→ `ILLEGAL VARIABLE`, as for INPUT (§7.15); `INPUT #` at the end of the line → `ILLEGAL FORMULA`
(an operand is required, §5.2).

### 7.26 IF END #

```
IF END "#" expression ( "THEN" | "GOTO" ) line-number
```

([G70] p. 78: "IF END #file designator THEN line number"; [K81] p. 529: "IF END for the
end-of-file condition".) The line number follows the GOTO rules (§7.6: `UNDEFINED NUMBER`,
`ILLEGAL TRANSFER`). The designator k is evaluated and checked (`INVALID FILE NUMBER`); then the
program jumps to the line if file k is **at its end**:

* k ≥ 1 in read mode: the file is opened if necessary (`CAN'T OPEN FILE`); it is at its end when
  no byte of it remains unread, i.e. the next INPUT #k would find no line. Since every INPUT #
  discards the rest of its last line, this is exactly "every line has been read".
* k ≥ 1 in write mode: never at its end (the condition is false). ([G70] p. 78 tests "the end of
  file space" when writing; Baysick files have no fixed space.)
* k = 0: standard input is at its end when no byte remains unread; to know, the runtime reads
  standard input (waiting for a terminal user to type a line or end-of-file); on a terminal
  stdout is flushed first. IF END #0 does not reset the output column: only a line read by INPUT
  (§7.15) or INPUT #0 (§7.25) — and, Baysick extension, by LINPUT or LINPUT #0 on a terminal
  (§15.2) — sets `col = out = 0`.

**Baysick decision:** IF END tests *before* reading (is there another line?), so the loop
`10 IF END #1 THEN 90` / `20 INPUT #1, A$` / `30 … GOTO 10` reads every line and never fails.
[G70] p. 78 describes the test after a READ ("whether a valid data item was read") and lets the
READ past the end assign zeros; a pre-test needs no such substitute values. An empty line still
counts as a line: if the last line of a file is empty, IF END is false before it and the INPUT #
that skips it (it has no field) then finds no further line → `END OF FILE`. Reading lines
verbatim, empty ones included, is the Baysick extension `LINPUT` (§15.2), for which this test is
exactly "is there another line".

Syntax errors: the designator is an ordinary expression (§5.1–§5.3), so its errors are the
expression errors, and after it `THEN` or `GOTO` must follow, else `INCORRECT FORMAT`
(`IF END #1 PRINT`). In particular `IF END #` at the end of the line → `ILLEGAL FORMULA` (an
operand is required, §5.2 rule 5), while `IF END # THEN 10` reads the letter `T` as the
designator (the variable T) and then finds no `THEN` → `INCORRECT FORMAT`.

### 7.27 CALL, SUB and SUBEND (Sixth Edition)

```
SUB name [ ":" parameter { "," parameter } ]
SUBEND
CALL name [ ":" argument { "," argument } ]
name      := '"' byte { byte } '"'                  any bytes except '"' and LF, at least one
parameter := simple-variable | simple-variable "$"
           | letter "(" ")" | letter "$" "(" ")"     a numeric or string array
argument  := letter "(" ")" | letter "$" "(" ")"     a whole numeric or string array
           | string-expression | expression
```

[K81] p. 530: the Sixth Edition's subprograms "connect to the calling program only through the
calling sequence. The statements used are CALL, SUB, and SUBEND. Parameters are specified by
reference"; arguments are "matched at each CALL for correct type and number"; there are no
global variables. The forms `CALL "SUM": a, b, c`, `SUB "SUM": x, y, z` … `SUBEND` ([B85] p. 35,
[C74], [B80] p. 55) and recursion ([B85] p. 37) are from the sources; every other rule of this
section is a **Baysick decision** (reasons at the end).

**Program units.** A **SUB block** is a SUB line, the lines after it, and the next SUBEND line.
Before any statement is checked, the compiler **pre-scans** the lines in ascending order and
partitions them, looking only at the keyword each statement starts with (§3.1): a **SUB line** is
a line whose statement starts with the keyword `SUB` (and not `SUBEND`, which is tested first),
**whatever follows the keyword** — `SUB SUM`, `SUB ""` and `SUB "S": 1` are SUB lines too, whose
errors are reported later, in phase-2 order (§10.1); a **SUBEND line** is a line whose statement
starts with `SUBEND`, whatever follows it. A SUB line that is not inside a multi-line DEF body
(§7.10) and not inside another SUB block starts a SUB block, which ends at the next SUBEND line
(or, in an erroneous program, at the END line or after the last line, below). (Multi-line DEF
bodies are found by the same pre-scan, from the DEF lines without `=` and the FNEND lines.) An END
line inside a SUB block ends the block in the pre-scan: the END line and the lines after it are
main-program lines, so a later line makes that END `END IS NOT LAST` (§7.3). A SUBEND or END line
inside a multi-line DEF body within a SUB block ends both the body and the block. Each SUB block is a
**subprogram**; the lines outside every SUB block are the **main program**. The main program and
the subprograms are the **program units**. A SUB block may stand anywhere in the line order; the
customary place, and the one every example uses, is after the main program's `END` ([C74]).
The main program never executes a line of a SUB block: control passes from the main-program line
before a block to the main-program line after it, as if the block were not there. A subprogram
runs only through CALL.

**Names.** A subprogram's name is the bytes between the quotes, kept exactly (§2: quoted text is
not compacted) and compared byte for byte, so `"SUM"`, `"sum"` and `"S UM"` are three names. A
name is not a string constant: it is neither a PRINT label nor counted for `TOO MANY LABELS`
(§4.3). A second SUB with a name already used → `DUPLICATE SUBPROGRAM IN n` (n = the later SUB
line), decided as soon as the name has been read, before the rest of the statement is checked
(`SUB "A": 1` after another `SUB "A"` is `DUPLICATE SUBPROGRAM`). After the whole program is
read, a CALL of a name that no SUB has →
`UNDEFINED SUBPROGRAM IN n` (n = the CALL line).

**SUB statement.** After `SUB` the name must follow (`"`), else `INCORRECT FORMAT`; an
unterminated name or the empty name `""` → `INCORRECT FORMAT`. After the name: end of line (no
parameters) or `:` and the parameter list; anything else → `INCORRECT FORMAT`. Each parameter is
a simple variable (`X`, `X1`), a string variable (`X$`), a numeric array `L()` or a string array
`L$()` (a letter, then for a string array `$`, then `(` `)`). A missing or malformed parameter
(`SUB "S":`, `SUB "S": A,`, `SUB "S": 1`, `SUB "S": A(1)`, `SUB "S": A(`, `SUB "S": X1()`,
`SUB "S": X1$()`) → `ILLEGAL VARIABLE`; the same parameter twice (`A, A`; `A$, A$`; `L(), L()`)
→ `ILLEGAL VARIABLE` (`A`, `A$`, `A()` and `A$()` are four different names, as everywhere, §4.2,
§4.4); more than **16** parameters (`LIM_SUB_PARAMS`) → `INCORRECT FORMAT`, reported as soon as
a seventeenth parameter starts, whatever it is (like the ninth DEF parameter, §7.10); after a
parameter anything but `,` or end of line → `INCORRECT FORMAT`.

**SUBEND statement.** `SUBEND` with nothing after it (text after it → `INCORRECT FORMAT`,
checked before the `UNFINISHED DEF` and `UNFINISHED SUB` of a SUBEND line below, as text after
FNEND is checked before a FOR open at FNEND). A SUBEND outside every SUB block →
`ILLEGAL INSTRUCTION IN n` (as FNEND outside a DEF body).

**Structure errors** (per statement, §10.1 phase 2, unless stated):

* a SUB line inside a SUB block or inside a multi-line DEF body → `NESTED SUB IN n` (n = that SUB
  line), checked before anything after the keyword, so a nested `SUB 1` or a nested SUB with a
  name already used is `NESTED SUB` too;
* an END line while a SUB block is open → `UNFINISHED SUB IN n` (n = the SUB line of the open
  block; END belongs to the main program, §7.3);
* a SUBEND line while a multi-line DEF of the same block is open → `UNFINISHED DEF IN n` (n = the
  DEF line);
* a SUBEND line while a FOR of the subprogram is open → `UNFINISHED SUB IN n` (n = the SUBEND
  line; like a FOR open at FNEND, §7.8);
* a SUB block still open after the last line → `UNFINISHED SUB IN n` (n = its SUB line;
  whole-program phase, §10.1).

**CALL statement.** After `CALL` the name must follow as in SUB (`INCORRECT FORMAT` otherwise,
also for `""` and an unterminated name). After the name: end of line (no arguments) or `:` and
the argument list; anything else → `INCORRECT FORMAT`. An argument is read as follows: a letter
followed by `()` is the whole numeric array of that letter, a letter followed by `$()` the whole
string array; text that starts a string expression (§5.2) is a string expression; any other text
is a numeric expression, read with every §5 rule (a missing argument — `CALL "S":`, `CALL "S":
A,` — is `ILLEGAL FORMULA`, an operand being required; `X1()` is `ILLEGAL VARIABLE`). More than
16 arguments → `INCORRECT FORMAT` as soon as a seventeenth starts; after an argument anything but
`,` or end of line → `INCORRECT FORMAT` (`CALL "S": A B`). Everywhere outside an argument list,
`A()` stays what it was (`ILLEGAL FORMULA`: an operand is required after `(`).

**Matching** (after the whole program is read, §10.1). For a CALL of name s with k arguments and
the SUB of that name with p parameters: k ≠ p → `INCORRECT NUMBER OF ARGUMENTS IN n`. Otherwise
each argument must have its parameter's **kind**: a numeric scalar (a numeric variable, element
or expression) for a numeric variable parameter, a string scalar (a string expression) for a
string variable parameter, a whole numeric array for `L()`, a whole string array for `L$()`. The
first argument, left to right, whose kind differs decides the message: an array where a scalar is
required or a scalar where an array is required → `ARGUMENT MISMATCH IN n`; otherwise (a string
for a number or a number for a string, scalars or arrays) → `MISMATCHED STRING OPERATION IN n`
(n = the CALL line). Whether a numeric array is a list or a table is checked when the subprogram
is entered (below), because a parameter array passed on by another subprogram has no fixed
dimensionality of its own.

**References.** A parameter is another name for the caller's variable, element or array
("Parameters are specified by reference", [K81] p. 530):

* an argument that is exactly a simple variable, a numeric array element, a string variable or a
  string array element (list or table) — nothing else in the argument — is passed **by
  reference**: the parameter is that variable or element for the whole activation; assigning the
  parameter assigns the caller's variable at once, and the caller sees every change. The
  subscripts of an element are evaluated and checked (`SUBSCRIPT ERROR`, n = the CALL line) when
  the arguments are evaluated; the reference then keeps naming that element — the storage
  element addressed at the CALL — even if the variables of its subscripts change, and even if a
  MAT statement in the subprogram redimensions the array so that the element's subscripts
  change (§7.11: storage element `i·(c+1) + j` is the one named, whatever the new shape);
* a whole array `L()` or `L$()` is passed by reference: the parameter array is the caller's
  array, with its current bounds; MAT statements in the subprogram that redimension it
  (§7.14.3) redimension the caller's array;
* inside a subprogram, an argument that is exactly one of its own parameters passes on the
  caller's variable (or array) that the parameter names — when that parameter names a by-value
  cell (below), it is that cell that is passed on;
* every **other** argument is passed **by value**: a constant, any expression with an operator or
  a function call, a variable in parentheses (`(A)`) or with a sign (`+X` and `-X` are
  expressions, §5.1, so `CALL "S": +X` passes the value of X), a string function call or a concatenation,
  and — inside a multi-line DEF body — a parameter of that function or its value variable (`FNx`,
  `FNx$`), which are the function call's own copies, not variables of a program unit. The value
  is computed and put in a fresh cell private to this CALL; the parameter names that cell, may be
  assigned, and the cell is discarded at SUBEND.

**Execution of CALL.**

1. The arguments are evaluated **left to right**: element subscripts, expressions and function
   calls in the order they are written (a function called by a later argument cannot move the
   element a former argument names, and does not change a by-value argument already computed).
2. A new **activation** of the subprogram starts. Checks, in this order: if 1024 activations
   (`LIM_CALL_DEPTH`) are already active, or if the costs of the active activations plus the
   cost of the new one would exceed 2 097 152 words (`LIM_CALL_WORDS`, below) →
   `TOO MANY CALLS IN n`; for each array parameter, left
   to right, whose dimensionality the subprogram fixes (below): the argument array must have it,
   else `DIMENSION ERROR IN n`; if the activation's storage cannot be allocated →
   `OUT OF ROOM IN n` (n = the CALL line in all three).
3. Every variable of the activation starts fresh: numeric variables and array elements 0, string
   variables and string array elements empty, arrays at their DIM (or default) bounds, no FOR
   loop and no GOSUB pending — nothing is kept from an earlier call or another activation.
4. Execution starts at the first line after the SUB line and goes on through the subprogram's
   lines as in any program unit; run-time errors report the subprogram line being executed.
5. Reaching the SUBEND line — in sequence, or by GOTO, IF, ON or IF END # (the SUBEND line
   belongs to the subprogram, so `GOTO` the SUBEND line returns) — ends the activation: its
   variables, arrays and pending GOSUBs are discarded, and the program continues after the CALL
   statement, with the CALL line current again. Reaching the SUB line itself (by a jump) does
   nothing.

**Recursion.** A subprogram may CALL itself, directly or through other subprograms or functions
([B85] p. 37: "these subprograms could call themselves recursively"); each activation has its own
variables (step 3). Two limits bound the active activations (step 2), and whichever is reached
first gives `TOO MANY CALLS`:

* at most **1024** activations at once (`LIM_CALL_DEPTH`);
* the **call budget**: every subprogram has a fixed **cost** in 8-byte words, computed by the
  compiler from the subprogram's text alone (DESIGN.md §5.3.1) — its activation storage (286
  numeric and 286 string variables, 858 words; its hidden FOR cells; one word per parameter; one
  word per numeric array element and two per string array element of its own arrays, four per
  array; two per string temporary of its expressions), plus its work area (temporaries of its
  largest statement and its CALL arguments) and that of its longest chain of function calls. The
  sum of the costs of the active activations never exceeds **2 097 152** words
  (`LIM_CALL_WORDS`, 16 MiB).

A subprogram whose single activation costs more than the whole call budget (more than
`LIM_CALL_WORDS`) gives `TOO MANY CALLS` on its first CALL, wherever it is called from: for example
`DIM A(999999), B(999999), C(99999)` inside a SUB, while the same DIM is fine in the main program.

Both limits depend only on the program text, so the point where `TOO MANY CALLS` occurs is the
same on every target and every machine. Every subprogram costs at least 858 words, so without
large local arrays the 1024-activation limit is reached first (1024 × ~900 words is under half the
budget); a subprogram with a local `DIM A(199999)` costs a little more than 200 000 words, and its
eleventh simultaneous activation exceeds the budget. Allocating an activation's storage can still
fail on a machine without enough memory (`OUT OF ROOM`, step 2), which depends on the host.

**What a program unit owns.** Private to each activation (and to the main program): all its
numeric and string variables; its arrays and string arrays (other than array parameters) with
their DIM statements (a DIM in a subprogram dimensions the subprogram's arrays; a DIM of a
parameter array → `ILLEGAL VARIABLE`); its FOR loops (FOR/NEXT are matched per unit, §7.8, and
each unit has its own hidden LIMIT/STEP cells); its pending GOSUBs; its `DEF` functions (below);
the temporary cells of its string expressions. Shared by the whole program: the DATA blocks and
their cursors (READ and RESTORE in any unit use the one numeric and the one string data block of
§7.5, built from the DATA statements of all units in line order); the files (FILES names and file
numbers of all units, modes, positions, column states, §7.21); standard input and output and the
print column (§8); the RND state and RANDOMIZE; the NUM and DET values; and the line numbers,
which are unique in the whole program.

**Within a subprogram:**

* the scalar and array rules of §4 and §7.11 hold per unit: `A` in the main program and `A` in a
  subprogram are different variables; a letter's array is a list or a table separately in each
  unit (the conflict check of §4.2 is per unit). A **parameter array**'s dimensionality is fixed
  by every use that fixes any array's kind (§7.11, §7.14.8, §7.19): a subscripted use (`L(I)`: a
  list, `L(I, J)`: a table), `MAT INPUT L` (a list), `MAT READ L(e)` / `MAT READ L(e, f)` (a list /
  a table), `CHANGE … TO L` or `CHANGE L TO …` (a list); conflicts → `ILLEGAL VARIABLE` as for
  any array. When no use fixes it — it appears only in MAT assignments, MAT PRINT, a MAT READ
  without dimensions, or as a CALL argument `L()` — it accepts lists and tables;
* GOTO, IF … THEN, ON … GOTO, GOSUB and IF END # may only name lines of the same program unit
  (and, as before, not cross the boundary of a multi-line DEF body), else
  `ILLEGAL TRANSFER IN n` (n = the line of the jump); the SUB and SUBEND lines belong to the
  subprogram;
* GOSUB and RETURN work as in §7.9, per activation: RETURN returns only to a GOSUB of the same
  activation (none pending in it → `ILLEGAL RETURN`); GOSUBs still pending at SUBEND are dropped;
  the 1024 pending GOSUBs of `TOO MANY GOSUBS` are counted over all activations;
* `DEF` defines a function **of that subprogram** (§7.10): it is called only by lines of the
  subprogram, its variables other than its parameters are the subprogram's variables of the
  current activation (including the subprogram's parameters), and its letter is independent of
  the same letter in other units (`DEF FNA` in the main program and in a subprogram are two
  functions; `DUPLICATE FUNCTION`, `UNDEFINED FUNCTION`, `INCORRECT NUMBER OF ARGUMENTS`,
  `MISMATCHED STRING OPERATION` and `RECURSIVE FUNCTION` are decided per unit). A multi-line DEF
  body, in any unit, may contain CALL statements;
* `STOP` ends the whole program, as anywhere; `END` cannot stand in a subprogram (above: it
  belongs to the main program); RETURN is never a return from the subprogram — only SUBEND is.

**Example** (the [B85] p. 35 program, upper-cased):

```
100 INPUT A, B
110 CALL "SUM": A, B, C
120 PRINT C
130 END
150 SUB "SUM": X, Y, Z
160 LET Z = X + Y
170 SUBEND
```

With the input line `2, 3` it prints ` 5`: Z is C, so line 160 assigns the main program's C.

**Baysick decisions** ([K81], [B85] give only what is quoted above): (a) recursion is allowed and
every activation starts fresh — the only semantics compatible with recursion, and what a
recursive-descent parser needs; (b) arguments that are not variables are passed by value through
a private cell, so `CALL "S": 2*X` is legal and cannot change anything of the caller (a variable
in parentheses is therefore the way to pass a variable by value); a function's parameters and
value variable are passed by value because they belong to one function call, not to a program
unit; (c) array parameters are written `L()` (no source shows one); lists and tables share the
form, and the dimensionality is checked at entry, `DIMENSION ERROR`, because it is known only at
run time when an array is passed on; (d) names are compared exactly, like every other quoted text;
(e) SUB blocks may stand anywhere (no source restricts it; placing them after END, as [C74] does,
is the convention); (f) there is no `SUBEXIT`: no source shows one, and `GOTO` the SUBEND line
returns, as `GOTO` the FNEND line does; (g) DATA, files, the terminal and the random number
generator are shared, because they are not variables ([K81]'s "no global variables") and a
subprogram of a compiler must read and write the program's files; (h) `DEF` inside a subprogram
is local to it, so a subprogram is a self-contained unit that could be compiled separately; (i)
at most 16 parameters (twice the DEF limit; arguments are passed through a vector, DESIGN.md
§5.3.1, so the number is not bound to registers) and 1024 activations (as for GOSUB), plus the
call budget, which bounds the memory recursion can take with a rule that depends on the program
text alone (a limit on the machine stack itself would differ between targets and machines); (j) the
messages `UNDEFINED SUBPROGRAM`, `DUPLICATE SUBPROGRAM`, `NESTED SUB`, `UNFINISHED SUB`,
`ARGUMENT MISMATCH` and `TOO MANY CALLS` are Baysick's, worded like the 1968 messages (`NESTED
DEF`, `UNFINISHED DEF`, `TOO MANY GOSUBS`).

## 8. PRINT output

The runtime keeps two counters for the current output line: `col`, the logical column
(0-based), and `out`, the number of characters physically written on this line. Spaces are
**lazy**: emitting a space only increments `col`; before any non-space character is written,
`col − out` spaces are written first. Consequently Baysick never writes trailing spaces (a
teletype shows none either).

* **emit(c)**: if `c` is a space: `col += 1`. Otherwise write `col − out` spaces, write `c`,
  `col += 1`, `out = col`.
* **newline**: write LF; `col = out = 0`.
* **string item** (a string constant, a string variable or a string list element, §7.2; Fifth
  and Sixth Editions: any string expression — `STR$(…)`, `FNx$…`, `SEG$(…)`, a concatenation
  with `&`, §4.6): emit
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
  `col ≠ 0`, a newline is written to stdout; then stdout is flushed. Before that, every file in
  write mode gets the same treatment with its own state (§10). After it, standard
  error's pending line is ended (Baysick extension, §15.5).
* **Files (Fifth Edition).** `PRINT #k` (k ≥ 1, §7.24) applies every rule of this section to file
  k with file k's own `col` and `out`, which start at 0 when SCRATCH #k puts the file in write
  mode. Standard output's state is used by PRINT, `PRINT #0`, MAT PRINT and the INPUT prompt.
* **Standard error (Baysick extension, §15.3).** `PRINT #-1` applies every rule of this section
  to standard error with its own `col` and `out` (0 at the start of the run), independent of
  standard output and of every file; standard error is unbuffered and standard output is written
  before each of its writes; a BASIC message on standard error first ends its pending line.
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
| END or STOP executed | pending-line newline (§8), flush | pending standard-error newline (§15.5) | 0 |
| READ with no data left | pending-line newline, flush | `OUT OF DATA IN n` + LF | **0** |
| INPUT, MAT INPUT or (Baysick extension) LINPUT without `#` needs a line, stdin at its end | pending-line newline, flush | `END OF INPUT IN n` + LF | **0** |
| any other run-time error | pending-line newline, flush | `<MESSAGE> IN n` + LF | 1 |
| INPUT diagnostic (§7.15), program continues | flush | `<MESSAGE>` + LF | — |
| END or STOP, and writing a file's last output fails (Fifth Edition) | pending-line newline, flush | `CAN'T WRITE FILE IN n` + LF | 1 |
| END e or STOP e executed (Baysick extension, §15.4), k = trunc(e) in 0 … 255 | pending-line newline, flush | pending standard-error newline (§15.5) | **k** (1 after a failed write) |
| END e or STOP e, k outside 0 … 255 (Baysick extension) | pending-line newline, flush | `EXIT STATUS OUT OF RANGE IN n` + LF | 1 |

`n` is the line number of the statement being executed (for errors inside a single-line FN
expression, the calling statement; inside a multi-line DEF body, the body line, §7.10; inside a
subprogram, the subprogram's line, and for an error while a CALL starts an activation —
`TOO MANY CALLS`, the entry `DIMENSION ERROR`, `OUT OF ROOM` — the CALL line, §7.27). STOP, OUT
OF DATA, END OF INPUT and every run-time error end the whole program, also inside a subprogram:
the activations still active are simply abandoned.
**Baysick decision:** running out of data is the normal way 1964 programs finished ([M64] p. 7:
"the program is assumed to be done"), so it exits 0, but the message is still written to stderr
so it is visible; running out of input is treated the same way (§7.15).

**Files at termination (Fifth Edition).** In every row of the table, before standard output's
pending-line newline and flush, the runtime finishes every file in **write mode**, in ascending
file number: if its `col ≠ 0` a newline is written to it, then its buffered output is written.
So every line a program wrote to a file ends with LF, as on standard output. Files in read mode
need nothing. If finishing a file fails: after END or STOP the program ends as the run-time error
`CAN'T WRITE FILE IN n` (n = the line of the END or STOP; the remaining files are still finished,
then stdout, then the message, exit 1); in every other row (an error is already being reported)
the failure does not change the message, but the exit status becomes **1** (also after `OUT OF
DATA` and `END OF INPUT`), because output was lost. **Baysick decision**, the same reasoning as
for a broken stdout below.

**Streams.** Programs read standard input only through INPUT, MAT INPUT and, in the Fifth
Edition, INPUT #0 and IF END #0 (§7.15, §7.21), and the Baysick extension LINPUT (§15.2), lazily: a program that executes none of them never
reads it, so its behaviour does not depend on stdin. Input is
read with `read(0, …)` into a runtime buffer; bytes after the last line consumed are never
interpreted. Standard output is written only by PRINT, PRINT #0, MAT PRINT, the INPUT prompt
(terminal only) and the termination newline; files only by PRINT #, the pending newline that RESTORE # writes
(§7.23) and their termination newline (§7.21–§7.24); standard error only by BASIC error messages, the three
INPUT diagnostics and, as a Baysick extension, `PRINT #-1` and its termination newline (§15.3,
§15.5; every row of the table above also ends a pending standard-error line before its message). A read error on stdin (other than `EINTR`) is treated as end of input.

**Baysick decision:** if writing stdout fails (any `write` error other than `EINTR`, or a write
that transfers 0 bytes), the runtime silently discards all further stdout output and the
program's exit status becomes **1** even after END, STOP, `END e` or `STOP e` with any status k
(§15.4) or OUT OF DATA (a run-time error
still exits 1 and its stderr message is still written); nothing extra is printed. Rationale:
output was lost, so success must not be reported, and stderr stays reserved for BASIC errors.
(A closed pipe normally raises `SIGPIPE`, which ends the process before this applies; the runtime
never changes the `SIGPIPE` action it inherits, and the same holds for standard error, §15.3.)

### 10.1 Compiler diagnostics

The compiler stops at the **first** error, determined in this order:

1. **Reading** (physical lines in file order): `PROGRAM TOO LONG` (file size), `LINE TOO LONG`,
   `ILLEGAL LINE NUMBER`, `PROGRAM TOO LONG` (line count).
2. **Statements** in ascending line-number order; within a statement, left to right. All
   per-statement errors (syntax, constants, `END IS NOT LAST`, `NOT MATCH WITH FOR`,
   `TOO MANY LOOPS`, `TOO MUCH DATA`, `TOO MANY LABELS`, DIM errors, `DUPLICATE FUNCTION`,
   array dimensionality conflicts, `FORMULA TOO COMPLEX`, MAT syntax errors of §7.14.2,
   `MISMATCHED STRING OPERATION`, `NESTED DEF`, `ILLEGAL TRANSFER` for GOSUB/RETURN in a body,
   `UNFINISHED DEF` at an END or at a FNEND with an open FOR; Fifth Edition: `TOO MANY FILES`,
   the FILES syntax errors, `DUPLICATE FUNCTION` for a `DEF FNx` and a `DEF FNx$`; Sixth Edition:
   the SUB, SUBEND and CALL syntax errors, `DUPLICATE SUBPROGRAM`, `NESTED SUB`,
   `UNFINISHED SUB` at an END or at a SUBEND with an open FOR, `UNFINISHED DEF` at a SUBEND,
   `ILLEGAL INSTRUCTION` for a SUBEND outside a SUB block, `ILLEGAL VARIABLE` for a DIM of a
   parameter array; Baysick extensions, §15: the LINPUT syntax errors, the errors of the
   expression after END or STOP — after the END checks of §7.3, which are decided first, at
   the keyword).
3. **Whole program**, in this order: `UNFINISHED DEF` (a DEF still open after the last line;
   reported at the DEF line); `UNFINISHED SUB` (Sixth Edition: a SUB block still open after the
   last line; reported at the SUB line); `FOR WITHOUT NEXT`; `NO END INSTRUCTION`; `NO DATA`;
   `NO STRING DATA`; `UNDEFINED NUMBER` (first offending reference in ascending line order, a
   line's references left to right); `ILLEGAL TRANSFER` (first jump between a multi-line DEF body
   and the rest of the program, or — Sixth Edition — between two program units, same order); `UNDEFINED FUNCTION` (first reference in ascending
   line order, single-line DEF expressions included at their DEF line);
   `INCORRECT NUMBER OF ARGUMENTS` (first call, same order, whose argument count differs from its
   DEF); `MISMATCHED STRING OPERATION` (Fifth Edition, §7.10.1: first call, same order, whose
   kind — `FNx` or `FNx$` — or any argument's kind differs from its DEF); `RECURSIVE FUNCTION` (lowest letter A…Z that can reach itself; reported at its DEF
   line; Sixth Edition: the main program's functions first, then each subprogram's in ascending
   order of its SUB line, lowest letter first within a unit). Sixth Edition, then:
   `UNDEFINED SUBPROGRAM` (first CALL, in ascending line order, of a name no SUB has);
   `INCORRECT NUMBER OF ARGUMENTS` (first CALL, same order, whose argument count differs from
   its SUB's parameter count); `ARGUMENT MISMATCH` or `MISMATCHED STRING OPERATION` (first CALL,
   same order, with an argument whose kind differs from its parameter's; its first such argument
   decides which, §7.27). In the checks of `UNDEFINED NUMBER`, `ILLEGAL TRANSFER`,
   `UNDEFINED FUNCTION` and the FN argument checks, "ascending line order" runs over all units
   together (every line has one number in the whole program); `UNDEFINED FUNCTION` means not
   defined in the unit of the call.

The message is written to **stderr** as exactly `<MESSAGE> IN <n>` + LF, or `<MESSAGE>` + LF for
messages without a line number, with **no prefix**, and the compiler exits with status **1**
without producing any output file. (Format from [M64] p. 23–24: `ILLEGAL FORMULA IN 70`.)

Command-line, file and toolchain problems are not BASIC errors; they are reported as
`baysick: ...` (see `docs/DESIGN.md` §CLI) with exit status 2, 3 or 4.

## 11. Error messages

Compile-time ("IN n" column says whether a line number is printed). Codes 1–31 and, Sixth Edition,
57–61 (they follow the run-time codes so that no earlier code changes):

| Code | Message | IN n | Raised when |
|-----:|---------|:----:|-------------|
| 1 | `ILLEGAL CONSTANT` | yes | >9 mantissa digits, >2 exponent digits, stray `.` (§4.1) |
| 2 | `ILLEGAL FORMULA` | yes | operand expected but not found; missing `)`; wrong builtin argument count; `NUM(`/`DET(`; `FNA()` |
| 3 | `ILLEGAL RELATION` | yes | IF without a valid relation after the first expression |
| 4 | `ILLEGAL LINE NUMBER` | no / yes | bad line number at start of a line (no); jump target with >5 digits (yes) |
| 5 | `ILLEGAL INSTRUCTION` | yes | statement text starts with no keyword (also an empty statement, §1.5); FNEND outside a DEF; Sixth Edition: SUBEND outside a SUB block |
| 6 | `ILLEGAL VARIABLE` | yes | variable required but missing/invalid; `X1(…)`, `X1$(…)`; list/table conflict; two subscripts on a string list; bad or repeated DEF parameter; `LET FNA` outside its body; Sixth Edition: bad or repeated SUB parameter, DIM of a parameter array |
| 7 | `INCORRECT FORMAT` | yes | missing `=`, `TO`, `THEN`/`GOTO`, line number, `)` in DEF/DIM; unterminated string; trailing text; > 8 DEF parameters; bad DATA string; Sixth Edition: a missing, empty or unterminated SUB/CALL name, text after it other than `:`, > 16 SUB parameters or CALL arguments |
| 8 | `END IS NOT LAST` | yes | END on a line that is not the highest-numbered line of the main program |
| 9 | `NO END INSTRUCTION` | no | program has no END |
| 10 | `NO DATA` | no | numeric READ/MAT READ target present, no numeric DATA values |
| 11 | `UNDEFINED FUNCTION` | yes | FN letter never DEFined |
| 12 | `UNDEFINED NUMBER` | yes | GOTO/IF/GOSUB target line does not exist |
| 13 | `PROGRAM TOO LONG` | no | file > 1 MiB or > 10 000 lines |
| 14 | `TOO MUCH DATA` | yes | > 100 000 numeric or > 100 000 string DATA values |
| 15 | `TOO MANY LABELS` | yes | > 65 536 bytes of string constants outside DATA |
| 16 | `TOO MANY LOOPS` | yes | > 1000 FOR statements (in the whole program, all program units together) |
| 17 | `NOT MATCH WITH FOR` | yes | NEXT with wrong variable or no open FOR (of the same body, §7.8) |
| 18 | `FOR WITHOUT NEXT` | no | FOR never closed |
| 19 | `DIMENSION TOO LARGE` | yes | DIM bound > 7 digits or > 1 000 000 elements |
| 20 | `LINE TOO LONG` | no | physical line > 255 bytes (Baysick) |
| 21 | `DUPLICATE FUNCTION` | yes | second DEF of a letter (Baysick) |
| 22 | `DUPLICATE DIMENSION` | yes | second DIM of a letter (Baysick) |
| 23 | `RECURSIVE FUNCTION` | yes | FN can reach itself (Baysick) |
| 24 | `FORMULA TOO COMPLEX` | yes | parenthesis depth > 32 (Baysick) |
| 25 | `MISMATCHED STRING OPERATION` | yes | a string where a number is required or vice versa (§4.5) ([M68] p. 72); Sixth Edition: also a numeric operand of `&` and a CALL argument of the other kind (§7.27) |
| 26 | `NO STRING DATA` | no | string READ/MAT READ target present, no string DATA values ([M68] p. 71) |
| 27 | `INCORRECT NUMBER OF ARGUMENTS` | yes | FN call with a different number of arguments than its DEF ([M68] p. 71); Sixth Edition: CALL with a different number of arguments than its SUB's parameters |
| 28 | `UNFINISHED DEF` | yes | multi-line DEF without FNEND (n = DEF line, also at an END or, Sixth Edition, a SUBEND); FOR open at FNEND (n = FNEND line) ([M68] p. 72) |
| 29 | `NESTED DEF` | yes | DEF inside a multi-line DEF body ([M68] p. 72) |
| 30 | `ILLEGAL TRANSFER` | yes | GOSUB/RETURN in a multi-line DEF body; a jump into or out of a body; Sixth Edition: a jump between program units (Baysick) |
| 31 | `TOO MANY FILES` | yes | more than 8 FILES names in the program (§7.21) ([G70] p. 86) |
| 57 | `UNDEFINED SUBPROGRAM` | yes | CALL of a name no SUB has (§7.27) (Baysick) |
| 58 | `DUPLICATE SUBPROGRAM` | yes | second SUB with the same name (§7.27) (Baysick) |
| 59 | `NESTED SUB` | yes | SUB inside a SUB block or a multi-line DEF body (§7.27) (Baysick) |
| 60 | `UNFINISHED SUB` | yes | SUB block without SUBEND (n = SUB line, also at an END); FOR open at SUBEND (n = SUBEND line) (§7.27) (Baysick) |
| 61 | `ARGUMENT MISMATCH` | yes | CALL with a whole array for a variable parameter or a variable or expression for an array parameter (§7.27) (Baysick) |

Run-time: codes 32–56 and, for the Baysick extensions (§15), 62 (after every edition's codes, so
that no code moves):

| Code | Message | Exit | Raised when |
|-----:|---------|:----:|-------------|
| 32 | `SUBSCRIPT ERROR` | 1 | rounded subscript outside `0..bound` |
| 33 | `ILLEGAL RETURN` | 1 | RETURN with no pending GOSUB (Sixth Edition: of the current activation, §7.9) |
| 34 | `OUT OF DATA` | 0 | READ with the data block exhausted |
| 35 | `DIVISION BY ZERO` | 1 | divisor is ±0 (Baysick) |
| 36 | `ZERO TO A NEGATIVE POWER` | 1 | `0 ^ b`, `b < 0` (Baysick) |
| 37 | `LOG OF ZERO` | 1 | `LOG(0)` (Baysick) |
| 38 | `OVERFLOW` | 1 | non-finite arithmetic or builtin result (Baysick) |
| 39 | `TOO MANY GOSUBS` | 1 | 1025th pending GOSUB (Baysick) |
| 40 | `DIMENSION ERROR` | 1 | MAT: operands do not conform, a dimension argument below 1, a result or new shape that does not fit the target's storage, a list given more than one column, a matrix with a zero dimension, IDN of a non-square matrix (§7.14; text from [M68] p. 73); Sixth Edition: a list passed for a table parameter or a table for a list parameter (§7.27) |
| 41 | `SINGULAR MATRIX` | 1 | MAT INV: a pivot not larger than the tolerance (§7.14.6) (Baysick) |
| 42 | `ON EVALUATED OUT OF RANGE` | 1 | ON: integer part below 1 or above the number of line numbers ([M68] p. 74) |
| 43 | `END OF INPUT` | 0 | INPUT/MAT INPUT needs a line, stdin is at its end (§7.15); Baysick extension: also LINPUT without `#` (§15.2) (Baysick) |
| 44 | `STRING TOO LONG` | 1 | CHANGE list to string with more than 65 536 characters; Sixth Edition: a concatenation `&` longer than 65 536 bytes (§4.6) (Baysick) |
| 45 | `ILLEGAL CHARACTER` | 1 | CHANGE list to string: a code outside 0–255 (text from [M68] p. 71) |
| 46 | `INPUT LINE TOO LONG` | 1 | an input line longer than 65 536 bytes (Baysick) |
| 47 | `OUT OF ROOM` | 1 | string storage could not be allocated ([M68] p. 74); Sixth Edition: also the storage of a subprogram activation (§7.27) |
| 48 | `CAN'T OPEN FILE` | 1 | a file cannot be opened for reading (INPUT #, IF END #) or writing (SCRATCH #) (§7.21) ([G70] p. 87) |
| 49 | `INVALID FILE NUMBER` | 1 | a file designator whose integer part is below 0 (Baysick extension: below −1 for PRINT #, §15.3) or above the number of FILES names (text and meaning: [G70] p. 88); Baysick decision: also `SCRATCH #0`, `RESTORE #0` (§7.21) |
| 50 | `ILLEGAL FILE COMMAND` | 1 | PRINT # to a file in read mode, INPUT # from a file in write mode (Baysick extension: also LINPUT #) (§7.21) ([G70] p. 88) |
| 51 | `END OF FILE` | 1 | INPUT # needs a line and the file (or standard input, #0) has none left (§7.25); Baysick extension: also LINPUT # (§15.2) (Baysick) |
| 52 | `INCORRECT FORMAT IN FILE` | 1 | an INPUT # field is not valid for its target (§7.25) ([G70] p. 88) |
| 53 | `CAN'T WRITE FILE` | 1 | writing a file failed (§7.21, §10) ([G70] p. 87) |
| 54 | `ILLEGAL 'VAL' ARGUMENT` | 1 | VAL of a string that is not a number (§6.1) ([G70] p. 88) |
| 55 | `ASC OF EMPTY STRING` | 1 | ASC of the empty string (§6.1) (Baysick) |
| 56 | `TOO MANY CALLS` | 1 | CALL would start the 1025th active activation, or the active activations' costs would exceed the call budget of 2 097 152 words (§7.27) (Baysick) |
| 62 | `EXIT STATUS OUT OF RANGE` | 1 | `END e` or `STOP e` with trunc(e) outside 0–255 (§15.4) (Baysick extension) |

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
[G70] messages not used by Baysick (p. 86–90): the file name and `LINE #` parts of the file
messages (Baysick prints `<MESSAGE> IN n` like every other error), `ILLEGAL FILE NAME OR
PASSWORD` (a bad FILES name is `INCORRECT FORMAT`, §7.21), `DATA RECORD TOO LARGE` (Baysick's
`INPUT LINE TOO LONG`), and the messages of features Baysick does not have.
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
| string length | 65 536 bytes | STRING TOO LONG (CHANGE; Sixth Edition: also `&`) |
| input line (stdin and files) | 65 536 bytes | INPUT LINE TOO LONG |
| DEF parameters | 8 | INCORRECT FORMAT |
| character codes | 0–255 | ILLEGAL CHARACTER |
| FOR statements | 1000 in the whole program (all program units) | TOO MANY LOOPS |
| parenthesis depth | 32 | FORMULA TOO COMPLEX |
| elements per array | 1 000 000 | DIMENSION TOO LARGE |
| MAT matrix shape | within the array's storage (§7.14.3); square matrices up to 999 × 999 | DIMENSION ERROR |
| pending GOSUBs | 1024 | TOO MANY GOSUBS |
| FILES names (file numbers 1–8; file 0 is the terminal) | 8 (`LIM_FILES`) | TOO MANY FILES |
| bytes of a FILES name | 255 (`LIM_FILE_NAME`; a 255-byte line holds at most 249) | — (LINE TOO LONG first) |
| open files at once | the 8 FILES numbers plus standard input and output (and, Baysick extension, standard error, §15.3) | — |
| SUB parameters / CALL arguments | 16 (`LIM_SUB_PARAMS`) | INCORRECT FORMAT |
| active subprogram activations | 1024 (`LIM_CALL_DEPTH`); summed activation cost 2 097 152 words (`LIM_CALL_WORDS`, §7.27) | TOO MANY CALLS |
| subprograms | no limit of their own (at most 5 000: each has a SUB and a SUBEND line) | PROGRAM TOO LONG |
| SUB/CALL name | the bytes between the quotes, at least 1 (a 255-byte line holds at most 249) | — |
| exit status of `END e` / `STOP e` (Baysick extension) | 0–255 after truncation (`LIM_EXIT_STATUS`) | EXIT STATUS OUT OF RANGE |
| `PRINT #` designators (Baysick extension) | −1 (standard error) … N; every other file statement 0 … N | INVALID FILE NUMBER |
| a LINPUT line (Baysick extension) | 65 536 bytes, as every input line | INPUT LINE TOO LONG |

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

Fifth Edition (each where [K81] gives only the feature's existence; forms from [G70] are
decisions too):

31. Scope: sequential files, `LEN ASC STR$ VAL`, string DEF, string tables; not random-access
    files, `CHAIN`, overlay subprograms, `USR$`, `CHANGE … BIT`, recursive DEF, `TIM CLK$ DAT$`,
    the run-time `FILE` statement (the table under "The Fifth Edition").
32. `FILES name; name; …` ([G70]) is a declaration like DATA; names numbered 1–8 in program
    order; more than 8 → `TOO MANY FILES`; a bad name → `INCORRECT FORMAT`.
33. A name is the host path, unchanged, relative to the working directory; unquoted names are
    compacted (upper case), quoted names exact.
34. Designators `#expression`, truncated ([G70]); file 0 is the terminal: `PRINT #0` = PRINT,
    `INPUT #0`/`IF END #0` read standard input with the file rules, sharing INPUT's reader.
35. Files start in read mode and open lazily; `SCRATCH #` creates/truncates and enters write
    mode; `RESTORE #` returns to read mode at the start; no append mode; `SCRATCH #0`,
    `RESTORE #0` are `INVALID FILE NUMBER`.
36. PRINT # follows §8 with each file's own column state; output is buffered per file and
    finished (pending newline, flush) at RESTORE # and at every termination, files before stdout.
37. INPUT # uses the §7.15 field rules with no prompt and no diagnostics: missing fields come
    from the next lines, excess fields are dropped, a bad field is `INCORRECT FORMAT IN FILE`,
    running out is `END OF FILE` (exit 1).
38. IF END # is a pre-test: true when no unread byte remains (read mode), false in write mode.
39. File errors `CAN'T OPEN FILE`, `INVALID FILE NUMBER`, `ILLEGAL FILE COMMAND`,
    `INCORRECT FORMAT IN FILE`, `CAN'T WRITE FILE` ([G70] texts without the file name) and
    `END OF FILE`; a failed file write at termination makes the exit status 1.
40. `LEN` counts bytes; `ASC` takes a string expression and fails on an empty string; `VAL` uses
    the INPUT number syntax and fails with `ILLEGAL 'VAL' ARGUMENT`; `STR$` is the §9 field
    without its blanks.
41. String functions `FNx$` share the letter with numeric functions; string and numeric
    parameters mix; a multi-line string function's value variable starts empty; arguments are
    evaluated to values left to right; results are copies; kind mismatches are found in the
    whole-program phase as `MISMATCHED STRING OPERATION`; recursion stays rejected.
42. String tables `A$(i, j)` follow the numeric table rules (bounds 10, 10 by default, DIM,
    redimensioning by MAT READ, MAT PRINT by rows); a string array named only in MAT READ/PRINT
    stays a list; MAT INPUT stays list-only; no `MAT PRINT #`/`MAT INPUT #`.

Sixth Edition (each where [K81] and [B85] give only the feature's existence and the forms quoted in
"The Sixth Edition"):

43. Scope: `SEG$`, `POS`, `&`, `CALL`/`SUB`/`SUBEND`; not the run-time `FILE` statement, image
    formatting, separate compilation and libraries, `CALL A$` (the table under "The Sixth
    Edition"); `MAT A = A*B` was already legal.
44. `SEG$(s, m, n)`: positions m through n, rounded like subscripts and clamped to the string,
    never an error; `POS(s, t [, m])`: first match at or after m (default 1), 0 if none, exact
    bytes, an empty t matches at m.
45. `&` joins string expressions left to right, each operand to its value; allowed in every
    string expression; a result over 65 536 bytes is `STRING TOO LONG`.
46. Subprograms: quoted names compared exactly; `SUB "s": params` … `SUBEND`, `CALL "s": args`;
    parameters by reference (variables, elements, whole arrays `L()`/`L$()`, a subprogram's own
    parameters passed on), every other argument by value through a private cell; at most 16
    parameters; arguments matched after the whole program (`UNDEFINED SUBPROGRAM`,
    `INCORRECT NUMBER OF ARGUMENTS`, `ARGUMENT MISMATCH`, `MISMATCHED STRING OPERATION`), list
    versus table at entry (`DIMENSION ERROR`).
47. Recursion allowed; every activation starts with fresh variables; at most 1024 activations
    and a call budget of 2 097 152 words of activation cost, both decided from the program text
    alone, so identically on every target (`TOO MANY CALLS`).
48. Each program unit owns its variables, arrays, FOR loops, pending GOSUBs, DEF functions and
    string temporaries; DATA, files, the terminal, RND, NUM and DET are shared.
49. SUB blocks may stand anywhere; the main program is every other line, and END must be its last
    line; `NESTED SUB`, `UNFINISHED SUB`, `DUPLICATE SUBPROGRAM`; jumps between units are
    `ILLEGAL TRANSFER`; no `SUBEXIT` (`GOTO` the SUBEND line).

Baysick extensions (§15; no edition has them, so every item is Baysick's own):

50. Scope: `LINPUT`, `PRINT #-1`, `END e` / `STOP e`; no command-line arguments or environment,
    no run-time `FILE` statement, no chosen status for OUT OF DATA, END OF INPUT or run-time
    errors (§15.1).
51. `LINPUT [#k,] target`: exactly one string target; the next line of the shared reader
    assigned verbatim (no field splitting, quotes, blank removal; CR LF and the 65 536-byte limit
    as for INPUT); without `#` the INPUT rules (prompt on a terminal, `END OF INPUT`, exit 0),
    with `#k` the INPUT # rules (`END OF FILE`, exit 1); `IF END #k` is its end test.
52. Standard error is designator −1 of PRINT # only, with its own column state and every §8
    rule; unbuffered, standard output written before each of its writes; a BASIC message ends a
    pending standard-error line first; write failures ignored; every other file statement keeps
    `INVALID FILE NUMBER` for −1.
53. `END e` and `STOP e` exit with trunc(e), 0–255 (else `EXIT STATUS OUT OF RANGE`, exit 1),
    after the normal termination steps; a failed write forces exit status 1 whatever e is.
54. Termination order: files, standard output, standard error's pending newline, the message
    (§15.5).

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

**Fifth Edition.** Every Fifth Edition addition likewise gives meaning to text that was an error:
a statement starting with `FILES` or `SCRATCH` (`ILLEGAL INSTRUCTION`), `PRINT #` (`ILLEGAL
FORMULA`), `INPUT #` (`ILLEGAL VARIABLE`), `RESTORE #` (`INCORRECT FORMAT`), `IF END #`
(`ILLEGAL RELATION`), `LEN(`, `ASC(`, `VAL(`, `STR$(`, `FNA$` (the letter followed by text that
cannot continue an expression), a string parameter (`ILLEGAL VARIABLE`), and two subscripts on a
string array. Two Fourth Edition error tests pinned text that became legal; at integration
(DESIGN.md §2.2) they were rewritten so that they test the same error class with text that stays
illegal:

| Test | Fourth Edition text → message | Fifth Edition text → message |
|------|-------------------------------|------------------------------|
| `tests/errors/c_ed4_string_table_dim` | `10 DIM A$(3,4)` → `ILLEGAL VARIABLE IN 10` | `10 DIM A$(3,4,5)` → `INCORRECT FORMAT IN 10` (a third bound, as `DIM A(3,4,5)`) |
| `tests/errors/c_ed4_string_two_subscripts` | `10 LET A$(1,2) = "X"` → `ILLEGAL VARIABLE IN 10` | `10 LET A$(1,2,3) = "X"` → `ILLEGAL FORMULA IN 10` (a third subscript, as `LET A(1,2,3) = 1`, §5.2) |

One message moves between phases without changing: a string argument for a numeric parameter
(`tests/errors/c_ed4_mismatched_fn_arg`) is now found in the whole-program phase (§7.10.1), still
`MISMATCHED STRING OPERATION` at the line of the call; only a program that also has a
per-statement error (any line) or an earlier whole-program error now reports that error instead.
No Fifth Edition feature changes the
meaning of a program that compiled before, so §14.2 has no Fifth Edition rows.

**Sixth Edition.** Every Sixth Edition addition gives meaning to text that was an error: a
statement starting with `CALL`, `SUB` or `SUBEND` (`ILLEGAL INSTRUCTION`), `&` after a string
operand (in PRINT: an item cannot start with `&`, `ILLEGAL FORMULA`; elsewhere leftover text,
`INCORRECT FORMAT`), `SEG$(` (the variable `S` followed by `EG$(`) and `POS(` (the variable `P` followed by `OS(`),
each an error in every position. The lines of a SUB block after END were
`END IS NOT LAST` and are now subprograms. No test of the Fifth Edition corpus pins any of these
texts, so no test is rewritten, and no Sixth Edition feature changes the meaning of a program that
compiled before (§14.2 has no Sixth Edition rows). Not a meaning change but worth noting: after
the Sixth Edition a program may contain lines that are not in the main program, which is why §7.3
now says "the last line of the main program".

**Baysick extensions (§15).** Two of the three extensions give meaning to text that was a compile
error: a statement starting with `LINPUT` (`ILLEGAL INSTRUCTION`) and `END` or `STOP` followed by
an expression (`INCORRECT FORMAT`, leftover text after the keyword). The third changes the
behaviour of a program that compiled: `PRINT #k` with trunc(k) = −1 stopped with
`INVALID FILE NUMBER IN n` (exit 1) and now writes to standard error. This is deliberate: it
changes only a program that ended in a run-time error, and only at that error (the program
continues where it used to stop). No test pins these texts: `tests/errors/r_ed5_invalid_negative`
uses `INPUT #-1`, which is still `INVALID FILE NUMBER` (§15.3), so no earlier test is rewritten.

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

## 15. Baysick extensions

**Status: normative, not historical.** The three features of this section belong to **no
Dartmouth edition**: they are Baysick's own additions, made because a compiler written in
Baysick — the Sea compiler, `docs/SEA_BOOTSTRAP.md` §2 rows 2 and 17 — needs them and nothing up
to the Sixth Edition provides them. Every rule here is a **Baysick decision** (like `END OF INPUT`
and `ILLEGAL TRANSFER` before them); no source is cited because none exists, except [W]'s
unverified mention of a later Dartmouth `LINPUT` (`docs/SEA_BOOTSTRAP.md` §1), which gives the
statement its name and nothing else. The extensions reuse the Fifth Edition file model (§7.21:
designators `#k`, file 0 = the terminal, `IF END #`, the input line reader) and the PRINT rules
of §8, so they add one keyword (`LINPUT`), two statement forms (`END` and `STOP` with an
expression) and one designator value (`#-1`), and nothing else. Like every edition's additions
they are always accepted (one language level, no flag): each gives meaning to a text that was a
compile error, except `PRINT #-1`, which compiled and stopped with `INVALID FILE NUMBER` at run
time (§14.1).

### 15.1 Scope

| Need (`docs/SEA_BOOTSTRAP.md` §2) | Extension | Section |
|-----------------------------------|-----------|---------|
| row 2: read a line verbatim; end of input testable | `LINPUT target`, `LINPUT #k, target` | §15.2 |
| row 17: diagnostics on standard error | `PRINT #-1, items` | §15.3 |
| row 17: a chosen exit status | `END expression`, `STOP expression` | §15.4 |

Not included, each a Baysick decision:

| Feature | Decision and reason |
|---------|---------------------|
| command-line arguments, environment variables (row 18) | not provided: Sea's driver passes everything on standard input (`docs/SEA_BOOTSTRAP.md` §4 item 3), so a compiled program still ignores its arguments and environment (except `BAYSICK_KERNELS`, DESIGN.md §6.6), and its behaviour depends only on its standard input and its files |
| the run-time `FILE` statement | still deferred ("The Sixth Edition"): `LINPUT` reads FILES numbers and standard input like `INPUT #` does, and a compiler reading its source on standard input and writing fixed-name files needs no run-time binding of names |
| several targets in one `LINPUT`, `MAT LINPUT`, a `LINE INPUT` spelling | not provided (§15.2 decisions) |
| reading standard error, `SCRATCH #-1`, `RESTORE #-1`, `IF END #-1` | not provided: standard error is an output stream; these stay `INVALID FILE NUMBER` (§15.3) |
| a statement that flushes standard output | not needed: standard output is written before every standard-error write and at termination (§15.3, §15.5) |
| a chosen exit status for `OUT OF DATA`, `END OF INPUT` or a run-time error | not provided: their statuses stay those of §10; a program that wants another status avoids the condition: it tests `IF END #` before reading input, and counts its DATA values (no statement tests for the end of the data) before reading, then ends with `STOP e` |
| exit statuses above 255, negative statuses, signals | not provided: a POSIX exit status is one byte (§15.4) |

### 15.2 LINPUT

```
LINPUT target
LINPUT "#" expression "," target
target := string-variable | letter "$" "(" expression [ "," expression ] ")"
```

The target is exactly one **string target of INPUT** (§7.15): a string variable `A$` … `Z9$`, a
string list element `L$(i)` or a string table element `T$(i, j)`; inside a multi-line DEF body a
string parameter of the function, inside a subprogram a string parameter of the SUB (which names
the caller's variable, §7.27), like any string variable there. LINPUT reads the **next line** of
its input and assigns it to the target **verbatim**: every byte of the line, in order, with no
splitting at commas, no interpretation of `"`, no removal of leading or trailing blanks, `&`
not special, byte 0 and every other byte kept; an empty line gives the empty string.

**Lines** are the input lines of §7.15 and §7.21, read by the same reader: the bytes up to the
next LF (not included); one CR immediately before the LF removed; a last line without LF counts
as a line if it is not empty (it keeps a trailing CR, since no LF follows it); a line longer than
65 536 bytes (after CR removal) → `INPUT LINE TOO LONG IN n` (exit 1). A line therefore always
fits a string (§12). Standard input has one reader shared by INPUT, MAT INPUT, INPUT #0, IF END #0
and LINPUT (§7.21), and every file k ≥ 1 one reader shared by INPUT #k, IF END #k and LINPUT #k;
each INPUT-like statement starts at the beginning of the next unread line, and LINPUT consumes
exactly one line. (INPUT and INPUT # discard the rest of their last line, so a LINPUT after them
reads the line after it.) LINPUT always reads the reader's **next unread line**: if it runs while
an INPUT or INPUT # statement on the same reader is still in progress (from a function called by
a target's subscript), the rest of that statement's partly read line is discarded, and the
enclosing statement then finds no field left on its current line and continues on the line after
the one LINPUT read, as §7.15 (`NOT ENOUGH INPUT -- ADD MORE`, a new line) and §7.25 (the next
line, silently) say for an exhausted line.

| Line in the input (bytes) | Value assigned | `LEN` |
|---------------------------|----------------|------:|
| `f(a, b)` LF | `f(a, b)` | 7 |
| `print("x") & y` LF | `print("x") & y` | 14 |
| `   two  blanks  ` LF | `   two  blanks  ` (every blank kept) | 16 |
| LF (an empty line) | the empty string | 0 |
| `abc` CR LF | `abc` | 3 |
| `abc` CR CR LF | `abc` CR | 4 |
| `a` NUL `b` LF | the three bytes `a`, 0, `b` | 3 |
| `last` at the end of the input, no LF | `last` | 4 |

**Without `#`** LINPUT reads **standard input with the INPUT rules** (§7.15): on a terminal it
first writes the prompt (the pending spaces of the output line, then `?` and a space, to stdout,
which is then flushed) and after the line `col = out = 0`; when standard input is not a terminal
nothing is written and the column state is unchanged. If standard input is at its end:
`END OF INPUT IN n`, **exit status 0**, exactly as for INPUT (§10).

**With `#k`** LINPUT reads **file k with the INPUT # rules** (§7.25): the designator is evaluated
and truncated (§7.21); k = 0 is standard input without a prompt (on a terminal stdout is flushed
before the line is read and `col = out = 0` after it, as for INPUT #0); k ≥ 1 must be in read mode
(else `ILLEGAL FILE COMMAND`) and is opened if necessary (`CAN'T OPEN FILE`); k = −1 (standard
error, §15.3) and every other k outside 0 … N → `INVALID FILE NUMBER`. If the file has no line
left: `END OF FILE IN n`, **exit status 1**. The end of a file is tested beforehand with
`IF END #k` (§7.26), which for a file in read mode (and for standard input) is true exactly when
no byte of the file remains unread — that is, exactly when the next `LINPUT #k` would find no
line. (For a file in write mode `IF END #k` is false, and `LINPUT #k` is `ILLEGAL FILE COMMAND`.)
So

```
100 IF END #0 THEN 200
110 LINPUT #0, L$
120 ...
130 GOTO 100
200 ...
```

reads every line of standard input, empty lines and the last line without LF included, and
continues at line 200 after the last one; it never ends the program at the end of the input. It
can still fail: a line over 65 536 bytes is `INPUT LINE TOO LONG`, and for a file k ≥ 1 the
first `IF END #k` may be `CAN'T OPEN FILE`.

**Order of evaluation:** the designator (if any); then the target's subscripts; then the file
number and the mode are checked and the line is read; then, for an array element, the subscript
is checked at the store (`SUBSCRIPT ERROR`, as for INPUT, §7.15); then the line is assigned. A
function called by a subscript may print or change files before the line is read (as in
§7.25).

**Compile-time errors:** no target, or a text that is not a target (`LINPUT`, `LINPUT 5`,
`LINPUT "X"`, `LINPUT #1,`) → `ILLEGAL VARIABLE`; a numeric target (`LINPUT A`, `LINPUT #1,
X(2)`) → `MISMATCHED STRING OPERATION`; anything after the target, a second target included
(`LINPUT A$, B$`) → `INCORRECT FORMAT`; `#` and its designator as for INPUT # (§7.25): a missing
`,` after the designator (`LINPUT #1`, `LINPUT #1 A$`) → `INCORRECT FORMAT`, `LINPUT #` at the end
of the line → `ILLEGAL FORMULA`, a string designator → `MISMATCHED STRING OPERATION`.

**Baysick decisions:** (a) the name `LINPUT` — [W] attributes it to a later Dartmouth BASIC
(unverified); it is one word, so no compaction rule can split it, and no keyword is a prefix of
it or has it as a prefix (§3.1); the later two-word `LINE INPUT` of other dialects is not
accepted, one spelling being enough; (b) exactly one target: each target needs its own line and
its own `IF END` test, which a list would hide; (c) the two forms mirror INPUT and INPUT #0: the
form without `#` is the interactive one (prompt, end of input ends the program successfully), the
`#` form the file one (no prompt, end of file is an error unless tested), so "a `#` selects the
file rules" holds for every statement; (d) the line is the reader's line, CR rule and length
limit included, so INPUT, INPUT # and LINPUT can never disagree about where a line ends, and the
only difference from INPUT # is that the fields are not split.

### 15.3 Standard error: PRINT #-1

The designator value **k = −1** (the file number of `PRINT #`, §7.24, truncated: −2 < x ≤ −1)
names **standard error** (`FILE_NUM_STDERR`). `PRINT #-1` (any expression with that value, e.g.
`PRINT #E, …` with E = −1) writes its items to standard error with **all of §8**, using
standard error's own state: its own `col` and `out` (0 at the start of the run), lazy spaces,
zones (`,`), the `;` rule, TAB and the 75-column rules (a number starts a new line of standard
error if fewer than 12 columns remain; a `,` that reaches column 75 ends its line). Printing to
standard error never changes the column of standard output or of any file, and the reverse.
`PRINT #-1` alone writes an empty line to standard error. Standard error is always writable:
there is no mode check. As for every `PRINT #`, the number is checked immediately before each
output (§7.24); k ≤ −2 → `INVALID FILE NUMBER` as before.

**Only PRINT #.** Standard error is an output stream: `INPUT #-1`, `LINPUT #-1`, `IF END #-1`,
`SCRATCH #-1` and `RESTORE #-1` → `INVALID FILE NUMBER IN n` (exit 1), exactly as before.

**Order of the bytes.** Standard error is **not buffered**, and standard output is written first:
before any byte is written to standard error, every buffered byte of standard output is written
(flushed) — only then: an output action that writes no byte (a `,` or TAB that only moves `col`,
lazy blanks) writes nothing anywhere and does not flush standard output, and a `PRINT #-1,;`
produces no output at all and does nothing (§7.24); then each output action of `PRINT #-1` — a string item, a number item, a TAB or `,`
or `;` that writes a newline, the end-of-statement newline — writes its bytes (with the lazy
spaces before its first non-blank byte) to standard error before the statement continues. So when
standard output and standard error are the same file or terminal (`2>&1`), their bytes appear in
the order the program produced them. Files are not affected: a file's output reaches the host
file only at the moments of §7.21, whatever is written to standard error.

**BASIC messages start a line.** Before a BASIC message is written to standard error — a
run-time error, `OUT OF DATA`, `END OF INPUT`, one of the three INPUT diagnostics (§7.15) or
MAT INPUT's `INPUT DATA NOT IN CORRECT FORMAT -- RETYPE IT` (§7.14.8) — if standard error's
`col ≠ 0` a newline is written to standard error first; after the message `col = out = 0` (every
message ends with LF). At every termination standard error's pending line is ended (§15.5). So
no message is ever glued to the end of a program's partial standard-error line, and the last
byte a program writes to standard error is always LF.

**A failed write to standard error** is ignored: the bytes are lost, nothing is reported and the
exit status is unchanged (there is no other stream to report on, and BASIC messages already
ignore it, DESIGN.md §6.7). A closed pipe is the exception it shares with standard output (§10): the
runtime leaves `SIGPIPE` at the action the program inherited, so with the default action a write
to a pipe whose reader has gone ends the process by the signal, exactly as a write to standard
output does; if the parent made the program ignore `SIGPIPE`, the write fails with `EPIPE` and is
ignored like every other failed standard-error write (while standard output's `EPIPE` makes the
exit status 1, §10). **Baysick decision:** one signal rule for both streams; ignoring `SIGPIPE`
process-wide would also change standard output, so that a filter piped into `head` would run to
its end instead of stopping.

Example: with standard output and standard error both redirected to one file,

```
10 PRINT "COMPILING";
20 PRINT #-1, "ERROR:", "LINE"; 3
30 PRINT " DONE"
40 END
```

leaves the bytes `COMPILINGERROR:         LINE 3` LF ` DONE` LF in it: `COMPILING` is written
when line 20 is about to write its first standard-error byte; `ERROR:`, 9 lazy blanks to the zone
at column 15, `LINE`, the number ` 3` (its trailing blank stays lazy) and the newline go to
standard error; ` DONE` continues standard output's line, whose `col` is still 9 from line 10,
and the end of line 30's PRINT ends it. Captured separately, standard output is `COMPILING DONE` LF and
standard error `ERROR:         LINE 3` LF.

**Baysick decisions:** (a) a designator, not a new statement: PRINT # already has every rule
standard error needs (zones, TAB, its own column state), so the whole of §8 applies without a
second set of rules; (b) −1 because it was `INVALID FILE NUMBER` (no FILES number loses its
meaning and no host path is reserved, §7.21) and 2, the Unix descriptor number, is a FILES
number; (c) unbuffered, standard output first: the only rule that gives program order on a
shared stream without a flush statement; a compiler writes few diagnostics, so the cost does not
matter; (d) failures ignored, as for BASIC messages.

### 15.4 Exit status: END and STOP with an expression

```
END [ expression ]
STOP [ expression ]
```

Without the expression both statements are exactly as before (§7.3, §7.13: exit status 0). With
it the expression x is evaluated when the statement executes and truncated, k = trunc(x) (like a
designator, §7.21, ON and TAB: the integer part); **0 ≤ k ≤ 255** (`LIM_EXIT_STATUS`) is
required, else the run-time error `EXIT STATUS OUT OF RANGE IN n` (exit 1; it ends the program
like every run-time error). So `STOP 1.9` exits 1, `STOP -0.5` exits 0, `STOP 256` and `STOP -1`
are errors. Then the program terminates **exactly as END does** (§10, §15.5): files in write mode
finished in ascending order, standard output's pending newline and flush, standard error's
pending newline — and the exit status is k, **except that a failed write makes it 1**: if a
file's output could not be written at this termination the program ends instead as the run-time
error `CAN'T WRITE FILE IN n` (exit 1, n = the END/STOP line), and if a write to standard output
failed at any time, the termination flush included, or an earlier file write failed (§10), the
status is 1 whatever k is. A program
therefore never reports a status other than 1 after it lost output, and a status 0 always means
that every byte arrived.

`END e` keeps every rule of END (§7.3): exactly one END, the last line of the main program, so it
runs only when control reaches the end; `STOP e` may stand anywhere — in the main program, in a
multi-line DEF body, in a subprogram, where it ends the whole program and the active activations
are abandoned (§7.27). Compile-time errors: a string expression →
`MISMATCHED STRING OPERATION`; an expression error → that error (`STOP )` → `ILLEGAL FORMULA`);
text after the expression → `INCORRECT FORMAT` (`STOP 1, 2`). For END, the checks of §7.3 (`END IS NOT
LAST`, then `UNFINISHED DEF`, `UNFINISHED SUB`) are decided at the keyword, before the expression
is parsed (`END A$` followed by another line of the
main program is `END IS NOT LAST`). Spaces are removed by compaction
(§2), so `STOP 1 2` is `STOP 12`.

**Baysick decisions:** (a) END and STOP take the status, not a new statement: STOP already
terminates "exactly like END" anywhere, and the status is the only thing a new statement would
add; (b) truncation like every other integer-valued operand that is not a subscript (designators,
ON, TAB); (c) 0–255 because a POSIX exit status is one byte; out of range is an error, not
reduced modulo 256 or clamped, since `STOP 256` would otherwise report success; (d) a failed
write forces 1, the one rule of §10 that already holds for END (k = 0), so the status a program
chooses can never hide lost output.

### 15.5 Termination and the three streams

Every termination — END or STOP with or without a status, `OUT OF DATA`, `END OF INPUT`, every
run-time error — does these steps in this order (§8, §10, DESIGN.md §6.8, §6.10):

1. every file in write mode, in ascending file number: a newline if its `col ≠ 0`, then its
   buffered output is written;
2. standard output: a newline if its `col ≠ 0`, then its buffer is written;
3. standard error: a newline if its `col ≠ 0`;
4. the message, if any, to standard error (`<MESSAGE> IN n` + LF);
5. exit with the status of §10 (END/STOP with a status: §15.4).

A failure in step 1 after END or STOP turns the termination into the run-time error
`CAN'T WRITE FILE` (§10), which runs steps 1–5 again for what is left (files already finished are
not finished twice). Standard error has no buffer, so step 3 writes at most one LF; standard
output's bytes always precede the message, as before.
