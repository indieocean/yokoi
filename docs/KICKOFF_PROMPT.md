# Yokoi — Build Kickoff Prompt

> Historical: the prompt that started the MVP, kept as written. For the current spec see [PRD.md](PRD.md), and for the code see [DEVELOPMENT.md](DEVELOPMENT.md).

You are a senior macOS engineer. Build **Yokoi**, a native SwiftUI macOS app that keeps a MacBook tidy for software engineers and game developers. The full spec is in `PRD.md`, the visual system is in `DESIGN.md`, and the target screens are the PNGs `01-dashboard.png` through `09-settings.png`. Read all three before writing code, and treat the PNGs as the visual source of truth.

## Scope for this first pass (MVP from PRD.md)
1. **Dashboard**: disk usage ring, reclaimable space by category, Scan and Clean actions, recent cleanups.
2. **node_modules**: find every `node_modules` folder under the scan roots. Show project, path, size, last touched, and a stale/active tag. Support multi-select and delete.
3. **Build artifacts**: detect build outputs per language/engine, matching only when that project's marker file exists (e.g. `target/` only next to `Cargo.toml`; Xcode DerivedData; `.build/` for Swift PM; Gradle `build/` and `.gradle/`; Python `__pycache__` and venvs; Unity `Library/` and `Temp/` next to `ProjectSettings/`; Unreal `Intermediate/`, `Saved/`, `DerivedDataCache/` next to a `.uproject`). Group results by language with colored badges.
4. **Caches**: user caches plus npm, yarn, pnpm, Homebrew, CocoaPods, pip, cargo registry, Xcode archives and simulators, each tagged Safe, Re-download, or Review.
5. **Big files**: size threshold slider, file-type filter, sortable table, Reveal in Finder, Move to Trash.
6. **Screenshots**: grid of Desktop screenshots. Let the user either move them to a folder they pick (default `~/Pictures/Screenshots/YYYY/MM/`) or delete them.
7. **Confirmation sheet**: shows total size, item count, a path preview, and Move to Trash (default) or Delete permanently.
8. **Settings**: scan roots, excluded folders, safety defaults.

Package managers (npm -g, pnpm, brew, casks, cargo, pip, gem) are **v1.1**. Stub the sidebar item and the data model, but don't run any CLI yet.

## Tech requirements
- Swift 5.10+, SwiftUI, macOS 14+, built from an Xcode project named `Yokoi`.
- `NavigationSplitView` with a translucent sidebar, and `Table` for lists. Use Swift Charts for the dashboard ring.
- Swift Concurrency for scanning: an `actor`-based scanner, `TaskGroup` for parallel directory walks, cancellable, with live progress. Use `FileManager` enumerators and `URLResourceValues` (`totalFileAllocatedSize`, `contentModificationDate`) for sizes and dates.
- Architecture: one `Scanner` protocol per category (`NodeModulesScanner`, `BuildArtifactScanner`, `CacheScanner`, `BigFileScanner`, `ScreenshotScanner`), a `CleanupService` that does trash, delete, and move, and an `@Observable` view model for each screen.
- Pattern rules live in one data-driven table (`ArtifactRule`: name, language, marker file, target globs, safety level), so adding a language is a single new entry.
- Not sandboxed (direct distribution). Detect missing Full Disk Access and show an onboarding prompt.

## Safety rules (non-negotiable)
- Move to Trash by default. Permanent delete always needs the confirmation sheet.
- Never delete anything outside the scan roots, or inside excluded folders, `/System`, or `/Library`.
- Warn before touching a project that changed in the last 14 days.
- Write every cleanup to a local log (`~/Library/Application Support/Yokoi/cleanup.log`) with path, size, action, and timestamp.
- Include a Dry Run toggle that shows what would happen without changing anything.
- No network calls and no telemetry.

## Design
Follow `DESIGN.md` exactly: dark-first, violet-to-cyan accent, glassy cards, JetBrains Mono (falling back to SF Mono) for paths, sizes, and versions, colored badges per language or tool, and red only for destructive actions. Put the palette in an asset catalog and a `Theme` type.

## How to work
1. Set up the Xcode project, folder structure, `Theme`, and the sidebar shell with empty screens. Make sure it builds and runs.
2. Build the scanner layer and unit tests first, running them against a temporary fixture directory that mimics real projects.
3. Build the screens one at a time in the order above, matching each PNG.
4. Wire up `CleanupService` and the confirmation sheet last, with tests for Trash, move, and exclusions.
5. After each step, build, run the tests, and give a short summary of what's done and what's next. Don't move on while the build is red.

Start with step 1 now.
