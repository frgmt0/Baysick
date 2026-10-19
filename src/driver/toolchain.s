// =====================================================================
// src/driver/toolchain.s -- running the external assembler and linker.
//
//   _drv_tmpdir_create()              -> x0 = new directory path, or 0
//                                        with x1 = errno
//   _drv_find_runtime(x0=archive name) -> x0 = path, or 0 (message printed)
//   _drv_find_sdk()                   -> x0 = SDK path, or 0 (message printed)
//   _drv_template_uses(x0=argv template, x1=PH_*) -> x0 = 1 if present, else 0
//   _drv_subst_argv(x0=argv template, x1=values[PH_LIMIT]) -> x0 = argv
//   _drv_run_tool(x0=argv)            -> x0 = 0 on success, else
//                                        EXIT_TOOLCHAIN (message printed,
//                                        temp dir removed first)
//   _drv_tmp_cleanup()                remove the temp dir (unless
//                                     --keep-temps); idempotent, no malloc
//   _drv_tmp_dir / _drv_tmp_asm / _drv_tmp_obj   (u64 pointers, 0 = none)
//                                     the temp dir and its files, recorded
//                                     for _drv_tmp_cleanup
//
// DESIGN.md sections 4.3-4.5 and 5.2. Tools are started with posix_spawnp
// (PATH search), inheriting stdin/stdout/stderr and the environment minus
// every SDKROOT entry, with SIGPIPE reset to its default action.
// =====================================================================
.include "baysick.inc"

.equ Ldrv_EINTR,        4
.equ Ldrv_R_OK,         4
.equ Ldrv_PATH_BUF,     1024        // initial executable-path buffer (MAXPATHLEN)
.equ Ldrv_SIGPIPE,      13
.equ Ldrv_SPAWN_SETSIGDEF, 0x0004   // POSIX_SPAWN_SETSIGDEF (Darwin)

    .section __TEXT,__text,regular,pure_instructions

.macro TC_ADR reg, sym
    adrp \reg, \sym@PAGE
    add \reg, \reg, \sym@PAGEOFF
.endm

// ---------------------------------------------------------------------
// _drv_tmpdir_create -- mkdtemp("$TMPDIR/baysick.XXXXXX").
//   $TMPDIR loses its trailing '/' characters; "/tmp" if unset or empty.
//   in:  none
//   out: x0 = arena path of the new directory, or 0 and x1 = errno
//   clobbers: x0-x17
//   callee-saved: x19 = TMPDIR text, x20 = its trimmed length,
//                 x21 = path buffer
//   frame: 48 bytes
// ---------------------------------------------------------------------
    .globl _drv_tmpdir_create
    .p2align 2
_drv_tmpdir_create:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    TC_ADR x0, Ltc_env_tmpdir
    bl _getenv
    mov x19, x0
    cbz x19, 1f
    ldrb w9, [x19]
    cbnz w9, 2f
1:
    TC_ADR x19, Ltc_default_tmp
2:
    mov x0, x19
    bl _strlen
    mov x20, x0
    // drop trailing slashes
3:
    cbz x20, 4f
    sub x9, x20, #1
    ldrb w10, [x19, x9]
    cmp w10, #'/'
    b.ne 4f
    mov x20, x9
    b 3b
4:
    // buffer = TMPDIR[0..len) + "/baysick.XXXXXX" + NUL (zeroed by the arena)
    add x0, x20, #(Ltc_template_end - Ltc_template + 1)
    bl _drv_alloc
    mov x21, x0
    mov x1, x19
    mov x2, x20
    bl _memcpy
    add x0, x21, x20
    TC_ADR x1, Ltc_template
    bl _strcpy
    mov x0, x21
    bl _mkdtemp
    cbz x0, 6f
    // record it so every exit path (including fatal ones) can remove it
    adrp x9, _drv_tmp_dir@PAGE
    str x0, [x9, _drv_tmp_dir@PAGEOFF]
    b 5f
6:
    bl ___error
    ldr w1, [x0]
    mov x0, #0
