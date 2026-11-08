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
| `Core/Models` | Categories, `ArtifactRule` table, `CacheLocation` table, item types, package-manager model. |
| `Core/Scanning` | `CategoryScanner` protocol, `ProjectWalker` (parallel `TaskGroup` walk with pruning), the `ScanEngine` actor and one scanner per category. |
| `Core/Safety` | `GlobMatcher` (exclusions) and `PathGuard`, the single gate for every file operation. |
| `Core/Cleanup` | `CleanupService` actor (trash / delete / move, dry run), the JSON Lines `CleanupLog`, `CleanSelection` and `HeadlessClean`. |
| `Core/Platform` | `ProcessRunner`, `ToolActions` (cleanups done through a tool) and `InUseDetector`. |
| `Core/CLI` | The `yokoi` command. |
| `Core/Settings` | `SettingsData` (Codable) plus default scan-root detection. |
| `Yokoi/App` | App entry, `AppModel`, `ScanStore` (single source of truth), `SettingsStore`, platform helpers. |
| `Yokoi/ViewModels` | One `@Observable` view model per screen. |
| `Yokoi/Views`, `Theme` | Screens, confirmation sheet, design-system components, palette (asset catalog + `Theme`). |
| `YokoiTests` | Swift Testing suites against a throwaway fixture home folder. |

## Adding a programming language / engine

Add one entry to `ArtifactRule.all` in `Core/Models/ArtifactRule.swift`: markers, target folders,
opt-in flags and a restore hint. Badge color and name go in `Ecosystem` (`Core/Models/Categories.swift`).

## Translations

Every string the app shows lives in one file, [`Yokoi/Localizable.xcstrings`](../Yokoi/Localizable.xcstrings)
(an Xcode String Catalog). Each entry has the English text, a note for translators and every language's translation.
Yokoi is in English, Japanese, Simplified and Traditional Chinese, Korean, Spanish, Portuguese (Brazil), German,
French, Arabic and Hebrew. The first translations were machine drafts, so every string is still marked
**Needs Review**.

### Adding a language

1. Open `Yokoi.xcodeproj` and select `Localizable.xcstrings`.
2. Click **+** under the language list and pick the language. Xcode adds it to the project.
3. Translate each string. Strings with a count ask for every plural form your language needs ("1 file", "5 files").
   Anything left empty falls back to English, so a partial translation still works.
4. Run it in that language and check the screens (see below), then open a pull request.

The file is JSON and can be edited without Xcode, but it's large and plural entries are nested, so Xcode is much easier.

### Reviewing a language

Fix what reads oddly, then right-click the string and choose **Mark as Reviewed**. A pull request that reviews part of a
language is welcome too.

### What to keep as is

- Product and tool names: Yokoi, npm, Homebrew, Xcode, Docker, Time Machine…
- Anything in backticks, paths, file names, commands and `node_modules`.
- Placeholders (`%@`, `%lld`, `%1$@`) and `**bold**` markers. You can reorder placeholders with positions (`%2$@ %1$@`).
- macOS terms (Trash, Put Back, Login Items, Full Disk Access): use the exact words macOS uses in your language.

Keep buttons and labels about as short as the English: many sit in tight spaces.

### Previewing a language

Run with a language for one launch, without changing your settings (in Xcode: **Product › Scheme › Edit Scheme ›
Run › Options › App Language**, or from the terminal):

```sh
Yokoi.app/Contents/MacOS/Yokoi -AppleLanguages "(ja)"
```

To check every screen at once, add it to the demo snapshot command (Debug build):

```sh
Yokoi.app/Contents/MacOS/Yokoi -YokoiDemo YES -ApplePersistenceIgnoreState YES -DKSnapshotDir /tmp/shots -AppleLanguages "(ja)"
```

Arabic and Hebrew mirror the whole layout. `LayoutDirection` in `Yokoi/App/YokoiApp.swift` turns this on when Yokoi's
language reads right to left, even if the Mac's doesn't.

### Writing new UI text

