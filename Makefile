ARCHS = arm64
TARGET := iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TOOL_NAME = connectbridged
connectbridged_FILES = daemon/connectbridged.m
connectbridged_FRAMEWORKS = SystemConfiguration
connectbridged_CFLAGS = -fobjc-arc -Wall
connectbridged_CODESIGN_FLAGS = -Sdaemon/entitlements.plist
connectbridged_INSTALL_PATH = /usr/libexec/connectbridge

include $(THEOS_MAKE_PATH)/tool.mk

SUBPROJECTS = prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

# The patched librespot is built separately (scripts/build-librespot.sh) and staged here.
LIBRESPOT_BIN = build/librespot

before-stage::
	@test -f $(LIBRESPOT_BIN) || { echo "build/librespot is missing: run scripts/build-librespot.sh first"; exit 1; }

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/usr/libexec/connectbridge$(ECHO_END)
	$(ECHO_NOTHING)cp $(LIBRESPOT_BIN) $(THEOS_STAGING_DIR)/usr/libexec/connectbridge/librespot$(ECHO_END)
	$(ECHO_NOTHING)ldid -Sdaemon/entitlements.plist $(THEOS_STAGING_DIR)/usr/libexec/connectbridge/librespot$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/usr/share/doc/com.sui827.connectbridge$(ECHO_END)
	$(ECHO_NOTHING)cp LICENSE THIRD_PARTY_NOTICES $(THEOS_STAGING_DIR)/usr/share/doc/com.sui827.connectbridge/$(ECHO_END)
