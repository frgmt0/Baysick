#!/bin/sh
# tests/run.sh -- Baysick test harness (POSIX sh). Builds nothing.
#
# usage: sh tests/run.sh [-v] [PATTERN...]
#   -v        show diffs for failures
#   PATTERN   only run tests whose name contains one of the patterns
#
# Environment:
#   BAYSICK               compiler to test        (default: build/baysick)
#   BAYSICK_TEST_TIMEOUT  seconds per program run (default: 10)
#
# Corpus layout and sidecar formats
# ---------------------------------
# tests/programs/NAME.bas   a program that must compile and run successfully
#   NAME.out   REQUIRED  exact expected stdout bytes
#   NAME.err   optional  exact expected stderr bytes (absent = stderr must be empty)
#   NAME.in    optional  the program's standard input (absent = /dev/null)
#   NAME.files/   optional  fixtures: copied into the program's working directory first
#   NAME.expect/  optional  expected files: each must exist after the run, byte-identical
#   exit status of the program must be 0.
#   Every program runs in a fresh empty working directory (docs/DESIGN.md 8.5); afterwards it
#   may hold only the expected files and unchanged fixtures (else "unexpected file R" /
#   "fixture R changed"). The same holds for run-phase tests/errors cases. A compile-phase or
#   tests/ir case with .files/.expect is a corpus mistake: exit 2.
#
# tests/errors/NAME.bas     a program with a compile-time or run-time error
#   NAME.meta  REQUIRED  two lines:  phase=compile|run   and   exit=<status>
#   NAME.err   REQUIRED  exact expected stderr bytes
#                        phase=compile: stderr of the compiler, which must exit
#                          with <status> and create no output file;
#                        phase=run: the compiler must succeed silently; this is
#                          the program's stderr, and the program must exit <status>.
#   NAME.out   optional  (phase=run only) exact expected stdout; absent = empty
#   NAME.in    optional  (phase=run only) the program's standard input
#                        (absent = /dev/null)
#   streams=merged|no-stdout  optional 3rd .meta line (phase=run only, docs/DESIGN.md 8.6):
#                        merged: stderr goes to the same open file as stdout (>out 2>&1), so
#                          NAME.out holds both in write order and NAME.err must be empty;
#                        no-stdout: stdout is closed (>&-), writes to fd 1 fail with EBADF,
#                          NAME.out must be absent or empty. Any other value: exit 2.
#
# tests/ir/NAME.bas         golden IR test
#   NAME.ir    REQUIRED  exact expected stdout of `baysick --emit-ir NAME.bas`
#                        (compiler must exit 0 with empty stderr)
#
# Exit status: 0 if every selected test passed, 1 otherwise, 2 on setup error.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BAYSICK=${BAYSICK:-$ROOT/build/baysick}
TIMEOUT=${BAYSICK_TEST_TIMEOUT:-10}
VERBOSE=0
if [ "${1:-}" = "-v" ]; then VERBOSE=1; shift; fi
PATTERNS="$*"

if [ ! -x "$BAYSICK" ]; then
    echo "run.sh: compiler '$BAYSICK' not found or not executable; run 'make' first" >&2
    exit 2
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/baysick-tests.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT INT TERM
: > "$TMP/empty"