- SwiftUI string literals (`Text("Scan")`, `Button("Clean")`) and `LocalizedStringKey` parameters are translated
  automatically. Use `String(localized: "…", comment: "…")` for strings built in code, with a comment that says where
  the string appears and what each placeholder is.
- Interpolate counts as numbers (`"\(n) items"`) so the catalog can add plural forms. Don't build plurals by hand.
- Data that shouldn't be translated (paths, project names, tool output) goes through `Text(verbatim:)` or the
  `verbatim:` initializers on Yokoi's own components.
- Build once: Xcode adds new strings to the catalog, where they show as untranslated.
- The `yokoi` command line, the cleanup log and `HeadlessClean` stay English, since scripts read them. The CLI forces
  English at launch (`Entry.main`).

## Safety model (as built)

- Move to Trash by default. In the app, permanent delete is only offered in the confirmation sheet, with an extra
  "I understand" tick every time.
- Every path goes through `PathGuard`: it must be strictly inside that **category's** allowed roots,
  not excluded, not inside `.git`, and not under `/System`, `/Library`, `/usr`, `/var`, Homebrew's or
  MacPorts' install trees… It checks both the literal path and the path with parent symlinks resolved.
  Apple's own app data under `~/Library` (`Containers/com.apple.*`, `Preferences/com.apple.*`…) is
  blocked too, and an `AppItem` marked as an Apple app or Yokoi itself is refused by `CleanupService`
  regardless of which screen built the entry.
- Scan and big-file locations can't be `/`, a folder above home, or a protected system folder
  (`ScanRootPolicy`), since a location is also the boundary cleanup may reach.
- Right before each operation the item is checked again at its parent's real location: permanent
  delete opens the parent and removes relative to it (`removefileat`); trash, move and put back
  re-resolve the parent with `realpath` first, so a parent swapped for a symlink after the check is noticed.
- `~/Library/Application Support/Yokoi` is created `0700` and its files (`cleanup.log`, `last-scan.json`,
  `scan-index.json`) `0600`: they list the user's files by name.
- External drives that `tmutil destinationinfo` lists as backup destinations are locked, in addition to the
  on-disk markers (APFS backup disks have none at the mount root).
- Projects changed in the last 14 days (configurable) start unchecked. The sheet holds them back
  unless you tick "Include them anyway".
- Dry run (Settings → Safety) logs and reports what would happen without touching anything.
- Every cleanup is appended to `~/Library/Application Support/Yokoi/cleanup.log` (JSON Lines:
  batch, timestamp, action, path, size, Trash location of each item).
- Cache cleanup removes a cache folder's *contents*, never the folder. No telemetry. The only network
  traffic is package managers checking for updates when you click "Check for Updates", and Sparkle's app update
  check (`Yokoi/App/Updater.swift`), which runs only if the user allowed it or chose "Check for Updates…".
  Debug builds and demo mode never start Sparkle.

## Status

