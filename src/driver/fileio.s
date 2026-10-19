// =====================================================================
// src/driver/fileio.s -- whole-file read and write, string helpers.
//
//   _drv_read_file(x0=path)              -> x0 = bytes (0 on error),
//                                           x1 = length, or errno on error
//   _drv_write_file(x0=path, x1=ptr, x2=len) -> x0 = 0 or errno
//   _drv_strcat3(x0=a, x1=b, x2=c)       -> x0 = new arena string a+b+c
//                                           (a NULL part counts as "")
// =====================================================================
.include "baysick.inc"

.equ Ldrv_O_RDONLY,      0x0000
.equ Ldrv_O_WRONLY,      0x0001
.equ Ldrv_O_CREAT,       0x0200
.equ Ldrv_O_TRUNC,       0x0400
.equ Ldrv_EINTR,         4
.equ Ldrv_STAT_SIZE,     144         // sizeof(struct stat), Darwin arm64
.equ Ldrv_STAT_ST_SIZE,  96          // offsetof(struct stat, st_size)
.equ Ldrv_READ_MIN,      4096        // minimum initial read buffer

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _drv_read_file -- read a whole file into arena memory, but at most
// LIM_SOURCE_BYTES + 1 bytes: anything longer is reported by the frontend
// as PROGRAM TOO LONG, and a length of LIMIT + 1 is enough to tell.
// (Without the cap, `baysick /dev/zero` would read until out of memory.)
//   in:  x0 = NUL-terminated path
//   out: success: x0 = buffer (arena, one spare byte), x1 = byte count
//        (<= LIM_SOURCE_BYTES + 1)
//        failure: x0 = 0, x1 = errno
//   clobbers: x0-x17
//   callee-saved: x19 = fd, x20 = buffer, x21 = bytes read,
//                 x22 = buffer capacity, x23 = errno on failure
//   frame: 64 + Ldrv_STAT_SIZE bytes (frame record, x19-x23, struct stat)
// ---------------------------------------------------------------------
    .globl _drv_read_file
    .p2align 2
