# Yokoi: Product Requirements Document

| | |
|---|---|
| Owner | Michael Irizarry |
| Status | Draft v0.1 · Oct 31, 2026 |
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
- Duplicate-file detection (could come later).
- Managing project dependencies beyond deleting folders (no `npm install` orchestration).
- Windows/Linux versions or cloud sync.
- Uninstalling apps.

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
- FR-D2 Donut ring + legend of reclaimable space by category (node_modules, build artifacts, caches, big files, screenshots, old packages).
- FR-D3 Primary actions: **Scan Again** and **Clean · ⟨size⟩**, which cleans the current Smart Select (only items labeled safe or stale by default).
- FR-D4 "Top offenders" (largest artifact, largest file, stalest project) that deep-link into their screens.
- FR-D5 Recent cleanups (from the log) and the next scheduled scan.
- FR-D6 Sidebar shows a per-category size/count and a disk capsule (used/free).

### 5.2 node_modules ([02-node-modules.png](../assets/ui/02-node-modules.png))
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

### 5.4 Caches ([04-caches.png](../assets/ui/04-caches.png))
- FR-C1 Sections: System & User, JavaScript, Native toolchains, Xcode, Browsers.
- FR-C2 Every location has a safety level:

| Level | Meaning | Default selection | Examples |
|---|---|---|---|
| **Safe** | Rebuilt automatically, no data loss | Selected | `~/Library/Caches`, `~/.npm/_cacache`, Yarn, Homebrew downloads, CocoaPods, pip, browser caches, `~/Library/Logs` |
| **Re-download** | Safe, but gets refetched over the network (slow next build) | Unselected | pnpm store, Cargo registry (`~/.cargo/registry`), Gradle `~/.gradle/caches` |
| **Review** | Might contain things the user wants | Unselected, warning shown | iOS simulators, Xcode Archives (contain dSYMs), device support |

- FR-C3 Use the tool's own command when one exists (`brew cleanup --prune=all`, `npm cache clean --force`, `pnpm store prune`, `xcrun simctl delete unavailable`, `pip cache purge`). Fall back to deleting files.
- FR-C4 "Select safe only" quick action.

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
- FR-P1 Tabs only appear for managers that are installed. Each shows a count.
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

## 6. Deletion safety model
| Guardrail | Requirement |
|---|---|
| Trash by default | All removals use `FileManager.trashItem`. Permanent delete needs an explicit choice each time. |
| Dry run | Every clean can run as a preview that lists paths and sizes without changing anything. Settings toggle "Always dry run first". |
| Exclusions | User paths and globs (for example `**/.git`, `~/Dropbox`) are never scanned or touched. |
| Active-project protection | Projects touched within N days (default 30) are unselected and flagged. Deleting one needs an extra confirmation. Projects with a running process (open in Xcode/Unity/Unreal, `node` cwd) are blocked. |
| Never-touch list | `/System`, `/Library` (outside known caches), `.git`, source files, anything outside the scan roots and known global paths. |
| Marker validation | Build artifacts are only matched next to their marker file (§5.3). |
| Symlinks | Don't follow symlinks out of the scan root. Deleting removes the link, not its target. |
| Log & undo | Each cleanup is written to a local JSON log (time, paths, sizes, method). Trash removals can be undone from the log (put back) until the Trash is emptied. |
| CLI actions | Package and cache commands are shown verbatim before they run. stdout/stderr are kept in the log. |

## 7. Settings & scheduling ([09-settings.png](../assets/ui/09-settings.png))
- Scan locations with depth (defaults: `~/dev`, `~/work`, `~/games`, `~/Library/Developer`, plus folders found on first run).
- Excluded paths and globs.
- Safety: default delete action (Trash/Permanent), skip projects touched within N days, always dry run.
- Schedule: automatic scan on/off, Daily/Weekly/Monthly, low priority via `NSBackgroundActivityScheduler`. Optional auto-clean of **Safe** caches only. Notify when reclaimable exceeds X GB (default 50).
- Screenshot auto rule (mirrors §5.6).

## 8. Menu bar helper
- `MenuBarExtra` showing free space and reclaimable space, last scan, **Scan now**, **Clean safe items** (opens a confirmation), and Open Yokoi.
- Runs scheduled scans and the screenshot rule while the main window is closed. Launch at login via `SMAppService.mainApp`.
- User notifications for threshold alerts and finished auto-actions.

## 9. Non-functional requirements
| Area | Requirement (proposed targets) |
|---|---|
| Scan performance | Full scan of about 1M files in ≤ 20 s on Apple Silicon (M1+) SSD. Incremental rescan in ≤ 5 s. First results stream to the UI in < 1 s. |
| Resource use | Background scans at utility QoS, < 30% of one core on average, < 300 MB RAM. |
| UI | 60 fps scrolling with 10k-row tables. Launch to usable in < 1 s. |
| Correctness | Size = allocated size (`totalFileAllocatedSize`). Hard links counted once. |
| Permissions | Full Disk Access is requested with an onboarding explainer. The app degrades gracefully without it (shows unscanned locations). |
| Privacy | 100% local. No network calls except package registry lookups the user starts. No telemetry by default. Opt-in anonymous crash reports only. |
| Accessibility | Full VoiceOver labels, keyboard navigation (⌘K, ⌘⌫, space to Quick Look), Dynamic Type where possible, respects Reduce Motion/Transparency, color never the only signal (pills carry text). |
| Appearance | Dark first. Light mode supported in v1.1. |
| Min OS | macOS 14 Sonoma (Observation, latest SwiftUI Table/Inspector, SMAppService). |
| Localization | English at launch. Strings externalized via String Catalogs. |

