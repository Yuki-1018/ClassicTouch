#!/usr/bin/env bash
# Builds the separate Goldfish Android QEMU engine for arm64 iOS ->
# build/Frameworks/libqemu-android.dylib (with AOSP emugl + EAGL host GLES).
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/env.sh"

QEMU_SRC="$ROOT/refs/qemu-android"
QEMU_BUILD="$BUILD/qemu-android"
EMUGL_SRC="$QEMU_SRC/emugl"
EMUGL_BUILD="$BUILD/emugl"
OUT_FRAMEWORKS="$BUILD/Frameworks"
mkdir -p "$QEMU_BUILD" "$EMUGL_BUILD/objs" "$OUT_FRAMEWORKS"

# 1. Build libemugl_host.a for arm64 iOS using $CXX (C++17)
echo "=== Building libemugl_host.a (AOSP emugl + EAGL) ==="
EMUGL_CXXFLAGS="-std=c++17 -O3 -mcpu=apple-a9 -fPIC -fvisibility=hidden \
    -Wno-deprecated-declarations -Wno-unused-parameter -Wno-sign-compare \
    -DEMUGL_BUILD=1 -DHOST_BUILD=1 -DOPENGL_GLES2 \
    -I$QEMU_SRC/hw/arm/android51 \
    -I$EMUGL_SRC \
    -I$EMUGL_SRC/host/include \
    -I$EMUGL_SRC/host/include/libOpenglRender \
    -I$EMUGL_SRC/host/libs/Translator/include \
    -I$EMUGL_SRC/host/libs/libOpenGLESDispatch \
    -I$EMUGL_SRC/host/libs/libOpenglRender \
    -I$EMUGL_SRC/host/libs/GLESv1_dec \
    -I$EMUGL_SRC/host/libs/GLESv2_dec \
    -I$EMUGL_SRC/host/libs/renderControl_dec \
    -I$EMUGL_SRC/generated/gles1 \
    -I$EMUGL_SRC/generated/gles2 \
    -I$EMUGL_SRC/generated/renderControl \
    -I$EMUGL_SRC/shared \
    -I$EMUGL_SRC/shared/OpenglCodecCommon \
    -I$EMUGL_SRC/shared/emugl/common"

