# Baysick IR Specification

**Status: normative.** Binary layouts are pinned in `include/ir.inc`; this document gives their
meaning, the semantics of every opcode, the **canonical lowering** from BASIC (so that
`--emit-ir` output is byte-for-byte reproducible), and the exact text grammar of the dump.
Language semantics referenced here are defined in `docs/LANGUAGE.md`.

## 1. Design and rationale

The IR is a **linear, target-independent three-address code over virtual registers** ("temps"):

* every value is an IEEE-754 double, except that a temp defined by `slit`, `svar`, `sald1` and,
  in the Fifth Edition, `scell`, `sald2`, `sparam` or `sfv` is a **string reference** ("sref"):
  the address of a 16-byte string descriptor (`SD_*`, `runtime.inc`). There are no string
  temporaries: every string value lives in a variable, an array element, a constant, a DATA item
  or — for the results of the Fifth Edition string functions (`STR$`, `FNx$`) and for string
  arguments — in a static **string temp cell** that the frontend allocates per use (§2.1,
  §3.3), and an sref names it (§3.2);
* an instruction reads up to three temps (`A`, `B`, `C`) and writes at most one (`DST`);
* control flow is explicit jumps to numbered labels; there are no basic-block objects, no SSA
  phi nodes and no implicit fall-through tricks;
* everything that touches language state (variables, arrays, DATA, PRINT, GOSUB stack, errors)
  is a dedicated opcode whose semantics are spelled out once here, so a backend author never needs
  to reverse-engineer BASIC.

Why three-address with unlimited temps instead of a stack IR: every operand is named, so a
backend can be written instruction-by-instruction with no simulated stack, the dump is readable,
and the simplest correct backend is trivial — give each temp a fixed 8-byte stack slot, load
operands into scratch registers, compute, store the result. A cleverer backend may do register
allocation; the IR does not prevent it. Why not SSA: BASIC programs jump arbitrarily (GOTO into
the middle of anything), so φ-placement would add complexity no backend needs.

**Temp lifetime rule** (backends may rely on it): within a function each temp is written by
exactly one instruction (static single assignment, without φ), and is read only by instructions
that come **after** its definition in the linear order and before the next `line` instruction
that follows the definition. Temps are function-local. A temp may be live across `callfn` and
`scallfn`. Every temp has a **kind** fixed by its defining opcode — *sref* for `slit`, `svar`,
`sald1`, `scell`, `sald2`, `sparam`, `sfv`, *number* for every other — and every operand field
requires one kind (§3, §3.2, §3.3, verifier §6).

## 2. Module structure

A **Module** (`IRM_*`, 3488 bytes; 3624 with the Fifth Edition contract, DESIGN.md §2.2)
holds:

| Part | Meaning |
|------|---------|
| `NFORS` | number of FOR statements; FOR *k* (0-based, in ascending line order) |
| `NSLOTS` | number of global variable cells = 286 + 2·NFORS |
| strings | table of string constants outside DATA `s0, s1, …` (`IRS_*`: pointer + length, no NUL): PRINT labels and the constants of LET, IF and CHANGE (Fifth Edition: of every string expression, §4.1) |
| data | the numeric DATA block: `NDATA` doubles as raw IEEE bits, in program order |
| sdata | the string DATA block: `NSDATA` entries `IRS_*` (bytes as stored, LANGUAGE.md §7.5), in program order |
| arrays | 26 entries `IRA_*` (letter A…Z): `DIMS` 0 (unused) / 1 / 2, bounds `B1`, `B2` (the initial bounds; they fix the storage `(B1+1)·(B2+1)`; MAT statements may change the run-time shape within it, LANGUAGE.md §7.14.3) |
| funcs | 27 entries `IRF_*`: index 0 = `main`, index 1+L = `FN` letter L; `PRESENT` = 0 if absent |
| sarrays | 26 entries `IRA_*` (letter A…Z) for the string arrays `A$( )` … `Z$( )`: `DIMS` 0 (unused), 1 (list: `B1`, default 10, storage `B1+1` strings, `B2` 0) or, Fifth Edition, 2 (table: `B1`, `B2`, default 10, 10, storage `(B1+1)·(B2+1)` strings) |
| stemps | Fifth Edition: `NSTEMPS`, the number of string temp cells `%s0 … %s(NSTEMPS−1)` (§2.1) |
| files | Fifth Edition: `NFILES` (0…8) FILES names `IRS_*` in file-number order (entry 0 = `#1`), bytes as the frontend determined them (LANGUAGE.md §7.21) |
| fnkinds | Fifth Edition: 27 u32 `FNK_*` words, one per function index: bit k (`FNK_SPARAM0 << k`) = parameter k is a string parameter; `FNK_STRING` = a string function `FNx$`; 0 for `main` and for numeric functions with numeric parameters |

A **Function** (`IRF_*`, 96 bytes) holds a linear array of
instructions, its temp count, a label table (`LABELS[id]` = BASIC line number for a line label,
0 for an internal label), its kind (`FUNC_KIND_MAIN`, `FUNC_KIND_FN` for a single-line DEF,
`FUNC_KIND_FNML` for a multi-line DEF), its parameters (`NPARAMS` 0…8 and `PARAMS[k]`, the
scalar slot naming parameter k; `PARAM` = `PARAMS[0]` or `IR_NONE`, kept for the one-parameter
form), `DEFLINE` and, for a multi-line function, `ENDLINE` (its FNEND line). In the Fifth
Edition `PARAMS[k]` is a **string slot** (0…285, the `X$` of the parameter) when bit k of the
function's `fnkinds` word is set, a scalar slot otherwise. `main` has one line
label per line of the main program (every program line that is not in a multi-line DEF body,
LANGUAGE.md §7.10) plus internal labels; a multi-line function has one line label per line of
its body plus internal labels; single-line functions have no labels.

### 2.1 Operand kinds

