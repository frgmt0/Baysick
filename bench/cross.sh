#!/bin/sh
# bench/cross.sh -- run the matrix-kernel benchmarks on a Linux x86_64 host from the Mac
# (docs/BENCH.md 4; same shape as tests/cross.sh). POSIX sh.
#
# usage: sh bench/cross.sh [-H HOST]
#   -H HOST   ssh destination (default: $BAYSICK_CROSS_HOST, else "desktop"); key
#             authentication is required (ssh -o BatchMode=yes)
#
# Environment: BUILD (default build), BAYSICK_CROSS_HOST, BENCH_QUICK=1 (smoke run).
#
# Packs include/, src/runtime_x86_64_linux/, Makefile.linux, bench/ and the e2e programs
# compiled with --target x86_64-linux into a local temporary directory, streams it as tar into
# ONE ssh call that unpacks it into a remote mktemp -d directory (removed on exit; HUP/INT/
# TERM/PIPE clean up too) and runs bench/run_linux.sh there. The report is printed here; the
# TSV that the remote side appends between marker lines is written to
# $BUILD/bench/x86_64-linux.tsv. OpenBLAS is required on the host.
#
# Exit status: 0 measured and validated, 1 a validation failure, 2 setup error (including
# "bench-cross: OpenBLAS not found on <host>", ssh failure, packing failure).

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 2
BUILD=${BUILD:-build}
HOST=${BAYSICK_CROSS_HOST:-desktop}
while [ $# -gt 0 ]; do
    case "$1" in
    -H)
        if [ $# -lt 2 ]; then echo "bench-cross: missing argument for '-H'" >&2; exit 2; fi
        HOST=$2; shift 2 ;;
    *) echo "bench-cross: usage: sh bench/cross.sh [-H HOST]" >&2; exit 2 ;;
    esac
done

QUICK=0
case "${BENCH_QUICK:-}" in '' | 0) ;; *) QUICK=1 ;; esac

COMPILER=$BUILD/baysick
[ -x "$COMPILER" ] || { echo "bench-cross: $COMPILER not found (run 'make' first)" >&2; exit 2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/baysick-bench.XXXXXX") || {
    echo "bench-cross: cannot create temporary directory" >&2
    exit 2
}
trap 'rm -rf "$TMP"' EXIT
trap 'rm -rf "$TMP"; exit 2' HUP INT TERM PIPE

# Pack the bundle.
P=$TMP/bundle
mkdir -p "$P/include" "$P/src/runtime_x86_64_linux" "$P/bench" "$P/e2e" || exit 2
cp include/*.inc "$P/include/" &&
    cp src/runtime_x86_64_linux/*.s "$P/src/runtime_x86_64_linux/" &&
    cp Makefile.linux "$P/" &&
    cp bench/bench.c bench/peak_x86_64.s bench/run_linux.sh "$P/bench/" || {
    echo "bench-cross: packing the bundle failed" >&2
    exit 2
}
for p in e2e_gemm e2e_inv e2e_mixed; do
    "$COMPILER" --target x86_64-linux -S "bench/programs/$p.bas" -o "$P/e2e/$p.s" || {
        echo "bench-cross: compiling bench/programs/$p.bas for x86_64-linux failed" >&2
        exit 2
    }
    cp "bench/programs/$p.out" "$P/e2e/$p.out" || exit 2
done

# Remote script: no single quote anywhere, so it survives any login shell.
REMOTE='d=$(mktemp -d "${TMPDIR:-/tmp}/baysick-bench.XXXXXX") || exit 2; trap "rm -rf \"\$d\"" EXIT; trap "rm -rf \"\$d\"; exit 2" HUP INT TERM PIPE; tar -C "$d" -xf - || exit 2; BENCH_QUICK='"$QUICK"' sh "$d/bench/run_linux.sh" "$d"'

# The ssh status goes to a file because it is the first stage of a pipeline; awk passes the
# report through unbuffered and diverts the TSV block. tar feeds ssh through a fifo so its own
# status is captured too (in a plain pipe `$?` would be ssh's alone and hide a failed pack).
mkfifo "$TMP/pack" || {
    echo "bench-cross: cannot create a fifo in $TMP" >&2
    exit 2
}
{
    COPYFILE_DISABLE=1 tar --no-xattrs -C "$P" -cf - . >"$TMP/pack" 2>"$TMP/tar.err" &
    tarpid=$!
    ssh -o BatchMode=yes -- "$HOST" "sh -c '$REMOTE' sh" <"$TMP/pack"
    echo $? >"$TMP/status"
    wait $tarpid
    echo $? >"$TMP/tarstatus"
} | awk -v tsv="$TMP/result.tsv" '
    $0 == "@@BENCH-TSV-BEGIN@@" { intsv = 1; next }
    $0 == "@@BENCH-TSV-END@@"   { intsv = 0; next }
    { if (intsv) print > tsv; else { print; fflush() } }'
st=$(cat "$TMP/status" 2>/dev/null)
[ -n "$st" ] || st=2
tarst=$(cat "$TMP/tarstatus" 2>/dev/null)
[ -n "$tarst" ] || tarst=2
# A failed pack is reported first: the remote side saw a short or empty archive. (A tar that
# died of SIGPIPE because ssh exited early is the ssh failure's symptom, so ssh's 255 wins.)
if [ "$tarst" -ne 0 ] && [ $st -ne 255 ]; then
    echo "bench-cross: packing the bundle with tar failed (status $tarst)" >&2
    cat "$TMP/tar.err" >&2 2>/dev/null
    exit 2
fi

case $st in
0 | 1) ;;
255)
    echo "bench-cross: ssh to '$HOST' failed" >&2
    exit 2 ;;
42)
    echo "bench-cross: OpenBLAS not found on $HOST" >&2
    echo "bench-cross: install it there (Arch: pacman -S openblas; Debian/Ubuntu: apt install libopenblas-dev)" >&2
    exit 2 ;;
2) exit 2 ;;
*)
    echo "bench-cross: remote command ended with unexpected status $st" >&2
    exit 2 ;;
esac

if [ $st -eq 0 ]; then
    if [ ! -s "$TMP/result.tsv" ]; then
        echo "bench-cross: the host returned no TSV data" >&2
        exit 2
    fi
    mkdir -p "$BUILD/bench" && cp "$TMP/result.tsv" "$BUILD/bench/x86_64-linux.tsv" || {
        echo "bench-cross: cannot write $BUILD/bench/x86_64-linux.tsv" >&2
        exit 2
    }
    echo "# wrote $BUILD/bench/x86_64-linux.tsv"
fi
exit $st
