# ──────────────────────────────────────────────────────
#  FaceIDFor6s — Makefile
#  Требует: Theos (https://theos.dev)
#  Сборка: make package FINALPACKAGE=1
# ──────────────────────────────────────────────────────

ARCHS           := arm64 arm64e
TARGET          := iphone:clang:15.0:14.0
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := FaceIDFor6s

FaceIDFor6s_FILES       := Tweak.x
FaceIDFor6s_CFLAGS      := -fobjc-arc -Wno-deprecated-declarations
FaceIDFor6s_FRAMEWORKS  := UIKit AVFoundation Vision LocalAuthentication
FaceIDFor6s_PRIVATE_FRAMEWORKS := BiometricKit SpringBoardFoundation

# Куда внедрять (SpringBoard + все приложения через BKDevicePolicyManager)
FaceIDFor6s_LIBRARIES   :=
FaceIDFor6s_BUNDLE_ID   := com.yourname.faceidfor6s

include $(THEOS_MAKE_PATH)/tweak.mk
