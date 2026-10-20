# =====================================================================
# src/runtime_x86_64_linux/rt_sub.s -- SUB activations and the call
# stack (LANGUAGE.md 7.27; DESIGN.md 5.3.1, 5.4.6, 6.9).
#
# Defines (global, runtime.inc):
#   bsk_sub_enter bsk_sub_leave
# Uses (private): bsk_rt_gosub_depth, bsk_rt_gosub_base (rt_gosub.s).
# Uses (global): bsk_curline (rt_main.s), calloc, free (libc), bsk_err
#   (rt_error.s).
#
# A CALL runs the SUB body, whose prologue calls bsk_sub_enter with the
# unit's SUBL_* record and the argument vector; SUBEND (subret) calls
# bsk_sub_leave. Each active activation has one call record of
# RT_CALL_RECSIZE bytes on the call stack:
#   RT_CALL_BLOCK  ptr  the activation block (calloc'd, SUBL_BLOCKSIZE)
#   RT_CALL_SUBL   ptr  the unit's SUBL_* record
#   RT_CALL_GBASE  u64  the GOSUB base of the calling activation
#   RT_CALL_LINE   u32  bsk_curline at the CALL (restored at SUBEND)
# At most LIM_CALL_DEPTH activations are active, and the sum of their
# SUBL_COST never exceeds LIM_CALL_WORDS; either limit gives TOO MANY
# CALLS. Both depend only on the program text (LANGUAGE.md 7.27).
# =====================================================================
.include "baysick.inc"

.equ RT_CALL_BLOCK,   0
.equ RT_CALL_SUBL,    8
.equ RT_CALL_GBASE,   16
.equ RT_CALL_LINE,    24
.equ RT_CALL_RECSIZE, 32            # DESIGN.md 6.1: records of 32 bytes

    .text

# ---------------------------------------------------------------------
# bsk_sub_enter -- start an activation of a SUB unit (LANGUAGE.md 7.27
#   step 2, DESIGN.md 6.9).
#   Purpose : in this order: LIM_CALL_DEPTH activations already active
#             -> TOO MANY CALLS; summed cost + SUBL_COST > LIM_CALL_WORDS
#             -> TOO MANY CALLS; for each parameter k (left to right)
#             with SUBL_PDIMS[k] = SUBD_LIST / SUBD_TABLE: argument k's
#             RTA_DIMS != 1 / 2 -> DIMENSION ERROR; calloc(1,
#             SUBL_BLOCKSIZE) = NULL -> OUT OF ROOM. Then: summed cost
#             += SUBL_COST; the NPARAMS argument pointers copied to
#             block + SUBL_PARAMOFF; the SUBL_NDESC RTA templates copied
#             to block + SUBL_DESCOFF, each copy's RTA_DATA (a block
#             offset) plus the block address; the call record {block,
#             SUBL, GOSUB base, bsk_curline} pushed; GOSUB base := GOSUB
#             depth. Errors report the CALL line (bsk_curline is not
#             changed here).
#   Inputs  : %rdi = SUBL_* record, %rsi = argument vector
#             (SUBL_NPARAMS pointers)
#   Outputs : %rax = the zero-filled activation block
#   Errors  : TOO MANY CALLS, DIMENSION ERROR, OUT OF ROOM
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = SUBL record, %r12 = argument vector,
#             %r13 = block, %r14 = loop index, %rbp = frame pointer
#   Frame   : 40 bytes (%rbp, %rbx, %r12, %r13, %r14); %rsp = 0
#             (mod 16) at the call
# ---------------------------------------------------------------------
    .globl bsk_sub_enter
    .type bsk_sub_enter, @function
    .p2align 4
bsk_sub_enter:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14                      # 5 pushes: %rsp = 0 (mod 16)
    movq %rdi, %rbx
    movq %rsi, %r12

    # Limit 1: the number of active activations.
    cmpq $LIM_CALL_DEPTH, .Lrt_sub_depth(%rip)
    jae .Lrt_sub_too_many
    # Limit 2: the call budget (64-bit sum, no overflow possible).
    movl SUBL_COST(%rbx), %eax
    addq .Lrt_sub_cost(%rip), %rax
    cmpq $LIM_CALL_WORDS, %rax
    ja .Lrt_sub_too_many

    # Array parameters whose dimensionality the unit fixes.
    xorl %r14d, %r14d               # k
