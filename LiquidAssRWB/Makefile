include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LiquidAssRWB

LiquidAssRWB_FILES = Tweak.x ../Shared/LGSharedSupport.m
LiquidAssRWB_CFLAGS = -fobjc-arc -DLIQUIDASS_DEBUG=$(LIQUIDASS_DEBUG)
LiquidAssRWB_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
