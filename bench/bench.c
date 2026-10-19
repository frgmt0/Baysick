/*
 * bench.c -- Baysick matrix-kernel benchmark harness (docs/BENCH.md, normative).
 *
 * One C file for both systems: __APPLE__ selects Accelerate (arm64-macos), everything else
 * OpenBLAS (x86_64-linux). It links libbaysickrt.a and calls only the exported kernel API
 * (_bsk_kern_*, DESIGN.md 6.6) plus the vendor library; no Baysick logic lives here.
 *
 *   bench [--tsv FILE] [--e2e DIR] [--only LIST]
 *
 *   --tsv FILE   write the machine-readable rows (BENCH.md section 5) to FILE
 *   --e2e DIR    also time the compiled programs DIR/e2e_gemm, e2e_inv, e2e_mixed
 *                (expected stdout in DIR/NAME.out) once per usable kernel variant
 *   --only LIST  comma-separated subset of: peak gemm add sub scale trn inv e2e
 *
 * Environment: BENCH_QUICK=1 limits sizes (n <= 512, INV n <= 250) and the time per
 * measurement (0.2 s). Exit status: 0 measured and validated; 1 a validation failure;
 * 2 setup error.
 *
 * Compile with BENCH_VENDOR_ONLY defined to build without the Baysick runtime archive: only
 * the peak loops, the vendor library and the vendor-versus-C-reference validation run (a
 * self-test of the measuring instrument). Constants shared with the runtime come from the
 * generated runtime_consts.h (bench/run_mac.sh and bench/run_linux.sh derive it from
 * include/runtime.inc), so no value that has a name in an include file is repeated here.
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "runtime_consts.h"

#ifdef __APPLE__
#include <Accelerate/Accelerate.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <sys/sysctl.h>
#define BENCH_TARGET "arm64-macos"
typedef __LAPACK_int lint;
#else
#include <cblas.h>
#include <sched.h>
#define BENCH_TARGET "x86_64-linux"
typedef int lint;
extern void dgetrf_(const lint *m, const lint *n, double *a, const lint *lda, lint *ipiv, lint *info);
extern void dgetri_(const lint *n, double *a, const lint *lda, const lint *ipiv, double *work,
                    const lint *lwork, lint *info);
#endif

#pragma STDC FP_CONTRACT OFF

extern char **environ;

/* ---- Baysick kernel API (DESIGN.md 6.6.1); MV_* records of runtime.inc ------------- */
typedef struct {
    double *data;
    uint64_t rows, cols, ld;
} mview;
_Static_assert(offsetof(mview, data) == MV_DATA, "MV_DATA");
_Static_assert(offsetof(mview, rows) == MV_ROWS, "MV_ROWS");
_Static_assert(offsetof(mview, cols) == MV_COLS, "MV_COLS");
_Static_assert(offsetof(mview, ld) == MV_LD, "MV_LD");
_Static_assert(sizeof(mview) == MV_SIZE, "MV_SIZE");

#ifndef BENCH_VENDOR_ONLY
extern void bsk_kern_init(void);
extern int bsk_kern_use(const char *name);
extern const char *bsk_kern_name(void);
extern const char *const *bsk_kern_variants(void);
extern uint64_t bsk_kern_features(void);
extern int bsk_kern_gemm(const mview *c, const mview *a, const mview *b);
extern int bsk_kern_add(const mview *c, const mview *a, const mview *b);
extern int bsk_kern_sub(const mview *c, const mview *a, const mview *b);
extern int bsk_kern_scale(const mview *c, const mview *a, double k);
extern void bsk_kern_trn(const mview *c, const mview *a);
extern int bsk_kern_inv(const mview *x, const mview *a);
#endif

/* ---- Peak loops (peak_arm64.s / peak_x86_64.s) -------------------------------------- */
typedef double (*peak_fn)(uint64_t iterations);
#ifdef __APPLE__
extern double peak_neon_fma(uint64_t iterations);
#else
extern double peak_sse2(uint64_t iterations);
extern double peak_avx2_fma(uint64_t iterations);
#endif

/* ---- Global settings ------------------------------------------------------------------ */
#define MIN_REPS 5
#define MAX_REPS 1000
#define MAX_VARIANTS 16
#define MAX_ROWS 4096
#define TINY_BATCH_SECONDS 100e-6 /* a timed repetition of a very short call is batched up to this */

static int g_quick;
static double g_min_time = 1.0;
static FILE *g_tsv;
static char *g_tsv_final; /* requested TSV path */
static char *g_tsv_tmp;   /* "<path>.tmp": the file actually written until the run succeeds */
static char g_cpu[160];
static const char *g_only; /* --only list or NULL */
static char *g_variants[MAX_VARIANTS];
static int g_nvariants;

typedef enum { K_GEMM, K_ADD, K_SUB, K_SCALE, K_TRN, K_INV, K_COUNT } kernel_id;
static const char *const kernel_name[K_COUNT] = {"gemm", "add", "sub", "scale", "trn", "inv"};

/* ---- Small utilities ------------------------------------------------------------------ */
static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static void die_setup(const char *fmt, ...) __attribute__((noreturn, format(printf, 1, 2)));

/* atexit handler: any exit before tsv_commit() (die_*, exit(1/2)) removes the partial TSV, so a
 * failed run never leaves a truncated file that looks like a result. */
static void tsv_cleanup(void) {
    if (!g_tsv_tmp) return;
    if (g_tsv) fclose(g_tsv);
    g_tsv = NULL;
    unlink(g_tsv_tmp);
    free(g_tsv_tmp);
    g_tsv_tmp = NULL;
}

/* Success path: flush, close and rename the temporary file over the requested path. */
static void tsv_commit(void) {
    if (!g_tsv_tmp) return;
    FILE *f = g_tsv;
    g_tsv = NULL;
    if (fflush(f) != 0 || ferror(f)) {
        fclose(f);
        die_setup("write error on '%s': %s", g_tsv_tmp, strerror(errno));
    }
    if (fclose(f) != 0) die_setup("cannot close '%s': %s", g_tsv_tmp, strerror(errno));
    if (rename(g_tsv_tmp, g_tsv_final) != 0) die_setup("cannot rename '%s' to '%s': %s", g_tsv_tmp, g_tsv_final, strerror(errno));
    free(g_tsv_tmp);
    g_tsv_tmp = NULL;
}

