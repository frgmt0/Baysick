// =====================================================================
// src/runtime/rt_ed6.s -- the Sixth Edition string operations: the
// concatenation operator `&` and the functions SEG$ and POS (DESIGN.md
// 6.9, LANGUAGE.md 4.6, 6.2).
//
// Defines (global, runtime.inc):
//   _bsk_str_cat _bsk_seg _bsk_pos
// Uses: _bsk_rt_str_setbytes (rt_str.s), _malloc, _realloc, _memcpy,
// _bsk_err.
//
// Position arguments are rounded like subscripts: r = floor(x + 0.5),
// evaluated exactly as in _bsk_aref1 (rt_array.s): r = floor(x), plus 1
// if x - floor(x) >= 0.5 (the IEEE sum x + 0.5 can round up and is not
// used). Every later comparison is done on the rounded doubles, so huge
// or negative positions never wrap; a position is converted to an
// integer only once it is known to lie in 1 .. LIM_STRING_LEN + 1.
// The max(r, 1) / min(r, L) clamps use fmaxnm / fminnm, so a NaN
// position (never produced by a BASIC expression: every arithmetic
// result is checked for OVERFLOW) acts as "no bound": SEG$ start 1,
// SEG$ end L, POS start 1.
// =====================================================================
.include "baysick.inc"

// RT_ED6_ROUND dreg: dreg := floor(dreg + 0.5), exactly (see above and
// the RT_SUBSCRIPT macro of rt_array.s for the proof).
// Clobbers dreg, d16, d17.
.macro RT_ED6_ROUND dreg
    frintm d17, \dreg               // r = floor(x)
    fsub \dreg, \dreg, d17          // f = x - r, in [0, 1)
    fmov d16, #0.5
    fcmp \dreg, d16
    fmov \dreg, d17                 // dreg = r (fmov keeps the flags)
    b.lt 1f                         // f < 0.5 (or NaN): r = floor(x)
    fmov d16, #1.0
    fadd \dreg, \dreg, d16          // f >= 0.5: r = floor(x) + 1
1:
.endm

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _bsk_str_cat -- dst := dst & src (LANGUAGE.md 4.6, DESIGN.md 6.9).
//   Purpose : Ld = dst LEN and Ls = src LEN are read first (src may be
//             dst); n = Ld + Ls; n > LIM_STRING_LEN -> STRING TOO LONG
//             with dst unchanged. If n > CAP the buffer grows to
//             cap' = max(n, 2 CAP) rounded up to a multiple of 16:
//             CAP > 0: realloc(PTR, cap'); CAP = 0 (PTR not owned):
//             malloc(cap') and the Ld old bytes copied into it; NULL ->
//             OUT OF ROOM. Then the Ls source bytes (read through src's
//             PTR after the growth, so src = dst reads the new buffer)
//             are copied to PTR + Ld, and LEN := n.
//   Inputs  : x0 = dst SD, x1 = src SD
//   Outputs : none
//   Errors  : STRING TOO LONG, OUT OF ROOM
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = dst, x20 = src, x21 = Ld, x22 = Ls,
//             x23 = n, x24 = cap'
//   Frame   : 64 bytes (frame record + x19..x24)
// ---------------------------------------------------------------------
    .globl _bsk_str_cat
    .p2align 2
