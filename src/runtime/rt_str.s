// =====================================================================
// src/runtime/rt_str.s -- string values (DESIGN.md 6.7, LANGUAGE.md 4.4,
// 7.1, 7.7, 7.19, 8).
//
// Defines (global, runtime.inc):
//   _bsk_str_set _bsk_str_cmp
//   _bsk_change_s2n _bsk_change_n2s _bsk_change_n2s_el
// Defines (private to the runtime, .private_extern):
//   _bsk_rt_str_reserve     make an SD own at least n bytes (OUT OF ROOM)
//   _bsk_rt_str_setbytes    SD := a copy of a byte range (INPUT, DATA)
// (_bsk_saref1 lives in rt_array.s, next to the subscript rule it shares.)
// (_bsk_print_sv lives in rt_print.s, with the pending file selection.)
//
// String descriptor (SD_*, runtime.inc): LEN bytes at PTR. CAP > 0 means
// PTR is a malloc'd buffer of CAP bytes owned by this descriptor; CAP = 0
// means PTR is not owned (string constants, string DATA, a never-assigned
// variable) and is never written. Owned buffers grow with realloc to a
// multiple of 16 bytes and are never shrunk or freed, so a program's
// string storage only ever grows to the largest value each variable or
// element has held; realloc failure is OUT OF ROOM.
// =====================================================================
.include "baysick.inc"

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _bsk_rt_str_reserve -- make dst own a buffer of at least n bytes.
//   Purpose : n <= CAP: nothing to do. Otherwise realloc(PTR if CAP > 0
//             else NULL, cap') with cap' = n rounded up to a multiple of
//             16 (at least 16 since n > CAP >= 0); NULL -> OUT OF ROOM;
//             PTR := buffer, CAP := cap'. LEN and the bytes are left
//             alone (the caller writes them).
//   Inputs  : x0 = dst SD, x1 = n (0 .. LIM_STRING_LEN)
//   Outputs : x0 = dst PTR (owned and >= n bytes when n > 0)
//   Errors  : OUT OF ROOM
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = dst, x20 = cap'
//   Frame   : 32 bytes (frame record + x19, x20)
// ---------------------------------------------------------------------
    .private_extern _bsk_rt_str_reserve
    .p2align 2
