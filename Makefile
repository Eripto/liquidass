export TARGET ?= iphone:clang:16.5:12.0
# iOS 12.5.x hardware is arm64.  Current Clang uses the new arm64e ABI and
# cannot emit an arm64e slice with a pre-iOS-14 minimum; the CI workflow keeps
# a separate arm64+arm64e/iOS 14 build to protect the existing modern package.
export ARCHS ?= arm64
# Theos leaves TARGET_CODESIGN empty on non-Darwin build hosts.  An unsigned
# preference-bundle executable is rejected by iOS 12, so make ldid part of the
# project contract instead of silently producing an uninstallable package.
ifeq ($(strip $(TARGET_CODESIGN)),)
TARGET_CODESIGN := ldid
endif
ifeq ($(strip $(TARGET_CODESIGN_FLAGS)),)
TARGET_CODESIGN_FLAGS := -S
endif
export TARGET_CODESIGN TARGET_CODESIGN_FLAGS
# Same non-Darwin-host reasoning as TARGET_CODESIGN above: a Linux build
# host's default `ld` is GNU ld, which cannot link the Mach-O output Theos
# produces here ("unrecognised emulation mode: llvm"). Only force the LLVM
# Mach-O linker when we are not already on a Darwin host, so this has no
# effect on an actual macOS/Xcode toolchain build.
ifneq ($(shell uname -s),Darwin)
export ADDITIONAL_LDFLAGS += -fuse-ld=lld
endif
# Several post-iOS-12 declarations are intentionally invoked through guarded
# paths or supplied by LGCompatibility's add-if-missing runtime shims.
export ADDITIONAL_CFLAGS += -Wno-unguarded-availability-new
LIQUIDASS_DEBUG ?= 0
export LIQUIDASS_DEBUG

INSTALL_TARGET_PROCESSES = backboardd SpringBoard
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = liquidass

liquidass_FILES     = Tweak.x Hooks/Dock.x Hooks/Folder.x Hooks/AppIcons.x Hooks/Banner.x Hooks/ControlCenter.x \
                      Hooks/AppLibrary.x Hooks/SearchPill.x Hooks/Spotlight.x Hooks/Widgets.x Hooks/ContextMenu.x \
                      Hooks/QuickActions.x Hooks/Passcode.x Hooks/Clock.x Hooks/Alerts.x \
                      Hooks/PreferencesControls.x Hooks/CoverSheet.x Hooks/TabBar.x \
                      Hooks/Keyboard.x \
                      LiquidAssPrefs/LGPrefsLiquidSlider.m \
                      LiquidAssPrefs/LGPrefsLiquidSwitch.m \
                      Shared/LGGlassKit.x Shared/LGLiveBackdropView.m \
                      Shared/LGIOS12LiveBackdropProvider.m \
                      Shared/LGIOS12StandaloneTestView.m \
                      Shared/LGSharedSupport.m Shared/LGCompatibility.m
liquidass_CFLAGS    = -fobjc-arc -DLIQUIDASS_DEBUG=$(LIQUIDASS_DEBUG)
liquidass_FRAMEWORKS = UIKit QuartzCore CoreText CoreGraphics CoreMotion Metal MetalKit

include $(THEOS)/makefiles/tweak.mk
SUBPROJECTS += LiquidAssBackboardd
SUBPROJECTS += LiquidAssRWB
SUBPROJECTS += LiquidAssPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk

# Subprojects are staged during internal-stage.  Sign the final staged copies
# from the top-level after-stage hook so no later bundle-copy step can replace
# either signature before Theos creates the data archive.
LIQUIDASS_STAGED_TWEAK := $(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/MobileSubstrate/DynamicLibraries/liquidass.dylib
LIQUIDASS_STAGED_PREFS := $(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/PreferenceBundles/LiquidAssPrefs.bundle/LiquidAssPrefs

after-stage:: internal-stage
	@test -f "$(LIQUIDASS_STAGED_TWEAK)" || { echo "error: staged tweak is missing: $(LIQUIDASS_STAGED_TWEAK)" >&2; exit 1; }
	@test -f "$(LIQUIDASS_STAGED_PREFS)" || { echo "error: staged preferences executable is missing: $(LIQUIDASS_STAGED_PREFS)" >&2; exit 1; }
	$(TARGET_CODESIGN) $(TARGET_CODESIGN_FLAGS) "$(LIQUIDASS_STAGED_TWEAK)"
	$(TARGET_CODESIGN) $(TARGET_CODESIGN_FLAGS) "$(LIQUIDASS_STAGED_PREFS)"

# originally i tried to add `release::` here but apparently that keeps breaking for whatever fucking reason so i decided to create `release.sh`
