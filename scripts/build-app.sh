#!/usr/bin/env bash
# Builds dist/AndroBridge.app (universal: Apple Silicon + Intel) and dist/AndroBridge-<version>.dmg.
#
#   scripts/build-app.sh                 # unsigned (ad-hoc signed) local build
#   scripts/build-app.sh --bundle-adb    # also copy your installed adb into the app (for your own build; see README licensing note)
#   scripts/build-app.sh --arch arm64    # Apple Silicon only (faster)
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh   # sign with a real certificate
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
BUNDLE_ADB=0
ARCHS=(--arch arm64 --arch x86_64)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-adb) BUNDLE_ADB=1 ;;
    --arch) ARCHS=(--arch "$2"); shift ;;
    *) echo "unknown option $1"; exit 1 ;;
  esac
  shift
done

echo "==> Building release binary (${ARCHS[*]})"
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/AndroBridge"

APP=dist/AndroBridge.app
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AndroBridge"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Drawing icon"
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

if [[ $BUNDLE_ADB == 1 ]]; then
  ADB="$(command -v adb || true)"
  [[ -z "$ADB" && -x "$HOME/Library/Android/sdk/platform-tools/adb" ]] && ADB="$HOME/Library/Android/sdk/platform-tools/adb"
  [[ -z "$ADB" ]] && { echo "adb not found; install android-platform-tools first"; exit 1; }
  PT="$(cd "$(dirname "$(readlink -f "$ADB")")" && pwd)"
  echo "==> Bundling adb from $PT (see README licensing note)"
  mkdir -p "$APP/Contents/Resources/platform-tools"
  cp "$PT/adb" "$APP/Contents/Resources/platform-tools/"
  [[ -d "$PT/lib64" ]] && cp -R "$PT/lib64" "$APP/Contents/Resources/platform-tools/"
  [[ -f "$PT/NOTICE.txt" ]] && cp "$PT/NOTICE.txt" "$APP/Contents/Resources/platform-tools/"
fi

echo "==> Signing"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  # Ad-hoc signature: required to run on Apple Silicon. NOT notarized.
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"

echo "==> Creating DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="dist/AndroBridge-$VERSION.dmg"
hdiutil create -volname "AndroBridge $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
(cd dist && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")

echo
echo "Built: $APP"
echo "       $DMG"
lipo -archs "$APP/Contents/MacOS/AndroBridge"