EMUGL_SRCS=(
    "$EMUGL_SRC/android/base/memory/LazyInstance.cpp"
    "$EMUGL_SRC/android/base/synchronization/MessageChannel.cpp"
    "$EMUGL_SRC/android/base/threads/Async.cpp"
    "$EMUGL_SRC/android/base/threads/FunctorThread.cpp"
    "$EMUGL_SRC/android/base/threads/ThreadStore.cpp"
    "$EMUGL_SRC/android/base/threads/Thread_pthread.cpp"
    "$EMUGL_SRC/shared/emugl/common/crash_reporter.cpp"
    "$EMUGL_SRC/shared/emugl/common/feature_control.cpp"
    "$EMUGL_SRC/shared/emugl/common/logging.cpp"
    "$EMUGL_SRC/shared/emugl/common/shared_library.cpp"
    "$EMUGL_SRC/shared/emugl/common/sockets.cpp"
    "$EMUGL_SRC/shared/emugl/common/stringparsing.cpp"
    "$EMUGL_SRC/shared/OpenglCodecCommon/ChecksumCalculator.cpp"
    "$EMUGL_SRC/shared/OpenglCodecCommon/ChecksumCalculatorThreadInfo.cpp"
    "$EMUGL_SRC/shared/OpenglCodecCommon/glUtils.cpp"
    "$EMUGL_SRC/generated/gles1/gles1_dec.cpp"
    "$EMUGL_SRC/generated/gles1/gles1_server_context.cpp"
    "$EMUGL_SRC/host/libs/GLESv1_dec/GLESv1Decoder.cpp"
    "$EMUGL_SRC/generated/gles2/gles2_dec.cpp"
    "$EMUGL_SRC/generated/gles2/gles2_server_context.cpp"
    "$EMUGL_SRC/host/libs/GLESv2_dec/GLESv2Decoder.cpp"
    "$EMUGL_SRC/generated/renderControl/renderControl_dec.cpp"
    "$EMUGL_SRC/generated/renderControl/renderControl_server_context.cpp"
    "$EMUGL_SRC/host/libs/libOpenGLESDispatch/EGLDispatch.cpp"
    "$EMUGL_SRC/host/libs/libOpenGLESDispatch/GLESv1Dispatch.cpp"
    "$EMUGL_SRC/host/libs/libOpenGLESDispatch/GLESv2Dispatch.cpp"
    "$EMUGL_SRC/host/libs/libOpenglRender/ChannelStream.cpp"
    "$EMUGL_SRC/host/libs/libOpenglRender/ColorBuffer.cpp"
    "$EMUGL_SRC/host/libs/libOpenglRender/FbConfig.cpp"
    "$EMUGL_SRC/host/libs/libOpenglRender/FrameBuffer.cpp"
    "$EMUGL_SRC/host/libs/libOpenglRender/NativeSubWindow_ios.cpp"
    "$EMUGL_SRC/host/libs/libOpenglRender/ReadBuffer.cpp"
    "$EMUGL_SRC/host/libs/libOpenglRender/RenderChannelImpl.cpp"
    "$EMUGL_SRC/host/libs/libOpenglRender/RenderContext.cpp"
    "$EMUGL_SRC/host/libs/libOpenglRender/RenderControl.cpp"
    "$EMUGL_SRC/host/libs/libOpenglRender/RenderLibImpl.cpp"
    "$EMUGL_SRC/host/libs/libOpenglRender/RenderThread.cpp"
    "$EMUGL_SRC/host/libs/libOpenglRender/RenderThreadInfo.cpp"
    "$EMUGL_SRC/host/libs/libOpenglRender/RenderWindow.cpp"
    "$EMUGL_SRC/host/libs/libOpenglRender/RendererImpl.cpp"
    "$EMUGL_SRC/host/libs/libOpenglRender/TextureDraw.cpp"
    "$EMUGL_SRC/host/libs/libOpenglRender/TextureResize.cpp"
    "$EMUGL_SRC/host/libs/libOpenglRender/TimeUtils.cpp"
    "$EMUGL_SRC/host/libs/libOpenglRender/WindowSurface.cpp"
    "$EMUGL_SRC/host/libs/libOpenglRender/render_api.cpp"
    "$EMUGL_SRC/eagl_ios_egl.cpp"
    "$EMUGL_SRC/goldfish_emugl_bridge.cpp"
)

EMUGL_OBJS=()
pids=()
for src in "${EMUGL_SRCS[@]}"; do
    rel="${src#$EMUGL_SRC/}"
    obj="$EMUGL_BUILD/objs/${rel//\//_}.o"
    EMUGL_OBJS+=("$obj")
    if [ ! -f "$obj" ] || [ "$src" -nt "$obj" ] || [ -n "$(find "$EMUGL_SRC" "$QEMU_SRC/hw/arm/android51" -maxdepth 6 \( -name "*.h" -o -name "*.hpp" \) -newer "$obj" -print -quit)" ]; then
        $CXX $EMUGL_CXXFLAGS -c "$src" -o "$obj" &
        pids+=($!)
        if [ "${#pids[@]}" -ge "$JOBS" ]; then
            wait "${pids[0]}"
            pids=("${pids[@]:1}")
        fi
    fi
done
for pid in "${pids[@]}"; do
    wait "$pid"
done

"$AR" rcs "$EMUGL_BUILD/libemugl_host.a" "${EMUGL_OBJS[@]}"

# 2. Configure & Build qemu-android (Goldfish ARMv7 only)
cd "$QEMU_BUILD"
unset CC CXX CFLAGS CXXFLAGS LDFLAGS
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export CC_FOR_BUILD=/usr/bin/cc
export CXX_FOR_BUILD=/usr/bin/c++