# Misplaced file-test directories are a corpus mistake (docs/DESIGN.md section 8.5): compile-phase
# error tests and IR tests never run a program. Checked for every case, before running anything.
for bas in "$ROOT"/tests/errors/*.bas "$ROOT"/tests/ir/*.bas; do
    [ -e "$bas" ] || continue
    base=${bas%.bas}
    [ -d "$base.files" ] || [ -d "$base.expect" ] || continue
    case "$bas" in
    */tests/errors/*)
        phase=
        [ -f "$base.meta" ] && phase=$(sed -n 's/^phase=//p' "$base.meta" | head -1)
        [ "$phase" = compile ] || continue
        echo "run.sh: errors/$(basename "$base"): .files/.expect only for program and run-phase tests" >&2
        exit 2 ;;
    *)
        echo "run.sh: ir/$(basename "$base"): .files/.expect only for program and run-phase tests" >&2
        exit 2 ;;
    esac
done

PASS=0
FAIL=0
FAILED=""

selected() {
    [ -z "$PATTERNS" ] && return 0
    set -f  # patterns are literal, never globs
    for p in $PATTERNS; do
        case "$1" in *"$p"*) set +f; return 0 ;; esac
    done
    set +f
    return 1
}

# run_limited SECONDS INFILE WORKDIR CMD... : run CMD in directory WORKDIR with stdin from
# INFILE, kill it after SECONDS; returns CMD's exit status (137 if killed). Caller redirects
# output. The exec makes the subshell become CMD, so the kill reaches the program itself.
run_limited() {
    _t=$1; _in=$2; _wd=$3; shift 3
    (cd "$_wd" && exec "$@" <"$_in") &
    _cpid=$!
    (
        _i=0
        while [ "$_i" -lt $((_t * 10)) ]; do
            sleep 0.1
            kill -0 "$_cpid" 2>/dev/null || exit 0
            _i=$((_i + 1))
        done
        kill -9 "$_cpid" 2>/dev/null
    ) &
    _wpid=$!
    wait "$_cpid"
    _st=$?
    wait "$_wpid" 2>/dev/null
    return $_st
}

# stdin_for BASE : the program's standard input: BASE.in if it exists, else /dev/null
stdin_for() {
    if [ -f "$1.in" ]; then echo "$1.in"; else echo /dev/null; fi
}

pass() { PASS=$((PASS + 1)); }

fail() { # fail NAME REASON
    FAIL=$((FAIL + 1))
    FAILED="$FAILED $1"
    echo "FAIL $1: $2"
}

# same EXPECTED ACTUAL LABEL NAME : compare two files exactly; on mismatch record failure
same() {
    if cmp -s "$1" "$2"; then return 0; fi
    fail "$4" "$3 differs"
    if [ "$VERBOSE" = 1 ]; then diff -u "$1" "$2" | sed 's/^/    /' | head -60; fi
    return 1
}

meta_get() { # meta_get FILE KEY
    sed -n "s/^$2=//p" "$1" | head -1
}

# newwork BASE : make the case's fresh, empty working directory $WORK below $TMP and copy the
# fixtures BASE.files/ into it (docs/DESIGN.md section 8.5). Returns 1 on failure.
newwork() {
    WORK=$(mktemp -d "$TMP/work.XXXXXX") || return 1
    if [ -d "$1.files" ]; then cp -R "$1.files/." "$WORK/" || return 1; fi
    return 0
}

# relfiles DIR : sorted relative paths (no leading ./) of the regular files under DIR.
# Names have no blanks or glob characters (the corpus rule), so callers may word-split.
relfiles() {
    (cd "$1" && find . -type f | sed 's|^\./||' | sort)
}

# check_files NAME BASE : section 8.5 checks 1 and 2 of the files left in $WORK. Records one
# failure and returns 1 on the first problem.
check_files() {
    _n=$1; _b=$2
    if [ -d "$_b.expect" ]; then
        for _r in $(relfiles "$_b.expect"); do
            if [ ! -f "$WORK/$_r" ]; then fail "$_n" "missing file $_r"; return 1; fi
            same "$_b.expect/$_r" "$WORK/$_r" "file $_r" "$_n" || return 1
        done
    fi
    for _r in $(relfiles "$WORK"); do
        if [ -f "$_b.expect/$_r" ]; then continue; fi
        if [ -f "$_b.files/$_r" ]; then
            if cmp -s "$_b.files/$_r" "$WORK/$_r"; then continue; fi
            fail "$_n" "fixture $_r changed"; return 1
        fi
        fail "$_n" "unexpected file $_r"; return 1
    done
    return 0
}

# ---- tests/programs ---------------------------------------------------------
for bas in "$ROOT"/tests/programs/*.bas; do
    [ -e "$bas" ] || continue
    name=programs/$(basename "$bas" .bas)
    selected "$name" || continue
    base=${bas%.bas}
    exe=$TMP/prog
    rm -f "$exe"
    if [ ! -f "$base.out" ]; then fail "$name" "missing $base.out"; continue; fi
    "$BAYSICK" "$bas" -o "$exe" >"$TMP/c.out" 2>"$TMP/c.err"
    st=$?
    if [ $st -ne 0 ]; then
        fail "$name" "compile failed (status $st): $(head -3 "$TMP/c.err" | tr '\n' ' ')"
        continue
    fi
    if ! newwork "$base"; then fail "$name" "cannot prepare the work directory"; rm -rf "$WORK"; continue; fi
    run_limited "$TIMEOUT" "$(stdin_for "$base")" "$WORK" "$exe" >"$TMP/r.out" 2>"$TMP/r.err"
    st=$?
    experr=$TMP/empty
    [ -f "$base.err" ] && experr=$base.err
    ok=1
    [ $st -eq 0 ] || { fail "$name" "exit status $st, expected 0"; ok=0; }
    [ $ok = 1 ] && { same "$base.out" "$TMP/r.out" "stdout" "$name" || ok=0; }
    [ $ok = 1 ] && { same "$experr" "$TMP/r.err" "stderr" "$name" || ok=0; }
    [ $ok = 1 ] && { check_files "$name" "$base" || ok=0; }
    rm -rf "$WORK"
    [ $ok = 1 ] && pass
done

# ---- tests/errors -----------------------------------------------------------
for bas in "$ROOT"/tests/errors/*.bas; do
    [ -e "$bas" ] || continue
    name=errors/$(basename "$bas" .bas)
    selected "$name" || continue
    base=${bas%.bas}
    if [ ! -f "$base.meta" ] || [ ! -f "$base.err" ]; then
        fail "$name" "missing .meta or .err sidecar"; continue
    fi
    phase=$(meta_get "$base.meta" phase)
    want=$(meta_get "$base.meta" exit)
    exe=$TMP/prog
    rm -f "$exe"
    "$BAYSICK" "$bas" -o "$exe" >"$TMP/c.out" 2>"$TMP/c.err"
    st=$?
    case "$phase" in
    compile)
        ok=1
        [ "$st" = "$want" ] || { fail "$name" "compiler exit status $st, expected $want"; ok=0; }
        [ $ok = 1 ] && [ -e "$exe" ] && { fail "$name" "compiler created an output file despite the error"; ok=0; }
        [ $ok = 1 ] && { same "$base.err" "$TMP/c.err" "compiler stderr" "$name" || ok=0; }
        [ $ok = 1 ] && { same "$TMP/empty" "$TMP/c.out" "compiler stdout" "$name" || ok=0; }
        [ $ok = 1 ] && pass
        ;;
    run)
        if [ $st -ne 0 ] || [ -s "$TMP/c.err" ]; then
            fail "$name" "compile failed (status $st): $(head -3 "$TMP/c.err" | tr '\n' ' ')"
            continue
        fi
        if ! newwork "$base"; then fail "$name" "cannot prepare the work directory"; rm -rf "$WORK"; continue; fi
        streams=$(meta_get "$base.meta" streams)
        case "$streams" in
        "" | merged | no-stdout) ;;
        *) echo "run.sh: errors/$(basename "$base"): bad streams '$streams' in $(basename "$base").meta" >&2; exit 2 ;;
        esac
        # section 8.6: truncate the capture the mode leaves unwritten (r.out/r.err are reused)
        case "$streams" in
        merged)    : >"$TMP/r.err"
                   run_limited "$TIMEOUT" "$(stdin_for "$base")" "$WORK" "$exe" >"$TMP/r.out" 2>&1 ;;
        no-stdout) : >"$TMP/r.out"
                   run_limited "$TIMEOUT" "$(stdin_for "$base")" "$WORK" "$exe" >&- 2>"$TMP/r.err" ;;
        *)         run_limited "$TIMEOUT" "$(stdin_for "$base")" "$WORK" "$exe" >"$TMP/r.out" 2>"$TMP/r.err" ;;
        esac
        st=$?
        expout=$TMP/empty
        [ -f "$base.out" ] && expout=$base.out
        ok=1
        [ "$st" = "$want" ] || { fail "$name" "program exit status $st, expected $want"; ok=0; }
        [ $ok = 1 ] && { same "$base.err" "$TMP/r.err" "stderr" "$name" || ok=0; }
        [ $ok = 1 ] && { same "$expout" "$TMP/r.out" "stdout" "$name" || ok=0; }
        [ $ok = 1 ] && { check_files "$name" "$base" || ok=0; }
        rm -rf "$WORK"
        [ $ok = 1 ] && pass
        ;;
    *)
        fail "$name" "bad phase '$phase' in $base.meta"
        ;;
    esac
done

# ---- tests/ir ---------------------------------------------------------------
for bas in "$ROOT"/tests/ir/*.bas; do
    [ -e "$bas" ] || continue
    name=ir/$(basename "$bas" .bas)
    selected "$name" || continue
    base=${bas%.bas}
    if [ ! -f "$base.ir" ]; then fail "$name" "missing $base.ir"; continue; fi
    "$BAYSICK" --emit-ir "$bas" >"$TMP/ir.out" 2>"$TMP/ir.err"
    st=$?
    ok=1
    [ $st -eq 0 ] || { fail "$name" "--emit-ir exit status $st: $(head -3 "$TMP/ir.err" | tr '\n' ' ')"; ok=0; }
    [ $ok = 1 ] && { same "$base.ir" "$TMP/ir.out" "IR dump" "$name" || ok=0; }
    [ $ok = 1 ] && { same "$TMP/empty" "$TMP/ir.err" "stderr" "$name" || ok=0; }
    [ $ok = 1 ] && pass
done

echo "----"
echo "passed: $PASS  failed: $FAIL"
if [ $FAIL -ne 0 ]; then
    echo "failed tests:$FAILED"
    exit 1
fi
exit 0
