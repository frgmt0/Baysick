// =====================================================================
// src/runtime/rt_files.s -- the Fifth Edition file layer: file numbers,
// modes, opening, SCRATCH #, RESTORE #, IF END # and the finishing of
// the files at termination (LANGUAGE.md 7.21-7.26, 10; DESIGN.md 6.8).
//
// Defines (global, runtime.inc):
//   _bsk_fsel _bsk_feof _bsk_scratch _bsk_frestore
// Defines (private to the runtime, .private_extern):
//   _bsk_rt_file_wcheck   PRINT #k: file k must be in write mode
//   _bsk_rt_file_ropen    INPUT #k / IF END #k: read mode, open if needed
//   _bsk_rt_files_finish  termination: finish the files in write mode
// Uses (defined by every Fifth Edition program): _bsk_files (SD[], the
// FILES names, entry k-1 = file #k), _bsk_files_count (u64).
// Uses (runtime): _bsk_rt_fsel, _bsk_rt_out_begin, _bsk_rt_out_end,
// _bsk_rt_out_failed (rt_print.s: the output side of a file),
// _bsk_rt_rd_setup, _bsk_rt_rd_reset, _bsk_rt_rd_atend (rt_input.s: the
// reader of a file), _bsk_err.
//
// File table (runtime-private, indexed by the file number k, 1 ..
// LIM_FILES; entry 0 unused; records beyond _bsk_files_count are never
// touched): the mode (Lrt_files_mode, one byte: RT_FM_CLOSED "read, not
// open" -- the zero initial state --, RT_FM_READ "read, open",
// RT_FM_WRITE "write") and the fd (Lrt_files_fd). Each file's output
// state (col, out, buffer, "write failed" flag) lives in rt_print.s and
// its reader (chunk, line, cursor) in rt_input.s, so the column logic
// and the line reader serve standard input/output and the files alike.
//
// Host interface: open(2) is variadic, so its mode argument goes on the
// stack (DESIGN.md 3.1). macOS values: O_RDONLY 0, O_WRONLY 1, O_CREAT
// 0x200, O_TRUNC 0x400; struct stat is 144 bytes with st_mode (u16) at
// offset 4. A path that names a directory opens for reading on Unix, so
// the read open checks fstat and fails for a directory.
// =====================================================================
.include "baysick.inc"

.equ RT_FM_CLOSED,  0               // read mode, not open
.equ RT_FM_READ,    1               // read mode, open
.equ RT_FM_WRITE,   2               // write mode
.equ RT_O_RDONLY,   0x0000          // <fcntl.h>, macOS
.equ RT_O_WRONLY,   0x0001
.equ RT_O_CREAT,    0x0200
.equ RT_O_TRUNC,    0x0400
.equ RT_O_MODE,     0x1B6           // 0666: permissions of a created file (umask applies)
.equ RT_STAT_SIZE,  144             // sizeof(struct stat), macOS arm64
.equ RT_STAT_MODE,  4               // offsetof(struct stat, st_mode), u16
.equ RT_S_IFMT,     0xF000          // 0170000
.equ RT_S_IFDIR,    0x4000          // 0040000
.equ RT_FILES_N,    LIM_FILES + 1   // table entries 0 .. LIM_FILES

    .section __TEXT,__text,regular,pure_instructions

// ---------------------------------------------------------------------
// Lrt_files_number -- check a file designator (LANGUAGE.md 7.21):
//   k = trunc(x), compared as a double, 0 <= k <= _bsk_files_count,
//   else INVALID FILE NUMBER (a NaN fails the first test).
//   Inputs  : d0 = x
//   Outputs : w0 = k
//   Errors  : INVALID FILE NUMBER
//   Clobbers: x0, x9, d0, d1
//   Callee-saved used: none
//   Frame   : none (leaf; the error exit is a branch)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_files_number:
    frintz d0, d0                   // k = trunc(x), exact
    fcmp d0, #0.0
    b.lt Lrt_files_badnum           // k < 0 (or unordered)
    adrp x9, _bsk_files_count@PAGE
    ldr x9, [x9, _bsk_files_count@PAGEOFF]
    ucvtf d1, x9                    // N, exact
    fcmp d0, d1
    b.gt Lrt_files_badnum           // k > N
    fcvtzu w0, d0                   // 0 <= k <= N <= LIM_FILES
    ret
