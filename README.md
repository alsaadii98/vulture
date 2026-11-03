# Vulture

See what's filling up your Mac, and free up space without the worry.

Vulture is a free, open-source cleaner and disk tool for macOS. It explains every file it offers to remove in plain words, never touches your documents, photos or messages, and keeps everything it removes in Recently Removed for 30 days.

> **Status:** early development (phase 2). The engine, the `vulture` command-line tool and the Mac app (Home, Clean Up, Storage, Recently Removed) work. Apps and Startup come next.

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
.build/release/vulture size ~        # what's using space in a folder
.build/release/vulture scan --json   # the same, for scripts and AI agents
```

**What cleaning does:** files apps make again on their own (caches, build files, downloaded packages) are removed right away, so you get the space now. Anything that can't come back by itself (installers, old downloads, archives) goes to **Recently Removed** for 30 days and can be put back exactly where it was. Before anything is touched, Vulture checks again that it's still the same item, that no app using it is open, and that nothing protected is involved.

For complete results, give your terminal **Full Disk Access** in System Settings › Privacy & Security. Without it, Vulture skips folders that hold other apps' private data rather than triggering a permission prompt.

## How it decides what's safe

- **Rules, not guesses.** Every kind of removable file is described by a rule in [`Sources/VultureCore/Rules`](Sources/VultureCore/Rules), with a plain-language title and explanation. See [docs/rules.md](docs/rules.md).
- **Hard limits no rule can override.** Your Documents, Desktop, Photos, Messages, Mail, iCloud Drive, keychains, SSH keys and AI assistants' chats are never offered. Neither is anything reached through a symbolic link.
- **Open apps are left alone.** Files that belong to an app that's running are skipped until it's closed.

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
