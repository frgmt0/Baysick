// =====================================================================
// src/backend/x86_64_linux/x64_desc.s -- the x86_64-linux backend
// descriptor (backend.inc BKD_*) and its assembler / linker argv
// templates (docs/DESIGN.md section 5.4.1).
//
// BKD_FLAGS is 0 (no BKF_HOST_NATIVE): the macOS driver only writes the
// .s file (as if -S were given). The templates record the exact commands
// that turn it into an executable on x86_64 Linux.
//
// Exports: _bk_x86_64_linux_desc (64-byte read-only descriptor)
// Uses:    _bk_x64_emit (x64_emit.s) as BKD_EMIT
// =====================================================================
.include "baysick.inc"

// ---- strings used by the descriptor and the templates ----------------
    .section __TEXT,__cstring,cstring_literals
Lbk_x64_desc_name:      .asciz "x86_64-linux"
Lbk_x64_desc_asm_sfx:   .asciz ".s"
Lbk_x64_desc_obj_sfx:   .asciz ".o"
Lbk_x64_desc_runtime:   .asciz "libbaysickrt.a"
Lbk_x64_desc_as:        .asciz "as"
Lbk_x64_desc_64:        .asciz "--64"
Lbk_x64_desc_o:         .asciz "-o"
Lbk_x64_desc_gcc:       .asciz "gcc"
Lbk_x64_desc_nopie:     .asciz "-no-pie"
Lbk_x64_desc_lm:        .asciz "-lm"

    .section __DATA,__const
    .p2align 3

// as --64 -o <obj> <asm>
Lbk_x64_desc_as_argv:
    .quad Lbk_x64_desc_as
    .quad Lbk_x64_desc_64
    .quad Lbk_x64_desc_o
    .quad PH_OBJ
    .quad PH_ASM
    .quad 0

// gcc -no-pie -o <exe> <obj> <runtime> -lm
Lbk_x64_desc_ld_argv:
    .quad Lbk_x64_desc_gcc
    .quad Lbk_x64_desc_nopie
    .quad Lbk_x64_desc_o
    .quad PH_EXE
    .quad PH_OBJ
    .quad PH_RUNTIME
    .quad Lbk_x64_desc_lm
    .quad 0

// ---- the descriptor itself (field order = backend.inc BKD_* offsets) --
    .globl _bk_x86_64_linux_desc
    .p2align 3
_bk_x86_64_linux_desc:
    .quad Lbk_x64_desc_name         // BKD_NAME
    .quad _bk_x64_emit              // BKD_EMIT
    .quad Lbk_x64_desc_as_argv      // BKD_AS_ARGV
    .quad Lbk_x64_desc_ld_argv      // BKD_LD_ARGV
    .quad 0                         // BKD_FLAGS: not host-native
    .quad Lbk_x64_desc_asm_sfx      // BKD_ASM_SUFFIX
    .quad Lbk_x64_desc_obj_sfx      // BKD_OBJ_SUFFIX
    .quad Lbk_x64_desc_runtime      // BKD_RUNTIME_NAME
Lbk_x64_desc_end:

// layout assertions against backend.inc
.if (Lbk_x64_desc_end - _bk_x86_64_linux_desc) != BKD_SIZE
    .error "x64_desc.s descriptor size differs from BKD_SIZE"
.endif
.if (BKD_NAME != 0) || (BKD_EMIT != 8) || (BKD_AS_ARGV != 16) || (BKD_LD_ARGV != 24)
    .error "backend.inc BKD_* layout differs from x64_desc.s"
.endif
.if (BKD_FLAGS != 32) || (BKD_ASM_SUFFIX != 40) || (BKD_OBJ_SUFFIX != 48) || (BKD_RUNTIME_NAME != 56)
    .error "backend.inc BKD_* layout differs from x64_desc.s"
.endif
