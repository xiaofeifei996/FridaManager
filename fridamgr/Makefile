include $(THEOS)/makefiles/common.mk

TOOL_NAME = fridamgr

fridamgr_FILES = main.m FMDaemon.m FMFridaServer.m FMSocketServer.m FMConfig.m FMDownloadManager.m
fridamgr_CFLAGS = -fobjc-arc
fridamgr_FRAMEWORKS = Foundation
fridamgr_LDFLAGS = -lcompression
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
fridamgr_LDFLAGS += -lroothide
else
fridamgr_LDFLAGS += -lroot
endif

fridamgr_CODESIGN_FLAGS = -Sentitlements.plist
fridamgr_INSTALL_PATH = /usr/local/bin

include $(THEOS_MAKE_PATH)/tool.mk
