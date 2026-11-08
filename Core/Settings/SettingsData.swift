import Foundation

enum DeleteMode: String, Codable, Sendable, CaseIterable {
    case trash, permanent
}

enum ScreenshotAutoAction: String, Codable, Sendable, CaseIterable {
    case move, delete
}

/// What scheduled auto-clean takes.
enum AutoCleanScope: String, Codable, Sendable, CaseIterable {
    case safeCaches, smartSelect
}

enum ScanFrequency: String, Codable, Sendable, CaseIterable {
    case daily, weekly, monthly
}

/// Which folders may be scan or big-file locations. A location is also the boundary cleanup may
/// reach, so the disk root, anything above the home folder and system locations are refused.
enum ScanRootPolicy {
    /// Why `url` can't be a location, or nil when it can.
    static func refusal(for url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let path = PathFormat.canonical(url.standardizedFileURL.path)
        let homePath = PathFormat.canonical(home.path)
        if path == "/" { return String(localized: "The whole disk can't be a scan location.") }
        if homePath.hasPrefix(path + "/") { return String(localized: "Folders above your home folder can't be scan locations.") }
        if PathGuard.isProtectedSystemPath(PathGuard.fold(path)) { return String(localized: "System folders can't be scan locations.") }
        return nil
    }
}

/// Everything the user can configure. Plain `Codable` value so it's easy to persist and test.
struct SettingsData: Codable, Sendable, Equatable {
    var scanRoots: [ScanRoot]
    var bigFileRoots: [String] = ["~"]
    var exclusions: [String] = ["**/.git"]

    // Safety
    var defaultDeleteMode: DeleteMode = .trash
    /// Projects changed within this many days need an extra confirmation.
    var protectRecentDays: Int = 14
    /// node_modules untouched for longer than this are "stale".
    var staleDays: Int = 90
    var dryRun: Bool = false
    /// Skip the confirmation sheet for Safe-level caches moved to the Trash (never for permanent delete).
    var skipConfirmForSafe: Bool = false

    // Big files
    var bigFileThreshold: Int64 = 1_000_000_000

    // Screenshots
    var screenshotFolderOverride: String? = nil
    var screenshotDestination: String = "~/Pictures/Screenshots"
    var screenshotOrganizeByDate: Bool = true
    var screenshotAgeDays: Int = 7
    /// Downloads untouched (not added or opened) for this many days count as reclaimable.
    var downloadsAgeDays: Int = 30

    // Schedule
    var autoScan: Bool = false
    var scanFrequency: ScanFrequency = .weekly
    /// Clean after each scheduled scan. The name predates `autoCleanScope`.
    var autoCleanSafeCaches: Bool = false
    var autoCleanScope: AutoCleanScope = .safeCaches
    /// Delete instead of using the Trash. The Trash only gives the space back once it's emptied.
    var autoCleanPermanent: Bool = false
    var notifyThresholdGB: Int = 50
    var showInMenuBar: Bool = false
    var launchAtLogin: Bool = false
    var screenshotAutoRule: Bool = false
    var screenshotAutoAction: ScreenshotAutoAction = .move

    var hasCompletedOnboarding: Bool = false

    init(scanRoots: [ScanRoot]) {
        self.scanRoots = scanRoots
    }

    static func defaults(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SettingsData {
        SettingsData(scanRoots: detectRoots(home: home))
    }

    /// Defaults from PRD §7 plus common project folders found on this Mac. Names are matched exactly
    /// against the folder listing so case-insensitive volumes don't produce duplicates.
    static func detectRoots(home: URL) -> [ScanRoot] {
        func children(_ url: URL) -> Set<String> {
            Set((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
        }
        let top = children(home)
        let docs = children(home.appendingPathComponent("Documents"))
        var roots: [ScanRoot] = []
        for name in ["dev", "work", "games", "Developer", "Projects", "projects", "code", "Code", "src", "repos", "git", "GitHub", "workspace"] where top.contains(name) {
            roots.append(ScanRoot(path: "~/\(name)"))
        }
        for name in ["Projects", "GitHub", "Code", "Developer", "dev", "Unity", "Unreal Projects"] where docs.contains(name) {
            roots.append(ScanRoot(path: "~/Documents/\(name)"))
        }
        if roots.isEmpty { roots.append(ScanRoot(path: "~/Documents")) }
        roots.append(ScanRoot(path: "~/Library/Developer"))
        return roots
    }

    func makeContext(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ScanContext {
        let screenshotFolder = screenshotFolderOverride.map { PathFormat.expand($0, home: home) }
            ?? ScreenshotScanner.systemScreenshotFolder(home: home)
        return ScanContext(
            home: home,
            // Checked here as well as when a folder is added: saved settings are only a file, and these roots are
            // what cleanup may reach.
            roots: scanRoots.filter { ScanRootPolicy.refusal(for: $0.url(home: home), home: home) == nil },
            bigFileRoots: bigFileRoots.map { PathFormat.expand($0, home: home) }
                .filter { ScanRootPolicy.refusal(for: $0, home: home) == nil },
            exclusions: GlobMatcher(patterns: exclusions, home: home),
            screenshotFolder: screenshotFolder,
            applicationFolders: [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        )
    }
}
