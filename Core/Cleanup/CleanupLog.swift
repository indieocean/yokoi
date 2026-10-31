import Foundation

/// One line in `~/Library/Application Support/DiskKeeper/cleanup.log` (JSON Lines).
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

/// Append-only cleanup log. Every cleanup (and dry run) is written here.
actor CleanupLog {
    let url: URL

    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("DiskKeeper/cleanup.log")
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
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for r in records {
            data.append(try Self.encoder.encode(r))
            data.append(0x0A)
        }
        if !fm.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
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
        let noun: String
        switch category {
        case .nodeModules: noun = count == 1 ? "node_modules" : "node_modules"
        case .buildArtifacts: noun = count == 1 ? "build folder" : "build folders"
        case .caches: noun = count == 1 ? "cache" : "caches"
        case .bigFiles: noun = count == 1 ? "big file" : "big files"
        case .screenshots: noun = count == 1 ? "screenshot" : "screenshots"
        case .applications: noun = count == 1 ? "app" : "apps"
        case .externalDrives: noun = "drive items"
        case .packages: noun = "packages"
        }
        if count == 1 && category != .nodeModules { return firstLabel }
        switch action {
        case "move": return "Moved \(count) \(noun)"
        case "command": return firstLabel
        default: return "Cleared \(count) \(noun)"
        }
    }
}
