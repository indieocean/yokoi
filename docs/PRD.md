# Yokoi: Product Requirements Document

| | |
|---|---|
| Owner | Michael Irizarry |
| Status | Living spec · built through v1.7.0 · updated Nov 8, 2026 |
| Platform | Native macOS (Swift / SwiftUI) |
| Design refs | [DESIGN.md](DESIGN.md) · [contact sheet](../assets/ui/00-contact-sheet.png) |

> Every number in this doc (performance, metrics, dates) is a **proposed target**, not a measured fact. Sample data in the mockups is made up.

---

## 1. Overview & problem
Developers' Macs fill up with files they can rebuild or re-download: `node_modules`, Rust `target/`, Xcode DerivedData, Unity `Library/`, Unreal `DerivedDataCache`, package-manager caches, simulator runtimes, old global packages, and a desktop full of screenshots. Today this means scattered commands (`rm -rf`, `brew cleanup`, `xcrun simctl delete unavailable`), guesswork about what's safe to delete, and generic cleaners that don't understand dev tooling.

**Yokoi** is a native Mac app that finds this developer clutter, explains it, and removes it safely. It's built for software engineers and game developers and should look the part.

## 2. Goals / Non-goals
**Goals**
1. Find reclaimable dev space in one scan, grouped by category, with clear safety labels.
2. Make cleanup safe by default: Trash first, dry run, exclusions, warnings for active projects, plus a log you can undo from.
3. Show installed vs latest versions across package managers and ask before any update or uninstall.
4. Keep the desktop tidy with screenshot rules (move by date or delete).
5. Feel like a first-class native dev tool (see [DESIGN.md](DESIGN.md)).

**Non-goals (v1)**
- General consumer "Mac cleaner" features (mail attachments, language packs, malware, RAM boosting).
- Managing project dependencies beyond deleting folders (no `npm install` orchestration).
- Windows/Linux versions or cloud sync.

## 3. Target users & personas
| Persona | Context | Main pain | Top features |
|---|---|---|---|
| **Maya, web/full-stack dev** | 60+ JS/TS repos in `~/dev`, npm/pnpm/yarn, Homebrew | Tens of GB in stale `node_modules`, caches, outdated global CLIs | node_modules, Caches, Package Managers |
| **Diego, game dev (Unity/Unreal)** | Large engine projects, 3D/video assets, VMs | Unreal DDC/Intermediate and Unity Library reach 10–50 GB per project, plus huge raw assets | Build Artifacts, Big Files |
| **Sam, mobile/Xcode dev** | iOS/Android, Swift PM, CocoaPods, Gradle | DerivedData, simulators, archives, Gradle caches | Build Artifacts, Caches (Xcode), Screenshots |

## 4. User stories
| # | As a… | I want to… | So that… |
|---|---|---|---|
| US1 | dev | see total reclaimable space by category at a glance | I know whether a cleanup is worth it |
| US2 | web dev | delete `node_modules` in projects I haven't touched in 90+ days | I free space without hurting active work |
| US3 | game dev | clear Unreal Intermediate/Saved/DDC and Unity Library/Temp per project | I get back tens of GB |
| US4 | mobile dev | clear DerivedData, unavailable simulators and old archives | Xcode stops eating my disk |
| US5 | dev | clear package caches labeled by safety | I don't delete something I can't get back |
| US6 | anyone | find files over a size I choose and reveal or trash them | I can deal with giant forgotten files |
| US7 | anyone | move desktop screenshots into dated folders or delete them, automatically after N days | my desktop stays clean |
| US8 | dev | see outdated/unused global packages for npm, brew, cargo, pip, gem, pnpm | I can update or remove them after confirming |
| US9 | cautious user | preview, confirm, and undo deletions | I trust the tool |
| US10 | busy user | run scans on a schedule and see status in the menu bar | I don't have to remember |

## 5. Functional requirements

### 5.1 Dashboard ([01-dashboard.png](../assets/ui/01-dashboard.png))
- FR-D1 KPI tiles: reclaimable total, projects scanned, last scan (duration, file count), freed all-time.
- FR-D2 Donut ring + legend of reclaimable space by category (package managers, build artifacts, caches, big files, downloads, screenshots, applications).
- FR-D3 Primary actions: **Scan Again** and **Clean · ⟨size⟩**, which cleans the current Smart Select (only items labeled safe or stale by default).
- FR-D4 "Top offenders" (largest artifact, largest file, stalest project) that deep-link into their screens.
- FR-D5 Recent cleanups (from the log) and the next scheduled scan.
- FR-D6 Sidebar shows a per-category size/count and a disk capsule (used/free).

