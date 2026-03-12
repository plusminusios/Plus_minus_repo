ARCHS           := arm64 arm64e
TARGET          := iphone:clang:16.5:14.0
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

# ── Твик ──────────────────────────────────────────────
TWEAK_NAME := FaceIDFor6s

FaceIDFor6s_FILES      := Tweak.x
FaceIDFor6s_CFLAGS     := -fobjc-arc -Wno-deprecated-declarations
FaceIDFor6s_FRAMEWORKS := UIKit AVFoundation Vision LocalAuthentication
FaceIDFor6s_PRIVATE_FRAMEWORKS := BiometricKit SpringBoardFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

# ── Панель настроек ────────────────────────────────────
BUNDLE_NAME := FaceIDFor6sPrefs

FaceIDFor6sPrefs_FILES := RootListController.m
FaceIDFor6sPrefs_CFLAGS          := -fobjc-arc
FaceIDFor6sPrefs_FRAMEWORKS      := UIKit
FaceIDFor6sPrefs_PRIVATE_FRAMEWORKS := Preferences
FaceIDFor6sPrefs_INSTALL_PATH    := /Library/PreferenceBundles
FaceIDFor6sPrefs_RESOURCE_DIRS   := Prefs/Resources

include $(THEOS_MAKE_PATH)/bundle.mk