static void die_setup(const char *fmt, ...) __attribute__((noreturn, format(printf, 1, 2)));
static void die_setup(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fputs("bench: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    exit(2);
}

static void die_validation(const char *kernel, const char *variant, int n, const char *fmt, ...)
    __attribute__((noreturn, format(printf, 4, 5)));
static void die_validation(const char *kernel, const char *variant, int n, const char *fmt, ...) {
    va_list ap;
    fflush(stdout);
    fprintf(stderr, "bench: VALIDATION FAILED kernel=%s variant=%s n=%d: ", kernel, variant, n);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(1);
}

static void *xalloc(size_t bytes) {
    void *p = NULL;
    if (bytes == 0) bytes = 64;
    if (posix_memalign(&p, 64, bytes) != 0) die_setup("out of memory (%zu bytes)", bytes);
    return p;
}

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static int only_has(const char *name) {
    if (!g_only) return 1;
    size_t len = strlen(name);
    const char *p = g_only;
    while (*p) {
        const char *e = strchr(p, ',');
        size_t l = e ? (size_t)(e - p) : strlen(p);
        if (l == len && strncmp(p, name, len) == 0) return 1;
        if (!e) break;
        p = e + 1;
    }
    return 0;
}

static void detect_cpu(void) {
    g_cpu[0] = 0;
#ifdef __APPLE__
    size_t len = sizeof g_cpu;
    if (sysctlbyname("machdep.cpu.brand_string", g_cpu, &len, NULL, 0) != 0) g_cpu[0] = 0;
#else
    FILE *f = fopen("/proc/cpuinfo", "r");
    char line[512];
    while (f && fgets(line, sizeof line, f)) {
        if (strncmp(line, "model name", 10) == 0) {
            char *c = strchr(line, ':');
            if (c) {
                c++;
                while (*c == ' ') c++;
                c[strcspn(c, "\n")] = 0;
                snprintf(g_cpu, sizeof g_cpu, "%s", c);
                break;
            }
        }
    }
    if (f) fclose(f);
#endif
    if (!g_cpu[0]) snprintf(g_cpu, sizeof g_cpu, "unknown");
}

/* BENCH.md 3.1: performance cores on macOS, CPU 1 on Linux. */
static void place_process(void) {
#ifdef __APPLE__
    if (pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0) != 0)
        fprintf(stderr, "bench: warning: could not raise the QoS class\n");
#else
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(1, &set);
    if (sched_setaffinity(0, sizeof set, &set) != 0) {
        CPU_ZERO(&set);
        CPU_SET(0, &set);
        if (sched_setaffinity(0, sizeof set, &set) != 0)
            fprintf(stderr, "bench: warning: could not pin the process to a CPU\n");
        else
            fprintf(stderr, "bench: warning: CPU 1 unavailable, pinned to CPU 0\n");
    }
#endif
}

/* ---- Measurement (BENCH.md 3.1) ------------------------------------------------------- */
typedef struct {
    int reps;
    double med, mn, mx;
} meas;

typedef void (*op_fn)(void *ctx);

/*
 * One untimed warm-up call, then timed repetitions until at least MIN_REPS repetitions and
 * g_min_time seconds have elapsed (at most MAX_REPS); the median repetition is the result.
 * `prep`, if given, runs untimed before every call (INV: the vendor call destroys its input).
 * A call shorter than TINY_BATCH_SECONDS is run in a batch inside each timed repetition and
 * the repetition's time is the batch time divided by the batch size, so the resolution of
 * the clock does not dominate microsecond kernels.
 */
static meas measure(op_fn op, op_fn prep, void *ctx) {
    static double ts[MAX_REPS];
    meas m;
    int inner = 1, n = 0;
    double a, b, warm;
    if (prep) prep(ctx);
    a = now_s();
    op(ctx);
    warm = now_s() - a;
    if (!prep && warm < TINY_BATCH_SECONDS) {
        a = now_s();
        op(ctx);
        warm = now_s() - a;
        if (warm < 1e-9) warm = 1e-9;
        inner = (int)ceil(TINY_BATCH_SECONDS / warm);
        if (inner > 100000) inner = 100000;
        if (inner < 1) inner = 1;
    }
    double start = now_s();
    for (;;) {
        if (prep) prep(ctx);
        a = now_s();
        for (int i = 0; i < inner; i++) op(ctx);
        b = now_s();
        ts[n++] = (b - a) / inner;
        if (n >= MAX_REPS) break;
        if (n >= MIN_REPS && (b - start) >= g_min_time) break;
    }
    qsort(ts, (size_t)n, sizeof ts[0], cmp_double);
    m.reps = n;
    m.mn = ts[0];
    m.mx = ts[n - 1];
    m.med = (n & 1) ? ts[n / 2] : 0.5 * (ts[n / 2 - 1] + ts[n / 2]);
    return m;
}

/* ---- Peak measurement (BENCH.md 3.4) -------------------------------------------------- */
typedef struct {
    const char *name; /* "neon-fma", "sse2", "avx2-fma" */
    double gflops;
} peak_t;
static peak_t g_peaks[4];
static int g_npeaks;

static double timed_peak_call(peak_fn f, uint64_t iters) {
    double a = now_s();
    double r = f(iters);
    double t = now_s() - a;
    if (r != 1.0 + (double)iters) {
        fprintf(stderr, "bench: peak loop returned %.17g, expected %.17g\n", r, 1.0 + (double)iters);
        exit(1);
    }
    return t;
}

