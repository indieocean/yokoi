import AppKit
import Foundation

/// Demo mode (`-YokoiDemo YES`): the real app UI filled with realistic sample data, for README
/// screenshots and recordings. Nothing is scanned, run or deleted, and the user's settings, scan
/// cache and cleanup log are never read or written.
enum DemoData {
    static var isEnabled: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "YokoiDemo")
        #else
        false
        #endif
    }

    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let now = Date()

    static func days(_ n: Double) -> Date { now.addingTimeInterval(-n * 86_400) }
    static func url(_ path: String) -> URL { home.appendingPathComponent(path) }
    static let GB: Int64 = 1_000_000_000
    static let MB: Int64 = 1_000_000

    // MARK: Settings

    /// A throwaway defaults domain so demo runs never touch real settings.
    static func defaults() -> UserDefaults {
        let name = "com.yokoi.demo"
        UserDefaults().removePersistentDomain(forName: name)
        let d = UserDefaults(suiteName: name)!
        var s = SettingsData(scanRoots: [ScanRoot(path: "~/dev"), ScanRoot(path: "~/work"), ScanRoot(path: "~/games", maxDepth: 4),
                                         ScanRoot(path: "~/Library/Developer")])
        s.exclusions = ["~/dev/hunchwell", "**/.git", "~/work/acme/prod-*", "~/Dropbox", "*.keep"]
        s.hasCompletedOnboarding = true
        s.autoScan = true
        s.showInMenuBar = false
        d.set(try? JSONEncoder().encode(s), forKey: "settings.v1")
        return d
    }

    // MARK: Store contents

    static let disk = DiskInfo(name: "Macintosh HD", total: 1_000 * GB, available: 188 * GB)

    static var summary: ScanSummary {
        ScanSummary(date: now.addingTimeInterval(-120), duration: 14.2, filesVisited: 3_100_000, projectCount: 1_284,
                    reclaimable: 0, previousReclaimable: 141 * GB)
    }

    static var nodeModules: [NodeModulesItem] {
        func nm(_ path: String, _ name: String, _ hint: String, _ pm: JSPackageManager, _ size: Int64, _ age: Double) -> NodeModulesItem {
            let project = url(path)
            return NodeModulesItem(url: project.appendingPathComponent("node_modules"), projectURL: project, projectName: name,
                                   frameworkHint: hint, packageManager: pm, size: size, fileCount: Int(size / 14_000), lastTouched: days(age))
        }
        return [
            nm("dev/hunchwell/web", "hunchwell-web", "next 14", .pnpm, 1_420 * MB, 2),
            nm("dev/electron/orbital-launcher", "orbital-launcher", "electron", .npm, 1_180 * MB, 120),
            nm("work/acme/design-tokens", "design-tokens", "monorepo", .pnpm, 846 * MB, 210),
            nm("dev/sandbox/rn-playground", "rn-playground", "expo", .npm, 792 * MB, 380),
            nm("work/acme/api-gateway", "api-gateway", "nestjs", .yarn, 534 * MB, 21),
            nm("games/pixel-forge/editor", "pixel-forge-editor", "vite", .pnpm, 488 * MB, 150),
            nm("dev/personal/blog-astro", "blog-astro", "astro", .bun, 402 * MB, 270),
            nm("dev/oss/cli-scaffold", "cli-scaffold", "tsup", .pnpm, 311 * MB, 1),
            nm("dev/sandbox/svelte-kanban", "svelte-kanban", "sveltekit", .npm, 276 * MB, 400),
            nm("dev/bots/discord-bot", "discord-bot", "node", .npm, 198 * MB, 240),
            nm("dev/practice/leetcode-ts", "leetcode-ts", "ts-node", .npm, 121 * MB, 760),
        ]
    }

    static var artifacts: [ArtifactItem] {
        func a(_ rule: String, _ eco: Ecosystem, _ project: String, _ targets: [String], _ size: Int64, _ age: Double,
               optIn: Bool = false, hint: String = "rebuild") -> ArtifactItem {
            let p = url(project)
            return ArtifactItem(ruleID: rule, ecosystem: eco, projectURL: p, projectName: p.lastPathComponent,
                                targets: targets.map { p.appendingPathComponent($0) }, optIn: optIn, note: nil, isGlobal: false,
                                size: size, fileCount: Int(size / 90_000), lastTouched: days(age), restoreHint: hint)
        }
        let derived = url("Library/Developer/Xcode/DerivedData")
        let goBuild = url("Library/Caches/go-build")
        return [
            a("rust", .rust, "dev/rust/ray-tracer", ["target"], 8_920 * MB, 60, hint: "cargo build"),
            a("rust", .rust, "games/bevy-roguelike", ["target"], 6_310 * MB, 95, hint: "cargo build"),
            ArtifactItem(ruleID: "xcode-deriveddata", ecosystem: .xcode, projectURL: derived, projectName: "All projects",
                         targets: [derived.appendingPathComponent("Orbital-abc")], optIn: false, note: nil, isGlobal: true,
                         size: 14_800 * MB, fileCount: 180_000, lastTouched: nil, restoreHint: "build again in Xcode"),
            a("unreal", .unreal, "games/Orbital", ["Intermediate", "Saved/Logs", "DerivedDataCache"], 5_440 * MB, 40),
            a("unity", .unity, "games/PixelForge", ["Library", "Temp"], 3_120 * MB, 5),
            a("gradle", .gradle, "work/acme/android-wallet", ["build", ".gradle"], 1_860 * MB, 75, hint: "./gradlew build"),
            a("swiftpm", .swiftPM, "dev/swift/disk-tools", [".build"], 942 * MB, 3, hint: "swift build"),
            a("python", .python, "dev/py/ml-notebooks", [".venv"], 1_240 * MB, 130),
            ArtifactItem(ruleID: "go-build", ecosystem: .go, projectURL: goBuild, projectName: "go-build",
                         targets: [goBuild.appendingPathComponent("00")], optIn: false, note: nil, isGlobal: true,
                         size: 612 * MB, fileCount: 9_000, lastTouched: nil, restoreHint: "go build"),
            a("dotnet", .dotnet, "work/InventoryApi", ["bin", "obj"], 388 * MB, 200, hint: "dotnet build"),
        ]
    }

    static var caches: [CacheItem] {
        CacheLocation.all.compactMap { loc -> CacheItem? in
            let sizes: [String: Int64] = [
                "user-caches": 4_820 * MB, "logs": 612 * MB, "trash": 2_300 * MB, "npm": 3_410 * MB, "pnpm": 2_960 * MB,
                "yarn": 1_120 * MB, "homebrew": 2_040 * MB, "cargo-registry": 1_780 * MB, "cocoapods": 884 * MB, "pip": 702 * MB,
                "simulator-devices": 3_270 * MB, "xcode-archives": 1_060 * MB, "ollama": 7_400 * MB, "installers": 9_100 * MB,
                "chrome": 1_310 * MB, "arc": 822 * MB,
            ]
            guard let size = sizes[loc.id] else { return nil }
            let u = loc.url(home: home)
            return CacheItem(locationID: loc.id, name: loc.name, section: loc.section, url: u, contents: [u.appendingPathComponent("demo")],
                             safety: loc.safety, badge: loc.badge, colorHex: loc.colorHex, size: size, fileCount: Int(size / 50_000),
                             restoreHint: loc.restoreHint, permanentOnly: loc.permanentOnly)
        }
    }

    static var bigFiles: [BigFileItem] {
        func f(_ path: String, _ kind: BigFileKind, _ size: Int64, _ age: Double, bundle: Bool = false) -> BigFileItem {
            BigFileItem(url: url(path), kind: kind, size: size, modified: days(age), isBundle: bundle)
        }
        return [
            f("Movies/Exports/orbital_trailer_4k_master.mov", .video, 14_200 * MB, 240),
            f("Downloads/ubuntu-24.04-desktop-arm64.iso", .diskImage, 5_710 * MB, 286),
            f("Downloads/Xcode_16.1.xip", .archive, 4_620 * MB, 340),
            f("games/assets/MegascansLibrary_backup.zip", .archive, 4_180 * MB, 83),
            f("VMs/win11-dev.utm", .vm, 38_400 * MB, 2, bundle: true),
            f("work/art/key_art_layers_v12.psd", .art, 2_940 * MB, 132),
            f("Desktop/old/gdc_talk_recording.mp4", .video, 2_310 * MB, 212),
            f("work/backups/pg_dump_prod_2025.tar.gz", .archive, 1_880 * MB, 262),
            f("games/Orbital/Raw/city_block_hipoly.fbx", .art, 1_420 * MB, 31),
            f("Music/Projects/ost_stems_final.wav", .audio, 1_210 * MB, 108),
        ]
    }

    static var applications: [AppItem] {
        func app(_ name: String, _ id: String, _ version: String, _ size: Int64, _ leftovers: [(String, Int64)], _ age: Double?,
                 store: Bool = false, protected: String? = nil) -> AppItem {
            AppItem(url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name, bundleID: id, version: version, appSize: size,
                    leftovers: leftovers.map { AppLeftover(url: url("Library/\($0.0)"), kind: String($0.0.split(separator: "/").first ?? ""), size: $0.1) },
                    lastUsed: age.map(days), isAppStore: store, protectedReason: protected, fileCount: 2_000)
        }
        return [
            app("Unity Hub", "com.unity3d.unityhub", "3.10.0", 566 * MB, [("Application Support/UnityHub", 2_100 * MB)], 1),
            app("Visual Studio Code", "com.microsoft.VSCode", "1.95.3", 612 * MB, [("Application Support/Code", 4_810 * MB), ("Caches/com.microsoft.VSCode", 180 * MB)], 0),
            app("Xcode", "com.apple.dt.Xcode", "16.1", 4_210 * MB, [("Developer/Xcode", 5 * MB)], 1, store: true, protected: "Apple app"),
            app("Docker", "com.docker.docker", "4.36.0", 1_900 * MB, [("Containers/com.docker.docker", 21_400 * MB)], 260),
            app("Blender", "org.blenderfoundation.blender", "4.2.3", 951 * MB, [("Application Support/Blender", 197 * MB)], 12),
            app("Android Studio", "com.google.android.studio", "2024.2", 2_800 * MB, [("Application Support/Google/AndroidStudio2024.2", 1_300 * MB), ("Caches/Google", 900 * MB)], 400),
            app("Figma", "com.figma.Desktop", "124.6", 480 * MB, [("Application Support/Figma", 340 * MB)], 3),
            app("Postman", "com.postmanlabs.mac", "11.19", 520 * MB, [("Application Support/Postman", 210 * MB)], 300),
            app("Steam", "com.valvesoftware.steam", "4.0", 1_400 * MB, [("Application Support/Steam", 1_390 * MB)], nil),
            app("zoom.us", "us.zoom.xos", "6.2.5", 498 * MB, [("Application Support/zoom.us", 5 * MB)], 500),
        ]
    }

    static let runningApps: Set<String> = ["com.microsoft.VSCode", "com.figma.Desktop", "com.unity3d.unityhub"]

    static var records: [CleanupRecord] {
        func r(_ batch: String, _ age: Double, _ action: String, _ cat: CleanCategory, _ label: String, _ size: Int64) -> CleanupRecord {
            CleanupRecord(batchID: batch, timestamp: days(age), action: action, dryRun: false, category: cat, label: label,
                          path: "~/\(label)", size: size, items: [], failed: 0)
        }
        var out: [CleanupRecord] = (0..<23).map { r("b1", 0.1, "trash", .nodeModules, "proj\($0)", 11_800 * MB / 23) }
        out.append(r("b2", 1, "trash", .buildArtifacts, "Xcode DerivedData", 27_400 * MB))
        out.append(r("b3", 3, "delete", .buildArtifacts, "Unreal DDC · Orbital", 19_200 * MB))
        out.append(r("b4", 4, "command", .caches, "brew cleanup --prune=all", 3_600 * MB))
        out += (0..<48).map { r("b5", 6, "move", .screenshots, "shot\($0)", 412 * MB / 48) }
        let older = ["Gradle caches", "Cargo registry", "pnpm store", "Unity Library · PixelForge", "CocoaPods", "Simulator caches"]
        out += (0..<81).map { r("old\($0)", 10 + Double($0), "trash", .caches, older[$0 % older.count], 16_700 * MB) }
        return out
    }

    // MARK: Screenshots (real image files so QuickLook thumbnails render)

    static func screenshots() -> [ScreenshotItem] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("yokoi-demo-screenshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let palettes: [(NSColor, NSColor)] = [
            (NSColor(srgbRed: 0.55, green: 0.42, blue: 1, alpha: 1), NSColor(srgbRed: 0.13, green: 0.83, blue: 0.93, alpha: 1)),
            (NSColor(srgbRed: 0.96, green: 0.45, blue: 0.71, alpha: 1), NSColor(srgbRed: 0.98, green: 0.62, blue: 0.24, alpha: 1)),
            (NSColor(srgbRed: 0.13, green: 0.83, blue: 0.93, alpha: 1), NSColor(srgbRed: 0.2, green: 0.83, blue: 0.6, alpha: 1)),
            (NSColor(srgbRed: 0.3, green: 0.32, blue: 0.4, alpha: 1), NSColor(srgbRed: 0.45, green: 0.4, blue: 0.9, alpha: 1)),
            (NSColor(srgbRed: 0.98, green: 0.45, blue: 0.09, alpha: 1), NSColor(srgbRed: 0.94, green: 0.34, blue: 0.37, alpha: 1)),
        ]
        return (0..<20).map { i in
            let created = now.addingTimeInterval(-Double(i) * 1.6 * 86_400 - 3_600 * Double(1 + i % 9))
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let fileURL = dir.appendingPathComponent("Screenshot \(f.string(from: created)).png")
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                let (c1, c2) = palettes[i % palettes.count]
                drawShot(fileURL, c1, c2, style: i % 3)
            }
            return ScreenshotItem(url: fileURL, size: Int64(1_200_000 + (i % 5) * 600_000), created: created, isRecording: false)
        }
    }

    private static func drawShot(_ url: URL, _ c1: NSColor, _ c2: NSColor, style: Int) {
        let size = NSSize(width: 640, height: 400)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(colors: [c1, c2])!.draw(in: NSRect(origin: .zero, size: size), angle: -35)
        let win = NSRect(x: 90, y: 50, width: 460, height: 300)
        switch style {
        case 0:
            NSColor(white: 0.08, alpha: 1).setFill(); NSBezierPath(roundedRect: win, xRadius: 14, yRadius: 14).fill()
            for (k, w) in [300.0, 380, 220, 340].enumerated() {
                (k == 2 ? NSColor(srgbRed: 0.94, green: 0.34, blue: 0.5, alpha: 0.7) : NSColor(white: 1, alpha: 0.2)).setFill()
                NSBezierPath(roundedRect: NSRect(x: 120, y: 290 - Double(k) * 50, width: w, height: 16), xRadius: 6, yRadius: 6).fill()
            }
        case 1:
            NSColor(white: 1, alpha: 0.88).setFill(); NSBezierPath(roundedRect: win, xRadius: 14, yRadius: 14).fill()
        default:
            NSColor(white: 1, alpha: 0.35).setFill(); NSBezierPath(ovalIn: NSRect(x: 240, y: 120, width: 160, height: 160)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: Elsewhere

    static var drives: [ExternalDrive] {
        [ExternalDrive(url: URL(fileURLWithPath: "/Volumes/Archive SSD"), name: "Archive SSD", format: "ExFAT", total: 2_000 * GB,
                       available: 742 * GB, isReadOnly: false, isTimeMachine: false, isEjectable: true, isAppleFormat: false),
         ExternalDrive(url: URL(fileURLWithPath: "/Volumes/Backups"), name: "Backups", format: "APFS", total: 4_000 * GB,
                       available: 1_200 * GB, isReadOnly: false, isTimeMachine: true, isEjectable: true, isAppleFormat: true)]
    }

    static var driveJunk: DriveJunk {
        let root = "/Volumes/Archive SSD"
        return DriveJunk(trashContents: (0..<14).map { URL(fileURLWithPath: "\(root)/.Trashes/501/old\($0).mov") }, trashSize: 18_400 * MB,
                         dsStores: (0..<312).map { URL(fileURLWithPath: "\(root)/d\($0)/.DS_Store") }, dsStoreSize: 4 * MB,
                         appleDoubles: (0..<2_870).map { URL(fileURLWithPath: "\(root)/p/._f\($0)") }, appleDoubleSize: 12 * MB,
                         filesVisited: 412_000, truncated: false)
    }

    static func packages() -> [PackageManagerKind: [InstalledPackage]] {
        func p(_ m: PackageManagerKind, _ n: String, _ v: String, _ latest: String?, used: Double?, _ size: Int64) -> InstalledPackage {
            InstalledPackage(manager: m, name: n, installedVersion: v, latestVersion: latest ?? v,
                             status: latest == nil ? .upToDate : .outdated, lastUsed: used.map(days), size: size)
        }
        return [
            .npm: [
                p(.npm, "typescript", "5.4.5", "5.6.3", used: 3, 22_100_000), p(.npm, "eslint", "8.57.0", "9.14.0", used: 14, 9_800_000),
                p(.npm, "nodemon", "3.0.1", "3.1.7", used: 240, 4_200_000), p(.npm, "vercel", "32.7.2", "37.14.0", used: 30, 61_400_000),
                p(.npm, "pnpm", "9.12.3", nil, used: 0, 18_000_000), p(.npm, "@angular/cli", "15.2.0", "18.2.11", used: 400, 48_700_000),
                p(.npm, "create-react-app", "5.0.1", nil, used: 760, 2_100_000), p(.npm, "http-server", "14.1.1", nil, used: 180, 1_300_000),
                p(.npm, "npm-check-updates", "16.14.0", "17.1.10", used: 5, 7_600_000), p(.npm, "yo", "4.3.1", "5.0.0", used: 1_100, 12_900_000),
            ],
            .homebrew: [
                p(.homebrew, "ffmpeg", "7.0.2", "7.1", used: 9, 54_000_000), p(.homebrew, "git", "2.46.0", "2.47.0", used: 0, 61_000_000),
                p(.homebrew, "imagemagick", "7.1.1-36", nil, used: 410, 38_000_000), p(.homebrew, "node", "22.9.0", "23.1.0", used: 0, 98_000_000),
                p(.homebrew, "postgresql@16", "16.4", nil, used: 2, 72_000_000), p(.homebrew, "redis", "7.2.5", "7.4.1", used: 40, 9_000_000),
                p(.homebrew, "wget", "1.24.5", nil, used: 520, 4_000_000),
            ],
            .cargo: [p(.cargo, "ripgrep", "14.0.0", "14.1.1", used: 0, 6_200_000), p(.cargo, "bat", "0.24.0", nil, used: 1, 5_400_000),
                     p(.cargo, "cargo-watch", "8.4.0", "8.5.3", used: 380, 12_000_000)],
            .pipx: [p(.pipx, "black", "24.8.0", nil, used: 6, 21_000_000), p(.pipx, "poetry", "1.8.3", nil, used: 70, 66_000_000)],
        ]
    }

    static var toolStatuses: [ToolAction: ToolActionStatus] {
        [.unavailableSimulators: ToolActionStatus(action: .unavailableSimulators, count: 6, size: 3_270 * MB,
                                                  items: ["iPhone 14 (iOS-16-4)"], commands: [["xcrun", "simctl", "delete", "unavailable"]], note: nil),
         .localSnapshots: ToolActionStatus(action: .localSnapshots, count: 3, size: nil, items: [], commands: [], note: nil),
         .dockerImages: ToolActionStatus(action: .dockerImages, count: 11, size: 7_840 * MB, items: [],
                                         commands: [["docker", "image", "prune", "--all", "--force"]], note: nil),
         .dockerBuildCache: ToolActionStatus(action: .dockerBuildCache, count: 214, size: 4_120 * MB, items: [],
                                             commands: [["docker", "builder", "prune", "--all", "--force"]], note: nil),
         .dockerVolumes: ToolActionStatus(action: .dockerVolumes, count: 2, size: 1_310 * MB, items: ["orbital_pgdata", "3f9c1e7a2b"],
                                          commands: [["docker", "volume", "rm", "orbital_pgdata", "3f9c1e7a2b"]], note: nil)]
    }

    /// Plausible file paths inside an entry, streamed by the demo cleanup.
    static func files(in entry: CleanupEntry) -> [String] {
        let base = entry.urls.first?.path ?? home.path
        let cacheTails = ["Cache_Data/f_00a3c1", "Cache_Data/f_01b9e2", "GPUCache/data_1", "Code Cache/js/9f2c41a0", "blob_storage/7e1d",
                          "index-v5/3a/9c/1f2e", "content-v2/sha512/4b/1c/9e77", "Service Worker/CacheStorage/2f9a", "fsCachedData/5D2C"]
        let buildTails = ["debug/incremental/core-1a2b3c/s-abc123.lock", "release/deps/libserde-9f3e.rlib", "debug/build/ring-8c1d/out/libring.a",
                          "Build/Intermediates.noindex/Orbital.build/Objects-normal/arm64/Engine.o", "ShaderCache/0/1d3f.bin",
                          "ArtifactDB", "Index.noindex/DataStore/v5/units/Renderer.o-2X9F", "lib/python3.12/site-packages/torch/lib/libtorch_cpu.dylib"]
        switch entry.category {
        case .caches:
            return (0..<14).map { "\(base)/\(cacheTails[($0 + entry.label.count) % cacheTails.count])" }
        case .buildArtifacts:
            return (0..<14).map { "\(base)/\(buildTails[($0 + entry.label.count) % buildTails.count])" }
        default:
            break
        }
        let tails = ["react-dom/cjs/react-dom.development.js", "typescript/lib/typescript.js", "@babel/core/lib/index.js",
                     "esbuild/bin/esbuild", "next/dist/compiled/webpack/bundle5.js", "lodash/lodash.js", "rxjs/dist/bundles/rxjs.umd.js",
                     "debug/incremental/core-1a2b3c/s-abc123.lock", "release/deps/libserde-9f3e.rlib", "Build/Intermediates.noindex/Orbital.build",
                     "ArtifactDB", "ShaderCache/0/1d3f.bin", "sharp/vendor/lib/libvips-cpp.dylib", "prettier/index.js", "date-fns/locale/index.js"]
        return (0..<14).map { "\(base)/\(tails[($0 + entry.label.count) % tails.count])" }
    }
}
