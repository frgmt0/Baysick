# =====================================================================
# src/runtime_x86_64_linux/rt_kinit.s -- matrix kernel CPU-feature
# detection, the kernel variant table and the dispatch trampolines
# (docs/DESIGN.md section 6.6).
#
# Defines (global, runtime.inc):
#   bsk_kern_init bsk_kern_use bsk_kern_name bsk_kern_variants
#   bsk_kern_features
#   bsk_kern_gemm bsk_kern_add bsk_kern_sub bsk_kern_scale
#   bsk_kern_trn bsk_kern_copy bsk_kern_fill bsk_kern_inv
#
# The variant table holds KV_* records, best variant first, baseline
# last (KV_REQUIRES = 0). Only the baseline "sse2" exists today; a new
# variant adds one record ahead of it (DESIGN.md 6.6.7) and nothing
# else in this file changes: every loop below walks the table by its
# record count.
#
# Link isolation (DESIGN.md 6.6.1): this file references only the
# kernel files (bsk_rt_ksse2_*) and libc (getenv), never another
# runtime file, so bench/ can link libbaysickrt.a with its own main.
#
# The current-variant pointer is statically initialised to the
# baseline record, so the trampolines are safe even before
# bsk_kern_init has run; bsk_kern_use/name/variants/features run the
# (idempotent) detection on first use.
# =====================================================================
.include "baysick.inc"

.equ RT_KINIT_NVAR, 1               # records in the variant table

    .text

# ---------------------------------------------------------------------
# .Lrt_kinit_detect -- fill .Lrt_kinit_feat with the KF_X64_* bits.
#   Purpose : DESIGN.md 6.6.2: AVX2 = CPUID.(7,0):EBX[5], FMA =
#             CPUID.1:ECX[12]; each also needs OS support of the AVX
#             state: CPUID.1:ECX[27] (OSXSAVE) and XGETBV(0) bits 1, 2.
#   Inputs  : none
#   Outputs : %rax = detected KF_* bits (also stored)
#   Clobbers: %rax %rcx %rdx %rsi %rdi %r8
#   Callee-saved used: %rbx (cpuid writes it; saved and restored)
#   Frame   : 8 bytes (saved %rbx); leaf
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_kinit_detect:
    pushq %rbx
    xorl %r8d, %r8d                 # feature bits found so far
    xorl %eax, %eax
    cpuid                           # leaf 0: %eax = highest basic leaf
    movl %eax, %esi                 # keep max leaf
    cmpl $1, %esi
    jb .Lrt_kinit_detect_done       # no leaf 1: nothing to report
    movl $1, %eax
    xorl %ecx, %ecx
    cpuid                           # leaf 1: feature flags in %ecx
    movl %ecx, %edi                 # keep leaf-1 ECX
    btl $27, %edi                   # OSXSAVE: XGETBV usable?
    jnc .Lrt_kinit_detect_done      # no: AVX state not enabled by the OS
    xorl %ecx, %ecx
    xgetbv                          # %edx:%eax = XCR0
    andl $6, %eax
    cmpl $6, %eax                   # XMM (bit 1) and YMM (bit 2) state
    jne .Lrt_kinit_detect_done      # OS does not save YMM: no AVX2/FMA
    btl $12, %edi                   # FMA3
    jnc 1f
    orl $KF_X64_FMA, %r8d
1:
    cmpl $7, %esi
    jb .Lrt_kinit_detect_done       # no leaf 7: no AVX2 bit to read
    movl $7, %eax
    xorl %ecx, %ecx
    cpuid                           # leaf 7 subleaf 0: %ebx flags
    btl $5, %ebx                    # AVX2
    jnc .Lrt_kinit_detect_done
    orl $KF_X64_AVX2, %r8d
.Lrt_kinit_detect_done:
    movq %r8, .Lrt_kinit_feat(%rip)
    movq %r8, %rax
    popq %rbx
    ret