5:
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// _drv_find_runtime -- locate the runtime archive (DESIGN.md 4.4).
//   $BAYSICK_RUNTIME if set and non-empty, else <dir of the compiler
//   executable, symlinks resolved>/<name>. Must be readable.
//   in:  x0 = archive file name (BKD_RUNTIME_NAME)
//   out: x0 = path, or 0 after printing "cannot find runtime library"
//   clobbers: x0-x17
//   callee-saved: x19 = name, x20 = executable path buffer,
//                 x21 = resolved path, x22 = candidate result
//   frame: 64 bytes ([sp,#48] = u32 buffer size for _NSGetExecutablePath)
// ---------------------------------------------------------------------
    .globl _drv_find_runtime
    .p2align 2
_drv_find_runtime:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov x19, x0
    TC_ADR x0, Ltc_env_runtime
    bl _getenv
    mov x22, x0
    cbz x22, 1f
    ldrb w9, [x22]
    cbnz w9, Ltc_rt_check
1:
    // executable path; retry once with the size the call asks for
    mov w9, #Ldrv_PATH_BUF
    str w9, [sp, #48]
    mov x0, #Ldrv_PATH_BUF
    bl _drv_alloc
    mov x20, x0
    add x1, sp, #48
    bl __NSGetExecutablePath
    cbz w0, 2f
    ldr w0, [sp, #48]
    bl _drv_alloc
    mov x20, x0
    add x1, sp, #48
    bl __NSGetExecutablePath
2:
    // resolve symlinks; on failure keep the unresolved path
    mov x0, x20
    mov x1, #0
    bl _realpath
    mov x21, x0
    cbnz x21, 3f
    mov x21, x20
3:
    // keep everything up to and including the last '/'
    mov x0, x21
    mov w1, #'/'
    bl _strrchr
    cbz x0, 4f
    strb wzr, [x0, #1]
    mov x0, x21
    mov x1, x19
    mov x2, #0
    bl _drv_strcat3
    mov x22, x0
    b Ltc_rt_check
4:
    mov x22, x19                        // no directory part at all
Ltc_rt_check:
    mov x0, x22
    mov w1, #Ldrv_R_OK
    bl _access
    cbz w0, Ltc_rt_ok
    // "baysick: cannot find runtime library '%s'"
    TC_ADR x0, Ltc_m_runtime
    mov x1, x22
    mov x2, #0
    bl _drv_diag
    mov x22, #0
Ltc_rt_ok:
    mov x0, x22
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

// ---------------------------------------------------------------------
// _drv_find_sdk -- macOS SDK path (DESIGN.md 4.5): $SDKROOT if set and
// non-empty, else the first line of `xcrun --show-sdk-path` (stdout
// through a pipe; same environment and signal setup as _drv_run_tool).
// xcrun's stderr passes through. Either way the result must be a real
// SDK: <sdk>/SDKSettings.plist or <sdk>/SDKSettings.json readable.
//   in:  none
//   out: x0 = arena path, or 0 after printing
//        "cannot determine macOS SDK path"
//   clobbers: x0-x17
//   callee-saved: x19 = result / scratch, x20 = pipe read fd,
//                 x21 = pipe write fd, x22 = spawn result
//   frame: 128 bytes: [sp,#48] file actions, [sp,#56] pid,
//          [sp,#60] wait status, [sp,#64] pipe fds (2 x int),
//          [sp,#72] argv (3 pointers), [sp,#96] OutBuf,
//          [sp,#120] spawn attributes
// ---------------------------------------------------------------------
    .globl _drv_find_sdk
    .p2align 2
_drv_find_sdk:
    stp x29, x30, [sp, #-128]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    TC_ADR x0, Ltc_env_sdkroot
    bl _getenv
    mov x19, x0
    cbz x19, 1f
    ldrb w9, [x19]
    cbnz w9, Ltc_sdk_check
1:
    // pipe for xcrun's stdout
    add x0, sp, #64
    bl _pipe
    cbnz w0, Ltc_sdk_fail
    ldp w20, w21, [sp, #64]
    // child: dup2(write end, 1), close both pipe fds
    add x0, sp, #48
    bl _posix_spawn_file_actions_init
    add x0, sp, #48
    mov w1, w21
    mov w2, #1
    bl _posix_spawn_file_actions_adddup2
    add x0, sp, #48
    mov w1, w20
    bl _posix_spawn_file_actions_addclose
    add x0, sp, #48
    mov w1, w21
    bl _posix_spawn_file_actions_addclose
    // argv = { "xcrun", "--show-sdk-path", NULL }
    TC_ADR x9, Ltc_s_xcrun
    TC_ADR x10, Ltc_s_showsdk
    stp x9, x10, [sp, #72]
    str xzr, [sp, #88]
    // SIGPIPE back to default in the child
    add x0, sp, #120
    bl Ltc_attr_init
    // environment without SDKROOT
    bl Ltc_tool_env
    mov x5, x0                          // envp
    add x0, sp, #56                     // &pid
    TC_ADR x1, Ltc_s_xcrun
    add x2, sp, #48                     // file actions
    add x3, sp, #120                    // attributes
    add x4, sp, #72                     // argv
    bl _posix_spawnp
    mov w22, w0
    add x0, sp, #120
    bl _posix_spawnattr_destroy
    add x0, sp, #48
    bl _posix_spawn_file_actions_destroy
    // the parent keeps only the read end
    mov w0, w21
    bl _close
    cbnz w22, Ltc_sdk_fail_close
    // collect all of xcrun's output
    add x0, sp, #96
    bl _ob_init
Ltc_sdk_read:
    add x0, sp, #96
    mov x1, #1024
    bl _ob_reserve
    mov x1, x0
    mov w0, w20
    mov x2, #1024
    bl _read
    tbnz x0, #63, Ltc_sdk_rderr
    cbz x0, Ltc_sdk_eof
    ldr x9, [sp, #96 + OB_LEN]
    add x9, x9, x0
    str x9, [sp, #96 + OB_LEN]
    b Ltc_sdk_read
Ltc_sdk_rderr:
    bl ___error
    ldr w9, [x0]
    cmp w9, #Ldrv_EINTR
    b.eq Ltc_sdk_read
Ltc_sdk_eof:
    mov w0, w20
    bl _close
    // reap xcrun; it must exit 0
    ldr w0, [sp, #56]
    bl Ltc_wait
    cbnz w0, Ltc_sdk_fail_free
    // NUL-terminate, cut at the first LF
    add x0, sp, #96
    mov w1, #0
    bl _ob_putc
    ldr x0, [sp, #96 + OB_DATA]
    mov w1, #'\n'
    bl _strchr
    cbz x0, 2f
    strb wzr, [x0]
2:
    ldr x0, [sp, #96 + OB_DATA]
    ldrb w9, [x0]
    cbz w9, Ltc_sdk_fail_free           // empty answer
    // copy into the arena, release the buffer
    mov x1, #0
    mov x2, #0
    bl _drv_strcat3
    mov x19, x0
    ldr x0, [sp, #96 + OB_DATA]
    bl _free
Ltc_sdk_check:
    // x19 = candidate SDK; it must carry SDKSettings.plist or .json
    mov x0, x19
    TC_ADR x1, Ltc_s_sdk_plist
    mov x2, #0
    bl _drv_strcat3
    mov w1, #Ldrv_R_OK
    bl _access
    cbz w0, Ltc_sdk_done
    mov x0, x19
    TC_ADR x1, Ltc_s_sdk_json
    mov x2, #0
    bl _drv_strcat3
    mov w1, #Ldrv_R_OK
    bl _access
    cbz w0, Ltc_sdk_done
    b Ltc_sdk_fail
Ltc_sdk_fail_free:
    ldr x0, [sp, #96 + OB_DATA]
    bl _free
    b Ltc_sdk_fail
Ltc_sdk_fail_close:
    mov w0, w20
    bl _close
Ltc_sdk_fail:
    TC_ADR x0, Ltc_m_sdk
    mov x1, #0
    mov x2, #0
    bl _drv_diag
    mov x19, #0
Ltc_sdk_done:
    mov x0, x19
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #128
    ret

// ---------------------------------------------------------------------
// Ltc_wait -- waitpid with EINTR retry; turn the status into a number.
//   in:  w0 = pid
//   out: w0 = exit status of the child (0..255); 128+signal if it was
//        killed by a signal; -1 if waitpid failed (errno set)
//   clobbers: x0-x17
//   callee-saved: x19 = pid
//   frame: 32 bytes ([sp,#24] = raw status)
// ---------------------------------------------------------------------
    .p2align 2
Ltc_wait:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov w19, w0
1:
    mov w0, w19
    add x1, sp, #24
    mov w2, #0
    bl _waitpid
    tbz w0, #31, 2f
    bl ___error
    ldr w9, [x0]
    cmp w9, #Ldrv_EINTR
    b.eq 1b
    mov w0, #-1
    b 3f
2:
    ldr w9, [sp, #24]
    and w10, w9, #0x7F                  // WTERMSIG / stopped marker
    cbnz w10, 4f
    ubfx w0, w9, #8, #8                 // WEXITSTATUS
    b 3f
4:
    add w0, w10, #128                   // killed by signal n -> 128+n
3:
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _drv_template_uses -- does an argv template contain a placeholder?
//   in:  x0 = NULL-terminated template, x1 = PH_* value
//   out: x0 = 1 if present, else 0
//   clobbers: x0, x9    (leaf)
// ---------------------------------------------------------------------
    .globl _drv_template_uses
    .p2align 2
_drv_template_uses:
1:
    ldr x9, [x0], #8
    cbz x9, 2f
    cmp x9, x1
    b.ne 1b
    mov x0, #1
    ret
2:
    mov x0, #0
    ret

// ---------------------------------------------------------------------
// _drv_subst_argv -- build a real argv from a template (DESIGN.md 5.2).
//   in:  x0 = template (entries < PH_LIMIT are placeholders),
//        x1 = values[PH_LIMIT] (string per placeholder number, 0 = none)
//   out: x0 = arena argv, NULL-terminated; an unresolved placeholder is
//        an internal error
//   clobbers: x0-x17
//   callee-saved: x19 = template, x20 = values, x21 = result
//   frame: 48 bytes
// ---------------------------------------------------------------------
    .globl _drv_subst_argv
    .p2align 2
_drv_subst_argv:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov x19, x0
    mov x20, x1
    // count entries (+1 for the terminator)
    mov x9, x19
    mov x0, #8
1:
    ldr x10, [x9], #8
    add x0, x0, #8
    cbnz x10, 1b
    bl _drv_alloc                       // zeroed: terminator already 0
    mov x21, x0
    mov x11, x0
2:
    ldr x10, [x19], #8
    cbz x10, 4f
    cmp x10, #PH_LIMIT
    b.hs 3f
    // placeholder: take its value
    ldr x10, [x20, x10, lsl #3]
    cbz x10, Ltc_subst_bad
3:
    str x10, [x11], #8
    b 2b
4:
    mov x0, x21
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
Ltc_subst_bad:
    TC_ADR x0, Ltc_m_subst
    bl _drv_fatal

// ---------------------------------------------------------------------
// _drv_run_tool -- posix_spawnp argv[0] and wait for it.
//   The child gets the environment without SDKROOT (Ltc_tool_env) and
//   SIGPIPE at its default action (the compiler itself ignores it).
//   On failure the temporary directory is removed (_drv_tmp_cleanup)
//   BEFORE the diagnostic is written, so a broken stderr cannot leak it.
//   in:  x0 = NULL-terminated argv
//   out: x0 = 0 if the tool exited with status 0, else EXIT_TOOLCHAIN
//        after printing "cannot run '%s': %s" or "'%s' failed with
//        exit status %d" (128+n for a tool killed by signal n)
//   clobbers: x0-x17
//   callee-saved: x19 = argv, x20 = error number / status
//   frame: 48 bytes ([sp,#32] = pid, [sp,#40] = spawn attributes)
// ---------------------------------------------------------------------
    .globl _drv_run_tool
    .p2align 2
_drv_run_tool:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    add x0, sp, #40
    bl Ltc_attr_init
    bl Ltc_tool_env
    mov x5, x0                          // envp without SDKROOT
    add x0, sp, #32                     // &pid
    ldr x1, [x19]                       // program name, PATH-searched
    mov x2, #0
    add x3, sp, #40                     // attributes
    mov x4, x19
    bl _posix_spawnp
    mov w20, w0
    add x0, sp, #40
    bl _posix_spawnattr_destroy
    mov w0, w20
    cbnz w0, Ltc_run_cannot
    ldr w0, [sp, #32]
    bl Ltc_wait
    tbnz w0, #31, Ltc_run_waiterr
    cbz w0, Ltc_run_done
    // "baysick: '%s' failed with exit status %d" -- after cleanup
    mov w20, w0
    bl _drv_tmp_cleanup
    mov w2, w20
    ldr x1, [x19]
    TC_ADR x0, Ltc_m_failed
    bl _drv_diag
    mov x0, #EXIT_TOOLCHAIN
    b Ltc_run_done
Ltc_run_waiterr:
    bl ___error
    ldr w0, [x0]
Ltc_run_cannot:
    // "baysick: cannot run '%s': %s" -- after cleanup
    mov w20, w0
    bl _drv_tmp_cleanup
    mov w0, w20
    bl _strerror
    mov x2, x0
    ldr x1, [x19]
    TC_ADR x0, Ltc_m_cannot
    bl _drv_diag
    mov x0, #EXIT_TOOLCHAIN
Ltc_run_done:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// Ltc_attr_init -- spawn attributes that reset SIGPIPE to SIG_DFL in the
// child (the compiler ignores SIGPIPE, and ignored signals are inherited).
//   in:  x0 = posix_spawnattr_t* (caller destroys it after spawning)
//   out: none
//   clobbers: x0-x17
//   callee-saved: x19 = attr pointer
//   frame: 32 bytes ([sp,#24] = sigset_t holding SIGPIPE)
// ---------------------------------------------------------------------
    .p2align 2
Ltc_attr_init:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov x19, x0
    bl _posix_spawnattr_init
    // sigset = { SIGPIPE }: bit (signo - 1)
    mov w9, #(1 << (Ldrv_SIGPIPE - 1))
    str w9, [sp, #24]
    mov x0, x19
    add x1, sp, #24
    bl _posix_spawnattr_setsigdefault
    mov x0, x19
    mov w1, #Ldrv_SPAWN_SETSIGDEF
    bl _posix_spawnattr_setflags
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Ltc_tool_env -- the environment handed to every spawned tool: the
// compiler's own environment with every "SDKROOT=..." entry removed (the
// SDK reaches ld explicitly through -syslibroot; a stray SDKROOT must
// never reach the /usr/bin tool shims). Built once, then cached.
//   in:  none
//   out: x0 = NULL-terminated envp (arena)
//   clobbers: x0-x17
//   callee-saved: x19 = environ cursor, x20 = count / current entry,
//                 x21 = result, x22 = write cursor
//   frame: 48 bytes
// ---------------------------------------------------------------------
    .p2align 2
Ltc_tool_env:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    adrp x9, Ltc_envp_cache@PAGE
    ldr x0, [x9, Ltc_envp_cache@PAGEOFF]
    cbnz x0, Ltc_env_ret
    bl __NSGetEnviron
    ldr x19, [x0]                       // environ (may be NULL)
    // count the entries
    mov x20, #0
    cbz x19, 2f
1:
    ldr x9, [x19, x20, lsl #3]
    cbz x9, 2f
    add x20, x20, #1
    b 1b
2:
    // zeroed array of count+1 pointers: the terminator is already there
    add x0, x20, #1
    lsl x0, x0, #3
    bl _drv_alloc
    mov x21, x0
    mov x22, x0
    cbz x19, 4f
3:
    // copy every entry that does not start with "SDKROOT="
    ldr x20, [x19], #8
    cbz x20, 4f
    mov x0, x20
    TC_ADR x1, Ltc_s_sdkroot_eq
    mov x2, #(Ltc_s_sdkroot_eq_end - Ltc_s_sdkroot_eq)
    bl _strncmp
    cbz w0, 3b                          // drop it
    str x20, [x22], #8
    b 3b
4:
    adrp x9, Ltc_envp_cache@PAGE
    str x21, [x9, Ltc_envp_cache@PAGEOFF]
    mov x0, x21
Ltc_env_ret:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// _drv_tmp_cleanup -- remove the temporary directory recorded in
// _drv_tmp_dir (with _drv_tmp_asm / _drv_tmp_obj inside it), unless
// --keep-temps. Clears the record, so it is safe to call more than once.
// Never allocates (used by _drv_oom) and never writes diagnostics.
//   in:  none
//   out: none
//   clobbers: x0-x17
//   callee-saved: x19 = directory path
//   frame: 32 bytes
// ---------------------------------------------------------------------
    .globl _drv_tmp_cleanup
    .p2align 2
_drv_tmp_cleanup:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    adrp x9, _drv_tmp_dir@PAGE
    ldr x19, [x9, _drv_tmp_dir@PAGEOFF]
    cbz x19, 3f                         // no directory was created
    adrp x9, _drv_opt_keep_temps@PAGE
    ldr x9, [x9, _drv_opt_keep_temps@PAGEOFF]
    cbnz x9, 3f                         // --keep-temps: leave it alone
    // forget it first, so nothing can try twice
    adrp x9, _drv_tmp_dir@PAGE
    str xzr, [x9, _drv_tmp_dir@PAGEOFF]
    adrp x9, _drv_tmp_asm@PAGE
    ldr x0, [x9, _drv_tmp_asm@PAGEOFF]
    str xzr, [x9, _drv_tmp_asm@PAGEOFF]
    cbz x0, 1f
    bl _unlink                          // ENOENT is fine
1:
    adrp x9, _drv_tmp_obj@PAGE
    ldr x0, [x9, _drv_tmp_obj@PAGEOFF]
    str xzr, [x9, _drv_tmp_obj@PAGEOFF]
    cbz x0, 2f
    bl _unlink
2:
    mov x0, x19
    bl _rmdir
3:
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

    .section __TEXT,__cstring,cstring_literals
Ltc_env_tmpdir:     .asciz "TMPDIR"
Ltc_env_runtime:    .asciz "BAYSICK_RUNTIME"
Ltc_env_sdkroot:    .asciz "SDKROOT"
Ltc_default_tmp:    .asciz "/tmp"
Ltc_template:       .ascii "/baysick.XXXXXX"
Ltc_template_end:   .byte 0
Ltc_s_xcrun:        .asciz "xcrun"
Ltc_s_showsdk:      .asciz "--show-sdk-path"
Ltc_m_runtime:      .asciz "cannot find runtime library '%s'"
Ltc_m_sdk:          .asciz "cannot determine macOS SDK path"
Ltc_m_cannot:       .asciz "cannot run '%s': %s"
Ltc_m_failed:       .asciz "'%s' failed with exit status %d"
Ltc_m_subst:        .asciz "unresolved placeholder in a backend argv template"
Ltc_s_sdk_plist:    .asciz "/SDKSettings.plist"
Ltc_s_sdk_json:     .asciz "/SDKSettings.json"
Ltc_s_sdkroot_eq:   .ascii "SDKROOT="
Ltc_s_sdkroot_eq_end: .byte 0

    .section __DATA,__data
    .p2align 3
// temporary directory and the files in it (0 = none); see _drv_tmp_cleanup
    .globl _drv_tmp_dir
_drv_tmp_dir:       .quad 0
    .globl _drv_tmp_asm
_drv_tmp_asm:       .quad 0
    .globl _drv_tmp_obj
_drv_tmp_obj:       .quad 0
// cached tool environment (Ltc_tool_env), 0 until first built
Ltc_envp_cache:     .quad 0