static void measure_peak(const char *name, peak_fn f, double flops_per_iter) {
    double warm_s = g_quick ? 0.05 : 0.2, run_s = g_quick ? 0.1 : 0.5;
    int runs = g_quick ? 3 : 5;
    uint64_t iters = 100000;
    double t, best = 0, w0;
    /* calibrate: iterations that take about run_s */
    for (;;) {
        t = timed_peak_call(f, iters);
        if (t >= 0.005) break;
        iters *= 10;
    }
    iters = (uint64_t)((double)iters * run_s / t);
    if (iters < 1) iters = 1;
    w0 = now_s();
    while (now_s() - w0 < warm_s) timed_peak_call(f, iters / 10 + 1);
    for (int r = 0; r < runs; r++) {
        t = timed_peak_call(f, iters);
        double g = flops_per_iter * (double)iters / t * 1e-9;
        if (g > best) best = g;
    }
    g_peaks[g_npeaks].name = name;
    g_peaks[g_npeaks].gflops = best;
    g_npeaks++;
}

static void measure_all_peaks(void) {
#ifdef __APPLE__
    measure_peak("neon-fma", peak_neon_fma, 96.0);
#else
    measure_peak("sse2", peak_sse2, 48.0);
    __builtin_cpu_init();
    if (__builtin_cpu_supports("avx2") && __builtin_cpu_supports("fma"))
        measure_peak("avx2-fma", peak_avx2_fma, 96.0);
#endif
}

__attribute__((unused)) static double peak_for_variant(const char *variant, const char **pname) {
    const char *want = NULL;
    if (!strcmp(variant, "neon")) want = "neon-fma";
    else if (!strcmp(variant, "sse2")) want = "sse2";
    else if (!strcmp(variant, "avx2")) want = "avx2-fma";
    for (int i = 0; want && i < g_npeaks; i++)
        if (!strcmp(g_peaks[i].name, want)) {
            if (pname) *pname = g_peaks[i].name;
            return g_peaks[i].gflops;
        }
    return 0;
}

/* ---- Workload data (BENCH.md 2) -------------------------------------------------------- */
static uint64_t g_rng;

static void fill_random(double *p, size_t count) {
    for (size_t i = 0; i < count; i++) {
        g_rng = 6364136223846793005ULL * g_rng + 1442695040888963407ULL;
        p[i] = (double)(g_rng >> 11) * 0x1p-52 - 1.0;
    }
}

#define SCALE_K 0.1 /* the scale factor of the scale kernel (inexact: exercises rounding) */

typedef struct {
    kernel_id kern;
    int n;
    double *A, *B; /* inputs, n x n, ld = n */
    double *C;     /* Baysick output */
    double *V;     /* vendor output / working copy */
    double k;
    mview a, b, c;
    lint *ipiv;
    double *work;
    lint lwork;
} bcase;

static void mk_view(mview *v, double *p, int n) {
    v->data = p;
    v->rows = (uint64_t)n;
    v->cols = (uint64_t)n;
    v->ld = (uint64_t)n;
}

/* ---- Vendor operations ------------------------------------------------------------------ */
static void vendor_prep(void *p) { /* INV only: dgetrf destroys its input */
    bcase *c = p;
    memcpy(c->V, c->A, (size_t)c->n * (size_t)c->n * sizeof(double));
}

static void vendor_op(void *p) {
    bcase *c = p;
    const int n = c->n;
    const size_t nn = (size_t)n * (size_t)n;
    switch (c->kern) {
    case K_GEMM:
        cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, n, n, n, 1.0, c->A, n, c->B, n, 0.0, c->V, n);
        break;
#ifdef __APPLE__
    case K_ADD: vDSP_vaddD(c->A, 1, c->B, 1, c->V, 1, nn); break;
    case K_SUB: vDSP_vsubD(c->B, 1, c->A, 1, c->V, 1, nn); break; /* vDSP: C = A - B with (B, A) order */
    case K_SCALE: vDSP_vsmulD(c->A, 1, &c->k, c->V, 1, nn); break;
    case K_TRN: vDSP_mtransD(c->A, 1, c->V, 1, (vDSP_Length)n, (vDSP_Length)n); break;
#else
    case K_ADD: /* proxy: copy A, then C += 1 * B */
        cblas_dcopy((int)nn, c->A, 1, c->V, 1);
        cblas_daxpy((int)nn, 1.0, c->B, 1, c->V, 1);
        break;
    case K_SUB: /* proxy: copy A, then C += -1 * B */
        cblas_dcopy((int)nn, c->A, 1, c->V, 1);
        cblas_daxpy((int)nn, -1.0, c->B, 1, c->V, 1);
        break;
    case K_SCALE: /* proxy: copy A, then C *= k */
        cblas_dcopy((int)nn, c->A, 1, c->V, 1);
        cblas_dscal((int)nn, c->k, c->V, 1);
        break;
    case K_TRN: cblas_domatcopy(CblasRowMajor, CblasTrans, n, n, 1.0, c->A, n, c->V, n); break;
#endif
    case K_INV: {
        /* The row-major buffer read as column-major is A^T; its inverse is (A^-1)^T, which
           read back as row-major is A^-1. */
        lint ln = n, info = 0;
        dgetrf_(&ln, &ln, c->V, &ln, c->ipiv, &info);
        if (info != 0) {
            fprintf(stderr, "bench: vendor dgetrf failed (info %d) n=%d\n", (int)info, n);
            exit(2);
        }
        dgetri_(&ln, c->V, &ln, c->ipiv, c->work, &c->lwork, &info);
        if (info != 0) {
            fprintf(stderr, "bench: vendor dgetri failed (info %d) n=%d\n", (int)info, n);
            exit(2);
        }
        break;
    }
    default: break;
    }
}

#ifndef BENCH_VENDOR_ONLY
/* ---- Baysick operation: the exported trampolines, exactly what BASIC programs run ------ */
static void baysick_op(void *p) {
    bcase *c = p;
    switch (c->kern) {
    case K_GEMM: bsk_kern_gemm(&c->c, &c->a, &c->b); break;
    case K_ADD: bsk_kern_add(&c->c, &c->a, &c->b); break;
    case K_SUB: bsk_kern_sub(&c->c, &c->a, &c->b); break;
    case K_SCALE: bsk_kern_scale(&c->c, &c->a, c->k); break;
    case K_TRN: bsk_kern_trn(&c->c, &c->a); break;
    case K_INV: bsk_kern_inv(&c->c, &c->a); break;
    default: break;
    }
}