# ---------------------------------------------------------------------
# .Lrt_kinit_streq -- compare two NUL-terminated strings.
#   Inputs  : %rdi, %rsi = strings
#   Outputs : ZF = 1 (je) when equal
#   Clobbers: %rax %rcx %rdi %rsi
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_kinit_streq:
    movzbl (%rdi), %eax
    movzbl (%rsi), %ecx
    cmpl %ecx, %eax
    jne 1f                          # differ: ZF = 0
    testl %eax, %eax
    jz 1f                           # both ended: ZF = 1
    addq $1, %rdi
    addq $1, %rsi
    jmp .Lrt_kinit_streq
1:
    ret

# ---------------------------------------------------------------------
# .Lrt_kinit_usable -- is a record usable with the detected features?
#   Inputs  : %rdx = record address
#   Outputs : ZF = 1 (je) when usable (all KV_REQUIRES bits detected)
#   Clobbers: %rax
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_kinit_usable:
    movq .Lrt_kinit_feat(%rip), %rax
    notq %rax                       # bits NOT detected
    testq KV_REQUIRES(%rdx), %rax   # any required bit missing?
    ret

# ---------------------------------------------------------------------
# .Lrt_kinit_find -- look up a usable record by name.
#   Purpose : "baseline" -> the last record; otherwise the first usable
#             record whose KV_NAME equals the string.
#   Inputs  : %rdi = NUL-terminated name
#   Outputs : %rax = record address, or 0 if not found / not usable
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = record cursor, %r12 = name, %r13 = count
#   Frame   : 32 bytes (%rbx %r12 %r13 + pad)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_kinit_find:
    pushq %rbx
    pushq %r12
    pushq %r13
    movq %rdi, %r12
    leaq .Lrt_kinit_baseline_str(%rip), %rsi
    call .Lrt_kinit_streq
    jne 1f
    leaq .Lrt_kinit_table + (RT_KINIT_NVAR - 1) * KV_SIZE(%rip), %rax
    jmp .Lrt_kinit_find_done        # "baseline": last record
1:
    leaq .Lrt_kinit_table(%rip), %rbx
    movl $RT_KINIT_NVAR, %r13d
.Lrt_kinit_find_loop:
    movq %rbx, %rdx
    call .Lrt_kinit_usable
    jne .Lrt_kinit_find_next        # requires missing features: skip
    movq %r12, %rdi
    movq KV_NAME(%rbx), %rsi
    call .Lrt_kinit_streq
    jne .Lrt_kinit_find_next
    movq %rbx, %rax                 # match
    jmp .Lrt_kinit_find_done
.Lrt_kinit_find_next:
    addq $KV_SIZE, %rbx
    subl $1, %r13d
    jnz .Lrt_kinit_find_loop
    xorl %eax, %eax                 # unknown or unusable
.Lrt_kinit_find_done:
    popq %r13
    popq %r12
    popq %rbx
    ret

# ---------------------------------------------------------------------
# bsk_kern_init -- detect features and choose the kernel variant.
#   Purpose : DESIGN.md 6.6.3. Idempotent: only the first call does
#             anything. Builds the usable-name list, then selects by
#             BAYSICK_KERNELS (unset/empty/"auto"/unknown -> first
#             usable record; "baseline" -> last; usable name -> it).
#   Inputs  : none
#   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = record cursor, %r12 = name-list cursor,
#             %r13 = records left, %rbp = frame pointer
#   Frame   : 40 bytes (%rbp %rbx %r12 %r13 + pad)
# ---------------------------------------------------------------------
    .globl bsk_kern_init
    .type bsk_kern_init, @function
    .p2align 4
bsk_kern_init:
    cmpl $0, .Lrt_kinit_done(%rip)
    jne .Lrt_kinit_init_ret         # already initialised
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    subq $8, %rsp                   # %rsp = 0 (mod 16)
    movl $1, .Lrt_kinit_done(%rip)
    call .Lrt_kinit_detect
    # Usable names, in table order, NULL-terminated (the array is
    # zero-initialised and has RT_KINIT_NVAR + 1 slots).
    leaq .Lrt_kinit_table(%rip), %rbx
    leaq .Lrt_kinit_names(%rip), %r12
    movl $RT_KINIT_NVAR, %r13d
    xorl %ecx, %ecx                 # first usable record (0 = none yet)
    movq %rcx, .Lrt_kinit_first(%rip)
