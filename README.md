# Vulture

See what's filling up your Mac, and free up space without the worry.

Vulture is a free, open-source cleaner and disk tool for macOS. It explains every file it offers to remove in plain words, never touches your documents, photos or messages, and keeps everything it removes in Recently Removed for 30 days.

> **Status:** early development (phase 4). The engine, the `vulture` command-line tool and the Mac app work: Home, Clean Up, Apps, Storage (with a weekly history), Startup, Recently Removed, Developer Files and an optional menu bar monitor. Releases aren't signed or notarized yet.

## Try it

Requires macOS 14 or later and Xcode 16 or later.

```sh
scripts/make-app.sh && open build/Vulture.app   # the Mac app
swift build -c release
.build/release/vulture scan          # what could be cleaned, and why
.build/release/vulture clean         # clean up the recommended items (asks first)
.build/release/vulture removed       # what's in Recently Removed
.build/release/vulture restore ID    # put a clean-up back
.build/release/vulture storage       # what kinds of things use your disk
.build/release/vulture dev           # simulators, Docker and old projects
.build/release/vulture projects      # build folders in projects untouched for 90 days
.build/release/vulture apps          # apps, largest first, with when each was last used
.build/release/vulture uninstall Figma   # remove an app and what it keeps (undoable)
.build/release/vulture leftovers     # files left by apps that are already gone
.build/release/vulture startup       # what starts by itself
.build/release/vulture history       # what changed on your disk this week
.build/release/vulture size ~        # what's using space in a folder
.build/release/vulture scan --json   # the same, for scripts and AI agents
```

**What cleaning does:** files apps make again on their own (caches, build files, downloaded packages) are removed right away, so you get the space now. Anything that can't come back by itself (installers, old downloads, archives) goes to **Recently Removed** for 30 days and can be put back exactly where it was. Before anything is touched, Vulture checks again that it's still the same item, that no app using it is open, and that nothing protected is involved.

For complete results, give your terminal **Full Disk Access** in System Settings › Privacy & Security. Without it, Vulture skips folders that hold other apps' private data rather than triggering a permission prompt.

## Releases

`scripts/release.sh VERSION` builds a universal `Vulture.app` (with the `vulture` tool in `Contents/Helpers`), a zip, a DMG and checksums in `build/release`. Pushing a `vX.Y.Z` tag does the same on GitHub and publishes a release. With a Developer ID certificate in the repository secrets (see `.github/workflows/release.yml`), the release is signed and notarized; without one it's published as a pre-release that macOS will warn about. A Homebrew cask for the project's tap is in `packaging/homebrew`.

## How it decides what's safe

- **Rules, not guesses.** Every kind of removable file is described by a rule in [`Sources/VultureCore/Rules`](Sources/VultureCore/Rules), with a plain-language title and explanation. See [docs/rules.md](docs/rules.md).
- **Hard limits no rule can override.** Your Documents, Desktop, Photos, Messages, Mail, iCloud Drive, keychains, SSH keys and AI assistants' chats are never offered. Neither is anything reached through a symbolic link.
- **Open apps are left alone.** Files that belong to an app that's running, or that any app has open, are skipped.
- **Honest about caches that come back.** If a folder fills up again within two days of cleaning, Vulture stops recommending it and says so.

## Project layout

| Path | What's there |
|---|---|
| `Sources/VultureCore` | The engine: scanner, rules, safety checks, cleanup planner. No UI. |
| `Sources/VultureCore/Rules` | The cleaning rules, as JSON |
| `Sources/vulture` | The command-line tool |
| `Tests/VultureCoreTests` | Tests that build throwaway folders; they never touch your real files |

## Contributing

Vulture is written from scratch. Please don't copy code, comments, tests or file lists from other cleaners, open source or not; describe what a folder is from the app's own documentation or your own testing.

New files start with:

```swift
// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later
```

Run `swift test` and `vulture check-rules Sources/VultureCore/Rules` before sending a change.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE). The Vulture name and logo are covered by [TRADEMARK.md](TRADEMARK.md): forks must use their own name.