### 5.2 node_modules ([02-node-modules.png](../assets/ui/02-node-modules.png))
This has no sidebar item of its own: it's the project view under **Package Managers → npm**.

- FR-N1 Find every `node_modules` under the scan roots. Don't descend into nested `node_modules`. Report each project root.
- FR-N2 Columns: project name, framework hint (read from `package.json` dependencies), path, status (Active/Stale), last touched, size bar, size.
- FR-N3 "Last touched" is the newest mtime of the project's source files (excluding node_modules/.git), falling back to the last git commit date.
- FR-N4 Filters: All / Stale / Active. Stale threshold defaults to 90 days and can be changed. Package manager is detected from the lockfile (npm/pnpm/yarn/bun).
- FR-N5 Multi-select, sort by any column, and a bottom bar showing the selected count and size, with Reveal and **Delete node_modules**, which opens the confirmation sheet (§5.8).

### 5.3 Build artifacts ([03-build-artifacts.png](../assets/ui/03-build-artifacts.png))
- FR-B1 Group results by language/engine with a colored badge and summary chips. Toggle between By language and By project.
- FR-B2 Only match a pattern when its **marker file** is present, to avoid false positives.
- FR-B3 Each row shows the project, path, a "rebuildable" note and size.

| Ecosystem | Marker | Paths removed |
|---|---|---|
| Rust | `Cargo.toml` | `target/` |
| Xcode | n/a (global) | `~/Library/Developer/Xcode/DerivedData/*` |
| Swift PM | `Package.swift` | `.build/` |
| Gradle / Android | `build.gradle(.kts)`, `settings.gradle` | `build/`, `.gradle/`, `app/build/` |
| Go | n/a (global) | `go env GOCACHE` (`~/Library/Caches/go-build`) |
| Python | `*.py`, `pyproject.toml`, `requirements.txt` | `__pycache__/`, `.venv/`, `venv/`, `.pytest_cache/`, `.mypy_cache/`, `.tox/` |
| .NET | `*.csproj`, `*.sln` | `bin/`, `obj/` |
| Unity | `ProjectSettings/ProjectVersion.txt` | `Library/`, `Temp/`, `Obj/`, `Logs/` |
| Unreal | `*.uproject` | `Intermediate/`, `Saved/` (excl. `Saved/Config`, opt-in), `DerivedDataCache/`, `Binaries/` (opt-in) |
| JS frameworks (optional) | `package.json` | `.next/`, `dist/`, `.turbo/`, `.parcel-cache/` |
| CMake / C++ | `CMakeLists.txt` | `build/`, `cmake-build-*/` |

- FR-B4 Opt-in items (Unreal `Binaries`, `Saved/Config`) are unchecked by default and carry a tooltip explaining the risk.

### 5.4 Caches & Tooling ([04-caches.png](../assets/ui/04-caches.png))
- FR-C1 Sections: System & User, JavaScript, Python, Native toolchains, Xcode, Android, Editors & IDEs, Containers, AI agents, AI models, Downloads, Browsers, Trash.
- FR-C2 Every location has a safety level:

| Level | Meaning | Default selection | Examples |
|---|---|---|---|
| **Safe** | Rebuilt automatically, no data loss | Selected | `~/Library/Caches`, `~/.npm/_cacache`, Yarn, Homebrew downloads, CocoaPods, pip, browser caches, `~/Library/Logs` |
| **Re-download** | Safe, but gets refetched over the network (slow next build) | Unselected | pnpm store, Cargo registry (`~/.cargo/registry`), Gradle `~/.gradle/caches` |
| **Review** | Might contain things the user wants | Unselected, warning shown | iOS simulators, Xcode Archives (contain dSYMs), device support |

- FR-C3 Cache locations are cleaned by removing a folder's contents, never the folder. Tool cleanups use the tool's own command, shown first: unavailable simulators and runtimes (`xcrun simctl`), local Time Machine snapshots (`tmutil`), Docker images, build cache and volumes (`docker`), and the Go module cache.
- FR-C4 "Select safe only" quick action.
- FR-C5 AI agents (Claude app, Claude Code, Claude Cowork, Codex, ChatGPT, Grok, Gemini CLI, Copilot CLI, OpenCode): only what an agent rebuilds is Safe. Session history, checkpoints and the Cowork VM are Review, so Smart Select and auto-clean never take them. Logins, settings, skills, plugins, Claude Code project memory, Codex sessions and Cursor chats are left out.
- FR-C6 A location with an agent or app using it is refused until that process quits (§6).

