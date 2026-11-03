#!/bin/sh
# Vulture — a free, open-source cleaner and disk tool for macOS.
# Copyright (C) 2026 Vulture contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds build/Vulture.app with the `vulture` command-line tool inside it.
#   scripts/make-app.sh                 debug build for this Mac
#   scripts/make-app.sh release 1.0.0   release build for Apple silicon and Intel
set -eu
cd "$(dirname "$0")/.."
config="${1:-debug}"
version="${2:-0.0.0-dev}"
build="${3:-1}"

if [ "$config" = release ]; then
  arch_flags="--arch arm64 --arch x86_64"
else
  arch_flags=""
fi
# shellcheck disable=SC2086
swift build -c "$config" $arch_flags --product VultureApp
# shellcheck disable=SC2086
swift build -c "$config" $arch_flags --product vulture
# shellcheck disable=SC2086
bin="$(swift build -c "$config" $arch_flags --show-bin-path)"

app="build/Vulture.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Helpers"
cp "$bin/VultureApp" "$app/Contents/MacOS/Vulture"
cp -R "$bin/Vulture_VultureCore.bundle" "$app/Contents/Resources/"
# The command-line tool finds its rules in Contents/Resources.
cp "$bin/vulture" "$app/Contents/Helpers/vulture"

# SwiftPM records the deployment target as the SDK version, which makes macOS treat Vulture as an
# old app and turn off Liquid Glass. Record the SDK it was really built with.
sdk="$(xcrun --sdk macosx --show-sdk-version)"
for binary in "$app/Contents/MacOS/Vulture" "$app/Contents/Helpers/vulture"; do
  vtool -set-build-version macos 14.0 "$sdk" -replace -output "$binary" "$binary"
done

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
  <key>CFBundleIdentifier</key><string>io.github.alsaadii98.Vulture</string>
  <key>CFBundleName</key><string>Vulture</string>
  <key>CFBundleDisplayName</key><string>Vulture</string>
  <key>CFBundleExecutable</key><string>Vulture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>Free and open source under GPL-3.0</string>
</dict>
</plist>
PLIST
# Sign ad hoc so it runs; release.sh signs again with the release certificate.
codesign --force --sign - "$app/Contents/Helpers/vulture"
codesign --force --sign - "$app"
echo "$app"
