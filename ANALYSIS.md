# Mole → Native macOS App: Analysis

Source analyzed: https://github.com/tw93/mole @ `a528763` (2026-10-29), shallow clone.

---

## 0. Strategic findings (read first)

1. **The author already ships a native app.** "Mole for Mac" (https://mole.fit) is a separate Swift implementation: $19 one-time for 2 Macs, macOS 14+, **closed source**. It already has review-before-delete, a treemap, a menu bar HUD, an app updater, startup items, fan control and AI-cache cleanup.
   → An open-source native app competes head-on with the author's paid product. Our angle has to be **open source, auditable, and faster**, not "first GUI for Mole".
2. **Vulture is an independent app. Mole is a reference only.**
   - **Clean-room rule:** never copy Mole's code, comments, test files or curated lists (`app_protection_data.sh`, `lib/clean/*.sh`). Write every rule ourselves.
   - Public facts are fine to use: Apple docs, tool docs (`xcrun simctl`, `docker system df`), and paths we observe on our own Macs.
   - Each rule records its own source (doc URL or "observed on macOS 15").
   - Never use the "Mole" name or logo.
3. **License: GPL-3.0 (decided 2026-10-29)** + trademark policy (`LICENSE`, `TRADEMARK.md`). See §9.

---

## 1. Codebase map

~88k lines including tests.

| Part | Lang | LOC (approx) | Role |
|---|---|---|---|
| `mole` + `bin/*.sh` | Bash | ~9k | Entry point, subcommand routing, menus |
| `lib/clean/*.sh` | Bash | ~25k | Cleanup rules: `dev.sh` alone is 6k lines / 153 functions (Xcode, npm, pnpm, Go, Rust, Docker, JetBrains, AI agents…) |
| `lib/core/*.sh` | Bash | ~12k | Safety layer: `file_ops.sh` (4.2k) has path validation, `lsof` open-handle checks, sqlite-in-use detection, a Trash pipeline, and sudo bounding. `app_protection*.sh` (3.4k) has protected bundle IDs |
| `lib/uninstall`, `lib/optimize`, `lib/manage` | Bash | ~10k | Uninstaller with leftovers, maintenance tasks, self-update |
| `cmd/analyze` | Go + Bubble Tea | ~5k (+6k tests) | Disk analyzer TUI: concurrent `os.ReadDir` scanner, four semaphores, `du` fallback, APFS clone awareness, cache, oplog |
| `cmd/status` | Go + Bubble Tea | ~4k (+4k tests) | Live metrics via gopsutil plus **shell-outs**: `system_profiler`, `ioreg`, `pmset`, `powermetrics`, `diskutil`, `ps`, `uptime`, `osascript` |
| `tests/` | bats + Go | ~100 files | Heavy regression coverage. Good: many edge cases are already encoded as tests |

External tool calls across the shell code (approx counts):

| Tool | Calls |
|---|---|
| `sudo` | 239 |
| `find` | 166 |
| `brew` | 127 |
| `plutil` | 74 |
| `du` | 56 |
| `defaults` | 41 |
| `mdfind` | 28 |
| `lsof` | 26 |
| `osascript` | 24 |
| `tmutil` | 21 |
| `sqlite3` | 16 |

## 2. Strengths worth keeping

- **Safety knowledge is the real asset.** It's years of edge cases: in-use sqlite DBs, live app caches, shared browser profiles, Trash top-level protection, symlink and identity re-checks before delete, and bounded sudo. Port this *knowledge*, not the Bash.
- **Dry-run, whitelist and history** (`mo history --json`): users praise these.
- **Breadth of dev and AI caches:** Xcode (DerivedData, DeviceSupport, simulators), Docker, JetBrains, Claude/Codex/Cursor versions. Nobody else has this coverage.
- **APFS clone-aware sizing** in the analyzer (`clone_darwin.go`), which avoids double-counting.

## 3. Weaknesses and improvement opportunities

| # | Problem | Evidence in code | Native fix |
|---|---|---|---|
| 1 | **Rules are code, not data.** Each cache location is a Bash function, so it's hard to audit, share or extend | `lib/clean/dev.sh` (153 functions), `app_caches.sh`, `user.sh` (3.6k lines) | Declarative rule files (JSON/YAML/TOML): path glob, category, risk level, "safe because…", required-closed bundle ID, min age. Community PRs then add rules, not code |
| 2 | **Process spawn overhead.** Thousands of `find`/`stat`/`du`/`plutil`/`lsof` forks per scan | Frequency table in §1 | Swift `FileManager`/`fts`/`getattrlistbulk(2)`, `PropertyListDecoder`, `libproc` (`proc_pidinfo` replaces `lsof`), Launch Services for bundle lookups. Expect 10–50× faster scans |
| 3 | **Status shells out every tick** | `cmd/status/metrics_*.go` call `system_profiler`, `ioreg`, `pmset`, `powermetrics` (needs root) | `host_statistics64`, `IOKit` (IOPSCopyPowerSourcesInfo, SMC for temps/fans, IOReport for GPU/ANE power, no root), `sysctl`, `getifaddrs`. Near-zero CPU in the menu bar |
| 4 | **Analyzer falls back to `du`** and uses plain `ReadDir` + `Lstat` | `scanner.go:133-160, 848` | `getattrlistbulk` gives name, size, allocated size, type and inode in one syscall per batch. Persist the index and update it with **FSEvents** so re-scans are instant |
| 5 | **Permanent deletes in some paths.** Caused issue #823 (Claude memory loss) | `safe_remove` vs `_mole_move_to_trash` both exist | Default to `FileManager.trashItem`. Add an app-managed **quarantine** with one-click undo for N days, and permanent delete only as opt-in |
| 6 | **Bash fragility:** `unbound variable` crashes (#790, #866), bash 3.2 compatibility hacks, locale bugs (#1267) | Comments throughout `mole`, `metrics.go:cLocaleEnv` | A typed Swift core removes the whole class of bugs |
| 7 | **sudo everywhere** (239 calls) | `file_ops.sh: safe_sudo_remove`, `_mole_bounded_sudo` | One `SMAppService` privileged helper with a **narrow XPC API**: an allow-listed operation enum, code-signature check of the caller, no arbitrary commands. Pearcleaner's helper root-exec bug (#278) is the lesson |
| 8 | **Install trust:** `curl \| bash` is distrusted on HN | README | Signed and notarized `.dmg`, Homebrew cask, Sparkle updates with EdDSA signatures, reproducible builds |
| 9 | **TUI only**, so beginners are scared | — | The app itself |

## 4. User research: what people actually need

**Coverage caveat:** Reddit blocked our crawler and X returned no usable posts. The evidence below comes from GitHub issues (Mole, Pearcleaner), Hacker News, Apple Community, MacRumors, MPU Talk, Macworld and Docker forums. **Before building, validate manually on r/macapps and r/MacOS.**

### Pain points, ranked

1. **"System Data" is huge and unexplained** (150–310 GB reports). The causes are Time Machine local snapshots, caches and update leftovers. Sources: [apple 254485649](https://discussions.apple.com/thread/254485649), [256115448](https://discussions.apple.com/thread/256115448)
2. **Developer junk:** Xcode (10–100 GB), a `Docker.raw` that never shrinks ([docker forum](https://forums.docker.com/t/docker-raw-is-way-too-big/123497)), and duplicate AI CLI binaries ([HN](https://news.ycombinator.com/item?id=50133231))
3. **Fear of deleting the wrong thing:** [Mole #823](https://github.com/tw93/Mole/issues/823), [Pearcleaner #506](https://github.com/alienator88/Pearcleaner/issues/506)
4. **Uninstall leftovers**, especially background items and launch agents
5. **Paying for 4–5 separate utilities** (~$75 total; [MacSales](https://eshop.macsales.com/blog/98567-mole-brings-5-absolutely-clutch-mac-utilities-into-one-orbit/))

### What users hate about existing tools

- **CleanMyMac:** subscription (~$47–71/yr), a background helper that won't quit, scareware marketing history, and "cleans caches that just rebuild"
- **DaisyDisk:** analysis only, no cleaning
- **Stats:** short history, no alerts, no fan control
- **Pearcleaner:** false positives, and a past helper security hole

### Explicit feature requests

- Trash instead of delete (Mole #439)
- Whitelist / protect (#1, #142, #206)
- Pick categories to clean (#545, #859)
- Unused simulators (#102)
- macOS installer files (#338)
- Old Chrome versions (#225)
- "Space freed since install" stat (#105)
- Menu-bar-only mode with no Dock icon (#929)
- **A review list that stays fast with hundreds of items** (#1011 says the paid app drops below 10 fps)

## 5. Product ideas, prioritized

### Must-have (MVP: beat the paid app on trust and speed)

1. **Instant disk map.** A `getattrlistbulk` scanner plus a persisted index plus FSEvents, so re-opening is <100 ms. Metal or Canvas treemap or sunburst, drill-down, Reveal / Trash / Quick Look.
2. **Smart Clean with "why" on every item.** Each row shows the rule, the risk level, "rebuilds automatically?", and the last-access date. Everything goes to quarantine with undo.
3. **System Data explainer.** Break down local snapshots (`tmutil`, with a delete button via the helper), APFS purgeable space, VM/swap, iOS backups, Mail downloads, update leftovers.
4. **Developer mode.** Xcode (DerivedData, archives, DeviceSupport, simulators via `simctl delete unavailable`), Docker (`docker system df`, then a guided prune plus a `Docker.raw` compaction hint), node_modules/target/.venv finder with "untouched > 90 days", Homebrew cleanup, AI tool caches/versions.
5. **Uninstaller.** Leftover detection by bundle ID, team ID and launch agents, plus Homebrew-aware removal and a **leftover scan for apps already deleted**.
6. **Menu bar monitor.** CPU/GPU/RAM/net/disk/battery/temps from IOKit with no shell-outs. Configurable, and Dock icon optional.

### Differentiators (why someone picks this over CleanMyMac or Mole for Mac)

7. **Open rule registry.** Rules live in a public repo, versioned, with community PRs and a CI test that validates every rule against fixture trees. The app fetches signed rule updates.
8. **Rebuild-aware savings.** Track whether a cleaned cache regrows, and stop recommending caches that grow back in a day. This answers the "cleans caches that rebuild" criticism directly.
9. **Space timeline.** Daily snapshots of disk usage by category: "what ate 40 GB this week?" Nobody does this well.
10. **Large & old files / duplicates.** APFS-clone-aware hashing (xxhash, size-first bucketing).
11. **Login & background items manager.** Launch agents/daemons, `SMAppService` items, and a "what is this?" lookup by signing team.
12. **Scheduled / threshold cleaning.** "When free space < 20 GB, notify me with a suggested cleanup." No silent auto-delete.
13. **Keep a CLI.** Ship a `vulture` CLI on the same Swift core (`--json`) and an MCP/agent skill, so we keep Mole's power-user and AI-agent audience.

### Avoid

- RAM "boosters", fake "optimize" buttons, scare-badge counters, an always-on daemon, telemetry by default. These are the top trust killers.

## 6. Recommended architecture

```
┌──────────────── App (SwiftUI + AppKit where needed) ────────────────┐
│  Views: Overview · Clean · Disk Map · Uninstall · Dev · Monitor      │
│  @Observable stores, Swift Concurrency, virtualized lists (NSTable   │
│  or List with lazy rows: must handle 100k rows at 120 fps)           │
├──────────────── VultureCore (Swift package, no UI) ──────────────────┤
│  Scanner     getattrlistbulk + TaskGroup, APFS clone/purgeable aware │
│  Index       SQLite (GRDB) persisted tree + FSEvents incremental     │
│  Rules       declarative rule files → matcher → findings + reasons   │
│  Safety      protected paths, open-handle check (libproc), bundle    │
│              running check (NSRunningApplication), identity recheck  │
│  Actions     quarantine/trash, undo log, history                     │
│  Metrics     host_statistics64, IOKit, SMC, IOReport, sysctl         │
├──────────────── Helper (SMAppService daemon, XPC) ───────────────────┤
│  Narrow enum API: deleteLocalSnapshot, removeSystemPath(allowlisted),│
│  flushDNS, rebuildLaunchServices… Caller signature validated.        │
└──────────────────────────────────────────────────────────────────────┘
CLI target `vulture` links VultureCore → same engine, JSON output.
```

- **Language:** all Swift. Rust is an option for the scanner, but `getattrlistbulk` from Swift is already syscall-bound, and one language keeps contributor friction low.
- **Min OS:** macOS 14 (Observation, SMAppService, modern SwiftUI). That matches the market and the paid app.
- **Permissions:** Full Disk Access onboarding with a clear explanation, and graceful degradation without it.
- **Distribution:** Developer ID + notarization, a Homebrew cask, Sparkle. The App Store is impossible because of the sandbox.
- **Build strategy (clean-room):** use Mole only to learn *which problem areas exist*, such as in-use sqlite DBs, shared browser profiles and Trash protection. Design our own rule schema and safety logic, and write our own Swift tests with fixture directories.

## 7. Suggested roadmap

| Phase | Scope | Exit criteria |
|---|---|---|
| 0 | Own rule schema + first hand-written rules + VultureCore scanner + CLI | Scans `~` faster than `mo analyze`; JSON output |
| 1 | Disk Map + Smart Clean + quarantine/undo | Review list fast with 10k items; zero permanent deletes by default |
| 2 | Dev mode + System Data explainer + helper | Snapshots and simulators handled |
| 3 | Uninstaller + login items + menu bar monitor | Menu bar uses <1% CPU |
| 4 | Space timeline, rebuild-aware savings, signed rule updates | Public 1.0 |

## 8. Open questions for you

- Name and branding (folder is "Vulture": keep it?)
- ~~License choice~~: **GPL-3.0** decided

## 9. License: "free, forks stay free, no reselling"

Key fact: **no OSI open-source license forbids selling.** The Open Source Definition (rule 1) bans restricting sale, so GPL-3.0 allows anyone to sell copies. A "no resale" clause makes a project **source-available**, not open source.

| Option | Forks must stay open? | Blocks selling? | Called "open source"? | Trade-off |
|---|---|---|---|---|
| **GPL-3.0 + trademark policy** | Yes, full source required | Not legally. In practice yes: anyone can grab the same app free, and a reseller can't use the name or logo | Yes (OSI) | Industry standard. Most contributors and trust. Homebrew, GitHub Sponsors and press all fine |
| **AGPL-3.0 + trademark** | Yes, also covers hosted/network use | Same as GPL | Yes | Network clause is mostly irrelevant for a desktop app |
| **PolyForm Noncommercial 1.0** | Not required | **Yes**, commercial use banned | **No**, source-available | Matches the wish literally. Fewer contributors; companies can't use it at work; "open source" claims get challenged |
| **CC BY-NC-SA 4.0** | Yes (share-alike) | Yes | No | Built for content, not code. Not recommended for software |

**Recommendation: GPL-3.0 + a registered or declared trademark on the name/logo + a signed official build channel.**
- GPL-3.0 keeps every fork open and free-of-restrictions, under the same license.
- The trademark stops scam resellers who repackage the app under its name. That's the real resale risk for cleaner apps; Mole itself fights lookalike domains.
- Signed builds plus a "download only from" notice let users spot fakes.
- If blocking every sale matters more than the "open source" label → PolyForm Noncommercial.

*Not legal advice. Check with a lawyer before registering a trademark.*
