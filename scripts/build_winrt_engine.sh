#!/usr/bin/env bash
# Builds the separate Windows RT ARMv7 QEMU engine for arm64 iOS ->
# build/Frameworks/libqemu-winrt.dylib.
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/env.sh"

QEMU_SRC="$ROOT/refs/qemu-android"
QEMU_BUILD="$BUILD/qemu-winrt"
OUT_FRAMEWORKS="$BUILD/Frameworks"
mkdir -p "$QEMU_BUILD" "$OUT_FRAMEWORKS"

cd "$QEMU_BUILD"
unset CC CXX CFLAGS CXXFLAGS LDFLAGS
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export CC_FOR_BUILD=/usr/bin/cc
export CXX_FOR_BUILD=/usr/bin/c++

if [ ! -f "$QEMU_BUILD/build.ninja" ] || [ "$QEMU_SRC/configs/devices/arm-softmmu/winrt.mak" -nt "$QEMU_BUILD/build.ninja" ]; then
    echo "=== Configuring qemu-winrt for $TRIPLE ==="
    rm -rf "$QEMU_BUILD/meson-private" "$QEMU_BUILD/meson-info" "$QEMU_BUILD/meson-logs"
    AR="$TC/ar" RANLIB="$TC/ranlib" NM="$TC/nm" STRIP="$TC/strip" \
    "$QEMU_SRC/configure" \
        --cross-prefix= \
        --cpu=aarch64 \
        --cc="$ROOT/build/wrappers/clang-ios" \
        --cxx="$ROOT/build/wrappers/clangxx-ios" \
        --objcc="$ROOT/build/wrappers/clang-ios" \
        --host-cc=/usr/bin/cc \
        --target-list=arm-softmmu \
        --without-default-features \
        --without-default-devices \
        --with-devices-arm=winrt \
        --enable-tcg \
        --enable-pixman \
        --enable-slirp \
        --enable-vpc \
        --enable-vhdx \
        --python=/usr/bin/python3 \
        --disable-docs \
        --disable-tools \
        --disable-werror \
        --disable-pie \
        --disable-qom-cast-debug \
        --audio-drv-list= \
        --extra-cflags="-O3 -mcpu=apple-a9 -fPIC -I$PREFIX/include" \
        --extra-cxxflags="-O3 -mcpu=apple-a9 -fPIC -I$PREFIX/include" \
        --extra-ldflags="-L$PREFIX/lib -lcrypto"
fi

echo "=== Building qemu-winrt objects and static archives ==="
LINK_CMD=$(ninja -C "$QEMU_BUILD" -t commands qemu-system-arm-unsigned | tail -n 1)
python3 - "$LINK_CMD" "$QEMU_BUILD" "$JOBS" <<'PY'
import shlex, subprocess, sys

link_cmd, qemu_build, jobs = sys.argv[1:4]
targets = [
    tok for tok in shlex.split(link_cmd)
    if (tok.endswith(".o") or tok.endswith(".a")) and not tok.startswith("/")
]
subprocess.check_call(["ninja", f"-j{jobs}"] + targets, cwd=qemu_build)
PY

echo "=== Compiling Windows RT iOS dylib entrypoints ==="
ENTRY_CFLAGS="-std=gnu11 -O3 -mcpu=apple-a9 -fPIC -D_GNU_SOURCE -DCOMPILING_SYSTEM_VS_USER -DCONFIG_SOFTMMU \
    -I$QEMU_BUILD -I$QEMU_BUILD/qapi -I$QEMU_BUILD/trace -I$QEMU_BUILD/ui \
    -I$QEMU_SRC -I$QEMU_SRC/include -I$QEMU_SRC/contrib/ios-winrt \
    -I$QEMU_SRC/host/include/aarch64 -I$QEMU_SRC/host/include/generic -I$QEMU_SRC/tcg/aarch64 \
    -I$PREFIX/include -I$PREFIX/include/glib-2.0 -I$PREFIX/lib/glib-2.0/include -I$PREFIX/include/pixman-1"

"$ROOT/build/wrappers/clang-ios" $ENTRY_CFLAGS -c "$QEMU_SRC/contrib/ios-winrt/qemu-winrt-entry.c" -o "$QEMU_BUILD/qemu-winrt-entry.o"
"$ROOT/build/wrappers/clang-ios" $ENTRY_CFLAGS -c "$QEMU_SRC/contrib/ios-winrt/qemu-winrt-ui.c" -o "$QEMU_BUILD/qemu-winrt-ui.o"

"$TC/nm" -g "$QEMU_BUILD/qemu-winrt-entry.o" "$QEMU_BUILD/qemu-winrt-ui.o" \
    | awk '$2 == "T" && $3 ~ /^_qemu_winrt_/ { print $3 }' | sort -u > "$QEMU_BUILD/libqemu-winrt.exports"

echo "=== Linking native iOS libqemu-winrt.dylib ==="
rm -f "$OUT_FRAMEWORKS/libqemu-winrt.dylib"

LINK_CMD=$(ninja -C "$QEMU_BUILD" -t commands qemu-system-arm-unsigned | tail -n 1)
python3 - "$LINK_CMD" "$QEMU_BUILD" "$OUT_FRAMEWORKS/libqemu-winrt.dylib" "$PREFIX/lib" <<'PY'
import shlex, subprocess, sys

link_cmd, qemu_build, out_dylib, prefix_lib = sys.argv[1:5]
args = shlex.split(link_cmd)
new_args = []
i = 0
while i < len(args):
    a = args[i]
    if a == "-o" and i + 1 < len(args) and args[i + 1] == "qemu-system-arm-unsigned":
        new_args.extend([
            "-dynamiclib",
            "-install_name", "@rpath/libqemu-winrt.dylib",
            "-o", out_dylib,
            f"-Wl,-exported_symbols_list,{qemu_build}/libqemu-winrt.exports",
        ])
        i += 2
        continue
    if a.endswith("system_main.c.o"):
        new_args.extend([
            f"{qemu_build}/qemu-winrt-entry.o",
            f"{qemu_build}/qemu-winrt-ui.o",
        ])
        i += 1
        continue
    new_args.append(a)
    i += 1

new_args.extend([f"-L{prefix_lib}", "-lcrypto", "-framework", "Foundation"])
print("Linking:", out_dylib)
subprocess.check_call(new_args, cwd=qemu_build)
PY

"$TC/ldid" -S "$OUT_FRAMEWORKS/libqemu-winrt.dylib"
echo "=== Built $OUT_FRAMEWORKS/libqemu-winrt.dylib ==="
