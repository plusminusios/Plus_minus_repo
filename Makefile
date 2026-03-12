ARCHS  := arm64 arm64e
TARGET := iphone:clang:16.5:14.0
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := FaceIDFor6s
FaceIDFor6s_FILES      := Tweak.x
FaceIDFor6s_CFLAGS     := -fobjc-arc -Wno-deprecated-declarations
FaceIDFor6s_FRAMEWORKS := UIKit AVFoundation Vision LocalAuthentication
FaceIDFor6s_PRIVATE_FRAMEWORKS := SpringBoardFoundation Preferences

include $(THEOS_MAKE_PATH)/tweak.mk
