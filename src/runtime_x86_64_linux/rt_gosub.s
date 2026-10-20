# =====================================================================
# src/runtime_x86_64_linux/rt_gosub.s -- GOSUB return-address stack.
#
# Defines: bsk_gosub_push bsk_gosub_pop
# Defines (private to the runtime, .globl + .hidden; used by rt_sub.s):
#   bsk_rt_gosub_depth   u64, number of pending GOSUBs (all activations)
#   bsk_rt_gosub_base    u64, depth when the current SUB activation
#                        started (0 in the main program, DESIGN.md 6.9)
# The stack holds LIM_GOSUB_DEPTH machine addresses (return labels in
# compiled code), counted over all activations. Pushing onto a full
# stack is TOO MANY GOSUBS; popping when no GOSUB of the current
# activation is pending (depth = base) is ILLEGAL RETURN.
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
    movq bsk_rt_gosub_depth(%rip), %rax
    cmpq $LIM_GOSUB_DEPTH, %rax
    jae .Lrt_gosub_full
    leaq .Lrt_gosub_stack(%rip), %rcx
    movq %rdi, (%rcx,%rax,8)        # stack[depth] = address
    addq $1, %rax
    movq %rax, bsk_rt_gosub_depth(%rip)
    ret
.Lrt_gosub_full:
    movl $ERR_TOO_MANY_GOSUBS, %edi
    jmp bsk_err
    .size bsk_gosub_push, . - bsk_gosub_push

# ---------------------------------------------------------------------
# bsk_gosub_pop -- pop the most recent return address of the current
#   activation.
#   Inputs  : none
#   Outputs : %rax = code address
#   Errors  : depth = GOSUB base (none of this activation pending)
#             -> ILLEGAL RETURN
#   Clobbers: %rax, %rcx, %rdx, %rdi
#   Callee-saved used: none
#   Frame   : none (leaf)
# ---------------------------------------------------------------------
    .globl bsk_gosub_pop
    .type bsk_gosub_pop, @function
    .p2align 4
bsk_gosub_pop:
    movq bsk_rt_gosub_depth(%rip), %rdx
    cmpq bsk_rt_gosub_base(%rip), %rdx
    jbe .Lrt_gosub_empty            # depth = base: nothing of ours
    subq $1, %rdx                   # top index
    movq %rdx, bsk_rt_gosub_depth(%rip)
    leaq .Lrt_gosub_stack(%rip), %rcx
    movq (%rcx,%rdx,8), %rax
    ret
.Lrt_gosub_empty:
    movl $ERR_ILLEGAL_RETURN, %edi
    jmp bsk_err
    .size bsk_gosub_pop, . - bsk_gosub_pop

# State: depth and base (u64), LIM_GOSUB_DEPTH 8-byte return addresses.
    .bss
    .p2align 3
    .globl bsk_rt_gosub_depth
    .hidden bsk_rt_gosub_depth
bsk_rt_gosub_depth:
    .zero 8
    .globl bsk_rt_gosub_base
    .hidden bsk_rt_gosub_base
bsk_rt_gosub_base:
    .zero 8
.Lrt_gosub_stack:
    .zero (8 * LIM_GOSUB_DEPTH)

    .section .note.GNU-stack,"",@progbits