Built: Dashboard, Build Artifacts, Caches & Tooling (+ Trash, installers, AI agents, AI models, unavailable
simulators, local Time Machine snapshots), Big Files, **Duplicates**, **Downloads**, Screenshots (+ daily auto rule), **Applications**
(uninstall + `~/Library` leftovers), **External Drives** (drive Trash, `.DS_Store`, `._` files, include a
drive in scans), **Package Managers** (17 managers with confirmed update/uninstall, and project `node_modules` under npm),
confirmation sheet, Put Back (undo from the log), open-project blocking, menu bar helper, scheduled scans,
launch at login, notifications, Settings, **Docker** (unused images, build cache, dangling volumes via `docker`),
**Android** (AVDs, system images, SDK and build caches, Gradle wrapper dists), the **`yokoi` CLI**, **App Intents**, auto-clean
and **11 languages** with right-to-left layout ([Translations](#translations)).

Extra safety added with these:
- Personal data is hard-blocked regardless of roots: Keychains, Mail, Messages, iCloud Drive
  (`Mobile Documents`), `CloudStorage`, Safari, Calendars, Photos libraries, and the top-level home folders themselves.
- Nothing is cleaned while a running process uses it (project open in Xcode/Unity/Unreal, `node` cwd,
  running app or agent, booted emulator). Checked when the sheet opens and again right before acting.
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

Shortcuts can't delete. `yokoi scan` can't either.

## What needs an administrator

Yokoi never runs anything as root. When a delete fails on permissions, `CleanupOutcome.adminCommand` builds a
`sudo rm -rf --` command for the user to read and run, shown in the outcome details and by `yokoi clean`. Only paths that
passed `PathGuard` can get there, and `CleanupService.needsAdministrator` leaves out what `sudo` wouldn't fix: macOS privacy
refusals and immutable or SIP-restricted items. Paths are always single-quoted (`^` is a wildcard under zsh's
EXTENDED_GLOB), and a path with control or text-reordering characters is never put in a command, because it can't be read
faithfully.

## Cleaning with nobody watching

`yokoi clean` (`Core/Cleanup/HeadlessClean.swift`) and scheduled auto-clean (`BackgroundScheduler.runAutoClean`) have no
confirmation sheet, so these hold for both:

- `CleanSelection` is the only way they pick items, and Smart Select uses it too. `CleanSelection.unattended` drops anything
  `permanentOnly`, so neither can empty the Trash, whatever safety level that location has.
- `InUseSnapshot.split` holds back what a running process uses. Check here before adding another way to start a cleanup:
  `CleanupService` doesn't do it.
- `CleanupService` still applies `PathGuard` to every path, and the Dry run setting still holds.
- The CLI refuses to scan or clean as root, or with launchd as its parent: `open Yokoi.app --args …` would otherwise run with
  the app's Full Disk Access (`CommandLineTool.refusal`). Text output goes through `PathFormat.printable`.
- `yokoi clean` only previews without `--yes`, and `--dry-run` beats `--yes`. It takes node_modules, build artifacts and
  caches only. Auto-clean is off by default, needs automatic scans on, and uses the Trash unless `autoCleanPermanent` is set.

## Duplicates

`DuplicateScanner` compares files of 1 MB or more in the big-file locations: by size, then a hash of each file's
first and last 64 KB, then SHA-256 of the whole file. It reads every real duplicate in full, so it only runs when asked
for. `CleanCategory.routine` leaves it out of full and background scans, and `ScanReport.scannable` leaves it out of the
CLI and Shortcuts. Its bytes aren't in the reclaimable total, because they're the same files as Big files and Downloads.

- Each copy is its own item (`DuplicateFile`), so no cleanup entry can stand for a whole group.
- `CleanupService` runs each entry's `KeepCheck` right before removing it. The copy is hashed again and must still match,
  and so must another copy that isn't in the same cleanup. A copy kept for several others is read once per cleanup. This
  holds whatever the UI sends, and it means a cleanup reads what it removes, which takes a while for big files.
- Hardlinks count as one file. Files with their data in the cloud (`SF_DATALESS`) are skipped, because reading one
  downloads it. Groups of clones that would free nothing aren't reported. Cloud-only and unreadable files are listed
  under "not checked" (`ScanProgress.skipped`).
- "Choose Folder…" scans one folder (`ScanContext.duplicateFolder`). It must be in a big-file location, since those are
  what cleanup may reach. Groups that are all inside git work trees are shown for a chosen folder, and "Select Extras"
  still leaves repository copies to be ticked by hand.
- Copies inside a git work tree are tagged, kept first, and never picked by "Select Extras". A group with every
  copy inside work trees isn't shown unless a folder was chosen: on a real home folder that's nearly all of them, and it's build output and
  vendored code.

## AI agents

The AI agents section of Caches & Tooling is ordinary `CacheLocation` entries, with a few rules of its own:

- Only what an agent rebuilds is Safe, because Safe is what auto-clean takes. Anything holding history is Review.
- Left out on purpose: logins, settings, skills and plugins, Codex sessions (indexed in SQLite, so removing the files
  alone leaves the index wrong) and Cursor's `state.vscdb` (its chats live inside).
- `breakdown` decides how a location splits into rows. `.claudeProjects` lists only what's known to be a session, so
  `memory` and anything a later version adds beside it stay. `.unlinkedDownloads` leaves out whatever a link in the
  sibling `bin` folder points at, and offers nothing when there's no such link.
- `usedByApps` entries with a `/` are path fragments, matched against what processes run and work in. The Claude Code
  binary's process is named after its version and npm installs run as `node`, so a name alone can't find them.

Tests are in `YokoiTests/AgentCleanupTests.swift`.

## Incremental rescans

Rescans reuse the last scan's measurements for anything FSEvents says hasn't changed. On a real home folder this
takes a full scan from about 14 s to about 3 s.

- `Core/Scanning/ChangeJournal.swift`: replays FSEvents history since a saved event ID and returns the folders that
  changed (`ChangeSet`). It returns `nil` (measure everything) if IDs wrapped, a root moved, or there's no answer.
- `Core/Scanning/ScanIndex.swift`: the saved measurements, in `scan-index.json` next to `last-scan.json`, shared by the
  app, the CLI and Shortcuts. A value is reused only if nothing at or under its path changed and the path's inode
  is the same (a folder swapped in by a move has a new inode). Scanners go through `ScanContext.measure` and
  `ScanContext.lastTouched`. Big files are cached per folder, up to `BigFileScanner.cachedDepth` levels below each
  location.
- The project walk itself (finding `node_modules` and build folders) always runs; it only lists folders.
- Everything is measured from scratch on the first scan, when the FSEvents database or volume changes, when the
  exclusions or big-file floor change (big files only), and every 7 days (`ScanIndex.maxAge`). The 7-day rescan
  catches small drift such as APFS settling the allocated size of files written just before a scan.
- Other volumes (`/Volumes/...`) are always measured in full.

## Releasing

`scripts/release.sh` archives with the Developer ID certificate, exports, verifies the hardened runtime, builds a DMG,
notarizes it with `notarytool` and staples it. One-time setup is at the top of the script.
`SKIP_NOTARIZE=1` stops after signing.

After notarizing it signs the DMG with the Sparkle key and writes `build/release/appcast.xml`, which is attached to
the release. Installed copies read `releases/latest/download/appcast.xml` (`SUFeedURL` in `Config/Yokoi-Info.plist`)
and only offer an update whose **build number** is higher than theirs, so bump `CURRENT_PROJECT_VERSION` every
release (the workflow refuses a tag that doesn't). The Sparkle key is in the login keychain under the account
`yokoi`; its public half is `SUPublicEDKey`. Losing the private key means installed copies can't be updated
automatically any more, so keep a backup:
`build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account yokoi -x sparkle-private.key`.

The DMG window (background, icon positions, volume icon) is laid out by `dmgbuild` from `scripts/dmg-settings.py`,
installed into `build/dmgbuild-venv` on first use from `scripts/dmgbuild-requirements.txt`, whose versions and hashes are pinned (`pip install --require-hashes`). The background is `assets/dmg/background.tiff` (1x + 2x), drawn by
`scripts/make-dmg-background.py`. To change it, edit that script (it needs Pillow), then:
`python3 scripts/make-dmg-background.py && tiffutil -cathidpicheck assets/dmg/background.png assets/dmg/background@2x.png -out assets/dmg/background.tiff`.
Icon positions are set in both scripts and must match.

### From GitHub Actions

`.github/workflows/release.yml` runs the same script when a version tag is pushed, then publishes the release:

```sh
# bump MARKETING_VERSION and CURRENT_PROJECT_VERSION first; the tag must match
git tag v1.2 && git push origin v1.2
```

The workflow has two jobs. `verify` checks the tag against the version and runs the tests; it has no secrets and
read-only access. `release` then signs, notarizes and publishes. It runs in the `release` **environment**, which must
require a reviewer: the job waits until someone approves it in the Actions tab. Set this up once:

1. Settings › Environments › New environment `release` › **Required reviewers**: add yourself. Under *Deployment
   branches and tags*, allow only tags matching `v*`.
2. Settings › Rules › Rulesets › New tag ruleset: target `v*`, restrict creations, updates and deletions, and bypass
   only for repository admins. Then nobody else can push a tag that starts a release.
3. Put the secrets below in the `release` environment (not as repository secrets), so only that job can read them.

Both jobs run on GitHub-hosted runners with a pinned image (`macos-26`) and Xcode version; change them together, in
`test.yml` as well. Never point `release` at a self-hosted runner: it writes signing keys to `$RUNNER_TEMP`.

The secrets (in the `release` environment):

| Secret | Value |
|---|---|
| `DEVELOPER_ID_P12` | The Developer ID Application certificate and private key, exported from Keychain Access as `.p12`, then `base64 -i cert.p12 \| pbcopy` |
| `DEVELOPER_ID_P12_PASSWORD` | The password chosen when exporting |
| `NOTARY_API_KEY` | The full text of the App Store Connect API key (`AuthKey_XXXX.p8`) |
| `NOTARY_KEY_ID` | That key's ID |
| `NOTARY_ISSUER_ID` | The issuer ID shown above the keys list in App Store Connect |
| `SPARKLE_PRIVATE_KEY` | The Sparkle update-signing key: `generate_keys --account yokoi -x key.txt`, then paste the file's contents |
| `HOMEBREW_TAP_TOKEN` | A fine-grained personal access token with **Contents: read and write** on `indieocean/homebrew-tap` only. The workflow uses it to set the new version and SHA-256 in `Casks/yokoi.rb`; without it the step warns and the cask has to be bumped by hand |

The certificate goes into a temporary keychain and the keys into temporary files, all deleted at the end of the run.
`.github/workflows/test.yml` runs the tests (unsigned) on pushes to `main` and on pull requests.

## README screenshots

Screenshots come from **demo mode**: the real app, filled with sample data. It never scans, deletes, runs tools,
or reads your settings, scan cache or cleanup log. To regenerate them, from a Debug build (`-DKSnapshotDir` is debug-only):

```sh
Yokoi.app/Contents/MacOS/Yokoi -YokoiDemo YES -ApplePersistenceIgnoreState YES -DKSnapshotDir /tmp/shots
# then copy /tmp/shots/*.png into assets/readme/screenshots/ (resize to 1600 px wide: sips -Z 1600 *.png)
# and make the site's copies: cwebp -q 82 -m 6 assets/readme/screenshots/NAME.png -o site/img/NAME.webp
```

Look at each image before committing. A capture can come out with the window shifted, which cuts off the sidebar.
`caches-items.png` is also written but isn't used. The demo video keeps its own copies in `video/public/`.

The cleanup animation GIF (`assets/readme/cleaning.gif`) is recorded the same way, from a Debug build:

```sh
scripts/make-cleanup-gif.sh path/to/Debug/Yokoi.app   # needs ffmpeg; WIDTH= and SPEED= to tweak
```

## Marketing site

`site/` is plain HTML, CSS and JS with no build step. `.github/workflows/pages.yml` publishes it to GitHub Pages
(<https://indieocean.github.io/yokoi/>) on every push to `main` that changes it. `main.js` fills every `data-version`
element from the latest GitHub release, so the version written in `index.html` is only a fallback.

The Homebrew command appears in the README and twice in `site/index.html`. Change them together.

## Demo video

`video/` is the [Remotion](https://www.remotion.dev) source of the demo video. See `video/README.md` for its commands.

## App icon

The icon comes from `assets/ui/yokoi-logo.jpg`. After changing the logo, regenerate every size with:

```sh
swift scripts/make-icon.swift assets/ui/yokoi-logo.jpg Yokoi/Assets.xcassets/AppIcon.appiconset assets/readme/icon.png
```
