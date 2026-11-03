#!/bin/sh
# Vulture — a free, open-source cleaner and disk tool for macOS.
# Copyright (C) 2026 Vulture contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Wraps the SwiftUI app target in a minimal .app bundle for local testing.
# Release packaging (signing, notarization, app icon) comes later.
set -eu
cd "$(dirname "$0")/.."
config="${1:-debug}"
swift build -c "$config" --product VultureApp
bin="$(swift build -c "$config" --show-bin-path)"
app="build/Vulture.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/VultureApp" "$app/Contents/MacOS/Vulture"
cp -R "$bin/Vulture_VultureCore.bundle" "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.vulture.Vulture</string>
  <key>CFBundleName</key><string>Vulture</string>
  <key>CFBundleDisplayName</key><string>Vulture</string>
  <key>CFBundleExecutable</key><string>Vulture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHumanReadableCopyright</key><string>Free and open source under GPL-3.0</string>
</dict>
</plist>
PLIST
echo "$app"
