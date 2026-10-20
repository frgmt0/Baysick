#!/bin/sh
# tests/cross_pack.sh -- build the x86_64-linux test bundle (macOS, POSIX sh).
#
# usage: sh tests/cross_pack.sh -o BUNDLE_DIR [PATTERN...]
#   -o BUNDLE_DIR  output directory; must not exist or must be empty (required)
#   PATTERN        only pack tests whose name (programs/NAME, errors/NAME)
#                  contains one of the patterns
#
# Environment:
#   BAYSICK   compiler (default: build/baysick)
#
# Layout of the bundle (docs/DESIGN.md section 8.3), consumed by
# tests/cross_run.sh on Linux: BUNDLE marker, Makefile.linux, include/*.inc,
# src/runtime_x86_64_linux/*.s, the two include-check files, cross_run.sh, the
# kernel conformance test tests/kern/kern_check.c and kern_run.sh (when no PATTERN
# is given or one matches "kern/kern_check", docs/DESIGN.md 8.7), and
# cases/<programs|errors>/NAME.s plus the unchanged sidecars (.out .err
# .meta and the optional .in stdin file). NAME.files/ and NAME.expect/
# (docs/DESIGN.md 8.5) are copied unchanged when present; compile-phase or tests/ir cases with
# them are a setup error (exit 2). A case whose
# compilation fails gets NAME.packfail ("status <n>" line, then the compiler's
# stderr) instead of NAME.s. compile-phase error tests are skipped.
#
# Exit status: 0 bundle complete (even with .packfail files), 2 setup error.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BAYSICK=${BAYSICK:-$ROOT/build/baysick}
BUNDLE=
while [ $# -gt 0 ]; do
    case "$1" in
    -o)
        if [ $# -lt 2 ]; then echo "cross_pack.sh: missing argument for '-o'" >&2; exit 2; fi
        BUNDLE=$2; shift 2 ;;
    --) shift; break ;;
    -*) echo "cross_pack.sh: unknown option '$1'" >&2; exit 2 ;;
    *) break ;;
    esac
done
PATTERNS="$*"

if [ -z "$BUNDLE" ]; then
    echo "cross_pack.sh: usage: sh tests/cross_pack.sh -o BUNDLE_DIR [PATTERN...]" >&2
    exit 2
fi
if [ ! -x "$BAYSICK" ]; then
    echo "cross_pack.sh: compiler '$BAYSICK' not found or not executable; run 'make' first" >&2
    exit 2
fi
if [ -e "$BUNDLE" ]; then
    if [ ! -d "$BUNDLE" ]; then
        echo "cross_pack.sh: '$BUNDLE' exists and is not a directory" >&2; exit 2
    fi
    if [ -n "$(ls -A "$BUNDLE" 2>/dev/null)" ]; then
        echo "cross_pack.sh: bundle directory '$BUNDLE' is not empty" >&2; exit 2
    fi
fi

setup_fail() { echo "cross_pack.sh: $1" >&2; exit 2; }