_drv_read_file:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]
    sub sp, sp, #Ldrv_STAT_SIZE
    // fd = open(path, O_RDONLY)
    mov w1, #Ldrv_O_RDONLY
    bl _open
    tbnz w0, #31, Ldrv_read_errno
    mov w19, w0
    // the size from fstat is only a capacity hint; reading goes to EOF
    // or to LIM_SOURCE_BYTES + 1 bytes, whichever comes first
    mov w0, w19
    mov x1, sp
    bl _fstat
    tbnz w0, #31, Ldrv_read_errno_close
    ldr x22, [sp, #Ldrv_STAT_ST_SIZE]
    add x22, x22, #1                    // room to see EOF without growing
    mov x9, #Ldrv_READ_MIN
    cmp x22, x9
    csel x22, x22, x9, hs
    // never more than limit + 1 bytes of data + the spare byte
    mov x9, #LIM_SOURCE_BYTES
    add x9, x9, #2
    cmp x22, x9
    csel x22, x22, x9, ls
    mov x0, x22
    bl _drv_alloc
    mov x20, x0
    mov x21, #0
Ldrv_read_loop:
    // grow (double, at most to limit + 2) when full; this also keeps
    // the spare byte after the data
    cmp x21, x22
    b.lo 1f
    lsl x22, x22, #1
    mov x9, #LIM_SOURCE_BYTES
    add x9, x9, #2
    cmp x22, x9
    csel x22, x22, x9, ls
    mov x0, x22
    bl _drv_alloc
    mov x1, x20
    mov x2, x21
    mov x20, x0
    bl _memcpy
1:
    // stop once over the source limit: the frontend only needs to see
    // that the file is too long (PROGRAM TOO LONG), not all of it
    mov x9, #LIM_SOURCE_BYTES
    cmp x21, x9
    b.hi Ldrv_read_eof
    // read min(capacity - len, limit + 1 - len) bytes (>= 1 here)
    mov w0, w19
    add x1, x20, x21
    add x2, x9, #1
    sub x2, x2, x21
    sub x9, x22, x21
    cmp x2, x9
    csel x2, x2, x9, ls
    bl _read
    tbnz x0, #63, Ldrv_read_rderr
    cbz x0, Ldrv_read_eof
    add x21, x21, x0
    b Ldrv_read_loop
Ldrv_read_rderr:
    bl ___error
    ldr w9, [x0]
    cmp w9, #Ldrv_EINTR
    b.eq Ldrv_read_loop
    b Ldrv_read_errno_close
Ldrv_read_eof:
    mov w0, w19
    bl _close
    mov x0, x20
    mov x1, x21
    b Ldrv_read_done
Ldrv_read_errno_close:
    // remember errno before close() can change it
    bl ___error
    ldr w23, [x0]
    mov w0, w19
    bl _close
    mov x0, #0
    mov x1, x23
    b Ldrv_read_done
Ldrv_read_errno:
    bl ___error
    ldr w1, [x0]
    mov x0, #0
Ldrv_read_done:
    add sp, sp, #Ldrv_STAT_SIZE
    ldr x23, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

// ---------------------------------------------------------------------
// _drv_write_file -- create/truncate a file and write bytes to it.
//   in:  x0 = path, x1 = bytes, x2 = length
//   out: x0 = 0 on success, else errno
//   clobbers: x0-x17
//   callee-saved: x19 = fd, x20 = cursor, x21 = bytes left,
//                 x22 = errno on failure
//   frame: 64 bytes (frame record, x19-x22, variadic slot area)
// ---------------------------------------------------------------------
    .globl _drv_write_file
    .p2align 2
_drv_write_file:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov x20, x1
    mov x21, x2
    // open(path, O_WRONLY|O_CREAT|O_TRUNC, 0644): the mode is variadic,
    // so it goes in the first stack slot
    sub sp, sp, #16
    mov x9, #0644
    str x9, [sp]
    mov w1, #(Ldrv_O_WRONLY | Ldrv_O_CREAT | Ldrv_O_TRUNC)
    bl _open
    add sp, sp, #16
    tbnz w0, #31, Ldrv_write_errno
    mov w19, w0
Ldrv_write_loop:
    cbz x21, Ldrv_write_close
    mov w0, w19
    mov x1, x20
    mov x2, x21
    bl _write
    tbnz x0, #63, Ldrv_write_wrerr
    add x20, x20, x0
    sub x21, x21, x0
    b Ldrv_write_loop
Ldrv_write_wrerr:
    bl ___error
    ldr w22, [x0]
    cmp w22, #Ldrv_EINTR
    b.eq Ldrv_write_loop
    mov w0, w19
    bl _close
    mov x0, x22
    b Ldrv_write_done
Ldrv_write_close:
    // close() can report a deferred write error
    mov w0, w19
    bl _close
    tbnz w0, #31, Ldrv_write_errno
    mov x0, #0
    b Ldrv_write_done
Ldrv_write_errno:
    bl ___error
    ldr w0, [x0]
Ldrv_write_done:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

// ---------------------------------------------------------------------
// _drv_strcat3 -- concatenate up to three strings into arena memory.
//   in:  x0 = a, x1 = b, x2 = c (each NUL-terminated or NULL = empty)
//   out: x0 = new NUL-terminated string
//   clobbers: x0-x17
//   callee-saved: x19-x21 = a, b, c; x22-x24 = their lengths;
//                 x25 = result, x26 = write cursor
//   frame: 80 bytes
// ---------------------------------------------------------------------
    .globl _drv_strcat3
    .p2align 2
_drv_strcat3:
    stp x29, x30, [sp, #-80]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    mov x19, x0
    mov x20, x1
    mov x21, x2
    // lengths (NULL -> 0)
    mov x22, #0
    cbz x19, 1f
    mov x0, x19
    bl _strlen
    mov x22, x0
1:
    mov x23, #0
    cbz x20, 2f
    mov x0, x20
    bl _strlen
    mov x23, x0
2:
    mov x24, #0
    cbz x21, 3f
    mov x0, x21
    bl _strlen
    mov x24, x0
3:
    // zeroed block of total+1 bytes, so the terminator is already there
    add x0, x22, x23
    add x0, x0, x24
    add x0, x0, #1
    bl _drv_alloc
    mov x25, x0
    mov x26, x0
    // copy the three parts back to back (empty/NULL parts are skipped)
    cbz x22, 4f
    mov x0, x26
    mov x1, x19
    mov x2, x22
    bl _memcpy
    add x26, x26, x22
4:
    cbz x23, 5f
    mov x0, x26
    mov x1, x20
    mov x2, x23
    bl _memcpy
    add x26, x26, x23
5:
    cbz x24, 6f
    mov x0, x26
    mov x1, x21
    mov x2, x24
    bl _memcpy
6:
    mov x0, x25
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #80
    ret