### Distribution tradeoff
| | Mac App Store (sandboxed) | Direct (Developer ID + notarized) |
|---|---|---|
| File access | Only user-granted folders (security-scoped bookmarks). No arbitrary `~/Library` | Full Disk Access possible |
| Running CLIs (`brew`, `npm`…) | Blocked by sandbox | Allowed via `Process` |
| Discovery/payments | Built in | Own site, Paddle/Stripe, Sparkle updates |
| **Recommendation** | n/a | **Direct distribution for v1.** An App Store "Lite" edition (folder-scoped cleaning, no package managers) could be considered later. |

## 10. Technical architecture
| Layer | Approach |
|---|---|
| UI | SwiftUI, `NavigationSplitView` (sidebar + detail), `Table` with `KeyPathComparator` sorting and `Set<ID>` selection, `.sheet` for confirmations, `.inspector` for the screenshot action panel, Swift Charts `SectorMark` for the ring, materials per DESIGN.md |
| State | `@Observable` models per feature, with one `ScanStore` as the source of truth |
| Scanning | Swift Concurrency: a `TaskGroup` per scan root that streams results (`AsyncStream`) to the UI, cancellable. `FileManager.enumerator(at:includingPropertiesForKeys:options:)` prefetching `.isDirectoryKey, .contentModificationDateKey, .totalFileAllocatedSizeKey, .isSymbolicLinkKey, .fileResourceIdentifierKey`. Pattern matches are pruned so the scanner skips their subtrees and sizes them in parallel |
| Incremental | `FSEvents` watcher plus a cached index (SQLite/SwiftData) keyed by path + mtime |
| Detectors | `ArtifactDetector` protocol (marker, paths, safety, restore hint), one per ecosystem, data-driven so new ones are easy to add |
| CLI | A `ProcessRunner` actor wrapping `Process` with a login-shell PATH (`/opt/homebrew/bin`, nvm/asdf shims), timeouts, JSON parsing, and a streamed output log |
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
*(Tracked from opt-in analytics or beta surveys only. There is no telemetry by default.)*

## 12. Release milestones (proposed)
| Release | Scope |
|---|---|
| **MVP (v1.0)** | Dashboard, node_modules, Build Artifacts (Rust, Xcode, Swift PM, Gradle, Python, Unity, Unreal), Caches (Safe + Re-download levels), Big Files, Screenshots (manual move/delete), confirmation sheet, Trash default + dry run + exclusions + active-project protection + log, Settings (locations, exclusions, safety), direct distribution, macOS 14+ |
| **v1.1** | Package managers (npm -g, pnpm -g, Homebrew formulae/casks, Cargo, pip, gem) with update/uninstall confirmation, screenshot auto rule, scheduling + menu bar helper + notifications, Go/.NET/CMake detectors, Xcode simulators/archives (Review level), undo from log, light mode |
| **Later (v1.2+)** | FSEvents incremental index, duplicate finder, Docker images/volumes, Android SDK/emulators, conda/poetry/uv, per-project "archive & restore" (lockfile kept, deps removed), CLI companion (`yokoi scan --json`), App Store Lite edition, Shortcuts/AppIntents |

## 13. Risks & open questions
**Risks**
| Risk | Mitigation |
|---|---|
| Deleting something the user needed | Trash default, Review level, marker validation, active-project protection, undo log |
| Wrong PATH, so the app can't find CLIs (nvm, asdf, Homebrew prefix) | Resolve PATH from the login shell, with manual override in Settings |
| Slow scans on huge trees or network volumes | Skip network/external volumes by default, prune matched subtrees, stream results, cancel |
| Full Disk Access friction | Clear onboarding, partial mode without it |
| CLI output formats change | Prefer JSON flags, version-gated parsers, tests with fixtures |
| Upgrading a global package breaks a toolchain | Show version changes, single-package default, keep output log |

**Open questions**
1. Business model: paid upfront, freemium (scan free, clean paid), or open source?
2. Should "Clean safe caches" ever run fully automatically without confirmation?
3. Should "Unused" package detection use binary atime (unreliable) or shell history parsing (privacy-sensitive)?
4. Should package managers move into MVP? They're in the original ask but carry the most risk.
5. Support Intel Macs, or Apple Silicon only?
6. Unreal `Saved/`: always opt-in, or split into Logs/Crashes (safe) vs Config (never)?
7. Is a sandboxed App Store edition worth maintaining?
