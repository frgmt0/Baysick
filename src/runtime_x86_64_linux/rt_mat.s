# =====================================================================
# src/runtime_x86_64_linux/rt_mat.s -- the MAT statements' runtime layer
# (docs/LANGUAGE.md 7.14, docs/DESIGN.md 6.5).
#
# Defines (global, runtime.inc):
#   bsk_mat_redim1 bsk_mat_redim2 bsk_mat_read bsk_mat_print
#   bsk_mat_zer bsk_mat_con bsk_mat_idn
#   bsk_mat_copy bsk_mat_trn bsk_mat_inv
#   bsk_mat_add bsk_mat_sub bsk_mat_mul bsk_mat_scale
#   bsk_smat_print (MAT PRINT of a string list)
#
# This file owns every BASIC rule of the MAT statements: shapes,
# conformability, the storage ("fits") test, redimensioning, aliasing,
# OVERFLOW / DIMENSION ERROR / SINGULAR MATRIX, the DATA cursor (via
# bsk_read) and the PRINT column (via the bsk_print_* entry points and
# bsk_rt_print_fresh). The arithmetic is delegated to the kernels
# through the bsk_kern_* trampolines (rt_kinit.s).
#
# Order inside an assignment (LANGUAGE.md 7.14.4): operand shapes and
# conformability -> target-fits test (against RTA_CAP, shape unchanged)
# -> compute -> kernel status -> set the target's shape -> store.
# Aliasing (DESIGN.md 6.5): +, -, (K)* run in place when the target is
# an operand (its shape cannot change); *, TRN, INV with the target as
# an operand compute into the static result temporary and are copied
# afterwards; otherwise the target's shape is set first and the kernel
# writes straight into it.
#
# Every entry point uses the same frame (RT_MAT_ENTER): six saved
# registers and three MV_* views plus one 8-byte slot.
# =====================================================================
.include "baysick.inc"

.equ RT_MAT_V0,    0                # MV view slot 0
.equ RT_MAT_V1,    32               # MV view slot 1
.equ RT_MAT_V2,    64               # MV view slot 2
.equ RT_MAT_SLOT,  96               # 8-byte scratch (scalar, count)
.equ RT_MAT_FRAME, 104
.equ RT_MAT_TWO31_BITS, 0x41E0000000000000   # 2^31 as a double

# RT_MAT_ENTER / RT_MAT_LEAVE -- prologue / epilogue of every entry
#   point: %rbp frame, %rbx %r12-%r15 saved, RT_MAT_FRAME bytes of
#   locals; %rsp = 0 (mod 16) at every call.
.macro RT_MAT_ENTER
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    subq $RT_MAT_FRAME, %rsp
.endm

.macro RT_MAT_LEAVE
    addq $RT_MAT_FRAME, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret
.endm

    .text

# ---------------------------------------------------------------------
# .Lrt_mat_dimerr -- stop with DIMENSION ERROR (bsk_err aligns the
#   stack itself and never returns).
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_mat_dimerr:
    movl $ERR_DIMENSION_ERROR, %edi
    jmp bsk_err

# ---------------------------------------------------------------------
# .Lrt_mat_dimarg -- convert a dimension argument (DESIGN.md 6.5).
#   Purpose : x < 0.5 (or NaN) or x >= 2^31 -> DIMENSION ERROR; else
#             d = floor(x + 1/2) exactly: floor(x), plus 1 when the
#             (exact) fraction x - floor(x) is >= 0.5.
#   Private convention (leaf):
#   Inputs  : %xmm0 = x
#   Outputs : %rax = d (1 .. 2^31)
#   Clobbers: %rax %xmm0 %xmm1
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_mat_dimarg:
    ucomisd .Lrt_mat_half(%rip), %xmm0
    jb .Lrt_mat_dimerr              # x < 0.5, or unordered (NaN)
    ucomisd .Lrt_mat_two31(%rip), %xmm0
    jae .Lrt_mat_dimerr             # x >= 2^31: no storage that large
    cvttsd2si %xmm0, %rax           # floor(x) (x > 0: truncation)
    cvtsi2sdq %rax, %xmm1
    subsd %xmm1, %xmm0              # fraction, exact
    ucomisd .Lrt_mat_half(%rip), %xmm0
    jb 1f
    addq $1, %rax                   # fraction >= 0.5: round up
1:
    ret

