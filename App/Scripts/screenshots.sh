#!/bin/bash
# Captures the README screenshots from a built Arca.app with demo archives.
# Needs a logged-in GUI session with screen-recording permission (CI macOS runners have both).
# Usage: screenshots.sh <Arca.app> <output-dir>
set -euo pipefail
APP="$(cd "$1" && pwd)"
OUT="$(mkdir -p "$2" && cd "$2" && pwd)"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'pkill -x Arca || true; rm -rf "$WORK"' EXIT

# --- Demo archives -----------------------------------------------------------
KIT="$WORK/Brand Kit"
mkdir -p "$KIT/Photos" "$KIT/Logos" "$KIT/Documents" "$KIT/Colors"
i=0
while IFS= read -r -d '' picture; do
  name="$(basename "${picture%.*}")"
  sips -s format jpeg -s formatOptions 82 -Z 2400 "$picture" --out "$KIT/Photos/$name.jpg" >/dev/null 2>&1 || continue
  i=$((i + 1)); [ $i -ge 6 ] && break
done < <(find "/System/Library/Desktop Pictures" "/Library/Desktop Pictures" -maxdepth 1 \
           \( -name '*.heic' -o -name '*.jpg' -o -name '*.png' \) -print0 2>/dev/null | sort -z)
ICONS="$ROOT/App/Arca/Assets.xcassets/AppIcon.appiconset"
cp "$ICONS/icon_512x512@2x.png" "$KIT/Logos/Arca Icon.png"
cp "$ICONS/icon_128x128.png" "$KIT/Logos/Arca Icon Small.png"
cat > "$KIT/README.md" <<'MD'
# Brand Kit

Photos, logos and the copy deck for the autumn campaign.
Edit anything in place — Arca writes your changes straight back into this archive.
MD
printf 'Campaign copy deck\n\nHeadline: Open anything. Change everything.\n' > "$WORK/copy.txt"
textutil -convert docx "$WORK/copy.txt" -output "$KIT/Documents/Copy Deck.docx"
textutil -convert rtf "$WORK/copy.txt" -output "$KIT/Documents/Press Release.rtf"
cat > "$KIT/Colors/palette.json" <<'JSON'
{ "primary": "#F29E3D", "secondary": "#E3542F", "ink": "#1C1C1E", "paper": "#FAFAF7" }
JSON
(cd "$KIT" && zip -qrX "$WORK/Brand Kit.zip" .)
PHOTO="$(cd "$KIT" && ls Photos | head -1)"

(cd "$ROOT" && "$APP/Contents/MacOS/7zz" a -bso0 -bsp0 "$WORK/arca-source.7z" Sources/ArcaKit Sources/arca App/Arca App/QuickLook README.md)

# --- Capture -----------------------------------------------------------------
cat > "$WORK/windowid.swift" <<'SWIFT'
import CoreGraphics
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let arca = windows.filter { $0[kCGWindowOwnerName as String] as? String == "Arca" && $0[kCGWindowLayer as String] as? Int == 0 }
func area(_ w: [String: Any]) -> Double {
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (b["Width"] ?? 0) * (b["Height"] ?? 0)
}
if let window = arca.max(by: { area($0) < area($1) }), let id = window[kCGWindowNumber as String] as? Int { print(id) }
SWIFT
swiftc -O "$WORK/windowid.swift" -o "$WORK/windowid"

shoot() {  # name appearance [archive reveal-path]
  local name=$1 appearance=$2 file=${3:-} reveal=${4:-}
  pkill -x Arca || true
  sleep 1
  local args=(-ApplePersistenceIgnoreState YES -AppleInterfaceStyle "$appearance")
  [ -n "$reveal" ] && args+=(-ArcaReveal "$reveal")
  if [ -n "$file" ]; then open -F -a "$APP" "$file" --args "${args[@]}"; else open -F -a "$APP" --args "${args[@]}"; fi
  sleep 8
  open -a "$APP"   # bring to front so the window draws as active
  sleep 2
  local id; id="$("$WORK/windowid")"
  [ -n "$id" ] || { echo "no Arca window for $name" >&2; return 1; }
  screencapture -x -l "$id" "$OUT/$name.png"
  echo "→ $OUT/$name.png"
}

shoot browser Light "$WORK/Brand Kit.zip" "Photos/$PHOTO"
shoot browser-dark Dark "$WORK/arca-source.7z" "Sources/ArcaKit/Archive.swift"
shoot welcome Light   # recents now list the two archives above
