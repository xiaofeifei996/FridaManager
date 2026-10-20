TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = Preferences
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

SUBPROJECTS = fridamgr fridamgrprefs

include $(THEOS_MAKE_PATH)/aggregate.mk

after-stage::
	@python3 scripts/stage.py "$(THEOS_STAGING_DIR)" "$(THEOS_PACKAGE_SCHEME)"
