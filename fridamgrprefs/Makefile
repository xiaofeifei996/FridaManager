include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = FridaManagerPrefs

FridaManagerPrefs_FILES = FMRootListController.m FMSocketClient.m
FridaManagerPrefs_CFLAGS = -fobjc-arc -I../fridamgr -fno-ptrauth-objc-class-ro -fno-ptrauth-objc-interface-sel
FridaManagerPrefs_FRAMEWORKS = UIKit
FridaManagerPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
FridaManagerPrefs_LDFLAGS += -lroothide
else
FridaManagerPrefs_LDFLAGS += -lroot
endif
FridaManagerPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
