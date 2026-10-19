# peak_x86_64.s -- peak floating-point rates of the x86_64 SSE2 and AVX2+FMA units (BENCH.md 3.4).
#
# double peak_sse2(uint64_t iterations)       System V AMD64, GNU as (AT&T syntax)
# double peak_avx2_fma(uint64_t iterations)   only call when the CPU and OS support AVX2 and FMA
#
# peak_sse2: iterations x 12 independent chains of `mulpd` + `addpd` (acc = acc*1.0 + 1.0), no
#   memory traffic; each pair is 2 lanes x (1 multiply + 1 add) = 4 flops per chain, so a call
#   performs 48 * iterations flops. 12 chains cover the mul+add latency.
# peak_avx2_fma: iterations x 12 independent chains of `vfmadd231pd ymm` (acc += 1.0*1.0);
#   4 lanes x 2 = 8 flops per instruction, 96 * iterations flops per call. Ends with vzeroupper.
#
# In:  %rdi = iterations (>= 1)
# Out: %xmm0 low double = chain 0 = 1.0 + iterations (exact below 2^53): the caller checks it
# Clobbers: %rax, %rdi, %xmm0-%xmm15 / %ymm0-%ymm15 (all caller-saved), no stack use.
    .text

    .globl  peak_sse2
    .type   peak_sse2, @function
    .p2align 4
peak_sse2:
    movq    $0x3ff0000000000000, %rax   # 1.0
    movq    %rax, %xmm14
    unpcklpd %xmm14, %xmm14             # both lanes 1.0: multiplicand
    movapd  %xmm14, %xmm15              # addend
    movapd  %xmm14, %xmm0               # accumulators start at 1.0
    movapd  %xmm14, %xmm1
    movapd  %xmm14, %xmm2
    movapd  %xmm14, %xmm3
    movapd  %xmm14, %xmm4
    movapd  %xmm14, %xmm5
    movapd  %xmm14, %xmm6
    movapd  %xmm14, %xmm7
    movapd  %xmm14, %xmm8
    movapd  %xmm14, %xmm9
    movapd  %xmm14, %xmm10
    movapd  %xmm14, %xmm11
.Lpeak_sse2_loop:
    # chain k: acc = acc * 1.0 + 1.0; mul and add interleaved so the scheduler keeps the
    # multiplies off the port the adds need
    mulpd   %xmm14, %xmm0
    addpd   %xmm15, %xmm0
    mulpd   %xmm14, %xmm1
    addpd   %xmm15, %xmm1
    mulpd   %xmm14, %xmm2
    addpd   %xmm15, %xmm2
    mulpd   %xmm14, %xmm3
    addpd   %xmm15, %xmm3
    mulpd   %xmm14, %xmm4
    addpd   %xmm15, %xmm4
    mulpd   %xmm14, %xmm5
    addpd   %xmm15, %xmm5
    mulpd   %xmm14, %xmm6
    addpd   %xmm15, %xmm6
    mulpd   %xmm14, %xmm7
    addpd   %xmm15, %xmm7
    mulpd   %xmm14, %xmm8
    addpd   %xmm15, %xmm8
    mulpd   %xmm14, %xmm9
    addpd   %xmm15, %xmm9
    mulpd   %xmm14, %xmm10
    addpd   %xmm15, %xmm10
    mulpd   %xmm14, %xmm11
    addpd   %xmm15, %xmm11
    decq    %rdi
    jnz     .Lpeak_sse2_loop
    ret
    .size   peak_sse2, .-peak_sse2

    .globl  peak_avx2_fma
    .type   peak_avx2_fma, @function
    .p2align 4
peak_avx2_fma:
    movq    $0x3ff0000000000000, %rax   # 1.0
    vmovq   %rax, %xmm14
    vbroadcastsd %xmm14, %ymm14         # four lanes of 1.0: both multiplicands
    vmovapd %ymm14, %ymm0               # accumulators start at 1.0
    vmovapd %ymm14, %ymm1
    vmovapd %ymm14, %ymm2
    vmovapd %ymm14, %ymm3
    vmovapd %ymm14, %ymm4
    vmovapd %ymm14, %ymm5
    vmovapd %ymm14, %ymm6
    vmovapd %ymm14, %ymm7
    vmovapd %ymm14, %ymm8
    vmovapd %ymm14, %ymm9
    vmovapd %ymm14, %ymm10
    vmovapd %ymm14, %ymm11
.Lpeak_avx2_loop:
    vfmadd231pd %ymm14, %ymm14, %ymm0   # acc += 1.0 * 1.0, 12 independent chains
    vfmadd231pd %ymm14, %ymm14, %ymm1
    vfmadd231pd %ymm14, %ymm14, %ymm2
    vfmadd231pd %ymm14, %ymm14, %ymm3
    vfmadd231pd %ymm14, %ymm14, %ymm4
    vfmadd231pd %ymm14, %ymm14, %ymm5
    vfmadd231pd %ymm14, %ymm14, %ymm6
    vfmadd231pd %ymm14, %ymm14, %ymm7
    vfmadd231pd %ymm14, %ymm14, %ymm8
    vfmadd231pd %ymm14, %ymm14, %ymm9
    vfmadd231pd %ymm14, %ymm14, %ymm10
    vfmadd231pd %ymm14, %ymm14, %ymm11
    decq    %rdi
    jnz     .Lpeak_avx2_loop
    vzeroupper                          # leave AVX state clean; xmm0 low double is the result
    ret
    .size   peak_avx2_fma, .-peak_avx2_fma

    .section .note.GNU-stack,"",@progbits
