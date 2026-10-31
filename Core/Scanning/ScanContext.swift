import Foundation
import os

/// A folder Disk Keeper scans for projects, with an optional depth limit.
struct ScanRoot: Codable, Sendable, Hashable, Identifiable {
    var id: String { path }
    /// Stored with `~` so it reads naturally in Settings.
    var path: String
    /// `nil` means unlimited depth.
    var maxDepth: Int?

    func url(home: URL) -> URL { PathFormat.expand(path, home: home).standardizedFileURL }
}

/// Everything a scanner needs. Value type, so scanners stay `Sendable` and testable with fixture folders.
struct ScanContext: Sendable {
    var home: URL
    var roots: [ScanRoot]
    var bigFileRoots: [URL]
    var exclusions: GlobMatcher
    var screenshotFolder: URL
    /// Where installed apps live (`/Applications`, `~/Applications`).
    var applicationFolders: [URL] = []
    /// Mounted external volumes that may be cleaned (not read-only, not Time Machine).
    var externalVolumes: [URL] = []
    /// Smallest file the big-file scanner reports. The UI threshold filters further.
    var bigFileFloor: Int64 = 100_000_000
    /// How many folders are sized at once.
    var concurrency: Int = 8

    func rootURLs() -> [(url: URL, maxDepth: Int?)] {
        roots.map { ($0.url(home: home), $0.maxDepth) }
    }

    /// Paths each category's cleanup may touch. Scoped per category so, for example, the big-file
    /// locations (home by default) never widen what node_modules or artifact cleanup can reach.
    func allowedRoots(for category: CleanCategory) -> [URL] {
        switch category {
        case .nodeModules:
            return roots.map { $0.url(home: home) }
        case .buildArtifacts:
            return roots.map { $0.url(home: home) } + GlobalArtifactRule.all.map { home.appendingPathComponent($0.relativePath) }
        case .caches:
            return CacheLocation.all.map { $0.url(home: home) }
        case .bigFiles:
            return bigFileRoots
        case .screenshots:
            return [screenshotFolder]
        case .applications:
            return applicationFolders + ApplicationScanner.leftoverFolders.map { home.appendingPathComponent($0) }
        case .externalDrives:
            return externalVolumes
        case .packages:
            return []
        }
    }

    func pathGuard(for category: CleanCategory) -> PathGuard {
        PathGuard(allowedRoots: allowedRoots(for: category), exclusions: exclusions, home: home)
    }

    func pathGuards() -> [CleanCategory: PathGuard] {
        Dictionary(uniqueKeysWithValues: CleanCategory.allCases.map { ($0, pathGuard(for: $0)) })
    }

    func isExcluded(_ url: URL) -> Bool { exclusions.matches(url) }
}

/// Live, thread-safe scan progress. Scanners bump counters; the UI polls `snapshot`.
final class ScanProgress: Sendable {
    struct Snapshot: Sendable, Equatable {
        var filesVisited = 0
        var foldersVisited = 0
        var itemsFound = 0
        var currentPath = ""
    }

    private let state = OSAllocatedUnfairLock(initialState: Snapshot())

    init() {}

    var snapshot: Snapshot { state.withLock { $0 } }

    func visited(files: Int = 0, folders: Int = 0, path: String? = nil) {
        state.withLock {
            $0.filesVisited += files
            $0.foldersVisited += folders
            if let path { $0.currentPath = path }
        }
    }

    func found(_ n: Int = 1) {
        state.withLock { $0.itemsFound += n }
    }
}
