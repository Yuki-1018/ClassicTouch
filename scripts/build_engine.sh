#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

QEMU_SRC="$ROOT/refs/qemu-ios-blake"
QEMU_BUILD="$BUILD/qemu-ios"
OUT_FRAMEWORKS="$BUILD/Frameworks"
mkdir -p "$QEMU_BUILD" "$OUT_FRAMEWORKS"

# Static pkg-config wrapper so meson/qemu links our static sysroot libs
PC_WRAPPER="$QEMU_BUILD/target-pkg-config"
cat > "$PC_WRAPPER" <<'EOF'
#!/bin/sh
exec pkg-config --static "$@"
EOF
chmod +x "$PC_WRAPPER"
export PKG_CONFIG="$PC_WRAPPER"

cd "$QEMU_BUILD"

unset CC CXX CFLAGS CXXFLAGS LDFLAGS
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export CC_FOR_BUILD=/usr/bin/cc
export CXX_FOR_BUILD=/usr/bin/c++

if [ -f "$QEMU_BUILD/build.ninja" ] && [ -f "$PREFIX/lib/pkgconfig/libavcodec.pc" ]; then
    if ! grep -q "IT_HAVE_AVCODEC" "$QEMU_BUILD/build.ninja"; then
        echo "=== Reconfiguring qemu-ios to enable IT_HAVE_AVCODEC ==="
        rm -f "$QEMU_BUILD/build.ninja"
    fi
fi

if [ ! -f "$QEMU_BUILD/build.ninja" ]; then
    echo "=== Configuring qemu-ios for $TRIPLE ==="
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
        --with-devices-arm=portable \
        --enable-tcg \
        --enable-pixman \
        --enable-slirp \
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

echo "=== Building qemu-system-arm-unsigned ==="
ninja -j"$JOBS" -d keeprsp qemu-system-arm-unsigned

echo "=== Compiling iOS dylib entrypoints ==="
ENTRY_CFLAGS="-std=gnu11 -O3 -mcpu=apple-a9 -fPIC -D_GNU_SOURCE -DCOMPILING_SYSTEM_VS_USER -DCONFIG_SOFTMMU \
    -I$QEMU_BUILD -I$QEMU_BUILD/qapi -I$QEMU_BUILD/trace -I$QEMU_BUILD/ui \
    -I$QEMU_SRC -I$QEMU_SRC/include -I$QEMU_SRC/contrib/ios-app -I$QEMU_SRC/contrib/macos-app \
    -I$QEMU_SRC/host/include/aarch64 -I$QEMU_SRC/host/include/generic -I$QEMU_SRC/tcg/aarch64 \
    -I$PREFIX/include -I$PREFIX/include/glib-2.0 -I$PREFIX/lib/glib-2.0/include -I$PREFIX/include/pixman-1"

"$ROOT/build/wrappers/clang-ios" $ENTRY_CFLAGS -c "$QEMU_SRC/contrib/ios-app/qemu-ios-entry.c" -o "$QEMU_BUILD/qemu-ios-entry.o"
"$ROOT/build/wrappers/clang-ios" $ENTRY_CFLAGS -c "$QEMU_SRC/contrib/ios-app/qemu-ios-ui.c" -o "$QEMU_BUILD/qemu-ios-ui.o"
"$ROOT/build/wrappers/clang-ios" $ENTRY_CFLAGS -c "$QEMU_SRC/contrib/macos-app/qemu-macos-extras.c" -o "$QEMU_BUILD/qemu-macos-extras.o"

"$TC/nm" -g "$QEMU_BUILD/qemu-ios-entry.o" "$QEMU_BUILD/qemu-ios-ui.o" "$QEMU_BUILD/qemu-macos-extras.o" "$QEMU_BUILD/libsystem.a.p/system_runstate.c.o" "$QEMU_BUILD/libqemu-arm-softmmu.a.p/hw_arm_gles-host-eagl.c.o" \
    | awk '$2 == "T" && $3 ~ /^_qemu_ios_/ { print $3 }' | sort -u > "$QEMU_BUILD/libqemu-arm.exports"

echo "=== Linking native iOS libqemu-arm.dylib ==="
# Clean out any old macOS dylibs / fake OpenGL.framework (preserve libqemu-android.dylib and libqemu-winrt.dylib)
find "$OUT_FRAMEWORKS" -maxdepth 1 ! -path "$OUT_FRAMEWORKS" ! -name "libqemu-android.dylib" ! -name "libqemu-winrt.dylib" -exec rm -rf {} +

LINK_CMD=$(ninja -C "$QEMU_BUILD" -t commands qemu-system-arm-unsigned | tail -n 1)
python3 - "$LINK_CMD" "$QEMU_BUILD" "$OUT_FRAMEWORKS/libqemu-arm.dylib" "$PREFIX/lib" <<'PY'
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
            "-install_name", "@rpath/libqemu-arm.dylib",
            "-o", out_dylib,
            f"-Wl,-exported_symbols_list,{qemu_build}/libqemu-arm.exports",
        ])
        i += 2
        continue
    if a.endswith("system_main.c.o"):
        new_args.extend([
            f"{qemu_build}/qemu-ios-entry.o",
            f"{qemu_build}/qemu-ios-ui.o",
            f"{qemu_build}/qemu-macos-extras.o",
        ])
        i += 1
        continue
    new_args.append(a)
    i += 1

new_args.extend([f"-L{prefix_lib}", "-lcrypto", "-framework", "OpenGLES", "-framework", "IOSurface", "-framework", "Foundation"])
print("Linking:", out_dylib)
subprocess.check_call(new_args, cwd=qemu_build)
PY

"$TC/ldid" -S "$OUT_FRAMEWORKS/libqemu-arm.dylib"
echo "=== Built $OUT_FRAMEWORKS/libqemu-arm.dylib ==="
