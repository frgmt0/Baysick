#!/bin/sh
# bench/run_mac.sh -- build and run the matrix-kernel benchmarks on macOS (docs/BENCH.md 4).
#
# usage: sh bench/run_mac.sh [--vendor-only]
#   --vendor-only   self-test of the instrument: build the harness without the Baysick
#                   runtime (peak loops, Accelerate, vendor-versus-C-reference validation)
#
# Environment: BUILD (default build; as in the Makefile), BENCH_QUICK=1 (smoke run).
#
# Steps: check the runtime archive exports the kernel API; derive runtime_consts.h from
# include/runtime.inc; compile bench/bench.c (xcrun cc, -framework Accelerate); compile the
# e2e programs with $BUILD/baysick; run the harness. Output: the report on stdout and
# $BUILD/bench/arm64-macos.tsv.
#
# Exit status: that of the harness (0 measured and validated, 1 validation failure), or 2
# for a setup error (missing tools, archive without the kernels, compile failure).

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 2
BUILD=${BUILD:-build}
BD=$BUILD/bench
VENDOR_ONLY=
case "${1:-}" in
'') ;;
--vendor-only) VENDOR_ONLY=1 ;;
*) echo "bench: usage: sh bench/run_mac.sh [--vendor-only]" >&2; exit 2 ;;
esac

fail() { echo "bench: $*" >&2; exit 2; }

xcrun --find cc >/dev/null 2>&1 || fail "no C compiler: 'xcrun cc' not found (install the Xcode command line tools)"
mkdir -p "$BD" || fail "cannot create $BD"

# runtime.inc constants -> C header (the include files stay the only place a value is named)
grep -E '^\.equ[[:space:]]+(MV|KS|KF|RT_KERN)_' include/runtime.inc |
    sed -E 's/^\.equ[[:space:]]+([A-Za-z0-9_]+),[[:space:]]*([0-9a-fA-FxX]+).*/#define \1 \2/' >"$BD/runtime_consts.h" ||
    fail "cannot derive $BD/runtime_consts.h"
[ -s "$BD/runtime_consts.h" ] || fail "no MV_/KS_/KF_ constants found in include/runtime.inc"

CFLAGS="-O2 -ffp-contract=off -DACCELERATE_NEW_LAPACK -I $BD"
if [ -n "$VENDOR_ONLY" ]; then
    xcrun cc $CFLAGS -DBENCH_VENDOR_ONLY -o "$BD/bench" bench/bench.c bench/peak_arm64.s -framework Accelerate ||
        fail "compiling the harness failed"
    exec "$BD/bench" --tsv "$BD/arm64-macos.tsv"
fi

ARCHIVE=$BUILD/libbaysickrt.a
COMPILER=$BUILD/baysick
[ -f "$ARCHIVE" ] || fail "$ARCHIVE not found (run 'make' first)"
[ -x "$COMPILER" ] || fail "$COMPILER not found (run 'make' first)"

# The archive must export the kernel API (DESIGN.md 6.6); until the kernels exist, stop clearly.
SYMS=$(nm -g "$ARCHIVE" 2>/dev/null | awk '$2 == "T" { print $3 }')
MISSING=
for s in init use name variants features gemm add sub scale trn inv; do
    echo "$SYMS" | grep -qx "_bsk_kern_$s" || MISSING="$MISSING _bsk_kern_$s"
done
if [ -n "$MISSING" ]; then
    echo "bench: $ARCHIVE does not export the matrix kernel API; missing:$MISSING" >&2
    echo "bench: the MAT kernels (docs/DESIGN.md section 6.6) are not implemented in this build" >&2
    exit 2
fi

xcrun cc $CFLAGS -o "$BD/bench" bench/bench.c bench/peak_arm64.s "$ARCHIVE" -framework Accelerate ||
    fail "compiling/linking the harness failed"

# End-to-end programs, compiled natively with the Baysick compiler.
E2E=$BD/e2e
rm -rf "$E2E" && mkdir -p "$E2E" || fail "cannot create $E2E"
for p in e2e_gemm e2e_inv e2e_mixed; do
    "$COMPILER" "bench/programs/$p.bas" -o "$E2E/$p" || fail "compiling bench/programs/$p.bas failed"
    cp "bench/programs/$p.out" "$E2E/$p.out" || fail "cannot copy $p.out"
done

"$BD/bench" --tsv "$BD/arm64-macos.tsv" --e2e "$E2E"
st=$?
[ $st -eq 0 ] && echo "# wrote $BD/arm64-macos.tsv"
exit $st
