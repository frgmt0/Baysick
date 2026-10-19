# =====================================================================
# src/runtime_x86_64_linux/rt_data.s -- READ, string READ, MAT READ of
# a string list and RESTORE on the program's two DATA blocks
# (LANGUAGE.md 7.4, 7.5, 7.14.4, 7.16; DESIGN.md 6.7).
#
# Defines: bsk_read bsk_sread bsk_sread_el bsk_restore bsk_smat_read
# Uses: bsk_saref1 (rt_array.s), bsk_rt_str_assign (rt_str.s).
# Uses (defined by every compiled program): bsk_data (double[]),
# bsk_data_count (u64), bsk_sdata (SD[], CAP 0), bsk_sdata_count (u64).
# The numeric and the string block have independent cursors.
# =====================================================================
.include "baysick.inc"

    .text

# ---------------------------------------------------------------------
# bsk_read -- next DATA value, in program order.
#   Inputs  : none
#   Outputs : %xmm0 = value
#   Errors  : no value left -> OUT OF DATA (the program ends, exit 0)
#   Clobbers: %rax, %rcx, %rdi, %xmm0
#   Callee-saved used: none
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_read
    .type bsk_read, @function
    .p2align 4
bsk_read:
    movq .Lrt_data_cursor(%rip), %rax   # index of next value
    cmpq bsk_data_count(%rip), %rax
    jae .Lrt_data_out                   # block exhausted
    leaq bsk_data(%rip), %rcx
    movsd (%rcx,%rax,8), %xmm0          # bsk_data[cursor]
    addq $1, %rax
    movq %rax, .Lrt_data_cursor(%rip)
    ret
.Lrt_data_out:
    movl $ERR_OUT_OF_DATA, %edi
    jmp bsk_err                         # prints OUT OF DATA IN n, exit 0
    .size bsk_read, . - bsk_read

# ---------------------------------------------------------------------
# bsk_sread -- next string DATA value (LANGUAGE.md 7.4, DESIGN.md 6.7).
#   Purpose : copy the next record of the string block (bsk_sdata, own
#             cursor) into dst with bsk_str_set semantics.
#   Inputs  : %rdi = destination SD
#   Outputs : none
#   Errors  : no value left -> OUT OF DATA (the program ends, exit 0);
#             OUT OF ROOM
#   Clobbers: all caller-saved registers
#   Callee-saved used: none
#   Frame   : none (tail jump to bsk_rt_str_assign / bsk_err)
# ---------------------------------------------------------------------
    .globl bsk_sread
    .type bsk_sread, @function
    .p2align 4
bsk_sread:
    movq .Lrt_data_scursor(%rip), %rax  # index of the next string
    cmpq bsk_sdata_count(%rip), %rax
    jae .Lrt_data_out                   # string block exhausted
    leaq 1(%rax), %rcx
    movq %rcx, .Lrt_data_scursor(%rip)
    imulq $SD_SIZE, %rax, %rax
    leaq bsk_sdata(%rip), %rcx
    addq %rcx, %rax                     # &bsk_sdata[cursor]
    movl SD_LEN(%rax), %edx             # n
    movq SD_PTR(%rax), %rsi             # bytes (never written: CAP 0)
    jmp bsk_rt_str_assign               # dst := copy
    .size bsk_sread, . - bsk_sread

# ---------------------------------------------------------------------
# bsk_sread_el -- READ into a string list element L$(i) (the element
#   form of `sread`, IR.md 3.2): the next string DATA value is taken
#   first, then the subscript is checked at the store (LANGUAGE.md 7.1,
#   7.4), then the value is copied as by bsk_sread.
#   Inputs  : %rdi = string-list descriptor (RTA_*), %xmm0 = subscript i
#   Outputs : none
#   Errors  : no value left -> OUT OF DATA (exit 0); then SUBSCRIPT
#             ERROR (bsk_saref1); OUT OF ROOM
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = the source SD, %rbp = frame pointer
#   Frame   : 24 bytes (%rbp, %rbx + 8 bytes pad); tail jump to
#             bsk_rt_str_assign
# ---------------------------------------------------------------------
    .globl bsk_sread_el
    .type bsk_sread_el, @function
    .p2align 4
