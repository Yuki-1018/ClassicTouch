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
cp -rf "$ROOT/Resources/guest-tools" "$BUNDLE/guest-tools"
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

# Sign with ldid
find "$BUNDLE/Frameworks" -type f \( -name "*.dylib" -o -name "OpenGL" \) -exec /home/Yuki-1018/theos/toolchain/linux/iphone/bin/ldid -S {} +
/home/Yuki-1018/theos/toolchain/linux/iphone/bin/ldid -S"$ROOT/entitlements.plist" "$BUNDLE/$APP_NAME"

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

echo "=== Packaging Complete! ==="
ls -lh "$DIST"
