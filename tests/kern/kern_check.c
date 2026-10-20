/*
 * tests/kern/kern_check.c -- kernel conformance test for _bsk_kern_gemm and
 * _bsk_kern_gemm_sub (docs/DESIGN.md 6.6.1, 6.6.4, 8.7; normative there).
 *
 * The two GEMM entries are class R (any summation order, FMA allowed), so this test never
 * compares against an implementation's output: every expected element is derived from the
 * definition in DESIGN.md 6.6.4 ("IEEE propagation"), element by element, independent of order:
 *
 *   * exact data (small integers, every partial sum in every order exactly representable):
 *     the exact value, the same in every variant;
 *   * a NaN term, or both +inf and -inf terms: NaN;
 *   * otherwise an infinite term: that infinity (the finite terms are far below overflow);
 *   * finite terms whose magnitudes sum above 2^1000 (overflow possible): any value; only the
 *     status must agree with what was stored.
 *
 * Every usable variant (_bsk_kern_variants, selected with _bsk_kern_use) runs every case. A case
 * also checks: the KS_* status (KS_NONFINITE exactly when a stored element is not finite); that
 * no memory outside C's view is written (guard zones and the row padding beyond MV_COLS hold a
 * sentinel NaN before and after the call); that A and B are not modified; that the sentinel NaNs
 * in A's and B's padding never reach a result; that gemm ignores C's previous contents; and
 * (class R determinism) that results on inexact data are bit-identical across views with other
 * MV_LD and alignment, across repeated calls and across C's previous contents.
 *
 * Shapes cover every micro-tile edge and blocking boundary of the three variants (neon: MR x NR
 * = 8 x 6, KC 256, MC 128, NC 2046, unpacked path for m*n*k <= 32768; sse2: 4 x 6, KC 256,
 * MC 48, NC 2046; avx2: 6 x 8, KC 256, MC 72, NC 2048), non-square shapes, row and column
 * vectors, views with MV_LD > MV_COLS and MV_DATA aligned to 8 but not 16 bytes.
 *
 * Built by tests/kern/kern_run.sh against libbaysickrt.a alone (link isolation, DESIGN.md
 * 6.6.1; this file defines main). Constants named in include/runtime.inc come from the
 * generated runtime_consts.h, so no value with a name in an include file is repeated here.
 *
 * Exit status: 0 every check passed (one summary line on stdout); 1 a check failed (one line
 * per failed check on stderr, at most MAX_LINES per case, variant and entry, then a count);
 * 2 setup error (no usable variant, out of memory).
 */
#include <math.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "runtime_consts.h"

/* ---- Baysick kernel API (DESIGN.md 6.6.1); MV_* records of runtime.inc ------------------- */
typedef struct {
    double *data;
    uint64_t rows, cols, ld;
} mview;
_Static_assert(offsetof(mview, data) == MV_DATA, "MV_DATA");
_Static_assert(offsetof(mview, rows) == MV_ROWS, "MV_ROWS");
_Static_assert(offsetof(mview, cols) == MV_COLS, "MV_COLS");
_Static_assert(offsetof(mview, ld) == MV_LD, "MV_LD");
_Static_assert(sizeof(mview) == MV_SIZE, "MV_SIZE");

extern void bsk_kern_init(void);
extern int64_t bsk_kern_use(const char *name);
extern const char *bsk_kern_name(void);
extern const char *const *bsk_kern_variants(void);
extern int64_t bsk_kern_gemm(const mview *c, const mview *a, const mview *b);
extern int64_t bsk_kern_gemm_sub(const mview *c, const mview *a, const mview *b);

/* ---- Settings --------------------------------------------------------------------------- */
#define GUARD 16         /* sentinel doubles before and after every matrix region */
#define MAX_LINES 8      /* failure lines printed per (case, variant, entry) */
#define MAX_VARIANTS 16
#define BIG_LIMIT 0x1p1000 /* finite terms whose magnitudes sum above this: value unspecified */

/* A quiet NaN with a payload no arithmetic on the test data produces: fills everything outside
 * the views. */
static const uint64_t SENTINEL_BITS = 0x7ff8badc0ffee123ull;