static int baysick_status(bcase *c) {
    switch (c->kern) {
    case K_GEMM: return bsk_kern_gemm(&c->c, &c->a, &c->b);
    case K_ADD: return bsk_kern_add(&c->c, &c->a, &c->b);
    case K_SUB: return bsk_kern_sub(&c->c, &c->a, &c->b);
    case K_SCALE: return bsk_kern_scale(&c->c, &c->a, c->k);
    case K_TRN: bsk_kern_trn(&c->c, &c->a); return KS_OK;
    case K_INV: return bsk_kern_inv(&c->c, &c->a);
    default: return KS_OK;
    }
}
#endif

/* ---- C references (compiled with -ffp-contract=off) ------------------------------------- */
static void ref_elementwise(const bcase *c, double *out) {
    const size_t nn = (size_t)c->n * (size_t)c->n;
    for (size_t i = 0; i < nn; i++) {
        switch (c->kern) {
        case K_ADD: out[i] = c->A[i] + c->B[i]; break;
        case K_SUB: out[i] = c->A[i] - c->B[i]; break;
        case K_SCALE: out[i] = c->k * c->A[i]; break;
        default: break;
        }
    }
}

static void ref_trn(const bcase *c, double *out) {
    const int n = c->n;
    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++) out[(size_t)j * n + i] = c->A[(size_t)i * n + j];
}

/* plain product and the per-element error bound 2*k*2^-53*sum|a||b| (n <= 512) */
static void ref_gemm(const bcase *c, double *out, double *bnd) {
    const int n = c->n;
    memset(out, 0, (size_t)n * n * sizeof(double));
    if (bnd) memset(bnd, 0, (size_t)n * n * sizeof(double));
    for (int i = 0; i < n; i++)
        for (int k = 0; k < n; k++) {
            const double a = c->A[(size_t)i * n + k];
            const double aa = fabs(a);
            for (int j = 0; j < n; j++) {
                const double b = c->B[(size_t)k * n + j];
                out[(size_t)i * n + j] += a * b;
                if (bnd) bnd[(size_t)i * n + j] += aa * fabs(b);
            }
        }
    if (bnd)
        for (size_t i = 0; i < (size_t)n * n; i++) bnd[i] *= 2.0 * n * 0x1p-53;
}

static double max_abs(const double *p, size_t cnt) {
    double m = 0;
    for (size_t i = 0; i < cnt; i++)
        if (fabs(p[i]) > m) m = fabs(p[i]);
    return m;
}

/* ---- Comparisons ------------------------------------------------------------------------ */
/* first index where the bit patterns differ (zero_tol: +0 and -0 are equal), else -1 */
static long first_bit_diff(const double *x, const double *y, size_t cnt, int zero_tol) {
    for (size_t i = 0; i < cnt; i++) {
        if (memcmp(&x[i], &y[i], sizeof(double)) == 0) continue;
        if (zero_tol && x[i] == 0.0 && y[i] == 0.0) continue;
        return (long)i;
    }
    return -1;
}

static long first_bound_violation(const double *x, const double *y, size_t cnt, const double *bnd, double bnd0) {
    for (size_t i = 0; i < cnt; i++) {
        double d = fabs(x[i] - y[i]);
        if (!(d <= (bnd ? bnd[i] : bnd0))) return (long)i;
    }
    return -1;
}

/* ---- Result rows, report and TSV (BENCH.md 5) --------------------------------------------- */
typedef struct {
    char kernel[16], variant[16];
    int n;
    double rate;        /* Baysick, in `unit`; NaN when none */
    double vendor_rate; /* NaN when none */
    double peak;        /* 0 when none */
    int gflops;
} row_t;
static row_t g_rows[MAX_ROWS];
static int g_nrows;

static void print_cell(const char *fmt, double v, int width) {
    char buf[64];
    if (isnan(v)) snprintf(buf, sizeof buf, "-");
    else snprintf(buf, sizeof buf, fmt, v);
    printf("%-*s ", width, buf);
}

static void emit_row(const char *kernel, const char *variant, int n, int k, const meas *me, const char *unit,
                     double rate, double vendor_rate, double peak) {
    int gflops = strcmp(unit, "GFLOP/s") == 0;
    double pv = (!isnan(rate) && !isnan(vendor_rate) && vendor_rate > 0) ? 100.0 * rate / vendor_rate : NAN;
    double pp = (gflops && peak > 0 && !isnan(rate)) ? 100.0 * rate / peak : NAN;
    printf("%-7s %-8s %-5d %-12.7f ", kernel, variant, n, me->med);
    print_cell("%.2f", rate, 9);
    print_cell("%.2f", vendor_rate, 8);
    print_cell("%.1f", pv, 8);
    print_cell("%.1f", (gflops && peak > 0) ? peak : NAN, 7);
    print_cell("%.1f", pp, 6);
    printf("\n");
    fflush(stdout);
    if (g_tsv) {
        fprintf(g_tsv, "%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%.9g\t%.9g\t%.9g\t%s\t", BENCH_TARGET, g_cpu, kernel, variant, n, n,
                k, me->reps, me->med, me->mn, me->mx, unit);
        if (!isnan(rate)) fprintf(g_tsv, "%.6g", rate);
        fputc('\t', g_tsv);
        if (!isnan(vendor_rate)) fprintf(g_tsv, "%.6g", vendor_rate);
        fputc('\t', g_tsv);
        if (!isnan(pv)) fprintf(g_tsv, "%.4g", pv);
        fputc('\t', g_tsv);
        if (gflops && peak > 0) fprintf(g_tsv, "%.6g", peak);
        fputc('\t', g_tsv);
        if (!isnan(pp)) fprintf(g_tsv, "%.4g", pp);
        fputc('\n', g_tsv);
        fflush(g_tsv);
    }
    if (g_nrows < MAX_ROWS) {
        row_t *r = &g_rows[g_nrows++];
        snprintf(r->kernel, sizeof r->kernel, "%s", kernel);
        snprintf(r->variant, sizeof r->variant, "%s", variant);
        r->n = n;
        r->rate = rate;
        r->vendor_rate = vendor_rate;
        r->peak = (gflops && peak > 0) ? peak : 0;
        r->gflops = gflops;
    }
}

