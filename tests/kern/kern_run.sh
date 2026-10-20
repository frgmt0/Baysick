#!/bin/sh
# tests/kern/kern_run.sh -- build and run the kernel conformance test (POSIX sh;
# macOS and Linux). docs/DESIGN.md section 8.7.
#
# usage: sh tests/kern/kern_run.sh [-v] ARCHIVE
#   -v        on failure, print every line the test wrote to stderr (else the first 20)
#   ARCHIVE   the runtime archive to test: build/libbaysickrt.a (macOS) or
#             build-x86_64-linux/libbaysickrt.a (Linux)
#
# Environment:
#   CC                    C compiler driver (default: "xcrun cc" on macOS, gcc elsewhere)
#   BAYSICK_KERN_TIMEOUT  seconds for the test program (default: 120)
#
# Steps: derive
# runtime_consts.h (the MV_*/KS_* constants) from include/runtime.inc; compile
# tests/kern/kern_check.c and link it with ARCHIVE alone (it defines main: link
# isolation, DESIGN.md 6.6.1); the compile must exit 0 with empty stderr; run it.
# The include files and the test source are found relative to this script, so the
# script works unchanged inside the x86_64-linux bundle (DESIGN.md 8.3).
#
# Output: "kern/kern_check: passed (...)" on success; "FAIL kern/kern_check: <reason>"
# and the test's failure lines (indented) otherwise.
#
# Exit status: 0 passed; 1 failed (build, run or a check); 2 setup error; a missing
# gemm_sub entry in ARCHIVE fails the link.

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TIMEOUT=${BAYSICK_KERN_TIMEOUT:-120}
VERBOSE=0
if [ "${1:-}" = "-v" ]; then VERBOSE=1; shift; fi
if [ $# -ne 1 ]; then
    echo "kern_run.sh: usage: sh tests/kern/kern_run.sh [-v] ARCHIVE" >&2
    exit 2
fi
ARCHIVE=$1
case "$TIMEOUT" in
'' | *[!0-9]*) echo "kern_run.sh: BAYSICK_KERN_TIMEOUT must be a number of seconds" >&2; exit 2 ;;
esac
if [ ! -f "$ARCHIVE" ]; then
    echo "kern_run.sh: runtime archive '$ARCHIVE' not found (build it first)" >&2
    exit 2
fi
ARCHIVE=$(cd "$(dirname "$ARCHIVE")" && pwd)/$(basename "$ARCHIVE")

# Platform: the link flags of DESIGN.md 5.4.1.
if [ "$(uname -s)" = Darwin ]; then
    CCDEF="xcrun cc"
    LDEXTRA=
else
    CCDEF=gcc
    LDEXTRA="-no-pie -lm"
fi
CC=${CC:-$CCDEF}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/baysick-kern.XXXXXX") || {
    echo "kern_run.sh: cannot create temporary directory" >&2
    exit 2
}
trap 'rm -rf "$TMP"' EXIT
# dash/busybox sh skip the EXIT trap on fatal signals: clean up explicitly there.
trap 'rm -rf "$TMP"; exit 2' HUP INT TERM PIPE

# runtime.inc constants -> C header (the include files stay the only place a value is named)
grep -E '^\.equ[[:space:]]+(MV|KS)_' "$ROOT/include/runtime.inc" |
    sed -E 's/^\.equ[[:space:]]+([A-Za-z0-9_]+),[[:space:]]*([0-9a-fA-FxX]+).*/#define \1 \2/' \
        >"$TMP/runtime_consts.h" || { echo "kern_run.sh: cannot derive runtime_consts.h" >&2; exit 2; }
[ -s "$TMP/runtime_consts.h" ] || { echo "kern_run.sh: no MV_/KS_ constants in include/runtime.inc" >&2; exit 2; }

# shellcheck disable=SC2086 # CC may be "xcrun cc"; LDEXTRA is a word list
$CC -std=c11 -O2 -Wall -Wextra -ffp-contract=off -I "$TMP" -o "$TMP/kern_check" \
    "$ROOT/tests/kern/kern_check.c" "$ARCHIVE" $LDEXTRA >"$TMP/cc.out" 2>"$TMP/cc.err"
st=$?
if [ $st -ne 0 ] || [ -s "$TMP/cc.out" ] || [ -s "$TMP/cc.err" ]; then
    echo "FAIL kern/kern_check: build failed (status $st)"
    cat "$TMP/cc.out" "$TMP/cc.err" | head -20 | sed 's/^/    /'
    exit 1
fi

# Run with a watchdog (as tests/run.sh does): 137 if killed.
"$TMP/kern_check" >"$TMP/r.out" 2>"$TMP/r.err" </dev/null &
cpid=$!
(
    i=0
    while [ "$i" -lt $((TIMEOUT * 10)) ]; do
        sleep 0.1
        kill -0 "$cpid" 2>/dev/null || exit 0
        i=$((i + 1))
    done
    kill -9 "$cpid" 2>/dev/null
) &
wpid=$!
wait "$cpid"
st=$?
wait "$wpid" 2>/dev/null

if [ $st -eq 0 ] && [ ! -s "$TMP/r.err" ]; then
    echo "kern/kern_check: passed ($(sed 's/^kern_check: //' "$TMP/r.out" | head -1))"
    exit 0
fi
case $st in
0) echo "FAIL kern/kern_check: exit status 0 but output on stderr" ;;
1) echo "FAIL kern/kern_check: checks failed" ;;
137) echo "FAIL kern/kern_check: killed after ${TIMEOUT} s" ;;
*) echo "FAIL kern/kern_check: exit status $st" ;;
esac
if [ "$VERBOSE" = 1 ]; then
    sed 's/^/    /' "$TMP/r.err"
else
    head -20 "$TMP/r.err" | sed 's/^/    /'
    n=$(wc -l <"$TMP/r.err" | tr -d " ")
    [ "$n" -gt 20 ] && echo "    ... $((n - 20)) more lines (-v shows all)"
fi
exit 1