# Misplaced file-test directories are a corpus mistake (docs/DESIGN.md section 8.5): compile-phase
# error tests and IR tests never run a program. Checked for every case, before creating anything.
for bas in "$ROOT"/tests/errors/*.bas "$ROOT"/tests/ir/*.bas; do
    [ -e "$bas" ] || continue
    base=${bas%.bas}
    [ -d "$base.files" ] || [ -d "$base.expect" ] || continue
    case "$bas" in
    */tests/errors/*)
        phase=
        [ -f "$base.meta" ] && phase=$(sed -n 's/^phase=//p' "$base.meta" | head -1)
        [ "$phase" = compile ] || continue
        setup_fail "errors/$(basename "$base"): .files/.expect only for program and run-phase tests" ;;
    *)
        setup_fail "ir/$(basename "$base"): .files/.expect only for program and run-phase tests" ;;
    esac
done

mkdir -p "$BUNDLE/include" "$BUNDLE/src/runtime_x86_64_linux" "$BUNDLE/tests" \
    "$BUNDLE/cases/programs" "$BUNDLE/cases/errors" \
    || setup_fail "cannot create bundle directory '$BUNDLE'"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/baysick-pack.XXXXXX") || setup_fail "cannot create temporary directory"
trap 'rm -rf "$TMP"' EXIT
# dash/busybox sh skip the EXIT trap on fatal signals: clean up explicitly there.
trap 'rm -rf "$TMP"; exit 2' HUP INT TERM PIPE

echo "baysick-x86_64-linux-bundle 1" > "$BUNDLE/BUNDLE" || setup_fail "cannot write $BUNDLE/BUNDLE"
cp "$ROOT/Makefile.linux" "$BUNDLE/" || setup_fail "cannot copy Makefile.linux"
cp "$ROOT"/include/*.inc "$BUNDLE/include/" || setup_fail "cannot copy include files"
for f in "$ROOT"/src/runtime_x86_64_linux/*.s; do
    [ -e "$f" ] || continue
    cp "$f" "$BUNDLE/src/runtime_x86_64_linux/" || setup_fail "cannot copy $f"
done
cp "$ROOT/tests/cross_run.sh" "$ROOT/tests/include_check_x86_64.s" \
    "$ROOT/tests/include_asserts.inc" "$BUNDLE/tests/" \
    || setup_fail "cannot copy test support files"

selected() {
    [ -z "$PATTERNS" ] && return 0
    set -f  # patterns are literal, never globs
    for p in $PATTERNS; do
        case "$1" in *"$p"*) set +f; return 0 ;; esac
    done
    set +f
    return 1
}

# Kernel conformance test (docs/DESIGN.md 8.7): C source and driver, compiled on Linux.
if selected "kern/kern_check"; then
    mkdir -p "$BUNDLE/tests/kern" || setup_fail "cannot create $BUNDLE/tests/kern"
    cp "$ROOT/tests/kern/kern_check.c" "$ROOT/tests/kern/kern_run.sh" "$BUNDLE/tests/kern/" \
        || setup_fail "cannot copy the kernel conformance test"
fi

PACKED=0
BAD=0

# pack_case KIND BAS : compile to cases/KIND/NAME.s and copy the sidecars
pack_case() {
    _kind=$1; _bas=$2
    _base=${_bas%.bas}
    _name=$(basename "$_base")
    _dir=$BUNDLE/cases/$_kind
    _out=$_dir/$_name.s
    "$BAYSICK" --target x86_64-linux -S "$_bas" -o "$_out" >"$TMP/c.out" 2>"$TMP/c.err"
    _st=$?
    if [ $_st -ne 0 ] || [ -s "$TMP/c.out" ] || [ -s "$TMP/c.err" ]; then
        rm -f "$_out"
        {
            echo "status $_st"
            cat "$TMP/c.err"
            if [ -s "$TMP/c.out" ]; then echo "unexpected stdout:"; cat "$TMP/c.out"; fi
        } > "$_dir/$_name.packfail" || setup_fail "cannot write $_dir/$_name.packfail"
        BAD=$((BAD + 1))
    elif [ ! -f "$_out" ]; then
        {
            echo "status $_st"
            echo "compiler did not create $_name.s"
        } > "$_dir/$_name.packfail" || setup_fail "cannot write $_dir/$_name.packfail"
        BAD=$((BAD + 1))
    fi
    for _ext in out err meta in; do
        if [ -f "$_base.$_ext" ]; then
            cp "$_base.$_ext" "$_dir/$_name.$_ext" || setup_fail "cannot copy $_base.$_ext"
        fi
    done
    # file-test directories (docs/DESIGN.md section 8.5), copied unchanged
    for _ext in files expect; do
        if [ -d "$_base.$_ext" ]; then
            cp -R "$_base.$_ext" "$_dir/$_name.$_ext" || setup_fail "cannot copy $_base.$_ext"
        fi
    done
    PACKED=$((PACKED + 1))
}

for bas in "$ROOT"/tests/programs/*.bas; do
    [ -e "$bas" ] || continue
    selected "programs/$(basename "$bas" .bas)" || continue
    pack_case programs "$bas"
done

for bas in "$ROOT"/tests/errors/*.bas; do
    [ -e "$bas" ] || continue
    name=$(basename "$bas" .bas)
    selected "errors/$name" || continue
    meta=${bas%.bas}.meta
    phase=
    if [ -f "$meta" ]; then phase=$(sed -n 's/^phase=//p' "$meta" | head -1); fi
    # compile-phase errors never reach a backend: covered by `make test`
    [ "$phase" = compile ] && continue
    pack_case errors "$bas"
done

echo "packed: $PACKED cases ($BAD failed to compile)"
exit 0
