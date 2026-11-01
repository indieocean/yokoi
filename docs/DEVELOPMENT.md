# Developing Yokoi

Notes for working on Yokoi itself. For what the app does, see the [README](../README.md).

Spec: [PRD.md](PRD.md) · design: [DESIGN.md](DESIGN.md) · mockups: [`assets/ui/`](../assets/ui/) · open questions: [QUESTIONS.md](QUESTIONS.md)

> Yokoi was called "Disk Keeper" during early development. Settings, the cleanup log and the last scan are
> migrated automatically on first launch (`Yokoi/App/LegacyMigration.swift`).

## Build, run, test

```sh
open Yokoi.xcodeproj            # then ⌘R / ⌘U in Xcode
# or from the terminal:
xcodebuild -project Yokoi.xcodeproj -scheme Yokoi build
xcodebuild -project Yokoi.xcodeproj -scheme Yokoi test
```

The project uses Xcode folder-synced groups: add a `.swift` file under `Yokoi/`, `Core/` or
`YokoiTests/` and it's picked up automatically, with no project-file edits.

Debug-only: `Yokoi.app/Contents/MacOS/Yokoi -DKSnapshotDir /some/dir` runs a scan, renders
every screen, the confirmation sheet and a dry-run cleanup animation to PNG, then quits. Handy for comparing against the mockups.

## Layout

| Folder | What's in it |
|---|---|
| `Core/` | Everything testable, compiled into both the app and the test bundle (no UI). |
| `Core/Models` | Categories, `ArtifactRule` table, `CacheLocation` table, item types, package-manager model (v1.1 stub). |
| `Core/Scanning` | `CategoryScanner` protocol, `ProjectWalker` (parallel `TaskGroup` walk with pruning), the `ScanEngine` actor and one scanner per category. |
| `Core/Safety` | `GlobMatcher` (exclusions) and `PathGuard`, the single gate for every file operation. |
| `Core/Cleanup` | `CleanupService` actor (trash / delete / move, dry run) and the JSON Lines `CleanupLog`. |
| `Core/Settings` | `SettingsData` (Codable) plus default scan-root detection. |
| `Yokoi/App` | App entry, `AppModel`, `ScanStore` (single source of truth), `SettingsStore`, platform helpers. |
| `Yokoi/ViewModels` | One `@Observable` view model per screen. |
| `Yokoi/Views`, `Theme` | Screens, confirmation sheet, design-system components, palette (asset catalog + `Theme`). |
| `YokoiTests` | Swift Testing suites against a throwaway fixture home folder. |

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
- Every cleanup is appended to `~/Library/Application Support/Yokoi/cleanup.log` (JSON Lines:
  batch, timestamp, action, path, size, Trash location of each item).
- Cache cleanup removes a cache folder's *contents*, never the folder. No telemetry. The only network
  traffic is package managers checking for updates, and only when you click "Check for Updates".

## Status

Built: Dashboard, node_modules, Build Artifacts, Caches (+ Trash, installers, AI models, unavailable
simulators, local Time Machine snapshots), Big Files, Screenshots (+ daily auto rule), **Applications**
(uninstall + `~/Library` leftovers), **External Drives** (drive Trash, `.DS_Store`, `._` files, include a
drive in scans), **Package Managers** (npm/pnpm/brew/casks/cargo/pip/gem with confirmed update/uninstall),
confirmation sheet, Put Back (undo from the log), open-project blocking, menu bar helper, scheduled scans,
launch at login, notifications, Settings, **Docker** (unused images, build cache, dangling volumes via `docker`),
**Android** (AVDs, system images, SDK and build caches, Gradle wrapper dists), the **`yokoi` CLI** and **App Intents**.

Extra safety added with these:
- Personal data is hard-blocked regardless of roots: Keychains, Mail, Messages, iCloud Drive
  (`Mobile Documents`), `CloudStorage`, Safari, Calendars, Photos libraries, and the top-level home folders themselves.
- Nothing is cleaned while a running process uses it (project open in Xcode/Unity/Unreal, `node` cwd,
  running app). Checked when the sheet opens and again right before acting.
- Command-line tools run without a shell, arguments passed literally; `sudo`, `su`, `osascript` and shells
  are refused outright.

## Command line and Shortcuts

- `Core/CLI/CommandLineTool.swift`: the `yokoi` command. `Yokoi/App/YokoiApp.swift` has a custom `@main` (`Entry`)
  that runs it instead of the app when the binary is invoked as `yokoi` (a lowercase symlink) or with a known
  subcommand (`Yokoi scan --json`). Other arguments, such as Xcode's `-NSDocumentRevisionsDebugMode`, start the app.
- `Core/Scanning/ScanReport.swift`: the headless, read-only scan both the CLI and Shortcuts use. Its totals follow
  `ScanStore.total` so the numbers match the dashboard.
- `Yokoi/App/Intents.swift`: App Intents (scan, free space, open a screen) and the `AppShortcutsProvider`.
  Navigation from an intent goes through `IntentRouter`, which waits for `AppModel` if the window isn't up yet.

None of these can delete. Cleaning always goes through the confirmation sheet.

## Releasing

`scripts/release.sh` archives with the Developer ID certificate, exports, verifies the hardened runtime, builds a DMG,
notarizes it with `notarytool` and staples it. One-time setup is at the top of the script.
`SKIP_NOTARIZE=1` stops after signing.

## README screenshots

Screenshots come from **demo mode**: the real app, filled with sample data. It never scans, deletes, runs tools,
or reads your settings, scan cache or cleanup log. To regenerate them:

```sh
Yokoi.app/Contents/MacOS/Yokoi -YokoiDemo YES -ApplePersistenceIgnoreState YES -DKSnapshotDir /tmp/shots
# then copy /tmp/shots/*.png into assets/readme/screenshots/ (resize to 1600 px wide: sips -Z 1600 *.png)
```

## App icon

The icon comes from `assets/ui/yokoi-logo.jpg`. After changing the logo, regenerate every size with:

```sh
swift scripts/make-icon.swift assets/ui/yokoi-logo.jpg Yokoi/Assets.xcassets/AppIcon.appiconset assets/readme/icon.png
```