# ---------------------------------------------------------------------
# .Lrt_mat_fits -- the LANGUAGE.md 7.14.3 storage test (no change).
#   Purpose : list: c = 1 and r + 1 <= RTA_CAP; table:
#             (r + 1)(c + 1) <= RTA_CAP (64-bit products); else
#             DIMENSION ERROR.
#   Private convention (leaf):
#   Inputs  : %rdi = descriptor, %rsi = r (>= 1), %rdx = c (>= 1),
#             both <= 2^31
#   Clobbers: %rax %rcx %r11
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_mat_fits:
    movl RTA_CAP(%rdi), %ecx        # storage S
    leaq 1(%rsi), %rax              # r + 1
    cmpl $1, RTA_DIMS(%rdi)
    jne 1f
    cmpq $1, %rdx                   # a list holds one column only
    jne .Lrt_mat_dimerr
    jmp 2f
1:
    movq %rdx, %r11
    addq $1, %r11
    imulq %r11, %rax                # (r + 1)(c + 1) < 2^63
2:
    cmpq %rcx, %rax
    ja .Lrt_mat_dimerr
    ret

# ---------------------------------------------------------------------
# .Lrt_mat_setshape -- make r x c the current shape (after fits).
#   Private convention (leaf):
#   Inputs  : %rdi = descriptor, %rsi = r, %rdx = c (1 for a list)
#   Clobbers: %rax
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_mat_setshape:
    movl %esi, RTA_B1(%rdi)         # rows (lists: the only bound)
    cmpl $1, RTA_DIMS(%rdi)
    je 1f
    movl %edx, RTA_B2(%rdi)         # columns
    leal 1(%rdx), %eax
    movl %eax, RTA_ROWLEN(%rdi)     # row length c + 1
1:
    ret

# ---------------------------------------------------------------------
# .Lrt_mat_shape -- current shape of an operand.
#   Purpose : table (B1, B2), list (B1, 1); a zero dimension ->
#             DIMENSION ERROR (LANGUAGE.md 7.14.1).
#   Private convention (leaf):
#   Inputs  : %rdi = descriptor
#   Outputs : %rax = rows, %rdx = columns
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_mat_shape:
    movl RTA_B1(%rdi), %eax
    movl $1, %edx
    cmpl $1, RTA_DIMS(%rdi)
    je 1f
    movl RTA_B2(%rdi), %edx
1:
    testq %rax, %rax
    jz .Lrt_mat_dimerr
    testq %rdx, %rdx
    jz .Lrt_mat_dimerr
    ret

# ---------------------------------------------------------------------
# .Lrt_mat_view -- MV view of a matrix in its current shape.
#   Purpose : table: MV_DATA = RTA_DATA + 8 (ROWLEN + 1), MV_LD =
#             ROWLEN, B1 x B2; list: MV_DATA = RTA_DATA + 8, MV_LD = 1,
#             B1 x 1.
#   Private convention (leaf):
#   Inputs  : %rdi = descriptor, %rsi = view to fill
#   Clobbers: %rax %rcx
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_mat_view:
    movl RTA_B1(%rdi), %eax
    movq %rax, MV_ROWS(%rsi)
    cmpl $1, RTA_DIMS(%rdi)
    je 1f
    movl RTA_B2(%rdi), %eax
    movq %rax, MV_COLS(%rsi)
    movl RTA_ROWLEN(%rdi), %ecx
    movq %rcx, MV_LD(%rsi)
    movq RTA_DATA(%rdi), %rax
    leaq 8(%rax,%rcx,8), %rax       # element (1,1)
    movq %rax, MV_DATA(%rsi)
    ret
1:
    movq $1, MV_COLS(%rsi)
    movq $1, MV_LD(%rsi)
    movq RTA_DATA(%rdi), %rax
    addq $8, %rax                   # element 1
    movq %rax, MV_DATA(%rsi)
    ret

# ---------------------------------------------------------------------
# .Lrt_mat_tmpview -- view of the static result temporary.
#   Private convention (leaf):
#   Inputs  : %rdi = view to fill, %rsi = rows, %rdx = cols
#             (rows * cols <= RT_MAT_SCRATCH_ELEMS: guaranteed because
#             the result also fits a target, whose storage is at most
#             LIM_ARRAY_ELEMS)
#   Clobbers: %rax
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_mat_tmpview:
    leaq .Lrt_mat_tmp(%rip), %rax
    movq %rax, MV_DATA(%rdi)
    movq %rsi, MV_ROWS(%rdi)
    movq %rdx, MV_COLS(%rdi)
    movq %rdx, MV_LD(%rdi)          # dense rows
    ret

