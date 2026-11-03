#!/bin/sh
# Vulture — a free, open-source cleaner and disk tool for macOS.
# Copyright (C) 2026 Vulture contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds a release: build/release/Vulture-VERSION.zip and .dmg, plus checksums.
#   scripts/release.sh 1.0.0
#
# Signing and notarization happen when these are set; otherwise the app is signed ad hoc,
# which can't update itself.
#   VULTURE_SIGN_IDENTITY   the signing certificate: Vulture's own release certificate, or later a
#                           "Developer ID Application: Your Name (TEAMID)"
#   VULTURE_NOTARY_PROFILE  a profile saved with: xcrun notarytool store-credentials (Developer ID only)
#   VULTURE_DOWNLOAD_BASE   where update.json says the zip is (default: this version's GitHub release)
set -eu
cd "$(dirname "$0")/.."
version="${1:?usage: scripts/release.sh VERSION}"
build="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
out="build/release"

scripts/make-app.sh release "$version" "$build"
app="build/Vulture.app"

identity="${VULTURE_SIGN_IDENTITY:--}"
if [ "$identity" = "-" ]; then
  echo "No VULTURE_SIGN_IDENTITY: signing ad hoc (not for public download)." >&2
  sign_flags=""
elif [ -n "${VULTURE_NOTARY_PROFILE:-}" ]; then
  sign_flags="--options runtime --timestamp"
else
  sign_flags=""
fi
# Inside out: the command-line tool, then the app.
# shellcheck disable=SC2086
codesign --force $sign_flags --sign "$identity" "$app/Contents/Helpers/vulture"
# shellcheck disable=SC2086
codesign --force $sign_flags --sign "$identity" "$app"
codesign --verify --strict --verbose=2 "$app"

rm -rf "$out" && mkdir -p "$out"
zip="$out/Vulture-$version.zip"
ditto -c -k --keepParent "$app" "$zip"

if [ -n "${VULTURE_NOTARY_PROFILE:-}" ] && [ "$identity" != "-" ]; then
  xcrun notarytool submit "$zip" --keychain-profile "$VULTURE_NOTARY_PROFILE" --wait
  xcrun stapler staple "$app"
  rm "$zip" && ditto -c -k --keepParent "$app" "$zip"
else
  echo "Not notarized." >&2
fi

dmg="$out/Vulture-$version.dmg"
staging="build/dmg"
rm -rf "$staging" && mkdir -p "$staging"
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname "Vulture $version" -srcfolder "$staging" -ov -format UDZO "$dmg"
if [ "$identity" != "-" ]; then codesign --force --sign "$identity" "$dmg"; fi

# What the app's updater reads from the latest release.
zip_sha="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
zip_size="$(stat -f %z "$zip")"
repo="https://github.com/alsaadii98/vulture"
base_url="${VULTURE_DOWNLOAD_BASE:-$repo/releases/download/v$version}"
cat > "$out/update.json" <<JSON
{
  "version": "$version",
  "url": "$base_url/Vulture-$version.zip",
  "sha256": "$zip_sha",
  "size": $zip_size,
  "minimumSystemVersion": "14.0",
  "notesURL": "$repo/releases/tag/v$version"
}
JSON

(cd "$out" && shasum -a 256 ./*.zip ./*.dmg > SHA256SUMS)
cat "$out/SHA256SUMS"
