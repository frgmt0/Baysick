// =====================================================================
// include/baysick.inc -- convenience umbrella: includes every contract
// file. Source files may include this or the individual files.
// Assemble with:  as -arch arm64 -I include ...
// =====================================================================
.include "limits.inc"
.include "errors.inc"
.include "tokens.inc"
.include "ir.inc"
.include "backend.inc"
.include "driver.inc"
.include "runtime.inc"