# ---------------------------------------------------------------------
# .Lrt_mat_status -- turn a kernel status into the BASIC error.
#   Private convention: %rax = KS_*; returns for KS_OK, otherwise
#   OVERFLOW (KS_NONFINITE) or SINGULAR MATRIX (KS_SINGULAR) via
#   bsk_err (no return).
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_mat_status:
    testq %rax, %rax
    jnz 1f
    ret
1:
    movl $ERR_OVERFLOW, %edi
    cmpq $KS_SINGULAR, %rax
    jne 2f
    movl $ERR_SINGULAR_MATRIX, %edi
2:
    jmp bsk_err

# ---------------------------------------------------------------------
# bsk_mat_redim1 -- redimension to r x 1 (MAT READ X(r), ZER(r), ...).
#   Inputs  : %rdi = descriptor, %xmm0 = r (dimension argument)
#   Outputs : none (DIMENSION ERROR if r is invalid or does not fit)
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = descriptor, %r12 = r; frame RT_MAT_ENTER
# ---------------------------------------------------------------------
    .globl bsk_mat_redim1
    .type bsk_mat_redim1, @function
    .p2align 4
bsk_mat_redim1:
    RT_MAT_ENTER
    movq %rdi, %rbx
    call .Lrt_mat_dimarg
    movq %rax, %r12                 # r
    movq %rbx, %rdi
    movq %r12, %rsi
    movl $1, %edx                   # r x 1
    call .Lrt_mat_fits
    call .Lrt_mat_setshape
    RT_MAT_LEAVE
    .size bsk_mat_redim1, . - bsk_mat_redim1

# ---------------------------------------------------------------------
# bsk_mat_redim2 -- redimension to r x c.
#   Inputs  : %rdi = descriptor, %xmm0 = r, %xmm1 = c
#   Outputs : none (DIMENSION ERROR if invalid or too large)
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = descriptor, %r12 = r, %r13 = c;
#             frame RT_MAT_ENTER (c argument kept in RT_MAT_SLOT)
# ---------------------------------------------------------------------
    .globl bsk_mat_redim2
    .type bsk_mat_redim2, @function
    .p2align 4
bsk_mat_redim2:
    RT_MAT_ENTER
    movq %rdi, %rbx
    movsd %xmm1, RT_MAT_SLOT(%rsp)  # c argument (first r is converted)
    call .Lrt_mat_dimarg
    movq %rax, %r12                 # r
    movsd RT_MAT_SLOT(%rsp), %xmm0
    call .Lrt_mat_dimarg
    movq %rax, %r13                 # c
    movq %rbx, %rdi
    movq %r12, %rsi
    movq %r13, %rdx
    call .Lrt_mat_fits
    call .Lrt_mat_setshape
    RT_MAT_LEAVE
    .size bsk_mat_redim2, . - bsk_mat_redim2

# ---------------------------------------------------------------------
# bsk_mat_read -- MAT READ with the current shape, row by row.
#   Purpose : each value comes from bsk_read (the shared DATA cursor;
#             OUT OF DATA ends the program there) and is stored at
#             once, so earlier elements stay stored.
#   Inputs  : %rdi = descriptor
#   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = current row pointer, %r12 = rows left,
#             %r13 = columns, %r14 = column index, %r15 = row stride
#             in bytes; frame RT_MAT_ENTER (view in RT_MAT_V0)
# ---------------------------------------------------------------------
    .globl bsk_mat_read
    .type bsk_mat_read, @function
    .p2align 4
bsk_mat_read:
    RT_MAT_ENTER
    movq %rdi, %rbx
    call .Lrt_mat_shape             # DIMENSION ERROR on a zero shape
    movq %rbx, %rdi
    leaq RT_MAT_V0(%rsp), %rsi
    call .Lrt_mat_view
    movq RT_MAT_V0 + MV_DATA(%rsp), %rbx
    movq RT_MAT_V0 + MV_ROWS(%rsp), %r12
    movq RT_MAT_V0 + MV_COLS(%rsp), %r13
    movq RT_MAT_V0 + MV_LD(%rsp), %r15
    shlq $3, %r15
.Lrt_mat_read_row:
    xorl %r14d, %r14d
.Lrt_mat_read_col:
    call bsk_read                   # next DATA value in %xmm0
    movsd %xmm0, (%rbx,%r14,8)      # store it right away
    addq $1, %r14
    cmpq %r13, %r14
    jb .Lrt_mat_read_col
    addq %r15, %rbx
    subq $1, %r12
    jnz .Lrt_mat_read_row
    RT_MAT_LEAVE
    .size bsk_mat_read, . - bsk_mat_read

