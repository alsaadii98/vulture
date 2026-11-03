#!/bin/sh
# Vulture — a free, open-source cleaner and disk tool for macOS.
# Copyright (C) 2026 Vulture contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Checks that an older Vulture updates itself to the release in ZIP, and refuses a copy signed by anyone else.
#   scripts/test-update.sh build/release/Vulture-1.0.0.zip "Vulture Release Signing"
# With IDENTITY "-" (ad hoc, debug builds only) set VULTURE_UPDATE_REQUIREMENT, and the refusal check is skipped.
set -eu
zip="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
identity="${2:--}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

feed() { # feed ZIP VERSION > update.json
  printf '{"version":"%s","url":"file://%s","sha256":"%s","size":%s,"minimumSystemVersion":"14.0"}\n' \
    "$2" "$1" "$(shasum -a 256 "$1" | cut -d' ' -f1)" "$(stat -f %z "$1")"
}
version_of() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist"; }

mkdir "$work/new" "$work/installed"
ditto -x -k "$zip" "$work/new"
new_version="$(version_of "$work/new/Vulture.app")"

# An "older" copy: the same app, signed the same way, claiming version 0.0.1.
make_old() {
  rm -rf "$work/installed/Vulture.app"
  cp -R "$work/new/Vulture.app" "$work/installed/"
  plutil -replace CFBundleShortVersionString -string 0.0.1 "$work/installed/Vulture.app/Contents/Info.plist"
  codesign --force --sign "$identity" "$work/installed/Vulture.app"
}
old="$work/installed/Vulture.app"

if [ "$identity" != "-" ]; then
  echo "== A copy signed by someone else is refused"
  make_old
  mkdir "$work/fake"
  cp -R "$work/new/Vulture.app" "$work/fake/"
  codesign --force --deep --sign - "$work/fake/Vulture.app"
  ditto -c -k --keepParent "$work/fake/Vulture.app" "$work/fake.zip"
  feed "$work/fake.zip" "$new_version" > "$work/fake.json"
  if "$old/Contents/Helpers/vulture" update --feed "$work/fake.json" --yes; then
    echo "FAIL: accepted an update signed by someone else" >&2; exit 1
  fi
  [ "$(version_of "$old")" = 0.0.1 ] || { echo "FAIL: installed copy changed" >&2; exit 1; }
fi

echo "== A damaged download is refused"
make_old
cp "$zip" "$work/damaged.zip"
printf 'x' >> "$work/damaged.zip"
feed "$zip" "$new_version" | sed "s|file://$zip|file://$work/damaged.zip|" > "$work/damaged.json"
if "$old/Contents/Helpers/vulture" update --feed "$work/damaged.json" --yes; then
  echo "FAIL: accepted a damaged download" >&2; exit 1
fi

echo "== The real release is installed"
make_old
feed "$zip" "$new_version" > "$work/update.json"
"$old/Contents/Helpers/vulture" update --check --feed "$work/update.json"
"$old/Contents/Helpers/vulture" update --feed "$work/update.json" --yes
[ "$(version_of "$old")" = "$new_version" ] || { echo "FAIL: still $(version_of "$old")" >&2; exit 1; }
codesign --verify --strict "$old"
"$old/Contents/Helpers/vulture" update --check --feed "$work/update.json"
echo "Update test passed: 0.0.1 -> $new_version"
