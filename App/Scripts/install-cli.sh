#!/bin/bash
# Installs the CLI bundled with Arca.app into a directory on PATH.
# Usage: sudo /Applications/Arca.app/Contents/Resources/install-cli.sh [bin-dir]
set -euo pipefail

RESOURCES="$(cd "$(dirname "$0")" && pwd -P)"
CLI="$RESOURCES/../MacOS/arca-cli"
BIN_DIR="${1:-/usr/local/bin}"

if [ "$#" -gt 1 ]; then
  echo "Usage: $0 [bin-dir]" >&2
  exit 1
fi
if [ ! -x "$CLI" ]; then
  echo "Run this installer from inside Arca.app/Contents/Resources." >&2
  exit 1
fi
CLI="$(cd "$RESOURCES/../MacOS" && pwd -P)/arca-cli"
mkdir -p "$BIN_DIR"
BIN_DIR="$(cd "$BIN_DIR" && pwd -P)"
LINK="$BIN_DIR/arca"

if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$CLI" ]; then
  echo "Already installed: $LINK"
elif [ -e "$LINK" ] || [ -L "$LINK" ]; then
  echo "$LINK already exists. Move or remove it before installing Arca's CLI." >&2
  exit 1
else
  ln -s "$CLI" "$LINK"
  echo "Installed: $LINK → $CLI"
fi

echo "Try: arca --version"
case ":${PATH:-}:" in
  *":$BIN_DIR:"*) ;;
  *) echo "Add $BIN_DIR to your shell's PATH to use arca from any directory." ;;
esac