_bsk_rt_str_reserve:
    ldr w9, [x0, #SD_CAP]
    cmp x1, x9
    b.hi Lrt_str_reserve_grow       // n > CAP: a larger buffer is needed
    ldr x0, [x0, #SD_PTR]           // fits (n = 0 never needs a buffer)
    ret
Lrt_str_reserve_grow:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    add x20, x1, #15
    and x20, x20, #~15              // cap' = n rounded up to 16
    // realloc's old pointer: the owned buffer, or NULL when not owned
    // (CAP = 0: PTR may point at a constant that must not be freed).
    ldr x0, [x19, #SD_PTR]
    cmp x9, #0
    csel x0, xzr, x0, eq
    mov x1, x20
    bl _realloc
    cbz x0, Lrt_str_oom
    str x0, [x19, #SD_PTR]
    str w20, [x19, #SD_CAP]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
Lrt_str_oom:
    mov w0, #ERR_OUT_OF_ROOM
    bl _bsk_err                     // noreturn

// ---------------------------------------------------------------------
// _bsk_rt_str_setbytes -- dst := a copy of len bytes at ptr.
//   Inputs  : x0 = dst SD, x1 = ptr (may be anything when len = 0),
//             x2 = len (0 .. LIM_STRING_LEN); the bytes must not lie in
//             dst's own buffer
//   Outputs : none
//   Errors  : OUT OF ROOM
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = dst, x20 = source pointer, x21 = len
//   Frame   : 48 bytes (frame record + x19..x21, padded)
// ---------------------------------------------------------------------
    .private_extern _bsk_rt_str_setbytes
    .p2align 2
_bsk_rt_str_setbytes:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x1, x2
    bl _bsk_rt_str_reserve          // x0 = buffer with room for len
    cbz x21, 1f                     // empty: nothing to copy
    mov x1, x20
    mov x2, x21
    bl _memcpy
1:
    str w21, [x19, #SD_LEN]         // LEN := len
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// _bsk_str_set -- dst := copy of src (LET with a string, LANGUAGE.md
//   7.1): the bytes are copied, so the two stay independent.
//   Inputs  : x0 = dst SD, x1 = src SD
//   Outputs : none
//   Errors  : OUT OF ROOM
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: none
//   Frame   : none (tail call)
// ---------------------------------------------------------------------
    .globl _bsk_str_set
    .p2align 2
_bsk_str_set:
    cmp x0, x1
    b.eq 1f                         // LET A$ = A$: nothing to do
    ldr w2, [x1, #SD_LEN]
    ldr x1, [x1, #SD_PTR]
    b _bsk_rt_str_setbytes          // tail call
1:
    ret

// ---------------------------------------------------------------------
// _bsk_str_cmp -- compare two strings (IF, LANGUAGE.md 7.7).
//   Purpose : trailing spaces (0x20) of both are ignored; then the bytes
//             are compared as unsigned numbers; the first difference
//             decides; a proper prefix is smaller.
//   Inputs  : x0 = a SD, x1 = b SD
//   Outputs : w0 = -1 (a < b), 0 (equal), +1 (a > b)
//   Clobbers: x0-x5, x9-x12
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .globl _bsk_str_cmp
    .p2align 2
_bsk_str_cmp:
    ldr x2, [x0, #SD_PTR]           // a bytes
    ldr w3, [x0, #SD_LEN]           // a length
    ldr x4, [x1, #SD_PTR]           // b bytes
    ldr w5, [x1, #SD_LEN]           // b length
    // Strip the trailing blanks of a, then of b.
1:
    cbz x3, 2f
    sub x9, x3, #1
    ldrb w10, [x2, x9]
    cmp w10, #' '
    b.ne 2f
    mov x3, x9
    b 1b
2:
    cbz x5, 3f
    sub x9, x5, #1
    ldrb w10, [x4, x9]
    cmp w10, #' '
    b.ne 3f
    mov x5, x9
    b 2b
3:
    // Compare the common prefix byte by byte.
    cmp x3, x5
    csel x11, x3, x5, lo            // m = min(la, lb)
    mov x9, #0
Lrt_str_cmp_loop:
    cmp x9, x11
    b.hs Lrt_str_cmp_len            // equal prefix: lengths decide
    ldrb w10, [x2, x9]
    ldrb w12, [x4, x9]
    add x9, x9, #1
    cmp w10, w12
    b.eq Lrt_str_cmp_loop
    // First difference: unsigned byte order.
    mov w0, #1
    mov w9, #-1
    csel w0, w9, w0, lo
    ret
Lrt_str_cmp_len:
    cmp x3, x5
    cset w0, ne                     // 1 if the lengths differ
    mov w9, #-1
    csel w0, w9, w0, lo             // shorter (a prefix of the other) is smaller
    ret

// ---------------------------------------------------------------------
// Lrt_str_round -- r = floor(x + 0.5), evaluated exactly (the subscript
//   rule of rt_array.s: floor(x), plus 1 when x - floor(x) >= 0.5; the
//   difference is exact whenever it matters).
//   Inputs  : d0 = x (finite)
//   Outputs : d0 = r (an integer-valued double)
//   Clobbers: d16, d17
//   Callee-saved used: none
//   Frame   : none (leaf)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_str_round:
    frintm d17, d0                  // floor(x)
    fsub d0, d0, d17                // fractional part
    fmov d16, #0.5
    fcmp d0, d16
    fmov d0, d17                    // (fmov keeps the flags)
    b.lt 1f
    fmov d16, #1.0
    fadd d0, d0, d16                // fraction >= 0.5: round up
1:
    ret

// ---------------------------------------------------------------------
// _bsk_change_s2n -- CHANGE string TO list (LANGUAGE.md 7.19).
//   Purpose : n = length of the string; n > the list's current bound ->
//             SUBSCRIPT ERROR; else L(0) = n and L(i) = code of byte i
//             (0..255), i = 1..n; later elements are not changed.
//   Inputs  : x0 = numeric list descriptor (RTA_*), x1 = source SD
//   Outputs : none
//   Errors  : SUBSCRIPT ERROR
//   Clobbers: x0, x9-x13, d0
//   Callee-saved used: none
//   Frame   : none (leaf; the error exit is a branch)
// ---------------------------------------------------------------------
    .globl _bsk_change_s2n
    .p2align 2
_bsk_change_s2n:
    ldr w9, [x1, #SD_LEN]           // n
    ldr w10, [x0, #RTA_B1]          // current bound
    cmp x9, x10
    b.hi Lrt_str_subscript          // the list cannot hold the codes
    ldr x11, [x0, #RTA_DATA]        // &L(0) (a list: element i at 8*i)
    ldr x12, [x1, #SD_PTR]
    ucvtf d0, x9
    str d0, [x11], #8               // L(0) = n
    cbz x9, 2f
1:
    ldrb w13, [x12], #1             // byte i
    ucvtf d0, w13                   // its code, exact
    str d0, [x11], #8               // L(i)
    subs x9, x9, #1
    b.ne 1b
2:
    ret

Lrt_str_subscript:
    mov w0, #ERR_SUBSCRIPT
    b _bsk_err

// ---------------------------------------------------------------------
// _bsk_change_n2s -- CHANGE list TO string (LANGUAGE.md 7.19).
//   Purpose : n = floor(L(0) + 0.5): n < 0 or n > the list's current
//             bound -> SUBSCRIPT ERROR; n > LIM_STRING_LEN -> STRING TOO
//             LONG; every code c = floor(L(i) + 0.5), i = 1..n, must be
//             0..LIM_CHAR_CODE, else ILLEGAL CHARACTER; only then is the
//             string of those n bytes assigned to dst (OUT OF ROOM).
//   Inputs  : x0 = destination SD, x1 = numeric list descriptor
//   Outputs : none
//   Errors  : SUBSCRIPT ERROR, STRING TOO LONG, ILLEGAL CHARACTER,
//             OUT OF ROOM
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: see Lrt_str_n2s
//   Frame   : none (branch to Lrt_str_n2s)
// ---------------------------------------------------------------------
    .globl _bsk_change_n2s
    .p2align 2
_bsk_change_n2s:
    mov w2, #0                      // x0 is the destination itself
    b Lrt_str_n2s

// ---------------------------------------------------------------------
// _bsk_change_n2s_el -- CHANGE list TO L$(i) (the element form of
//   `chgn2s`, IR.md 3.2): the conversion and all its checks as
//   _bsk_change_n2s first; then the subscript is checked at the store
//   (_bsk_saref1, LANGUAGE.md 7.1, 7.19); then the element is assigned.
//   Inputs  : x0 = string-list descriptor (RTA_*), d0 = subscript i,
//             x1 = numeric list descriptor
//   Outputs : none
//   Errors  : SUBSCRIPT ERROR (length), STRING TOO LONG, ILLEGAL
//             CHARACTER; then SUBSCRIPT ERROR (i); OUT OF ROOM
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: see Lrt_str_n2s
//   Frame   : none (branch to Lrt_str_n2s)
// ---------------------------------------------------------------------
    .globl _bsk_change_n2s_el
    .p2align 2
_bsk_change_n2s_el:
    mov w2, #1                      // x0 is a string list, d0 = i
    b Lrt_str_n2s

// ---------------------------------------------------------------------
// Lrt_str_n2s -- the body of _bsk_change_n2s / _bsk_change_n2s_el.
//   Inputs  : x0 = destination SD (w2 = 0) or string-list descriptor
//             (w2 = 1, d0 = subscript), x1 = numeric list descriptor
//   Outputs : none
//   Errors  : as _bsk_change_n2s_el
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = dst (or the string list until the store),
//             x20 = &L(1), x21 = n, x22 = loop index, x23 = w2,
//             d8 = subscript
//   Frame   : 64 bytes (frame record + x19..x23 + d8)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_str_n2s:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]
    str d8, [sp, #56]
    mov x19, x0
    mov w23, w2
    fmov d8, d0
    ldr x20, [x1, #RTA_DATA]
    ldr d0, [x20], #8               // L(0); x20 = &L(1)
    bl Lrt_str_round                // n as a double
    fcmp d0, #0.0
    b.lt Lrt_str_subscript          // n < 0
    ldr w9, [x1, #RTA_B1]
    ucvtf d1, w9
    fcmp d0, d1
    b.gt Lrt_str_subscript          // n > current bound
    mov w9, #LIM_STRING_LEN
    ucvtf d1, w9
    fcmp d0, d1
    b.gt Lrt_str_toolong            // more bytes than a string may hold
    fcvtzu x21, d0                  // 0 <= n <= 65536: exact
    // Pass 1: every code must be a byte before anything is assigned.
    mov w9, #LIM_CHAR_CODE
    ucvtf d2, w9
    mov x22, #0
Lrt_str_n2s_check:
    cmp x22, x21
    b.hs Lrt_str_n2s_store
    ldr d0, [x20, x22, lsl #3]
    bl Lrt_str_round                // c (leaf: d2 survives)
    fcmp d0, #0.0
    b.lt Lrt_str_badchar
    fcmp d0, d2
    b.gt Lrt_str_badchar
    add x22, x22, #1
    b Lrt_str_n2s_check
Lrt_str_n2s_store:
    // A string list element: its subscript is checked now, at the
    // store, after the conversion's own checks (LANGUAGE.md 7.19).
    cbz w23, 3f
    mov x0, x19
    fmov d0, d8
    bl _bsk_saref1                  // x0 = &L$(i); SUBSCRIPT ERROR here
    mov x19, x0
3:
    // Pass 2: make room, then write the bytes.
    mov x0, x19
    mov x1, x21
    bl _bsk_rt_str_reserve          // x0 = buffer (n bytes)
    mov x22, #0
1:
    cmp x22, x21
    b.hs 2f
    ldr d0, [x20, x22, lsl #3]
    bl Lrt_str_round
    fcvtzu w9, d0                   // 0..255, exact
    strb w9, [x0, x22]
    add x22, x22, #1
    b 1b
2:
    str w21, [x19, #SD_LEN]         // LEN := n
    ldr d8, [sp, #56]
    ldr x23, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

Lrt_str_toolong:
    mov w0, #ERR_STRING_TOO_LONG
    b _bsk_err
Lrt_str_badchar:
    mov w0, #ERR_ILLEGAL_CHARACTER
    b _bsk_err