### 5.5 Big files ([05-big-files.png](../assets/ui/05-big-files.png))
- FR-F1 Threshold slider on a log scale (100 MB to 10 GB+), default ≥ 1 GB.
- FR-F2 Type filters: Video, Archives, Disk images, 3D/Art, VMs (by UTType and extension).
- FR-F3 Sortable list: type badge, name, location, modified date, size. Row actions are Reveal in Finder and Quick Look.
- FR-F4 Actions: Move to Trash (default) or Move to… (for example an external drive). Never delete permanently without the confirmation sheet.
- FR-F5 Exclude system/app bundle internals and anything already in Trash.

### 5.6 Desktop screenshots ([06-screenshots.png](../assets/ui/06-screenshots.png))
- FR-S1 Detect screenshots and screen recordings on the Desktop (or the custom location read from `com.apple.screencapture location`) by filename pattern + `kMDItemIsScreenCapture`.
- FR-S2 Thumbnail grid (QuickLook) with multi-select. Tabs: Screenshots / Recordings. Highlight items older than the rule threshold.
- FR-S3 Action panel: **Move to folder…** (folder picker, default `~/Pictures/Screenshots/YYYY/MM/`, organized by date) or **Delete** (Trash).
- FR-S4 **Auto rule** toggle: every day, move or delete screenshots older than N days (default 7). Runs in the background helper and is logged.
- FR-S5 Name conflicts are resolved by adding a suffix. Never overwrite.

### 5.7 Package managers ([07-package-managers.png](../assets/ui/07-package-managers.png))
- FR-P1 Tabs only appear for managers that are installed. Each shows a count. There are 17: npm, pnpm, yarn, bun, Homebrew, casks, MacPorts, mas, Cargo, Go, .NET, pip, pipx, uv, conda, gem and Composer. The table in FR-P4 shows the original seven.
- FR-P2 Columns: package, installed version, latest version (→ green if newer), status (Outdated / Up to date / Unused > 1y), last used, size, row action (Update or Uninstall).
- FR-P3 A terminal strip shows the exact command that was run and how long it took (transparency).
- FR-P4 Version-checking commands:

| Manager | List installed | Check outdated | Update | Uninstall |
|---|---|---|---|---|
| npm (global) | `npm ls -g --depth=0 --json` | `npm outdated -g --json` | `npm i -g <pkg>@latest` | `npm uninstall -g <pkg>` |
| pnpm (global) | `pnpm ls -g --json` | `pnpm outdated -g --format json` | `pnpm add -g <pkg>@latest` | `pnpm rm -g <pkg>` |
| Homebrew formulae | `brew info --json=v2 --installed` | `brew outdated --json=v2` | `brew upgrade <f>` | `brew uninstall <f>` (offer `brew autoremove`) |
| Homebrew casks | `brew list --cask --versions` | `brew outdated --cask --greedy --json=v2` | `brew upgrade --cask <c>` | `brew uninstall --cask <c>` |
| Cargo | `cargo install --list` | crates.io index lookup (or `cargo install-update -l` if present) | `cargo install <crate>` | `cargo uninstall <crate>` |
| pip | `python3 -m pip list --format=json` | `python3 -m pip list --outdated --format=json` | `pip install -U <pkg>` | `pip uninstall -y <pkg>` |
| gem | `gem list --local` | `gem outdated` | `gem update <gem>` | `gem uninstall <gem>` |

- FR-P5 "Last used" comes from the atime of the binaries in the bin dir (best effort, labeled approximate). Size is the on-disk size of the install dir.
- FR-P6 **Confirmation flow:** every Update or Uninstall (single or batch) opens a sheet that lists the packages and version changes, shows the commands that will run, and offers a "Show output" log. Nothing runs until the user confirms. Failures are shown per package.
- FR-P7 Python: detect multiple interpreters (system, Homebrew, pyenv) and scope to one chosen interpreter. Warn against changing the system Python.

### 5.8 Confirmation sheet ([08-confirm-delete.png](../assets/ui/08-confirm-delete.png))
- Shows total size, item and file count, the first N paths (+ "N more"), and how to restore (for example "run `npm install`").
- Radio choice: **Move to Trash** (default) / **Delete permanently** (red, "cannot be undone").
- "Don't ask again" only applies to Safe-level items and never to permanent deletion.

