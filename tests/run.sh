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
#   exit status of the program must be 0.
#
# tests/errors/NAME.bas     a program with a compile-time or run-time error
#   NAME.meta  REQUIRED  two lines:  phase=compile|run   and   exit=<status>
#   NAME.err   REQUIRED  exact expected stderr bytes
#                        phase=compile: stderr of the compiler, which must exit
#                          with <status> and create no output file;
#                        phase=run: the compiler must succeed silently; this is
#                          the program's stderr, and the program must exit <status>.
#   NAME.out   optional  (phase=run only) exact expected stdout; absent = empty
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

# run_limited SECONDS CMD... : run CMD with stdin from /dev/null, kill it after
# SECONDS; returns CMD's exit status (137 if killed). Caller redirects output.
run_limited() {
    _t=$1; shift
    "$@" </dev/null &
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
    run_limited "$TIMEOUT" "$exe" >"$TMP/r.out" 2>"$TMP/r.err"
    st=$?
    experr=$TMP/empty
    [ -f "$base.err" ] && experr=$base.err
    ok=1
    [ $st -eq 0 ] || { fail "$name" "exit status $st, expected 0"; ok=0; }
    [ $ok = 1 ] && { same "$base.out" "$TMP/r.out" "stdout" "$name" || ok=0; }
    [ $ok = 1 ] && { same "$experr" "$TMP/r.err" "stderr" "$name" || ok=0; }
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
        run_limited "$TIMEOUT" "$exe" >"$TMP/r.out" 2>"$TMP/r.err"
        st=$?
        expout=$TMP/empty
        [ -f "$base.out" ] && expout=$base.out
        ok=1
        [ "$st" = "$want" ] || { fail "$name" "program exit status $st, expected $want"; ok=0; }
        [ $ok = 1 ] && { same "$base.err" "$TMP/r.err" "stderr" "$name" || ok=0; }
        [ $ok = 1 ] && { same "$expout" "$TMP/r.out" "stdout" "$name" || ok=0; }
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
