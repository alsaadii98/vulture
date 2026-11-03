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

# App icon from the 1024 px master
iconset="build/AppIcon.iconset"
rm -rf "$iconset" && mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size Assets/AppIcon-1024.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double Assets/AppIcon-1024.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
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
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHumanReadableCopyright</key><string>Free and open source under GPL-3.0</string>
</dict>
</plist>
PLIST
echo "$app"