# ---------------------------------------------------------------------
# bsk_mat_print -- one MAT PRINT item (LANGUAGE.md 7.14.5 steps 2-3).
#   Purpose : newline if col != 0; each row: numbers separated by the
#             ',' rule (zoned) or the ';' rule (packed), then newline;
#             a list is one row. (The empty line between items is the
#             prnl the compiler emits.)
#   Inputs  : %rdi = descriptor, %esi = MATPR_ZONED / MATPR_PACKED
#   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = current row pointer, %r12 = mode,
#             %r13 = columns, %r14 = column index, %r15 = row stride
#             in bytes; frame RT_MAT_ENTER (view in RT_MAT_V0, rows
#             left in RT_MAT_SLOT)
# ---------------------------------------------------------------------
    .globl bsk_mat_print
    .type bsk_mat_print, @function
    .p2align 4
bsk_mat_print:
    RT_MAT_ENTER
    movq %rdi, %rbx
    movl %esi, %r12d                # layout mode
    call .Lrt_mat_shape             # DIMENSION ERROR on a zero shape
    movq %rbx, %rdi
    leaq RT_MAT_V0(%rsp), %rsi
    call .Lrt_mat_view
    movq RT_MAT_V0 + MV_DATA(%rsp), %rbx
    movq RT_MAT_V0 + MV_COLS(%rsp), %r13
    movq RT_MAT_V0 + MV_LD(%rsp), %r15
    shlq $3, %r15
    movq RT_MAT_V0 + MV_ROWS(%rsp), %rax
    movq %rax, RT_MAT_SLOT(%rsp)    # rows left
    cmpl $1, RTA_DIMS(%rdi)
    jne 1f
    # a list prints as one row of n numbers: n "columns" with stride 8
    movq RT_MAT_V0 + MV_ROWS(%rsp), %r13
    movq $1, RT_MAT_SLOT(%rsp)
1:
    call bsk_rt_print_fresh         # a matrix starts on a new line
.Lrt_mat_print_row:
    xorl %r14d, %r14d
.Lrt_mat_print_col:
    movsd (%rbx,%r14,8), %xmm0
    call bsk_print_num              # number item (12-column room rule)
    addq $1, %r14
    cmpq %r13, %r14
    jae .Lrt_mat_print_rowend       # no separator after the last one
    cmpl $MATPR_PACKED, %r12d
    je 2f
    call bsk_print_comma            # zoned: next 15-column zone
    jmp .Lrt_mat_print_col
2:
    call bsk_print_semi             # packed: next multiple of 3
    jmp .Lrt_mat_print_col
.Lrt_mat_print_rowend:
    call bsk_print_nl               # newline after each row
    addq %r15, %rbx
    subq $1, RT_MAT_SLOT(%rsp)
    jnz .Lrt_mat_print_row
    RT_MAT_LEAVE
    .size bsk_mat_print, . - bsk_mat_print

# ---------------------------------------------------------------------
# bsk_smat_print -- one MAT PRINT item that is a string list
#   (LANGUAGE.md 7.14.5 steps 2-3, DESIGN.md 6.5).
#   Purpose : current bound 0 -> DIMENSION ERROR; newline if col != 0;
#             one row of the string items X$(1) .. X$(n), each but the
#             last followed by the ',' rule (zoned) or nothing (packed);
#             then newline.
#   Inputs  : %rdi = string-list descriptor, %esi = MATPR_ZONED /
#             MATPR_PACKED
#   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = current element (SD*), %r12 = mode,
#             %r13 = n, %r14 = element index; frame RT_MAT_ENTER
# ---------------------------------------------------------------------
    .globl bsk_smat_print
    .type bsk_smat_print, @function
    .p2align 4
bsk_smat_print:
    RT_MAT_ENTER
    movl RTA_B1(%rdi), %r13d        # current bound n
    testq %r13, %r13
    jz .Lrt_mat_dimerr              # a list of no elements
    movl %esi, %r12d                # layout mode
    movq RTA_DATA(%rdi), %rbx
    addq $SD_SIZE, %rbx             # element 1
    movl $1, %r14d
    call bsk_rt_print_fresh         # a matrix starts on a new line
.Lrt_mat_sprint_loop:
    movq %rbx, %rdi
    call bsk_print_sv               # the string item
    cmpq %r13, %r14
    jae .Lrt_mat_sprint_end         # no separator after the last one
    cmpl $MATPR_PACKED, %r12d
    je 1f                           # packed: no movement at all
    call bsk_print_comma            # zoned: next 15-column zone
1:
    addq $SD_SIZE, %rbx
    addq $1, %r14
    jmp .Lrt_mat_sprint_loop
