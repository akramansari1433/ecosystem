#!/usr/bin/env bash
# Builds the Android app and copies the APK to dist/Ecosystem.apk.
# Usage: scripts/build-apk.sh [debug|release]   (default: debug)
set -euo pipefail

VARIANT="${1:-debug}"
cd "$(dirname "$0")/../android-app"
ROOT="$(cd .. && pwd)"

: "${JAVA_HOME:=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
export JAVA_HOME
[ -x "$JAVA_HOME/bin/java" ] || { echo "JDK 21 not found at JAVA_HOME=$JAVA_HOME"; exit 1; }

case "$VARIANT" in
  debug)   TASK=assembleDebug;   OUT=app/build/outputs/apk/debug/app-debug.apk ;;
  release) TASK=assembleRelease; OUT=app/build/outputs/apk/release/app-release-unsigned.apk ;;
  *) echo "usage: $0 [debug|release]"; exit 1 ;;
esac

echo "==> ./gradlew $TASK"
./gradlew "$TASK"

mkdir -p "$ROOT/dist"
cp "$OUT" "$ROOT/dist/Ecosystem.apk"
echo "Done: $ROOT/dist/Ecosystem.apk"
