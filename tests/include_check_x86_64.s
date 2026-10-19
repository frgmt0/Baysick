# tests/include_check_x86_64.s -- assembled on Linux by
# `make -f Makefile.linux check-includes` (GNU as, x86_64 ELF).
# Proves the contract include files parse with GNU as, are safe to
# include twice, and that the documented record layouts are consistent.
# The Apple as / arm64 twin is tests/include_check.s.
.include "baysick.inc"
.include "baysick.inc"          # guards: second include must be a no-op
.include "include_asserts.inc"

    .section .data.rel.ro,"aw",@progbits
    BSK_EMIT_ERRMSG_TABLE .Lerrtab
ASSERT ((.Lerrtab_m1 - .Lerrtab) == ERR_TABLE_SIZE*8),     "error message table size"

    .section .rodata
    BSK_EMIT_INPUT_MSGS .Linmsg
ASSERT ((.Linmsg_retype_end - .Linmsg_retype) == 46),      "INPUT retype message (with LF)"
ASSERT ((.Linmsg_more_end - .Linmsg_more) == 29),          "INPUT add-more message (with LF)"
ASSERT ((.Linmsg_excess_end - .Linmsg_excess) == 33),      "INPUT excess message (with LF)"

    .text
    ret

    .section .note.GNU-stack,"",@progbits