### 5.9 Duplicates
- FR-DU1 Find files of 1 MB or more with identical contents (SHA-256), in the big-file locations or in one chosen folder, skipping what Big files skips (FR-F5). The folder must be in a big-file location, since those bound what cleanup may reach.
- FR-DU2 Runs only when asked for. It reads files in full, so full and background scans, the CLI and Shortcuts leave it out. Its bytes aren't in the reclaimable total, because they overlap Big files and Downloads.
- FR-DU3 Group copies by contents, biggest saving first. Each copy shows its path, modified date and what removing it frees. Row actions are Reveal in Finder and Quick Look.
- FR-DU4 Hardlinks count as one file. Groups of APFS clones that would free nothing aren't listed.
- FR-DU5 Groups with every copy inside git work trees aren't listed, unless a folder was chosen. Copies in a repository are tagged and kept first.
- FR-DU6 Nothing is preselected. "Select Extras" picks all but the best copy in each group and never picks a copy in a repository. The best copy is one in a repository, then one outside Downloads, then the shortest path.
- FR-DU7 One copy always stays. The last unpicked copy can't be picked, and cleanup refuses a removal unless the copy still matches its hash and another copy outside that cleanup does too, read again right before acting.
- FR-DU8 Move to Trash, with permanent delete only from the confirmation sheet. No Move to…: a moved copy frees nothing.
- FR-DU9 Cloud-only files are never read, since that would download them. They're listed as not checked, along with unreadable files.

### 5.10 Downloads
- FR-W1 List the direct children of `~/Downloads` (files, folders sized as a whole, installers, archives), with when each was added and last opened. Screenshots saved there are left to the Screenshots screen.
- FR-W2 Items untouched for 30 days (configurable) count as reclaimable.
- FR-W3 Incomplete downloads and archives already extracted are flagged as leftovers. These are the user's own files, so Smart Select never preselects them.

### 5.11 Applications
- FR-A1 List apps in `/Applications` and `~/Applications` with size, last opened and leftovers in `~/Library`.
- FR-A2 Leftovers match by exact bundle id. The app name is only used for Application Support, Caches and Logs, and only when no other installed app uses that name.
- FR-A3 Anything matched on what an app could simply claim stays unless the user ticks it.
- FR-A4 Apple apps, Yokoi itself and running apps are locked.

### 5.12 External drives
- FR-E1 Find local volumes under `/Volumes`, skipping network shares. Read-only volumes and Time Machine disks are never cleaned.
- FR-E2 Offer the drive's own Trash, `.DS_Store` files, and `._` AppleDouble files on exFAT, FAT and NTFS only.
- FR-E3 Everything here is delete-only: moving to the Trash on an external drive frees nothing.
- FR-E4 A drive can be included in project and big-file scans.

## 6. Deletion safety model
| Guardrail | Requirement |
|---|---|
| Trash by default | All removals use `FileManager.trashItem` unless permanent delete is chosen: in the confirmation sheet each time, with `--permanent` on the command line, or with the opt-in auto-clean setting. |
| Dry run | Every clean can run as a preview that lists paths and sizes without changing anything. Settings toggle "Dry run". |
| Exclusions | User paths and globs (for example `**/.git`, `~/Dropbox`) are never scanned or touched. |
| Active-project protection | Projects touched within N days (default 14) are unselected and flagged. Deleting one needs an extra confirmation. Projects with a running process (open in Xcode/Unity/Unreal, `node` cwd), running apps and agents, and booted Android emulators are blocked. |
| Never-touch list | `/System`, `/Library` (outside known caches), `.git`, source files, anything outside the scan roots and known global paths. |
| Marker validation | Build artifacts are only matched next to their marker file (§5.3). |
| Symlinks | Don't follow symlinks out of the scan root. Deleting removes the link, not its target. |
| Log & undo | Each cleanup is written to a local JSON log (time, paths, sizes, method). Trash removals can be undone from the log (put back) until the Trash is emptied. |
| CLI actions | Package and cache commands are shown verbatim before they run. stdout/stderr are kept in the log. |

