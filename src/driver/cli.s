// =====================================================================
// src/driver/cli.s -- command-line parsing (DESIGN.md section 4.1).
//
//   _drv_cli_parse(w0=argc, x1=argv)   fills the _drv_opt_* variables;
//                                      returns only if the command line is
//                                      valid (help/version/usage errors exit)
//   _drv_output_stem(x0=input path) -> x0 = arena string: the path without
//                                      a trailing ".bas", else path + ".out"
//
// Driver-private option variables (u64 each, defined here):
//   _drv_opt_input      input path
//   _drv_opt_output     -o path or 0
//   _drv_opt_asm_only   1 if -S
//   _drv_opt_emit_ir    1 if --emit-ir
//   _drv_opt_keep_temps 1 if --keep-temps
//   _drv_opt_desc       selected backend descriptor (BKD_*)
// =====================================================================
.include "baysick.inc"

    .section __TEXT,__text,regular,pure_instructions

// Load the address of a local symbol into a register.
.macro CLI_ADR reg, sym
    adrp \reg, \sym@PAGE
    add \reg, \reg, \sym@PAGEOFF
.endm

// Compare the current argument (x22) with a literal; branch if equal.
.macro CLI_IFARG lit, target
    mov x0, x22
    CLI_ADR x1, \lit
    bl _strcmp
    cbz w0, \target
.endm

// Store 1 into an option variable.
.macro CLI_SET1 var
    CLI_ADR x9, \var
    mov x10, #1
    str x10, [x9]
.endm

// ---------------------------------------------------------------------
// _drv_cli_parse -- parse argv, select the target.
//   in:  w0 = argc, x1 = argv
//   out: none; exits with EXIT_OK for --help/--version and with
//        EXIT_USAGE (after printing the message) for usage errors
//   clobbers: x0-x17
//   callee-saved: x19 = argv cursor, x20 = arguments left,
//                 x21 = number of input files seen, x22 = current argument,
//                 x23 = target name, x24 = target table cursor
//   frame: 64 bytes
// ---------------------------------------------------------------------
    .globl _drv_cli_parse
    .p2align 2
_drv_cli_parse:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    // skip argv[0]
    add x19, x1, #8
    subs w20, w0, #1
    csel w20, w20, wzr, ge
    mov x21, #0
    CLI_ADR x23, Lcli_default_target
