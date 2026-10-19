// =====================================================================
// src/driver/main.s -- the compiler's _main (DESIGN.md sections 1, 4).
//
//   CLI -> read source -> _ir_module_new -> _fe_compile -> _ir_verify ->
//   --emit-ir: _ir_dump to -o file / stdout
//   -S (or non-native target): BKD_EMIT -> <out or stem.s>
//   default: BKD_EMIT -> temp dir prog.s -> as -> ld -> cleanup
//
// Exit status per DESIGN.md 4.2 (limits.inc EXIT_*).
// =====================================================================
.include "baysick.inc"

    .section __TEXT,__text,regular,pure_instructions

.macro MAIN_ADR reg, sym
    adrp \reg, \sym@PAGE
    add \reg, \reg, \sym@PAGEOFF
.endm

// Load the u64 option variable \var into \reg.
.macro MAIN_LDOPT reg, var
    adrp \reg, \var@PAGE
    ldr \reg, [\reg, \var@PAGEOFF]
.endm

// ---------------------------------------------------------------------
// _main -- compiler entry point.
//   in:  w0 = argc, x1 = argv
//   out: never returns; exits with EXIT_* status
//   callee-saved: x19 = input path, x20 = backend descriptor,
//                 x21 = Module*, x22 = source bytes, x23 = source length /
//                 scratch, x24 = output path, x25 = temp dir (0 if none),
//                 x26 = assembly path, x27 = object path, x28 = exit status
//   frame: 128 bytes: frame record, x19-x28, OutBuf at [sp,#96]
// ---------------------------------------------------------------------
    .globl _main
    .p2align 2
