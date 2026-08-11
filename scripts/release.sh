#!/usr/bin/env bash
# Rebuilds both apps into dist/. Run this whenever a feature changes, so the
# committed dist/Ecosystem.dmg and dist/Ecosystem.apk stay current.
set -euo pipefail

cd "$(dirname "$0")/.."
scripts/package-dmg.sh
scripts/build-apk.sh "${1:-debug}"

echo
echo "dist/ is up to date:"
ls -lh dist/Ecosystem.dmg dist/Ecosystem.apk | awk '{print "  " $NF, "(" $5 ")"}'
