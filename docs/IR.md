# Baysick IR Specification

**Status: normative.** Binary layouts are pinned in `include/ir.inc`; this document gives their
meaning, the semantics of every opcode, the **canonical lowering** from BASIC (so that
`--emit-ir` output is byte-for-byte reproducible), and the exact text grammar of the dump.
Language semantics referenced here are defined in `docs/LANGUAGE.md`.

## 1. Design and rationale

The IR is a **linear, target-independent three-address code over virtual registers** ("temps"):

* every value is an IEEE-754 double; there are no other types;
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
that follows the definition. Temps are function-local. A temp may be live across `callfn`.

## 2. Module structure

A **Module** (`IRM_*`, 2192 bytes) holds:

| Part | Meaning |
|------|---------|
| `NFORS` | number of FOR statements; FOR *k* (0-based, in ascending line order) |
| `NSLOTS` | number of global variable cells = 286 + 2·NFORS |
| strings | table of PRINT literals `s0, s1, …` (`IRS_*`: pointer + length, no NUL) |
| data | the DATA block: `NDATA` doubles as raw IEEE bits, in program order |
| arrays | 26 entries `IRA_*` (letter A…Z): `DIMS` 0 (unused) / 1 / 2, bounds `B1`, `B2` (the initial bounds; they fix the storage `(B1+1)·(B2+1)`; MAT statements may change the run-time shape within it, LANGUAGE.md §7.14.3) |
| funcs | 27 entries `IRF_*`: index 0 = `main`, index 1+L = `FN` letter L; `PRESENT` = 0 if absent |

A **Function** (`IRF_*`) holds a linear array of instructions, its temp count, and a label table
(`LABELS[id]` = BASIC line number for a line label, 0 for an internal label). `main` has one line
label per program line plus internal labels; FN functions have no labels.

### 2.1 Operand kinds

