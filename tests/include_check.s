// tests/include_check.s -- assembled by `make check-includes` (macOS).
// Proves the contract include files parse with Apple `as`, are safe to
// include twice, and that the documented record layouts are consistent.
// The GNU as / x86_64 ELF twin is tests/include_check_x86_64.s.
.include "baysick.inc"
.include "baysick.inc"          // guards: second include must be a no-op
.include "include_asserts.inc"

    .section __DATA,__const
    BSK_EMIT_ERRMSG_TABLE errtab
ASSERT ((errtab_m1 - errtab) == ERR_TABLE_SIZE*8),         "error message table size"

    .section __TEXT,__const
    BSK_EMIT_INPUT_MSGS inmsg
ASSERT ((inmsg_retype_end - inmsg_retype) == 46),          "INPUT retype message (with LF)"
ASSERT ((inmsg_more_end - inmsg_more) == 29),              "INPUT add-more message (with LF)"
ASSERT ((inmsg_excess_end - inmsg_excess) == 33),          "INPUT excess message (with LF)"

    .section __TEXT,__text
    .p2align 2
    ret
