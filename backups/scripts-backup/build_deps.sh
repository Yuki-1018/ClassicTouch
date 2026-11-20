#!/bin/bash
# Static arm64-iOS dependencies of the engine (qemu-ios) and the portable runtime:
#   glib/gio/gobject/gmodule, pcre2, libffi, libintl   reused prebuilt (refs/Artifice-prev sysroot, arm64 iOS)
#   zlib                                                 the SDK's libz
#   pixman 0.44.2, OpenSSL 3.6.x, libslirp (+ qemu-ios's restrict/guestfwd patches)   built here
# Network access is needed the first time (sources are cached in build/src).
source "$(dirname "$0")/env.sh"
cd "$BUILD"
REFS="$ROOT/refs"
QEMU="$REFS/qemu-ios-blake"

# --- prebuilt glib stack -------------------------------------------------------
if [ ! -f "$PREFIX/lib/libglib-2.0.a" ]; then
    cp -a "$REFS/Artifice-prev/deps/nat/sysroot/." "$PREFIX/"
    rm -f "$PREFIX/lib/libslirp.a" "$PREFIX/lib/pkgconfig/slirp.pc"     # rebuilt with the qemu-ios patches
    rm -rf "$PREFIX/include/slirp"
    # the .pc files point at the old prefix
    for pc in "$PREFIX"/lib/pkgconfig/*.pc; do
        sed -i -E "s|^prefix=.*|prefix=$PREFIX|" "$pc"
    done
fi

# --- zlib (SDK) ---------------------------------------------------------------
cat > "$PREFIX/lib/pkgconfig/zlib.pc" <<EOF
Name: zlib
Description: iOS SDK zlib
Version: 1.2.12
Libs: -lz
Cflags:
EOF

CROSS="$(meson_cross_file)"

# --- pixman --------------------------------------------------------------------
if [ ! -f "$PREFIX/lib/libpixman-1.a" ]; then
    t=$(fetch https://www.cairographics.org/releases/pixman-0.44.2.tar.gz)
    rm -rf pixman-0.44.2 && tar xf "$t"
    meson setup pixman-build pixman-0.44.2 --cross-file "$CROSS" --prefix "$PREFIX" --libdir lib \
        --default-library static --buildtype release -Dtests=disabled -Ddemos=disabled \
        -Da64-neon=disabled -Dgtk=disabled -Dlibpng=disabled -Dopenmp=disabled
    ninja -C pixman-build install
fi

# --- OpenSSL --------------------------------------------------------------------
if [ ! -f "$PREFIX/lib/libcrypto.a" ]; then
    t=$(fetch https://github.com/openssl/openssl/releases/download/openssl-3.6.3/openssl-3.6.3.tar.gz)
    rm -rf openssl-3.6.3 && tar xf "$t"
    (cd openssl-3.6.3 &&
        CC="$TC/clang" CFLAGS="-target $TRIPLE -isysroot $SDK $OPT_CFLAGS" \
        ./Configure ios64-cross no-shared no-tests no-module no-engine no-apps no-docs \
            --prefix="$PREFIX" --libdir=lib CROSS_TOP="$(dirname "$(dirname "$SDK")")" CROSS_SDK="$(basename "$SDK")" &&
        make -j"$JOBS" build_libs && make install_dev)
fi

# --- libslirp (qemu-ios's pinned revision and patches) -----------------------
if [ ! -f "$PREFIX/lib/libslirp.a" ]; then
    rev=$(sed -n 's/^revision = //p' "$QEMU/subprojects/slirp.wrap")
    t=$(fetch "https://gitlab.freedesktop.org/slirp/libslirp/-/archive/$rev/libslirp-$rev.tar.gz")
    rm -rf "libslirp-$rev" && tar xf "$t"
    for p in libslirp-set-restricted.patch libslirp-restricted-dns.patch; do
        patch -d "libslirp-$rev" -p1 < "$QEMU/subprojects/packagefiles/$p"
    done
    meson setup slirp-build "libslirp-$rev" --cross-file "$CROSS" --prefix "$PREFIX" --libdir lib \
        --default-library static --buildtype release
    ninja -C slirp-build install
fi

# --- FFmpeg 9.0.1 (patched libavcodec/libavutil for AMC audio + VXD H.264) ---
if [ ! -f "$PREFIX/lib/libavcodec.a" ] || [ ! -f "$PREFIX/lib/pkgconfig/libavcodec.pc" ]; then
    t=$(fetch "https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz" "cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635")
    rm -rf ffmpeg-9.0.1 && tar xf "$t"
    for p in h264-chunk-er.patch h264-cavlc-pcm-offset.patch; do
        patch -d ffmpeg-9.0.1 -p1 < "$QEMU/contrib/ffmpeg/$p"
    done
    (cd ffmpeg-9.0.1 && \
        unset CC CXX CFLAGS CXXFLAGS LDFLAGS && \
        export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" && \
        ./configure \
            --prefix="$PREFIX" --libdir="$PREFIX/lib" \
            --target-os=darwin --arch=aarch64 --enable-cross-compile \
            --host-cc=/usr/bin/cc \
            --cc="$TC/clang" --cxx="$TC/clang++" --as="$TC/clang -target $TRIPLE -isysroot $SDK -mcpu=apple-a9 -fPIC" \
            --ar="$TC/ar" --ranlib="$TC/ranlib" --nm="$TC/nm" --strip="$TC/strip" \
            --extra-cflags="-target $TRIPLE -isysroot $SDK $OPT_CFLAGS -fPIC" \
            --extra-ldflags="-target $TRIPLE -isysroot $SDK" \
            --disable-everything --disable-autodetect --disable-programs --disable-doc \
            --disable-avdevice --disable-avformat --disable-avfilter --disable-swscale --disable-swresample \
            --enable-decoder=aac,mp3,alac,h264 --enable-encoder=aac \
            --enable-static --disable-shared --enable-pic && \
        make -j"$JOBS" && make install)
fi

echo "dependencies ready in $PREFIX"
ls "$PREFIX/lib"/*.a
