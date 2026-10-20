# Sea bootstrap gap analysis

**Status: informative.** This document asks what a compiler for Sea (`sea/README.md`: a
matrix language with a C/Rust-like syntax, to be written in Baysick) needs from the language it
is written in, and where each need is met: by the Third and Fourth Editions that Baysick now
specifies (`docs/LANGUAGE.md`), by a later Dartmouth edition, or by nothing Dartmouth ever had.
It ends with a recommendation for the next edition Baysick should grow into. Nothing here is
normative; LANGUAGE.md wins for every language rule.

**Update:** the recommendation of §4 item 1 has been taken. LANGUAGE.md specifies the Fifth
Edition subset (sequential files with `IF END`, `LEN ASC STR$ VAL`, string `DEF`, string tables;
"The Fifth Edition", §4.6, §6.1, §7.10.1, §7.21–§7.26), and Baysick implements it on both
targets (DESIGN.md §2.4). Its
semantics come from the GE MARK II BASIC manual of November 1970 [G70] (LANGUAGE.md §0), the
closest available document, with every detail recorded as a Baysick decision. `TIM` was left
out after all (row 19: a compiler does not need it), with the other exclusions listed in
LANGUAGE.md "The Fifth Edition". The rows of §2 marked "Fifth (implemented)" or
"**implemented**" below are covered now: rows 3, 4, 8, 10, 11, 13 and 15.

## 1. Sources

| Ref | Source |
|-----|--------|
| [M68] | *BASIC*, Fourth Edition, Kemeny and Kurtz, Dartmouth, 1 January 1968 (LANGUAGE.md §0). |
| [K81] | T. E. Kurtz, "BASIC", *History of Programming Languages*, ACM/Academic Press, 1981, §3.3–3.6, p. 526–531. The Fifth Edition is §3.5 (p. 528–529), the Sixth §3.6 (p. 530–531). |
| [U72] | *User's Guide to the Dartmouth Time-Sharing System*, September 1972, §11.2.3 (p. 51): the Sixth Edition file statements `FILE #`, `INPUT #`, `PRINT #`, `READ #`, `WRITE #`, `SCRATCH #`. |
| [W] | Wikipedia, "Dartmouth BASIC": secondary; used only where marked **unverified**. |
| [G70] | *GE MARK II BASIC Language Reference Manual*, 711224B, General Electric, November 1970 (LANGUAGE.md §0): the source of Baysick's Fifth Edition file statement forms and error texts. |

The Fifth Edition manual (Dartmouth, late 1970) and the Sixth Edition manual (Mather and Waite,
1971) are not publicly scanned; their features below come from Kurtz's history [K81], whose
descriptions are short. **Wherever only [K81] describes a feature, its exact syntax and
semantics are not known and would have to be specified by Baysick**, as LANGUAGE.md did for the
Third Edition. One discrepancy: [K81] p. 529 says in-line `'` comments "appeared for the first
time" in the Fifth Edition, but [M68] p. 52 — the January 1968 Fourth Edition manual — already
documents them; Baysick follows the manual.

What each later edition adds, per [K81]:

* **Fifth Edition (1970)** [K81 p. 528–529]: files — `FILES`/`FILE` naming files by reference
  number; sequential ("terminal format") files read and written with `INPUT` and `PRINT`, with
  `IF END` for the end-of-file condition; random-access files with `READ`, `WRITE`, `LOC`,
  `LOF`, `RESET`; `CHAIN` (start another program); "subprograms" (overlay segments sharing all
  variables); two-dimensional string arrays; `DEF` functions with string arguments and values;
  the functions `CLK$`, `DAT$`, `LEN`, `USR$`, `STR$` ("the printed form of a number but without
  leading or trailing spaces"), `VAL`, `ASC`, `TIM`; recursive `DEF` functions (removed again in
  the Sixth Edition); `CHANGE … BIT n`.
