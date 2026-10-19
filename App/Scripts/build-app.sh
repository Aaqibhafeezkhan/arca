#!/bin/bash
# Builds a Release Arca.app (universal) into <output-dir>.
# Signs ad hoc unless SIGN_IDENTITY is set (e.g. "Developer ID Application: …").
# Usage: build-app.sh <output-dir>
set -euo pipefail
OUT="$(mkdir -p "$1" && cd "$1" && pwd)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${SIGN_IDENTITY:--}"

cd "$ROOT"
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen --quiet
xcodebuild -project Arca.xcodeproj -scheme Arca -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$ROOT/build/DerivedData" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}" \
  build -quiet
rm -rf "$OUT/Arca.app"
ditto "$ROOT/build/DerivedData/Build/Products/Release/Arca.app" "$OUT/Arca.app"
codesign --verify --deep --strict "$OUT/Arca.app"
echo "→ $OUT/Arca.app ($(defaults read "$OUT/Arca.app/Contents/Info" CFBundleShortVersionString))"
