#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP_NAME="ClassicTouch"
BUNDLE="$DIST/Payload/$APP_NAME.app"
IPA="$DIST/$APP_NAME.ipa"
TIPA="$DIST/$APP_NAME.tipa"
DEB_DIR="$DIST/deb"

echo "=== Packaging $APP_NAME for iOS ==="

rm -rf "$DIST"
mkdir -p "$BUNDLE" "$DIST/Payload"

# Copy binary
cp -f "$ROOT/build/ClassicTouch" "$BUNDLE/$APP_NAME"
chmod 755 "$BUNDLE/$APP_NAME"

# Copy Info.plist
cp -f "$ROOT/Info.plist" "$BUNDLE/Info.plist"

# Copy Resources
cp -f "$ROOT/Resources/firmware-catalog.json" "$BUNDLE/firmware-catalog.json"
# Pack guest Mach-O helpers inside host-tools.itpack so sideloaders never re-sign or strip guest entitlements;
# keep armv6.itpack / armv7.itpack alongside it in guest-tools/.
mkdir -p "$BUNDLE/guest-tools"
cp -f "$ROOT/Resources/guest-tools"/*.itpack "$BUNDLE/guest-tools/"
python3 - "$ROOT/Resources/guest-tools" "$BUNDLE/guest-tools/host-tools.itpack" << 'PYEOF'
import hashlib, json, os, stat, struct, sys, zlib
src_dir, out_path = sys.argv[1], sys.argv[2]
entries, chunks = [], []
for name in sorted(os.listdir(src_dir)):
    if name.endswith(".itpack") or name.startswith("."):
        continue
    full = os.path.join(src_dir, name)
    if not os.path.isfile(full):
        continue
    data = open(full, "rb").read()
    mode = stat.S_IMODE(os.stat(full).st_mode)
    entries.append({
        "name": name,
        "size": len(data),
        "mode": mode,
        "sha256": hashlib.sha256(data).hexdigest(),
    })
    chunks.append(data)
idx = json.dumps({"format": 1, "entries": entries}, separators=(", ", ": ")).encode("utf-8")
comp = zlib.compress(b"".join(chunks), 9)
open(out_path, "wb").write(b"ITPACK01" + struct.pack("<I", len(idx)) + idx + comp)
print(f"Packed {len(entries)} guest-tools into {os.path.basename(out_path)} ({os.path.getsize(out_path)} bytes)")
PYEOF
cp -rf "$ROOT/Resources/en.lproj" "$BUNDLE/en.lproj"
cp -rf "$ROOT/Resources/ja.lproj" "$BUNDLE/ja.lproj"
cp -f "$ROOT/Resources/AppIcons"/*.png "$BUNDLE/"

# Ensure native iOS libqemu-arm.dylib is built
if [ ! -f "$ROOT/build/Frameworks/libqemu-arm.dylib" ]; then
    echo "ERROR: $ROOT/build/Frameworks/libqemu-arm.dylib missing. Run scripts/build_engine.sh first." >&2
    exit 1
fi

# Copy Frameworks
mkdir -p "$BUNDLE/Frameworks"
cp -rf "$ROOT/build/Frameworks"/* "$BUNDLE/Frameworks/"
chmod -R 755 "$BUNDLE/Frameworks"

# Sign with ldid (-Cadhoc sets CS_ADHOC on CodeDirectory)
find "$BUNDLE/Frameworks" -type f \( -name "*.dylib" -o -name "OpenGL" \) -exec /home/Yuki-1018/theos/toolchain/linux/iphone/bin/ldid -Cadhoc -S {} +
/home/Yuki-1018/theos/toolchain/linux/iphone/bin/ldid -Cadhoc -S"$ROOT/entitlements.plist" "$BUNDLE/$APP_NAME"

# Create .ipa and .tipa (TrollStore IPA)
cd "$DIST"
zip -qry "$IPA" Payload
cp -f "$IPA" "$TIPA"

echo "=== Created IPA & TIPA ==="
ls -lh "$IPA" "$TIPA"

# Create Debian package (.deb) for Theos / Cydia / Sileo / Filza installation
mkdir -p "$DEB_DIR/Applications" "$DEB_DIR/DEBIAN"
cp -rf "$BUNDLE" "$DEB_DIR/Applications/"
cp -f "$ROOT/control" "$DEB_DIR/DEBIAN/control"

# Postinst to set permissions and uicache
cat << 'EOF' > "$DEB_DIR/DEBIAN/postinst"
#!/bin/sh
chmod -R 755 /Applications/ClassicTouch.app
uicache -p /Applications/ClassicTouch.app 2>/dev/null || true
exit 0
EOF
chmod 755 "$DEB_DIR/DEBIAN/postinst"

dpkg-deb -Zgzip --root-owner-group -b "$DEB_DIR" "$DIST/${APP_NAME}_1.0.0_iphoneos-arm64.deb"

# Clean temporary packaging directories
rm -rf "$DIST/Payload" "$DEB_DIR"

echo "=== Packaging Complete! ==="
ls -lh "$DIST"
