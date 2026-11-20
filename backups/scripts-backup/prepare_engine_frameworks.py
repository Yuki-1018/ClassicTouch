#!/usr/bin/env python3
import os
import sys
import glob
import struct
import zipfile
import subprocess

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ZIP_PATH = os.path.join(ROOT, "refs/release-assets/LightTouch-v0.0.13-macOS-arm64.zip")
OUT_DIR = os.path.join(ROOT, "build/Frameworks")
TOOLCHAIN_BIN = "/home/Yuki-1018/theos/toolchain/linux/iphone/bin"
SDK_PATH = "/home/Yuki-1018/theos/sdks/iPhoneOS16.5.sdk"

os.makedirs(OUT_DIR, exist_ok=True)

print("=== Extracting dylibs from macOS release zip ===")
with zipfile.ZipFile(ZIP_PATH, 'r') as z:
    for name in z.namelist():
        if name.endswith("libqemu-arm.dylib") or (name.startswith("LightTouch.app/Contents/Frameworks/") and name.endswith(".dylib")):
            base = os.path.basename(name)
            dest = os.path.join(OUT_DIR, base)
            with open(dest, "wb") as f:
                f.write(z.read(name))
            print(f"  Extracted {base}")

def patch_macho_platform(path):
    with open(path, "r+b") as f:
        data = f.read(32)
        if len(data) < 32:
            return
        magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack("<IIIIIIII", data)
        if magic != 0xfeedfacf: # 64-bit Mach-O little-endian
            return
        offset = 32
        for _ in range(ncmds):
            f.seek(offset)
            cmd_data = f.read(8)
            if len(cmd_data) < 8:
                break
            cmd, cmdsize = struct.unpack("<II", cmd_data)
            if cmd == 0x32: # LC_BUILD_VERSION
                # platform at +8, minos at +12, sdk at +16
                f.seek(offset + 8)
                f.write(struct.pack("<III", 2, 15 << 16, (16 << 16) | (5 << 8)))
            elif cmd == 0x24: # LC_VERSION_MIN_MACOSX
                f.seek(offset)
                f.write(struct.pack("<I", 0x25)) # LC_VERSION_MIN_IPHONEOS
            offset += cmdsize

print("=== Patching Mach-O platforms to iOS (platform=2) ===")
for dylib in glob.glob(os.path.join(OUT_DIR, "*.dylib")):
    patch_macho_platform(dylib)
    print(f"  Patched {os.path.basename(dylib)}")

int_tool = os.path.join(TOOLCHAIN_BIN, "install_name_tool")
otool = os.path.join(TOOLCHAIN_BIN, "otool")

REWRITES = {
    "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation": "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
    "/System/Library/Frameworks/CoreMedia.framework/Versions/A/CoreMedia": "/System/Library/Frameworks/CoreMedia.framework/CoreMedia",
    "/System/Library/Frameworks/CoreVideo.framework/Versions/A/CoreVideo": "/System/Library/Frameworks/CoreVideo.framework/CoreVideo",
    "/System/Library/Frameworks/VideoToolbox.framework/Versions/A/VideoToolbox": "/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox",
    "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation": "/System/Library/Frameworks/Foundation.framework/Foundation",
    "/System/Library/Frameworks/CoreServices.framework/Versions/A/CoreServices": "/System/Library/Frameworks/CoreServices.framework/CoreServices",
    "/System/Library/Frameworks/SystemConfiguration.framework/Versions/A/SystemConfiguration": "/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration",
    "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit": "/System/Library/Frameworks/IOKit.framework/IOKit",
    "/System/Library/Frameworks/OpenGL.framework/Versions/A/OpenGL": "@rpath/OpenGL.framework/OpenGL",
}

print("=== Rewriting all framework dependencies to iOS native paths ===")
for dylib in glob.glob(os.path.join(OUT_DIR, "*.dylib")):
    res = subprocess.run([otool, "-L", dylib], capture_output=True, text=True, check=True)
    changes = []
    for line in res.stdout.splitlines()[1:]:
        dep = line.strip().split(" (")[0]
        if dep in REWRITES:
            changes.extend(["-change", dep, REWRITES[dep]])
        elif dep.startswith("@loader_path/../Frameworks/"):
            new_dep = "@rpath/" + dep.replace("@loader_path/../Frameworks/", "")
            changes.extend(["-change", dep, new_dep])
        elif dep.startswith("@loader_path/"):
            new_dep = "@rpath/" + dep.replace("@loader_path/", "")
            changes.extend(["-change", dep, new_dep])
        elif "build/Frameworks/" in dep:
            new_dep = "@rpath/" + os.path.basename(dep)
            changes.extend(["-change", dep, new_dep])

    cmd = [int_tool] + changes
    cmd.extend(["-id", "@rpath/" + os.path.basename(dylib)])
    cmd.extend(["-add_rpath", "@loader_path", "-add_rpath", "@executable_path/Frameworks"])
    cmd.append(dylib)
    subprocess.run(cmd, check=True)
    print(f"  Configured {os.path.basename(dylib)}")

print("=== Building OpenGL.framework stub for iOS ===")
gl_framework_dir = os.path.join(OUT_DIR, "OpenGL.framework")
os.makedirs(gl_framework_dir, exist_ok=True)

qemu_dylib = os.path.join(OUT_DIR, "libqemu-arm.dylib")
nm_tool = os.path.join(TOOLCHAIN_BIN, "nm")
res = subprocess.run([nm_tool, "-u", qemu_dylib], capture_output=True, text=True, check=True)
syms = []
for line in res.stdout.splitlines():
    line = line.strip()
    if line.startswith("_gl") or line.startswith("_CGL"):
        syms.append(line.lstrip("_"))

syms = sorted(list(set(syms)))
stub_c = os.path.join(OUT_DIR, "opengl_stub.c")
with open(stub_c, "w") as f:
    f.write("#include <stdint.h>\n#include <stddef.h>\n\n")
    for s in syms:
        f.write(f'__attribute__((visibility("default"))) void *{s}(void) {{ return NULL; }}\n')

gl_dylib = os.path.join(gl_framework_dir, "OpenGL")
clang_tool = os.path.join(TOOLCHAIN_BIN, "clang")
subprocess.run([
    clang_tool,
    "-target", "arm64-apple-ios15.0",
    "-isysroot", SDK_PATH,
    "-shared", "-fPIC",
    "-install_name", "@rpath/OpenGL.framework/OpenGL",
    "-o", gl_dylib,
    stub_c
], check=True)
print(f"  Built {gl_dylib} ({len(syms)} exported GL/CGL symbols)")

ldid_tool = os.path.join(TOOLCHAIN_BIN, "ldid")
print("=== Pseudo-signing all framework binaries ===")
subprocess.run([ldid_tool, "-S", gl_dylib], check=True)
for dylib in glob.glob(os.path.join(OUT_DIR, "*.dylib")):
    subprocess.run([ldid_tool, "-S", dylib], check=True)
    print(f"  Signed {os.path.basename(dylib)}")

print("=== Frameworks preparation complete! ===")