enum { E_GEMM, E_GEMM_SUB, E_COUNT };
static const char *const entry_name[E_COUNT] = {"gemm", "gemm_sub"};

static const char *g_variants[MAX_VARIANTS];
static int g_nvariants;
static long g_checks;   /* (case, variant, entry) runs completed */
static long g_failures; /* failed checks */

/* ---- Small utilities -------------------------------------------------------------------- */
static uint64_t bits_of(double x) {
    uint64_t u;
    memcpy(&u, &x, sizeof u);
    return u;
}

static double double_of(uint64_t u) {
    double x;
    memcpy(&x, &u, sizeof x);
    return x;
}

static void *xmalloc(size_t n) {
    void *p = malloc(n ? n : 1);
    if (!p) {
        fprintf(stderr, "kern_check: out of memory (%zu bytes)\n", n);
        exit(2);
    }
    return p;
}

/* The BENCH.md generator: s := 6364136223846793005*s + 1442695040888963407 mod 2^64. */
static uint64_t g_rng;

static uint64_t rng_next(void) {
    g_rng = 6364136223846793005ull * g_rng + 1442695040888963407ull;
    return g_rng;
}

/* An integer in [lo, hi], as a double. */
static double rnd_int(int lo, int hi) {
    return (double)(lo + (int)((rng_next() >> 33) % (uint64_t)(hi - lo + 1)));
}

/* A double in [-1, 1) with 52 random bits (inexact products and sums). */
static double rnd_unit(void) {
    return (double)(rng_next() >> 11) * 0x1p-52 - 1.0;
}

/* ---- Matrices: a view inside a sentinel-filled, guarded region -------------------------- */
typedef struct {
    unsigned char *raw; /* malloc result */
    double *base;       /* 64-byte aligned start of the region */
    size_t total;       /* doubles in the region */
    size_t start;       /* index of element (0,0) in the region */
    mview v;
} mat;

/* mat_new: rows x cols view with row stride ld, element (0,0) off doubles past the 64-byte
 * aligned guard zone (off odd: 8- but not 16-byte aligned). Everything is the sentinel. */
static void mat_new(mat *x, uint64_t rows, uint64_t cols, uint64_t ld, unsigned off) {
    x->start = GUARD + off;
    x->total = x->start + (size_t)rows * ld + GUARD;
    x->raw = xmalloc(x->total * sizeof(double) + 64);
    x->base = (double *)(((uintptr_t)x->raw + 63) & ~(uintptr_t)63);
    x->v.data = x->base + x->start;
    x->v.rows = rows;
    x->v.cols = cols;
    x->v.ld = ld;
    for (size_t i = 0; i < x->total; i++) x->base[i] = double_of(SENTINEL_BITS);
}

static void mat_free(mat *x) {
    free(x->raw);
    x->raw = NULL;
}

static double *at(const mat *x, uint64_t i, uint64_t j) {
    return x->v.data + i * x->v.ld + j;
}

/* in_view: is region index idx an element of the view? */
static int in_view(const mat *x, size_t idx) {
    if (idx < x->start) return 0;
    size_t r = (idx - x->start) / x->v.ld, c = (idx - x->start) % x->v.ld;
    return r < x->v.rows && c < x->v.cols;
}

/* Layout of one run: per-matrix offset (0..7 doubles) and extra row stride. The extra stride
 * is 0 (MV_LD = MV_COLS), 1, 2 or 9. */
typedef struct {
    unsigned off[3];
    uint64_t pad[3];
} layout;

static layout layout_for(unsigned seed) {
    static const uint64_t pads[4] = {0, 1, 2, 9};
    layout l;
    for (int t = 0; t < 3; t++) {
        l.off[t] = (seed * (2u * (unsigned)t + 1u) + (unsigned)t) % 8u;
        l.pad[t] = pads[(seed / (unsigned)(t + 1) + (unsigned)t) % 4u];
    }
    return l;
}

/* ---- Expected results: DESIGN.md 6.6.4, element by element ------------------------------ */
enum { X_EXACT, X_FINITE, X_NAN, X_PINF, X_NINF, X_ANY };