Lcli_loop:
    cbz w20, Lcli_after
    ldr x22, [x19], #8
    sub w20, w20, #1
    // anything not starting with '-' (or exactly "-") is the input file
    ldrb w9, [x22]
    cmp w9, #'-'
    b.ne Lcli_input
    ldrb w9, [x22, #1]
    cbz w9, Lcli_input
    CLI_IFARG Lcli_s_o, Lcli_opt_o
    CLI_IFARG Lcli_s_S, Lcli_opt_S
    CLI_IFARG Lcli_s_emit, Lcli_opt_emit
    CLI_IFARG Lcli_s_target, Lcli_opt_target
    CLI_IFARG Lcli_s_keep, Lcli_opt_keep
    CLI_IFARG Lcli_s_help, Lcli_opt_help
    CLI_IFARG Lcli_s_h, Lcli_opt_help
    CLI_IFARG Lcli_s_version, Lcli_opt_version
    // "baysick: unknown option '%s'" + usage line
    CLI_ADR x0, Lcli_m_unknown
    mov x1, x22
    mov x2, #0
    bl _drv_diag
    b Lcli_usage_exit
Lcli_input:
    // remember the (last) input file and count them
    CLI_ADR x9, _drv_opt_input
    str x22, [x9]
    add x21, x21, #1
    b Lcli_loop
Lcli_opt_o:
    cbz w20, Lcli_missing
    ldr x10, [x19], #8
    sub w20, w20, #1
    CLI_ADR x9, _drv_opt_output
    str x10, [x9]
    b Lcli_loop
Lcli_opt_target:
    cbz w20, Lcli_missing
    ldr x23, [x19], #8
    sub w20, w20, #1
    b Lcli_loop
Lcli_opt_S:
    CLI_SET1 _drv_opt_asm_only
    b Lcli_loop
Lcli_opt_emit:
    CLI_SET1 _drv_opt_emit_ir
    b Lcli_loop
Lcli_opt_keep:
    CLI_SET1 _drv_opt_keep_temps
    b Lcli_loop
Lcli_opt_help:
    CLI_ADR x0, Lcli_help_text
    bl Lcli_stdout_exit
Lcli_opt_version:
    CLI_ADR x0, Lcli_version_text
    bl Lcli_stdout_exit
Lcli_missing:
    // "baysick: missing argument for '%s'" + usage line
    CLI_ADR x0, Lcli_m_missing
    mov x1, x22
    mov x2, #0
    bl _drv_diag
    b Lcli_usage_exit
Lcli_after:
    // exactly one input file
    cmp x21, #1
    b.ne Lcli_usage_exit
    // -S and --emit-ir are mutually exclusive
    CLI_ADR x9, _drv_opt_asm_only
    ldr x9, [x9]
    CLI_ADR x10, _drv_opt_emit_ir
    ldr x10, [x10]
    and x9, x9, x10
    cbnz x9, Lcli_usage_exit
    // find the descriptor whose BKD_NAME equals the target name
    CLI_ADR x24, _drv_targets
Lcli_target_loop:
    ldr x9, [x24], #8
    cbz x9, Lcli_bad_target
    str x9, [sp, #-16]!                 // keep the descriptor over strcmp
    ldr x0, [x9, #BKD_NAME]
    mov x1, x23
    bl _strcmp
    ldr x9, [sp], #16
    cbnz w0, Lcli_target_loop
    CLI_ADR x10, _drv_opt_desc
    str x9, [x10]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret
Lcli_bad_target:
    // "baysick: unknown target '%s'" (no usage line)
    CLI_ADR x0, Lcli_m_target
    mov x1, x23
    mov x2, #0
    bl _drv_diag
    mov w0, #EXIT_USAGE
    bl __exit
Lcli_usage_exit:
    bl _drv_usage_line
    mov w0, #EXIT_USAGE
    bl __exit

// ---------------------------------------------------------------------
// Lcli_stdout_exit -- write a string to stdout and exit EXIT_OK.
//   in:  x0 = NUL-terminated text
//   out: does not return
//   clobbers: everything caller-saved; callee-saved: x19 = text
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lcli_stdout_exit:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov x19, x0
    bl _strlen
    mov x2, x0
    mov x1, x19
    mov w0, #1
    bl _write
    mov w0, #EXIT_OK
    bl __exit

// ---------------------------------------------------------------------
// _drv_output_stem -- default output name (DESIGN.md 4.1).
//   in:  x0 = input path
//   out: x0 = arena string: path minus a trailing ".bas", or path + ".out"
//   clobbers: x0-x17
//   callee-saved: x19 = path, x20 = its length
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .globl _drv_output_stem
    .p2align 2
_drv_output_stem:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    bl _strlen
    mov x20, x0
    cmp x20, #4
    b.lo Lcli_stem_append
    // does it end in ".bas"?
    add x0, x19, x20
    sub x0, x0, #4
    CLI_ADR x1, Lcli_s_bas
    bl _strcmp
    cbnz w0, Lcli_stem_append
    // copy everything but the suffix into a zeroed block (NUL included)
    sub x20, x20, #4
    add x0, x20, #1
    bl _drv_alloc
    mov x1, x19
    mov x2, x20
    str x0, [sp, #-16]!
    bl _memcpy
    ldr x0, [sp], #16
    b Lcli_stem_done
Lcli_stem_append:
    mov x0, x19
    CLI_ADR x1, Lcli_s_out
    mov x2, #0
    bl _drv_strcat3
Lcli_stem_done:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

    .section __TEXT,__cstring,cstring_literals
Lcli_default_target:
    .asciz "arm64-macos"
Lcli_s_o:       .asciz "-o"
Lcli_s_S:       .asciz "-S"
Lcli_s_emit:    .asciz "--emit-ir"
Lcli_s_target:  .asciz "--target"
Lcli_s_keep:    .asciz "--keep-temps"
Lcli_s_help:    .asciz "--help"
Lcli_s_h:       .asciz "-h"
Lcli_s_version: .asciz "--version"
Lcli_s_bas:     .asciz ".bas"
Lcli_s_out:     .asciz ".out"
Lcli_m_unknown: .asciz "unknown option '%s'"
Lcli_m_missing: .asciz "missing argument for '%s'"
Lcli_m_target:  .asciz "unknown target '%s'"
Lcli_version_text:
    .asciz "baysick 0.2.0 (Dartmouth BASIC, Second Edition 1964)\n"
Lcli_help_text:
    .ascii "usage: baysick <file.bas> [-o out] [-S] [--emit-ir] [--target arm64-macos] [--keep-temps]\n"
    .ascii "       baysick --help | -h | --version\n"
    .ascii "\n"
    .ascii "Compile a Dartmouth BASIC (1964) program to a native executable.\n"
    .ascii "\n"
    .ascii "  -o <out>         output path (default: input without .bas, or input + .out)\n"
    .ascii "  -S               write assembly (default name <stem>.s) instead of linking\n"
    .ascii "  --emit-ir        write the IR dump to <out>, or to stdout without -o\n"
    .ascii "  --target <name>  code generation target (default: arm64-macos)\n"
    .ascii "  --keep-temps     keep the temporary directory with the .s and .o files\n"
    .ascii "  -h, --help       show this help\n"
    .ascii "  --version        show the version\n"
    .ascii "\n"
    .ascii "Environment: BAYSICK_RUNTIME (runtime archive path), SDKROOT (macOS SDK),\n"
    .asciz "TMPDIR (temporary directory).\n"

    .section __DATA,__data
    .p2align 3
    .globl _drv_opt_input
_drv_opt_input:         .quad 0
    .globl _drv_opt_output
_drv_opt_output:        .quad 0
    .globl _drv_opt_asm_only
_drv_opt_asm_only:      .quad 0
    .globl _drv_opt_emit_ir
_drv_opt_emit_ir:       .quad 0
    .globl _drv_opt_keep_temps
_drv_opt_keep_temps:    .quad 0
    .globl _drv_opt_desc
_drv_opt_desc:          .quad 0
