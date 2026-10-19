// =====================================================================
// include/backend.inc -- the pluggable backend interface.
//
// CONTRACT FILE. See docs/DESIGN.md "Backend interface".
//
// A backend is a read-only 64-byte descriptor (BKD_*) exported under a
// global symbol. The driver's target table (src/driver/targets.s) lists
// the descriptors; --target <name> selects one by BKD_NAME.
//
// Currently: _bk_arm64_macos_desc  (src/backend/arm64_macos/a64_desc.s)
// =====================================================================
.ifndef BSK_BACKEND_INC
.equ BSK_BACKEND_INC, 1

// ---- Backend descriptor (BKD_*), 64 bytes, in __DATA,__const ------------
.equ BKD_NAME,          0   // ptr  NUL-terminated target name, e.g. "arm64-macos"
.equ BKD_EMIT,          8   // ptr  emit function (see below)
.equ BKD_AS_ARGV,       16  // ptr  NULL-terminated argv template for the assembler
.equ BKD_LD_ARGV,       24  // ptr  NULL-terminated argv template for the linker
.equ BKD_FLAGS,         32  // u64  BKF_* flags
.equ BKD_ASM_SUFFIX,    40  // ptr  ".s"
.equ BKD_OBJ_SUFFIX,    48  // ptr  ".o"
.equ BKD_RUNTIME_NAME,  56  // ptr  runtime archive file name, e.g. "libbaysickrt.a"
.equ BKD_SIZE,          64

// ---- BKD_FLAGS bits --------------------------------------------------------
.equ BKF_HOST_NATIVE,   1   // driver may run AS/LD argv on this host. If clear,
                            // the driver behaves as if -S were given.

// ---- argv template placeholders ---------------------------------------------
// An argv template is an array of pointers terminated by 0. An entry whose
// numeric value is < PH_LIMIT is not a string but a placeholder that the
// driver substitutes before posix_spawnp:
.equ PH_ASM,            1   // path of the generated assembly file
.equ PH_OBJ,            2   // path of the object file
.equ PH_EXE,            3   // path of the output executable
.equ PH_RUNTIME,        4   // path of the runtime archive (see DESIGN.md)
.equ PH_SDK,            5   // macOS SDK path ($SDKROOT or `xcrun --show-sdk-path`)
.equ PH_LIMIT,          16

// ---- Emit function -----------------------------------------------------------
//   BKD_EMIT(x0 = const Module*, x1 = OutBuf*) -> x0 = 0 on success,
//                                               else ptr to NUL-terminated
//                                               internal-error reason.
//   Appends one complete assembly translation unit to the OutBuf.
//   AAPCS64; may call _ob_* and _drv_alloc. Must not modify the Module.

.endif
