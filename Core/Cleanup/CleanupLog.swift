import Foundation

/// One line in `~/Library/Application Support/Yokoi/cleanup.log` (JSON Lines).
struct CleanupRecord: Codable, Sendable, Identifiable, Hashable {
    struct Moved: Codable, Sendable, Hashable {
        /// Where the item was.
        let original: String
        /// Where it went (Trash location or move destination). `nil` for permanent deletes and dry runs.
        let destination: String?
    }

    var id: String { "\(batchID)-\(path)" }
    let batchID: String
    let timestamp: Date
    let action: String          // "trash" | "delete" | "move" | "restore" | "command"
    let dryRun: Bool
    let category: CleanCategory
    let label: String
    /// Primary path for the entry (project node_modules, cache folder, file…).
    let path: String
    let size: Int64
    let items: [Moved]
    let failed: Int
    /// For "restore" records: the batch that was put back.
    var restoresBatchID: String? = nil
}

extension FileManager {
    /// Creates Yokoi's support folder readable only by its owner (0700), tightening an existing one.
    /// The scan cache and cleanup log list the user's files by name, so they don't rely on the
    /// permissions of `~/Library` alone.
    func createPrivateDirectory(at url: URL) throws {
        try createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Atomic write (temporary file, then rename) followed by owner-only permissions on the result.
    func writePrivately(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Append-only cleanup log. Every cleanup (and dry run) is written here.
actor CleanupLog {
    let url: URL

    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Yokoi/cleanup.log")
    }

    init(url: URL = CleanupLog.defaultURL) {
        self.url = url
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func append(_ records: [CleanupRecord]) throws {
        guard !records.isEmpty else { return }
        let fm = FileManager.default
        try fm.createPrivateDirectory(at: url.deletingLastPathComponent())
        var data = Data()
        for r in records {
            data.append(try Self.encoder.encode(r))
            data.append(0x0A)
        }
        if !fm.fileExists(atPath: url.path) {
            try fm.writePrivately(data, to: url)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func readAll() -> [CleanupRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? Self.decoder.decode(CleanupRecord.self, from: Data($0)) }
    }
}

extension Array where Element == CleanupRecord {
    /// Bytes actually freed (dry runs and moves within the disk don't count).
    var freedBytes: Int64 {
        let restored = restoredBatchIDs
        return filter { !$0.dryRun && ($0.action == "trash" || $0.action == "delete") && $0.failed == 0 && !restored.contains($0.batchID) }
            .reduce(0) { $0 + $1.size }
    }

    var restoredBatchIDs: Set<String> { Set(compactMap(\.restoresBatchID)) }

    /// Batches, newest first, for the "Recent cleanups" list (restore records are folded into their batch).
    var batches: [CleanupBatch] {
        let restored = restoredBatchIDs
        let grouped = Dictionary(grouping: filter { !$0.dryRun && $0.action != "restore" }, by: \.batchID)
        return grouped.values.compactMap { CleanupBatch(records: $0, restored: restored.contains($0[0].batchID)) }
            .sorted { $0.date > $1.date }
    }
}

struct CleanupBatch: Identifiable, Sendable, Hashable {
    let id: String
    let date: Date
    let action: String
    let category: CleanCategory
    let count: Int
    let size: Int64
    let firstLabel: String
    let restored: Bool
    /// Trash batches can be put back while the items are still in the Trash.
    var canPutBack: Bool { action == "trash" && !restored }
    let records: [CleanupRecord]

    init?(records: [CleanupRecord], restored: Bool = false) {
        guard let first = records.first else { return nil }
        id = first.batchID
        date = first.timestamp
        action = first.action
        category = first.category
        count = records.count
        size = records.reduce(0) { $0 + $1.size }
        firstLabel = first.label
        self.restored = restored
        self.records = records
    }

    var title: String {
        if count == 1 && category != .nodeModules { return firstLabel }
        switch action {
        case "move": return movedTitle
        case "command": return firstLabel
        default: return clearedTitle
        }
    }

    /// "Moved 3 downloads": one whole localized phrase per category, so word order and plurals can change.
    private var movedTitle: String {
        let n = count
        return switch category {
        case .nodeModules: String(localized: "Moved \(n) node_modules", comment: "Recent cleanups row; node_modules is a folder name, don't translate it")
        case .buildArtifacts: String(localized: "Moved \(n) build folders", comment: "Recent cleanups row")
        case .caches: String(localized: "Moved \(n) caches", comment: "Recent cleanups row")
        case .bigFiles: String(localized: "Moved \(n) big files", comment: "Recent cleanups row")
        case .duplicates: String(localized: "Moved \(n) duplicates", comment: "Recent cleanups row")
        case .downloads: String(localized: "Moved \(n) downloads", comment: "Recent cleanups row")
        case .screenshots: String(localized: "Moved \(n) screenshots", comment: "Recent cleanups row")
        case .applications: String(localized: "Moved \(n) apps", comment: "Recent cleanups row")
        case .externalDrives: String(localized: "Moved \(n) drive items", comment: "Recent cleanups row: junk items on external drives")
        case .packages: String(localized: "Moved \(n) packages", comment: "Recent cleanups row")
        }
    }

    /// "Cleared 3 caches".
    private var clearedTitle: String {
        let n = count
        return switch category {
        case .nodeModules: String(localized: "Cleared \(n) node_modules", comment: "Recent cleanups row; node_modules is a folder name, don't translate it")
        case .buildArtifacts: String(localized: "Cleared \(n) build folders", comment: "Recent cleanups row")
        case .caches: String(localized: "Cleared \(n) caches", comment: "Recent cleanups row")
        case .bigFiles: String(localized: "Cleared \(n) big files", comment: "Recent cleanups row")
        case .duplicates: String(localized: "Cleared \(n) duplicates", comment: "Recent cleanups row")
        case .downloads: String(localized: "Cleared \(n) downloads", comment: "Recent cleanups row")
        case .screenshots: String(localized: "Cleared \(n) screenshots", comment: "Recent cleanups row")
        case .applications: String(localized: "Cleared \(n) apps", comment: "Recent cleanups row")
        case .externalDrives: String(localized: "Cleared \(n) drive items", comment: "Recent cleanups row: junk items on external drives")
        case .packages: String(localized: "Cleared \(n) packages", comment: "Recent cleanups row")
        }
    }
}
