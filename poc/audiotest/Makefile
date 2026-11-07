ARCHS = arm64
TARGET := iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk
TOOL_NAME = audiotest
audiotest_FILES = main.m
audiotest_FRAMEWORKS = AVFoundation
audiotest_CFLAGS = -fobjc-arc
include $(THEOS_MAKE_PATH)/tool.mk
