import Foundation

enum CleanupAction: Sendable, Hashable {
    case trash
    case delete
    /// Moves items into `destination`, optionally into `YYYY/MM` subfolders by each item's date.
    case move(destination: URL, organizeByDate: Bool)

    var logName: String {
        switch self {
        case .trash: "trash"
        case .delete: "delete"
        case .move: "move"
        }
    }
}

/// One thing to clean, flattened from any `Reclaimable`.
struct CleanupEntry: Sendable, Identifiable, Hashable {
    let id: String
    let category: CleanCategory
    let label: String
    let displayPath: String
    let urls: [URL]
    let size: Int64
    let fileCount: Int
    let safety: SafetyLevel
    let restoreHint: String
    let projectLastTouched: Date?
    /// Used to organize moves by date (screenshots).
    let date: Date?
    /// Root of the owning project or app, used to refuse cleanup while it's open.
    var projectRoot: URL? = nil
    /// Only permanent delete is allowed (the Trash itself).
    var permanentOnly = false

    init<R: Reclaimable>(_ item: R, displayPath: String? = nil, date: Date? = nil) {
        id = item.id
        category = item.category
        label = item.title
        self.displayPath = displayPath ?? item.urls.first.map { PathFormat.abbreviate($0) } ?? item.title
        urls = item.urls
        size = item.size
        fileCount = item.fileCount
        safety = item.safety
        restoreHint = item.restoreHint
        projectLastTouched = item.projectLastTouched
        self.date = date
        switch item {
        case let i as NodeModulesItem: projectRoot = i.projectURL
        case let i as ArtifactItem: projectRoot = i.isGlobal ? nil : i.projectURL
        case let i as AppItem: projectRoot = i.url
        case let i as CacheItem: permanentOnly = i.permanentOnly
        default: break
        }
    }

    init(id: String, category: CleanCategory, label: String, displayPath: String, urls: [URL], size: Int64,
         fileCount: Int = 1, safety: SafetyLevel = .safe, restoreHint: String = "", projectLastTouched: Date? = nil, date: Date? = nil) {
        self.id = id
        self.category = category
        self.label = label
        self.displayPath = displayPath
        self.urls = urls
        self.size = size
        self.fileCount = fileCount
        self.safety = safety
        self.restoreHint = restoreHint
        self.projectLastTouched = projectLastTouched
        self.date = date
    }

    /// True when the owning project changed within `days` (active-project protection).
    func isRecentlyActive(days: Int, now: Date = Date()) -> Bool {
        guard let d = projectLastTouched else { return false }
        return now.timeIntervalSince(d) < Double(days) * 86_400
    }
}

struct CleanupOutcome: Sendable {
    struct Failure: Sendable, Hashable {
        let path: String
        let reason: String
    }

    let batchID: String
    let action: CleanupAction
    let dryRun: Bool
    let records: [CleanupRecord]
    let failures: [Failure]
    /// Entry ids that were fully handled (all paths succeeded).
    let completedIDs: Set<String>
    let bytes: Int64

    var itemCount: Int { completedIDs.count }
}

/// The file operations behind a cleanup. Abstracted so tests can observe or fake them.
protocol FileOperations: Sendable {
    func trash(_ url: URL) throws -> URL?
    /// Permanently removes `url` (recursively), calling `onFile` for each path as it goes.
    func remove(_ url: URL, onFile: ((String) -> Void)?) throws
    func move(_ url: URL, to destination: URL) throws
    func createDirectory(_ url: URL) throws
    func exists(_ url: URL) -> Bool
}

struct SystemFileOperations: FileOperations {
    func trash(_ url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }

    /// Uses `removefile(3)`: recursive, never follows symlinks, and reports every path it removes.
    func remove(_ url: URL, onFile: ((String) -> Void)?) throws {
        guard let onFile else { return try FileManager.default.removeItem(at: url) }
        guard let state = removefile_state_alloc() else { return try FileManager.default.removeItem(at: url) }
        defer { removefile_state_free(state) }
        let box = Unmanaged.passRetained(RemoveCallbackBox(onFile))
        defer { box.release() }
        let callback: @convention(c) (removefile_state_t?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32 = { _, path, ctx in
            if let path, let ctx {
                Unmanaged<RemoveCallbackBox>.fromOpaque(ctx).takeUnretainedValue().onFile(String(cString: path))
            }
            return Int32(REMOVEFILE_PROCEED)
        }
        removefile_state_set(state, UInt32(REMOVEFILE_STATE_CONFIRM_CALLBACK), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        removefile_state_set(state, UInt32(REMOVEFILE_STATE_CONFIRM_CONTEXT), box.toOpaque())
        if removefile(url.path, state, removefile_flags_t(REMOVEFILE_RECURSIVE)) != 0 {
            let code = errno
            // removefile reports ENOENT if something vanished mid-way; only fail if the item is still there.
            if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
            }
        }
    }

    func move(_ url: URL, to destination: URL) throws { try FileManager.default.moveItem(at: url, to: destination) }

    func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func exists(_ url: URL) -> Bool {
        // lstat semantics: a dangling symlink still "exists".
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
}

/// Holds the per-file callback for `removefile`'s C callback.
final class RemoveCallbackBox {
    let onFile: (String) -> Void
    init(_ onFile: @escaping (String) -> Void) { self.onFile = onFile }
}

/// Trashes, deletes and moves files, enforcing the `PathGuard` on every single path and logging
/// every cleanup. Permanent delete is only reachable through an explicit `.delete` action.
actor CleanupService {
    private let guards: [CleanCategory: PathGuard]
    private let log: CleanupLog
    private let ops: FileOperations

    /// - Parameter guards: the allowed roots for each category. A category without a guard can't be cleaned.
    init(guards: [CleanCategory: PathGuard], log: CleanupLog, fileOperations: FileOperations = SystemFileOperations()) {
        self.guards = guards
        self.log = log
        self.ops = fileOperations
    }

    init(context: ScanContext, log: CleanupLog, fileOperations: FileOperations = SystemFileOperations()) {
        self.init(guards: context.pathGuards(), log: log, fileOperations: fileOperations)
    }

    func perform(_ entries: [CleanupEntry], action: CleanupAction, dryRun: Bool, now: Date = Date(),
                 progress: CleanupProgress? = nil) async -> CleanupOutcome {
        let batchID = UUID().uuidString
        var records: [CleanupRecord] = []
        var failures: [CleanupOutcome.Failure] = []
        var completed = Set<String>()
        var bytes: Int64 = 0
        progress?.begin(entries: entries.count, files: entries.reduce(0) { $0 + max($1.fileCount, $1.urls.count) },
                        bytes: entries.reduce(0) { $0 + $1.size })

        for entry in entries {
            if Task.isCancelled { break }
            var moved: [CleanupRecord.Moved] = []
            var failedHere = 0
            var filesCounted = 0
            progress?.startEntry(label: entry.label)
            defer {
                progress?.finishEntry(bytes: failedHere == 0 ? entry.size : 0, files: max(entry.fileCount, entry.urls.count),
                                      filesAlreadyCounted: filesCounted, failed: failedHere > 0)
            }
            let pathGuard = guards[entry.category] ?? PathGuard(allowedRoots: [], exclusions: GlobMatcher(patterns: []))
            if entry.permanentOnly, case .trash = action {
                failures.append(.init(path: entry.displayPath, reason: "Refused: items already in the Trash can only be deleted permanently"))
                continue
            }
            for url in entry.urls {
                if let violation = pathGuard.check(url) {
                    failures.append(.init(path: url.path, reason: "Refused: \(violation.description)"))
                    failedHere += 1
                    continue
                }
                if case .move(let destination, _) = action,
                   destination.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path + "/") {
                    failures.append(.init(path: url.path, reason: "Refused: destination is inside the item"))
                    failedHere += 1
                    continue
                }
                guard ops.exists(url) else {
                    failures.append(.init(path: url.path, reason: "No longer exists"))
                    failedHere += 1
                    continue
                }
                if dryRun {
                    progress?.touched(url.path)
                    moved.append(.init(original: url.path, destination: nil))
                    continue
                }
                do {
                    switch action {
                    case .trash:
                        progress?.touched(url.path)
                        let result = try ops.trash(url)
                        moved.append(.init(original: url.path, destination: result?.path))
                    case .delete:
                        progress?.touched(url.path)
                        var n = 0
                        try ops.remove(url, onFile: progress.map { p in
                            { path in
                                n += 1
                                p.touched(path, countsAsFile: true)
                            }
                        })
                        filesCounted += n
                        moved.append(.init(original: url.path, destination: nil))
                    case .move(let destination, let organize):
                        let folder = Self.destinationFolder(base: destination, date: entry.date ?? now, organizeByDate: organize)
                        try ops.createDirectory(folder)
                        let target = Self.uniqueDestination(for: url.lastPathComponent, in: folder, exists: ops.exists)
                        progress?.touched(url.path)
                        try ops.move(url, to: target)
                        moved.append(.init(original: url.path, destination: target.path))
                    }
                } catch {
                    failures.append(.init(path: url.path, reason: error.localizedDescription))
                    failedHere += 1
                }
            }
            if failedHere == 0 {
                completed.insert(entry.id)
                bytes += entry.size
            }
            if !moved.isEmpty {
                records.append(CleanupRecord(
                    batchID: batchID, timestamp: now, action: action.logName, dryRun: dryRun,
                    category: entry.category, label: entry.label, path: entry.displayPath,
                    size: failedHere == 0 ? entry.size : 0, items: moved, failed: failedHere
                ))
            }
        }

        do {
            try await log.append(records)
        } catch {
            failures.append(.init(path: log.url.path, reason: "Couldn't write the cleanup log: \(error.localizedDescription)"))
        }
        return CleanupOutcome(batchID: batchID, action: action, dryRun: dryRun, records: records,
                              failures: failures, completedIDs: completed, bytes: bytes)
    }

    /// Puts a Trash batch back where it came from (undo). Items whose original path is taken, or that
    /// are no longer in the Trash, are skipped and reported. Writes "restore" records to the log.
    func restore(batch records: [CleanupRecord], now: Date = Date()) async -> CleanupOutcome {
        var restored: [CleanupRecord] = []
        var failures: [CleanupOutcome.Failure] = []
        var bytes: Int64 = 0
        let batchID = UUID().uuidString
        for record in records where record.action == "trash" && !record.dryRun {
            var moved: [CleanupRecord.Moved] = []
            var failed = 0
            for item in record.items {
                guard let trashed = item.destination.map(URL.init(fileURLWithPath:)) else { failed += 1; continue }
                let original = URL(fileURLWithPath: item.original)
                if !ops.exists(trashed) {
                    failures.append(.init(path: item.original, reason: "No longer in the Trash"))
                    failed += 1
                } else if ops.exists(original) {
                    failures.append(.init(path: item.original, reason: "Something else is at the original path now"))
                    failed += 1
                } else {
                    do {
                        try ops.createDirectory(original.deletingLastPathComponent())
                        try ops.move(trashed, to: original)
                        moved.append(.init(original: trashed.path, destination: original.path))
                    } catch {
                        failures.append(.init(path: item.original, reason: error.localizedDescription))
                        failed += 1
                    }
                }
            }
            if !moved.isEmpty {
                if failed == 0 { bytes += record.size }
                restored.append(CleanupRecord(batchID: batchID, timestamp: now, action: "restore", dryRun: false,
                                              category: record.category, label: record.label, path: record.path,
                                              size: failed == 0 ? record.size : 0, items: moved, failed: failed,
                                              restoresBatchID: record.batchID))
            }
        }
        try? await log.append(restored)
        return CleanupOutcome(batchID: batchID, action: .trash, dryRun: false, records: restored, failures: failures,
                              completedIDs: Set(restored.map(\.path)), bytes: bytes)
    }

    /// `base/YYYY/MM` when organizing by date (PRD FR-S3).
    static func destinationFolder(base: URL, date: Date, organizeByDate: Bool) -> URL {
        guard organizeByDate else { return base }
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return base
            .appendingPathComponent(String(format: "%04d", c.year ?? 1970))
            .appendingPathComponent(String(format: "%02d", c.month ?? 1))
    }

    /// Never overwrites: `name.png`, `name 2.png`, `name 3.png`… (PRD FR-S5).
    static func uniqueDestination(for name: String, in folder: URL, exists: (URL) -> Bool) -> URL {
        var candidate = folder.appendingPathComponent(name)
        guard exists(candidate) else { return candidate }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 2
        repeat {
            let newName = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            candidate = folder.appendingPathComponent(newName)
            n += 1
        } while exists(candidate)
        return candidate
    }
}
