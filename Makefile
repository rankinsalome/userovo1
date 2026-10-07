ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = smoba

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = gamehack
gamehack_FILES = Tweak.xm
gamehack_CFLAGS = -fobjc-arc

include $(THEOS)/makefiles/tweak.mk