.Lrt_mat_sprint_end:
    call bsk_print_nl               # newline after the row
    RT_MAT_LEAVE
    .size bsk_smat_print, . - bsk_smat_print

# ---------------------------------------------------------------------
# .Lrt_mat_fillcur -- fill the current matrix of a descriptor.
#   Private convention: called from an RT_MAT_ENTER frame with the
#   return address pushed, so the caller's view slot RT_MAT_V0 is at
#   8 + RT_MAT_V0(%rsp) here.
#   Inputs  : %rdi = descriptor, %xmm0 = value
#   Clobbers: all caller-saved registers; the caller's RT_MAT_V0 holds
#             the view afterwards
#   Frame   : 8 bytes (alignment pad); %rsp = 0 (mod 16) at calls
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_mat_fillcur:
    subq $8, %rsp                   # caller's view now at 16(%rsp)
    movsd %xmm0, (%rsp)             # keep the value
    pushq %rdi
    call .Lrt_mat_shape             # DIMENSION ERROR on a zero shape
    popq %rdi                       # alignment back to (mod 16) = 8
    leaq 16 + RT_MAT_V0(%rsp), %rsi
    call .Lrt_mat_view
    leaq 16 + RT_MAT_V0(%rsp), %rdi
    movsd (%rsp), %xmm0
    call bsk_kern_fill
    addq $8, %rsp
    ret

# ---------------------------------------------------------------------
# bsk_mat_zer / bsk_mat_con -- fill the current matrix with 0 / 1.
#   Inputs  : %rdi = descriptor
#   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: none besides the RT_MAT_ENTER frame
# ---------------------------------------------------------------------
    .globl bsk_mat_zer
    .type bsk_mat_zer, @function
    .p2align 4
bsk_mat_zer:
    RT_MAT_ENTER
    xorpd %xmm0, %xmm0              # 0
    call .Lrt_mat_fillcur
    RT_MAT_LEAVE
    .size bsk_mat_zer, . - bsk_mat_zer

    .globl bsk_mat_con
    .type bsk_mat_con, @function
    .p2align 4
bsk_mat_con:
    RT_MAT_ENTER
    movsd .Lrt_mat_one(%rip), %xmm0 # 1
    call .Lrt_mat_fillcur
    RT_MAT_LEAVE
    .size bsk_mat_con, . - bsk_mat_con

# ---------------------------------------------------------------------
# bsk_mat_idn -- identity in the current shape, which must be square.
#   Inputs  : %rdi = descriptor
#   Outputs : none (DIMENSION ERROR if not square)
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = descriptor; frame RT_MAT_ENTER
# ---------------------------------------------------------------------
    .globl bsk_mat_idn
    .type bsk_mat_idn, @function
    .p2align 4
bsk_mat_idn:
    RT_MAT_ENTER
    movq %rdi, %rbx
    call .Lrt_mat_shape
    cmpq %rax, %rdx
    jne .Lrt_mat_dimerr             # rows != columns
    movq %rbx, %rdi
    xorpd %xmm0, %xmm0
    call .Lrt_mat_fillcur           # zeros; view left in RT_MAT_V0
    movq RT_MAT_V0 + MV_DATA(%rsp), %rax
    movq RT_MAT_V0 + MV_LD(%rsp), %rcx
    leaq 8(,%rcx,8), %rcx           # diagonal step: (LD + 1) * 8
    movq RT_MAT_V0 + MV_ROWS(%rsp), %rdx
    movsd .Lrt_mat_one(%rip), %xmm0
1:
    movsd %xmm0, (%rax)             # (i, i) = 1
    addq %rcx, %rax
    subq $1, %rdx
    jnz 1b
    RT_MAT_LEAVE
    .size bsk_mat_idn, . - bsk_mat_idn

# ---------------------------------------------------------------------
# bsk_mat_copy -- MAT B = A.
#   Inputs  : %rdi = destination, %rsi = source
#   Outputs : none (DIMENSION ERROR: zero shape, does not fit)
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = destination, %r12 = source,
#             %r13/%r14 = result rows/columns; frame RT_MAT_ENTER
# ---------------------------------------------------------------------
    .globl bsk_mat_copy
    .type bsk_mat_copy, @function
    .p2align 4
