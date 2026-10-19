// =====================================================================
// include/driver.inc -- services the driver exports to the other compiler
// modules (frontend, ir, backend): arena allocation, output buffers,
// fatal errors. Also the frontend entry point the driver calls.
//
// CONTRACT FILE. See docs/DESIGN.md "Driver services".
// =====================================================================
.ifndef BSK_DRIVER_INC
.equ BSK_DRIVER_INC, 1

// ---- Arena -----------------------------------------------------------------
.equ ARENA_CHUNK,       1048576 // bytes per arena chunk (requests larger than
                                // ARENA_CHUNK/4 get their own malloc)
.equ ARENA_ALIGN,       16
//  _drv_alloc(x0=size) -> x0 = ptr, 16-byte aligned, zero-filled.
//      Never returns NULL: on malloc failure prints
//      "baysick: out of memory\n" to stderr and exits EXIT_INTERNAL.
//      Memory is never freed (process lifetime).

// ---- Output buffer (OB_*), 24 bytes -----------------------------------------
.equ OB_DATA,           0       // ptr  bytes (arena or malloc owned by ob_*)
.equ OB_LEN,            8       // u64  bytes used
.equ OB_CAP,            16      // u64  capacity
.equ OB_SIZE,           24
.equ OB_INITIAL_CAP,    65536
//  _ob_init(x0=OutBuf*)                    empty buffer
//  _ob_putc(x0=OutBuf*, w1=byte)
//  _ob_putn(x0=OutBuf*, x1=ptr, x2=len)
//  _ob_puts(x0=OutBuf*, x1=NUL-terminated string)
//  _ob_putu(x0=OutBuf*, x1=u64)            unsigned decimal, no padding
//  _ob_puti(x0=OutBuf*, x1=s64)            signed decimal, '-' if negative
//  _ob_puthex16(x0=OutBuf*, x1=u64)        exactly 16 UPPERCASE hex digits
//  _ob_putg17(x0=OutBuf*, d0=double)       same text as C printf("%.17g")
//  _ob_write_fd(x0=OutBuf*, w1=fd) -> x0 = 0 ok / -1 on write error
//  All preserve x19-x28 and d8-d15 (AAPCS64).

// ---- Fatal / internal errors -------------------------------------------------
//  _drv_fatal(x0=NUL-terminated reason)    noreturn: prints
//      "baysick: internal error: <reason>\n" to stderr, exit EXIT_INTERNAL.

// ---- Frontend entry point (implemented in src/frontend/) ------------------------
//  _fe_compile(x0=source bytes, x1=source length, x2=Module* from _ir_module_new)
//      -> x0 = ERR_* code (0 = success), x1 = BASIC line number for the
//         message, or 0 when the message carries no line number.
//      On success the Module is complete (all functions, arrays, strings,
//      data, nfors). On error the Module contents are unspecified.

.endif
