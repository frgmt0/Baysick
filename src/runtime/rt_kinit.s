// =====================================================================
// src/runtime/rt_kinit.s -- matrix kernel dispatch (DESIGN.md 6.6).
//
// Defines (global, runtime.inc):
//   _bsk_kern_init _bsk_kern_use _bsk_kern_name _bsk_kern_variants
//   _bsk_kern_features
//   _bsk_kern_gemm _bsk_kern_add _bsk_kern_sub _bsk_kern_scale
//   _bsk_kern_trn _bsk_kern_copy _bsk_kern_fill _bsk_kern_inv
//                                    (trampolines into the current variant)
//
// The variant table (KV_* records, best first, baseline last) is the only
// registration point for kernel variants (DESIGN.md 6.6.3, 6.6.7). It
// currently holds the `neon` baseline (rt_kneon_*.s).
//
// Link isolation (DESIGN.md 6.6.1): this file references only the kernel
// files (rt_kneon_*.s) and libc (_sysctlbyname, _getenv, _strcmp), so the
// benchmark harness can link libbaysickrt.a with its own main.
//
// The current-variant pointer is statically initialised to the baseline
// record, so the trampolines are usable even before _bsk_kern_init.
// =====================================================================
.include "baysick.inc"

.equ RT_KV_COUNT, 1                 // records in Lrt_kinit_table

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// Lrt_kinit_sysctl_flag -- read one boolean CPU-feature sysctl key.
//   Purpose : sysctlbyname(name, &v, &len, NULL, 0) with a 32-bit v;
//             the feature is present iff the call returns 0 and v == 1.
//             A missing key or a failing call means "absent".
//   Inputs  : x0 = NUL-terminated key name
//   Outputs : w0 = 1 if present, else 0
//   Clobbers: x0-x17, d0-d7, d16-d31 (calls libc)
//   Callee-saved used: none
//   Frame   : 32 bytes (frame record + v at [sp,#16] + len at [sp,#24])
// ---------------------------------------------------------------------
    .p2align 2
