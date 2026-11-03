#!/bin/sh
# Vulture — a free, open-source cleaner and disk tool for macOS.
# Copyright (C) 2026 Vulture contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds a release: build/release/Vulture-VERSION.zip and .dmg, plus checksums.
#   scripts/release.sh 1.0.0
#
# Signing and notarization happen when these are set; otherwise the app is signed ad hoc,
# which runs on the Mac that built it but makes Gatekeeper warn everywhere else.
#   VULTURE_SIGN_IDENTITY   "Developer ID Application: Your Name (TEAMID)"
#   VULTURE_NOTARY_PROFILE  a profile saved with: xcrun notarytool store-credentials
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
else
  sign_flags="--options runtime --timestamp"
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

(cd "$out" && shasum -a 256 ./*.zip ./*.dmg > SHA256SUMS)
cat "$out/SHA256SUMS"