/* ---- Kernel workloads ------------------------------------------------------------------- */
static const int gemm_sizes[] = {64, 127, 128, 255, 256, 512, 1023, 1024, 2048, 0};
static const int ew_sizes[] = {64, 256, 1024, 2048, 0};
/* INV sizes: one list feeds both the array and the build-time check, so a size above the
 * kernel's static workspace limit (RT_KERN_INV_MAXN, generated runtime_consts.h) cannot build. */
#define INV_SIZE_LIST X(100) X(250) X(500) X(1000)
#define X(n) _Static_assert((n) <= RT_KERN_INV_MAXN, "INV size exceeds RT_KERN_INV_MAXN");
INV_SIZE_LIST
#undef X
#define X(n) n,
static const int inv_sizes[] = {INV_SIZE_LIST 0};
#undef X

static double work_units(kernel_id k, int n, const char **unit) {
    double nn = (double)n * (double)n;
    switch (k) {
    case K_GEMM:
    case K_INV: *unit = "GFLOP/s"; return 2.0 * nn * (double)n;
    case K_ADD:
    case K_SUB: *unit = "GB/s"; return 24.0 * nn;
    default: *unit = "GB/s"; return 16.0 * nn; /* scale, trn */
    }
}

static void print_block_header(kernel_id k) {
    const char *unit;
    work_units(k, 1, &unit);
    printf("\n# %s  (rates in %s)\n", kernel_name[k], unit);
    printf("kernel  variant  n     median_s     baysick   vendor   %%vendor  peak    %%peak\n");
    fflush(stdout);
}

static void run_kernel_size(kernel_id kern, int n) {
    const size_t nn = (size_t)n * (size_t)n;
    const size_t bytes = nn * sizeof(double);
    const char *unit;
    bcase c;
    memset(&c, 0, sizeof c);
    c.kern = kern;
    c.n = n;
    c.k = SCALE_K;
    c.A = xalloc(bytes);
    c.B = xalloc(bytes);
    c.C = xalloc(bytes);
    c.V = xalloc(bytes);
    double *ref = xalloc(bytes);
    double *base = xalloc(bytes);
    double *bnd = (kern == K_GEMM && n <= 512) ? xalloc(bytes) : NULL;
    double bnd0 = 0;
    g_rng = 1964;
    fill_random(c.A, nn);
    fill_random(c.B, nn);
    if (kern == K_INV)
        for (int i = 0; i < n; i++) c.A[(size_t)i * n + i] += (double)n;
    mk_view(&c.a, c.A, n);
    mk_view(&c.b, c.B, n);
    mk_view(&c.c, c.C, n);
    if (kern == K_INV) {
        c.ipiv = xalloc((size_t)n * sizeof(lint));
        lint ln = n, lw = -1, info = 0;
        double wq = 0;
        dgetri_(&ln, c.V, &ln, c.ipiv, &wq, &lw, &info); /* workspace query */
        c.lwork = (info == 0 && wq > 0) ? (lint)wq : (lint)(64 * n);
        if (c.lwork < n) c.lwork = n;
        c.work = xalloc((size_t)c.lwork * sizeof(double));
    }

    /* --- vendor result, checked against the plain C reference where one exists --- */
    if (kern == K_INV) vendor_prep(&c);
    vendor_op(&c);
    switch (kern) {
    case K_GEMM:
        if (bnd) {
            ref_gemm(&c, ref, bnd);
            long bad = first_bound_violation(c.V, ref, nn, bnd, 0);
            if (bad >= 0) die_validation("gemm", "vendor", n, "vendor result differs from the C reference at element %ld", bad);
        } else {
            bnd0 = 2.0 * n * 0x1p-53 * (double)n * max_abs(c.A, nn) * max_abs(c.B, nn);
        }
        break;
    case K_ADD:
    case K_SUB:
    case K_SCALE:
    case K_TRN: {
        if (kern == K_TRN) ref_trn(&c, ref);
        else ref_elementwise(&c, ref);
        long bad = first_bit_diff(c.V, ref, nn, 0);
        if (bad >= 0)
            die_validation(kernel_name[kern], "vendor", n, "vendor result differs bitwise from the C reference at element %ld (%.17g vs %.17g)",
                           bad, c.V[bad], ref[bad]);
        break;
    }
    case K_INV: {
        /* A * X must be the identity to within the conditioning of this matrix */
        double worst = 0;
        for (int i = 0; i < n; i += (n > 250 ? 7 : 1))
            for (int j = 0; j < n; j += (n > 250 ? 5 : 1)) {
                double s = 0;
                for (int k = 0; k < n; k++) s += c.A[(size_t)i * n + k] * c.V[(size_t)k * n + j];
                s -= (i == j);
                if (fabs(s) > worst) worst = fabs(s);
            }
        if (!(worst <= 1e-9)) die_validation("inv", "vendor", n, "vendor A*inv(A) differs from the identity by %.3g", worst);
        break;
    }
    default: break;
    }
    const double vmax = (kern == K_INV) ? max_abs(c.V, nn) : 0;
    (void)vmax;
    (void)bnd0;

#ifndef BENCH_VENDOR_ONLY
    /* --- baseline variant result (class-E and INV comparisons are against it) --- */
    if (bsk_kern_use("baseline") != 0) die_setup("_bsk_kern_use(\"baseline\") failed");
    memset(c.C, 0xff, bytes);
    int st = baysick_status(&c);
    if (st != KS_OK) die_validation(kernel_name[kern], "baseline", n, "kernel returned status %d", st);
    memcpy(base, c.C, bytes);

    /* --- every usable variant, validated before any timing --- */
    for (int v = 0; v < g_nvariants; v++) {
        const char *vn = g_variants[v];
        if (bsk_kern_use(vn) != 0) die_setup("_bsk_kern_use(\"%s\") failed for a listed variant", vn);
        memset(c.C, 0xff, bytes);
        st = baysick_status(&c);
        if (st != KS_OK) die_validation(kernel_name[kern], vn, n, "kernel returned status %d", st);
        long bad;
        switch (kern) {
        case K_GEMM:
            bad = first_bound_violation(c.C, c.V, nn, bnd, bnd0);
            if (bad >= 0) die_validation("gemm", vn, n, "element %ld = %.17g, vendor %.17g", bad, c.C[bad], c.V[bad]);
            bad = first_bound_violation(c.C, base, nn, bnd, bnd0);
            if (bad >= 0) die_validation("gemm", vn, n, "element %ld = %.17g, baseline %.17g", bad, c.C[bad], base[bad]);
            break;
        case K_INV:
            for (size_t i = 0; i < nn; i++)
                if (!(fabs(c.C[i] - c.V[i]) <= 1e-8 * vmax))
                    die_validation("inv", vn, n, "element %zu = %.17g, vendor %.17g", i, c.C[i], c.V[i]);
            /* class E: bit-identical to the baseline (the sign of a zero may differ, DESIGN.md 6.6.4) */
            bad = first_bit_diff(c.C, base, nn, 1);
            if (bad >= 0) die_validation("inv", vn, n, "element %ld = %.17g differs from the baseline %.17g", bad, c.C[bad], base[bad]);
            break;
        default:
            bad = first_bit_diff(c.C, ref, nn, 0);
            if (bad >= 0)
                die_validation(kernel_name[kern], vn, n, "element %ld = %.17g, reference %.17g (bit-for-bit required)", bad, c.C[bad], ref[bad]);
            bad = first_bit_diff(c.C, base, nn, 0);
            if (bad >= 0) die_validation(kernel_name[kern], vn, n, "element %ld differs from the baseline", bad);
            break;
        }
    }
#endif

    /* --- timing --- */
    double units = work_units(kern, n, &unit);
    meas vm = measure(vendor_op, kern == K_INV ? vendor_prep : NULL, &c);
    double vrate = units / vm.med * 1e-9;
    int k_inner = (kern == K_GEMM) ? n : 0;
#ifdef BENCH_VENDOR_ONLY
    emit_row(kernel_name[kern], "-", n, k_inner, &vm, unit, NAN, vrate, 0);
#else
    for (int v = 0; v < g_nvariants; v++) {
        const char *vn = g_variants[v];
        if (bsk_kern_use(vn) != 0) die_setup("_bsk_kern_use(\"%s\") failed for a listed variant", vn);
        memset(c.C, 0xff, bytes);
        meas bm = measure(baysick_op, NULL, &c);
        emit_row(kernel_name[kern], vn, n, k_inner, &bm, unit, units / bm.med * 1e-9, vrate, peak_for_variant(vn, NULL));
    }
#endif
    free(c.A);
    free(c.B);
    free(c.C);
    free(c.V);
    free(ref);
    free(base);
    free(bnd);
    free(c.ipiv);
    free(c.work);
}