Lrt_files_badnum:
    mov w0, #ERR_INVALID_FILE_NUMBER
    b _bsk_err

// ---------------------------------------------------------------------
// Lrt_files_number1 -- Lrt_files_number for SCRATCH # and RESTORE #,
//   where file 0 (the terminal) is INVALID FILE NUMBER too.
//   Inputs  : d0 = x
//   Outputs : w0 = k (1 .. N)
//   Errors  : INVALID FILE NUMBER
//   Clobbers: x0, x9, d0, d1
//   Callee-saved used: none
//   Frame   : 16 bytes (frame record)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_files_number1:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl Lrt_files_number
    cbz w0, Lrt_files_badnum        // #0 cannot be scratched or restored
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------
// Lrt_files_path -- file k's FILES name as a NUL-terminated host path in
//   a static buffer (the bytes unchanged, LANGUAGE.md 7.21).
//   Inputs  : w0 = k (1 .. N)
//   Outputs : x0 = path, or 0 if the name is longer than LIM_FILE_NAME
//             (impossible for a compiled program; then the open fails)
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = length
//   Frame   : 32 bytes (frame record + x19)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_files_path:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    adrp x9, _bsk_files@PAGE
    add x9, x9, _bsk_files@PAGEOFF
    sub w10, w0, #1
    add x9, x9, x10, lsl #4         // &_bsk_files[k-1] (SD_SIZE 16)
    ldr w19, [x9, #SD_LEN]
    mov x0, #0
    cmp x19, #LIM_FILE_NAME
    b.hi 1f                         // cannot be a FILES name
    ldr x1, [x9, #SD_PTR]
    adrp x0, Lrt_files_pathbuf@PAGE
    add x0, x0, Lrt_files_pathbuf@PAGEOFF
    mov x2, x19
    bl _memcpy                      // x0 = the buffer
    strb wzr, [x0, x19]             // NUL terminator
1:
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
.if SD_SIZE != 16
    .error "rt_files.s: Lrt_files_path assumes SD_SIZE == 16"
.endif

// ---------------------------------------------------------------------
// Lrt_files_open -- open(path of file k, flags, RT_O_MODE).
//   Inputs  : w0 = k (1 .. N), w1 = flags
//   Outputs : w0 = fd, or -1 on failure
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = flags
//   Frame   : 32 bytes (frame record + x19) + 16 bytes (variadic slot)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_files_open:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov w19, w1
    bl Lrt_files_path               // x0 = path or 0
    mov w9, #-1
    cbz x0, 1f                      // no usable path: fails
    sub sp, sp, #16
    mov x9, #RT_O_MODE
    str x9, [sp]                    // variadic mode argument: on the stack
    mov w1, w19
    bl _open
    add sp, sp, #16
    mov w9, w0                      // fd or -1
1:
    mov w0, w9
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _bsk_fsel -- select the file of the next print or input entry point
//   (DESIGN.md 6.8, 6.10): k = trunc(x), compared as a double,
//   FILE_NUM_STDERR (-1) <= k <= _bsk_files_count, else INVALID FILE
//   NUMBER; then the pending selection _bsk_rt_fsel := k + 2 (0 means
//   "none", 1 is standard error). The print entry points accept -1;
//   the input entry points reject it (error 49) when they take it.
//   Inputs  : d0 = designator value
//   Outputs : none
//   Errors  : INVALID FILE NUMBER
//   Clobbers: x0, x9, d0, d1
//   Callee-saved used: none
//   Frame   : 16 bytes (frame record)
// ---------------------------------------------------------------------
    .globl _bsk_fsel
    .p2align 2
_bsk_fsel:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    frintz d0, d0                   // k = trunc(x), exact
    fmov d1, #-1.0                  // FILE_NUM_STDERR
    fcmp d0, d1
    mov w0, #(FILE_NUM_STDERR + 2)  // standard error's selection value
    b.eq 1f                         // k = -1 (a NaN is unordered: no)
    bl Lrt_files_number             // w0 = k, 0 .. N (else error 49)
    add w0, w0, #2                  // 0 means "none", 1 standard error
1:
    adrp x9, _bsk_rt_fsel@PAGE
    str w0, [x9, _bsk_rt_fsel@PAGEOFF]
    ldp x29, x30, [sp], #16
    ret
.if FILE_NUM_STDERR != -1
    .error "rt_files.s: _bsk_fsel compares with the constant -1.0"
.endif

// ---------------------------------------------------------------------
// _bsk_rt_file_wcheck -- PRINT #k (k >= 1): the file must be in write
//   mode, else ILLEGAL FILE COMMAND (LANGUAGE.md 7.21, 7.24).
//   Inputs  : w0 = k (1 .. N)
//   Outputs : none
//   Errors  : ILLEGAL FILE COMMAND
//   Clobbers: x9, x10
//   Callee-saved used: none
//   Frame   : none (leaf; the error exit is a branch)
// ---------------------------------------------------------------------
    .private_extern _bsk_rt_file_wcheck
    .p2align 2
_bsk_rt_file_wcheck:
    adrp x9, Lrt_files_mode@PAGE
    add x9, x9, Lrt_files_mode@PAGEOFF
    ldrb w10, [x9, w0, uxtw]
    cmp w10, #RT_FM_WRITE
    b.ne Lrt_files_badcmd
    ret
Lrt_files_badcmd:
    mov w0, #ERR_ILLEGAL_FILE_COMMAND
    b _bsk_err

// ---------------------------------------------------------------------
// _bsk_rt_file_ropen -- INPUT #k / IF END #k (k >= 1) in read mode:
//   write mode -> ILLEGAL FILE COMMAND; "read, not open" -> open the
//   host file for reading (open(path, O_RDONLY), then fstat: a
//   directory is closed again and fails; any failure CAN'T OPEN FILE),
//   set up its reader (_bsk_rt_rd_setup: OUT OF ROOM), "read, open";
//   "read, open" -> nothing.
//   Inputs  : w0 = k (1 .. N)
//   Outputs : none
//   Errors  : ILLEGAL FILE COMMAND, CAN'T OPEN FILE, OUT OF ROOM
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = k, x20 = fd
//   Frame   : 32 bytes (frame record + x19, x20) + RT_STAT_SIZE
//             (struct stat)
// ---------------------------------------------------------------------
    .private_extern _bsk_rt_file_ropen
    .p2align 2
_bsk_rt_file_ropen:
    adrp x9, Lrt_files_mode@PAGE
    add x9, x9, Lrt_files_mode@PAGEOFF
    ldrb w10, [x9, w0, uxtw]
    cmp w10, #RT_FM_WRITE
    b.eq Lrt_files_badcmd           // INPUT # from a file being written
    cmp w10, #RT_FM_READ
    b.ne 1f
    ret                             // already open for reading
1:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    sub sp, sp, #RT_STAT_SIZE       // struct stat at [sp]
    mov w19, w0
    mov w1, #RT_O_RDONLY
    bl Lrt_files_open
    tbnz w0, #31, Lrt_files_cantopen
    mov w20, w0
    mov x1, sp
    bl _fstat
    cbnz w0, 2f                     // fstat failed: cannot read it
    ldrh w9, [sp, #RT_STAT_MODE]
    and w9, w9, #RT_S_IFMT
    cmp w9, #RT_S_IFDIR
    b.ne 3f                         // not a directory: usable
2:
    mov w0, w20
    bl _close                       // a directory is no input file
    b Lrt_files_cantopen
3:
    mov w0, w19
    mov w1, w20
    bl _bsk_rt_rd_setup             // buffers (OUT OF ROOM), emptied
    adrp x9, Lrt_files_fd@PAGE
    add x9, x9, Lrt_files_fd@PAGEOFF
    str w20, [x9, w19, uxtw #2]
    adrp x9, Lrt_files_mode@PAGE
    add x9, x9, Lrt_files_mode@PAGEOFF
    mov w10, #RT_FM_READ
    strb w10, [x9, w19, uxtw]       // "read, open"
    add sp, sp, #RT_STAT_SIZE
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
Lrt_files_cantopen:
    mov w0, #ERR_CANT_OPEN_FILE
    bl _bsk_err                     // noreturn

// ---------------------------------------------------------------------
// _bsk_feof -- IF END # (LANGUAGE.md 7.26): is file k at its end?
//   k >= 1 in write mode: never (0). k >= 1 in read mode: opened if
//   needed, then at its end when its reader holds no unread byte and a
//   chunk read returns none. k = 0: the same on standard input's reader
//   (on a terminal stdout is flushed before the read).
//   Inputs  : d0 = designator value
//   Outputs : w0 = 1 at the end, else 0
//   Errors  : INVALID FILE NUMBER, CAN'T OPEN FILE, OUT OF ROOM
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = k
//   Frame   : 32 bytes (frame record + x19)
// ---------------------------------------------------------------------
    .globl _bsk_feof
    .p2align 2
_bsk_feof:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    bl Lrt_files_number             // w0 = k
    mov w19, w0
    cbz w19, 1f                     // #0: standard input
    adrp x9, Lrt_files_mode@PAGE
    add x9, x9, Lrt_files_mode@PAGEOFF
    ldrb w10, [x9, w19, uxtw]
    mov w0, #0
    cmp w10, #RT_FM_WRITE
    b.eq 2f                         // write mode: never at its end
    mov w0, w19
    bl _bsk_rt_file_ropen           // open if needed
1:
    mov w0, w19
    bl _bsk_rt_rd_atend             // w0 = 1 at the end
2:
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// Lrt_files_close -- close file k if it is open (read or write mode) and
//   make it "read, not open"; its reader is emptied. Write mode: the
//   unwritten output is not written here (SCRATCH discards it; RESTORE
//   writes it before calling this).
//   Inputs  : w0 = k (1 .. N)
//   Outputs : none
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = k
//   Frame   : 32 bytes (frame record + x19)
// ---------------------------------------------------------------------
    .p2align 2
Lrt_files_close:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    mov w19, w0
    adrp x9, Lrt_files_mode@PAGE
    add x9, x9, Lrt_files_mode@PAGEOFF
    ldrb w10, [x9, w19, uxtw]
    cbz w10, 1f                     // RT_FM_CLOSED: nothing is open
    strb wzr, [x9, w19, uxtw]       // "read, not open" from now on
    adrp x9, Lrt_files_fd@PAGE
    add x9, x9, Lrt_files_fd@PAGEOFF
    ldr w0, [x9, w19, uxtw #2]
    bl _close                       // the result is ignored
1:
    mov w0, w19
    bl _bsk_rt_rd_reset             // its unread bytes are discarded
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _bsk_scratch -- SCRATCH #k (LANGUAGE.md 7.22): k = 0 -> INVALID FILE
//   NUMBER; close the file if open (write mode: the buffered output is
//   discarded); open(path, O_WRONLY|O_CREAT|O_TRUNC, 0666) (failure:
//   CAN'T OPEN FILE); only then the output buffer is allocated if the
//   file has none yet (OUT OF ROOM); write mode with col = out = 0 and
//   an empty buffer.
//   Inputs  : d0 = designator value
//   Outputs : none
//   Errors  : INVALID FILE NUMBER, CAN'T OPEN FILE, OUT OF ROOM
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = k, x20 = fd
//   Frame   : 32 bytes (frame record + x19, x20)
// ---------------------------------------------------------------------
    .globl _bsk_scratch
    .p2align 2
_bsk_scratch:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    bl Lrt_files_number1            // w0 = k >= 1
    mov w19, w0
    bl Lrt_files_close
    mov w0, w19
    mov w1, #(RT_O_WRONLY | RT_O_CREAT | RT_O_TRUNC)
    bl Lrt_files_open               // created or truncated
    tbnz w0, #31, Lrt_files_cantopen
    mov w20, w0
    adrp x9, Lrt_files_fd@PAGE
    add x9, x9, Lrt_files_fd@PAGEOFF
    str w20, [x9, w19, uxtw #2]
    mov w0, w19
    mov w1, w20
    bl _bsk_rt_out_begin            // buffer (OUT OF ROOM), col = out = 0
    adrp x9, Lrt_files_mode@PAGE
    add x9, x9, Lrt_files_mode@PAGEOFF
    mov w10, #RT_FM_WRITE
    strb w10, [x9, w19, uxtw]       // write mode
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _bsk_frestore -- RESTORE #k (LANGUAGE.md 7.23): k = 0 -> INVALID FILE
//   NUMBER; write mode: a newline if the file's col != 0, its buffered
//   output written (failure: CAN'T WRITE FILE), closed; read mode, open:
//   closed. The file becomes "read, not open" with an empty reader.
//   Inputs  : d0 = designator value
//   Outputs : none
//   Errors  : INVALID FILE NUMBER, CAN'T WRITE FILE
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = k
//   Frame   : 32 bytes (frame record + x19)
// ---------------------------------------------------------------------
    .globl _bsk_frestore
    .p2align 2
_bsk_frestore:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    bl Lrt_files_number1            // w0 = k >= 1
    mov w19, w0
    adrp x9, Lrt_files_mode@PAGE
    add x9, x9, Lrt_files_mode@PAGEOFF
    ldrb w10, [x9, w19, uxtw]
    cmp w10, #RT_FM_WRITE
    b.ne 1f
    mov w0, w19
    mov w1, #1                      // a failure raises CAN'T WRITE FILE
    bl _bsk_rt_out_end              // pending newline, buffer written
1:
    mov w0, w19
    bl Lrt_files_close              // "read, not open", reader emptied
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------------
// _bsk_rt_files_finish -- termination (LANGUAGE.md 10, DESIGN.md 6.8):
//   the first call finishes, for k = 1 .. N in ascending order, every
//   file in write mode whose "write failed" flag is clear: a newline if
//   its col != 0, then its buffer is written; a failure is remembered
//   and the loop goes on. Later calls finish nothing (_bsk_err called
//   from _bsk_end). Files in read mode need nothing; nothing is closed.
//   Inputs  : none
//   Outputs : w0 = 1 if some file's output failed (now or earlier),
//             else 0
//   Clobbers: x0-x17, d0-d7, d16-d31
//   Callee-saved used: x19 = k, x20 = N, x21 = result
//   Frame   : 48 bytes (frame record + x19..x21, padded)
// ---------------------------------------------------------------------
    .private_extern _bsk_rt_files_finish
    .p2align 2
_bsk_rt_files_finish:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    adrp x9, _bsk_files_count@PAGE
    ldr x20, [x9, _bsk_files_count@PAGEOFF]
    cmp x20, #LIM_FILES
    mov x9, #LIM_FILES
    csel x20, x9, x20, hi           // never beyond the table
    adrp x9, Lrt_files_done@PAGE
    ldr w10, [x9, Lrt_files_done@PAGEOFF]
    cbnz w10, Lrt_files_fin_status  // finished already
    mov w10, #1
    str w10, [x9, Lrt_files_done@PAGEOFF]
    mov x19, #1
Lrt_files_fin_loop:
    cmp x19, x20
    b.hi Lrt_files_fin_status
    adrp x9, Lrt_files_mode@PAGE
    add x9, x9, Lrt_files_mode@PAGEOFF
    ldrb w10, [x9, x19]
    cmp w10, #RT_FM_WRITE
    b.ne 1f                         // read mode: nothing to do
    mov w0, w19
    mov w1, #0                      // report only, never raise here
    bl _bsk_rt_out_end
1:
    add x19, x19, #1
    b Lrt_files_fin_loop
Lrt_files_fin_status:
    // The result: any file whose "write failed" flag is set.
    mov w21, #0
    mov x19, #1
2:
    cmp x19, x20
    b.hi 3f
    mov w0, w19
    bl _bsk_rt_out_failed
    orr w21, w21, w0
    add x19, x19, #1
    b 2b
3:
    mov w0, w21
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------
// State (zero-initialised: every file "read, not open").
//   Lrt_files_mode     RT_FILES_N bytes, RT_FM_* of file k at index k
//   Lrt_files_fd       RT_FILES_N u32, the fd of an open file k
//   Lrt_files_done     u32 1 once the files were finished
//   Lrt_files_pathbuf  LIM_FILE_NAME + 1 bytes, a NUL-terminated path
// ---------------------------------------------------------------------
.zerofill __DATA,__bss,Lrt_files_mode,RT_FILES_N,3
.zerofill __DATA,__bss,Lrt_files_fd,4*RT_FILES_N,3
.zerofill __DATA,__bss,Lrt_files_done,4,2
.zerofill __DATA,__bss,Lrt_files_pathbuf,LIM_FILE_NAME+1,4
