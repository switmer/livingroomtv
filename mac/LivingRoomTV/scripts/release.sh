#!/bin/zsh
# Build a notarized, universal-binary release of LivingRoomTV.
# Output: dist/LivingRoomTV-<version>.dmg
#
# Required env vars (set these before running, or source from a .env):
#   APPLE_TEAM_ID            Your 10-char Apple Developer Team ID
#   DEVELOPER_ID_APPLICATION Full cert common name, e.g.
#                            "Developer ID Application: Your Name (ABCD1234EF)"
#   NOTARY_PROFILE           Keychain profile name set up via:
#                            xcrun notarytool store-credentials <name> ...
#
# Optional:
#   SKIP_NOTARIZE=1   Sign with Developer ID but skip the notary submission
#                     (useful for fast local iteration on the signing path).

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# -- Required env vars --------------------------------------------------------

require_env() {
    local name="$1"
    if [ -z "${(P)name:-}" ]; then
        echo "✗ Missing required env var: $name" >&2
        echo "  See header of release.sh for setup instructions." >&2
        exit 1
    fi
}

require_env APPLE_TEAM_ID
require_env DEVELOPER_ID_APPLICATION
if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    require_env NOTARY_PROFILE
fi

APP_NAME="LivingRoomTV"
APP_DIR="dist/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG_PATH="dist/${APP_NAME}-${VERSION}.dmg"

# -- Build (universal: arm64 + x86_64) ----------------------------------------

echo "==> Clean"
rm -rf dist .build
mkdir -p "${MACOS}" "${RESOURCES}"

echo "==> Build universal release binary (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64

# Multi-arch builds land in a different path
BUILD_DIR=".build/apple/Products/Release"
if [ ! -x "${BUILD_DIR}/${APP_NAME}" ]; then
    echo "✗ Expected universal binary at ${BUILD_DIR}/${APP_NAME}" >&2
    exit 1
fi

# Verify it's actually universal
echo "==> Verifying architecture"
lipo -info "${BUILD_DIR}/${APP_NAME}"

# -- Assemble bundle ----------------------------------------------------------

echo "==> Generate icon"
ICONSET="dist/AppIcon.iconset"
swift scripts/make-icon.swift "${ICONSET}" > /dev/null
iconutil --convert icns "${ICONSET}" --output "${RESOURCES}/AppIcon.icns"
rm -rf "${ICONSET}"

echo "==> Assemble bundle"
cp "${BUILD_DIR}/${APP_NAME}" "${MACOS}/${APP_NAME}"
cp "Resources/Info.plist" "${CONTENTS}/Info.plist"

