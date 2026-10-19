#!/bin/sh
# Downloads the pinned, checksum-verified 7-Zip console binary (universal).
# Usage: fetch-7zz.sh [destination-dir]   (default: App/Vendor)
set -eu
VERSION="26.04"
ARCHIVE="7z2604-mac.tar.xz"
SHA256="bee04358cbcbc7106273cee0e8d72916db2696c48067a3538c34d8cd6fd16578"

DEST="${1:-$(cd "$(dirname "$0")/.." && pwd)/Vendor}"
mkdir -p "$DEST"
if [ -x "$DEST/7zz" ] && [ "$(cat "$DEST/.7zz-version" 2>/dev/null)" = "$VERSION" ]; then
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL --retry 3 -o "$TMP/$ARCHIVE" "https://github.com/ip7z/7zip/releases/download/$VERSION/$ARCHIVE"
echo "$SHA256  $TMP/$ARCHIVE" | shasum -a 256 -c - >/dev/null
tar -xJf "$TMP/$ARCHIVE" -C "$TMP" 7zz License.txt
mv "$TMP/7zz" "$DEST/7zz"
mv "$TMP/License.txt" "$DEST/7-Zip License.txt"
chmod 755 "$DEST/7zz"
echo "$VERSION" > "$DEST/.7zz-version"
echo "7-Zip $VERSION → $DEST/7zz"