_bsk_str_cat:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    mov x19, x0
    mov x20, x1
    // Both lengths before anything changes (src may be dst).
    ldr w21, [x19, #SD_LEN]         // Ld (zero-extended)
    ldr w22, [x20, #SD_LEN]         // Ls
    add x23, x21, x22               // n = Ld + Ls (no u32 overflow: <= 2^17)
    mov x9, #LIM_STRING_LEN
    cmp x23, x9
    b.hi Lrt_ed6_cat_long           // too long: dst unchanged
    // Room: n <= CAP keeps the buffer (n = 0 always fits).
    ldr w9, [x19, #SD_CAP]
    cmp x23, x9
    b.ls Lrt_ed6_cat_copy
    // cap' = max(n, 2 CAP), rounded up to a multiple of 16.
    lsl x10, x9, #1
    cmp x23, x10
    csel x24, x23, x10, hi
    add x24, x24, #15
    and x24, x24, #~15
    cbz w9, Lrt_ed6_cat_fresh
    // Owned buffer: realloc keeps the Ld bytes.
    ldr x0, [x19, #SD_PTR]
    mov x1, x24
    bl _realloc
    cbz x0, Lrt_ed6_cat_oom
    b Lrt_ed6_cat_set
Lrt_ed6_cat_fresh:
    // PTR not owned (a constant, DATA or nothing): a new buffer, then
    // the Ld bytes of the old value copied into it.
    mov x0, x24
    bl _malloc
    cbz x0, Lrt_ed6_cat_oom
    cbz x21, Lrt_ed6_cat_set        // empty old value: nothing to copy
    ldr x1, [x19, #SD_PTR]
    mov x2, x21
    bl _memcpy                      // returns the new buffer in x0
Lrt_ed6_cat_set:
    str x0, [x19, #SD_PTR]          // PTR := the owned buffer
    str w24, [x19, #SD_CAP]         // CAP := cap'
Lrt_ed6_cat_copy:
    // Append the Ls source bytes; src's PTR is read now, so src = dst
    // uses the (possibly moved) buffer. [0, Ld) and [Ld, n) never overlap.
    cbz x22, Lrt_ed6_cat_len
    ldr x0, [x19, #SD_PTR]
    add x0, x0, x21                 // PTR + Ld
    ldr x1, [x20, #SD_PTR]
    mov x2, x22
    bl _memcpy
Lrt_ed6_cat_len:
    str w23, [x19, #SD_LEN]         // LEN := n
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret
Lrt_ed6_cat_long:
    mov w0, #ERR_STRING_TOO_LONG
    bl _bsk_err                     // noreturn
Lrt_ed6_cat_oom:
    mov w0, #ERR_OUT_OF_ROOM
    bl _bsk_err                     // noreturn

// ---------------------------------------------------------------------
// _bsk_seg -- dst := SEG$(src, m, n) (LANGUAGE.md 6.2, DESIGN.md 6.9).
//   Purpose : m', n' = rounded m, n; L = src LEN; first = max(m', 1),
//             last = min(n', L); first > last -> dst := "" (LEN 0, the
//             buffer kept); else dst := a copy of bytes first .. last
//             (1-based) of src, as _bsk_str_set does.
//   Inputs  : x0 = dst SD (a string temp cell, never src), x1 = src SD,
//             d0 = m, d1 = n
//   Outputs : none
//   Errors  : OUT OF ROOM
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : none (tail call to _bsk_rt_str_setbytes)
// ---------------------------------------------------------------------
    .globl _bsk_seg
    .p2align 2
_bsk_seg:
    RT_ED6_ROUND d0                 // m'
    RT_ED6_ROUND d1                 // n'
    fmov d2, #1.0
    fmaxnm d0, d0, d2               // first = max(m', 1)
    ldr w9, [x1, #SD_LEN]
    ucvtf d3, w9                    // L, exact
    fminnm d1, d1, d3               // last = min(n', L)
    fcmp d0, d1
    b.gt Lrt_ed6_seg_empty          // first > last: the empty string
    // Here 1 <= first <= last <= L: both convert exactly.
    fcvtzu x10, d0                  // first
    fcvtzu x11, d1                  // last
    sub x2, x11, x10
    add x2, x2, #1                  // len = last - first + 1
    ldr x9, [x1, #SD_PTR]
    add x1, x9, x10
    sub x1, x1, #1                  // src PTR + first - 1
    b _bsk_rt_str_setbytes          // dst := those bytes (tail call)
Lrt_ed6_seg_empty:
    str wzr, [x0, #SD_LEN]          // LEN := 0, PTR and CAP kept
    ret

// ---------------------------------------------------------------------
// _bsk_pos -- POS(a, b, start) (LANGUAGE.md 6.2, DESIGN.md 6.9).
//   Purpose : s' = rounded start, p0 = max(s', 1); L = a LEN, K = b LEN;
//             the smallest p with p0 <= p <= L - K + 1 whose K bytes at
//             position p of a equal b's bytes (exact unsigned bytes; an
//             empty b matches at every p), else 0. No error.
//   Inputs  : x0 = a SD, x1 = b SD, d0 = start
//   Outputs : d0 = position (exact integer) or 0
//   Clobbers: x0-x2, x9-x15, d0-d3, d16, d17
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .globl _bsk_pos
    .p2align 2
_bsk_pos:
    RT_ED6_ROUND d0                 // s'
    fmov d2, #1.0
    fmaxnm d0, d0, d2               // p0 = max(s', 1)
    ldr w9, [x0, #SD_LEN]           // L
    ldr w10, [x1, #SD_LEN]          // K
    sub x11, x9, x10
    add x11, x11, #1                // last start = L - K + 1 (may be <= 0)
    scvtf d3, x11                   // exact (|value| <= 2^17)
    fcmp d0, d3
    b.gt Lrt_ed6_pos_none           // p0 beyond the last start: no match
    fcvtzu x12, d0                  // p = p0, 1 <= p <= L - K + 1
    cbz x10, Lrt_ed6_pos_found      // empty b matches at p0
    ldr x13, [x0, #SD_PTR]          // a bytes
    ldr x14, [x1, #SD_PTR]          // b bytes
    ldrb w15, [x14]                 // b's first byte, the quick test
Lrt_ed6_pos_try:
    // Compare the K bytes of a at position p (a + p - 1) with b.
    add x9, x13, x12
    sub x9, x9, #1                  // x9 = a + p - 1
    ldrb w0, [x9]
    cmp w0, w15
    b.ne Lrt_ed6_pos_next           // first byte differs
    mov x0, #1                      // byte index within b
Lrt_ed6_pos_cmp:
    cmp x0, x10
    b.hs Lrt_ed6_pos_found          // all K bytes equal
    ldrb w1, [x9, x0]
    ldrb w2, [x14, x0]
    cmp w1, w2
    b.ne Lrt_ed6_pos_next
    add x0, x0, #1
    b Lrt_ed6_pos_cmp
Lrt_ed6_pos_next:
    add x12, x12, #1                // next start position
    cmp x12, x11
    b.le Lrt_ed6_pos_try            // while p <= L - K + 1
Lrt_ed6_pos_none:
    movi d0, #0                     // no match: 0
    ret
Lrt_ed6_pos_found:
    ucvtf d0, x12                   // the position, exact
    ret
