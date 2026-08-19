#!/bin/bash
#
# Builds a signed, notarized, stapled ThumbPrint.dmg for public download.
#
#   ./Scripts/release.sh                # full release build
#   ./Scripts/release.sh --no-notarize  # sign and package only (local smoke test)
#
# The Xcode project itself stays ad-hoc signed so anyone can clone and build
# without a certificate. The Developer ID identity, hardened runtime and secure
# timestamp are applied here instead, on the release build only.
#
# One-time setup for notarization — stores an app-specific password in the
# keychain under the profile name this script expects:
#
#   xcrun notarytool store-credentials "ThumbPrint" \
#       --apple-id "djsnowlin@gmail.com" \
#       --team-id "DPLC4BD7ST" \
#       --password "<app-specific-password from appleid.apple.com>"

set -euo pipefail

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

IDENTITY="Developer ID Application: Sascha Nowlin (DPLC4BD7ST)"
TEAM_ID="DPLC4BD7ST"
NOTARY_PROFILE="ThumbPrint"
DIST="dist"

NOTARIZE=1
[[ "${1:-}" == "--no-notarize" ]] && NOTARIZE=0

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31mError: %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- preflight --
step "Checking prerequisites"

security find-identity -v -p codesigning | grep -q "$IDENTITY" \
    || fail "signing identity not found in the keychain: $IDENTITY"

if (( NOTARIZE )); then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || fail "notary profile '$NOTARY_PROFILE' not stored. See the header of this script."
fi
echo "Signing identity and notary credentials present."

# -------------------------------------------------------------------- build --
step "Building Release"

rm -rf "$DIST"
mkdir -p "$DIST"

xcodebuild \
    -project ThumbPrint.xcodeproj \
    -scheme ThumbPrint \
    -configuration Release \
    -derivedDataPath "$DIST/DerivedData" \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    ENABLE_HARDENED_RUNTIME=YES \
    clean build \
    | grep -E "error:|warning:|BUILD" || true

APP="$DIST/DerivedData/Build/Products/Release/ThumbPrint.app"
[[ -d "$APP" ]] || fail "build did not produce $APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
echo "Built ThumbPrint $VERSION"

# --------------------------------------------------------------------- sign --
# Re-signed explicitly rather than trusting the build's signature, because
# notarization requires --options runtime and a secure --timestamp, and a
# build-phase signature carries neither reliably.
step "Signing with Developer ID"

codesign --force --options runtime --timestamp \
    --entitlements Config/ThumbPrint.entitlements \
    --sign "$IDENTITY" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
echo "Signature valid."

# --------------------------------------------------------------- notarize ----
if (( NOTARIZE )); then
    step "Notarizing the app"

    ZIP="$DIST/ThumbPrint-$VERSION.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"

    xcrun notarytool submit "$ZIP" \
        --keychain-profile "$NOTARY_PROFILE" --wait \
        || fail "notarization failed — run 'xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE' for the reason"

    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    echo "App notarized and stapled."
fi

# ------------------------------------------------------------------ package --
step "Building the disk image"

STAGE="$DIST/stage"
DMG="$DIST/ThumbPrint-$VERSION.dmg"

mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/ThumbPrint.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
    -volname "ThumbPrint $VERSION" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    -quiet "$DMG"

rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if (( NOTARIZE )); then
    step "Notarizing the disk image"
    xcrun notarytool submit "$DMG" \
        --keychain-profile "$NOTARY_PROFILE" --wait \
        || fail "disk image notarization failed"
    xcrun stapler staple "$DMG"
fi

# ------------------------------------------------------------------- verify --
step "Verifying the result"

codesign --verify --deep --strict --verbose=2 "$APP"
codesign --display --verbose=2 "$APP" 2>&1 | grep -E "^(Authority|TeamIdentifier|Timestamp|flags)"

if (( NOTARIZE )); then
    # Only meaningful once a ticket exists: Gatekeeper rejects a Developer ID
    # build that has not been notarized, which is the expected state of a
    # --no-notarize run rather than a failure.
    spctl --assess --type exec --verbose=2 "$APP" || fail "Gatekeeper rejected the app"
    xcrun stapler validate "$DMG" || fail "the disk image has no stapled ticket"
fi

rm -rf "$DIST/DerivedData"
shasum -a 256 "$DMG"

printf '\n\033[32mReady: %s\033[0m\n' "$DMG"
echo "Attach it and confirm the app opens with no Gatekeeper warning before publishing."
