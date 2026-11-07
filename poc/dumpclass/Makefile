ARCHS = arm64
TARGET := iphone:clang:latest:15.0
include $(THEOS)/makefiles/common.mk
TOOL_NAME = dumpclass
dumpclass_FILES = main.m
dumpclass_CFLAGS = -fobjc-arc
include $(THEOS_MAKE_PATH)/tool.mk
