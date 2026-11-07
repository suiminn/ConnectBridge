ARCHS = arm64
TARGET := iphone:clang:latest:15.0
include $(THEOS)/makefiles/common.mk
TOOL_NAME = nptest
nptest_FILES = main.m
nptest_FRAMEWORKS = AVFoundation MediaPlayer
nptest_CFLAGS = -fobjc-arc
include $(THEOS_MAKE_PATH)/tool.mk
