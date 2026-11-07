TARGET := iphone:clang:latest:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = ConnectBridgePrefs

ConnectBridgePrefs_FILES = CBRootListController.m
ConnectBridgePrefs_FRAMEWORKS = UIKit
# The Xcode SDK ships no private frameworks; Preferences is already loaded in Settings.
ConnectBridgePrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup
ConnectBridgePrefs_INSTALL_PATH = /Library/PreferenceBundles
ConnectBridgePrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