static void run_kernel(kernel_id kern) {
    const int *sizes = (kern == K_GEMM) ? gemm_sizes : (kern == K_INV) ? inv_sizes : ew_sizes;
    print_block_header(kern);
    for (; *sizes; sizes++) {
        if (g_quick && *sizes > (kern == K_INV ? 250 : 512)) continue;
        run_kernel_size(kern, *sizes);
    }
}

/* ---- End-to-end programs (BENCH.md 2) ----------------------------------------------------- */
static const char *const e2e_names[] = {"e2e_gemm", "e2e_inv", "e2e_mixed"};

static char *slurp(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) die_setup("cannot read '%s': %s", path, strerror(errno));
    size_t cap = 4096, n = 0;
    char *buf = malloc(cap);
    size_t got;
    while (buf && (got = fread(buf + n, 1, cap - n, f)) > 0) {
        n += got;
        if (n == cap) {
            cap *= 2;
            buf = realloc(buf, cap);
        }
    }
    fclose(f);
    if (!buf) die_setup("out of memory");
    *len = n;
    return buf;
}

/* Run `exe` once with BAYSICK_KERNELS=variant (if non-NULL); stdout into *out. Returns the
   wall seconds, or -1 on failure to run / non-zero exit / timeout. */
static double run_process(const char *exe, const char *variant, char **out, size_t *outlen) {
    int pfd[2];
    if (pipe(pfd) != 0) die_setup("pipe: %s", strerror(errno));
    size_t nenv = 0;
    while (environ[nenv]) nenv++;
    char **envp = calloc(nenv + 2, sizeof *envp);
    size_t ne = 0;
    for (size_t i = 0; i < nenv; i++)
        if (strncmp(environ[i], "BAYSICK_KERNELS=", 16) != 0) envp[ne++] = environ[i];
    char kv[64];
    if (variant) {
        snprintf(kv, sizeof kv, "BAYSICK_KERNELS=%s", variant);
        envp[ne++] = kv;
    }
    envp[ne] = NULL;
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&fa, pfd[1], 1);
    posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addclose(&fa, pfd[0]);
    posix_spawn_file_actions_addclose(&fa, pfd[1]);
    char *argv[] = {(char *)exe, NULL};
    pid_t pid;
    double t0 = now_s();
    int rc = posix_spawn(&pid, exe, &fa, NULL, argv, envp);
    posix_spawn_file_actions_destroy(&fa);
    free(envp);
    close(pfd[1]);
    if (rc != 0) {
        close(pfd[0]);
        fprintf(stderr, "bench: cannot run '%s': %s\n", exe, strerror(rc));
        return -1;
    }
    size_t cap = 4096, n = 0;
    char *buf = malloc(cap);
    int timed_out = 0;
    for (;;) {
        struct pollfd p = {pfd[0], POLLIN, 0};
        int pr = poll(&p, 1, 1000);
        if (pr < 0 && errno == EINTR) continue;
        if (now_s() - t0 > 300.0) {
            timed_out = 1;
            kill(pid, SIGKILL);
            break;
        }
        if (pr == 0) continue;
        if (n + 4096 > cap) {
            cap *= 2;
            buf = realloc(buf, cap);
        }
        ssize_t r = read(pfd[0], buf + n, cap - n);
        if (r <= 0) break;
        n += (size_t)r;
    }
    int status = 0;
    waitpid(pid, &status, 0);
    double t = now_s() - t0;
    close(pfd[0]);
    if (timed_out || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        free(buf);
        fprintf(stderr, "bench: '%s' %s\n", exe, timed_out ? "timed out" : "did not exit with status 0");
        return -1;
    }
    *out = buf;
    *outlen = n;
    return t;
}

