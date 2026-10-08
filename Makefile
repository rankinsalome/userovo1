ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = smoba

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = gamehack
gamehack_FILES = Tweak.xm ESP.mm
gamehack_CFLAGS = -fobjc-arc -std=c++17 -Wno-error -Wno-unused-function
gamehack_LOGOS_DEFAULT_GENERATOR = internal

include $(THEOS)/makefiles/tweak.mk

#12
