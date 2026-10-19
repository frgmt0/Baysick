// =====================================================================
// src/backend/arm64_macos/a64_desc.s -- the arm64-macos backend
// descriptor (backend.inc BKD_*) and its assembler / linker argv
// templates (docs/DESIGN.md section 5.1-5.2).
//
// Exports: _bk_arm64_macos_desc (64-byte read-only descriptor)
// Uses:    _bk_arm64_emit (a64_emit.s) as BKD_EMIT
// =====================================================================
.include "baysick.inc"

// ---- strings used by the descriptor and the templates ----------------
    .section __TEXT,__cstring,cstring_literals
Lbk_desc_name:      .asciz "arm64-macos"
Lbk_desc_asm_sfx:   .asciz ".s"
Lbk_desc_obj_sfx:   .asciz ".o"
Lbk_desc_runtime:   .asciz "libbaysickrt.a"
Lbk_desc_as:        .asciz "as"
Lbk_desc_ld:        .asciz "ld"
Lbk_desc_arch:      .asciz "-arch"
Lbk_desc_arm64:     .asciz "arm64"
Lbk_desc_minver:    .asciz "-mmacosx-version-min=11.0"
Lbk_desc_o:         .asciz "-o"
Lbk_desc_lsystem:   .asciz "-lSystem"
Lbk_desc_syslib:    .asciz "-syslibroot"
Lbk_desc_e:         .asciz "-e"
Lbk_desc_main:      .asciz "_main"
Lbk_desc_platver:   .asciz "-platform_version"
Lbk_desc_macos:     .asciz "macos"
Lbk_desc_v11:       .asciz "11.0"

    .section __DATA,__const
    .p2align 3

// as -arch arm64 -mmacosx-version-min=11.0 -o <obj> <asm>
Lbk_desc_as_argv:
    .quad Lbk_desc_as
    .quad Lbk_desc_arch
    .quad Lbk_desc_arm64
    .quad Lbk_desc_minver
    .quad Lbk_desc_o
    .quad PH_OBJ
    .quad PH_ASM
    .quad 0

// ld -o <exe> <obj> <runtime> -lSystem -syslibroot <sdk> -e _main
//    -arch arm64 -platform_version macos 11.0 11.0
Lbk_desc_ld_argv:
    .quad Lbk_desc_ld
    .quad Lbk_desc_o
    .quad PH_EXE
    .quad PH_OBJ
    .quad PH_RUNTIME
    .quad Lbk_desc_lsystem
    .quad Lbk_desc_syslib
    .quad PH_SDK
    .quad Lbk_desc_e
    .quad Lbk_desc_main
    .quad Lbk_desc_arch
    .quad Lbk_desc_arm64
    .quad Lbk_desc_platver
    .quad Lbk_desc_macos
    .quad Lbk_desc_v11
    .quad Lbk_desc_v11
    .quad 0

// ---- the descriptor itself (field order = backend.inc BKD_* offsets) --
    .globl _bk_arm64_macos_desc
    .p2align 3
_bk_arm64_macos_desc:
    .quad Lbk_desc_name         // BKD_NAME
    .quad _bk_arm64_emit        // BKD_EMIT
    .quad Lbk_desc_as_argv      // BKD_AS_ARGV
    .quad Lbk_desc_ld_argv      // BKD_LD_ARGV
    .quad BKF_HOST_NATIVE       // BKD_FLAGS
    .quad Lbk_desc_asm_sfx      // BKD_ASM_SUFFIX
    .quad Lbk_desc_obj_sfx      // BKD_OBJ_SUFFIX
    .quad Lbk_desc_runtime      // BKD_RUNTIME_NAME

// layout assertions against backend.inc
.if (BKD_NAME != 0) || (BKD_EMIT != 8) || (BKD_AS_ARGV != 16) || (BKD_LD_ARGV != 24)
    .error "backend.inc BKD_* layout differs from a64_desc.s"
.endif
.if (BKD_FLAGS != 32) || (BKD_ASM_SUFFIX != 40) || (BKD_OBJ_SUFFIX != 48) || (BKD_RUNTIME_NAME != 56) || (BKD_SIZE != 64)
    .error "backend.inc BKD_* layout differs from a64_desc.s"
.endif