.Lrt_sub_dims_loop:
    cmpl SUBL_NPARAMS(%rbx), %r14d
    jae .Lrt_sub_dims_done
    movzbl SUBL_PDIMS(%rbx,%r14), %eax
    cmpl $SUBD_LIST, %eax
    je 1f
    cmpl $SUBD_TABLE, %eax
    jne .Lrt_sub_dims_next          # scalar or any array: not checked
1:
    movq (%r12,%r14,8), %rdx        # argument k: an RTA descriptor
    cmpl RTA_DIMS(%rdx), %eax       # SUBD_LIST = 1, SUBD_TABLE = 2 dims
    jne .Lrt_sub_dim_err
.Lrt_sub_dims_next:
    addl $1, %r14d
    jmp .Lrt_sub_dims_loop
.Lrt_sub_dims_done:

    # The activation block, zero-filled: every variable starts fresh.
    movl $1, %edi
    movl SUBL_BLOCKSIZE(%rbx), %esi
    call calloc@PLT
    testq %rax, %rax
    jz .Lrt_sub_room
    movq %rax, %r13

    # Committed: count the cost.
    movl SUBL_COST(%rbx), %eax
    addq %rax, .Lrt_sub_cost(%rip)

    # Parameter pointers to block + SUBL_PARAMOFF.
    movl SUBL_PARAMOFF(%rbx), %edi
    addq %r13, %rdi                 # destination
    xorl %ecx, %ecx
.Lrt_sub_param_loop:
    cmpl SUBL_NPARAMS(%rbx), %ecx
    jae .Lrt_sub_param_done
    movq (%r12,%rcx,8), %rax
    movq %rax, (%rdi,%rcx,8)
    addl $1, %ecx
    jmp .Lrt_sub_param_loop
.Lrt_sub_param_done:

    # Descriptor templates to block + SUBL_DESCOFF, RTA_DATA relocated.
    movl SUBL_DESCOFF(%rbx), %edi
    addq %r13, %rdi                 # destination descriptor
    movq SUBL_DESCS(%rbx), %rsi     # source template (0 when none)
    movl SUBL_NDESC(%rbx), %ecx
.Lrt_sub_desc_loop:
    testl %ecx, %ecx
    jz .Lrt_sub_desc_done
    movdqu (%rsi), %xmm0            # copy the RTA_SIZE (32) bytes
    movdqu 16(%rsi), %xmm1
    movdqu %xmm0, (%rdi)
    movdqu %xmm1, 16(%rdi)
    addq %r13, RTA_DATA(%rdi)       # block offset -> address
    addq $RTA_SIZE, %rsi
    addq $RTA_SIZE, %rdi
    subl $1, %ecx
    jmp .Lrt_sub_desc_loop
.Lrt_sub_desc_done:

    # Push the call record and start this activation's GOSUB range.
    movq .Lrt_sub_depth(%rip), %rax
    movq %rax, %rcx
    shlq $5, %rcx                   # depth * RT_CALL_RECSIZE
    leaq .Lrt_sub_stack(%rip), %rdx
    addq %rcx, %rdx                 # the new record
    movq %r13, RT_CALL_BLOCK(%rdx)
    movq %rbx, RT_CALL_SUBL(%rdx)
    movq bsk_rt_gosub_base(%rip), %rcx
    movq %rcx, RT_CALL_GBASE(%rdx)
    movl bsk_curline(%rip), %ecx
    movl %ecx, RT_CALL_LINE(%rdx)   # the CALL line
    addq $1, %rax
    movq %rax, .Lrt_sub_depth(%rip)
    movq bsk_rt_gosub_depth(%rip), %rcx
    movq %rcx, bsk_rt_gosub_base(%rip)  # base := depth

    movq %r13, %rax                 # return the block
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret
.Lrt_sub_too_many:
    movl $ERR_TOO_MANY_CALLS, %edi
    jmp bsk_err                     # noreturn; realigns the stack