bsk_mat_copy:
    RT_MAT_ENTER
    movq %rdi, %rbx
    movq %rsi, %r12
    movq %r12, %rdi
    call .Lrt_mat_shape
    movq %rax, %r13
    movq %rdx, %r14
    movq %rbx, %rdi
    movq %r13, %rsi
    movq %r14, %rdx
    call .Lrt_mat_fits
    cmpq %rbx, %r12
    je .Lrt_mat_copy_done           # MAT A = A: nothing to do
    call .Lrt_mat_setshape          # %rdi %rsi %rdx still set
    movq %rbx, %rdi
    leaq RT_MAT_V0(%rsp), %rsi
    call .Lrt_mat_view
    movq %r12, %rdi
    leaq RT_MAT_V1(%rsp), %rsi
    call .Lrt_mat_view
    leaq RT_MAT_V0(%rsp), %rdi
    leaq RT_MAT_V1(%rsp), %rsi
    call bsk_kern_copy
.Lrt_mat_copy_done:
    RT_MAT_LEAVE
    .size bsk_mat_copy, . - bsk_mat_copy

# ---------------------------------------------------------------------
# RT_MAT_ELEMWISE name, kernel -- MAT C = A + B / A - B.
#   Inputs  : %rdi = destination, %rsi = A, %rdx = B
#   Outputs : none (DIMENSION ERROR, OVERFLOW)
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = destination, %r12 = A, %r13 = B,
#             %r14/%r15 = shape; frame RT_MAT_ENTER (views V0 = C,
#             V1 = A, V2 = B)
# ---------------------------------------------------------------------
.macro RT_MAT_ELEMWISE name, kernel
    .globl \name
    .type \name, @function
    .p2align 4
\name:
    RT_MAT_ENTER
    movq %rdi, %rbx
    movq %rsi, %r12
    movq %rdx, %r13
    movq %r12, %rdi
    call .Lrt_mat_shape             # shape of A
    movq %rax, %r14
    movq %rdx, %r15
    movq %r13, %rdi
    call .Lrt_mat_shape             # shape of B
    cmpq %r14, %rax
    jne .Lrt_mat_dimerr             # A and B must have the same shape
    cmpq %r15, %rdx
    jne .Lrt_mat_dimerr
    movq %rbx, %rdi
    movq %r14, %rsi
    movq %r15, %rdx
    call .Lrt_mat_fits
    cmpq %rbx, %r12
    je 1f                           # target is an operand: in place,
    cmpq %rbx, %r13                 # its shape is already the result's
    je 1f
    call .Lrt_mat_setshape          # else shape first, then write
1:
    movq %rbx, %rdi
    leaq RT_MAT_V0(%rsp), %rsi
    call .Lrt_mat_view
    movq %r12, %rdi
    leaq RT_MAT_V1(%rsp), %rsi
    call .Lrt_mat_view
    movq %r13, %rdi
    leaq RT_MAT_V2(%rsp), %rsi
    call .Lrt_mat_view
    leaq RT_MAT_V0(%rsp), %rdi
    leaq RT_MAT_V1(%rsp), %rsi
    leaq RT_MAT_V2(%rsp), %rdx
    call \kernel
    call .Lrt_mat_status            # OVERFLOW if not finite
    RT_MAT_LEAVE
    .size \name, . - \name
.endm

    RT_MAT_ELEMWISE bsk_mat_add, bsk_kern_add
    RT_MAT_ELEMWISE bsk_mat_sub, bsk_kern_sub

# ---------------------------------------------------------------------
# bsk_mat_scale -- MAT C = (K) * A.
#   Inputs  : %rdi = destination, %rsi = source, %xmm0 = K
#   Outputs : none (DIMENSION ERROR, OVERFLOW)
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = destination, %r12 = source,
#             %r14/%r15 = shape; frame RT_MAT_ENTER (K in RT_MAT_SLOT,
#             views V0 = C, V1 = A)
# ---------------------------------------------------------------------
    .globl bsk_mat_scale
    .type bsk_mat_scale, @function
    .p2align 4
bsk_mat_scale:
    RT_MAT_ENTER
    movq %rdi, %rbx
    movq %rsi, %r12
    movsd %xmm0, RT_MAT_SLOT(%rsp)  # K
    movq %r12, %rdi
    call .Lrt_mat_shape
    movq %rax, %r14
    movq %rdx, %r15
    movq %rbx, %rdi
    movq %r14, %rsi
    movq %r15, %rdx
    call .Lrt_mat_fits
    cmpq %rbx, %r12
    je 1f                           # in place
    call .Lrt_mat_setshape
1:
    movq %rbx, %rdi
    leaq RT_MAT_V0(%rsp), %rsi
    call .Lrt_mat_view
    movq %r12, %rdi
    leaq RT_MAT_V1(%rsp), %rsi
    call .Lrt_mat_view
    leaq RT_MAT_V0(%rsp), %rdi
    leaq RT_MAT_V1(%rsp), %rsi
    movsd RT_MAT_SLOT(%rsp), %xmm0
    call bsk_kern_scale
    call .Lrt_mat_status
    RT_MAT_LEAVE
    .size bsk_mat_scale, . - bsk_mat_scale

