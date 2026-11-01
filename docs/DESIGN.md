# Yokoi: UI Design Spec (mock content only)

## Direction
Dark-first, native macOS developer tool. Translucent sidebar, a violet→cyan accent, monospace for every path, size, version and command. Category colors double as language/tool badges. It should feel close to Xcode, Raycast and Linear.

## Color palette
| Token | Hex | Use |
|---|---|---|
| bg.window | #0E1016 | Main content background |
| bg.sidebar | #1E212E → #141620 (92%) | Sidebar (`.sidebar` material) |
| surface.card | white 3.5% → 1.5% | Cards, with a 1px white 7% stroke |
| text.primary | #E6E8EE | |
| text.secondary | #7D8597 | Labels, metadata |
| text.tertiary | #5E6578 | Section headers |
| accent | #7C5CFF (grad #8B6CFF→#6D4CF5) | Selection, primary buttons, checkboxes |
| accent.2 | #22D3EE | Gradients, secondary data |
| danger | #F0565E → #D63A44 | Delete / Clean |
| success | #34D399 | Freed space, "safe", up to date |
| warning | #F59E0B | Stale, outdated, review |
| info | #60A5FA | Xcode, Yarn |
| Badges | Rust #F97316 · Python #FACC15 · Unity #A78BFA · .NET #C084FC · Unreal #E6E8EE · Gradle #34D399 · Swift #F87171 · Go #22D3EE | 13% fill, 27% inner stroke |

## Typography
- UI: SF Pro (Inter in the mocks). Title 15/650, body 13/400–550, label 11.5, section 10.5 uppercase with +0.08em tracking.
- Mono: SF Mono / JetBrains Mono for paths (11.5), sizes (12/500, right-aligned, `.monospacedDigit()`), versions, commands and KPIs (20–26/700).

## Spacing and shape
4-pt grid. Content padding is 20/22. Card gap is 16. Rows are 38pt (30 in dense grouped lists). Corner radii: window 12, card 12, button/field 7, badge 7, pill 5. The window is 1280×820, the sidebar 232pt and the toolbar 52pt.

## Components
Sidebar nav item (icon, label, mono count badge), disk-usage capsule, KPI tile, donut ring + legend with mini bars, Table with checkbox column, grouped section rows, status pill, language badge, segmented control, threshold slider with tick labels, thumbnail grid cell (selection ring + glass caption), action inspector panel (radio cards, auto-rule toggle), terminal command strip, bottom selection bar (count · size · Reveal · destructive CTA), confirmation sheet (size/items stats, path preview, Trash vs Permanent radio), Settings rows (toggle, segmented, pop-up).

## SwiftUI notes
- `NavigationSplitView` with a `List(selection:)` sidebar, `.listStyle(.sidebar)`, `.navigationSplitViewColumnWidth(232)`, and the disk capsule in `.safeAreaInset(edge: .bottom)`.
- `.preferredColorScheme(.dark)` by default. Set `.tint(Color("Accent"))`. Use `.windowStyle(.hiddenTitleBar)` + `.toolbar` with `.searchable` (⌘K).
- Lists use `Table` with `TableColumn` sorting via `KeyPathComparator`, plus `Set<ID>` selection. Group with `Section` / `DisclosureGroup` for Build Artifacts and Caches.
- Cards use `RoundedRectangle(12).fill(.white.opacity(0.03)).overlay(stroke .white.opacity(0.07))`. Overlays and HUDs use `.ultraThinMaterial`.
- Ring: `Circle().trim(from:to:)` per category, `.stroke(style: StrokeStyle(lineWidth: 18, lineCap: .butt))`, or Swift Charts `SectorMark(innerRadius: .ratio(0.78))`.
- Confirmation: `.sheet` (drops from toolbar) or `.confirmationDialog`. Trash uses `FileManager.trashItem`. Permanent uses `removeItem`, behind a red label.
- Big Files: `Slider` on a log scale. Reveal uses `NSWorkspace.shared.activateFileViewerSelecting`.
- Screenshots: `LazyVGrid(.adaptive(min:150))`, `QLThumbnailGenerator`, and `NSOpenPanel` (canChooseDirectories) for "Move to folder…". The auto rule runs on a background schedule.
- Package managers: shell out via `Process` (`npm outdated -g --json`, `brew outdated --json=v2`, `cargo install --list`, `pip list --outdated --format=json`, `gem outdated`). Always confirm before uninstalling.
- Menu bar helper: `MenuBarExtra("Yokoi", systemImage: "internaldrive")`, plus `SMAppService.mainApp` for launch at login.
- Scheduling: `NSBackgroundActivityScheduler`. Exclusions are stored as globs. Ask for Full Disk Access on first run.

## SF Symbols (sidebar)
| Item | Symbol |
|---|---|
| Dashboard | `gauge.with.dots.needle.67percent` |
| node_modules | `shippingbox` |
| Build Artifacts | `hammer` |
| Caches | `archivebox` |
| Big Files | `doc.badge.ellipsis` / `externaldrive.badge.exclamationmark` |
| Screenshots | `camera.viewfinder` |
| Package Managers | `cube.box` |
| Settings | `gearshape` |
Actions: `arrow.clockwise` (Rescan), `trash` (Clean), `magnifyingglass` (Reveal), `arrow.up.circle` (Update), `folder.badge.plus` (Move to folder).

## Files
`01–09-*.html/png` are per-screen mockups rendered at 2× (2880×1920), `00-contact-sheet.png` shows all screens, and `gen.py` is the generator.