Lrt_kinit_sysctl_flag:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str wzr, [sp, #16]              // v = 0 (stays 0 if the call fails)
    mov x9, #4
    str x9, [sp, #24]               // len = sizeof(v)
    add x1, sp, #16                 // &v
    add x2, sp, #24                 // &len
    mov x3, #0                      // newp = NULL
    mov x4, #0                      // newlen = 0
    bl _sysctlbyname
    cbnz w0, 1f                     // call failed: absent
    ldr w9, [sp, #16]
    cmp w9, #1
    cset w0, eq                     // present iff v == 1
    b 2f
1:
    mov w0, #0
2:
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lrt_kinit_find -- look a variant up by name among the usable records.
//   Purpose : "baseline" -> the last record; otherwise the record whose
//             KV_NAME equals the name and whose KV_REQUIRES bits are all
//             detected.
//   Inputs  : x0 = NUL-terminated name
//   Outputs : x0 = record address, or 0 if unknown / not usable
//   Clobbers: x0-x17, d0-d7, d16-d31 (calls _strcmp)
//   Callee-saved used: x19 = name, x20 = record cursor, x21 = records
//             left, x22 = detected features
//   Frame   : 48 bytes (frame record + x19..x22)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_kinit_find:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov x19, x0
    // "baseline" names the last record (always usable: KV_REQUIRES = 0).
    adrp x1, Lrt_kinit_s_baseline@PAGE
    add x1, x1, Lrt_kinit_s_baseline@PAGEOFF
    bl _strcmp
    cbnz w0, Lrt_kinit_find_scan
    adrp x0, Lrt_kinit_table@PAGE
    add x0, x0, Lrt_kinit_table@PAGEOFF
    add x0, x0, #((RT_KV_COUNT - 1) * KV_SIZE)
    b Lrt_kinit_find_done
Lrt_kinit_find_scan:
    adrp x20, Lrt_kinit_table@PAGE
    add x20, x20, Lrt_kinit_table@PAGEOFF
    mov x21, #RT_KV_COUNT
    adrp x9, Lrt_kinit_features@PAGE
    ldr x22, [x9, Lrt_kinit_features@PAGEOFF]
Lrt_kinit_find_loop:
    cbz x21, Lrt_kinit_find_none
    ldr x9, [x20, #KV_REQUIRES]
    bics xzr, x9, x22               // required bits not detected?
    b.ne Lrt_kinit_find_next        // record not usable on this CPU
    ldr x1, [x20, #KV_NAME]
    mov x0, x19
    bl _strcmp
    cbz w0, Lrt_kinit_find_hit
Lrt_kinit_find_next:
    add x20, x20, #KV_SIZE
    sub x21, x21, #1
    b Lrt_kinit_find_loop
Lrt_kinit_find_hit:
    mov x0, x20
    b Lrt_kinit_find_done
Lrt_kinit_find_none:
    mov x0, #0
Lrt_kinit_find_done:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// _bsk_kern_init -- detect CPU features and select the kernel variant.
//   Purpose : (idempotent: only the first call does anything)
//             1. KF_* bits from sysctlbyname (DESIGN.md 6.6.2);
//             2. the NULL-terminated list of usable variant names, in
//                table order (_bsk_kern_variants);
//             3. BAYSICK_KERNELS: unset, empty or "auto" -> first usable
//                record; "baseline" -> last record; a usable name -> that
//                record; anything else -> as "auto" (silently).
//   Inputs  : none
//   Outputs : none
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = feature bits / record cursor, x20 = records
//             left, x21 = next slot of the names array, x22 = first usable
//             record
//   Frame   : 48 bytes (frame record + x19..x22)
// ---------------------------------------------------------------------
    .globl _bsk_kern_init
    .p2align 2
_bsk_kern_init:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    adrp x9, Lrt_kinit_done@PAGE
    ldr w10, [x9, Lrt_kinit_done@PAGEOFF]
    cbnz w10, Lrt_kinit_init_ret    // already initialised
    mov w10, #1
    str w10, [x9, Lrt_kinit_done@PAGEOFF]

    // 1. Feature detection.
    mov x19, #0
    adrp x0, Lrt_kinit_s_sme@PAGE
    add x0, x0, Lrt_kinit_s_sme@PAGEOFF
    bl Lrt_kinit_sysctl_flag
    cbz w0, 1f
    orr x19, x19, #KF_A64_SME
1:
    adrp x0, Lrt_kinit_s_sme2@PAGE
    add x0, x0, Lrt_kinit_s_sme2@PAGEOFF
    bl Lrt_kinit_sysctl_flag
    cbz w0, 1f
    orr x19, x19, #KF_A64_SME2
1:
    adrp x0, Lrt_kinit_s_f64@PAGE
    add x0, x0, Lrt_kinit_s_f64@PAGEOFF
    bl Lrt_kinit_sysctl_flag
    cbz w0, 1f
    orr x19, x19, #KF_A64_SME_F64F64
1:
    adrp x9, Lrt_kinit_features@PAGE
    str x19, [x9, Lrt_kinit_features@PAGEOFF]

    // 2. Usable names, in table order; remember the first usable record.
    adrp x21, Lrt_kinit_names@PAGE
    add x21, x21, Lrt_kinit_names@PAGEOFF
    adrp x9, Lrt_kinit_table@PAGE
    add x9, x9, Lrt_kinit_table@PAGEOFF
    mov x20, #RT_KV_COUNT
    mov x22, #0
    mov x10, x19                    // detected bits
    mov x19, x9                     // record cursor
Lrt_kinit_init_scan:
    cbz x20, Lrt_kinit_init_scanned
    ldr x11, [x19, #KV_REQUIRES]
    bics xzr, x11, x10
    b.ne 1f                         // not usable here
    ldr x12, [x19, #KV_NAME]
    str x12, [x21], #8              // append its name
    cbnz x22, 1f
    mov x22, x19                    // first usable record = "auto"
1:
    add x19, x19, #KV_SIZE
    sub x20, x20, #1
    b Lrt_kinit_init_scan
Lrt_kinit_init_scanned:
    str xzr, [x21]                  // NULL terminator
    // The baseline (KV_REQUIRES = 0) is always usable, so x22 != 0.
    adrp x9, Lrt_kinit_cur@PAGE
    str x22, [x9, Lrt_kinit_cur@PAGEOFF]

    // 3. Environment override.
    adrp x0, Lrt_kinit_s_env@PAGE
    add x0, x0, Lrt_kinit_s_env@PAGEOFF
    bl _getenv
    cbz x0, Lrt_kinit_init_ret      // unset: auto
    ldrb w9, [x0]
    cbz w9, Lrt_kinit_init_ret      // empty: auto
    bl Lrt_kinit_find               // "auto" and unknown names give 0
    cbz x0, Lrt_kinit_init_ret
    adrp x9, Lrt_kinit_cur@PAGE
    str x0, [x9, Lrt_kinit_cur@PAGEOFF]
Lrt_kinit_init_ret:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// _bsk_kern_use -- re-select the kernel variant by name.
//   Inputs  : x0 = NUL-terminated name (a usable variant or "baseline")
//   Outputs : x0 = 0 on success; -1 (and no change) if the name is
//             unknown or the variant is not usable on this CPU
//   Runs _bsk_kern_init first (idempotent).
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = the name (across _bsk_kern_init)
//   Frame   : 32 bytes (frame record + x19)
// ---------------------------------------------------------------------
    .globl _bsk_kern_use
    .p2align 2
_bsk_kern_use:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov x19, x0                     // keep the name across init
    bl _bsk_kern_init               // features must be known (idempotent)
    mov x0, x19
    bl Lrt_kinit_find
    cbz x0, 1f
    adrp x9, Lrt_kinit_cur@PAGE
    str x0, [x9, Lrt_kinit_cur@PAGEOFF]
    mov x0, #0
    b 2f
1:
    mov x0, #-1
2:
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _bsk_kern_name -- name of the variant in use.
//   Inputs  : none
//   Outputs : x0 = NUL-terminated KV_NAME of the current record
//   Clobbers: x0-x17, d0-d7, d16-d31 (runs _bsk_kern_init first)
//   Callee-saved used: none
//   Frame   : 16 bytes (frame record)
// ---------------------------------------------------------------------
    .globl _bsk_kern_name
    .p2align 2
_bsk_kern_name:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl _bsk_kern_init               // idempotent
    adrp x9, Lrt_kinit_cur@PAGE
    ldr x9, [x9, Lrt_kinit_cur@PAGEOFF]
    ldr x0, [x9, #KV_NAME]
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// _bsk_kern_variants -- NULL-terminated array of usable variant names in
//   table order (runs _bsk_kern_init first).
//   Inputs  : none
//   Outputs : x0 = pointer to the array
//   Clobbers: x0-x17, d0-d7, d16-d31 (runs _bsk_kern_init first)
//   Callee-saved used: none
//   Frame   : 16 bytes (frame record)
// ---------------------------------------------------------------------
    .globl _bsk_kern_variants
    .p2align 2
_bsk_kern_variants:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl _bsk_kern_init               // idempotent
    adrp x0, Lrt_kinit_names@PAGE
    add x0, x0, Lrt_kinit_names@PAGEOFF
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// _bsk_kern_features -- detected KF_* bits (runs _bsk_kern_init first).
//   Inputs  : none
//   Outputs : x0 = feature mask
//   Clobbers: x0-x17, d0-d7, d16-d31 (runs _bsk_kern_init first)
//   Callee-saved used: none
//   Frame   : 16 bytes (frame record)
// ---------------------------------------------------------------------
    .globl _bsk_kern_features
    .p2align 2
_bsk_kern_features:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl _bsk_kern_init               // idempotent
    adrp x9, Lrt_kinit_features@PAGE
    ldr x0, [x9, Lrt_kinit_features@PAGEOFF]
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Trampolines _bsk_kern_gemm ... _bsk_kern_inv: load the current record,
// load the kernel's slot, branch to it with the arguments untouched.
// Contracts: runtime.inc / DESIGN.md 6.6.1. Clobbers x16 in addition to
// whatever the kernel clobbers. No frame.
// ---------------------------------------------------------------------
.macro RT_KTRAMP name, slot
    .globl \name
    .p2align 2
\name:
    adrp x16, Lrt_kinit_cur@PAGE
    ldr x16, [x16, Lrt_kinit_cur@PAGEOFF]   // current KV_* record
    ldr x16, [x16, #\slot]                  // this kernel's function
    br x16
.endm

    RT_KTRAMP _bsk_kern_gemm,  KV_GEMM
    RT_KTRAMP _bsk_kern_add,   KV_ADD
    RT_KTRAMP _bsk_kern_sub,   KV_SUB
    RT_KTRAMP _bsk_kern_scale, KV_SCALE
    RT_KTRAMP _bsk_kern_trn,   KV_TRN
    RT_KTRAMP _bsk_kern_copy,  KV_COPY
    RT_KTRAMP _bsk_kern_fill,  KV_FILL
    RT_KTRAMP _bsk_kern_inv,   KV_INV

// ---------------------------------------------------------------------
// Strings.
// ---------------------------------------------------------------------
    .section __TEXT,__cstring,cstring_literals
Lrt_kinit_s_neon:     .asciz "neon"
Lrt_kinit_s_baseline: .asciz "baseline"
Lrt_kinit_s_env:      .asciz "BAYSICK_KERNELS"
Lrt_kinit_s_sme:      .asciz "hw.optional.arm.FEAT_SME"
Lrt_kinit_s_sme2:     .asciz "hw.optional.arm.FEAT_SME2"
Lrt_kinit_s_f64:      .asciz "hw.optional.arm.FEAT_SME_F64F64"

// ---------------------------------------------------------------------
// The variant table: KV_* records, best variant first, baseline last
// (KV_REQUIRES = 0). Add a variant by adding a record ahead of `neon`
// and raising RT_KV_COUNT (DESIGN.md 6.6.7).
// ---------------------------------------------------------------------
    .section __DATA,__const
    .p2align 3
Lrt_kinit_table:
    // neon: Advanced SIMD baseline, every kernel specialised.
    .quad Lrt_kinit_s_neon          // KV_NAME
    .quad 0                         // KV_REQUIRES
    .quad _bsk_kneon_gemm           // KV_GEMM
    .quad _bsk_kneon_add            // KV_ADD
    .quad _bsk_kneon_sub            // KV_SUB
    .quad _bsk_kneon_scale          // KV_SCALE
    .quad _bsk_kneon_trn            // KV_TRN
    .quad _bsk_kneon_copy           // KV_COPY
    .quad _bsk_kneon_fill           // KV_FILL
    .quad _bsk_kneon_inv            // KV_INV
Lrt_kinit_table_end:
.if (Lrt_kinit_table_end - Lrt_kinit_table) != (RT_KV_COUNT * KV_SIZE)
    .error "rt_kinit: RT_KV_COUNT does not match the variant table"
.endif

// ---------------------------------------------------------------------
// State.
//   Lrt_kinit_cur       ptr  current KV_* record (initially the baseline)
//   Lrt_kinit_features  u64  detected KF_* bits
//   Lrt_kinit_done      u32  1 once _bsk_kern_init has run
//   Lrt_kinit_names     NULL-terminated array of usable variant names
// ---------------------------------------------------------------------
    .section __DATA,__data
    .p2align 3
Lrt_kinit_cur:
    .quad Lrt_kinit_table + (RT_KV_COUNT - 1) * KV_SIZE
.zerofill __DATA,__bss,Lrt_kinit_features,8,3
.zerofill __DATA,__bss,Lrt_kinit_done,4,2
.zerofill __DATA,__bss,Lrt_kinit_names,(RT_KV_COUNT + 1) * 8,3
