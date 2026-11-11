#!/bin/bash
# Build "Pointy.app" into build/. The app carries its own copy of the
# extension, the brief compiler and the /ui command, so the extension version
# is the app version: bump extension/manifest.json and rebuild.
#
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --install  also copy to /Applications and relaunch
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Pointy.app"
VERSION="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/extension/manifest.json")"

# Universal: one app for Intel and Apple silicon Macs.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release --package-path "$ROOT/app" "${ARCHS[@]}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --package-path "$ROOT/app" "${ARCHS[@]}" --show-bin-path)/Pointy" "$APP/Contents/MacOS/Pointy"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
cp -R "$ROOT/extension" "$APP/Contents/Resources/extension"
cp "$ROOT/server/brief.cjs" "$APP/Contents/Resources/brief.cjs"
cp "$ROOT/claude-command/ui.md" "$APP/Contents/Resources/ui.md"
# The mascot is the logo; scripts/make-icons.swift draws these.
cp "$ROOT/app/AppIcon.icns" "$ROOT/app/MenuIcon.png" "$ROOT/app/MenuIcon@2x.png" "$APP/Contents/Resources/"

# Signing decides whether macOS keeps the microphone grant across rebuilds: it
# ties the grant to the signature's identity. An "Apple Development" certificate
# (free: add any Apple ID in Xcode › Settings › Accounts) is one identity for
# every build. Without it the build is signed ad-hoc, macOS treats each rebuild
# as a new app, and the mic has to be switched off and on again in System
# Settings after every build. Sharing the app with others needs a paid
# Developer ID and notarisation on top of this.
IDENTITY="${POINTY_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}"
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "signed with $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "signed ad-hoc: no Apple Development certificate (the mic grant will reset on each build)"
fi
echo "built $APP ($VERSION)"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Pointy || true
  rm -rf "/Applications/Pointy.app"
  cp -R "$APP" "/Applications/Pointy.app"
  open "/Applications/Pointy.app"
  echo "installed /Applications/Pointy.app"
fi