typedef struct {
    int cls;
    double val; /* X_EXACT only */
} expect;

typedef struct {
    int nan, pinf, ninf, big, inexact;
    int64_t isum; /* exact sum of the integer terms */
    double s;     /* sum of the magnitudes of the finite terms (an upper-bound estimate) */
} acc;

static int small_int(double x, double limit) {
    return x == trunc(x) && fabs(x) <= limit;
}

/* acc_value: add the term v (or -v when neg) -- C0 of gemm_sub. */
static void acc_value(acc *a, double v, int neg) {
    if (isnan(v)) { a->nan = 1; return; }
    if (isinf(v)) {
        if ((signbit(v) != 0) ^ neg) a->ninf = 1; else a->pinf = 1;
        return;
    }
    if (v == 0.0) return;
    int e;
    frexp(v, &e);
    if (e > 1000) { a->big = 1; return; }
    a->s += fabs(v);
    if (small_int(v, 0x1p40)) a->isum += neg ? -(int64_t)v : (int64_t)v;
    else a->inexact = 1;
}

/* acc_product: add the term x*y (or -(x*y) when neg), classified exactly, without rounding:
 * NaN if a factor is NaN or it is 0*inf (either zero), +-inf with the product of the signs if
 * a factor is infinite and the other nonzero, else the exact real product. */
static void acc_product(acc *a, double x, double y, int neg) {
    if (isnan(x) || isnan(y)) { a->nan = 1; return; }
    if (isinf(x) || isinf(y)) {
        if (x == 0.0 || y == 0.0) { a->nan = 1; return; }
        if ((signbit(x) != 0) ^ (signbit(y) != 0) ^ neg) a->ninf = 1; else a->pinf = 1;
        return;
    }
    if (x == 0.0 || y == 0.0) return; /* an exact zero term */
    int ex, ey;
    frexp(x, &ex);
    frexp(y, &ey);
    if (ex + ey > 1000) { a->big = 1; return; } /* |x*y| may exceed BIG_LIMIT */
    double t = x * y;                            /* |t| < 2^1000: no overflow */
    a->s += fabs(t);
    if (small_int(x, 0x1p20) && small_int(y, 0x1p20)) a->isum += neg ? -(int64_t)t : (int64_t)t;
    else a->inexact = 1;
}

static expect acc_finish(const acc *a) {
    expect e = {X_ANY, 0.0};
    if (a->nan || (a->pinf && a->ninf)) e.cls = X_NAN;          /* rule 1: always */
    else if (a->big || a->s > BIG_LIMIT) e.cls = X_ANY;           /* rule 4 */
    else if (a->pinf) e.cls = X_PINF;                             /* rule 2 */
    else if (a->ninf) e.cls = X_NINF;
    else if (a->inexact || a->s > 0x1p53) e.cls = X_FINITE;       /* rule 3 */
    else { e.cls = X_EXACT; e.val = (double)a->isum; }
    return e;
}

/* expect_all: the expected class of every element of C. c0 is C's value before the call
 * (gemm_sub only, row-major m x n). */
static void expect_all(int entry, const mat *A, const mat *B, const double *c0, expect *out) {
    uint64_t m = A->v.rows, k = A->v.cols, n = B->v.cols;
    for (uint64_t i = 0; i < m; i++) {
        for (uint64_t j = 0; j < n; j++) {
            acc a;
            memset(&a, 0, sizeof a);
            int neg = 0;
            if (entry == E_GEMM_SUB) {
                acc_value(&a, c0[i * n + j], 0);
                neg = 1;
            }
            for (uint64_t p = 0; p < k; p++) acc_product(&a, *at(A, i, p), *at(B, p, j), neg);
            out[i * n + j] = acc_finish(&a);
        }
    }
}

static int matches(const expect *e, double v) {
    switch (e->cls) {
    case X_EXACT: return v == e->val; /* +0 == -0: the sign of a zero is unspecified */
    case X_FINITE: return isfinite(v);
    case X_NAN: return isnan(v);
    case X_PINF: return v == INFINITY;
    case X_NINF: return v == -INFINITY;
    default: return 1;
    }
}

