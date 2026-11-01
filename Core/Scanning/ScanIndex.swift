import Foundation
import os

/// What the last scan measured, so a rescan only re-measures what FSEvents says changed (PRD: incremental
/// rescan). A saved value is reused when nothing at or under its path changed since the saved event ID
/// and the path still has the same inode (catches a folder replaced by a move or rename).
/// Without usable history (first scan, reset journal, other volume) everything is measured as before.
final class ScanIndex: Sendable {
    struct Stored: Codable, Sendable {
        static let currentVersion = 1
        var version = Stored.currentVersion
        var eventID: UInt64
        /// When everything was last measured from scratch. Older than `maxAge` starts over.
        var fullScanAt = Date()
        var volume: String?
        /// Big-file results depend on the exclusions and size floor; they're dropped when these change.
        var bigFileKey: String
        var sizes: [String: Sized] = [:]
        var lastTouched: [String: Touched] = [:]
        var bigFiles: [String: BigFiles] = [:]
    }

    struct Sized: Codable, Sendable {
        let inode: UInt64
        let isDirectory: Bool
        let size: Int64
        let files: Int
    }

    struct Touched: Codable, Sendable {
        let inode: UInt64
        let date: Date?
    }

    struct BigFiles: Codable, Sendable {
        let inode: UInt64
        let items: [BigFileItem]
    }

    /// The previous scan's values, or `nil` when they can't be trusted.
    private let previous: Stored?
    private let changes: ChangeSet?
    /// FSEvents history only covers these folders (and everything under them).
    private let watched: [String]
    private let fresh: OSAllocatedUnfairLock<Stored>
    private let reuseCount = OSAllocatedUnfairLock(initialState: 0)

    /// Reused values are re-measured from scratch this often. Bounds drift from sizes APFS settles after
    /// a measurement (recently written files) and from anything FSEvents might have missed.
    static let maxAge: TimeInterval = 7 * 86_400

    init(previous: Stored?, changes: ChangeSet?, watched: [String], eventID: UInt64, volume: String?, bigFileKey: String) {
        let previous = changes == nil ? nil : previous
        self.previous = previous
        self.changes = changes
        self.watched = watched.map(ChangeSet.normalize)
        var fresh = Stored(eventID: eventID, volume: volume, bigFileKey: bigFileKey)
        if let previous { fresh.fullScanAt = previous.fullScanAt }
        self.fresh = OSAllocatedUnfairLock(initialState: fresh)
    }

    /// Whether this scan can reuse anything at all.
    var isIncremental: Bool { previous != nil }

    /// How many measurements were reused instead of taken again.
    var reused: Int { reuseCount.withLock { $0 } }

    // MARK: Loading and saving

    /// Shared by the app, the `yokoi` command and Shortcuts.
    static var defaultURL: URL {
        CleanupLog.defaultURL.deletingLastPathComponent().appendingPathComponent("scan-index.json")
    }

    /// Loads the saved index and asks FSEvents what changed since it was written.
    static func prepare(stored url: URL, context: ScanContext) async -> ScanIndex {
        let watched = watchedPaths(context)
        let volume = ChangeJournal.volumeID(of: context.home)
        let key = bigFileKey(context)
        let start = ChangeJournal.currentEventID()

        var previous = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        if let p = previous, p.version != Stored.currentVersion || volume == nil || p.volume != volume
            || Date().timeIntervalSince(p.fullScanAt) > maxAge { previous = nil }
        if previous?.bigFileKey != key { previous?.bigFiles = [:] }

        var changes: ChangeSet?
        if let previous {
            changes = await ChangeJournal.changes(since: previous.eventID, under: watched)
        }
        // Next time, replay from the newest event actually read. Starting from `start` instead could skip
        // events FSEvents hadn't delivered yet when the history was read.
        return ScanIndex(previous: previous, changes: changes, watched: watched,
                         eventID: changes?.throughEventID ?? start, volume: volume, bigFileKey: key)
    }