# ---------------------------------------------------------------------
# .Lrt_mat_finish -- common tail of *, TRN, INV (called with the
#   caller's RT_MAT_ENTER frame 8 bytes up, like .Lrt_mat_fillcur).
#   Purpose : if the target %rbx is an operand, the result was computed
#             into the temporary (caller's V0); set the target's shape
#             r x c and copy the temporary into it. Otherwise nothing:
#             the kernel already wrote into the target.
#   Inputs  : %rbx = target, %r14 = r, %r15 = c, %r13 = 1 when the
#             temporary was used
#   Clobbers: all caller-saved registers; the caller's V1
#   Frame   : 8 bytes (alignment pad)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_mat_finish:
    testq %r13, %r13
    jz 1f
    subq $8, %rsp                   # caller's frame now at 16(%rsp)
    movq %rbx, %rdi
    movq %r14, %rsi
    movq %r15, %rdx
    call .Lrt_mat_setshape
    leaq 16 + RT_MAT_V1(%rsp), %rsi
    call .Lrt_mat_view              # target view, new shape
    leaq 16 + RT_MAT_V1(%rsp), %rdi
    leaq 16 + RT_MAT_V0(%rsp), %rsi # the temporary
    call bsk_kern_copy
    addq $8, %rsp
1:
    ret

# ---------------------------------------------------------------------
# .Lrt_mat_resview -- where a *, TRN or INV result goes.
#   Purpose : target %rbx an operand (%rbx == %r12 or %rbx == %rdx
#             on entry) -> the temporary, r x c, %r13 = 1; else set the
#             target's shape to r x c and use its view, %r13 = 0.
#             Called like .Lrt_mat_finish; fills the caller's V0.
#   Inputs  : %rbx = target, %r12 = first operand, %rdx = second
#             operand (or the first again), %r14 = r, %r15 = c
#   Outputs : %r13 = temporary used; caller's V0 = result view
#   Clobbers: all caller-saved registers
#   Frame   : none (all helpers it calls are leaves)
# ---------------------------------------------------------------------
    .p2align 4
.Lrt_mat_resview:
    xorl %r13d, %r13d
    cmpq %rbx, %r12
    je 1f
    cmpq %rbx, %rdx
    je 1f
    movq %rbx, %rdi                 # not aliased: shape first, write
    movq %r14, %rsi                 # straight into the target
    movq %r15, %rdx
    call .Lrt_mat_setshape
    leaq 8 + RT_MAT_V0(%rsp), %rsi
    jmp .Lrt_mat_view               # tail call fills the view
1:
    movl $1, %r13d                  # aliased: the result temporary
    leaq 8 + RT_MAT_V0(%rsp), %rdi
    movq %r14, %rsi
    movq %r15, %rdx
    jmp .Lrt_mat_tmpview

