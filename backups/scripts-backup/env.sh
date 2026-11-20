# Shared cross-compilation environment for arm64 iOS (sourced by every build script).
# Theos ships an Apple clang/ld64 port for Linux plus the iPhoneOS SDK.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THEOS="${THEOS:-$HOME/theos}"
TC="$THEOS/toolchain/linux/iphone/bin"
SDK="${SDK:-$THEOS/sdks/iPhoneOS16.5.sdk}"
MIN_IOS="${MIN_IOS:-15.0}"
TRIPLE="arm64-apple-ios$MIN_IOS"

BUILD="$ROOT/build"
SRC_CACHE="$BUILD/src"
PREFIX="$BUILD/sysroot"          # static dependencies for arm64 iOS
JOBS="${JOBS:-$(nproc)}"
mkdir -p "$SRC_CACHE" "$PREFIX/lib/pkgconfig" "$PREFIX/include"

export PATH="$TC:$PATH"
export CC="$TC/clang -target $TRIPLE -isysroot $SDK"
export CXX="$TC/clang++ -target $TRIPLE -isysroot $SDK"
export AR="$TC/ar" RANLIB="$TC/ranlib" STRIP="$TC/strip" NM="$TC/nm" LIPO="$TC/lipo"
# -O3 + Apple A9 (ARMv8.0-A + Crypto/AES/SHA2, no A10+ CRC32 or A11+ LSE atomics) for all iOS 15+ devices (iPhone 6s / SE / 7 / 8+).
export OPT_CFLAGS="-O3 -mcpu=apple-a9 -fno-common -fvisibility=default"
export CFLAGS="$OPT_CFLAGS -fPIC -I$PREFIX/include"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-L$PREFIX/lib"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR=""

fetch() { # url [sha256] [filename] -> path in SRC_CACHE
    local url="$1" out="$SRC_CACHE/${3:-$(basename "$1")}"
    if [ ! -s "$out" ]; then
        curl -fsSL --retry 3 -o "$out.part" "$url" >&2
        mv "$out.part" "$out"
    fi
    if [ -n "${2:-}" ]; then echo "$2  $out" | sha256sum -c - >/dev/null; fi
    echo "$out"
}

meson_cross_file() { # writes a meson cross file for arm64 iOS
    local f="$BUILD/ios-arm64.cross"
    cat > "$f" <<EOF
[binaries]
c = ['$TC/clang', '-target', '$TRIPLE', '-isysroot', '$SDK']
cpp = ['$TC/clang++', '-target', '$TRIPLE', '-isysroot', '$SDK']
objc = ['$TC/clang', '-target', '$TRIPLE', '-isysroot', '$SDK']
ar = '$TC/ar'
strip = '$TC/strip'
ranlib = '$TC/ranlib'
pkg-config = '/usr/bin/pkg-config'

[host_machine]
system = 'darwin'
subsystem = 'ios'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[properties]
needs_exe_wrapper = true

[built-in options]
c_args = ['-mcpu=apple-a9', '-fPIC', '-I$PREFIX/include']
cpp_args = ['-mcpu=apple-a9', '-fPIC', '-I$PREFIX/include']
c_link_args = ['-L$PREFIX/lib']
cpp_link_args = ['-L$PREFIX/lib']
EOF
    echo "$f"
}
