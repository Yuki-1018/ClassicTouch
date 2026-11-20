#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

PORTABLE_DIR="$ROOT/refs/LightTouch/Portable"
QEMU_DIR="$ROOT/refs/qemu-ios-blake"
OUT_LIB="$PREFIX/lib/liblighttouch.a"
OBJ_DIR="$BUILD/obj/portable"
mkdir -p "$OBJ_DIR"

echo "=== Building LightTouch Portable static library for arm64 iOS ==="

CXX_CMD="$ROOT/build/wrappers/clangxx-ios"
AR_CMD="$ROOT/build/wrappers/ar-ios"
RANLIB_CMD="$ROOT/build/wrappers/xcrun ranlib"

CXXFLAGS_ALL="-std=c++17 $OPT_CFLAGS -fPIC \
  -I $PORTABLE_DIR/include \
  -I $PORTABLE_DIR/src \
  -I $PORTABLE_DIR/network \
  -I $QEMU_DIR/contrib/ios-app \
  -I $QEMU_DIR/contrib/macos-app \
  -I $PREFIX/include"

SOURCES=(
  "$PORTABLE_DIR/src/Storage.cpp"
  "$PORTABLE_DIR/src/Runtime.cpp"
  "$PORTABLE_DIR/src/GuestPackage.cpp"
  "$PORTABLE_DIR/src/Library.cpp"
  "$PORTABLE_DIR/src/Screenshot.cpp"
  "$PORTABLE_DIR/network/Network.cpp"
)

OBJS=()
for src in "${SOURCES[@]}"; do
  base=$(basename "$src" .cpp)
  obj="$OBJ_DIR/$base.o"
  echo "Compiling $base.cpp..."
  $CXX_CMD $CXXFLAGS_ALL -c "$src" -o "$obj"
  OBJS+=("$obj")
done

echo "Creating $OUT_LIB..."
rm -f "$OUT_LIB"
$AR_CMD rcs "$OUT_LIB" "${OBJS[@]}"
$RANLIB_CMD "$OUT_LIB"

cp -f "$PORTABLE_DIR/include/lighttouch.h" "$PREFIX/include/lighttouch.h"
echo "=== LightTouch Portable build complete: $OUT_LIB ==="
ls -lh "$OUT_LIB"