static const char *class_text(const expect *e, char *buf, size_t len) {
    switch (e->cls) {
    case X_EXACT: snprintf(buf, len, "%.17g", e->val); break;
    case X_FINITE: snprintf(buf, len, "a finite value"); break;
    case X_NAN: snprintf(buf, len, "NaN"); break;
    case X_PINF: snprintf(buf, len, "+inf"); break;
    case X_NINF: snprintf(buf, len, "-inf"); break;
    default: snprintf(buf, len, "anything"); break;
    }
    return buf;
}

/* ---- Failure reporting ------------------------------------------------------------------ */
typedef struct {
    const char *label, *variant;
    int entry;
    uint64_t m, n, k;
    int lines;
} run_ctx;

static void failf(run_ctx *r, const char *fmt, ...) __attribute__((format(printf, 2, 3)));

static void failf(run_ctx *r, const char *fmt, ...) {
    g_failures++;
    if (++r->lines > MAX_LINES) return;
    fprintf(stderr, "kern_check: %s %s %s m=%llu n=%llu k=%llu: ", r->variant, entry_name[r->entry],
            r->label, (unsigned long long)r->m, (unsigned long long)r->n, (unsigned long long)r->k);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

static void fail_tail(run_ctx *r) {
    if (r->lines > MAX_LINES)
        fprintf(stderr, "kern_check: %s %s %s: ... %d more failed checks not shown\n", r->variant,
                entry_name[r->entry], r->label, r->lines - MAX_LINES);
}

static void use_variant(const char *name) {
    if (bsk_kern_use(name) != 0) {
        fprintf(stderr, "kern_check: _bsk_kern_use(\"%s\") failed for a listed variant\n", name);
        g_failures++;
        return;
    }
    if (strcmp(bsk_kern_name(), name) != 0) {
        fprintf(stderr, "kern_check: _bsk_kern_name() is \"%s\" after _bsk_kern_use(\"%s\")\n",
                bsk_kern_name(), name);
        g_failures++;
    }
}

static int64_t call_entry(int entry, const mat *C, const mat *A, const mat *B) {
    if (entry == E_GEMM) return bsk_kern_gemm(&C->v, &A->v, &B->v);
    return bsk_kern_gemm_sub(&C->v, &A->v, &B->v);
}

/* prepare_c: sentinel everywhere, then the view := c0 (gemm_sub) or garbage (gemm: C is an
 * output only, so its previous contents must not matter). */
static void prepare_c(int entry, mat *C, const double *c0) {
    uint64_t m = C->v.rows, n = C->v.cols;
    static const uint64_t garbage[4] = {0x7ff0000000000000ull, 0x7ff800000000beefull,
                                        0xfff0000000000000ull, 0xd2e0000000000000ull};
    for (size_t i = 0; i < C->total; i++) C->base[i] = double_of(SENTINEL_BITS);
    for (uint64_t i = 0; i < m; i++)
        for (uint64_t j = 0; j < n; j++)
            *at(C, i, j) = entry == E_GEMM_SUB ? c0[i * n + j] : double_of(garbage[(i + j) % 4]);
}

/* check_run: everything a run must satisfy (see the header). snapA/snapB are copies of A's and
 * B's regions taken before the call. */
static void check_run(run_ctx *r, int64_t st, const mat *C, const mat *A, const mat *B,
                      const double *snapA, const double *snapB, const expect *ex) {
    uint64_t m = C->v.rows, n = C->v.cols;
    int nonfinite = 0;
    char buf[64];
    for (uint64_t i = 0; i < m; i++) {
        for (uint64_t j = 0; j < n; j++) {
            double v = *at(C, i, j);
            if (!isfinite(v)) nonfinite = 1;
            if (!matches(&ex[i * n + j], v))
                failf(r, "element (%llu,%llu) = %.17g, expected %s", (unsigned long long)i,
                      (unsigned long long)j, v, class_text(&ex[i * n + j], buf, sizeof buf));
        }
    }
    int64_t want = nonfinite ? KS_NONFINITE : KS_OK;
    if (st != want)
        failf(r, "status %lld, expected %lld (%s stored element)", (long long)st, (long long)want,
              nonfinite ? "a non-finite" : "every finite");
    for (size_t i = 0; i < C->total; i++) {
        if (in_view(C, i)) continue;
        if (bits_of(C->base[i]) != SENTINEL_BITS) {
            long long d = (long long)i - (long long)C->start;
            failf(r, "C memory outside the view written at element offset %lld (row stride %llu)", d,
                  (unsigned long long)C->v.ld);
        }
    }
    if (memcmp(A->base, snapA, A->total * sizeof(double)) != 0) failf(r, "A (or its padding) modified");
    if (memcmp(B->base, snapB, B->total * sizeof(double)) != 0) failf(r, "B (or its padding) modified");
}

/* ---- Scenarios: where the non-finite values go ------------------------------------------- */
enum {
    SC_EXACT,     /* small integers only */
    SC_A_PINF,    /* A(m-1,k-1) = +inf, B(k-1,:) = 0, 1, -2, ...: last row, last k, edge tile */
    SC_B_NINF,    /* B(0,n-1) = -inf, A(:,0) = 2, 0, -1, ...: last column, first k */
    SC_A_NAN,     /* A(m/2,k/2) = NaN */
    SC_B_NAN0,    /* B(k/2,n/2) = NaN and A(:,k/2) = 0 */
    SC_NOSKIP,    /* A(:,k-1) = 0 with B(k-1,n-1) = +inf; A(m-1,:) = 0 with B(0,0) = -inf */
    SC_MIXED,     /* A(0,0) = +inf, A(0,k-1) = -inf, B(0,:) = 1, B(k-1,:) = +-1 */
    SC_C0,        /* C0 specials (gemm_sub) and A(0,k/2) = +inf */
    SC_NEGZERO,   /* A(m-1,0) = -0, B(0,n-1) = +inf */
    SC_NC,        /* infinities and NaN in columns 2045..2048 (the NC boundaries) */
    SC_OVERFLOW,  /* A(0,0) = B(0,0) = 2^600: one finite term of 2^1200 */
    SC_COUNT
};
static const char *const sc_name[SC_COUNT] = {"exact", "A+inf", "B-inf", "A-NaN", "B-NaN*0",
                                              "no-skip", "mixed", "C0", "neg-zero", "NC", "overflow"};

static void apply_scenario(int sc, mat *A, mat *B, double *c0) {
    uint64_t m = A->v.rows, k = A->v.cols, n = B->v.cols;
    switch (sc) {
    case SC_A_PINF:
        *at(A, m - 1, k - 1) = INFINITY;
        for (uint64_t j = 0; j < n; j++) *at(B, k - 1, j) = (double[]){0, 1, -2}[j % 3];
        break;
    case SC_B_NINF:
        *at(B, 0, n - 1) = -INFINITY;
        for (uint64_t i = 0; i < m; i++) *at(A, i, 0) = (double[]){2, 0, -1}[i % 3];
        break;
    case SC_A_NAN:
        *at(A, m / 2, k / 2) = NAN;
        break;
    case SC_B_NAN0:
        *at(B, k / 2, n / 2) = NAN;
        for (uint64_t i = 0; i < m; i++) *at(A, i, k / 2) = 0.0;
        break;
    case SC_NOSKIP:
        for (uint64_t i = 0; i < m; i++) *at(A, i, k - 1) = 0.0;
        for (uint64_t p = 0; p < k; p++) *at(A, m - 1, p) = 0.0;
        *at(B, k - 1, n - 1) = INFINITY;
        *at(B, 0, 0) = -INFINITY;
        break;
    case SC_MIXED:
        *at(A, 0, 0) = INFINITY;
        *at(A, 0, k - 1) = -INFINITY;
        for (uint64_t j = 0; j < n; j++) {
            *at(B, 0, j) = 1.0;
            *at(B, k - 1, j) = (j % 2) ? 1.0 : -1.0;
        }
        break;
    case SC_C0:
        c0[0] = NAN;
        c0[(m - 1) * n + (n - 1)] = INFINITY;
        c0[(m / 2) * n + n / 2] = -INFINITY;
        c0[n - 1] = INFINITY;
        *at(A, 0, k / 2) = INFINITY;
        for (uint64_t j = 0; j < n; j++) *at(B, k / 2, j) = (j % 3 == 0) ? 0.0 : ((j % 3 == 1) ? 1.0 : -3.0);
        break;
    case SC_NEGZERO:
        *at(A, m - 1, 0) = -0.0;
        *at(B, 0, n - 1) = INFINITY;
        break;
    case SC_NC: {
        static const uint64_t cols[4] = {2045, 2046, 2047, 2048};
        double vals[4] = {INFINITY, -INFINITY, NAN, INFINITY};
        for (int t = 0; t < 4; t++) {
            uint64_t j = cols[t] < n ? cols[t] : n - 1;
            *at(B, (uint64_t)t % k, j) = vals[t];
        }
        break;
    }
    case SC_OVERFLOW:
        for (uint64_t i = 0; i < m; i++) *at(A, i, 0) = 0.0;
        for (uint64_t j = 0; j < n; j++) *at(B, 0, j) = 0.0;
        for (uint64_t p = 0; p < k; p++) *at(A, 0, p) = 0.0;
        *at(A, 0, 0) = 0x1p600;
        *at(B, 0, 0) = 0x1p600;
        break;
    default:
        break;
    }
}

/* ---- One case: build the inputs once, check every variant and both entries -------------- */
static void run_case(const char *label, uint64_t m, uint64_t n, uint64_t k, int sc, unsigned seed) {
    char lab[96];
    snprintf(lab, sizeof lab, "%s/%s", label, sc_name[sc]);
    for (int entry = 0; entry < E_COUNT; entry++) {
        layout l = layout_for(seed + (unsigned)entry);
        mat A, B, C;
        mat_new(&A, m, k, k + l.pad[0], l.off[0]);
        mat_new(&B, k, n, n + l.pad[1], l.off[1]);
        mat_new(&C, m, n, n + l.pad[2], l.off[2]);
        double *c0 = xmalloc(m * n * sizeof(double));
        g_rng = 1964u + seed * 7919u + (unsigned)entry;
        for (uint64_t i = 0; i < m; i++)
            for (uint64_t p = 0; p < k; p++) *at(&A, i, p) = rnd_int(-3, 3);
        for (uint64_t p = 0; p < k; p++)
            for (uint64_t j = 0; j < n; j++) *at(&B, p, j) = rnd_int(-3, 3);
        for (uint64_t t = 0; t < m * n; t++) c0[t] = rnd_int(-50, 50);
        apply_scenario(sc, &A, &B, c0);
        expect *ex = xmalloc(m * n * sizeof(expect));
        expect_all(entry, &A, &B, c0, ex);
        double *snapA = xmalloc(A.total * sizeof(double));
        double *snapB = xmalloc(B.total * sizeof(double));
        memcpy(snapA, A.base, A.total * sizeof(double));
        memcpy(snapB, B.base, B.total * sizeof(double));
        for (int vi = 0; vi < g_nvariants; vi++) {
            run_ctx r = {lab, g_variants[vi], entry, m, n, k, 0};
            use_variant(g_variants[vi]);
            prepare_c(entry, &C, c0);
            int64_t st = call_entry(entry, &C, &A, &B);
            check_run(&r, st, &C, &A, &B, snapA, snapB, ex);
            fail_tail(&r);
            g_checks++;
        }
        free(snapA);
        free(snapB);
        free(ex);
        free(c0);
        mat_free(&A);
        mat_free(&B);
        mat_free(&C);
    }
}

/* ---- Class R determinism on inexact data ------------------------------------------------ */
/* Two copies of the same values in different layouts; per variant and entry: run 1 (layout 1),
 * run 2 (layout 2, different previous contents of C for gemm), run 3 (layout 1 again). The
 * three results must be bit-identical (DESIGN.md 6.6.4: a deterministic function of the
 * variant, the shapes and the values). */
static void run_determinism(const char *label, uint64_t m, uint64_t n, uint64_t k, unsigned seed) {
    char lab[96];
    snprintf(lab, sizeof lab, "%s/class-R", label);
    for (int entry = 0; entry < E_COUNT; entry++) {
        layout l1 = layout_for(seed), l2 = layout_for(seed + 5);
        mat A1, B1, C1, A2, B2, C2;
        mat_new(&A1, m, k, k + l1.pad[0], l1.off[0]);
        mat_new(&B1, k, n, n + l1.pad[1], l1.off[1]);
        mat_new(&C1, m, n, n + l1.pad[2], l1.off[2]);
        mat_new(&A2, m, k, k + l2.pad[0] + 3, (l2.off[0] + 1) % 8);
        mat_new(&B2, k, n, n + l2.pad[1] + 3, (l2.off[1] + 1) % 8);
        mat_new(&C2, m, n, n + l2.pad[2] + 3, (l2.off[2] + 1) % 8);
        double *c0 = xmalloc(m * n * sizeof(double));
        double *zero = xmalloc(m * n * sizeof(double));
        double *r1 = xmalloc(m * n * sizeof(double));
        g_rng = 77u + seed;
        for (uint64_t i = 0; i < m; i++)
            for (uint64_t p = 0; p < k; p++) *at(&A1, i, p) = *at(&A2, i, p) = rnd_unit();
        for (uint64_t p = 0; p < k; p++)
            for (uint64_t j = 0; j < n; j++) *at(&B1, p, j) = *at(&B2, p, j) = rnd_unit();
        for (uint64_t t = 0; t < m * n; t++) {
            c0[t] = rnd_unit();
            zero[t] = 0.0;
        }
        for (int vi = 0; vi < g_nvariants; vi++) {
            run_ctx r = {lab, g_variants[vi], entry, m, n, k, 0};
            use_variant(g_variants[vi]);
            /* run 1: gemm's C starts at zero here, garbage in run 2 */
            prepare_c(E_GEMM_SUB, &C1, entry == E_GEMM_SUB ? c0 : zero);
            int64_t st = call_entry(entry, &C1, &A1, &B1);
            for (uint64_t i = 0; i < m; i++)
                for (uint64_t j = 0; j < n; j++) r1[i * n + j] = *at(&C1, i, j);
            for (uint64_t t = 0; t < m * n; t++)
                if (!isfinite(r1[t])) {
                    failf(&r, "element %llu = %.17g is not finite", (unsigned long long)t, r1[t]);
                    break;
                }
            if (st != KS_OK) failf(&r, "status %lld, expected KS_OK", (long long)st);
            for (int run = 2; run <= 3; run++) {
                mat *C = run == 2 ? &C2 : &C1;
                prepare_c(entry, C, c0);
                st = call_entry(entry, C, run == 2 ? &A2 : &A1, run == 2 ? &B2 : &B1);
                if (st != KS_OK) failf(&r, "run %d: status %lld, expected KS_OK", run, (long long)st);
                for (uint64_t i = 0; i < m; i++)
                    for (uint64_t j = 0; j < n; j++)
                        if (bits_of(*at(C, i, j)) != bits_of(r1[i * n + j]))
                            failf(&r,
                                  "run %d (%s): element (%llu,%llu) = %a, run 1 gave %a "
                                  "(class R: no dependence on layout, alignment or earlier calls)",
                                  run, run == 2 ? "other MV_LD and alignment" : "same views again",
                                  (unsigned long long)i, (unsigned long long)j, *at(C, i, j),
                                  r1[i * n + j]);
            }
            fail_tail(&r);
            g_checks++;
        }
        free(c0);
        free(zero);
        free(r1);
        mat_free(&A1);
        mat_free(&B1);
        mat_free(&C1);
        mat_free(&A2);
        mat_free(&B2);
        mat_free(&C2);
    }
}

/* ---- The case list ---------------------------------------------------------------------- */
typedef struct {
    const char *label;
    uint64_t m, n, k;
} shape;

/* Exact data at the blocking boundaries (KC 256; MC 48, 72, 128; NC 2046, 2048), the unpacked
 * threshold of neon (m*n*k <= 32768) and vectors. */
static const shape exact_shapes[] = {
    {"vector-row", 1, 40, 1000},     {"vector-col", 40, 1, 1000},  {"dot", 1, 1, 40000},
    {"thin", 2, 3, 6000},            {"kc-1", 47, 7, 255},         {"kc", 48, 6, 256},
    {"kc+1", 49, 13, 257},           {"2kc+1", 71, 8, 513},        {"2kc", 72, 7, 512},
    {"2kc-1", 73, 9, 511},           {"mc-neon-1", 127, 6, 260},   {"mc-neon", 128, 12, 300},
    {"mc-neon+1", 129, 5, 257},      {"mc-all", 130, 50, 7},       {"odd", 97, 98, 99},
    {"nc-3", 3, 2045, 7},            {"nc-2", 3, 2046, 7},         {"nc-1", 3, 2047, 7},
    {"nc", 3, 2048, 7},              {"nc+1", 3, 2049, 7},         {"2nc", 2, 4100, 5},
    {"nc+kc", 9, 2049, 260},         {"square", 150, 140, 300},    {"tiny-limit", 32, 32, 32},
    {"tiny-limit+", 32, 32, 33},     {"tiny-wide", 16, 64, 32},    {"tiny-wide+", 16, 64, 33},
};

/* Shapes for the IEEE scenarios: unpacked (neon), packed with edge tiles in both directions,
 * two KC blocks, the MC boundaries, the NC boundary. */
static const shape ieee_shapes[] = {
    {"1x1x1", 1, 1, 1},    {"2x3x2", 2, 3, 2},       {"tiny", 5, 7, 9},   {"edges", 9, 7, 600},
    {"edges2", 13, 11, 300}, {"mc-sse2", 49, 13, 520}, {"mc-all", 130, 50, 7}, {"nc+1", 3, 2049, 7},
};

static const shape det_shapes[] = {
    {"tiny", 5, 7, 9}, {"packed", 37, 41, 300}, {"mc-all", 130, 50, 7}, {"nc+1", 3, 2049, 7},
};

#define COUNT(a) (sizeof(a) / sizeof((a)[0]))

int main(void) {
    bsk_kern_init();
    const char *const *vl = bsk_kern_variants();
    for (; vl && *vl && g_nvariants < MAX_VARIANTS; vl++) g_variants[g_nvariants++] = *vl;
    if (g_nvariants == 0) {
        fprintf(stderr, "kern_check: _bsk_kern_variants() lists no usable variant\n");
        return 2;
    }
    unsigned seed = 1;

    /* every micro-tile edge: m and n run through all residues of MR and NR of every variant */
    for (uint64_t m = 1; m <= 9; m++)
        for (uint64_t n = 1; n <= 9; n++) {
            static const uint64_t ks[4] = {1, 2, 3, 7};
            for (int t = 0; t < 4; t++) run_case("tiny-grid", m, n, ks[t], SC_EXACT, seed++);
        }
    for (uint64_t m = 8; m <= 15; m++)
        for (uint64_t n = 6; n <= 13; n++) run_case("edge-grid", m, n, 700, SC_EXACT, seed++);
    for (size_t t = 0; t < COUNT(exact_shapes); t++)
        run_case(exact_shapes[t].label, exact_shapes[t].m, exact_shapes[t].n, exact_shapes[t].k,
                 SC_EXACT, seed++);

    /* IEEE propagation */
    for (size_t t = 0; t < COUNT(ieee_shapes); t++)
        for (int sc = SC_A_PINF; sc < SC_COUNT; sc++)
            run_case(ieee_shapes[t].label, ieee_shapes[t].m, ieee_shapes[t].n, ieee_shapes[t].k, sc,
                     seed++);

    /* class R determinism */
    for (size_t t = 0; t < COUNT(det_shapes); t++)
        run_determinism(det_shapes[t].label, det_shapes[t].m, det_shapes[t].n, det_shapes[t].k,
                        seed++);

    if (g_failures) {
        fprintf(stderr, "kern_check: %ld failed checks in %ld runs\n", g_failures, g_checks);
        return 1;
    }
    printf("kern_check: %ld runs passed (variants:", g_checks);
    for (int vi = 0; vi < g_nvariants; vi++) printf(" %s", g_variants[vi]);
    printf(")\n");
    return 0;
}