.Lrt_kinit_init_names:
    movq %rbx, %rdx
    call .Lrt_kinit_usable
    jne 1f
    movq KV_NAME(%rbx), %rax
    movq %rax, (%r12)               # append the name
    addq $8, %r12
    cmpq $0, .Lrt_kinit_first(%rip)
    jne 1f
    movq %rbx, .Lrt_kinit_first(%rip)   # best usable record
1:
    addq $KV_SIZE, %rbx
    subl $1, %r13d
    jnz .Lrt_kinit_init_names
    # Default: the first usable record (the baseline always is).
    movq .Lrt_kinit_first(%rip), %rax
    movq %rax, .Lrt_kinit_cur(%rip)
    leaq .Lrt_kinit_env_str(%rip), %rdi
    call getenv@PLT                 # %rax = value or NULL
    testq %rax, %rax
    jz .Lrt_kinit_init_out          # unset: auto
    movq %rax, %rdi
    call .Lrt_kinit_find            # baseline / usable name / 0
    testq %rax, %rax
    jz .Lrt_kinit_init_out          # empty, "auto", unknown: auto
    movq %rax, .Lrt_kinit_cur(%rip)
.Lrt_kinit_init_out:
    addq $8, %rsp
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
.Lrt_kinit_init_ret:
    ret
    .size bsk_kern_init, . - bsk_kern_init

# ---------------------------------------------------------------------
# bsk_kern_use -- re-select the variant by name.
#   Inputs  : %rdi = NUL-terminated name ("baseline" allowed)
#   Outputs : %rax = 0 on success, -1 (no change) if unknown/unusable
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = the name, %rbp = frame pointer
#   Frame   : 16 bytes (%rbp %rbx)
# ---------------------------------------------------------------------
    .globl bsk_kern_use
    .type bsk_kern_use, @function
    .p2align 4
bsk_kern_use:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    subq $8, %rsp                   # %rsp = 0 (mod 16)
    movq %rdi, %rbx
    call bsk_kern_init              # features must be known
    movq %rbx, %rdi
    call .Lrt_kinit_find
    testq %rax, %rax
    jz 1f
    movq %rax, .Lrt_kinit_cur(%rip) # switch
    xorl %eax, %eax
    jmp 2f
1:
    movq $-1, %rax                  # unknown or not usable: no change
2:
    addq $8, %rsp
    popq %rbx
    popq %rbp
    ret
    .size bsk_kern_use, . - bsk_kern_use

# ---------------------------------------------------------------------
# bsk_kern_name -- name of the variant in use.
#   Outputs : %rax = KV_NAME of the current record
#   Clobbers: all caller-saved registers (may run bsk_kern_init)
#   Frame   : 8 bytes (alignment pad)
# ---------------------------------------------------------------------
    .globl bsk_kern_name
    .type bsk_kern_name, @function
    .p2align 4
bsk_kern_name:
    subq $8, %rsp                   # align for the call
    call bsk_kern_init
    addq $8, %rsp
    movq .Lrt_kinit_cur(%rip), %rax
    movq KV_NAME(%rax), %rax
    ret
    .size bsk_kern_name, . - bsk_kern_name

# ---------------------------------------------------------------------
# bsk_kern_variants -- NULL-terminated array of the usable names.
#   Outputs : %rax = pointer to the static array (table order)
#   Clobbers: all caller-saved registers (may run bsk_kern_init)
#   Frame   : 8 bytes (alignment pad)
# ---------------------------------------------------------------------
    .globl bsk_kern_variants
    .type bsk_kern_variants, @function
    .p2align 4
bsk_kern_variants:
    subq $8, %rsp
    call bsk_kern_init
    addq $8, %rsp
    leaq .Lrt_kinit_names(%rip), %rax
    ret
    .size bsk_kern_variants, . - bsk_kern_variants

# ---------------------------------------------------------------------
# bsk_kern_features -- detected KF_* bits.
#   Outputs : %rax = feature mask
#   Clobbers: all caller-saved registers (may run bsk_kern_init)
#   Frame   : 8 bytes (alignment pad)
# ---------------------------------------------------------------------
    .globl bsk_kern_features
    .type bsk_kern_features, @function
    .p2align 4