## 7. Settings & scheduling ([09-settings.png](../assets/ui/09-settings.png))
- Scan locations with depth (defaults: `~/dev`, `~/work`, `~/games`, `~/Library/Developer`, plus folders found on first run).
- Excluded paths and globs.
- Safety: default delete action (Trash/Permanent), skip projects touched within N days, dry run.
- Schedule: automatic scan on/off, Daily/Weekly/Monthly, low priority via `NSBackgroundActivityScheduler`. Optional auto-clean (below). Notify when reclaimable exceeds X GB (default 50).
- Screenshot auto rule (mirrors §5.6).

**Auto-clean** (opt-in, needs automatic scans): runs after each scheduled scan with no confirmation. Takes Safe caches, or everything Smart Select takes. Uses the Trash unless "Delete permanently" is on. Never empties the Trash, holds back anything in use, and is logged like any other cleanup. `yokoi clean` follows the same rules: it previews until given `--yes`, and `--permanent` deletes for good.

## 8. Menu bar helper
- `MenuBarExtra` showing free space and reclaimable space, last scan, **Scan now**, **Clean safe items** (opens a confirmation), and Open Yokoi.
- Runs scheduled scans and the screenshot rule while the main window is closed. Launch at login via `SMAppService.mainApp`. The Settings toggle shows macOS's own status, so it follows changes made in System Settings → Login Items, and offers to open that pane when Yokoi is switched off there.
- User notifications for threshold alerts and finished auto-actions.

## 9. Non-functional requirements
| Area | Requirement (proposed targets) |
|---|---|
| Scan performance | Full scan of about 1M files in ≤ 20 s on Apple Silicon (M1+) SSD. Incremental rescan in ≤ 5 s. First results stream to the UI in < 1 s. |
| Resource use | Background scans at utility QoS, < 30% of one core on average, < 300 MB RAM. |
| UI | 60 fps scrolling with 10k-row tables. Launch to usable in < 1 s. |
| Correctness | Size = allocated size (`totalFileAllocatedSize`). Hard links counted once, and sizes of cleanable folders count only what cleaning frees. |
| Permissions | Full Disk Access is requested with an onboarding explainer. The app degrades gracefully without it (shows unscanned locations). |
| Privacy | 100% local. No network calls except package registry lookups the user starts and Sparkle update checks the user allows. No telemetry and no crash reporting. |
| Accessibility | Full VoiceOver labels, keyboard navigation (⌘K, ⌘⌫, space to Quick Look), Dynamic Type where possible, respects Reduce Motion/Transparency, color never the only signal (pills carry text). |
| Appearance | Dark only. Light mode isn't built. |
| Min OS | macOS 14 Sonoma (Observation, latest SwiftUI Table/Inspector, SMAppService). |
| Localization | The app is in English, Japanese, Simplified and Traditional Chinese, Korean, Spanish, Portuguese (Brazil), German, French, Arabic and Hebrew, from one String Catalog (`Yokoi/Localizable.xcstrings`). It follows the Mac's language or the per-app choice in System Settings, with no picker of its own. Arabic and Hebrew mirror the layout. The CLI, cleanup log and website stay English. The translations are drafts awaiting native review. |

### Distribution tradeoff
| | Mac App Store (sandboxed) | Direct (Developer ID + notarized) |
|---|---|---|
| File access | Only user-granted folders (security-scoped bookmarks). No arbitrary `~/Library` | Full Disk Access possible |
| Running CLIs (`brew`, `npm`…) | Blocked by sandbox | Allowed via `Process` |
| Discovery/payments | Built in | Own site, Paddle/Stripe, Sparkle updates |
| **Recommendation** | n/a | **Direct distribution for v1.** An App Store "Lite" edition (folder-scoped cleaning, no package managers) could be considered later. |

**Shipped:** direct distribution, signed and notarized, free and open source (GPL-3.0). Available as a `.dmg` from GitHub Releases and with `brew install --cask indieocean/tap/yokoi`. Updates come through Sparkle.

