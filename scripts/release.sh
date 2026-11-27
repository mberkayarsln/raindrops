#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${IDENTITY:-Developer ID Application: Mustafa Berkay Arslan (MZ6TYANWHN)}"
TEAM_ID="${TEAM_ID:-MZ6TYANWHN}"
NOTARY_PROFILE="${NOTARY_PROFILE:-raindrops}"
DERIVED=build/release
APP="$DERIVED/Build/Products/Release/Raindrops.app"
DIST=dist
DMG="$DIST/Raindrops.dmg"

xcodegen generate --quiet
rm -rf "$DERIVED"
xcodebuild -project Raindrops.xcodeproj -scheme Raindrops -configuration Release -derivedDataPath "$DERIVED" -quiet \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  build

codesign --verify --deep --strict --verbose=2 "$APP"
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
  echo "Release build still has get-task-allow"
  exit 1
fi
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/source"
ditto "$APP" "$STAGE/source/Raindrops.app"
tiffutil -cathidpicheck Resources/DMG/background.png Resources/DMG/background@2x.png -out "$STAGE/background.tiff" >/dev/null

mkdir -p "$DIST"
rm -f "$DMG"
create-dmg \
  --volname Raindrops \
  --volicon "$APP/Contents/Resources/AppIcon.icns" \
  --background "$STAGE/background.tiff" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 128 \
  --text-size 13 \
  --icon Raindrops.app 165 180 \
  --hide-extension Raindrops.app \
  --app-drop-link 495 180 \
  --no-internet-enable \
  "$DMG" "$STAGE/source" >/dev/null
codesign --sign "$IDENTITY" --timestamp "$DMG"

RESULT=$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
STATUS=$(plutil -extract status raw -o - - <<< "$RESULT")
SUBMISSION=$(plutil -extract id raw -o - - <<< "$RESULT")
if [[ "$STATUS" != "Accepted" ]]; then
  echo "Notarization failed: $STATUS"
  xcrun notarytool log "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE"
  exit 1
fi

xcrun stapler staple -q "$DMG"
xcrun stapler validate -q "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo "Raindrops $VERSION: $(pwd)/$DMG"