| Kind | Encoding | Text |
|------|----------|------|
| temp | u32 index `0..NTEMPS-1` | `t<n>` |
| slot | u32 in `IRI_X`: `0..285` user scalars, `286+2k` LIMIT of FOR k, `287+2k` STEP of FOR k | `A`, `X7`, `%lim3`, `%step3` |
| label | u32 id in `IRI_X` (or `IRI_IMM` for gosub's return label) | `@<line>` for a line label, `L<id>` for an internal label |
| array | u32 letter 0..25 in `IRI_X`; MAT opcodes also in `IRI_A` / `IRI_B` (§3.1) | `A` … `Z` |
| function | u32 letter 0..25 in `IRI_X` | `FNA` … `FNZ` |
| string | u32 id in `IRI_X` | `s<n>` |
| constant | u64 IEEE-754 bits in `IRI_IMM` | `0x` + 16 uppercase hex digits |
| relation | u16 in `IRI_REL` | `eq ne lt le gt ge` |
| line number | u64 in `IRI_IMM` (`line` op) | decimal |

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
| `callfn` 26 | DST, X=fn, A | `t6 = callfn FNA, t5` | DST := result of function FN X called with argument A |
| `param` 27 | DST | `t0 = param` | DST := the argument of the current FN function |
| `ret` 28 | A | `ret t3` | return A from the current FN function |
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

Placement rules (checked by the verifier, §6): `param` and `ret` occur only in FN functions;
`line`, `label`, `jmp`, `jcmp`, `jfor`, `gosub`, `return`, `read`, `pr*`, `mat*`, `end`, `stop`,
`stv` to a FOR slot occur only in `main`. Every FN function ends with `ret`; `main` ends with `end` (because
END must be the last line). Instructions after an unconditional transfer (`jmp`, `return`, `end`,
`stop`, `ret`) up to the next label are reachable only through labels, as usual.

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

## 4. Canonical lowering (frontend → IR)

The frontend must produce **exactly** this IR; `tests/ir/*.ir` depend on it.

### 4.1 Numbering

* **Line labels.** Before lowering, `main` gets label ids `0..N-1` for the N program lines in
  ascending line order (`_ir_new_label(main, line)`).
* **Internal labels** are allocated in `main` in the order the lowering below requests them,
  starting at N.
* **Temps** are allocated per function, starting at 0, at the moment the instruction that
  defines them is emitted. Expressions are lowered in **post-order, left operand first**, one
  instruction per node. There is **no** constant folding, CSE or dead-code removal.
* **FOR index k** counts FOR statements in ascending line order from 0.
* **String ids** count PRINT string literals in ascending line order, left to right, from 0
  (no deduplication). **Data index** likewise for DATA values.

### 4.2 Expressions (emit order)

| Source | Emitted |
|--------|---------|
| constant | `tN = const BITS` (BITS = strtod of the constant's text) |
| simple variable v (not the FN parameter) | `tN = ldv v` |
| the FN parameter (inside its DEF body) | `tN = param` (every occurrence emits a new `param`) |
| `( e )` | lowering of e (nothing extra) |
| `+ e` (leading unary plus) | lowering of e |
| `- t…` (leading minus, §5.1 of LANGUAGE.md) | lowering of the first *term*, then `tN = neg tTerm`, then the rest of the expression |
| `a op b` (`+ - * / ^`) | a, then b, then `tN = add/sub/mul/div/pow ta, tb` |
| `F(e)` builtin (not RND) | e, then `tN = sin/cos/…/int te` |
| `RND(e)` | e (its value is discarded), then `tN = rnd` |
| bare `RND` | `tN = rnd` |
| `FNx(e)` | e, then `tN = callfn FNx, te` |
| `L(i)` | i, then `tN = ald1 L, ti` |
| `L(i, j)` | i, j, then `tN = ald2 L, ti, tj` |

### 4.3 Statements

Every program line, in ascending order, first emits `line <n>` (which also defines its line
label), then:

| Statement | Emitted after `line` |
|-----------|----------------------|
| `REM`, `DATA`, `DIM`, `DEF` | nothing in `main` (DATA values go to the data table; DIM to the array table; DEF lowers its body into function FNx, see 4.4) |
| `LET v = e` | e; `stv v, te` |
| `LET L(i) = e` | i; e; `ast1 L, ti, te` |
| `LET L(i,j) = e` | i; j; e; `ast2 L, ti, tj, te` |
| `PRINT …` | for each element left to right: string → `prstr sK`; expression → its lowering then `prnum te`; `,` → `prcomma`; `;` → `prsemi` **only if the previous element was an expression**, otherwise nothing. After the list: `prnl` unless the last element was `,` or `;` (an empty PRINT emits just `prnl`). |
| `GOTO n` | `jmp @n` |
| `IF a REL b THEN n` | a; b; `jcmp REL, ta, tb, @n` |
| `GOSUB n` | allocate internal label R; `gosub @n, LR`; `label LR` |
| `RETURN` | `return` |
| `READ x1, x2, …` | for each target in order: [subscripts i (, j)]; `tN = read`; then `stv v, tN` or `ast1 L, ti, tN` or `ast2 L, ti, tj, tN` |
| `END` | `end` |
| `STOP` | `stop` |
| `MAT READ X1, X2, …` | for each target in order: if it has dimensions `(r)` or `(r, c)`: r; [c;] `matredim X, tr` or `matredim X, tr, tc`; then `matread X` |
| `MAT PRINT X1 s1 X2 s2 …` | for each item in order: `prnl` if it is not the first item; `matprint X, packed` if the separator after it is `;`, else `matprint X, zoned` |
| `MAT X = Y` | `matcopy X, Y` |
| `MAT X = Y + Z` / `- Z` / `* Z` | `matadd X, Y, Z` / `matsub X, Y, Z` / `matmul X, Y, Z` |
| `MAT X = (e) * Y` | e; `matscale X, te, Y` |
| `MAT X = ZER` / `CON` | `matzer X` / `matcon X` |
| `MAT X = ZER(r)` / `CON(r)` | r; `matredim X, tr`; `matzer X` / `matcon X` |
| `MAT X = ZER(r, c)` / `CON(r, c)` | r; c; `matredim X, tr, tc`; `matzer X` / `matcon X` |
| `MAT X = IDN` | `matidn X` |
| `MAT X = IDN(n)` | n; `matredim X, tn, tn`; `matidn X` |
| `MAT X = TRN(Y)` / `INV(Y)` | `mattrn X, Y` / `matinv X, Y` |
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

NEXT v, closing FOR k (uses that FOR's labels B and X):

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

`DEF FNx(p) = e` creates function index 1+x with `PARAM` = slot of p and `DEFLINE` = the DEF
line, and lowers e into it with the rules of 4.2 (temps from 0), followed by `ret te`. Functions
are created in the order their DEF lines are lowered, but are stored (and dumped, and emitted) at
their fixed index, i.e. in letter order.

## 5. Text dump format (`--emit-ir`)

The dump is ASCII, every line terminated by LF, no trailing spaces, no tabs. Grammar (literal
text in quotes, `SP` = one space):

```
dump      := header module-line array-line* string-line* data-line* function+
header    := "; baysick-ir 1" LF
module-line := "module slots=" U " fors=" U " funcs=" U " strings=" U " data=" U LF
array-line  := "array " LETTER " dims=1 b1=" U LF
             | "array " LETTER " dims=2 b1=" U " b2=" U LF          (letters A..Z, used arrays only)
string-line := "string s" U SP '"' BYTES '"' LF                       (raw bytes of the literal)
data-line   := "data d" U SP HEX " ; " G17 LF
function  := func-head instr* "endfunc" LF
func-head := "func main temps=" U " labels=" U LF
           | "func FN" LETTER " param=" VAR " temps=" U " labels=" U LF
instr     := "  " text-form LF                                       (text forms from §3)
U   := unsigned decimal, no leading zeros ("0" for zero)
HEX := "0x" 16 uppercase hexadecimal digits of the IEEE bits
G17 := the value formatted exactly as C printf("%.17g")
```

* `funcs=` counts present functions (main + defined FNs). Functions are dumped `main` first, then
  FNA…FNZ in letter order, skipping absent ones.
* `const` lines end with `" ; " G17` like data lines.
* MAT opcodes print as in §3 (`matprint A, zoned`, `matscale C, t3, A`, …); see
  `tests/ir/mat_ops.ir` for every form.
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

1. Every opcode is `< OP_COUNT`; field usage matches §3 and §3.1 (unused fields are
   `IR_NONE`/0; `matprint` IMM is 0 or 1; `matredim` B may be `IR_NONE`, A may not).
2. Every temp operand (a field whose kind is temp for that opcode, §3.1) is `< NTEMPS` and is
   defined by an earlier instruction in the same function.
3. Every label referenced by `jmp/jcmp/jfor/gosub` (both labels) is `< NLABELS` and is defined by
   exactly one `line`/`label` in `main`; every label id is defined exactly once.
4. Slots are `< NSLOTS`; array letters refer to arrays with `DIMS` ≠ 0 and the right
   dimensionality (`ald1/ast1` ↔ 1, `ald2/ast2` ↔ 2; MAT opcodes accept either, in every
   array-kind field); string ids `< NSTRINGS`; `callfn` targets
   are present FN functions.
5. Placement rules of §3; `main` ends with `end`; each FN function ends with `ret`.
6. `NSLOTS == 286 + 2*NFORS`; every array with `DIMS ≠ 0` has `(B1+1)*(B2+1) <= 1 000 000`.

## 7. Writing a new backend

A backend translates one Module into one assembly text file (see `docs/DESIGN.md` §Backend
interface for the descriptor and §Runtime ABI for the calls). A minimal, correct strategy:

1. Emit the data: `NSLOTS` zeroed doubles for globals; per used array a zeroed element block of
   `(B1+1)*(B2+1)` doubles and a 32-byte `RTA_*` descriptor; the strings; `_bsk_data` and
   `_bsk_data_count`.
2. For each present function emit a function with a frame of `8*NTEMPS` bytes (+ space for the
   FN argument); temp *n* lives at a fixed frame offset.
3. Translate each instruction independently: load operand temps, compute or call the runtime
   entry listed in DESIGN.md, store `DST`. Labels become local assembler labels.
4. `line` stores IMM to `_bsk_curline`. `gosub` pushes the *address* of the return label via
   `_bsk_gosub_push` and jumps; `return` calls `_bsk_gosub_pop` and jumps indirectly to the result.
5. Each MAT opcode is one call: the address of each named array's descriptor in an argument
   register (target first), the temp operands in floating-point argument registers, the
   `matprint` mode as an integer (DESIGN.md §6.5). The descriptor's `RTA_CAP` field must hold
   `(B1+1)·(B2+1)`, and the descriptor must be writable (MAT rewrites the current bounds).

Nothing else is needed; all language rules live in the runtime or are explicit opcodes.

Two backends follow this recipe and are specified instruction by instruction: `arm64-macos`
(DESIGN.md §5.3) and `x86_64-linux` (DESIGN.md §5.4). The IR is identical for both; only the
descriptor, the emitted syntax and the runtime ABI names/registers (DESIGN.md §6.4) differ.
