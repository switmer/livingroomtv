#!/bin/zsh
set -euo pipefail

# Build LivingRoomTV as a proper .app bundle with icon, ad-hoc signed.
# Result: dist/LivingRoomTV.app ready to drag to /Applications.

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

APP_NAME="LivingRoomTV"
APP_DIR="dist/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "==> Clean"
rm -rf dist
mkdir -p "${MACOS}" "${RESOURCES}"

echo "==> Build release binary"
swift build -c release

echo "==> Generate icon"
ICONSET="dist/AppIcon.iconset"
swift scripts/make-icon.swift "${ICONSET}" > /dev/null
iconutil --convert icns "${ICONSET}" --output "${RESOURCES}/AppIcon.icns"
rm -rf "${ICONSET}"

echo "==> Assemble bundle"
cp ".build/release/${APP_NAME}" "${MACOS}/${APP_NAME}"
cp "Resources/Info.plist" "${CONTENTS}/Info.plist"

# SPM generates a per-target resource bundle alongside the binary as a flat
# directory of files. Modern codesign rejects flat .bundle directories — they
# must be proper macOS bundles with Contents/Info.plist + Contents/Resources/.
# Bundle.module's lookups (url(forResource:withExtension:)) resolve through
# Contents/Resources/ on macOS, so this layout still works at runtime.
for b in .build/release/*.bundle; do
  [ -e "$b" ] || continue
  bundle_name="$(basename "$b")"
  dest="${MACOS}/${bundle_name}"
  mkdir -p "${dest}/Contents/Resources"
  # Copy all resource files into Contents/Resources/
  find "$b" -mindepth 1 -maxdepth 1 -exec cp -R {} "${dest}/Contents/Resources/" \;
  # Write a minimal Info.plist so codesign recognizes it as a bundle
  bundle_id="com.stevewitmer.LivingRoomTV.${bundle_name%.bundle}"
  cat > "${dest}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleIdentifier</key>
    <string>${bundle_id}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${bundle_name%.bundle}</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
PLIST
  echo "   + repackaged $(basename "$b")"
done

echo "==> Ad-hoc sign"
codesign --force --deep --sign - "${APP_DIR}"
codesign --verify --verbose=2 "${APP_DIR}" 2>&1 | sed 's/^/   /'

echo ""
echo "Built: ${ROOT}/${APP_DIR}"
echo ""
echo "Install:  mv ${APP_DIR} /Applications/"
echo "Run:      open /Applications/${APP_NAME}.app"