bsk_kern_features:
    subq $8, %rsp
    call bsk_kern_init
    addq $8, %rsp
    movq .Lrt_kinit_feat(%rip), %rax
    ret
    .size bsk_kern_features, . - bsk_kern_features

# ---------------------------------------------------------------------
# Trampolines: load the current record, jump through the kernel's
# slot with every argument register untouched (System V: %rdi %rsi
# %rdx %xmm0 are the kernel's arguments; %rax is free on entry).
# ---------------------------------------------------------------------
.macro RT_KINIT_TRAMPOLINE name, slot
    .globl \name
    .type \name, @function
    .p2align 4
\name:
    movq .Lrt_kinit_cur(%rip), %rax    # current KV_* record
    jmp *\slot(%rax)                    # tail-jump to the kernel
    .size \name, . - \name
.endm

    RT_KINIT_TRAMPOLINE bsk_kern_gemm,  KV_GEMM
    RT_KINIT_TRAMPOLINE bsk_kern_add,   KV_ADD
    RT_KINIT_TRAMPOLINE bsk_kern_sub,   KV_SUB
    RT_KINIT_TRAMPOLINE bsk_kern_scale, KV_SCALE
    RT_KINIT_TRAMPOLINE bsk_kern_trn,   KV_TRN
    RT_KINIT_TRAMPOLINE bsk_kern_copy,  KV_COPY
    RT_KINIT_TRAMPOLINE bsk_kern_fill,  KV_FILL
    RT_KINIT_TRAMPOLINE bsk_kern_inv,   KV_INV

# ---------------------------------------------------------------------
# Variant table (read-only, holds pointers -> .data.rel.ro).
# ---------------------------------------------------------------------
    .section .data.rel.ro,"aw",@progbits
    .p2align 3
.Lrt_kinit_table:
    # sse2: x86-64 baseline (KV_REQUIRES = 0), specialises everything
    .quad .Lrt_kinit_sse2_str       # KV_NAME
    .quad 0                         # KV_REQUIRES
    .quad bsk_rt_ksse2_gemm         # KV_GEMM
    .quad bsk_rt_ksse2_add          # KV_ADD
    .quad bsk_rt_ksse2_sub          # KV_SUB
    .quad bsk_rt_ksse2_scale        # KV_SCALE
    .quad bsk_rt_ksse2_trn          # KV_TRN
    .quad bsk_rt_ksse2_copy         # KV_COPY
    .quad bsk_rt_ksse2_fill         # KV_FILL
    .quad bsk_rt_ksse2_inv          # KV_INV
.Lrt_kinit_table_end:
.if (.Lrt_kinit_table_end - .Lrt_kinit_table) != (RT_KINIT_NVAR * KV_SIZE)
    .error "rt_kinit.s: RT_KINIT_NVAR does not match the variant table"
.endif

    .section .rodata
.Lrt_kinit_sse2_str:
    .asciz "sse2"
.Lrt_kinit_baseline_str:
    .asciz "baseline"
.Lrt_kinit_env_str:
    .asciz "BAYSICK_KERNELS"

# ---------------------------------------------------------------------
# State.
#   .Lrt_kinit_cur    ptr  current record (starts at the baseline)
#   .Lrt_kinit_first  ptr  best usable record (set by bsk_kern_init)
#   .Lrt_kinit_feat   u64  detected KF_* bits
#   .Lrt_kinit_names  ptr[NVAR + 1] usable names, NULL-terminated
#   .Lrt_kinit_done   u32  1 once bsk_kern_init has run
# ---------------------------------------------------------------------
    .data
    .p2align 3
.Lrt_kinit_cur:
    .quad .Lrt_kinit_table + (RT_KINIT_NVAR - 1) * KV_SIZE

    .bss
    .p2align 3
.Lrt_kinit_first:
    .zero 8
.Lrt_kinit_feat:
    .zero 8
.Lrt_kinit_names:
    .zero 8 * (RT_KINIT_NVAR + 1)
.Lrt_kinit_done:
    .zero 4

    .section .note.GNU-stack,"",@progbits