bsk_sread_el:
    movq .Lrt_data_scursor(%rip), %rax  # index of the next string
    cmpq bsk_sdata_count(%rip), %rax
    jae .Lrt_data_out                   # string block exhausted
    leaq 1(%rax), %rcx
    movq %rcx, .Lrt_data_scursor(%rip)
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    subq $8, %rsp                       # %rsp = 0 (mod 16)
    imulq $SD_SIZE, %rax, %rax
    leaq bsk_sdata(%rip), %rbx
    addq %rax, %rbx                     # &bsk_sdata[cursor]
    call bsk_saref1                     # %rax = &L$(i); SUBSCRIPT ERROR
    movq %rax, %rdi
    movl SD_LEN(%rbx), %edx             # n
    movq SD_PTR(%rbx), %rsi             # bytes (never written: CAP 0)
    addq $8, %rsp
    popq %rbx
    popq %rbp
    jmp bsk_rt_str_assign               # element := copy
    .size bsk_sread_el, . - bsk_sread_el

# ---------------------------------------------------------------------
# bsk_restore -- RESTORE / RESTORE* / RESTORE$ (LANGUAGE.md 7.16).
#   Inputs  : %edi = RESTORE_ALL (both cursors), RESTORE_NUM (numeric
#             cursor) or RESTORE_STR (string cursor)
#   Outputs : none
#   Clobbers: none
#   Callee-saved used: none
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_restore
    .type bsk_restore, @function
    .p2align 4
bsk_restore:
    cmpl $RESTORE_STR, %edi
    je 1f                               # RESTORE$: strings only
    movq $0, .Lrt_data_cursor(%rip)     # RESTORE, RESTORE*: numbers
    cmpl $RESTORE_NUM, %edi
    je 2f                               # RESTORE*: numbers only
1:
    movq $0, .Lrt_data_scursor(%rip)    # RESTORE, RESTORE$: strings
2:
    ret
    .size bsk_restore, . - bsk_restore

# ---------------------------------------------------------------------
# bsk_smat_read -- MAT READ of a string list with its current bound
#   (LANGUAGE.md 7.14.4, DESIGN.md 6.5).
#   Purpose : bound 0 -> DIMENSION ERROR; else elements 1 .. B1 receive
#             the next string DATA values, each stored at once (an OUT
#             OF DATA in the middle leaves the earlier ones stored).
#   Inputs  : %rdi = string-list descriptor (RTA_*)
#   Outputs : none
#   Errors  : DIMENSION ERROR, OUT OF DATA (exit 0), OUT OF ROOM
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = current element (SD*), %r12 = elements
#             left, %rbp = frame pointer
#   Frame   : 24 bytes (%rbp, %rbx, %r12)
# ---------------------------------------------------------------------
    .globl bsk_smat_read
    .type bsk_smat_read, @function
    .p2align 4
bsk_smat_read:
    movl RTA_B1(%rdi), %eax             # current bound n
    testl %eax, %eax
    jz .Lrt_data_dimerr                 # a list of no elements
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12                          # 3 pushes: %rsp = 0 (mod 16)
    movq %rax, %r12                     # elements left
    movq RTA_DATA(%rdi), %rbx
    addq $SD_SIZE, %rbx                 # element 1
.Lrt_data_smat_loop:
    movq %rbx, %rdi
    call bsk_sread                      # next string value, stored now
    addq $SD_SIZE, %rbx
    subq $1, %r12
    jnz .Lrt_data_smat_loop
    popq %r12
    popq %rbx
    popq %rbp
    ret
.Lrt_data_dimerr:
    movl $ERR_DIMENSION_ERROR, %edi
    jmp bsk_err
    .size bsk_smat_read, . - bsk_smat_read

# DATA cursor: index of the next value to read, initially 0.
    .bss
    .p2align 3
.Lrt_data_cursor:
    .zero 8
# String DATA cursor: index of the next string record, initially 0.
.Lrt_data_scursor:
    .zero 8

    .section .note.GNU-stack,"",@progbits
