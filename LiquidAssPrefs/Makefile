include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = LiquidAssPrefs

LG_PACKAGE_VERSION := $(shell sed -n 's/^Version: //p' ../control | head -n 1)

PREF_LOCAL_FILES := LGPRootListController.m LGPSurfaceController.m LGPrefsSurfaceCatalog.m LGPrefsDataSupport.m \
                    LGPrefsUIHelpers.m LGPrefsLiquidSlider.m LGPrefsLiquidSwitch.m
PREF_SHARED_FILES := ../Shared/LGSharedSupport.m ../Shared/LGLiveBackdropView.m
LiquidAssPrefs_FILES = $(PREF_LOCAL_FILES) $(PREF_SHARED_FILES)
LiquidAssPrefs_FRAMEWORKS = UIKit QuartzCore CoreText CoreGraphics CoreMotion
LiquidAssPrefs_INSTALL_PATH = /Library/PreferenceBundles
LiquidAssPrefs_CFLAGS = -fobjc-arc -I../Shared -DLG_PACKAGE_VERSION=@\"$(LG_PACKAGE_VERSION)\" -DLIQUIDASS_DEBUG=$(LIQUIDASS_DEBUG)
LiquidAssPrefs_LDFLAGS += -Wl,-undefined,dynamic_lookup

LiquidAssPrefs_RESOURCE_FILES = ../changelogs

include $(THEOS_MAKE_PATH)/bundle.mk

after-stage::
	mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences
	cp Resources/entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/LiquidAssPrefs.plist
	ldid -S $(THEOS_STAGING_DIR)/Library/PreferenceBundles/LiquidAssPrefs.bundle/LiquidAssPrefs