# ---------------------------------------------------------------------
# bsk_mat_mul -- MAT C = A * B.
#   Inputs  : %rdi = destination, %rsi = A, %rdx = B
#   Outputs : none (DIMENSION ERROR, OVERFLOW)
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = destination, %r12 = A, %r13 = B (then
#             "temporary used"), %r14 = rows of A, %r15 = columns of B;
#             frame RT_MAT_ENTER (V0 = result, V1 = A, V2 = B)
# ---------------------------------------------------------------------
    .globl bsk_mat_mul
    .type bsk_mat_mul, @function
    .p2align 4
bsk_mat_mul:
    RT_MAT_ENTER
    movq %rdi, %rbx
    movq %rsi, %r12
    movq %rdx, %r13
    movq %r12, %rdi
    call .Lrt_mat_shape             # A: m x p
    movq %rax, %r14
    movq %rdx, RT_MAT_SLOT(%rsp)    # p
    movq %r13, %rdi
    call .Lrt_mat_shape             # B: p2 x n
    cmpq RT_MAT_SLOT(%rsp), %rax
    jne .Lrt_mat_dimerr             # columns of A != rows of B
    movq %rdx, %r15                 # n
    movq %rbx, %rdi
    movq %r14, %rsi
    movq %r15, %rdx
    call .Lrt_mat_fits              # result m x n must fit the target
    # operand views first (the target's shape may change next)
    movq %r12, %rdi
    leaq RT_MAT_V1(%rsp), %rsi
    call .Lrt_mat_view
    movq %r13, %rdi
    leaq RT_MAT_V2(%rsp), %rsi
    call .Lrt_mat_view
    movq %r13, %rdx                 # second operand
    call .Lrt_mat_resview           # V0 = target or temporary
    leaq RT_MAT_V0(%rsp), %rdi
    leaq RT_MAT_V1(%rsp), %rsi
    leaq RT_MAT_V2(%rsp), %rdx
    call bsk_kern_gemm
    call .Lrt_mat_status            # OVERFLOW if not finite
    call .Lrt_mat_finish
    RT_MAT_LEAVE
    .size bsk_mat_mul, . - bsk_mat_mul

# ---------------------------------------------------------------------
# bsk_mat_trn -- MAT C = TRN(A).
#   Inputs  : %rdi = destination, %rsi = source
#   Outputs : none (DIMENSION ERROR)
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = destination, %r12 = source, %r13 =
#             temporary used, %r14/%r15 = result shape (n x m);
#             frame RT_MAT_ENTER (V0 = result, V1 = source)
# ---------------------------------------------------------------------
    .globl bsk_mat_trn
    .type bsk_mat_trn, @function
    .p2align 4
bsk_mat_trn:
    RT_MAT_ENTER
    movq %rdi, %rbx
    movq %rsi, %r12
    movq %r12, %rdi
    call .Lrt_mat_shape             # A: m x n
    movq %rdx, %r14                 # result rows = n
    movq %rax, %r15                 # result columns = m
    movq %rbx, %rdi
    movq %r14, %rsi
    movq %r15, %rdx
    call .Lrt_mat_fits
    movq %r12, %rdi
    leaq RT_MAT_V1(%rsp), %rsi
    call .Lrt_mat_view
    movq %r12, %rdx                 # only one operand
    call .Lrt_mat_resview
    leaq RT_MAT_V0(%rsp), %rdi
    leaq RT_MAT_V1(%rsp), %rsi
    call bsk_kern_trn
    call .Lrt_mat_finish
    RT_MAT_LEAVE
    .size bsk_mat_trn, . - bsk_mat_trn

# ---------------------------------------------------------------------
# bsk_mat_inv -- MAT C = INV(A) (LANGUAGE.md 7.14.6).
#   Inputs  : %rdi = destination, %rsi = source
#   Outputs : none (DIMENSION ERROR, SINGULAR MATRIX, OVERFLOW)
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = destination, %r12 = source, %r13 =
#             temporary used, %r14/%r15 = shape (n x n);
#             frame RT_MAT_ENTER (V0 = result, V1 = source)
# ---------------------------------------------------------------------
    .globl bsk_mat_inv
    .type bsk_mat_inv, @function
    .p2align 4
bsk_mat_inv:
    RT_MAT_ENTER
    movq %rdi, %rbx
    movq %rsi, %r12
    movq %r12, %rdi
    call .Lrt_mat_shape
    cmpq %rax, %rdx
    jne .Lrt_mat_dimerr             # INV needs a square matrix
    movq %rax, %r14
    movq %rdx, %r15
    movq %rbx, %rdi
    movq %r14, %rsi
    movq %r15, %rdx
    call .Lrt_mat_fits
    # The kernel's static workspace bounds n. Storage limits keep every
    # BASIC matrix far below it (n <= 999); the test only guards the
    # kernel's precondition (same as the arm64 runtime).
    cmpq $RT_KERN_INV_MAXN, %r14
    ja .Lrt_mat_dimerr
    movq %r12, %rdi
    leaq RT_MAT_V1(%rsp), %rsi
    call .Lrt_mat_view
    movq %r12, %rdx
    call .Lrt_mat_resview
    leaq RT_MAT_V0(%rsp), %rdi
    leaq RT_MAT_V1(%rsp), %rsi
    call bsk_kern_inv               # n <= RT_KERN_INV_MAXN (guarded above)
    call .Lrt_mat_status            # SINGULAR MATRIX / OVERFLOW
    call .Lrt_mat_finish
    RT_MAT_LEAVE
    .size bsk_mat_inv, . - bsk_mat_inv

    .section .rodata
    .p2align 3
.Lrt_mat_half:
    .double 0.5
.Lrt_mat_one:
    .double 1.0
.Lrt_mat_two31:
    .quad RT_MAT_TWO31_BITS         # 2^31

# MAT result temporary (DESIGN.md 6.6.6): RT_MAT_SCRATCH_ELEMS doubles
    .bss
    .p2align 6
.Lrt_mat_tmp:
    .zero RT_MAT_SCRATCH_ELEMS * 8

    .section .note.GNU-stack,"",@progbits
