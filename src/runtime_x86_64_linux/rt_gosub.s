# =====================================================================
# src/runtime_x86_64_linux/rt_gosub.s -- GOSUB return-address stack.
#
# Defines: bsk_gosub_push bsk_gosub_pop
# The stack holds LIM_GOSUB_DEPTH machine addresses (return labels in
# compiled code). Pushing onto a full stack is TOO MANY GOSUBS; popping
# an empty one is ILLEGAL RETURN.
# =====================================================================
.include "baysick.inc"

    .text

# ---------------------------------------------------------------------
# bsk_gosub_push -- push a return address.
#   Inputs  : %rdi = code address to return to
#   Outputs : none
#   Errors  : LIM_GOSUB_DEPTH addresses already pending -> TOO MANY GOSUBS
#   Clobbers: %rax, %rcx, %rdi
#   Callee-saved used: none
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_gosub_push
    .type bsk_gosub_push, @function
    .p2align 4
bsk_gosub_push:
    movq .Lrt_gosub_depth(%rip), %rax
    cmpq $LIM_GOSUB_DEPTH, %rax
    jae .Lrt_gosub_full
    leaq .Lrt_gosub_stack(%rip), %rcx
    movq %rdi, (%rcx,%rax,8)        # stack[depth] = address
    addq $1, %rax
    movq %rax, .Lrt_gosub_depth(%rip)
    ret
.Lrt_gosub_full:
    movl $ERR_TOO_MANY_GOSUBS, %edi
    jmp bsk_err
    .size bsk_gosub_push, . - bsk_gosub_push

# ---------------------------------------------------------------------
# bsk_gosub_pop -- pop the most recent return address.
#   Inputs  : none
#   Outputs : %rax = code address
#   Errors  : stack empty -> ILLEGAL RETURN
#   Clobbers: %rax, %rcx, %rdx, %rdi
#   Callee-saved used: none
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_gosub_pop
    .type bsk_gosub_pop, @function
    .p2align 4
bsk_gosub_pop:
    movq .Lrt_gosub_depth(%rip), %rdx
    testq %rdx, %rdx
    jz .Lrt_gosub_empty
    subq $1, %rdx                   # top index
    movq %rdx, .Lrt_gosub_depth(%rip)
    leaq .Lrt_gosub_stack(%rip), %rcx
    movq (%rcx,%rdx,8), %rax
    ret
.Lrt_gosub_empty:
    movl $ERR_ILLEGAL_RETURN, %edi
    jmp bsk_err
    .size bsk_gosub_pop, . - bsk_gosub_pop

# State: depth (u64) and LIM_GOSUB_DEPTH 8-byte return addresses.
    .bss
    .p2align 3
.Lrt_gosub_depth:
    .zero 8
.Lrt_gosub_stack:
    .zero (8 * LIM_GOSUB_DEPTH)

    .section .note.GNU-stack,"",@progbits
