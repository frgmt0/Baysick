// =====================================================================
// include/runtime.inc -- the runtime ABI between compiled BASIC programs
// (emitted by a backend) and the runtime libraries (src/runtime/ for
// arm64-macos, src/runtime_x86_64_linux/ for x86_64-linux).
//
// CONTRACT FILE. Normative description: docs/DESIGN.md section 6 (6.4 for
// x86_64-linux). Shared with GNU as: see the comment rule in DESIGN.md 3.4.
//
// arm64-macos: all runtime entry points follow AAPCS64 (Darwin variant):
// arguments in x0-x7 / d0-d7, results in x0 / d0, x19-x28 and d8-d15
// preserved, x18 never touched. Symbol names below are the Mach-O names
// (leading _).
//
// x86_64-linux: the same entry points and semantics under the ELF names
// (no leading underscore: main, bsk_curline, bsk_print_num, ...) and the
// System V AMD64 ABI: d0 -> %xmm0, d1 -> %xmm1, pointer/integer argument
// x0 -> %rdi, x1 -> %rsi, x2 -> %rdx, w0 -> %edi, w1 -> %esi, pointer or
// integer result x0 -> %rax, double result d0 -> %xmm0; %rbx %rbp %r12-%r15
// preserved; %rsp 16-byte aligned at every call. The RTA_*, MV_*, KV_*
// layouts and every constant below are identical.
// =====================================================================
.ifndef BSK_RUNTIME_INC
.equ BSK_RUNTIME_INC, 1

// ---- Symbols DEFINED BY THE RUNTIME ------------------------------------------
//  _main                      process entry: init, bl _bsk_program, bl _bsk_end
//  _bsk_curline   (u32 data)  current BASIC line; compiled code stores it at each
//                             OP_LINE; used in run-time error messages
//  _bsk_print_num(d0=x)                 PRINT a number item
//  _bsk_print_str(x0=ptr, x1=len)       PRINT a string item
//  _bsk_print_comma()                   PRINT ',' (next zone)
//  _bsk_print_semi()                    PRINT ';' after a number (next multiple of 3)
//  _bsk_print_nl()                      end of PRINT without trailing separator
//  _bsk_read() -> d0                    next DATA value (OUT OF DATA ends program)
//  _bsk_div(d0=a, d1=b) -> d0           a/b with DIVISION BY ZERO / OVERFLOW checks
//  _bsk_pow(d0=a, d1=b) -> d0           a^b per LANGUAGE.md (|a|^b, 0^neg error)
//  _bsk_chk(d0=x) -> d0                 returns x, or OVERFLOW error if x not finite
//  _bsk_sin _bsk_cos _bsk_tan _bsk_atn _bsk_exp _bsk_abs _bsk_log _bsk_sqr
//  _bsk_int  (d0=x) -> d0               builtins with LANGUAGE.md semantics/checks
//  _bsk_rnd() -> d0                     next RND value
//  _bsk_aref1(x0=ArrayDesc*, d0=i) -> x0          address of element i
//  _bsk_aref2(x0=ArrayDesc*, d0=i, d1=j) -> x0    address of element (i,j)
//  _bsk_gosub_push(x0=return address)   TOO MANY GOSUBS when full
//  _bsk_gosub_pop() -> x0               return address; ILLEGAL RETURN when empty
//  _bsk_end()                           noreturn: END/STOP -> exit 0
//  _bsk_err(w0=ERR_* code)              noreturn: run-time error
//
//  MAT statements (DESIGN.md 6.5; x0/x1/x2 = RTA descriptors, LANGUAGE.md 7.14):
//  _bsk_mat_redim1(x0=desc, d0=rows)              shape rows x 1
//  _bsk_mat_redim2(x0=desc, d0=rows, d1=cols)     shape rows x cols
//  _bsk_mat_read(x0=desc)                         MAT READ, current shape
//  _bsk_mat_print(x0=desc, w1=MATPR_ZONED|MATPR_PACKED)
//  _bsk_mat_zer(x0=desc)  _bsk_mat_con(x0=desc)  _bsk_mat_idn(x0=desc)
//  _bsk_mat_copy(x0=dst, x1=src)  _bsk_mat_trn(x0=dst, x1=src)
//  _bsk_mat_inv(x0=dst, x1=src)
//  _bsk_mat_add(x0=dst, x1=a, x2=b)  _bsk_mat_sub(...)  _bsk_mat_mul(...)
//  _bsk_mat_scale(x0=dst, x1=src, d0=k)           dst = (k) * src
//
//  Matrix kernels (DESIGN.md 6.6; x0/x1/x2 = MV views; also called by bench/):
//  _bsk_kern_init()                     select the kernel variant (idempotent)
//  _bsk_kern_use(x0=name) -> x0         0 ok, -1 unknown/unsupported variant
//  _bsk_kern_name() -> x0               NUL-terminated name of the variant in use
//  _bsk_kern_variants() -> x0           NULL-terminated array of usable variant names
//  _bsk_kern_features() -> x0           detected KF_* bits
//  _bsk_kern_gemm(x0=C, x1=A, x2=B) -> x0 KS_*      C = A * B
//  _bsk_kern_add(x0=C, x1=A, x2=B) -> x0 KS_*       C = A + B
//  _bsk_kern_sub(x0=C, x1=A, x2=B) -> x0 KS_*       C = A - B
//  _bsk_kern_scale(x0=C, x1=A, d0=k) -> x0 KS_*     C = k * A
//  _bsk_kern_trn(x0=C, x1=A)                        C = transpose of A
//  _bsk_kern_copy(x0=C, x1=A)                       C = A
//  _bsk_kern_fill(x0=C, d0=v)                       every element of C = v
//  _bsk_kern_inv(x0=X, x1=A) -> x0 KS_*             X = inverse of A (pinned algorithm)

