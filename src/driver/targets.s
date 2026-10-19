// =====================================================================
// src/driver/targets.s -- the table of available backends.
//
//   _drv_targets: NULL-terminated array of pointers to backend
//   descriptors (backend.inc BKD_*). --target <name> selects the entry
//   whose BKD_NAME equals <name>; the default is "arm64-macos".
// =====================================================================
.include "baysick.inc"

    .section __DATA,__const
    .globl _drv_targets
    .p2align 3
_drv_targets:
    .quad _bk_arm64_macos_desc          // src/backend/arm64_macos/a64_desc.s
    .quad _bk_x86_64_linux_desc         // src/backend/x86_64_linux/x64_desc.s
    .quad 0                             // end of table
