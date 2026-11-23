#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THEOS="/home/Yuki-1018/theos"
CLANG="$THEOS/toolchain/linux/iphone/bin/clang"
SDK="$THEOS/sdks/iPhoneOS16.5.sdk"
MIN_IOS="${MIN_IOS:-15.0}"
TRIPLE="arm64-apple-ios$MIN_IOS"
SYSROOT="$ROOT/build/sysroot"
OBJ_DIR="$ROOT/build/obj/app"

mkdir -p "$OBJ_DIR" "$ROOT/build"

echo "=== Compiling ClassicTouch Sources ==="

# Compile henge-brk.S
echo "  Assembling henge-brk.S..."
$CLANG -target "$TRIPLE" -isysroot "$SDK" -c "$ROOT/src/henge-brk.S" -o "$OBJ_DIR/henge-brk.o"

# Compile C / ObjC sources
for src in \
    "$ROOT/src/main.m" \
    "$ROOT/src/AppDelegate.m" \
    "$ROOT/src/MainViewController.m" \
    "$ROOT/src/SettingsViewController.m" \
    "$ROOT/src/EmulatorViewController.m" \
    "$ROOT/src/IPSWDownloader.m" \
    "$ROOT/src/ios_audio_bridge.m" \
    "$ROOT/src/ios_metal_view.m" \
    "$ROOT/src/FrameMailbox.cpp" \
    "$ROOT/src/AndroidMetalView.mm" \
    "$ROOT/src/adb/Protocol.cpp" \
    "$ROOT/src/adb/RSAPublicKey.cpp" \
    "$ROOT/src/adb/Client.cpp" \
    "$ROOT/src/adb/ADBKey.mm" \
    "$ROOT/src/adb/ADBClient.mm" \
    "$ROOT/src/ios_motion_manager.m" \
    "$ROOT/src/ios_network_proxy.mm" \
    "$ROOT/src/ios_usb_mux.mm" \
    "$ROOT/src/ios_ipa_installer.mm" \
    "$ROOT/src/ios_guest_tools.m" \
    "$ROOT/src/ios_jit_helper.c"
do
    obj="$OBJ_DIR/$(basename "${src%.*}").o"
    echo "  Compiling $(basename "$src")..."
    EXTRA_CPP=""
    if [ "${src##*.}" = "mm" ] || [ "${src##*.}" = "cpp" ]; then
        EXTRA_CPP="-std=c++20"
    fi
    $CLANG -target "$TRIPLE" -isysroot "$SDK" \
        -O3 -mcpu=apple-a9 $EXTRA_CPP -fobjc-arc -Wno-deprecated-declarations \
        -I"$ROOT/src" \
        -I"$ROOT/src/adb" \
        -I"$SYSROOT/include" \
        -I"$ROOT/refs/LightTouch/Portable/include" \
        -I"$ROOT/refs/LightTouch/Portable/network" \
        -c "$src" -o "$obj"
done

echo "=== Linking ClassicTouch Executable ==="
$CLANG -target "$TRIPLE" -isysroot "$SDK" \
    "$OBJ_DIR"/*.o \
    -L"$SYSROOT/lib" \
    -Wl,-rpath,@executable_path/Frameworks \
    -Wl,-rpath,@loader_path/Frameworks \
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
    -framework UIKit \
    -framework CoreGraphics \
    -framework Foundation \
    -framework CoreFoundation \
    -framework Metal \
    -framework MetalKit \
    -framework QuartzCore \
    -framework AudioToolbox \
    -framework CoreAudio \
    -framework AVFoundation \
    -framework CoreMotion \
    -framework UniformTypeIdentifiers \
    -framework Security \
    -framework SystemConfiguration \
    -framework UserNotifications \
    -lc++ \
    -o "$ROOT/build/ClassicTouch"

echo "=== App Executable Built Successfully ==="
ls -lh "$ROOT/build/ClassicTouch"
file "$ROOT/build/ClassicTouch"

echo "=== Packaging IPA & DEB ==="
bash "$ROOT/scripts/package_app.sh"