* **Sixth Edition (1971)** [K81 p. 530–531; U72 §11.2.3]: `CALL`/`SUB`/`SUBEND` subprograms that
  "connect to the calling program only through the calling sequence" (parameters by reference,
  no global variables, separately compilable); `FILE` with run-time binding of names to file
  numbers and the `#` statements of [U72]; the string functions `SEG$` (substring), `POS`
  (search) and the `&` concatenation operator ("Together, these functions allow all string
  operations"); image formatting in PRINT; `MAT A = A*B` legal.
* A whole-line input statement `LINPUT` is attributed to a later Dartmouth BASIC by [W] only:
  **unverified**; nothing below depends on it.

## 2. What a compiler written in Baysick needs

The Sea compiler reads Sea source text and writes target text (assembly or Baysick IR) — the
same shape as Baysick's own pipeline. Classification: **(a)** covered by the Third/Fourth
Edition as specified in LANGUAGE.md; **(b)** covered by the Fifth or Sixth Edition (citation);
**(c)** a gap no Dartmouth edition up to the Sixth fills.

| # | Need | Class | How / where |
|--:|------|:-----:|-------------|
| 1 | Read the source one line at a time | (a), limited | `INPUT A$` reads one field of a line (§7.15). See §3: only lines without `,` and `"` and not empty |
| 2 | Read a line **verbatim** — commas, quotes, `&`, leading blanks, empty lines | **(c)** | INPUT and MAT INPUT always split at commas and interpret quotes ([M68] p. 65); the Fifth/Sixth Edition file INPUT is the same statement on a file ([K81] p. 529). `LINPUT` is unverified ([W]) |
| 3 | Detect the end of the input and continue running | (b) | Fourth Edition: end of input ends the program (LANGUAGE.md §7.15, `END OF INPUT`, exit 0), so nothing can run after the last line. Fifth Edition: `IF END` on sequential files [K81 p. 529]. **Fifth (implemented):** `IF END #0` / `INPUT #0` read standard input as file 0 and test its end (LANGUAGE.md §7.21, §7.26) |
| 4 | Several input files (modules, a prelude) / several outputs (assembly + listing) | (b) | Fifth Edition `FILES`/`FILE`, `INPUT #`, `PRINT #` [K81 p. 528–529]; Sixth Edition run-time `FILE` [K81 p. 530; U72 §11.2.3]. **Fifth (implemented):** `FILES` (names fixed at compile time, up to 8), `SCRATCH #`, `RESTORE #`, `PRINT #`, `INPUT #` (LANGUAGE.md §7.21–§7.25); run-time `FILE` stays a Sixth Edition feature |
| 5 | Write arbitrary text to the output | (a) | `PRINT A$` writes any bytes (§8); a byte that BASIC cannot type (`"`, control characters) is built with `CHANGE` (§7.19). Lines may exceed 75 columns (never wrapped). Trailing blanks are never written (lazy spaces, §8) — harmless for assembly text |
| 6 | Character codes of a string, and a string from codes | (a) | `CHANGE` ([M68] p. 67–69; [K81] p. 528: "any conceivable string operation could be carried out by equivalent operations on numbers") |
| 7 | Compare strings, sort identifiers, symbol tables | (a) | IF with strings (§7.7), string lists (§4.4), numeric lists for hashing via CHANGE codes |
| 8 | String length, character at position, substring | (a) via CHANGE / (b) | Fourth: `CHANGE A$ TO V` then `V(0)`, `V(i)`. Fifth: `LEN`, `ASC` [K81 p. 529] (**implemented**, LANGUAGE.md §6.1); Sixth: `SEG$`, `POS` [K81 p. 531] |
| 9 | Concatenation, building output lines | (a) via CHANGE / (b) | Fourth: copy codes into one list, `CHANGE V TO A$` (or print pieces with `;`, §8). Sixth: `&` [K81 p. 531] |
| 10 | Number → text (emit constants, labels, offsets) | (a) by arithmetic / (b) | Fourth: digits by `INT` arithmetic + CHANGE. Fifth: `STR$` [K81 p. 529] (BASIC's 6-significant-digit print form: fine for integers below 10⁹, not for exact reals; **implemented**, LANGUAGE.md §6.1) |
| 11 | Text → number (parse numeric literals) | (a) by arithmetic / (b) | Fourth: CHANGE + digit arithmetic. Fifth: `VAL` [K81 p. 529] (**implemented**: the INPUT number syntax, LANGUAGE.md §6.1) |
| 12 | Exact IEEE bit patterns of real constants | (a) | Baysick numbers are doubles (§5.4); scaling by powers of two is exact, so a program can extract mantissa and exponent and print hex digits |
| 13 | Recursive descent parsing, nested scopes | (a), clumsy | GOSUB has a 1024-deep return stack but no locals (§7.9); explicit stacks in lists. Multi-line DEF has local parameters and is non-recursive (§7.10); **Fifth (implemented):** string parameters and string results (§7.10.1); recursive DEF left out |
| 14 | Procedures with private variables, separate compilation | (b) | Sixth Edition `CALL`/`SUB`/`SUBEND` [K81 p. 530] |
| 15 | Records, 2-D tables of strings (AST nodes, token tables) | (a) / (b) | Fourth: parallel numeric lists/tables and 1-D string lists. Fifth: two-dimensional string arrays [K81 p. 529] (**implemented**, LANGUAGE.md §4.4) |
| 16 | Program size of a real compiler (thousands of lines) | (a), with limits | Baysick limits (§12): 10 000 lines of ≤ 255 bytes, line numbers ≤ 99999. Fifth `CHAIN`/subprograms and Sixth `SUB` allow splitting [K81 p. 529–530] |
| 17 | Report errors on stderr and fail the build with a non-zero exit status | **(c)** | A program's only stderr output and only non-zero exit are BASIC run-time errors (§10). A deliberate run-time error (e.g. `ON 0 GO TO 10`) exits 1 with `ON EVALUATED OUT OF RANGE IN n` — usable as a last resort, not as diagnostics |
| 18 | Command-line arguments, environment (input file name, options) | **(c)** | No Dartmouth edition has them (programs ran under a time-sharing command system). Use stdin/stdout redirection |
| 19 | Elapsed time (the workloads time themselves; a compiler does not need it) | (b) | Fifth `TIM`, `CLK$` [K81 p. 529]; **not** in Baysick's Fifth Edition (left out, LANGUAGE.md "The Fifth Edition") |
| 20 | Unpredictable random seed (not needed by a compiler) | (a) | `RANDOMIZE` (§7.18) |

## 3. Is INPUT from stdin plus PRINT to stdout enough?

**PRINT to stdout is enough** for the output side (rows 5, 9, 10): any byte sequence can be
written, a statement ending in `;` continues the line, and strings are never wrapped or
truncated. The costs are manual number formatting and building special characters with
CHANGE — clumsy, not blocking.

**INPUT from stdin is not enough** for the input side. For `INPUT A$` (LANGUAGE.md §7.15):

* a comma ends the field: the line `f(a, b)` gives `f(a` and a `TOO MUCH INPUT -- EXCESS
  IGNORED` diagnostic, and the rest is lost;
* a `"` is interpreted: `print("x")` is `INPUT DATA NOT IN CORRECT FORMAT -- RETYPE IT`, and the
  program reads the *next* line instead;
* leading blanks are removed (harmless for a free-form syntax, fatal for any layout rule);
* an empty or all-blank line has no field: `NOT ENOUGH INPUT -- ADD MORE`, and the next line is
  read in its place, so empty lines silently disappear;
* at the end of the input the program **ends** (`END OF INPUT`, exit 0): a compiler cannot emit
  its epilogue, check for unclosed blocks or report "unexpected end of file" after the last line.

`MAT INPUT L$` (§7.14.8) helps a little: it returns every comma-separated field (so `,` can be
re-inserted between them, losing only the blanks after each comma), and an empty line gives
`NUM = 0` instead of disappearing. But `"` and `&` remain special, and end of input still ends
the program.

So a Fourth Edition Sea compiler would only work on source restricted to lines without `"`, `,`
(or with MAT INPUT: without `"` and `&`), terminated by an agreed sentinel line. That is a
workable experiment but not an acceptable language for Sea, whose workloads (`sea/workloads/`)
use string labels, function calls with several arguments and formatted output.

## 4. Recommendation: the next edition

**Implement the Fifth Edition (1970) next**, scoped to what a compiler needs, then the Sixth:

1. **Fifth Edition, files and strings** — sequential files (`FILES`/`FILE`, `INPUT #`,
   `PRINT #`, `IF END #`) with standard input and output available as files, so end of input
   becomes a testable condition (row 3) and several inputs and outputs exist (row 4); `LEN`,
   `ASC`, `STR$`, `VAL` (rows 8, 10, 11); string `DEF` arguments and values; two-dimensional
   string arrays (row 15); `TIM`. Random-access files, `CHAIN`, the overlay "subprograms",
   `USR$`, `CHANGE … BIT` and recursive DEF are not needed by the compiler and can be left out
   with a recorded Baysick decision each.
2. **Sixth Edition, structure** — `SEG$`, `POS`, `&` (rows 8–9) and `CALL`/`SUB`/`SUBEND`
   (row 14), which is what makes a compiler of realistic size maintainable.
3. **Baysick extensions for the (c) gaps**, each a deliberate, documented addition outside any
   edition (as `END OF INPUT` and `ILLEGAL TRANSFER` are now):
   * a verbatim line-input statement (row 2) — the one blocking gap. Because [W]'s `LINPUT`
     is unverified, Baysick should specify it as its own decision: read the next line of a file
     (or stdin) into a string variable with no splitting, quoting or blank removal, and set
     the `IF END` condition at end of input instead of ending the program;
   * a way to write a line to stderr and to end with a chosen exit status (row 17);
   * no command-line arguments (row 18): Sea's driver can pass everything on stdin.

**Why the Fifth first, not straight to the Sixth:** the Fifth Edition brings the two things a
compiler cannot work around — files with an end-of-file test, and string functions that make
text processing practical — while everything the Sixth adds can be emulated (concatenation and
substrings with CHANGE, procedures with GOSUB and explicit stacks). The Sixth Edition's
`SUB` model (no global variables, parameters by reference) is also a larger change to the
compiler's frame and call design (DESIGN.md §5.3–5.4), better done once the I/O exists.
Both editions have only [K81]'s summaries as sources, so the next design phase starts with the
same work as this one: finding or reconstructing the semantics and recording every decision.