// ---- Symbols DEFINED BY EVERY COMPILED PROGRAM (backend output) ------------------
//  _bsk_program               code: the BASIC main function (AAPCS64, no args)
//  _bsk_data                  8-byte aligned array of IEEE-754 doubles (DATA values)
//  _bsk_data_count            .quad number of entries in _bsk_data (may be 0)

// ---- Array descriptor (RTA_*), 32 bytes, emitted by the backend -----------------
.equ RTA_DATA,          0   /* ptr  element storage, (b1+1)*(b2+1) doubles, zero-filled */
.equ RTA_DIMS,          8   /* u32  1 or 2 */
.equ RTA_B1,            12  /* u32  upper bound of first subscript */
.equ RTA_B2,            16  /* u32  upper bound of second subscript (0 for lists) */
.equ RTA_ROWLEN,        20  /* u32  b2+1 for tables, 1 for lists */
.equ RTA_LETTER,        24  /* u32  0..25 (diagnostics only) */
.equ RTA_CAP,           28  /* u32  capacity in elements = (b1+1)*(b2+1) of the IR bounds */
.equ RTA_SIZE,          32
// element (i,j) address = RTA_DATA + 8*(i*RTA_ROWLEN + j)   (row-major)
// RTA_B1, RTA_B2 and RTA_ROWLEN are the CURRENT shape: the backend emits the
// IR bounds; MAT redimensioning (LANGUAGE.md 7.14.3) rewrites them at run
// time (lists: B1 only; tables: B1, B2, ROWLEN = B2+1) within RTA_CAP, and
// _bsk_aref1/_bsk_aref2 check subscripts against the current values. The
// descriptor therefore lives in writable data (__DATA,__data / .data).

// ---- Matrix view (MV_*), 32 bytes: a rows x cols block of doubles ---------------
// Element (i,j), 0-based within the view, is at MV_DATA + 8*(i*MV_LD + j).
// The MAT layer builds views of BASIC matrices: a table with shape r x c is
// MV_DATA = RTA_DATA + 8*(ROWLEN+1) (element (1,1)), MV_LD = ROWLEN; a list
// with n elements is the n x 1 view MV_DATA = RTA_DATA + 8, MV_LD = 1.
.equ MV_DATA,           0   /* ptr  element (0,0) of the view */
.equ MV_ROWS,           8   /* u64  >= 1 */
.equ MV_COLS,           16  /* u64  >= 1 */
.equ MV_LD,             24  /* u64  row stride in elements, >= MV_COLS (or 1 when MV_COLS = 1) */
.equ MV_SIZE,           32

