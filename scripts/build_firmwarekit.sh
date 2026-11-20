#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
source "$ROOT/build/rust-env.sh"

export PATH="$ROOT/build/wrappers:$PATH"
export SDKROOT="$SDK"
export IPHONEOS_DEPLOYMENT_TARGET="15.0"
export CC_aarch64_apple_ios="$ROOT/build/wrappers/clang-ios"
export CXX_aarch64_apple_ios="$ROOT/build/wrappers/clangxx-ios"
export AR_aarch64_apple_ios="$ROOT/build/wrappers/ar-ios"
export CARGO_TARGET_AARCH64_APPLE_IOS_LINKER="$ROOT/build/wrappers/clang-ios"
export CARGO_TARGET_AARCH64_APPLE_IOS_RUSTFLAGS="-C target-cpu=apple-a7"

echo "=== Building lighttouch-firmware (libfirmwarekit.a) for arm64 iOS ==="
cd "$ROOT/refs/LightTouch"

cargo build --release -p lighttouch-firmware --lib --target aarch64-apple-ios

TARGET_LIB="$ROOT/refs/LightTouch/target/aarch64-apple-ios/release/libfirmwarekit.a"
if [ -f "$TARGET_LIB" ]; then
    cp -f "$TARGET_LIB" "$PREFIX/lib/libfirmwarekit.a"
    echo "=== Installed $PREFIX/lib/libfirmwarekit.a ==="
    ls -lh "$PREFIX/lib/libfirmwarekit.a"
else
    echo "Error: $TARGET_LIB not found!"
    exit 1
fi