# Stage SPM resource bundles into Contents/Resources/ where Bundle.module's
# accessor expects them (it checks Bundle.main.resourceURL, NOT Contents/MacOS/).
#
# SPM emits the bundle in one of two shapes depending on build flags:
#   - Single-arch `swift build`: FLAT — PNGs sit directly under the .bundle dir
#   - Universal `swift build --arch arm64 --arch x86_64`: PROPER — uses Xcode
#     build system which produces Contents/Info.plist + Contents/Resources/
#
# Handle both. The proper case = straight copy. The flat case = wrap into
# Contents/Resources/ and write a minimal Info.plist so codesign accepts it.
for b in "${BUILD_DIR}"/*.bundle; do
    [ -e "$b" ] || continue
    bundle_name="$(basename "$b")"
    dest="${RESOURCES}/${bundle_name}"

    if [ -f "${b}/Contents/Info.plist" ]; then
        cp -R "$b" "${RESOURCES}/"
        echo "   + copied ${bundle_name} (already proper macOS bundle)"
    else
        mkdir -p "${dest}/Contents/Resources"
        find "$b" -mindepth 1 -maxdepth 1 -exec cp -R {} "${dest}/Contents/Resources/" \;
        bundle_id="com.stevewitmer.LivingRoomTV.${bundle_name%.bundle}"
        cat > "${dest}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleIdentifier</key><string>${bundle_id}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>${bundle_name%.bundle}</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
PLIST
        echo "   + repackaged ${bundle_name} (wrapped flat SPM output)"
    fi
done

# -- Sign with Developer ID ---------------------------------------------------

echo "==> Sign with Developer ID"
# Hardened runtime is required for notarization. The --options runtime flag
# enables it; we sign nested bundles first, then the outer .app.
codesign --force --options runtime --timestamp \
    --sign "${DEVELOPER_ID_APPLICATION}" \
    "${RESOURCES}"/*.bundle 2>/dev/null || true
codesign --force --options runtime --timestamp \
    --sign "${DEVELOPER_ID_APPLICATION}" \
    "${APP_DIR}"
codesign --verify --strict --verbose=2 "${APP_DIR}"

# -- Notarize -----------------------------------------------------------------

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    echo "==> Skipping notarization (SKIP_NOTARIZE=1)"
else
    echo "==> Submit to notary service (this can take 1–10 minutes)"
    NOTARY_ZIP="dist/${APP_NAME}-notary.zip"
    /usr/bin/ditto -c -k --keepParent "${APP_DIR}" "${NOTARY_ZIP}"

    xcrun notarytool submit "${NOTARY_ZIP}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait

    rm -f "${NOTARY_ZIP}"

    echo "==> Staple ticket"
    xcrun stapler staple "${APP_DIR}"
    xcrun stapler validate "${APP_DIR}"
fi

# -- Build DMG ---------------------------------------------------------------

echo "==> Build DMG"
if command -v create-dmg >/dev/null 2>&1; then
    rm -f "${DMG_PATH}"
    # Multi-rep TIFF with 1× (540×380) + 2× (1080×760) renditions — Finder
    # picks the right one for the display. Plain @2x PNG looks broken because
    # Finder treats pixel dims as point dims and clips the window viewport.
    BG_IMAGE="Resources/dmg/background.tiff"
    BG_ARG=()
    if [ -f "${BG_IMAGE}" ]; then
        BG_ARG=(--background "${BG_IMAGE}")
        echo "   using custom background ${BG_IMAGE}"
    fi
    # Icon positions match the placeholder boxes in the background image.
    # Window 540×380; background 1080×760 (2× retina). Coordinates are in
    # window space — create-dmg scales the background to fill.
    create-dmg \
        --volname "${APP_NAME} ${VERSION}" \
        --window-size 540 380 \
        --icon-size 128 \
        --icon "${APP_NAME}.app" 123 217 \
        --hide-extension "${APP_NAME}.app" \
        --app-drop-link 417 217 \
        "${BG_ARG[@]}" \
        "${DMG_PATH}" \
        "${APP_DIR}" \
        2>&1 | tail -5
else
    echo "   create-dmg not installed — falling back to plain hdiutil"
    rm -f "${DMG_PATH}"
    hdiutil create -volname "${APP_NAME} ${VERSION}" \
        -srcfolder "${APP_DIR}" \
        -ov -format UDZO \
        "${DMG_PATH}"
    echo "   tip: \`brew install create-dmg\` for a nicer installer window"
fi

# -- Sign + (optionally) notarize the DMG itself -----------------------------

echo "==> Sign DMG"
codesign --force --sign "${DEVELOPER_ID_APPLICATION}" --timestamp "${DMG_PATH}"

if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    echo "==> Notarize DMG"
    xcrun notarytool submit "${DMG_PATH}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait
    xcrun stapler staple "${DMG_PATH}"
fi

echo ""
echo "✅ Built: ${ROOT}/${DMG_PATH}"
echo ""
echo "==> Verifying Gatekeeper acceptance"
spctl -a -t open --context context:primary-signature -v "${DMG_PATH}" 2>&1 | sed 's/^/   /' || true

# -- Optional: draft a GitHub release ----------------------------------------

TAG="v${VERSION}"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    echo ""
    printf "Create a draft GitHub release tagged %s? [Y/n] " "${TAG}"
    read -r reply
    case "${reply:-Y}" in
        [Nn]*)
            echo "Skipped. Run manually:"
            echo "  gh release create ${TAG} ${DMG_PATH} --title \"LivingRoomTV ${VERSION}\" --draft --generate-notes"
            ;;
        *)
            gh release create "${TAG}" "${DMG_PATH}" \
                --title "LivingRoomTV ${VERSION}" \
                --draft \
                --generate-notes
            ;;
    esac
else
    echo ""
    echo "Manual upload (gh CLI not available):"
    echo "  gh release create ${TAG} ${DMG_PATH} --title \"LivingRoomTV ${VERSION}\" --draft --generate-notes"
fi
