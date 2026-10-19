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
// x0 -> %rdi, x1 -> %rsi, w0 -> %edi, pointer result x0 -> %rax, double
// result d0 -> %xmm0; %rbx %rbp %r12-%r15 preserved; %rsp 16-byte aligned
// at every call. The RTA_* layout and every constant below are identical.
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
.equ RTA_PAD,           28  /* u32  0 */
.equ RTA_SIZE,          32
// element (i,j) address = RTA_DATA + 8*(i*RTA_ROWLEN + j)   (row-major)

// ---- PRINT layout constants --------------------------------------------------
.equ PRINT_LINE_WIDTH,  75  /* teletype line width used by the zone logic */
.equ PRINT_ZONE_WIDTH,  15  /* ',' moves to the next multiple of 15 */
.equ PRINT_PACK_WIDTH,  3   /* ';' after a number moves to the next multiple of 3 */
.equ PRINT_MIN_ROOM,    12  /* a number starts a new line if fewer than 12 columns remain */
.equ PRINT_SIG_DIGITS,  6   /* significant digits for non-integers */
.equ PRINT_INT_LIMIT,   1000000000 /* integers with |x| < 1e9 print in full */
.equ RT_OUTBUF_SIZE,    4096 /* runtime stdout buffer */

// ---- RND generator (Park-Miller "minimal standard") ---------------------------
.equ RNG_MULT,          16807
.equ RNG_MOD,           2147483647  /* 2^31 - 1 */
.equ RNG_SEED,          1964        /* state before the first RND call */

.endif