    /// Writes what this scan measured. With `carryOver`, values from the previous scan that are still valid
    /// are kept too (a partial or cancelled scan didn't visit them).
    func save(to url: URL, carryOver: Bool) {
        var out = fresh.withLock { $0 }
        if carryOver, let previous {
            for (k, v) in previous.sizes where out.sizes[k] == nil && reusable(k, inode: v.inode, isDirectory: v.isDirectory) {
                out.sizes[k] = v
            }
            for (k, v) in previous.lastTouched where out.lastTouched[k] == nil {
                let path = String(k[..<(k.lastIndex(of: "#") ?? k.endIndex)])
                if reusable(path, inode: v.inode, isDirectory: true) { out.lastTouched[k] = v }
            }
            if out.bigFileKey == previous.bigFileKey {
                for (k, v) in previous.bigFiles where out.bigFiles[k] == nil && reusable(k, inode: v.inode, isDirectory: true) {
                    out.bigFiles[k] = v
                }
            }
        }
        guard let data = try? JSONEncoder().encode(out) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Cached work

    /// Allocated size and file count, reused when nothing under `url` changed.
    func measure(_ url: URL, progress: ScanProgress?) -> FileWalker.Measurement {
        let key = Self.key(url)
        guard let node = Self.node(key) else { return FileWalker.measure(url, progress: progress) }
        if let old = previous?.sizes[key], old.isDirectory == node.isDirectory,
           reusable(key, inode: old.inode, isDirectory: old.isDirectory, current: node.inode) {
            progress?.visited(files: old.files)
            fresh.withLock { $0.sizes[key] = old }
            reuseCount.withLock { $0 += 1 }
            return FileWalker.Measurement(size: old.size, files: old.files)
        }
        let m = FileWalker.measure(url, progress: progress)
        if !Task.isCancelled {
            fresh.withLock { $0.sizes[key] = Sized(inode: node.inode, isDirectory: node.isDirectory, size: m.size, files: m.files) }
        }
        return m
    }

    /// `FileWalker.lastTouched`, reused when nothing in the project changed.
    func lastTouched(project: URL, skipping skip: Set<String>) -> Date? {
        let path = Self.key(project)
        let key = path + "#" + Self.fingerprint(skip.sorted())
        guard let node = Self.node(path), node.isDirectory else { return FileWalker.lastTouched(project: project, skipping: skip) }
        if let old = previous?.lastTouched[key], reusable(path, inode: old.inode, isDirectory: true, current: node.inode) {
            fresh.withLock { $0.lastTouched[key] = old }
            reuseCount.withLock { $0 += 1 }
            return old.date
        }
        let date = FileWalker.lastTouched(project: project, skipping: skip)
        if !Task.isCancelled { fresh.withLock { $0.lastTouched[key] = Touched(inode: node.inode, date: date) } }
        return date
    }

    /// Big files found under `dir` last time, if nothing under it changed.
    func bigFiles(under dir: URL) -> [BigFileItem]? {
        let key = Self.key(dir)
        guard let old = previous?.bigFiles[key], let node = Self.node(key), node.isDirectory,
              reusable(key, inode: old.inode, isDirectory: true, current: node.inode) else { return nil }
        fresh.withLock { $0.bigFiles[key] = old }
        reuseCount.withLock { $0 += 1 }
        return old.items
    }

    func store(bigFiles items: [BigFileItem], under dir: URL) {
        let key = Self.key(dir)
        guard !Task.isCancelled, let node = Self.node(key), node.isDirectory else { return }
        fresh.withLock { $0.bigFiles[key] = BigFiles(inode: node.inode, items: items) }
    }

    // MARK: Helpers

    private func reusable(_ key: String, inode: UInt64, isDirectory: Bool, current: UInt64? = nil) -> Bool {
        guard let changes, isWatched(key), (current ?? Self.node(key)?.inode) == inode else { return false }
        return isDirectory ? !changes.touches(directory: key) : !changes.touches(file: key)
    }

    private func isWatched(_ key: String) -> Bool {
        watched.contains { key == $0 || key.hasPrefix($0 == "/" ? "/" : $0 + "/") }
    }

    /// Home and `/Applications`, plus scan roots elsewhere on the startup disk. Other volumes are always
    /// measured in full (event IDs and the history reset check are per startup volume).
    static func watchedPaths(_ context: ScanContext) -> [String] {
        let home = context.home.standardizedFileURL.path
        let candidates = [home] + (context.applicationFolders + context.rootURLs().map(\.url) + context.bigFileRoots).map { $0.standardizedFileURL.path }
        let local = candidates.filter { !$0.hasPrefix("/Volumes/") && FileManager.default.fileExists(atPath: $0) }
        return Array(Set(local)).filter { p in !local.contains { o in o != p && p.hasPrefix(o + "/") } }.sorted()
    }

    static func bigFileKey(_ context: ScanContext) -> String {
        fingerprint(context.exclusions.patterns + ["floor:\(context.bigFileFloor)"])
    }

    static func key(_ url: URL) -> String { ChangeSet.normalize(url.standardizedFileURL.path) }

    private static func node(_ path: String) -> (inode: UInt64, isDirectory: Bool)? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return (UInt64(st.st_ino), (st.st_mode & S_IFMT) == S_IFDIR)
    }

    /// Stable across launches (unlike `hashValue`). FNV-1a.
    private static func fingerprint(_ parts: [String]) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in parts.joined(separator: "\u{1F}").utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100_0000_01b3
        }
        return String(h, radix: 16)
    }
}
