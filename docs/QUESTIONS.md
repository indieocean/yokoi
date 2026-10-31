# Yokoi — open questions & decisions log

Questions that came up while building the MVP unattended. Each has the decision I made so work
could continue. Answer or override any of them and I'll adjust.

## Spec conflicts I resolved

1. **Active-project window: 14 vs 30 days.** The kickoff says warn for projects changed in the last
   14 days; the PRD and the Settings mockup say 30. **Decision:** default 14 (kickoff is newer),
   editable in Settings → Safety ("Protect projects touched within").
2. **Xcode simulators and archives in MVP?** The kickoff includes them; the PRD lists them as v1.1.
   **Decision:** included as **Review** level (unchecked by default). Simulators are listed as the
   whole `CoreSimulator/Devices` folder. Detecting only *unavailable* simulators needs
   `xcrun simctl`, which the MVP doesn't run. OK to run `simctl` in v1.1?
3. **Tool commands for caches** (`brew cleanup`, `npm cache clean`…, PRD FR-C3). The MVP runs no CLI,
   so caches are cleaned by removing the folder's *contents* (the folder itself is kept).
4. **Log format.** `~/Library/Application Support/Yokoi/cleanup.log` is JSON Lines: one record per
   cleaned item with batch id, timestamp, action, path, size, the Trash location of each moved item
   (for v1.1 undo) and a dry-run flag.
5. **"Default delete action: Permanent" vs "Permanent delete needs an explicit choice each time".**
   **Decision:** the setting preselects the radio in the confirmation sheet, but permanent delete
   always needs an extra "I understand" tick in the sheet. Trash stays the shipped default.

## Safety design choices worth a look

6. **Big files live outside the scan roots** (`~/Downloads`, `~/Movies`…), but the rule is "never
   delete outside the scan roots". **Decision:** a separate *Big file locations* list (default `~`)
   and per-category allowed roots: node_modules/artifacts may only touch scan roots (+ DerivedData and
   go-build), caches only the known cache folders, big files only the big-file locations, screenshots
   only the screenshot folder. Is `~` the right default for big files?
7. **`~/Library/Caches/com.apple.*` is never touched** by "User caches" (Apple's own caches can be
   in use and are mostly protected without Full Disk Access). OK?
8. **Hard links** are not de-duplicated when sizing (PRD says "counted once"). Needs `lstat` link counts
   per file; deferred because it slows the walk. Sizes can be slightly high for pnpm-style hardlinked
   `node_modules`. Want this in MVP?
9. **Projects under `~/Library/...` scan roots** (e.g. `~/Library/Developer`) are treated as cleanup
   locations, not walked for projects, because walking CoreSimulator trees is slow and noisy.

## Product questions

10. **Bundle identifier / signing.** Using `com.yokoi.Yokoi`. The app target is now signed with the
    "Apple Development" certificate on this Mac (team `3P2Q7V729Y`), so privacy permissions and Full Disk Access
    survive rebuilds (ad-hoc signing made macOS re-ask on every build). Shipping outside the Mac App Store
    still needs a **Developer ID Application** certificate plus notarization. Which team should own releases?
11. **JetBrains Mono** isn't installed on this Mac and I didn't download it. The app uses it when
    installed and falls back to SF Mono. Bundle the font (OFL licensed) in the app?
12. **Default scan roots.** PRD says `~/dev`, `~/work`, `~/games`, `~/Library/Developer` "plus folders
    found on first run". I also auto-detect `~/Developer`, `~/Projects`, `~/code`, `~/src`, `~/repos`,
    `~/Documents/Projects`, `~/Documents/GitHub`… and fall back to `~/Documents` if none exist.
13. **JS `dist/`** is treated as opt-in (some repos commit or publish it). Same for Unreal `Binaries/`
    and `Saved/Config` (per FR-B4).
14. **Schedule, menu bar helper, launch at login, auto rule** are v1.1. They're shown in Settings and
    Screenshots but disabled with a "v1.1" tag. Hide them instead?
15. **Toolbar "Pause" button** on the dashboard mockup: a scan can be cancelled, not paused/resumed.
    The button reads "Stop" while scanning.
16. **Unity `*_BackUpThisFolder_ButDontShipItWithYourGame`** (IL2CPP build backup, found in your
    `kawaiidoku` project) is detected as an **opt-in** Unity target. Unity recommends keeping it for crash
    symbolication. Fine as opt-in?
17. **Dashboard "Reclaimable" includes Review-level caches** (e.g. ~40 GB of simulator devices on this Mac),
    so the headline number is large. "Clean · size" (Smart Select) only uses Safe/stale items. Should the
    headline exclude Review items?
18. **Git.** I ran `git init` and added a `.gitignore`, but made no commits (you didn't ask for any).
    Want me to commit the MVP?

## What I couldn't verify unattended

- **Real deletions through the UI.** Trash, delete, move, exclusions and dry run are covered by unit tests
  against a fixture folder. I didn't click "Clean" on your real files.
- **Screenshots grid with real thumbnails.** Your Desktop has no screenshots right now, so I only saw
  the empty state. Detection is unit-tested.
- **Full Disk Access flow.** The ad-hoc-signed debug build doesn't have FDA, so the banner and onboarding
  show. Granting it in System Settings should make them go away (the app re-checks on activation).

## Round 2 (Applications, external drives, v1.1 features)

19. **Apple apps can't be uninstalled** (bundle id `com.apple.*`), including Xcode. Want Xcode removable?
20. **App Store apps owned by root** may fail to move to the Trash without admin rights. Yokoi never
    escalates; the failure is shown and you can use Finder instead. OK?
21. **Dusty's "protected Documents/Desktop"**: not applied as a blanket ban because your projects live in
    `~/Documents/Projects`. Documents/Desktop/Downloads are only touched inside folders you've added.
22. **Local Time Machine snapshots**: `tmutil deletelocalsnapshots` may need admin rights; Yokoi won't use
    sudo and shows the command to run yourself if it fails.
23. **External drive junk** (`.DS_Store`, `._*`, drive Trash) is delete-only (moving to Trash on an external drive
    frees nothing). `._` files are only offered on non-Mac formats (exFAT/FAT/NTFS).
24. **Auto-clean Safe caches** (Settings → Schedule) runs without a confirmation sheet after scheduled scans
    when you turn it on. It only ever moves Safe caches to the Trash and logs it. Keep?

### Bugs fixed in this round
- App froze on launch: the menu bar helper's on/off binding wrote settings on every scene update, which
  re-rendered the scene forever. It now only writes on real changes.
- Scheduled jobs would have crashed: Swift 6 asserted main-thread isolation on a background callback.
- ⌘-number shortcuts would have trapped with 10 screens; capped at ⌘1–⌘9.
