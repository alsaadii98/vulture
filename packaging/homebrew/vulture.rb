# Vulture — a free, open-source cleaner and disk tool for macOS.
# Copyright (C) 2026 Vulture contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Cask for the project's tap, github.com/alsaadii98/homebrew-vulture:
#   brew install --cask alsaadii98/vulture/vulture
# The release workflow fills in version and sha256 and pushes this file to the tap.
cask "vulture" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/alsaadii98/vulture/releases/download/v#{version}/Vulture-#{version}.zip"
  name "Vulture"
  desc "Free, open-source cleaner and disk tool that explains every file"
  homepage "https://github.com/alsaadii98/vulture"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Vulture checks for new versions itself and asks before installing them.
  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Vulture.app"
  binary "#{appdir}/Vulture.app/Contents/Helpers/vulture"

  caveats <<~EOS
    Vulture isn't notarized by Apple yet. The first time you open it, macOS says it can't check it:
    open System Settings > Privacy & Security and click "Open Anyway". Later updates don't ask again.
  EOS

  zap trash: [
    "~/Library/Application Support/Vulture",
    "~/Library/Preferences/io.github.alsaadii98.Vulture.plist",
  ]
end
