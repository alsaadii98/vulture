# Vulture — a free, open-source cleaner and disk tool for macOS.
# Copyright (C) 2026 Vulture contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Cask for the project's own tap (github.com/alsaadii98/homebrew-vulture):
#   brew install alsaadii98/vulture/vulture
# The release workflow fills in version and sha256.
cask "vulture" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/alsaadii98/vulture/releases/download/v#{version}/Vulture-#{version}.zip"
  name "Vulture"
  desc "Free, open-source cleaner and disk tool that explains every file"
  homepage "https://github.com/alsaadii98/vulture"

  depends_on macos: ">= :sonoma"

  app "Vulture.app"
  binary "#{appdir}/Vulture.app/Contents/Helpers/vulture"

  zap trash: [
    "~/Library/Application Support/Vulture",
    "~/Library/Preferences/io.github.alsaadii98.Vulture.plist",
  ]
end