// ---- Kernel status (x0 result of _bsk_kern_gemm/add/sub/scale/inv) ----------------
.equ KS_OK,             0   /* every stored result element is finite */
.equ KS_NONFINITE,      1   /* some result element is +-inf or NaN -> OVERFLOW */
.equ KS_SINGULAR,       2   /* _bsk_kern_inv only: pivot <= tolerance -> SINGULAR MATRIX */

// ---- Detected CPU features (_bsk_kern_features, KV_REQUIRES), DESIGN.md 6.6.2 -------
.equ KF_A64_SME,        0x1     /* sysctlbyname("hw.optional.arm.FEAT_SME") == 1 */
.equ KF_A64_SME2,       0x2     /* sysctlbyname("hw.optional.arm.FEAT_SME2") == 1 */
.equ KF_A64_SME_F64F64, 0x4     /* sysctlbyname("hw.optional.arm.FEAT_SME_F64F64") == 1 */
.equ KF_X64_AVX2,       0x100   /* CPUID.(7,0):EBX[5], with OS AVX state (XCR0[2:1] = 11b) */
.equ KF_X64_FMA,        0x200   /* CPUID.1:ECX[12], with OS AVX state (XCR0[2:1] = 11b) */

// ---- Kernel variant record (KV_*), 80 bytes, DESIGN.md 6.6.3 ---------------------
// A runtime-private, read-only table of these records, best variant first,
// baseline last (KV_REQUIRES = 0). A slot a variant does not specialise
// points at the baseline function.
.equ KV_NAME,           0   /* ptr  NUL-terminated variant name ("neon", "sse2", ...) */
.equ KV_REQUIRES,       8   /* u64  KF_* bits that must all be detected */
.equ KV_GEMM,           16  /* ptr  same contract as _bsk_kern_gemm */
.equ KV_ADD,            24
.equ KV_SUB,            32
.equ KV_SCALE,          40
.equ KV_TRN,            48
.equ KV_COPY,           56
.equ KV_FILL,           64
.equ KV_INV,            72
.equ KV_SIZE,           80

// ---- PRINT layout constants --------------------------------------------------
.equ PRINT_LINE_WIDTH,  75  /* teletype line width used by the zone logic */
.equ PRINT_ZONE_WIDTH,  15  /* ',' moves to the next multiple of 15 */
.equ PRINT_PACK_WIDTH,  3   /* ';' after a number moves to the next multiple of 3 */
.equ PRINT_MIN_ROOM,    12  /* a number starts a new line if fewer than 12 columns remain */
.equ PRINT_SIG_DIGITS,  6   /* significant digits for non-integers */
.equ PRINT_INT_LIMIT,   1000000000 /* integers with |x| < 1e9 print in full */
.equ RT_OUTBUF_SIZE,    4096 /* runtime stdout buffer */

// ---- Matrix runtime sizes (DESIGN.md 6.5, 6.6) ----------------------------------
.equ RT_MAT_SCRATCH_ELEMS, 1048576 /* doubles in the MAT-layer result temporary (>= LIM_ARRAY_ELEMS) */
.equ RT_KERN_INV_MAXN,  1024        /* _bsk_kern_inv: largest n (its n x n workspace is static) */
.equ RT_INV_TOL_SHIFT,  52          /* INV tolerance = (n * 2^-52) * max|a(i,j)|, LANGUAGE.md 7.14.6 */

// ---- RND generator (Park-Miller "minimal standard") ---------------------------
.equ RNG_MULT,          16807
.equ RNG_MOD,           2147483647  /* 2^31 - 1 */
.equ RNG_SEED,          1964        /* state before the first RND call */

.endif
