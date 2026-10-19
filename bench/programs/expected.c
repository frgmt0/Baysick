/*
 * expected.c -- derives the expected stdout of the e2e_*.bas programs (bench/programs)
 * independently of the compiler.
 *
 * The programs use only integer arithmetic that is exact in doubles (and an inverse whose
 * residual check is far from its threshold), so their outputs follow from LANGUAGE.md alone:
 * this file replays the BASIC arithmetic in C (long long) and formats the numbers by the
 * LANGUAGE.md section 9 and 8 rules (integer fields: sign or space, digits; zoned items start
 * at the next multiple of 15 and packed items at the next multiple of 3, strictly right of the
 * position after the field's trailing space; the last trailing space is never printed).
 *
 * usage: cc -O2 -o expected bench/programs/expected.c && ./expected NAME > bench/programs/NAME.out
 *        NAME is e2e_gemm, e2e_inv or e2e_mixed.
 */
#include <stdio.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

static int col; /* current print column */

static void out_str(const char *s) {
    fputs(s, stdout);
    col += (int)strlen(s);
}

static void to_col(int c) {
    while (col < c) { putchar(' '); col++; }
}

/* number field: sign-or-space, digits; the trailing space is accounted in col+1 only when
   something follows, so it is modelled by pending_space. */
static int pending_space;

static void flush_space(void) {
    if (pending_space) { putchar(' '); col++; pending_space = 0; }
}

static void out_num(long long v) {
    char b[32];
    flush_space();
    snprintf(b, sizeof b, "%c%lld", v < 0 ? '-' : ' ', v < 0 ? -v : v);
    fputs(b, stdout);
    col += (int)strlen(b);
    pending_space = 1;
}

static void zone(void) { /* ',' : next multiple of 15 strictly right of the cursor */
    int cur = col + pending_space;
    int next = (cur / 15 + 1) * 15;
    flush_space();
    to_col(next);
}

static void pack(void) { /* ';' after a number: next multiple of 3 strictly right */
    int cur = col + pending_space;
    int next = (cur / 3 + 1) * 3;
    flush_space();
    to_col(next);
}

static void nl(void) { pending_space = 0; putchar('\n'); col = 0; }

static long long modfloor(long long t, long long m) { return t - m * (t / m); }

static void gemm(void) {
    enum { N = 400 };
    static long long A[N + 1][N + 1], B[N + 1][N + 1], C[N + 1][N + 1];
    for (int i = 1; i <= N; i++)
        for (int j = 1; j <= N; j++) {
            A[i][j] = modfloor((long long)i * j, 9) - 4;
            B[i][j] = modfloor(i + 2LL * j, 7) - 3;
        }
    for (int i = 1; i <= N; i++)
        for (int j = 1; j <= N; j++) {
            long long s = 0;
            for (int k = 1; k <= N; k++) s += A[i][k] * B[k][j];
            C[i][j] = s;
        }
    long long s1 = 0;
    for (int i = 1; i <= N; i++) {
        for (int j = 1; j <= N; j++) s1 += C[i][j] * (i + 2LL * j);
        s1 = s1 - 1000003LL * (s1 / 1000003LL); /* INT chops toward zero */
    }
    out_str("PRODUCT 400 X 400"); nl();
    out_str("CHECKSUM"); zone(); out_num(s1); nl();
    out_str("CORNERS"); zone();
    out_num(C[1][1]); pack(); out_num(C[1][N]); pack();
    out_num(C[N][1]); pack(); out_num(C[N][N]); nl();
}

static void inv(void) {
    /* the program prints the number of elements of A*INV(A) off the identity by more than
       1E-9; for this matrix (diagonal 1000 + small integers, off-diagonal row sums <= 897) the
       inverse is accurate to about 1E-13, so the count is 0. Verified here with a double
       Gauss-Jordan elimination, so a wrong premise would be reported, not printed. */
    enum { N = 300 };
    static double W[N][N], X[N][N], A[N][N];
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++) {
            A[i][j] = (double)(modfloor((long long)(i + 1) * (j + 1), 7) - 3) + (i == j ? 1000 : 0);
            W[i][j] = A[i][j];
            X[i][j] = i == j;
        }
    for (int p = 0; p < N; p++) {
        int r = p;
        for (int i = p + 1; i < N; i++)
            if (fabs(W[i][p]) > fabs(W[r][p])) r = i;
        if (r != p)
            for (int j = 0; j < N; j++) {
                double t = W[p][j]; W[p][j] = W[r][j]; W[r][j] = t;
                t = X[p][j]; X[p][j] = X[r][j]; X[r][j] = t;
            }
        double d = W[p][p];
        for (int j = 0; j < N; j++) { W[p][j] /= d; X[p][j] /= d; }
        for (int i = 0; i < N; i++) {
            if (i == p) continue;
            double f = W[i][p];
            for (int j = 0; j < N; j++) { W[i][j] -= f * W[p][j]; X[i][j] -= f * X[p][j]; }
        }
    }
    long long bad = 0;
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++) {
            double s = 0;
            for (int k = 0; k < N; k++) s += A[i][k] * X[k][j];
            if (i == j) s -= 1;
            if (!(s <= 1e-9 && s >= -1e-9)) bad++;
        }
    if (bad != 0) {
        fprintf(stderr, "expected.c: premise broken: %lld elements off the identity\n", bad);
        exit(1);
    }
    out_str("INVERSE 300 X 300"); nl();
    out_str("OFF IDENTITY"); zone(); out_num(bad); nl();
}

static void mixed(void) {
    long long A[4][5] = {{0}}, B[4][5] = {{0}}, C[4][5], T[5][4], D[5][5];
    const long long da[12] = {1, -2, 3, 4, 5, 6, -7, 8, 9, 10, 11, -12};
    const long long db[12] = {2, 0, -1, 3, -4, 5, 1, 2, 6, -3, 2, 1};
    for (int i = 1; i <= 3; i++)
        for (int j = 1; j <= 4; j++) {
            A[i][j] = da[(i - 1) * 4 + j - 1];
            B[i][j] = db[(i - 1) * 4 + j - 1];
            C[i][j] = 3 * ((A[i][j] + B[i][j]) - A[i][j]);
            T[j][i] = C[i][j];
        }
    for (int i = 1; i <= 4; i++)
        for (int j = 1; j <= 4; j++) {
            long long s = 0;
            for (int k = 1; k <= 3; k++) s += T[i][k] * C[k][j];
            D[i][j] = s;
        }
    for (int j = 1; j <= 4; j++) {
        long long s = D[1][j] + D[2][j] + D[3][j] + D[4][j];
        if (j > 1) zone();
        out_num(s);
    }
    nl();
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: expected e2e_gemm|e2e_inv|e2e_mixed\n"); return 2; }
    if (!strcmp(argv[1], "e2e_gemm")) gemm();
    else if (!strcmp(argv[1], "e2e_inv")) inv();
    else if (!strcmp(argv[1], "e2e_mixed")) mixed();
    else { fprintf(stderr, "expected: unknown program '%s'\n", argv[1]); return 2; }
    return 0;
}