if [ ! -f "$QEMU_BUILD/build.ninja" ]; then
    echo "=== Configuring qemu-android for $TRIPLE ==="
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
        --with-devices-arm=android \
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

echo "=== Building qemu-android objects and static archives ==="
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

echo "=== Compiling Android iOS dylib entrypoints ==="
ENTRY_CFLAGS="-std=gnu11 -O3 -mcpu=apple-a9 -fPIC -D_GNU_SOURCE -DCOMPILING_SYSTEM_VS_USER -DCONFIG_SOFTMMU \
    -I$QEMU_BUILD -I$QEMU_BUILD/qapi -I$QEMU_BUILD/trace -I$QEMU_BUILD/ui \
    -I$QEMU_SRC -I$QEMU_SRC/include -I$QEMU_SRC/contrib/ios-android \
    -I$QEMU_SRC/host/include/aarch64 -I$QEMU_SRC/host/include/generic -I$QEMU_SRC/tcg/aarch64 \
    -I$PREFIX/include -I$PREFIX/include/glib-2.0 -I$PREFIX/lib/glib-2.0/include -I$PREFIX/include/pixman-1"

"$ROOT/build/wrappers/clang-ios" $ENTRY_CFLAGS -c "$QEMU_SRC/contrib/ios-android/qemu-android-entry.c" -o "$QEMU_BUILD/qemu-android-entry.o"
"$ROOT/build/wrappers/clang-ios" $ENTRY_CFLAGS -c "$QEMU_SRC/contrib/ios-android/qemu-android-ui.c" -o "$QEMU_BUILD/qemu-android-ui.o"

"$TC/nm" -g "$QEMU_BUILD/qemu-android-entry.o" "$QEMU_BUILD/qemu-android-ui.o" \
    | awk '$2 == "T" && $3 ~ /^_qemu_android_/ { print $3 }' | sort -u > "$QEMU_BUILD/libqemu-android.exports"

echo "=== Linking native iOS libqemu-android.dylib ==="
rm -f "$OUT_FRAMEWORKS/libqemu-android.dylib"

LINK_CMD=$(ninja -C "$QEMU_BUILD" -t commands qemu-system-arm-unsigned | tail -n 1)
python3 - "$LINK_CMD" "$QEMU_BUILD" "$OUT_FRAMEWORKS/libqemu-android.dylib" "$PREFIX/lib" "$EMUGL_BUILD/libemugl_host.a" <<'PY'
import shlex, subprocess, sys

link_cmd, qemu_build, out_dylib, prefix_lib, emugl_lib = sys.argv[1:6]
args = shlex.split(link_cmd)
new_args = []
i = 0
while i < len(args):
    a = args[i]
    if a == "-o" and i + 1 < len(args) and args[i + 1] == "qemu-system-arm-unsigned":
        new_args.extend([
            "-dynamiclib",
            "-install_name", "@rpath/libqemu-android.dylib",
            "-o", out_dylib,
            f"-Wl,-exported_symbols_list,{qemu_build}/libqemu-android.exports",
        ])
        i += 2
        continue
    if a.endswith("system_main.c.o"):
        new_args.extend([
            f"{qemu_build}/qemu-android-entry.o",
            f"{qemu_build}/qemu-android-ui.o",
            emugl_lib,
        ])
        i += 1
        continue
    new_args.append(a)
    i += 1

new_args.extend([f"-L{prefix_lib}", "-lc++", "-lcrypto", "-framework", "OpenGLES", "-framework", "IOSurface", "-framework", "Foundation"])
print("Linking:", out_dylib)
subprocess.check_call(new_args, cwd=qemu_build)
PY

"$TC/ldid" -S "$OUT_FRAMEWORKS/libqemu-android.dylib"
echo "=== Built $OUT_FRAMEWORKS/libqemu-android.dylib ==="
