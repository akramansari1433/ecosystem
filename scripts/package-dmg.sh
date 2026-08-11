#!/usr/bin/env bash
# Builds Ecosystem.app in Release and packages it as dist/Ecosystem.dmg.
set -euo pipefail

cd "$(dirname "$0")/../mac-app"
ROOT="$(cd .. && pwd)"
DIST="$ROOT/dist"
BUILD="$ROOT/build/mac"
STAGE="$BUILD/dmg"

command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen"; exit 1; }

echo "==> Generating Xcode project"
xcodegen >/dev/null

echo "==> Building Release"
xcodebuild -project Ecosystem.xcodeproj -scheme Ecosystem \
  -configuration Release -derivedDataPath "$BUILD/DerivedData" \
  build >/dev/null

APP="$BUILD/DerivedData/Build/Products/Release/Ecosystem.app"
[ -d "$APP" ] || { echo "build produced no app at $APP"; exit 1; }

echo "==> Staging disk image"
rm -rf "$STAGE" "$DIST/Ecosystem.dmg"
mkdir -p "$STAGE" "$DIST"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating dist/Ecosystem.dmg"
hdiutil create -volname "Ecosystem" -srcfolder "$STAGE" -ov -format UDZO \
  "$DIST/Ecosystem.dmg" >/dev/null
rm -rf "$STAGE"

echo "Done: $DIST/Ecosystem.dmg"
