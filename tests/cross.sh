#!/bin/sh
# tests/cross.sh -- compile on the Mac, run on a Linux x86_64 host (POSIX sh).
#
# usage: sh tests/cross.sh [-v] [-H HOST] [PATTERN...]
#   -v        show diffs for failures
#   -H HOST   ssh destination (default: $BAYSICK_CROSS_HOST, else "desktop");
#             key authentication is required (ssh -o BatchMode=yes)
#   PATTERN   only test cases whose name contains one of the patterns
#
# Environment:
#   BAYSICK               compiler used by cross_pack.sh (default: build/baysick)
#   BAYSICK_TEST_TIMEOUT  seconds per program, forwarded (default: 10)
#   BAYSICK_KERNELS       if set, forwarded to the remote runs (kernel variant; name chars only)
#   BAYSICK_CROSS_HOST    default host
#
# Packs a bundle (tests/cross_pack.sh) into a local temp directory, streams it
# as tar into ONE ssh call that unpacks it into a remote mktemp -d directory
# (removed on exit; HUP/INT/TERM/PIPE clean up and exit 2), and runs tests/cross_run.sh there.
#
# Exit status: that of cross_run.sh (0 all passed, 1 failures, 2 setup error);
# 2 also if packing fails, ssh fails (255) or the remote status is anything
# else (e.g. 127, 137). docs/DESIGN.md 8.3.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOST=${BAYSICK_CROSS_HOST:-desktop}
TIMEOUT=${BAYSICK_TEST_TIMEOUT:-10}
VERBOSE=
while [ $# -gt 0 ]; do
    case "$1" in
    -v) VERBOSE=-v; shift ;;
    -H)
        if [ $# -lt 2 ]; then echo "cross.sh: missing argument for '-H'" >&2; exit 2; fi
        HOST=$2; shift 2 ;;
    --) shift; break ;;
    -*) echo "cross.sh: unknown option '$1'" >&2; exit 2 ;;
    *) break ;;
    esac
done

case "$TIMEOUT" in
'' | *[!0-9]*) echo "cross.sh: BAYSICK_TEST_TIMEOUT must be a number of seconds" >&2; exit 2 ;;
esac

TMP=$(mktemp -d "${TMPDIR:-/tmp}/baysick-cross.XXXXXX") || {
    echo "cross.sh: cannot create temporary directory" >&2
    exit 2
}
trap 'rm -rf "$TMP"' EXIT
# dash/busybox sh skip the EXIT trap on fatal signals: clean up explicitly there.
trap 'rm -rf "$TMP"; exit 2' HUP INT TERM PIPE

if ! sh "$ROOT/tests/cross_pack.sh" -o "$TMP/bundle" "$@"; then
    echo "cross.sh: packing the test bundle failed" >&2
    exit 2
fi

# Optional kernel variant for the remote runs; restricted to name characters so the remote
# script stays free of single quotes and of anything the remote shell could interpret.
KPFX=
case "${BAYSICK_KERNELS:-}" in
'') ;;
*[!A-Za-z0-9_]*) echo "cross.sh: BAYSICK_KERNELS must contain only letters, digits and underscores" >&2; exit 2 ;;
*) KPFX="BAYSICK_KERNELS=$BAYSICK_KERNELS " ;;
esac

# Remote script: no single quote anywhere, so it survives any login shell.
REMOTE='d=$(mktemp -d "${TMPDIR:-/tmp}/baysick-cross.XXXXXX") || exit 2; trap "rm -rf \"\$d\"" EXIT; trap "rm -rf \"\$d\"; exit 2" HUP INT TERM PIPE; tar -C "$d" -xf - || exit 2; BAYSICK_TEST_TIMEOUT='"$TIMEOUT"' '"$KPFX"'sh "$d/tests/cross_run.sh" "$@" "$d"'

# Run the transfer in the foreground of a subshell; ssh gets the tar stream on stdin.
COPYFILE_DISABLE=1 tar --no-xattrs -C "$TMP/bundle" -cf - . | ssh -o BatchMode=yes -- "$HOST" "sh -c '$REMOTE' sh $VERBOSE"
st=$?
# st is ssh's status (the pipeline's last command); tar errors surface as a
# remote unpack failure (exit 2).
if [ $st -eq 255 ]; then
    echo "cross.sh: ssh to '$HOST' failed" >&2
    exit 2
fi
case $st in
0 | 1 | 2) exit $st ;;
esac
echo "cross.sh: remote command ended with unexpected status $st" >&2
exit 2
