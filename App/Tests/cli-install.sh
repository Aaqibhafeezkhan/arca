#!/bin/bash
# End-to-end check against a built app, without installing into system directories.
set -euo pipefail

APP="$(cd "${1:?Usage: cli-install.sh /path/to/Arca.app}" && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/arca-cli-test.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

# Exercise spaces in the app and installation paths, as well as execution
# outside the checkout. Copying also checks that no build products are needed.
mkdir -p "$WORK/Applications with spaces" "$WORK/bin with spaces"
ditto "$APP" "$WORK/Applications with spaces/Arca.app"
APP="$WORK/Applications with spaces/Arca.app"
INSTALLER="$APP/Contents/Resources/install-cli.sh"
BIN_DIR="$WORK/bin with spaces"
"$INSTALLER" "$BIN_DIR"
"$INSTALLER" "$BIN_DIR"
test "$(readlink "$BIN_DIR/arca")" = "$APP/Contents/MacOS/arca-cli"

export PATH="$BIN_DIR:/usr/bin:/bin"
unset ARCA_7ZZ
cd "$WORK"
arca --version
printf 'Hello from the installed CLI\n' > hello.txt
arca create example.zip hello.txt
arca list example.zip | /usr/bin/grep -q 'hello.txt'
arca cat example.zip hello.txt > actual.txt
cmp hello.txt actual.txt
arca extract example.zip extracted
cmp hello.txt extracted/hello.txt

# The symlinked CLI must still find the app's bundled 7-Zip.
arca create example.7z hello.txt
arca cat example.7z hello.txt > actual.txt
cmp hello.txt actual.txt

mkdir conflict
printf 'Existing command\n' > conflict/arca
if "$INSTALLER" "$WORK/conflict"; then
  echo 'Installer unexpectedly overwrote an existing command' >&2
  exit 1
fi
test "$(cat conflict/arca)" = 'Existing command'
rm conflict/arca
ln -s "$WORK/missing-command" conflict/arca
if "$INSTALLER" "$WORK/conflict"; then
  echo 'Installer unexpectedly overwrote an unrelated symlink' >&2
  exit 1
fi
test "$(readlink conflict/arca)" = "$WORK/missing-command"
echo 'PASS: bundled CLI installs safely and works outside the checkout'