_main:
    stp x29, x30, [sp, #-128]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    mov x25, #0
    // ---- ignore SIGPIPE: a closed stdout/stderr then makes write()
    // fail with EPIPE instead of killing us before cleanup ----
    mov w19, w0                         // keep argc / argv for the CLI
    mov x20, x1
    mov w0, #13                         // SIGPIPE
    mov x1, #1                          // SIG_IGN
    bl _signal
    mov w0, w19
    mov x1, x20
    // ---- command line (exits on usage errors, --help, --version) ----
    bl _drv_cli_parse
    MAIN_LDOPT x19, _drv_opt_input
    MAIN_LDOPT x20, _drv_opt_desc
    // ---- read the program ----
    mov x0, x19
    bl _drv_read_file
    cbnz x0, 1f
    // "baysick: cannot read '%s': %s"
    mov x0, x1
    bl _strerror
    mov x2, x0
    mov x1, x19
    MAIN_ADR x0, Lmain_m_read
    bl _drv_diag
    mov w28, #EXIT_USAGE
    b Lmain_exit
1:
    mov x22, x0
    mov x23, x1
    // ---- frontend ----
    bl _ir_module_new
    mov x21, x0
    mov x0, x22
    mov x1, x23
    mov x2, x21
    bl _fe_compile
    cbz w0, 2f
    // BASIC compile error: message, exit 1, nothing written
    bl _drv_basic_error
    mov w28, #EXIT_COMPILE_ERROR
    b Lmain_exit
2:
    // ---- verifier: any failure is an internal error ----
    mov x0, x21
    bl _ir_verify
    cbz x0, 3f
    bl _drv_fatal
3:
    MAIN_LDOPT x24, _drv_opt_output
    add x0, sp, #96
    bl _ob_init
    MAIN_LDOPT x9, _drv_opt_emit_ir
    cbz x9, Lmain_backend
    // ---- --emit-ir: dump to -o file or stdout ----
    mov x0, x21
    add x1, sp, #96
    bl _ir_dump
    cbz x24, 4f
    mov x0, x24
    add x1, sp, #96
    bl Lmain_write_output
    mov w28, w0
    b Lmain_exit
4:
    add x0, sp, #96
    mov w1, #1
    bl _ob_write_fd
    mov w28, #EXIT_OK
    cbz x0, Lmain_exit
    bl ___error
    ldr w0, [x0]
    bl _strerror
    mov x2, x0
    MAIN_ADR x1, Lmain_s_stdout
    MAIN_ADR x0, Lmain_m_write
    bl _drv_diag
    mov w28, #EXIT_USAGE
    b Lmain_exit
Lmain_backend:
    // ---- backend: one complete assembly file into the OutBuf ----
    ldr x9, [x20, #BKD_EMIT]
    mov x0, x21
    add x1, sp, #96
    blr x9
    cbz x0, 5f
    bl _drv_fatal
5:
    // -S, or a target that cannot run its tools here: write the .s only
    MAIN_LDOPT x9, _drv_opt_asm_only
    cbnz x9, 6f
    ldr x9, [x20, #BKD_FLAGS]
    tbnz x9, #0, Lmain_native           // bit 0 = BKF_HOST_NATIVE
6:
    cbnz x24, 7f
    // default name: <stem><asm suffix>
    mov x0, x19
    bl _drv_output_stem
    ldr x1, [x20, #BKD_ASM_SUFFIX]
    mov x2, #0
    bl _drv_strcat3
    mov x24, x0
7:
    mov x0, x24
    add x1, sp, #96
    bl Lmain_write_output
    mov w28, w0
    b Lmain_exit

Lmain_native:
    // ---- default mode: assemble and link through a temp directory ----
    cbnz x24, 8f
    mov x0, x19
    bl _drv_output_stem
    mov x24, x0
8:
    MAIN_ADR x9, Lmain_ph_values
    str x24, [x9, #(8 * PH_EXE)]
    // runtime archive, only if a template wants it
    ldr x0, [x20, #BKD_AS_ARGV]
    mov x1, #PH_RUNTIME
    bl _drv_template_uses
    mov x23, x0
    ldr x0, [x20, #BKD_LD_ARGV]
    mov x1, #PH_RUNTIME
    bl _drv_template_uses
    orr x23, x23, x0
    cbz x23, 9f
    ldr x0, [x20, #BKD_RUNTIME_NAME]
    bl _drv_find_runtime
    mov w28, #EXIT_TOOLCHAIN
    cbz x0, Lmain_exit
    MAIN_ADR x9, Lmain_ph_values
    str x0, [x9, #(8 * PH_RUNTIME)]
9:
    // SDK path, only if a template wants it
    ldr x0, [x20, #BKD_AS_ARGV]
    mov x1, #PH_SDK
    bl _drv_template_uses
    mov x23, x0
    ldr x0, [x20, #BKD_LD_ARGV]
    mov x1, #PH_SDK
    bl _drv_template_uses
    orr x23, x23, x0
    cbz x23, 10f
    bl _drv_find_sdk
    mov w28, #EXIT_TOOLCHAIN
    cbz x0, Lmain_exit
    MAIN_ADR x9, Lmain_ph_values
    str x0, [x9, #(8 * PH_SDK)]
10:
    // temporary directory
    bl _drv_tmpdir_create
    cbnz x0, 11f
    // "baysick: cannot create temporary directory: %s"
    mov x0, x1
    bl _strerror
    mov x1, x0
    mov x2, #0
    MAIN_ADR x0, Lmain_m_tmpdir
    bl _drv_diag
    mov w28, #EXIT_USAGE
    b Lmain_exit
11:
    mov x25, x0
    // <tmp>/prog<asm suffix>, <tmp>/prog<obj suffix>
    MAIN_ADR x1, Lmain_s_prog
    ldr x2, [x20, #BKD_ASM_SUFFIX]
    bl _drv_strcat3
    mov x26, x0
    mov x0, x25
    MAIN_ADR x1, Lmain_s_prog
    ldr x2, [x20, #BKD_OBJ_SUFFIX]
    bl _drv_strcat3
    mov x27, x0
    MAIN_ADR x9, Lmain_ph_values
    str x26, [x9, #(8 * PH_ASM)]
    str x27, [x9, #(8 * PH_OBJ)]
    // record the files for _drv_tmp_cleanup (the directory itself was
    // recorded by _drv_tmpdir_create)
    adrp x9, _drv_tmp_asm@PAGE
    str x26, [x9, _drv_tmp_asm@PAGEOFF]
    adrp x9, _drv_tmp_obj@PAGE
    str x27, [x9, _drv_tmp_obj@PAGEOFF]
    // write the assembly file
    ldr x1, [sp, #96 + OB_DATA]
    ldr x2, [sp, #96 + OB_LEN]
    mov x0, x26
    bl _drv_write_file
    cbz x0, 12f
    // clean up before the diagnostic (stderr may be a broken pipe)
    mov w23, w0
    bl _drv_tmp_cleanup
    mov w0, w23
    bl _strerror
    mov x2, x0
    mov x1, x26
    MAIN_ADR x0, Lmain_m_write
    bl _drv_diag
    mov w28, #EXIT_USAGE
    b Lmain_exit
12:
    // assembler, then linker
    ldr x0, [x20, #BKD_AS_ARGV]
    MAIN_ADR x1, Lmain_ph_values
    bl _drv_subst_argv
    bl _drv_run_tool
    mov w28, w0
    cbnz w28, Lmain_exit
    ldr x0, [x20, #BKD_LD_ARGV]
    MAIN_ADR x1, Lmain_ph_values
    bl _drv_subst_argv
    bl _drv_run_tool
    mov w28, w0

Lmain_exit:
    // ---- remove (or report) the temporary directory, then exit.
    // Failure diagnostics were already printed AFTER cleanup by the
    // failing step; this is the success / --keep-temps path. ----
    cbz x25, Lmain_exit_now
    MAIN_LDOPT x9, _drv_opt_keep_temps
    cbz x9, 13f
    // "baysick: temporary files kept in %s"
    MAIN_ADR x0, Lmain_m_kept
    mov x1, x25
    mov x2, #0
    bl _drv_diag
    b Lmain_exit_now
13:
    bl _drv_tmp_cleanup
Lmain_exit_now:
    mov w0, w28
    bl __exit

// ---------------------------------------------------------------------
// Lmain_write_output -- write an OutBuf to an output file.
//   in:  x0 = path, x1 = OutBuf*
//   out: w0 = EXIT_OK, or EXIT_USAGE after printing
//        "baysick: cannot write '%s': %s"
//   clobbers: x0-x17
//   callee-saved: x19 = path
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .p2align 2
Lmain_write_output:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov x19, x0
    ldr x2, [x1, #OB_LEN]
    ldr x1, [x1, #OB_DATA]
    bl _drv_write_file
    cbz x0, 1f
    bl _strerror
    mov x2, x0
    mov x1, x19
    MAIN_ADR x0, Lmain_m_write
    bl _drv_diag
    mov w0, #EXIT_USAGE
    b 2f
1:
    mov w0, #EXIT_OK
2:
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

    .section __TEXT,__cstring,cstring_literals
Lmain_m_read:   .asciz "cannot read '%s': %s"
Lmain_m_write:  .asciz "cannot write '%s': %s"
Lmain_m_tmpdir: .asciz "cannot create temporary directory: %s"
Lmain_m_kept:   .asciz "temporary files kept in %s"
Lmain_s_stdout: .asciz "<stdout>"
Lmain_s_prog:   .asciz "/prog"

    .section __DATA,__data
    .p2align 3
// substitution values for the argv placeholders, indexed by PH_*
Lmain_ph_values:
    .space 8 * PH_LIMIT
