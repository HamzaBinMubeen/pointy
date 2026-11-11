#!/bin/bash
# Package Pointy as a drag-to-install disk image for sharing:
#   build/Pointy-<version>.dmg
#
# It holds the universal app, an Applications shortcut to drag it onto, and
# "How to open.txt". Until the app is signed with a Developer ID and notarised
# (paid Apple Developer membership), macOS blocks it on first open; the text
# file walks people through Privacy & Security › Open Anyway.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-app.sh"

VERSION="$(plutil -extract CFBundleShortVersionString raw "$ROOT/build/Pointy.app/Contents/Info.plist")"
STAGE="$(mktemp -d)"
DMG="$ROOT/build/Pointy-$VERSION.dmg"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$ROOT/build/Pointy.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/How to open.txt" <<'TXT'
Pointy — install

1. Drag "Pointy" onto the Applications folder.
2. Open it from Applications.

macOS will say it "can't be opened because Apple cannot check it for malicious
software". That is because this early build isn't notarised by Apple yet. To open it:

3. Click "Done" on that message.
4. Open System Settings › Privacy & Security, scroll down, and click
   "Open Anyway" next to Pointy. Confirm with your password or Touch ID.

You only do this once. After that, Pointy lives in your menu bar and walks
you through the rest: the browser extension, the microphone, and /ui for Claude Code.

Needs macOS 14 or later. On-device speech needs macOS 26.
TXT

rm -f "$DMG"
hdiutil create -volname "Pointy $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
echo "made $DMG ($(du -h "$DMG" | cut -f1))"