static void run_e2e(const char *dir) {
    int reps = g_quick ? 1 : 3;
    printf("\n# end-to-end  (compiled BASIC programs, wall seconds of the whole process)\n");
    printf("program     variant  reps  median_s\n");
    for (size_t pi = 0; pi < sizeof e2e_names / sizeof e2e_names[0]; pi++) {
        char exe[1024], outp[1024];
        snprintf(exe, sizeof exe, "%s/%s", dir, e2e_names[pi]);
        snprintf(outp, sizeof outp, "%s/%s.out", dir, e2e_names[pi]);
        size_t explen;
        char *expect = slurp(outp, &explen);
        int nv = g_nvariants ? g_nvariants : 1;
        for (int v = 0; v < nv; v++) {
            const char *vn = g_nvariants ? g_variants[v] : NULL;
            double ts[8];
            for (int r = 0; r < reps; r++) {
                char *got = NULL;
                size_t gl = 0;
                double t = run_process(exe, vn, &got, &gl);
                if (t < 0) die_validation(e2e_names[pi], vn ? vn : "-", 0, "program failed to run");
                if (gl != explen || memcmp(got, expect, gl) != 0)
                    die_validation(e2e_names[pi], vn ? vn : "-", 0, "stdout differs from %s", outp);
                free(got);
                ts[r] = t;
            }
            qsort(ts, (size_t)reps, sizeof ts[0], cmp_double);
            meas m = {reps, ts[reps / 2], ts[0], ts[reps - 1]};
            if (reps % 2 == 0) m.med = 0.5 * (ts[reps / 2 - 1] + ts[reps / 2]);
            printf("%-11s %-8s %-5d %.3f\n", e2e_names[pi], vn ? vn : "-", reps, m.med);
            fflush(stdout);
            if (g_tsv)
                fprintf(g_tsv, "%s\t%s\t%s\t%s\t0\t0\t0\t%d\t%.9g\t%.9g\t%.9g\ts\t\t\t\t\t\n", BENCH_TARGET, g_cpu,
                        e2e_names[pi], vn ? vn : "-", m.reps, m.med, m.mn, m.mx);
        }
        free(expect);
    }
    if (g_tsv) fflush(g_tsv);
}

/* ---- Goals (BENCH.md 6): reported, never enforced --------------------------------------- */
static const row_t *find_row(const char *kernel, const char *variant, int n) {
    for (int i = 0; i < g_nrows; i++)
        if (g_rows[i].n == n && !strcmp(g_rows[i].kernel, kernel) && !strcmp(g_rows[i].variant, variant)) return &g_rows[i];
    return NULL;
}

static void goal_line(const char *variant, const char *what, int have, double worst, double goal, double stretch) {
    if (!have) {
        printf("#   %-8s %-46s not measured\n", variant, what);
        return;
    }
    printf("#   %-8s %-46s worst %.1f%%  (goal %.0f%%", variant, what, worst, goal);
    if (stretch > 0) printf(", stretch %.0f%%", stretch);
    printf(")  %s", worst >= goal ? "MET" : "NOT MET");
    if (stretch > 0 && worst >= goal) printf(worst >= stretch ? ", stretch MET" : ", stretch not met");
    printf("\n");
}

static void report_goals(void) {
    printf("\n# goals (BENCH.md section 6; reported, not enforced)\n");
    for (int v = 0; v < g_nvariants; v++) {
        const char *vn = g_variants[v];
        double worst;
        int have;
        /* GEMM n >= 512: >= 70% of peak (stretch 85%) */
        worst = 1e30; have = 0;
        for (int i = 0; i < g_nrows; i++)
            if (!strcmp(g_rows[i].kernel, "gemm") && !strcmp(g_rows[i].variant, vn) && g_rows[i].n >= 512 && g_rows[i].peak > 0) {
                double p = 100.0 * g_rows[i].rate / g_rows[i].peak;
                if (p < worst) worst = p;
                have = 1;
            }
        goal_line(vn, "gemm n>=512, % of peak (stretch 85)", have, worst, 70, 85);
        /* GEMM n = 64..256: >= 50% of peak */
        worst = 1e30; have = 0;
        for (int i = 0; i < g_nrows; i++)
            if (!strcmp(g_rows[i].kernel, "gemm") && !strcmp(g_rows[i].variant, vn) && g_rows[i].n >= 64 && g_rows[i].n <= 256 && g_rows[i].peak > 0) {
                double p = 100.0 * g_rows[i].rate / g_rows[i].peak;
                if (p < worst) worst = p;
                have = 1;
            }
        goal_line(vn, "gemm n=64..256, % of peak", have, worst, 50, 0);
        /* GEMM odd n within 10% of the neighbouring even size's rate */
        static const int odd[3][2] = {{127, 128}, {255, 256}, {1023, 1024}};
        worst = 1e30; have = 0;
        for (int i = 0; i < 3; i++) {
            const row_t *o = find_row("gemm", vn, odd[i][0]), *e = find_row("gemm", vn, odd[i][1]);
            if (o && e) {
                double p = 100.0 * o->rate / e->rate;
                if (p < worst) worst = p;
                have = 1;
            }
        }
        goal_line(vn, "gemm odd n, % of the even neighbour's rate", have, worst, 90, 0);
        /* add, sub, scale: >= 80% of vendor at every size */
        static const char *const ew[3] = {"add", "sub", "scale"};
        for (int k = 0; k < 3; k++) {
            worst = 1e30; have = 0;
            for (int i = 0; i < g_nrows; i++)
                if (!strcmp(g_rows[i].kernel, ew[k]) && !strcmp(g_rows[i].variant, vn)) {
                    double p = 100.0 * g_rows[i].rate / g_rows[i].vendor_rate;
                    if (p < worst) worst = p;
                    have = 1;
                }
            char what[64];
            snprintf(what, sizeof what, "%s, %% of vendor GB/s, every size", ew[k]);
            goal_line(vn, what, have, worst, 80, 0);
        }
        /* transpose: >= 50% of vendor, n >= 256 */
        worst = 1e30; have = 0;
        for (int i = 0; i < g_nrows; i++)
            if (!strcmp(g_rows[i].kernel, "trn") && !strcmp(g_rows[i].variant, vn) && g_rows[i].n >= 256) {
                double p = 100.0 * g_rows[i].rate / g_rows[i].vendor_rate;
                if (p < worst) worst = p;
                have = 1;
            }
        goal_line(vn, "trn n>=256, % of vendor GB/s", have, worst, 50, 0);
        /* INV: correct (validated above) and >= 25% of vendor at n = 100 */
        const row_t *r = find_row("inv", vn, 100);
        goal_line(vn, "inv n=100, % of vendor (validated correct)", r != NULL, r ? 100.0 * r->rate / r->vendor_rate : 0, 25, 0);
    }
}

