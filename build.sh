#!/bin/bash
# Builds Codex Switch.app — a menu bar app for switching Codex accounts.
# Requires: Xcode command line tools (swiftc), iconutil. No Xcode project needed.
set -euo pipefail
cd "$(dirname "$0")"

APP="Codex Switch.app"
EXEC_NAME="CodexSwitch"
MIN_MACOS="13.0"

echo "› Generating icons…"
swift tools/icons.swift Resources build/AppIcon.iconset .github >/dev/null
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

echo "› Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/menubar.png Resources/menubar@2x.png "$APP/Contents/Resources/"

echo "› Compiling Swift…"
ARCH="$(uname -m)"
swiftc -O \
    -swift-version 5 \
    -target "${ARCH}-apple-macos${MIN_MACOS}" \
    -framework AppKit -framework SwiftUI \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/${EXEC_NAME}"

# Ad-hoc code signature so macOS will launch it locally without Gatekeeper complaints.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "✓ Built $(pwd)/$APP"
