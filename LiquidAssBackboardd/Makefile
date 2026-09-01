include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LiquidAssBackboardd

LiquidAssBackboardd_FILES     = Tweak.mm LGSymbolResolver.mm
LiquidAssBackboardd_CFLAGS    = -fobjc-arc -std=c++17 -fno-objc-arc-exceptions -DLIQUIDASS_DEBUG=$(LIQUIDASS_DEBUG)
# Non-Darwin build host only: vanilla clang cannot build this SDK's
# Objective-C++ headers as Clang modules (an `using_if_exists` attribute
# incompatibility, unrelated to this project's own source). Disabling
# modules and stubbing the one resulting missing header
# (compat_include/ptrauth.h -- see that file for why it's safe to stub)
# is a build-host toolchain workaround, not a source change, so it is
# gated to only apply off a real Darwin/Xcode toolchain.
ifneq ($(shell uname -s),Darwin)
LiquidAssBackboardd_CFLAGS += -fno-modules -Icompat_include
endif
LiquidAssBackboardd_FRAMEWORKS = Metal QuartzCore CoreFoundation
LiquidAssBackboardd_LDFLAGS   = -lc++

include $(THEOS_MAKE_PATH)/tweak.mk

ifneq ($(shell uname -s),Darwin)
# See the CFLAGS comment above -- Theos also injects a separate
# MODULESFLAGS for iphone targets regardless of -fno-modules in CFLAGS;
# clearing it is required for -fno-modules to actually take effect.
MODULESFLAGS :=
endif
