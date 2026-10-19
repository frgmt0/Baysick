# =====================================================================
# src/runtime_x86_64_linux/rt_data.s -- READ from the program's DATA
# block.
#
# Defines: bsk_read
# Uses (defined by every compiled program): bsk_data (double[]),
# bsk_data_count (u64).
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

# DATA cursor: index of the next value to read, initially 0.
    .bss
    .p2align 3
.Lrt_data_cursor:
    .zero 8

    .section .note.GNU-stack,"",@progbits
