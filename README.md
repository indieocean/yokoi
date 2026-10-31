# Disk Keeper

Native SwiftUI macOS app (macOS 14+) that finds developer clutter and removes it safely.
Spec: [PRD.md](PRD.md) · design: [DESIGN.md](DESIGN.md) · mockups: `assets/ui/` · open questions: [QUESTIONS.md](QUESTIONS.md)

## Build, run, test

```sh
open DiskKeeper.xcodeproj            # then ⌘R / ⌘U in Xcode
# or from the terminal:
xcodebuild -project DiskKeeper.xcodeproj -scheme DiskKeeper build
xcodebuild -project DiskKeeper.xcodeproj -scheme DiskKeeper test
```

The project uses Xcode folder-synced groups: add a `.swift` file under `DiskKeeper/`, `Core/` or
`DiskKeeperTests/` and it's picked up automatically, with no project-file edits.

Debug-only: `DiskKeeper.app/Contents/MacOS/DiskKeeper -DKSnapshotDir /some/dir` runs a scan, renders
every screen and the confirmation sheet to PNG, then quits. Handy for comparing against the mockups.

## Layout

| Folder | What's in it |
|---|---|
| `Core/` | Everything testable, compiled into both the app and the test bundle (no UI). |
| `Core/Models` | Categories, `ArtifactRule` table, `CacheLocation` table, item types, package-manager model (v1.1 stub). |
| `Core/Scanning` | `CategoryScanner` protocol, `ProjectWalker` (parallel `TaskGroup` walk with pruning), the `ScanEngine` actor and one scanner per category. |
| `Core/Safety` | `GlobMatcher` (exclusions) and `PathGuard`, the single gate for every file operation. |
| `Core/Cleanup` | `CleanupService` actor (trash / delete / move, dry run) and the JSON Lines `CleanupLog`. |
| `Core/Settings` | `SettingsData` (Codable) plus default scan-root detection. |
| `DiskKeeper/App` | App entry, `AppModel`, `ScanStore` (single source of truth), `SettingsStore`, platform helpers. |
| `DiskKeeper/ViewModels` | One `@Observable` view model per screen. |
| `DiskKeeper/Views`, `Theme` | Screens, confirmation sheet, design-system components, palette (asset catalog + `Theme`). |
| `DiskKeeperTests` | Swift Testing suites against a throwaway fixture home folder. |

## Adding a language / engine

Add one entry to `ArtifactRule.all` in `Core/Models/ArtifactRule.swift`: markers, target folders,
opt-in flags and a restore hint. Badge color and name go in `Ecosystem` (`Core/Models/Categories.swift`).

## Safety model (as built)

- Move to Trash by default. Permanent delete only from the confirmation sheet, with an extra
  "I understand" tick every time.
- Every path goes through `PathGuard`: it must be strictly inside that **category's** allowed roots,
  not excluded, not inside `.git`, and not under `/System`, `/Library`, `/usr`… It checks both the literal path
  and the path with parent symlinks resolved.
- Projects changed in the last 14 days (configurable) start unchecked. The sheet holds them back
  unless you tick "Include them anyway".
- Dry run (Settings → Safety) logs and reports what would happen without touching anything.
- Every cleanup is appended to `~/Library/Application Support/DiskKeeper/cleanup.log` (JSON Lines:
  batch, timestamp, action, path, size, Trash location of each item).
- Cache cleanup removes a cache folder's *contents*, never the folder. No telemetry. The only network
  traffic is package managers checking for updates, and only when you click "Check for Updates".

## Status

Built: Dashboard, node_modules, Build Artifacts, Caches (+ Trash, installers, AI models, unavailable
simulators, local Time Machine snapshots), Big Files, Screenshots (+ daily auto rule), **Applications**
(uninstall + `~/Library` leftovers), **External Drives** (drive Trash, `.DS_Store`, `._` files, include a
drive in scans), **Package Managers** (npm/pnpm/brew/casks/cargo/pip/gem with confirmed update/uninstall),
confirmation sheet, Put Back (undo from the log), open-project blocking, menu bar helper, scheduled scans,
launch at login, notifications, Settings.

Extra safety added with these:
- Personal data is hard-blocked regardless of roots: Keychains, Mail, Messages, iCloud Drive
  (`Mobile Documents`), `CloudStorage`, Safari, Calendars, Photos libraries, and the top-level home folders themselves.
- Nothing is cleaned while a running process uses it (project open in Xcode/Unity/Unreal, `node` cwd,
  running app). Checked when the sheet opens and again right before acting.
- Command-line tools run without a shell, arguments passed literally; `sudo`, `su`, `osascript` and shells
  are refused outright.