| Kind | Encoding | Text |
|------|----------|------|
| temp | u32 index `0..NTEMPS-1` | `t<n>` |
| slot | u32 in `IRI_X`: `0..285` user scalars, `286+2k` LIMIT of FOR k, `287+2k` STEP of FOR k | `A`, `X7`, `%lim3`, `%step3` |
| string slot | u32 in `IRI_X` (`svar`): `0..285`, numbered like scalar slots, a separate space | `A$`, `X7$` |
| string list | u32 letter 0..25 in `IRI_X` (`sald1`, `smat*`, element form of `sread`/`insv`); in `IRI_IMM` (element form of `chgn2s`, §3.2) | `A$` … `Z$` |
| string table | u32 letter 0..25 in `IRI_X` (`sald2`; `smatredim`, `smatread`, `smatprint` accept a string list or table) | `A$` … `Z$` |
| string temp cell | u32 in `IRI_X` (`scell`): `0..NSTEMPS-1` | `%s<n>` |
| label | u32 id in `IRI_X` (or `IRI_IMM` for gosub's return label) | `@<line>` for a line label, `L<id>` for an internal label |
| array | u32 letter 0..25 in `IRI_X`; MAT opcodes also in `IRI_A` / `IRI_B` (§3.1) | `A` … `Z` |
| function | u32 letter 0..25 in `IRI_X` | `FNA` … `FNZ` |
| string | u32 id in `IRI_X` | `s<n>` |
| constant | u64 IEEE-754 bits in `IRI_IMM` | `0x` + 16 uppercase hex digits |
| relation | u16 in `IRI_REL` | `eq ne lt le gt ge` |
| line number | u64 in `IRI_IMM` (`line` op) | decimal |
| small integer | u64 in `IRI_IMM`: parameter index (`param`, `stparam`, `fnarg`, `sparam`), count (`onsel`), RESTORE variant | decimal / `all num str` |

Scalar slot of a variable: `letter*11 + (digit+1)`, or `letter*11` for a bare letter
(`A`=0, `A0`=1, … `A9`=10, `B`=11, …, `Z9`=285). Text name: the letter, followed by the digit if
any.

Unused operand fields hold `IR_NONE` (0xFFFFFFFF); unused `IRI_REL` and `IRI_IMM` are 0.

## 3. Instruction set

Each instruction is a 32-byte record (`IRI_*`). "Run-time line" means the value last stored by a
`line` instruction (the runtime's `_bsk_curline`); run-time errors report it.

| Op | Fields | Text form | Semantics |
|----|--------|-----------|-----------|
| `nop` 0 | — | `nop` | nothing (never produced by the frontend) |
| `line` 1 | IMM=line, X=label | `line 100` | defines line label X; sets the run-time line to IMM |
| `label` 2 | X | `label L7` | defines internal label X |
| `const` 3 | DST, IMM | `t0 = const 0x3FF0000000000000 ; 1` | DST := double with these bits |
| `ldv` 4 | DST, X=slot | `t1 = ldv A` | DST := global cell X |
| `stv` 5 | X=slot, A | `stv A, t1` | global cell X := A |
| `add` 6 `sub` 7 `mul` 8 | DST, A, B | `t2 = add t0, t1` | IEEE op; OVERFLOW error if result not finite |
| `div` 9 | DST, A, B | `t2 = div t0, t1` | B = ±0 → DIVISION BY ZERO; else A/B with OVERFLOW check |
| `pow` 10 | DST, A, B | `t2 = pow t0, t1` | LANGUAGE.md §5.4 rule for `^` (runtime `_bsk_pow`) |
| `neg` 11 | DST, A | `t2 = neg t0` | DST := −A (sign flip, never errors) |
| `sin` 12 … `int` 20 | DST, A | `t3 = sqr t2` | builtin per LANGUAGE.md §6: `sin cos tan atn exp abs log sqr int` (opcodes 12–20 in that order) |
| `rnd` 21 | DST | `t4 = rnd` | DST := next RND value |
| `ald1` 22 | DST, X=array, A | `t5 = ald1 A, t4` | DST := element A of list X (SUBSCRIPT ERROR check) |
| `ald2` 23 | DST, X, A, B | `t5 = ald2 B, t3, t4` | DST := element (A,B) of table X |
| `ast1` 24 | X, A, B | `ast1 A, t4, t5` | element A of list X := B |
| `ast2` 25 | X, A, B, C | `ast2 B, t3, t4, t5` | element (A,B) of table X := C |
| `callfn` 26 | DST, X=fn, A or none | `t6 = callfn FNA, t5` / `t6 = callfn FNA` | DST := result of function FN X called with first argument A (none: no arguments) and the arguments of the `fnarg` instructions right before it |
| `param` 27 | DST, IMM=k | `t0 = param` (k = 0) / `t0 = param 2` | DST := parameter k of the current FN function (its current value in a multi-line function) |
| `ret` 28 | A | `ret t3` | return A from the current FN function (a multi-line function also restores the caller's run-time line) |
| `jmp` 29 | X | `jmp @100` | jump to label X |
| `jcmp` 30 | REL, A, B, X | `jcmp le, t0, t1, @80` | if `A REL B` (IEEE ordered compare) jump to X |
| `jfor` 31 | A, B, C, X | `jfor t0, t1, t2, L5` | if exhausted(A, B, C) jump to X, where exhausted(v,l,s) = `(s >= 0 and v > l) or (s < 0 and v < l)` |
| `gosub` 32 | X=target, IMM=return label | `gosub @200, L9` | push return label IMM (TOO MANY GOSUBS if 1024 pending); jump to X |
| `return` 33 | — | `return` | pop a return label and jump to it; ILLEGAL RETURN if none |
| `read` 34 | DST | `t7 = read` | DST := next DATA value; if none: OUT OF DATA termination |
| `prnum` 35 | A | `prnum t7` | PRINT number item (LANGUAGE.md §8–9) |
| `prstr` 36 | X=string | `prstr s0` | PRINT string item |
| `prcomma` 37 | — | `prcomma` | PRINT `,` |
| `prsemi` 38 | — | `prsemi` | PRINT `;` that follows a number |
| `prnl` 39 | — | `prnl` | PRINT end-of-statement newline |
| `end` 40 | — | `end` | normal termination (END) |
| `stop` 41 | — | `stop` | normal termination (STOP); identical behaviour to `end` |
| `matredim` 42 | X=array, A=temp, B=temp or none | `matredim A, t0, t1` / `matredim V, t0` | redimension X to A × B (B none: A × 1) per LANGUAGE.md §7.14.3; A, B are rounded like subscripts; DIMENSION ERROR |
| `matread` 43 | X | `matread A` | MAT READ of X with its current shape (OUT OF DATA termination) |
| `matprint` 44 | X, IMM=mode | `matprint A, zoned` / `matprint A, packed` | print X per LANGUAGE.md §7.14.5 steps 2–3; IMM = `MATPR_ZONED` 0 / `MATPR_PACKED` 1 |
| `matzer` 45 `matcon` 46 | X | `matzer A` | every element of X's current matrix := 0 / 1 |
| `matidn` 47 | X | `matidn A` | X := identity of its current (square) shape; DIMENSION ERROR if not square |
| `matcopy` 48 | X, A=array | `matcopy B, A` | X := matrix A (redimensions X) |
| `matadd` 49 `matsub` 50 `matmul` 51 | X, A=array, B=array | `matadd C, A, B` | X := A + B / A − B / A · B (LANGUAGE.md §7.14.4, §7.14.7) |
| `matscale` 52 | X, A=temp, B=array | `matscale C, t3, A` | X := (A) · matrix B |
| `mattrn` 53 `matinv` 54 | X, A=array | `mattrn B, A` | X := transpose / inverse of matrix A (§7.14.6) |

Placement rules (checked by the verifier, §6). Opcode groups:

* **E** (expression): `const ldv add sub mul div pow neg sin cos tan atn exp abs log sqr int rnd
  ald1 ald2 callfn fnarg sgn cot num det`, and (Fifth Edition) `len asc val`;
* **S** (string reference): `slit svar sald1`, and (Fifth Edition) `scell sald2`;
* **X** (string expression, Fifth Edition): `sset sstr scallfn` — the operations a string
  expression or a string argument needs (also inside single-line functions);
* **T** (statement): `line label stv ast1 ast2 jmp jcmp jfor read prnum prstr prcomma prsemi
  prnl stop`, the MAT opcodes 42–54, and `sjcmp prsv prtab sread inbeg innum insv inend
  matinput smatinput smatredim smatread smatprint chgs2n chgn2s onsel restore randomize`, and
  (Fifth Edition) `fsel jeof scratch frestore`.

`nop` belongs to no group: it is allowed in every function kind.

| Function kind | Allowed | It ends with |
|---------------|---------|--------------|
| `main` | E, S, X, T, `gosub`, `return`, `end` | `end` (END must be the last line) |
| single-line FN (`FUNC_KIND_FN`) | E, S, X, `param`, `sparam`, and `ret` (numeric) or `sret` (string function) | `ret` / `sret` |
| multi-line FN (`FUNC_KIND_FNML`) | E, S, X, T, `param`, `stparam`, `sparam`, and `ldfv`, `stfv`, `ret` (numeric) or `sfv`, `sret` (string function) | `ret` / `sret` (its FNEND) |

(Without Fifth Edition features S and X never occur in a single-line function, so the table is the
Fourth Edition table for every Fourth Edition program.)

Instructions after an unconditional transfer (`jmp`, `return`, `end`, `stop`, `ret`, `sret`) up to the
next label are reachable only through labels, as usual.

### 3.1 MAT opcodes

Opcodes 42–54 implement the Second Edition MAT statements (LANGUAGE.md §7.14). Each is one call
into the runtime (DESIGN.md §6.5), which owns all shape checks, redimensioning, aliasing,
overflow checks and errors; the IR only names arrays and scalar temps. Field kinds differ per
opcode: in `matcopy`, `matadd`, `matsub`, `matmul`, `mattrn`, `matinv` the `A` (and `B`) fields
hold **array letters** (0..25), not temps; `matscale` has a temp in `A` (the scalar) and an
array letter in `B`; `matredim` has temps in `A` and `B` (`B` = `IR_NONE` for a one-argument
shape). `X` is always the target array. `DST` and `C` are `IR_NONE` in every MAT opcode; `IMM`
is 0 except in `matprint`. A MAT statement never defines a temp. The text forms print array
letters as `A` … `Z` and temps as `t<n>`, operands in field order (`X`, then `A`, then `B`).

Arrays named by MAT opcodes may be lists or tables (the runtime treats a list as an `n × 1`
matrix); a letter that appears only in MAT statements is a table with `B1 = B2 = 10` in the array
table (LANGUAGE.md §7.11).

### 3.2 Third and Fourth Edition opcodes

Opcodes 55–84 (LANGUAGE.md §6–§7.20). "sref" fields hold a temp of kind sref; "list" fields a
numeric-list letter (`DIMS` = 1 in the array table); "slist" fields a string-list letter
(`DIMS` = 1 in the sarray table). Each is one runtime call (DESIGN.md §6.7) except `fnarg`,
`stparam`, `ldfv`, `stfv`, which only move a double, and `slit`, `svar`, which only form an
address. Unused fields as in §2.1.

| Op | Fields | Text form | Semantics |
|----|--------|-----------|-----------|
| `slit` 55 | DST, X=string | `t0 = slit s3` | DST := reference to string constant X (never written through) |
| `svar` 56 | DST, X=string slot | `t0 = svar A$` | DST := reference to string variable X |
| `sald1` 57 | DST, X=slist, A | `t1 = sald1 L$, t0` | DST := reference to element A of string list X (subscript rule and SUBSCRIPT ERROR as `ald1`) |
| `sset` 58 | A=sref, B=sref | `sset t0, t1` | the string A references := a copy of the string B references (A is never a `slit`); OUT OF ROOM |
| `sjcmp` 59 | REL, A=sref, B=sref, X | `sjcmp lt, t0, t1, @80` | if the strings compare `REL` (LANGUAGE.md §7.7: trailing spaces removed, unsigned bytes) jump to X |
| `prsv` 60 | A=sref | `prsv t2` | PRINT string item: the bytes of the string A references |
| `prtab` 61 | A | `prtab t3` | PRINT `TAB(A)` (LANGUAGE.md §8) |
| `sread` 62 | A=sref; element form: X=slist, B | `sread t4`; `sread L$, t4` | the string A references (element form: element B of string list X) := next string DATA value; none: OUT OF DATA termination |
| `inbeg` 63 | — | `inbeg` | INPUT: read the first line (prompt on a terminal; END OF INPUT) |
| `innum` 64 | DST | `t5 = innum` | INPUT: DST := next field as a number (NOT ENOUGH / RETYPE handling, LANGUAGE.md §7.15) |
| `insv` 65 | A=sref; element form: X=slist, B | `insv t6`; `insv L$, t6` | INPUT: the string A references (element form: element B of string list X) := next field as a string |
| `inend` 66 | — | `inend` | INPUT: TOO MUCH INPUT check |
| `matinput` 67 | X=list | `matinput V` | MAT INPUT of numeric list X; sets NUM (LANGUAGE.md §7.14.8) |
| `smatinput` 68 | X=slist | `smatinput V$` | MAT INPUT of string list X; sets NUM |
| `smatredim` 69 | X=slist, A | `smatredim L$, t0` | current bound of string list X := A (rounded like a subscript), within its storage; DIMENSION ERROR |
| `smatread` 70 | X=slist | `smatread L$` | MAT READ of string list X, current bound, from the string DATA block |
| `smatprint` 71 | X=slist, IMM=mode | `smatprint L$, zoned` / `smatprint L$, packed` | MAT PRINT of string list X (LANGUAGE.md §7.14.5) |
| `chgs2n` 72 | X=list, A=sref | `chgs2n A, t2` | CHANGE (string A) TO list X |
| `chgn2s` 73 | X=list, A=sref; element form: X=list, IMM=slist, B | `chgn2s A, t2`; `chgn2s A, L$, t2` | CHANGE list X TO (the string A references; element form: element B of string list IMM) |
| `onsel` 74 | DST, A, IMM=N | `t1 = onsel t0, 3` | DST := trunc(A) if it is in 1…N, else ON EVALUATED OUT OF RANGE |
| `restore` 75 | IMM=variant | `restore all` / `restore num` / `restore str` | RESTORE / RESTORE* / RESTORE$ |
| `randomize` 76 | — | `randomize` | RANDOMIZE |
| `sgn` 77 `cot` 78 | DST, A | `t1 = sgn t0` | SGN / COT (LANGUAGE.md §6) |
| `num` 79 `det` 80 | DST | `t0 = num` | NUM / DET (DET: OVERFLOW if not finite) |
| `fnarg` 81 | IMM=k, A | `fnarg 1, t4` | argument k (1…7) of the `callfn` that follows |
| `stparam` 82 | IMM=k, A | `stparam 0, t3` | parameter k of the current multi-line function := A |
| `ldfv` 83 | DST | `t2 = ldfv` | DST := the current multi-line function's value variable |
| `stfv` 84 | A | `stfv t2` | the current multi-line function's value variable := A |

**Element form of `sread`, `insv`, `chgn2s`.** These three store into a string target. The
plain form names it with an sref temp in `A` (in practice a `svar`: a string variable). A
string list element `L$(i)` is named instead by the **element form**, selected by `A` =
`IR_NONE`: `B` = the subscript temp (a number), and the string list letter in `X` (`sread`,
`insv`; `IMM` = 0) or in `IMM` (`chgn2s`, whose `X` is its numeric list); `DST` and `C` are
`IR_NONE`. The runtime call (DESIGN.md §6.7: `_bsk_sread_el`, `_bsk_input_str_el`,
`_bsk_change_n2s_el`) first takes the value — the next string DATA value; the next valid input
field, after any `NOT ENOUGH INPUT` / `RETYPE` diagnostics; the converted list, after its own
SUBSCRIPT ERROR / STRING TOO LONG / ILLEGAL CHARACTER checks — and only then applies the
subscript rule of `sald1` (SUBSCRIPT ERROR) and stores. So the subscript is checked at the
store (LANGUAGE.md §7.1, §7.4, §7.15, §7.19), which a `sald1` before the call could not do.
Text: `sread L$, tB`, `insv L$, tB`, `chgn2s X, L$, tB` (the `$` letter distinguishes them from
the plain forms `sread tA`, `insv tA`, `chgn2s X, tA`).

**`fnarg` rule.** A call with k arguments (k ≥ 2) is the k − 1 instructions `fnarg 1, …`,
`fnarg 2, …`, …, `fnarg k−1, …`, in this order, **immediately** followed by its `callfn` (A =
argument 0). Nothing else may come between them, so a backend can load the arguments straight
into its argument registers. A call with k = 0 has `callfn` A = `IR_NONE` and no `fnarg`. The
verifier checks that the count, `1 + number of fnargs` (or 0), equals the callee's `NPARAMS`.

### 3.3 Fifth Edition opcodes

Opcodes 85–98 (LANGUAGE.md §4.4–§4.6, §6.1, §7.10.1, §7.21–§7.26). "file" fields hold a number temp, the designator value
before truncation; the runtime truncates and checks it. Each opcode is one runtime call
(DESIGN.md §6.8) except `scell`, `sparam`, `sfv`, which only form an address, and `scallfn`,
which calls a generated function. Unused fields as in §2.1.

| Op | Fields | Text form | Semantics |
|----|--------|-----------|-----------|
| `scell` 85 | DST, X=cell | `t0 = scell %s3` | DST := reference to string temp cell X |
| `sstr` 86 | A=sref, B | `sstr t1, t0` | the string A references := STR$(B) (LANGUAGE.md §6.1); A is never a `slit`; OUT OF ROOM |
| `len` 87 `asc` 88 `val` 89 | DST, A=sref | `t2 = len t1` | DST := LEN / ASC / VAL of the string A references (ASC OF EMPTY STRING, ILLEGAL 'VAL' ARGUMENT) |
| `sald2` 90 | DST, X=string table, A, B | `t3 = sald2 T$, t1, t2` | DST := reference to element (A, B) of string table X (subscript rules and SUBSCRIPT ERROR as `ald2`) |
| `sparam` 91 | DST, IMM=k | `t0 = sparam` (k = 0) / `t0 = sparam 2` | DST := reference to string parameter k of the current FN function (its own copy of the argument) |
| `sfv` 92 | DST | `t1 = sfv` | DST := reference to the value variable `FNx$` of the current multi-line string function |
| `scallfn` 93 | B=sref, X=fn, A or none | `scallfn t5, FNA, t3` / `scallfn t5, FNA` | call string function FN X with first argument A (none: no arguments) and the arguments of the `fnarg` instructions right before it; its value is stored into the string B references (a `scell`) |
| `sret` 94 | A=sref | `sret t2` | return from the current string function with a copy of the string A references as its value (a multi-line function also restores the caller's run-time line) |
| `fsel` 95 | A=file | `fsel t0` | select file A for the one print or input opcode that follows (§3.3.2) |
| `jeof` 96 | A=file, X | `jeof t0, @90` | IF END #: if file A is at its end (LANGUAGE.md §7.26) jump to X |
| `scratch` 97 | A=file | `scratch t0` | SCRATCH # |
| `frestore` 98 | A=file | `frestore t0` | RESTORE # |

Existing opcodes with Fifth Edition field uses (verifier §6): `smatredim` may have `B` = a number
temp (the column count; X a string table: `smatredim T$, t0, t1`), like `matredim`;
`smatread` and `smatprint` accept a string table in X; `fnarg` and `callfn`/`scallfn` `A` hold an
sref when the callee's parameter is a string parameter (§3.3.1); `sset` may target a `scell`,
`sparam` or `sfv` reference; `sread`, `insv`, `chgn2s` (plain form) may target a `scell`.

#### 3.3.1 String functions and string arguments

A string parameter is passed **by reference to a private copy**: the caller passes, in the
argument position of the parameter, an sref to a string that nothing else will read or write —
a fresh `scell` holding a copy of the argument (§4.2), or the `scell` that already holds the
result of a `STR$` or string FN call in that argument. The callee keeps that sref in its local
cell k (DESIGN.md §5.3) and `sparam k` returns it, so assigning a string parameter writes into
the caller's private cell and never into a caller's variable. A **string function's value** is
the `scell` the caller names in `scallfn`'s B: the callee receives its address as a hidden
argument (DESIGN.md §5.3: `x8` on arm64, `%rax` on x86_64), keeps it in local cell NP, `sfv`
returns it (multi-line), a multi-line string function's prologue sets it to the empty string, and
`sret A` copies A into it. Because a function is never active twice at once (RECURSIVE FUNCTION,
LANGUAGE.md §7.10), no string ever needs a stack.

The `fnarg` rule (§3.2) is unchanged: argument k of a call is `fnarg k` (k ≥ 1) or the
`callfn`/`scallfn` `A` (k = 0); its temp is a number for a numeric parameter and an sref for a
string parameter. `callfn` calls numeric functions only, `scallfn` string functions only.

#### 3.3.2 The `fsel` rule

`fsel A` is always **immediately** followed by one of `prnum prstr prsv prcomma prsemi prtab prnl
inbeg innum insv inend`, and that instruction acts on file `trunc(A)` (the runtime checks the
number, `INVALID FILE NUMBER`, and the mode, `ILLEGAL FILE COMMAND`) instead of standard output /
the standard-input INPUT dialogue: on file 0 a print opcode is exactly the plain one, an input
opcode reads standard input with the INPUT # rules (no prompt, no diagnostics, END OF FILE). A
print or input opcode without a preceding `fsel` is the Fourth Edition operation, unchanged. So
items of a PRINT # are evaluated before their `fsel` (a function called by an item may print to
standard output), and nothing can come between the selection and its use.

## 4. Canonical lowering (frontend → IR)

The frontend must produce **exactly** this IR; `tests/ir/*.ir` depend on it.

### 4.1 Numbering

* **Line labels.** Before lowering, `main` gets label ids `0..N-1` for the N lines of the main
  program (every line not in a multi-line DEF body) in ascending line order
  (`_ir_new_label(main, line)`); then each multi-line function, in ascending order of its DEF
  line, is created (`_ir_func_begin`, `_ir_func_set`) and gets label ids `0..M-1` for the M lines
  of its body. Without multi-line DEFs this is exactly the earlier numbering.
* **Internal labels** are allocated in the function being lowered (`main` or a multi-line
  function) in the order the lowering below requests them, starting after its line labels.
* **Temps** are allocated per function, starting at 0, at the moment the instruction that
  defines them is emitted. Expressions are lowered in **post-order, left operand first**, one
  instruction per node. There is **no** constant folding, CSE or dead-code removal.
* **FOR index k** counts FOR statements in ascending line order from 0.
* **String ids** count the string constants outside DATA statements (PRINT labels and the
  constants of LET, IF and CHANGE; Fifth Edition: every string constant in a string expression,
  e.g. a function argument, a `LEN`/`ASC`/`VAL` argument, a single-line string DEF's expression
  at its DEF line, a PRINT # item; never a FILES name) in ascending line order, left to right,
  from 0 (no deduplication) — for programs without the new statements, exactly the PRINT literals as
  before. **Data index** likewise for numeric DATA values, **string data index** for string DATA
  values (separately, from 0).
* **String temp cells** (Fifth Edition) are numbered from 0 over the whole module, in the order
  their `scell` instructions are emitted (lines in ascending order; a single-line DEF's
  expression is lowered at its DEF line, a multi-line body line by line). Each `scell` emitted by
  the rules below allocates a **new** cell (`_ir_new_stemp`); no cell is shared by two `scell`
  instructions. **File numbers** count the FILES names in ascending line order, left to right,
  from 1 (`_ir_add_file`).

### 4.2 Expressions (emit order)

| Source | Emitted |
|--------|---------|
| constant | `tN = const BITS` (BITS = strtod of the constant's text) |
| simple variable v (not a parameter of the enclosing DEF) | `tN = ldv v` |
| parameter k of the enclosing DEF (inside its expression or body) | `tN = param` (k = 0) / `tN = param k` (every occurrence emits a new `param`) |
| `FNx` without `(` inside the multi-line body of FNx (its value variable) | `tN = ldfv` |
| `( e )` | lowering of e (nothing extra) |
| `+ e` (leading unary plus) | lowering of e |
| `- t…` (leading minus, §5.1 of LANGUAGE.md) | lowering of the first *term*, then `tN = neg tTerm`, then the rest of the expression |
| `a op b` (`+ - * / ^`) | a, then b, then `tN = add/sub/mul/div/pow ta, tb` |
| `F(e)` builtin (not RND) | e, then `tN = sin/cos/…/int/sgn/cot te` |
| `NUM` / `DET` | `tN = num` / `tN = det` |
| `RND(e)` | e (its value is discarded), then `tN = rnd` |
| bare `RND` | `tN = rnd` |
| `FNx(e)` | e, then `tN = callfn FNx, te` |
| `FNx(e0, e1, …, ek)` (k ≥ 1) | e0, e1, …, ek (left to right), then `fnarg 1, te1`, …, `fnarg k, tek`, then `tN = callfn FNx, te0` |
| `FNx` without `(` (a call with no arguments) | `tN = callfn FNx` |
| `L(i)` | i, then `tN = ald1 L, ti` |
| `L(i, j)` | i, j, then `tN = ald2 L, ti, tj` |
| `LEN(s)` / `ASC(s)` / `VAL(s)` | s's string reference tS (below), then `tN = len tS` / `asc` / `val` |
| parameter k of the enclosing DEF that is a string parameter, in a string position | `tN = sparam` (k = 0) / `tN = sparam k` |

String expressions (LANGUAGE.md §4.4, §4.6) are lowered where a statement, function or argument
needs one; each yields one sref temp, "its string reference":

| Source | Emitted |
|--------|---------|
| `"…"` (string constant K) | `tN = slit sK` |
| `V$` | `tN = svar V$` |
| `L$(i)` | i, then `tN = sald1 L$, ti` |
| `T$(i, j)` (string table, Fifth Edition) | i, j, then `tN = sald2 T$, ti, tj` |
| `STR$(e)` | e, then `tC = scell %sK` (a new cell), `sstr tC, te`; the reference is tC |
| `FNx$` inside the multi-line body of FNx$ (its value variable) | `tN = sfv` |
| `FNx$` without `(` (a call with no arguments) | `tC = scell %sK`, `scallfn tC, FNx`; the reference is tC |
| `FNx$(a0, …, ak)` | the arguments as for a call below, then `tC = scell %sK`, then `fnarg 1, ta1`, …, `fnarg k, tak`, then `scallfn tC, FNx, ta0`; the reference is tC |

**Arguments of a call** (`FNx(…)` and `FNx$(…)`, Fifth Edition rules; for numeric arguments
exactly the rows above): the arguments are lowered left to right; a numeric argument is its
expression's temp; a string argument whose expression is a `STR$` or string FN call is that
call's result cell; any other string argument (a constant, a variable, an array element, a
string parameter or a value variable) is lowered to its reference tR and then **copied into a
new cell** right away: `tC = scell %sK`, `sset tC, tR`; the argument is tC. So `FNA(X, B$)` is
`tX = ldv X`, `tB = svar B$`, `tC = scell %s0`, `sset tC, tB`, `fnarg 1, tC`, `tN = callfn FNA,
tX`.

### 4.3 Statements

Every program line, in ascending order, first emits `line <n>` (which also defines its line
label) into the function it belongs to — `main`, or the multi-line function whose body contains
it — then, into the same function:

| Statement | Emitted after `line` |
|-----------|----------------------|
| `REM`, `DATA`, `DIM`, single-line `DEF` | nothing (DATA values go to the data tables; DIM to the array tables; a single-line DEF lowers its expression into function FNx, see 4.4) |
| multi-line `DEF` header (in `main`) | `jmp @m`, m = the first line after its FNEND (4.4) |
| `FNEND` (in its function) | `tN = ldfv`; `ret tN` |
| `LET v = e` | e; `stv v, te` (v a parameter k of the enclosing multi-line DEF: `stparam k, te`; v = `FNx` in its own body: `stfv te`) |
| `LET L(i) = e` | i; e; `ast1 L, ti, te` |
| `LET L(i,j) = e` | i; j; e; `ast2 L, ti, tj, te` |
| `LET x1 = x2 = … = e` (numeric, ≥ 2 targets) | for each target left to right: its subscripts (i; or i; j); then e; then for each target left to right its store with value te (`stv`, `ast1`, `ast2`, `stparam`, `stfv` as above). With one target this is the three rows above. |
| `LET s1 = … = sk = r` (string targets) | for each target left to right: a string variable V$: `tsj = svar V$`; a list element `L$(i)`: only i; then r's string reference; then for each target left to right: (a list element: `tsj = sald1 L$, ti`;) `sset tsj, tr` — the `sald1` immediately before its `sset`, so the subscript is checked at the store (LANGUAGE.md §7.1) |
| `PRINT …` | for each element left to right: string constant → `prstr sK`; string variable or element — Fifth Edition: any other string expression (`STR$(…)`, `FNx$…`, a string parameter, a value variable `FNx$`) — → its string reference, then `prsv tr`; `TAB(e)` → e, then `prtab te`; expression → its lowering then `prnum te`; `,` → `prcomma`; `;` → `prsemi` **only if the previous element was an expression**, otherwise nothing. After the list: `prnl` unless the last element was `,` or `;` (an empty PRINT emits just `prnl`). |
| `GOTO n` | `jmp @n` |
| `IF a REL b THEN n`, `IF a REL b GOTO n` | a; b; `jcmp REL, ta, tb, @n` |
| `IF r1 REL r2 THEN n` (strings; also `GOTO`) | r1's string reference; r2's; `sjcmp REL, tr1, tr2, @n` |
| `ON e GOTO n1, …, nN` (also `THEN`) | e; `tk = onsel te, N`; for i = 1 … N−1: `tc = const <i>`, `jcmp eq, tk, tc, @ni`; then `jmp @nN` |
| `GOSUB n` | allocate internal label R; `gosub @n, LR`; `label LR` |
| `RETURN` | `return` |
| `READ x1, x2, …` | for each target in order: numeric: [subscripts i (, j)]; `tN = read`; then `stv v, tN` or `ast1 L, ti, tN` or `ast2 L, ti, tj, tN` (or `stparam k, tN` for a parameter); string: a string variable V$: `tr = svar V$`, `sread tr`; a list element `L$(i)`: i, then the element form `sread L$, ti` (§3.2: the value is taken, then the subscript checked at the store) |
| `INPUT x1, x2, …` | `inbeg`; for each target in order: numeric: [subscripts]; `tN = innum`; then its store as in READ; string: a string variable V$: `tr = svar V$`, `insv tr`; a list element `L$(i)`: i, then the element form `insv L$, ti` (the field is taken, with its diagnostics, before the subscript is checked); after the last target `inend` |
| `RESTORE` / `RESTORE*` / `RESTORE$` | `restore all` / `restore num` / `restore str` |
| `RANDOMIZE` | `randomize` |
| `CHANGE r TO L` | r's string reference; `chgs2n L, tr` |
| `CHANGE L TO s` | a string variable V$: `ts = svar V$`, `chgn2s L, ts`; a list element `M$(i)`: i, then the element form `chgn2s L, M$, ti` (the conversion's checks come before the subscript check) |
| `END` | `end` |
| `STOP` | `stop` |
| `MAT READ X1, X2, …` | for each target in order: if it has dimensions `(r)` or `(r, c)`: r; [c;] `matredim X, tr` or `matredim X, tr, tc`; then `matread X`. A string list `X$`: [r; `smatredim X$, tr`;] `smatread X$` |
| `MAT PRINT X1 s1 X2 s2 …` | for each item in order: `prnl` if it is not the first item; `matprint X, packed` if the separator after it is `;`, else `matprint X, zoned` (a string list: `smatprint X$, packed` / `zoned`) |
| `MAT INPUT V` / `MAT INPUT V$` | `matinput V` / `smatinput V$` |
| `MAT X = Y` | `matcopy X, Y` |
| `MAT X = Y + Z` / `- Z` / `* Z` | `matadd X, Y, Z` / `matsub X, Y, Z` / `matmul X, Y, Z` |
| `MAT X = (e) * Y` | e; `matscale X, te, Y` |
| `MAT X = ZER` / `CON` | `matzer X` / `matcon X` |
| `MAT X = ZER(r)` / `CON(r)` | r; `matredim X, tr`; `matzer X` / `matcon X` |
| `MAT X = ZER(r, c)` / `CON(r, c)` | r; c; `matredim X, tr, tc`; `matzer X` / `matcon X` |
| `MAT X = IDN` | `matidn X` |
| `MAT X = IDN(n)` | n; `matredim X, tn, tn`; `matidn X` |
| `MAT X = TRN(Y)` / `INV(Y)` | `mattrn X, Y` / `matinv X, Y` |
| `FILES …` (Fifth Edition) | nothing (each name is added with `_ir_add_file` when the line is parsed) |
| string table element target `T$(i,j)` in `LET` (Fifth Edition) | target phase: i; j. Store phase: `te = sald2 T$, ti, tj`, `sset te, tr` (the `sald2` immediately before its `sset`, like `sald1`) |
| string table element target `T$(i,j)` in `READ`, `INPUT` | i; j; `tC = scell %sK`; `sread tC` / `insv tC`; `te = sald2 T$, ti, tj`; `sset te, tC` (the value is taken into the cell first, then the subscripts are checked at the store) |
| `CHANGE L TO T$(i,j)` | i; j; `tC = scell %sK`; `chgn2s L, tC`; `te = sald2 T$, ti, tj`; `sset te, tC` |
| `LET FNx$ = r` (in the body of FNx$; also one target of a multiple string LET) | target phase: `tv = sfv`; store phase: `sset tv, tr` |
| a string parameter target `P$` (multi-line body) in LET, READ, INPUT, INPUT #, CHANGE | as a string variable with `tr = sparam k` in place of `tr = svar P$` |
| `MAT READ T$(r, c)` (string table) | r; c; `smatredim T$, tr, tc`; `smatread T$` (without dimensions: `smatread T$`) |
| `MAT PRINT … T$ …` (string table) | `smatprint T$, zoned` / `packed`, as for a string list |
| `SCRATCH #e` | e; `scratch te` |
| `RESTORE #e` | e; `frestore te` |
| `IF END #e THEN n` (also `GOTO`) | e; `jeof te, @n` |
| `PRINT #e` [`,` items] | e (→ tF); then exactly the PRINT lowering of the items (above), except that every emitted `prnum prstr prsv prtab prcomma prsemi prnl` is immediately preceded by `fsel tF` (the item's value — its expression or string reference — is lowered before the `fsel`). `PRINT #e` alone: e; `fsel tF`; `prnl` |
| `INPUT #e, x1, …` | e (→ tF); `fsel tF`; `inbeg`; then each target exactly as in INPUT except that every `innum` / `insv` is immediately preceded by `fsel tF` (the subscripts, and for a string variable its `svar`, come before the `fsel`; a string table element uses the cell form above with `fsel tF` before its `insv tC`); after the last target `fsel tF`, `inend` |
| `FOR v = a TO b [STEP c]` (FOR index k) | see below |
| `NEXT v` (closing FOR k) | see below |

FOR (allocate internal labels Z, B, X in that order when the FOR is lowered):

```
  <a>  -> ta
  <b>  -> tb
  <c>  -> tc            ; without STEP: tc = const 0x3FF0000000000000 ; 1
  stv %limk, tb
  stv %stepk, tc
  jfor ta, tb, tc, LZ
  stv v, ta
  jmp LB
  label LZ
  td = sub ta, tc
  stv v, td
  jmp LX
  label LB
```

NEXT v, closing FOR k (uses that FOR's labels B and X; in a multi-line body, if v is parameter
k' of the function, every `stv v` above and below is `stparam k'` and every `ldv v` is
`param k'`; the labels belong to the function being lowered):

```
  te = ldv v
  ts = ldv %stepk
  tg = add te, ts
  tl = ldv %limk
  jfor tg, tl, ts, LX
  stv v, tg
  jmp LB
  label LX
```

### 4.4 Functions

`DEF FNx(p0, …, pk-1) = e` (single-line, k = 0…8) creates function index 1+x
(`_ir_func_begin(module, 1+x, slot of p0 or IR_NONE, DEF line)`, then
`_ir_func_set(fn, FUNC_KIND_FN, k, slots, 0)`) and lowers e into it with the rules of 4.2 (temps
from 0), followed by `ret te`. Functions are created in the order their DEF lines are lowered, but
are stored (and dumped, and emitted) at their fixed index, i.e. in letter order.

A **multi-line** `DEF FNx(p0, …)` (no `=`) creates function 1+x the same way with
`_ir_func_set(fn, FUNC_KIND_FNML, k, slots, <FNEND line>)` before any line is lowered (§4.1:
its line labels are allocated then). In `main` the DEF line lowers to `line <n>` and `jmp @m`
(m = the first main line after the FNEND; it exists, because END is the last line and is not in
a body). The body lines are lowered into the function with the statement rules of 4.3 (temps and
internal labels of that function), GOTO/IF/ON targets naming its own line labels; FNEND lowers to
`line <n>`, `tN = ldfv`, `ret tN`.

**String functions and string parameters** (Fifth Edition). For every function with a string
parameter or a string result the frontend calls `_ir_set_fnkind(module, 1+x, bits)` when it
creates the function (`FNK_SPARAM0 << k` for each string parameter k, `FNK_STRING` for `FNx$`);
`PARAMS[k]` of a string parameter `P$` is the string slot of `P$`. A single-line string
function `DEF FNx$(…) = s` lowers s (its string reference tS) followed by `sret tS`. In a
multi-line string function, FNEND lowers to `line <n>`, `tN = sfv`, `sret tN`. A string parameter
is read with `sparam k` (every occurrence emits a new `sparam`), its value variable with `sfv`.

## 5. Text dump format (`--emit-ir`)

The dump is ASCII, every line terminated by LF, no trailing spaces, no tabs. Grammar (literal
text in quotes, `SP` = one space):

```
dump      := header module-line array-line* sarray-line* string-line* data-line* sdata-line*
             [ stemps-line ] file-line* function+
header    := "; baysick-ir 1" LF
module-line := "module slots=" U " fors=" U " funcs=" U " strings=" U " data=" U LF
array-line  := "array " LETTER " dims=1 b1=" U LF
             | "array " LETTER " dims=2 b1=" U " b2=" U LF          (letters A..Z, used arrays only)
sarray-line := "sarray " LETTER " dims=1 b1=" U LF                   (string arrays A$..Z$ in letter order, used ones only)
             | "sarray " LETTER " dims=2 b1=" U " b2=" U LF          (string table, Fifth Edition)
string-line := "string s" U SP '"' BYTES '"' LF                       (raw bytes of the literal)
data-line   := "data d" U SP HEX " ; " G17 LF
sdata-line  := "sdata d" U SP '"' BYTES '"' LF                         (raw bytes of the string DATA value)
stemps-line := "stemps " U LF                                          (NSTEMPS; only if NSTEMPS > 0)
file-line   := "file #" U SP '"' BYTES '"' LF                          (FILES name of file number U, from 1)
function  := func-head instr* "endfunc" LF
func-head := "func main temps=" U " labels=" U LF
           | "func " FNAME " param=" PVAR " temps=" U " labels=" U LF          (single-line, one parameter)
           | "func " FNAME " params=" PLIST " temps=" U " labels=" U LF       (single-line, 0 or 2..8 parameters)
           | "func " FNAME " params=" PLIST " def=" U " fnend=" U
             " temps=" U " labels=" U LF                                        (multi-line, any count)
FNAME := "FN" LETTER [ "$" ]                                           ("$": a string function, FNK_STRING)
PLIST := "-" | PVAR { "," PVAR }                                       ("-" = no parameters)
PVAR  := VAR [ "$" ]                                                   ("$": a string parameter)
instr     := "  " text-form LF                                       (text forms from §3)
U   := unsigned decimal, no leading zeros ("0" for zero)
HEX := "0x" 16 uppercase hexadecimal digits of the IEEE bits
G17 := the value formatted exactly as C printf("%.17g")
```

* `funcs=` counts present functions (main + defined FNs). Functions are dumped `main` first, then
  FNA…FNZ in letter order, skipping absent ones.
* `const` lines end with `" ; " G17` like data lines.
* MAT opcodes print as in §3 (`matprint A, zoned`, `matscale C, t3, A`, …); see
  `tests/ir/mat_ops.ir` for every form. The §3.2 opcodes print as in their table; see
  `tests/ir/ed4_strings.ir`, `tests/ir/ed4_input_on.ir`, `tests/ir/ed4_functions.ir` and, for the
  element forms of `sread`, `insv` and `chgn2s`, `tests/ir/ed4_slist_targets.ir`.
* `module-line` is unchanged: string lists and string DATA are counted by their lines only.
  A dump of a program without Third/Fourth Edition features is byte-identical to the earlier
  format. Likewise the Fifth Edition adds only the `dims=2` sarray form, the optional `stemps`
  line, `file` lines, the `$` forms of FNAME and PVAR and the §3.3 text forms, so a dump of a
  program without Fifth Edition features is byte-identical to the Fourth Edition format. See
  `tests/ir/ed5_*.ir`.
* BYTES of a `file` line are written raw like those of a `string` line; a FILES name cannot
  contain `"` or LF either.
* BYTES of a `string` or `sdata` line are written raw (no escaping); since neither can contain
  `"` or LF, the line is unambiguous.
* Operand separators are `", "` exactly as in the §3 text forms; `=` has one space on each side.

Example (`tests/ir/let_print.bas`):

```
10 LET A = 2
20 LET B1 = -A + 3 * (A - 1) ^ 2 / 4
30 PRINT "A ="A, B1; "END";
40 PRINT
50 END
```

```
; baysick-ir 1
module slots=286 fors=0 funcs=1 strings=2 data=0
string s0 "A ="
string s1 "END"
func main temps=15 labels=5
  line 10
  t0 = const 0x4000000000000000 ; 2
  stv A, t0
  line 20
  t1 = ldv A
  t2 = neg t1
  t3 = const 0x4008000000000000 ; 3
  t4 = ldv A
  t5 = const 0x3FF0000000000000 ; 1
  t6 = sub t4, t5
  t7 = const 0x4000000000000000 ; 2
  t8 = pow t6, t7
  t9 = mul t3, t8
  t10 = const 0x4010000000000000 ; 4
  t11 = div t9, t10
  t12 = add t2, t11
  stv B1, t12
  line 30
  prstr s0
  t13 = ldv A
  prnum t13
  prcomma
  t14 = ldv B1
  prnum t14
  prsemi
  prstr s1
  line 40
  prnl
  line 50
  end
endfunc
```

## 6. Verifier (`_ir_verify`)

The driver runs the verifier on every module before dumping or emitting; a failure is an
internal error (exit 4). Checks:

1. Every opcode is `< OP_COUNT`; field usage matches §3, §3.1 and §3.2 (unused fields are
   `IR_NONE`/0; `matprint` and `smatprint` IMM is 0 or 1; `matredim` B may be `IR_NONE`, A may
   not; `restore` IMM is 0…2; `onsel` IMM is ≥ 1; `fnarg` IMM is 1…7; `param`/`stparam` IMM is
   `< NPARAMS` of the function; `callfn` A may be `IR_NONE`, a call that loads no argument;
   `sread`, `insv`, `chgn2s` with A = `IR_NONE` are the element form of §3.2: B is a number
   temp, X a declared string list (`sread`, `insv`; IMM 0) or, for `chgn2s`, X a numeric list
   and IMM a declared string list letter).
2. Every temp operand (a field whose kind is temp for that opcode, §3.1, §3.2) is `< NTEMPS`, is
   defined by an earlier instruction in the same function, and has the kind the field requires
   (sref for the sref fields of §3.2, number everywhere else, including the subscript `B` of an
   element form). A string reference that is written (`sset` A, `sread` A, `insv` A, the
   `chgn2s` target A) is never defined by a `slit`.
3. Every label referenced by `jmp/jcmp/sjcmp/jfor/jeof/gosub` (both labels) is `< NLABELS` of the
   same function and is defined by exactly one `line`/`label` of that function; every label id
   is defined exactly once.
4. Slots are `< NSLOTS` (no rule limits the FOR slots to `main`: a multi-line FN body writes
   those of its own FOR loops with `stv`); array letters refer to arrays with `DIMS` ≠ 0 and the
   right dimensionality (`ald1/ast1` ↔ 1, `ald2/ast2` ↔ 2; MAT opcodes accept either, in every
   array-kind field; `matinput`, `chgs2n`, `chgn2s` ↔ 1); string-list letters (in `X`, or in the
   `IMM` of `chgn2s`'s element form) refer to sarrays with `DIMS` = 1 (rule 8 lists the Fifth
   Edition exceptions for string tables); string slots are `< 286`; string ids `< NSTRINGS`; `callfn` targets are
   present FN functions, and the number of arguments (`fnarg` rule, §3.2) equals the callee's
   `NPARAMS`.
5. Placement rules of §3; `main` ends with `end`; each FN function ends with `ret`; `fnarg`
   instructions are consecutive, numbered 1, 2, … and immediately followed by a `callfn`.
6. `NSLOTS == 286 + 2*NFORS`; every array with `DIMS ≠ 0` has `(B1+1)*(B2+1) <= 1 000 000`,
   every string list `B1 + 1 <= 1 000 000`.
7. Function records: `KIND` is `FUNC_KIND_FN` or `FUNC_KIND_FNML` for index ≥ 1; `NPARAMS ≤ 8`;
   `PARAMS[k]` `< 286` for `k < NPARAMS` and `IR_NONE` after; `PARAM` = `PARAMS[0]` or `IR_NONE`;
   `ENDLINE > DEFLINE` for `FUNC_KIND_FNML`, 0 otherwise.
8. Fifth Edition:
   * `scell` X `< NSTEMPS`; `sald2` X a declared string table (sarray `DIMS` = 2), `sald1` and
     the element forms of `sread`/`insv`/`chgn2s` a declared string **list** (`DIMS` = 1);
     `smatinput` a string list; `smatredim` B = `IR_NONE` for a string list and a number temp for
     a string table (A a number temp in both); `smatread`/`smatprint` either.
   * `fnkinds` of `main` is 0; no bits above `FNK_STRING`; string-parameter bits only below
     `NPARAMS`; `PARAMS[k]` of a string parameter `< 286` (a string slot).
   * `sparam` IMM `< NPARAMS` with bit IMM set; `param`/`stparam` IMM with bit IMM clear; `sfv`
     only in a multi-line function with `FNK_STRING`; `ldfv`/`stfv` and `ret` only in functions
     without `FNK_STRING`, `sret` only in functions with it; every string function ends with
     `sret`.
   * `callfn` targets a present function without `FNK_STRING`, `scallfn` one with it; for each
     argument k (A for k = 0, `fnarg k` otherwise) the temp kind is sref exactly when the callee's
     bit k is set. `scallfn` B is an sref defined by `scell`.
   * The written sref of `sstr` A, `sset` A, `sread` A, `insv` A and the `chgn2s` target A is
     never defined by a `slit`.
   * `fsel` is immediately followed by one of `prnum prstr prsv prcomma prsemi prtab prnl inbeg
     innum insv inend` (§3.3.2), and A is a number temp; `jeof`, `scratch`, `frestore` have a
     number temp in A (`jeof`: X a label, rule 3).
   * `NFILES ≤ LIM_FILES`; every file name has 1…`LIM_FILE_NAME` bytes and no byte 0.
   * every string table has `(B1+1)*(B2+1) <= 1 000 000`.
   * Not checked: two properties of the canonical lowering (§4) are guaranteed by the frontend,
     and the verifier does not check them — the `fnkinds` word of an absent function (0: only a
     DEFined function gets one), and that no cell is shared by two `scell` instructions (§4.1).

## 7. Writing a new backend

A backend translates one Module into one assembly text file (see `docs/DESIGN.md` §Backend
interface for the descriptor and §Runtime ABI for the calls). A minimal, correct strategy:

1. Emit the data: `NSLOTS` zeroed doubles for globals; 286 zeroed 16-byte string descriptors
   for the string variables; per used array a zeroed element block of `(B1+1)*(B2+1)` doubles and
   a 32-byte `RTA_*` descriptor; per used string list a zeroed block of `B1+1` string descriptors
   and an `RTA_*` descriptor; the strings and a string descriptor (`SD_*`, `CAP` 0) per string;
   `_bsk_data`, `_bsk_data_count`, `_bsk_sdata` (one `SD_*` per string DATA value) and
   `_bsk_sdata_count`.
2. For each present function emit a function with a frame of `8*NTEMPS` bytes plus its local
   cells (parameters; for a multi-line function also the value variable and the saved run-time
   line); temp *n* lives at a fixed frame offset; an sref temp holds a pointer.
3. Translate each instruction independently: load operand temps, compute or call the runtime
   entry listed in DESIGN.md, store `DST`. Labels become local assembler labels.
4. `line` stores IMM to `_bsk_curline`. `gosub` pushes the *address* of the return label via
   `_bsk_gosub_push` and jumps; `return` calls `_bsk_gosub_pop` and jumps indirectly to the result.
5. Each MAT opcode is one call: the address of each named array's descriptor in an argument
   register (target first), the temp operands in floating-point argument registers, the
   `matprint` mode as an integer (DESIGN.md §6.5). The descriptor's `RTA_CAP` field must hold
   `(B1+1)·(B2+1)`, and the descriptor must be writable (MAT rewrites the current bounds).

6. Each §3.2 opcode is one runtime call (DESIGN.md §6.7) with srefs as pointer arguments, or a
   move of a double between a temp and a local cell (`fnarg` loads argument register k directly).
7. The §3.3 opcodes (Fifth Edition) are runtime calls too (DESIGN.md §6.8), plus: a static block
   of `NSTEMPS` zeroed string descriptors for `scell`; string-table descriptors and storage
   like numeric tables but with 16-byte elements; the `_bsk_files` table of the FILES names; and
   for string parameters and string functions the register convention of DESIGN.md §5.3
   (string argument k in the k-th integer argument register, the result descriptor's address in
   a hidden register).

Nothing else is needed; all language rules live in the runtime or are explicit opcodes.

Two backends follow this recipe and are specified instruction by instruction: `arm64-macos`
(DESIGN.md §5.3) and `x86_64-linux` (DESIGN.md §5.4). The IR is identical for both; only the
descriptor, the emitted syntax and the runtime ABI names/registers (DESIGN.md §6.4) differ.