## 10. Technical architecture
| Layer | Approach |
|---|---|
| UI | SwiftUI, `NavigationSplitView` (sidebar + detail), `Table` with `KeyPathComparator` sorting and `Set<ID>` selection, `.sheet` for confirmations, `.inspector` for the screenshot action panel, Swift Charts `SectorMark` for the ring, materials per DESIGN.md |
| State | `@Observable` models per feature, with one `ScanStore` as the source of truth |
| Scanning | Swift Concurrency: a `TaskGroup` per scan root that streams results (`AsyncStream`) to the UI, cancellable. `FileManager.enumerator(at:includingPropertiesForKeys:options:)` prefetching `.isDirectoryKey, .contentModificationDateKey, .totalFileAllocatedSizeKey, .isSymbolicLinkKey, .fileResourceIdentifierKey`. Pattern matches are pruned so the scanner skips their subtrees and sizes them in parallel |
| Incremental | FSEvents history replayed from a saved event ID (`ChangeJournal`), plus saved measurements in `scan-index.json` (`ScanIndex`), reused only if nothing at or under a path changed and its inode is the same |
| Detectors | One data-driven table, `ArtifactRule` (markers, target folders, opt-in flags, restore hint), so a new ecosystem is one new entry |
| CLI | A `ProcessRunner` actor wrapping `Process` with a login-shell PATH (`/opt/homebrew/bin`, nvm/asdf shims), tools resolved to trusted absolute paths and run without a shell, timeouts, JSON parsing, and a streamed output log |
| Deletion | `CleanupService`: dry-run plan → confirm → `trashItem`/`removeItem` → log entry. Runs in the main app (no privileged helper in v1) |
| Thumbnails | `QLThumbnailGenerator`, Spotlight `NSMetadataQuery` for screenshot detection |
| Background | `MenuBarExtra` + login item via `SMAppService`, `NSBackgroundActivityScheduler`, `UNUserNotificationCenter` |
| Updates | Sparkle 2 (direct distribution) |

## 11. Success metrics (proposed targets)
| Metric | Target |
|---|---|
| Median space reclaimed on first clean | ≥ 20 GB |
| Users who complete a clean in their first session | ≥ 70% |
| Accidental-deletion reports (restore from log / support) | < 0.5% of cleanups |
| Retention: users with ≥ 1 scheduled scan active at day 30 | ≥ 40% |
| Full-scan p50 time on reference machine | ≤ 20 s |
| App rating / NPS among beta devs | ≥ 4.5★ / NPS ≥ 40 |
*(The app has no telemetry, so these can only come from beta surveys.)*

## 12. Release milestones
| Release | Scope |
|---|---|
| **MVP (v1.0)** | Dashboard, node_modules, Build Artifacts (Rust, Xcode, Swift PM, Gradle, Python, Unity, Unreal), Caches (Safe + Re-download levels), Big Files, Screenshots (manual move/delete), confirmation sheet, Trash default + dry run + exclusions + active-project protection + log, Settings (locations, exclusions, safety), direct distribution, macOS 14+ |
| **v1.1** | Package managers (npm -g, pnpm -g, Homebrew formulae/casks, Cargo, pip, gem) with update/uninstall confirmation, screenshot auto rule, scheduling + menu bar helper + notifications, Go/.NET/CMake detectors, Xcode simulators/archives (Review level), undo from log |
| **Shipped through v1.7** | FSEvents incremental index, Applications, External Drives, Docker, Android SDK/emulators, 17 package managers, CLI (`yokoi scan`, `yokoi clean`), Shortcuts/App Intents, Downloads, Duplicates (§5.9), auto-clean, AI agent cleanup (§5.4), 11 languages with right-to-left layout (§9) |
| **Later** | Per-project "archive & restore" (lockfile kept, deps removed), light mode, App Store Lite edition |

## 13. Risks & open questions
**Risks**
| Risk | Mitigation |
|---|---|
| Deleting something the user needed | Trash default, Review level, marker validation, active-project protection, undo log |
| Wrong PATH, so the app can't find CLIs (nvm, asdf, Homebrew prefix) | Resolve PATH from the login shell, and run only tools from locations no other account can write to |
| Slow scans on huge trees or network volumes | Skip network/external volumes by default, prune matched subtrees, stream results, cancel |
| Full Disk Access friction | Clear onboarding, partial mode without it |
| CLI output formats change | Prefer JSON flags, version-gated parsers, tests with fixtures |
| Upgrading a global package breaks a toolchain | Show version changes, single-package default, keep output log |

**Open questions**
1. Should "Unused" package detection use binary atime (unreliable) or shell history parsing (privacy-sensitive)?
2. Unreal `Saved/`: always opt-in, or split into Logs/Crashes (safe) vs Config (never)?
3. Is a sandboxed App Store edition worth maintaining?

**Decided**
- Business model: free and open source (GPL-3.0).
- Unattended cleaning: yes, but only as opt-in auto-clean, under the rules in §7.
- Package managers: shipped after the MVP, in v1.1.
- Intel Macs: supported, alongside Apple Silicon.
