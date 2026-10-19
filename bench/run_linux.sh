#!/bin/sh
# bench/run_linux.sh -- the Linux half of `make bench-cross` (docs/BENCH.md 4); run by
# bench/cross.sh on the remote host from the unpacked bundle. POSIX sh.
#
# usage: sh run_linux.sh BUNDLE_DIR
#
# BUNDLE_DIR holds include/, src/runtime_x86_64_linux/, Makefile.linux, bench/ and e2e/
# (NAME.s compiled on the Mac with --target x86_64-linux, and NAME.out). Environment:
# BENCH_QUICK, AS (default as), CC (default gcc).
#
# Output: the harness report on stdout, then (status 0 only) the TSV between the lines
# @@BENCH-TSV-BEGIN@@ and @@BENCH-TSV-END@@ for bench/cross.sh to split off.
# Exit status: the harness's (0, 1), 2 setup error, 42 OpenBLAS missing (cross.sh turns it
# into "bench-cross: OpenBLAS not found on <host>", exit 2).

B=${1:-}
[ -n "$B" ] && [ -d "$B/bench" ] || { echo "run_linux.sh: usage: sh run_linux.sh BUNDLE_DIR" >&2; exit 2; }
cd "$B" || exit 2
AS=${AS:-as}
CC=${CC:-gcc}

fail() { echo "bench: $*" >&2; exit 2; }

command -v "$CC" >/dev/null 2>&1 || fail "no C compiler ($CC) on this host"
command -v "$AS" >/dev/null 2>&1 || fail "no assembler ($AS) on this host"
command -v make >/dev/null 2>&1 || fail "make not found on this host"
[ "$(uname -sm)" = "Linux x86_64" ] || fail "not an x86_64 Linux host ($(uname -sm))"

# OpenBLAS: its own cblas.h (it declares cblas_domatcopy and openblas_get_config; a reference
# cblas.h in /usr/include does not) and libopenblas. Never fall back to the reference BLAS.
cat >bench/probe.c <<'PROBE'
#include <cblas.h>
#include <string.h>
int main(void) {
    const char *c = openblas_get_config();
    openblas_set_num_threads(1);
    (void)cblas_domatcopy;
    return !(c && strstr(c, "OpenBLAS"));
}
PROBE
OBINC=
FOUND=
CANDS="$(pkg-config --cflags-only-I openblas 2>/dev/null) /usr/include/openblas /usr/include/x86_64-linux-gnu/openblas-pthread /usr/include/openblas-base"
for cand in $CANDS ""; do
    case "$cand" in -I*) flag=$cand ;; "") flag= ;; *) [ -d "$cand" ] && flag="-I$cand" || continue ;; esac
    if $CC -O1 $flag -o bench/probe bench/probe.c -lopenblas -lm >/dev/null 2>&1 && ./bench/probe; then
        OBINC=$flag
        FOUND=1
        break
    fi
done
if [ -z "$FOUND" ]; then
    echo "bench: no usable OpenBLAS (libopenblas with its cblas.h, cblas_domatcopy and openblas_get_config)" >&2
    echo "bench: install it: Arch 'pacman -S openblas', Debian/Ubuntu 'apt install libopenblas-dev'" >&2
    exit 42
fi

make -f Makefile.linux AS="$AS" >&2 || fail "building the x86_64 runtime failed"
ARCHIVE=build-x86_64-linux/libbaysickrt.a
[ -f "$ARCHIVE" ] || fail "$ARCHIVE was not built"

SYMS=$(nm -g "$ARCHIVE" 2>/dev/null | awk '$2 == "T" { print $3 }')
MISSING=
for s in init use name variants features gemm add sub scale trn inv; do
    echo "$SYMS" | grep -qx "bsk_kern_$s" || MISSING="$MISSING bsk_kern_$s"
done
if [ -n "$MISSING" ]; then
    echo "bench: $ARCHIVE does not export the matrix kernel API; missing:$MISSING" >&2
    echo "bench: the MAT kernels (docs/DESIGN.md section 6.6) are not implemented in this build" >&2
    exit 2
fi

grep -E '^\.equ[[:space:]]+(MV|KS|KF|RT_KERN)_' include/runtime.inc |
    sed -E 's/^\.equ[[:space:]]+([A-Za-z0-9_]+),[[:space:]]*([0-9a-fA-FxX]+).*/#define \1 \2/' >bench/runtime_consts.h ||
    fail "cannot derive runtime_consts.h"
[ -s bench/runtime_consts.h ] || fail "no MV_/KS_/KF_ constants found in include/runtime.inc"

$CC -O2 -ffp-contract=off -no-pie $OBINC -I bench -o bench/bench bench/bench.c bench/peak_x86_64.s "$ARCHIVE" -lopenblas -lm ||
    fail "compiling/linking the harness failed"

# End-to-end programs: assemble and link like DESIGN.md 5.4.1.
mkdir -p e2e/bin || fail "cannot create e2e/bin"
for p in e2e_gemm e2e_inv e2e_mixed; do
    "$AS" --64 -o "e2e/bin/$p.o" "e2e/$p.s" || fail "assembling e2e/$p.s failed"
    $CC -no-pie -o "e2e/bin/$p" "e2e/bin/$p.o" "$ARCHIVE" -lm || fail "linking $p failed"
    cp "e2e/$p.out" "e2e/bin/$p.out" || fail "cannot copy $p.out"
done

./bench/bench --tsv bench/x86_64-linux.tsv --e2e e2e/bin
st=$?
if [ $st -eq 0 ]; then
    echo "@@BENCH-TSV-BEGIN@@"
    cat bench/x86_64-linux.tsv
    echo "@@BENCH-TSV-END@@"
fi
exit $st