.Lrt_sub_dim_err:
    movl $ERR_DIMENSION_ERROR, %edi
    jmp bsk_err
.Lrt_sub_room:
    movl $ERR_OUT_OF_ROOM, %edi
    jmp bsk_err
    .size bsk_sub_enter, . - bsk_sub_enter

# RT_CALL_RECSIZE is 1 << 5 (the shifts above and below depend on it).
.if (RT_CALL_RECSIZE != 32)
.error "rt_sub.s: RT_CALL_RECSIZE must be 32"
.endif

# ---------------------------------------------------------------------
# bsk_sub_leave -- end the newest activation (SUBEND, LANGUAGE.md 7.27
#   step 5, DESIGN.md 6.9).
#   Purpose : pop the newest call record; summed cost -= its SUBL_COST;
#             free the buffer of every SD record with SD_CAP > 0 among
#             the SUBL_NSD records at block + SUBL_SDOFF; free the
#             block; GOSUB depth := the current GOSUB base (pending
#             GOSUBs of the activation are dropped); GOSUB base := the
#             saved base; bsk_curline := the saved CALL line.
#   Inputs  : none (an activation is active: only SUB bodies call it)
#   Outputs : none
#   Clobbers: all caller-saved registers
#   Callee-saved used: %rbx = the call record, %r12 = SD cursor,
#             %r13 = SD records left, %rbp = frame pointer
#   Frame   : 40 bytes (%rbp, %rbx, %r12, %r13 + 8 bytes pad)
# ---------------------------------------------------------------------
    .globl bsk_sub_leave
    .type bsk_sub_leave, @function
    .p2align 4
bsk_sub_leave:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    subq $8, %rsp                   # %rsp = 0 (mod 16) at calls

    # Pop the record.
    movq .Lrt_sub_depth(%rip), %rax
    subq $1, %rax
    movq %rax, .Lrt_sub_depth(%rip)
    shlq $5, %rax                   # depth * RT_CALL_RECSIZE
    leaq .Lrt_sub_stack(%rip), %rbx
    addq %rax, %rbx                 # the record being popped

    # Give the activation's budget back.
    movq RT_CALL_SUBL(%rbx), %rdx
    movl SUBL_COST(%rdx), %eax
    subq %rax, .Lrt_sub_cost(%rip)

    # Free the string buffers the block's SD records own.
    movq RT_CALL_BLOCK(%rbx), %r12
    movl SUBL_SDOFF(%rdx), %eax
    addq %rax, %r12                 # first SD record
    movl SUBL_NSD(%rdx), %r13d
.Lrt_sub_free_loop:
    testl %r13d, %r13d
    jz .Lrt_sub_free_done
    cmpl $0, SD_CAP(%r12)
    je 1f                           # not owned: nothing to free
    movq SD_PTR(%r12), %rdi
    call free@PLT
1:
    addq $SD_SIZE, %r12
    subl $1, %r13d
    jmp .Lrt_sub_free_loop
.Lrt_sub_free_done:
    movq RT_CALL_BLOCK(%rbx), %rdi
    call free@PLT                   # the block itself

    # Drop the activation's pending GOSUBs, restore the caller's state.
    movq bsk_rt_gosub_base(%rip), %rax
    movq %rax, bsk_rt_gosub_depth(%rip)
    movq RT_CALL_GBASE(%rbx), %rax
    movq %rax, bsk_rt_gosub_base(%rip)
    movl RT_CALL_LINE(%rbx), %eax
    movl %eax, bsk_curline(%rip)    # the CALL line is current again

    addq $8, %rsp
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret
    .size bsk_sub_leave, . - bsk_sub_leave

# State: number of active activations, their summed SUBL_COST (u64,
# both initially 0) and LIM_CALL_DEPTH call records.
    .bss
    .p2align 3
.Lrt_sub_depth:
    .zero 8
.Lrt_sub_cost:
    .zero 8
.Lrt_sub_stack:
    .zero (RT_CALL_RECSIZE * LIM_CALL_DEPTH)

    .section .note.GNU-stack,"",@progbits
