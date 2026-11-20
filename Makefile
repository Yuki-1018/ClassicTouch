export ARCHS = arm64
export TARGET = iphone:clang:16.5:15.0

INSTALL_TARGET_PROCESSES = ClassicTouch

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = ClassicTouch

SYSROOT = build/sysroot

ClassicTouch_FILES = \
	src/main.m \
	src/AppDelegate.m \
	src/MainViewController.m \
	src/EmulatorViewController.m \
	src/IPSWDownloader.m \
	src/ios_audio_bridge.m \
	src/ios_metal_view.m \
	src/ios_motion_manager.m \
	src/ios_jit_helper.c \
	src/henge-brk.S

ClassicTouch_CFLAGS = \
	-O3 -mcpu=apple-a9 \
	-fobjc-arc \
	-Wno-deprecated-declarations \
	-Isrc \
	-I$(SYSROOT)/include \
	-Irefs/LightTouch/Portable/include

ClassicTouch_LDFLAGS = \
	-L$(SYSROOT)/lib \
	-lfirmwarekit \
	-llighttouch \
	-lslirp \
	-lglib-2.0 \
	-lintl \
	-lpcre2-8 \
	-lffi \
	-lssl \
	-lcrypto \
	-lpixman-1 \
	-lz \
	-lresolv \
	-liconv \
	-lc++

ClassicTouch_FRAMEWORKS = \
	UIKit \
	CoreGraphics \
	Foundation \
	CoreFoundation \
	Metal \
	MetalKit \
	QuartzCore \
	AudioToolbox \
	CoreAudio \
	AVFoundation \
	CoreMotion \
	UniformTypeIdentifiers \
	Security \
	SystemConfiguration \
	UserNotifications

ClassicTouch_CODESIGN_FLAGS = -Sentitlements.plist
ClassicTouch_BUNDLE_NAME = ClassicTouch
ClassicTouch_INSTALL_PATH = /Applications
ClassicTouch_BUNDLE_RESOURCES = \
	Info.plist \
	Resources/firmware-catalog.json \
	Resources/guest-tools \
	$(wildcard Resources/AppIcons/*.png)

include $(THEOS_MAKE_PATH)/application.mk

after-all::
	@bash scripts/package_app.sh
