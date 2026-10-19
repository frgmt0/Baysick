#!/bin/sh
# tests/cross_run.sh -- run an x86_64-linux test bundle (Linux, POSIX sh).
#
# usage: sh tests/cross_run.sh [-v] [BUNDLE_DIR]
#   -v          show diffs for failures
#   BUNDLE_DIR  bundle made by tests/cross_pack.sh (default: the directory
#               above this script's own directory)
#
# Environment:
#   BAYSICK_TEST_TIMEOUT  seconds per program run (default: 10)
#   AS                    GNU assembler (default: as)
#   CC                    C compiler driver, used only to link (default: gcc)
#
# Builds the runtime from the bundle (make -f Makefile.linux), then for every
# case assembles + links the compiler's .s and compares the run exactly like
# tests/run.sh (same sidecar formats, including the optional NAME.in stdin
# file, same output format, same exit status: 0 all passed, 1 any failed,
# 2 setup error). docs/DESIGN.md section 8.3.

AS=${AS:-as}
CC=${CC:-gcc}
TIMEOUT=${BAYSICK_TEST_TIMEOUT:-10}
VERBOSE=0
if [ "${1:-}" = "-v" ]; then VERBOSE=1; shift; fi
if [ $# -gt 1 ]; then
    echo "cross_run.sh: usage: sh tests/cross_run.sh [-v] [BUNDLE_DIR]" >&2
    exit 2
fi
BUNDLE=${1:-$(dirname "$0")/..}
BUNDLE=$(cd "$BUNDLE" 2>/dev/null && pwd) || {
    echo "cross_run.sh: cannot enter bundle directory '${1:-}'" >&2
    exit 2
}

if [ "$(cat "$BUNDLE/BUNDLE" 2>/dev/null)" != "baysick-x86_64-linux-bundle 1" ]; then
    echo "cross_run.sh: '$BUNDLE' is not a baysick x86_64-linux bundle (BUNDLE marker missing or wrong)" >&2
    exit 2
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/baysick-crossrun.XXXXXX") || {
    echo "cross_run.sh: cannot create temporary directory" >&2
    exit 2
}
trap 'rm -rf "$TMP"' EXIT
# dash/busybox sh skip the EXIT trap on fatal signals: clean up explicitly there.
trap 'rm -rf "$TMP"; exit 2' HUP INT TERM PIPE
: > "$TMP/empty"

command -v "$AS" >/dev/null 2>&1 || { echo "cross_run.sh: assembler '$AS' not found" >&2; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "cross_run.sh: C compiler '$CC' not found (needed to link)" >&2; exit 2; }
command -v make >/dev/null 2>&1 || { echo "cross_run.sh: make not found" >&2; exit 2; }

# ---- setup: build the runtime from the bundle --------------------------------
if ! make -C "$BUNDLE" -f Makefile.linux check-includes all AS="$AS" >"$TMP/make.log" 2>&1; then
    echo "cross_run.sh: building the x86_64 runtime failed:" >&2
    sed 's/^/    /' "$TMP/make.log" >&2
    exit 2
fi
RTLIB=$BUNDLE/build-x86_64-linux/libbaysickrt.a
if [ ! -f "$RTLIB" ]; then
    echo "cross_run.sh: runtime build produced no $RTLIB" >&2
    exit 2
fi

PASS=0
FAIL=0
FAILED=""

# run_limited SECONDS INFILE CMD... : run CMD with stdin from INFILE, kill it
# after SECONDS; returns CMD's exit status (137 if killed). Caller redirects output.
run_limited() {
    _t=$1; _in=$2; shift 2
    "$@" <"$_in" &
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

# build NAME BASE : packfail check, assemble and link BASE.s into $TMP/prog.
# Returns 0 on success; otherwise records the failure and returns 1.
build() {
    _name=$1; _base=$2
    rm -f "$TMP/prog" "$TMP/prog.o"
    if [ -f "$_base.packfail" ]; then
        fail "$_name" "compile (on the Mac) failed: $(head -3 "$_base.packfail" | tr '\n' ' ')"
        return 1
    fi
    "$AS" --64 -o "$TMP/prog.o" "$_base.s" >"$TMP/a.out" 2>"$TMP/a.err"
    _st=$?
    if [ $_st -ne 0 ] || [ -s "$TMP/a.out" ] || [ -s "$TMP/a.err" ]; then
        fail "$_name" "assemble failed (status $_st): $(head -3 "$TMP/a.err" | tr '\n' ' ')"
        return 1
    fi
    "$CC" -no-pie -o "$TMP/prog" "$TMP/prog.o" "$RTLIB" -lm >"$TMP/l.out" 2>"$TMP/l.err"
    _st=$?
    if [ $_st -ne 0 ] || [ -s "$TMP/l.out" ] || [ -s "$TMP/l.err" ]; then
        fail "$_name" "link failed (status $_st): $(head -3 "$TMP/l.err" | tr '\n' ' ')"
        return 1
    fi
    return 0
}

# case_names KIND : sorted unique NAMEs having NAME.s or NAME.packfail
case_names() {
    ls "$BUNDLE/cases/$1" 2>/dev/null | sed -n -e 's/\.s$//p' -e 's/\.packfail$//p' | sort -u
}

# ---- cases/programs ----------------------------------------------------------
for n in $(case_names programs); do
    name=programs/$n
    base=$BUNDLE/cases/programs/$n
    if [ ! -f "$base.out" ]; then fail "$name" "missing $n.out"; continue; fi
    build "$name" "$base" || continue
    run_limited "$TIMEOUT" "$(stdin_for "$base")" "$TMP/prog" >"$TMP/r.out" 2>"$TMP/r.err"
    st=$?
    experr=$TMP/empty
    [ -f "$base.err" ] && experr=$base.err
    ok=1
    [ $st -eq 0 ] || { fail "$name" "exit status $st, expected 0"; ok=0; }
    [ $ok = 1 ] && { same "$base.out" "$TMP/r.out" "stdout" "$name" || ok=0; }
    [ $ok = 1 ] && { same "$experr" "$TMP/r.err" "stderr" "$name" || ok=0; }
    [ $ok = 1 ] && pass
done

# ---- cases/errors (run phase only) ------------------------------------------
for n in $(case_names errors); do
    name=errors/$n
    base=$BUNDLE/cases/errors/$n
    if [ ! -f "$base.meta" ] || [ ! -f "$base.err" ]; then
        fail "$name" "missing .meta or .err sidecar"; continue
    fi
    want=$(meta_get "$base.meta" exit)
    build "$name" "$base" || continue
    run_limited "$TIMEOUT" "$(stdin_for "$base")" "$TMP/prog" >"$TMP/r.out" 2>"$TMP/r.err"
    st=$?
    expout=$TMP/empty
    [ -f "$base.out" ] && expout=$base.out
    ok=1
    [ "$st" = "$want" ] || { fail "$name" "program exit status $st, expected $want"; ok=0; }
    [ $ok = 1 ] && { same "$base.err" "$TMP/r.err" "stderr" "$name" || ok=0; }
    [ $ok = 1 ] && { same "$expout" "$TMP/r.out" "stdout" "$name" || ok=0; }
    [ $ok = 1 ] && pass
done

echo "----"
echo "passed: $PASS  failed: $FAIL"
if [ $FAIL -ne 0 ]; then
    echo "failed tests:$FAILED"
    exit 1
fi
exit 0
