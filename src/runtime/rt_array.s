// =====================================================================
// src/runtime/rt_array.s -- array element addressing with bounds checks.
//
// Defines: _bsk_aref1 _bsk_aref2   (DESIGN.md section 6.2)
//          _bsk_saref1             (string lists, DESIGN.md section 6.7;
//                                   here to share the subscript macro)
// A subscript s is converted to r = floor(s + 0.5) (LANGUAGE.md 7.11),
// evaluated exactly: r = floor(s), plus 1 if s - floor(s) >= 0.5. The
// IEEE sum s + 0.5 is NOT used: it can round up (s = 0.5 - 2^-54 gives
// 1.0), which would make r one too large.
// 0 <= r <= bound is checked on the rounded double before conversion to
// an integer, so huge or negative subscripts can never wrap.
// Element (i, j) is at RTA_DATA + 8 * (i * RTA_ROWLEN + j).
// =====================================================================
.include "baysick.inc"

// RT_SUBSCRIPT dreg, boundoff, xout: round the subscript in dreg, check
// it against the u32 bound at [x0 + boundoff], leave the integer in
// xout. Error branch: SUBSCRIPT ERROR (no return).
// Rounding: f = s - floor(s) is computed exactly whenever it matters
// (s >= 0: f is a multiple of ulp(s) below 1; s in [-1, -0.5]: Sterbenz;
// s in (-0.5, 0): the true f exceeds 0.5 and rounding is monotonic;
// s < -1: f is a multiple of ulp(s) below 1), so "f >= 0.5" decides
// floor(s + 0.5) exactly. NaN: f is NaN, the compare is unordered, r
// stays NaN and fails the r < 0 test below; +-Inf: r = +-Inf, f = NaN,
// r fails a range test. So NaN, infinite, huge and negative subscripts
// are rejected before any conversion and can never wrap.
// Clobbers dreg, d16, d17, w9.
.macro RT_SUBSCRIPT dreg, boundoff, xout
    frintm d17, \dreg               // r = floor(s)
    fsub \dreg, \dreg, d17          // f = s - r, in [0, 1)
    fmov d16, #0.5
    fcmp \dreg, d16
    fmov \dreg, d17                 // dreg = r (fmov keeps the flags)
    b.lt 1f                         // f < 0.5 (or NaN): r stays floor(s)
    fmov d16, #1.0
    fadd \dreg, \dreg, d16          // f >= 0.5: r = floor(s) + 1
1:
    fcmp \dreg, #0.0
    b.lt Lrt_array_bad              // r < 0
    ldr w9, [x0, #\boundoff]
    ucvtf d17, w9                   // bound as a double (exact)
    fcmp \dreg, d17
    b.gt Lrt_array_bad              // r > bound
    fcvtzu \xout, \dreg             // 0 <= r <= bound: exact
.endm

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _bsk_aref1 -- address of list element L(i).
//   Inputs  : x0 = array descriptor (RTA_*), d0 = subscript i
//   Outputs : x0 = address of the element
//   Errors  : SUBSCRIPT ERROR if the rounded subscript is outside 0..B1
//   Clobbers: x9-x11, d0, d16, d17
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .globl _bsk_aref1
    .p2align 2
_bsk_aref1:
    RT_SUBSCRIPT d0, RTA_B1, x10
    ldr w11, [x0, #RTA_ROWLEN]      // 1 for lists
    mul x10, x10, x11               // i * rowlen
    ldr x9, [x0, #RTA_DATA]
    add x0, x9, x10, lsl #3         // data + 8 * index
    ret

// ---------------------------------------------------------------------
// _bsk_aref2 -- address of table element T(i, j).
//   Inputs  : x0 = array descriptor, d0 = subscript i, d1 = subscript j
//   Outputs : x0 = address of the element
//   Errors  : SUBSCRIPT ERROR if i is outside 0..B1 or j outside 0..B2
//   Clobbers: x9-x12, d0, d1, d16, d17
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .globl _bsk_aref2
    .p2align 2
_bsk_aref2:
    RT_SUBSCRIPT d0, RTA_B1, x10    // row
    RT_SUBSCRIPT d1, RTA_B2, x12    // column
    ldr w11, [x0, #RTA_ROWLEN]
    madd x10, x10, x11, x12         // i * rowlen + j
    ldr x9, [x0, #RTA_DATA]
    add x0, x9, x10, lsl #3
    ret

// ---------------------------------------------------------------------
// _bsk_saref1 -- address of string list element L$(i) (DESIGN.md 6.7).
//   Purpose : the subscript rule of _bsk_aref1 against the current
//             RTA_B1; a string list stores SD_SIZE-byte records.
//   Inputs  : x0 = string-list descriptor (RTA_*), d0 = subscript i
//   Outputs : x0 = address of the element's SD record
//   Errors  : SUBSCRIPT ERROR if the rounded subscript is outside 0..B1
//   Clobbers: x9, x10, d0, d16, d17
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .globl _bsk_saref1
    .p2align 2
_bsk_saref1:
    RT_SUBSCRIPT d0, RTA_B1, x10
    ldr x9, [x0, #RTA_DATA]
    add x0, x9, x10, lsl #4         // data + SD_SIZE * index
    ret
.if SD_SIZE != 16
    .error "rt_array: _bsk_saref1 assumes SD_SIZE == 16"
.endif

// Shared error exit for all three functions.
Lrt_array_bad:
    mov w0, #ERR_SUBSCRIPT
    b _bsk_err
