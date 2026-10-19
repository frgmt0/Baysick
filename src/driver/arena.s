// =====================================================================
// src/driver/arena.s -- the compiler's bump allocator and fatal exits.
//
//   _drv_alloc(x0=size) -> x0   zeroed, 16-byte aligned, never NULL
//   _drv_fatal(x0=reason)       "baysick: internal error: <reason>", exit 4
//   _drv_oom()                  "baysick: out of memory", exit 4
//   Both remove the temporary directory (_drv_tmp_cleanup) first.
//
// Memory comes from ARENA_CHUNK-sized chunks obtained with calloc (so it
// is already zero-filled); requests larger than ARENA_CHUNK/4 get their
// own calloc block. Nothing is ever freed (DESIGN.md section 3.2).
// =====================================================================
.include "baysick.inc"

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// _drv_alloc -- allocate zeroed arena memory.
//   in:  x0 = size in bytes (0 is allowed and yields a 16-byte block)
//   out: x0 = pointer, 16-byte aligned, zero-filled
//   clobbers: x0-x17 (caller-saved); on calloc failure exits via _drv_oom
//   callee-saved: x19 = rounded request size, x20 = &arena state
//   frame: 32 bytes (frame record + x19/x20)
// ---------------------------------------------------------------------
    .globl _drv_alloc
    .p2align 2
_drv_alloc:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    // round the request up to a multiple of ARENA_ALIGN (minimum one unit)
    add x19, x0, #(ARENA_ALIGN - 1)
    and x19, x19, #~(ARENA_ALIGN - 1)
    cbnz x19, 1f
    mov x19, #ARENA_ALIGN
1:
    // big requests bypass the chunks so they do not waste a whole chunk
    mov x9, #(ARENA_CHUNK / 4)
    cmp x19, x9
    b.hi Ldrv_alloc_big
    // state: [x20] = next free byte, [x20+8] = end of the current chunk
    adrp x20, Ldrv_arena_state@PAGE
    add x20, x20, Ldrv_arena_state@PAGEOFF
    ldp x10, x11, [x20]
    sub x12, x11, x10                   // bytes left in the chunk
    cmp x19, x12
    b.hi Ldrv_alloc_newchunk
    // fits: bump the pointer
    add x12, x10, x19
    str x12, [x20]
    mov x0, x10
    b Ldrv_alloc_done
Ldrv_alloc_newchunk:
    // abandon the tail of the old chunk, take a fresh zeroed chunk
    mov x0, #1
    mov x1, #ARENA_CHUNK
    bl _calloc
    cbz x0, Ldrv_alloc_oom
    add x10, x0, x19                    // first byte after this request
    mov x11, #ARENA_CHUNK
    add x11, x0, x11                    // end of the chunk
    stp x10, x11, [x20]
    b Ldrv_alloc_done
Ldrv_alloc_big:
    // dedicated zeroed block (calloc memory is 16-byte aligned on Darwin)
    mov x0, #1
    mov x1, x19
    bl _calloc
    cbz x0, Ldrv_alloc_oom
Ldrv_alloc_done:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
Ldrv_alloc_oom:
    bl _drv_oom

// ---------------------------------------------------------------------
// _drv_fatal -- report an internal error and exit EXIT_INTERNAL.
//   The temporary directory, if any, is removed before the message.
//   in:  x0 = NUL-terminated reason
//   out: does not return
//   clobbers: everything caller-saved
//   callee-saved: x19 = reason
//   frame: 32 bytes (frame record, x19)
// ---------------------------------------------------------------------
    .globl _drv_fatal
    .p2align 2
_drv_fatal:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov x19, x0
    bl _drv_tmp_cleanup
    // "baysick: internal error: %s"
    mov x1, x19
    mov x2, #0
    adrp x0, Ldrv_fatal_fmt@PAGE
    add x0, x0, Ldrv_fatal_fmt@PAGEOFF
    bl _drv_diag
    mov w0, #EXIT_INTERNAL
    bl __exit

// ---------------------------------------------------------------------
// _drv_oom -- report out of memory and exit EXIT_INTERNAL. Uses a plain
// write(2) of a static message so it never needs to allocate. The
// temporary directory, if any, is removed before the message.
//   in:  none
//   out: does not return
//   clobbers: everything caller-saved; callee-saved: none
//   frame: 16 bytes (frame record)
// ---------------------------------------------------------------------
    .globl _drv_oom
    .p2align 2
_drv_oom:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    // remove the temp dir first (_drv_tmp_cleanup never allocates)
    bl _drv_tmp_cleanup
    mov w0, #2                          // stderr
    adrp x1, Ldrv_oom_msg@PAGE
    add x1, x1, Ldrv_oom_msg@PAGEOFF
    mov x2, #(Ldrv_oom_msg_end - Ldrv_oom_msg)
    bl _write
    mov w0, #EXIT_INTERNAL
    bl __exit

    .section __TEXT,__cstring,cstring_literals
Ldrv_fatal_fmt:
    .asciz "internal error: %s"
Ldrv_oom_msg:
    .ascii "baysick: out of memory\n"
Ldrv_oom_msg_end:
    .byte 0

    .section __DATA,__data
    .p2align 3
// [0] next free byte of the current chunk, [8] end of the current chunk
// (both 0 initially, so the first request takes a new chunk)
Ldrv_arena_state:
    .quad 0
    .quad 0
