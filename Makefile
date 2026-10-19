# Baysick -- build file.
#
# Tools used: as, ld, ar, xcrun (Xcode command line tools). Nothing else.
#
#   make                  build build/baysick and build/libbaysickrt.a
#   make test             build, then run tests/run.sh
#   make check-includes   assemble the contract include files (layout assertions)
#   make cross-pack       pack the x86_64-linux test bundle into build/x86_64-linux-bundle
#   make cross            pack and run the bundle on a Linux host (tests/cross.sh)
#   make clean            remove build/
#
# The compiler finds its runtime at run time as <dir of baysick>/libbaysickrt.a,
# or at $BAYSICK_RUNTIME if that is set (see docs/DESIGN.md section 4.4).

AS      := as
LD      := ld
AR      := ar
BUILD   := build

ASFLAGS := -arch arm64 -mmacosx-version-min=11.0 -I include
# Evaluated only when a link actually happens (recursive variable).
SDK      = $(if $(SDKROOT),$(SDKROOT),$(shell xcrun --show-sdk-path))
LDFLAGS  = -lSystem -syslibroot $(SDK) -e _main -arch arm64 -platform_version macos 11.0 11.0

COMPILER_DIRS := src/frontend src/ir src/driver src/backend/arm64_macos src/backend/x86_64_linux
COMPILER_SRCS := $(wildcard src/frontend/*.s src/ir/*.s src/driver/*.s src/backend/*/*.s)
RUNTIME_SRCS  := $(wildcard src/runtime/*.s)
COMPILER_OBJS := $(patsubst src/%.s,$(BUILD)/obj/%.o,$(COMPILER_SRCS))
RUNTIME_OBJS  := $(patsubst src/%.s,$(BUILD)/obj/%.o,$(RUNTIME_SRCS))
INCLUDES      := $(wildcard include/*.inc)

.PHONY: all test clean check-includes check-sources cross-pack cross
.DEFAULT_GOAL := all

all: $(BUILD)/baysick $(BUILD)/libbaysickrt.a

# Fail with a clear message (instead of a confusing ld/ar error) while a
# module has not been written yet.
check-sources:
	@missing=""; \
	for d in $(COMPILER_DIRS) src/runtime; do \
	  set -- $$d/*.s; \
	  if [ ! -e "$$1" ]; then missing="$$missing $$d"; fi; \
	done; \
	if [ -n "$$missing" ]; then \
	  echo "make: no assembly sources in:$$missing" >&2; \
	  echo "make: the Baysick compiler/runtime is not implemented yet (see docs/DESIGN.md section 2)" >&2; \
	  exit 1; \
	fi

$(BUILD)/baysick: $(COMPILER_OBJS) | check-sources
	$(LD) -o $@ $(COMPILER_OBJS) $(LDFLAGS)

$(BUILD)/libbaysickrt.a: $(RUNTIME_OBJS) | check-sources
	rm -f $@
	$(AR) rcs $@ $(RUNTIME_OBJS)

$(BUILD)/obj/%.o: src/%.s $(INCLUDES)
	@mkdir -p $(dir $@)
	$(AS) $(ASFLAGS) -o $@ $<

# The include files are shared with the x86_64-linux runtime (GNU as), where
# `//` only starts a comment at the beginning of a line: a trailing comment
# must be written /* ... */ (docs/DESIGN.md section 3.4). The grep enforces it.
check-includes: $(INCLUDES) tests/include_check.s tests/include_asserts.inc
	@mkdir -p $(BUILD)
	@if grep -nE '^[[:space:]]*[^[:space:]/].*//' $(INCLUDES) tests/include_asserts.inc; then \
	  echo "make: trailing // comment in a shared include file (use /* ... */)" >&2; exit 1; \
	fi
	$(AS) $(ASFLAGS) -I tests -o $(BUILD)/include_check.o tests/include_check.s
	@echo "include files assemble and layout assertions hold"

test: check-includes all
	sh tests/run.sh

# x86_64-linux cross testing (docs/DESIGN.md section 8.3): pack the compiled
# test cases into a bundle, or pack + run them on a Linux host over ssh.
cross-pack: all
	rm -rf $(BUILD)/x86_64-linux-bundle
	sh tests/cross_pack.sh -o $(BUILD)/x86_64-linux-bundle

cross: all
	sh tests/cross.sh

clean:
	rm -rf $(BUILD)