/* ---- main ------------------------------------------------------------------------------- */
static void list_features(char *buf, size_t cap) {
    buf[0] = 0;
#ifndef BENCH_VENDOR_ONLY
    static const struct {
        uint64_t bit;
        const char *name;
    } names[] = {{KF_A64_SME, "sme"}, {KF_A64_SME2, "sme2"}, {KF_A64_SME_F64F64, "sme_f64f64"}, {KF_X64_AVX2, "avx2"}, {KF_X64_FMA, "fma"}};
    uint64_t f = bsk_kern_features();
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++)
        if (f & names[i].bit) {
            if (buf[0]) strncat(buf, ",", cap - strlen(buf) - 1);
            strncat(buf, names[i].name, cap - strlen(buf) - 1);
        }
#endif
    if (!buf[0]) snprintf(buf, cap, "-");
}

int main(int argc, char **argv) {
    const char *tsv_path = NULL, *e2e_dir = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--tsv") && i + 1 < argc) tsv_path = argv[++i];
        else if (!strcmp(argv[i], "--e2e") && i + 1 < argc) e2e_dir = argv[++i];
        else if (!strcmp(argv[i], "--only") && i + 1 < argc) g_only = argv[++i];
        else die_setup("usage: bench [--tsv FILE] [--e2e DIR] [--only LIST]");
    }
    const char *q = getenv("BENCH_QUICK");
    g_quick = q && *q && strcmp(q, "0") != 0;
    if (g_quick) g_min_time = 0.2;

    /* the vendor library must run single-threaded: set before its first call */
#ifdef __APPLE__
    setenv("VECLIB_MAXIMUM_THREADS", "1", 1);
    const char *vendor_name = "Accelerate (single thread)";
#else
    setenv("OPENBLAS_NUM_THREADS", "1", 1);
    const char *cfg = openblas_get_config();
    if (!cfg || !strstr(cfg, "OpenBLAS")) die_setup("OpenBLAS not found: the linked BLAS is not OpenBLAS");
    openblas_set_num_threads(1);
    if (openblas_get_num_threads() != 1) die_setup("could not force OpenBLAS to one thread");
    char vendor_buf[200];
    snprintf(vendor_buf, sizeof vendor_buf, "OpenBLAS (single thread; %s)", cfg);
    const char *vendor_name = vendor_buf;
#endif

    detect_cpu();
    place_process();
    if (tsv_path) {
        /* Written to <path>.tmp and renamed on success (tsv_commit); removed on every failure exit. */
        size_t tl = strlen(tsv_path) + sizeof ".tmp";
        g_tsv_final = (char *)tsv_path;
        g_tsv_tmp = (char *)malloc(tl);
        if (!g_tsv_tmp) die_setup("out of memory");
        snprintf(g_tsv_tmp, tl, "%s.tmp", tsv_path);
        atexit(tsv_cleanup);
        g_tsv = fopen(g_tsv_tmp, "w");
        if (!g_tsv) die_setup("cannot write '%s': %s", g_tsv_tmp, strerror(errno));
        fprintf(g_tsv, "target\tcpu\tkernel\tvariant\tm\tn\tk\treps\tmedian_s\tmin_s\tmax_s\tunit\tbaysick_rate\tvendor_rate\tpct_vendor\tpeak_rate\tpct_peak\n");
    }

#ifndef BENCH_VENDOR_ONLY
    bsk_kern_init();
    const char *const *vl = bsk_kern_variants();
    for (; vl && *vl && g_nvariants < MAX_VARIANTS; vl++) g_variants[g_nvariants++] = strdup(*vl);
    if (g_nvariants == 0) die_setup("_bsk_kern_variants() lists no usable variant");
#endif

    double load0[3] = {0, 0, 0}, load1[3] = {0, 0, 0};
    if (getloadavg(load0, 3) < 1) load0[0] = 0;

    char feat[128], vars[256] = "";
    list_features(feat, sizeof feat);
    for (int i = 0; i < g_nvariants; i++) {
        if (i) strncat(vars, ",", sizeof vars - strlen(vars) - 1);
        strncat(vars, g_variants[i], sizeof vars - strlen(vars) - 1);
    }
    if (!vars[0]) snprintf(vars, sizeof vars, "none (vendor only)");
    printf("# baysick bench  target=%s  cpu=\"%s\"  features=%s  variants=%s%s\n", BENCH_TARGET, g_cpu, feat, vars,
           g_quick ? "  QUICK" : "");

    if (only_has("peak") || !g_only) measure_all_peaks();
    printf("# peak:");
    for (int i = 0; i < g_npeaks; i++) printf(" %s %.1f GFLOP/s%s", g_peaks[i].name, g_peaks[i].gflops, i + 1 < g_npeaks ? "," : "");
    printf("   vendor: %s   load(before) %.2f\n", vendor_name, load0[0]);
    fflush(stdout);

    for (int k = 0; k < K_COUNT; k++)
        if (only_has(kernel_name[k])) run_kernel((kernel_id)k);
    if (e2e_dir && only_has("e2e")) run_e2e(e2e_dir);
    if (g_nvariants) report_goals();

    if (getloadavg(load1, 3) < 1) load1[0] = 0;
    printf("\n# load %.2f/%.2f\n", load0[0], load1[0]);
    if (load0[0] > 1.0 || load1[0] > 1.0) printf("# warning: 1-minute load average above 1.0; timings may be disturbed\n");
    tsv_commit();
    return 0;
}
