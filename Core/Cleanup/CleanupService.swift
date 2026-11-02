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
    /// Why the item must never be cleaned (an Apple app, Yokoi itself). `CleanupService` refuses it,
    /// whatever screen or automation built the entry.
    var refusal: String? = nil
    /// When the scan that found this item started. A path created after it holds something the scan never
    /// saw (a reinstalled `node_modules`, an app updated in place), so cleanup refuses it until a rescan.
    var scannedAt: Date? = nil
    /// Apps or processes whose running blocks this cleanup (`CacheLocation.usedByApps`).
    var usedByApps: [String] = []

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
        case let i as AppItem:
            projectRoot = i.url
            refusal = i.protectedReason
        case let i as CacheItem:
            permanentOnly = i.permanentOnly
            // A running emulator keeps its AVD's files open: block like an open project.
            if CacheLocation.inUseGuarded.contains(i.locationID) { projectRoot = i.url }
            usedByApps = CacheLocation.byID[i.locationID]?.usedByApps ?? []
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
///
/// Every operation that takes `allowed` asks it again about the item at its parent folder's real
/// location (`F_GETPATH`) just before acting, and refuses if it says no. A parent swapped for a
/// symlink after the `PathGuard` check therefore can't redirect a trash, delete or move elsewhere.
protocol FileOperations: Sendable {
    func trash(_ url: URL, allowed: (URL) -> Bool) throws -> URL?
    /// Permanently removes `url` (recursively), calling `onFile` for each path as it goes.
    func remove(_ url: URL, allowed: (URL) -> Bool, onFile: ((String) -> Void)?) throws
    func move(_ url: URL, to destination: URL, allowed: (URL) -> Bool) throws
    func createDirectory(_ url: URL) throws
    func exists(_ url: URL) -> Bool
}

/// `removefile(3)` from libSystem, looked up at runtime. The function ships with every macOS, but
/// some SDKs (Xcode 26) have no header for it. Signatures and constants match `<removefile.h>`.
private struct RemoveFile: Sendable {
    typealias State = OpaquePointer
    typealias Callback = @convention(c) (State?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32

    let alloc: @convention(c) () -> State?
    let free: @convention(c) (State?) -> Int32
    let set: @convention(c) (State?, UInt32, UnsafeRawPointer?) -> Int32
    let remove: @convention(c) (UnsafePointer<CChar>?, State?, UInt32) -> Int32
    /// `removefileat(3)`: removes a name relative to an open folder.
    let removeAt: (@convention(c) (Int32, UnsafePointer<CChar>?, State?, UInt32) -> Int32)?

    static let recursive: UInt32 = 1        // REMOVEFILE_RECURSIVE
    static let confirmCallback: UInt32 = 1  // REMOVEFILE_STATE_CONFIRM_CALLBACK
    static let confirmContext: UInt32 = 2   // REMOVEFILE_STATE_CONFIRM_CONTEXT
    static let proceed: Int32 = 0           // REMOVEFILE_PROCEED

    static let api: RemoveFile? = {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        func load<T>(_ name: String, as _: T.Type) -> T? {
            dlsym(defaultHandle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let alloc = load("removefile_state_alloc", as: (@convention(c) () -> State?).self),
              let free = load("removefile_state_free", as: (@convention(c) (State?) -> Int32).self),
              let set = load("removefile_state_set", as: (@convention(c) (State?, UInt32, UnsafeRawPointer?) -> Int32).self),
              let remove = load("removefile", as: (@convention(c) (UnsafePointer<CChar>?, State?, UInt32) -> Int32).self)
        else { return nil }
        let removeAt = load("removefileat", as: (@convention(c) (Int32, UnsafePointer<CChar>?, State?, UInt32) -> Int32).self)
        return RemoveFile(alloc: alloc, free: free, set: set, remove: remove, removeAt: removeAt)
    }()
}

struct SystemFileOperations: FileOperations {
    /// Opens the item's parent folder and returns the descriptor plus the item's path with the parent
    /// as the kernel sees it (`F_GETPATH`). The caller closes the descriptor.
    private static func openParent(of url: URL) throws -> (dir: Int32, real: URL) {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", name != "/" else { throw posixError(EINVAL, url.path) }
        let dir = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dir >= 0 else { throw posixError(errno, url.path) }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(dir, F_GETPATH, &buf) != -1 else {
            let code = errno
            close(dir)
            throw posixError(code, url.path)
        }
        return (dir, URL(fileURLWithPath: String(cString: buf)).appendingPathComponent(name))
    }

    /// The item's path with its parent folder's symlinks resolved (`realpath(3)`), checked again by
    /// `allowed` just before a path-based operation. Refuses when the parent has been swapped for a
    /// symlink since the `PathGuard` check. `realpath` needs only search permission on the parent, so
    /// this also works on `~/.Trash` without Full Disk Access (put back); opening the folder would not.
    static func verifiedLocation(of url: URL, allowed: (URL) -> Bool) throws -> URL {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", name != "/" else { throw posixError(EINVAL, url.path) }
        guard let resolved = realpath(url.deletingLastPathComponent().path, nil) else { throw posixError(errno, url.path) }
        defer { free(resolved) }
        let real = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent(name)
        guard allowed(real) else { throw refused(real, checkedAs: url) }
        return real
    }

    private static func refused(_ real: URL, checkedAs url: URL) -> NSError {
        NSError(domain: "Yokoi.Cleanup", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Refused: \(real.path) is not where the item was checked",
            NSFilePathErrorKey: url.path,
        ])
    }

    /// Moves the item to the Trash from its verified location. `trashItem` itself is path-based, so the
    /// remaining window is the microseconds between that resolution and the move.
    func trash(_ url: URL, allowed: (URL) -> Bool) throws -> URL? {
        let real = try Self.verifiedLocation(of: url, allowed: allowed)
        var result: NSURL?
        try FileManager.default.trashItem(at: real, resultingItemURL: &result)
        return result as URL?
    }

    /// Uses `removefile(3)`: recursive, never follows symlinks, and reports every path it removes.
    ///
    /// The parent folder is opened first, and `allowed` judges the item at that folder's real path
    /// (`F_GETPATH`). The removal then runs relative to the open folder (`removefileat`), so swapping a
    /// parent for a symlink after the PathGuard check can't redirect a permanent delete somewhere else.
    func remove(_ url: URL, allowed: (URL) -> Bool, onFile: ((String) -> Void)?) throws {
        let name = url.lastPathComponent
        let (dir, real) = try Self.openParent(of: url)
        defer { close(dir) }
        let parent = real.deletingLastPathComponent().path
        guard allowed(real) else { throw Self.refused(real, checkedAs: url) }

        guard let api = RemoveFile.api, let removeAt = api.removeAt, let state = api.alloc() else {
            // No removefileat: fall back to the path (re-checked just above).
            return try FileManager.default.removeItem(at: real)
        }
        defer { _ = api.free(state) }
        var box: Unmanaged<RemoveCallbackBox>?
        if let onFile {
            // removefileat reports paths relative to the open folder; show them in full.
            let b = Unmanaged.passRetained(RemoveCallbackBox { path in onFile(path.hasPrefix("/") ? path : parent + "/" + path) })
            box = b
            let callback: RemoveFile.Callback = { _, path, ctx in
                if let path, let ctx {
                    Unmanaged<RemoveCallbackBox>.fromOpaque(ctx).takeUnretainedValue().onFile(String(cString: path))
                }
                return RemoveFile.proceed
            }
            _ = api.set(state, RemoveFile.confirmCallback, unsafeBitCast(callback, to: UnsafeRawPointer.self))
            _ = api.set(state, RemoveFile.confirmContext, b.toOpaque())
        }
        defer { box?.release() }
        if removeAt(dir, name, state, RemoveFile.recursive) != 0 {
            let code = errno
            // removefile reports ENOENT if something vanished mid-way; only fail if the item is still there.
            var st = stat()
            if fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 { throw Self.posixError(code, url.path) }
        }
    }

    private static func posixError(_ code: Int32, _ path: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
    }

    /// Moves from the verified location. `moveItem` never overwrites an existing destination.
    func move(_ url: URL, to destination: URL, allowed: (URL) -> Bool) throws {
        let real = try Self.verifiedLocation(of: url, allowed: allowed)
        try FileManager.default.moveItem(at: real, to: destination)
    }

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
    /// Whose `~/.Trash` restores may come out of.
    private let home: URL

    /// - Parameter guards: the allowed roots for each category. A category without a guard can't be cleaned.
    init(guards: [CleanCategory: PathGuard], log: CleanupLog, fileOperations: FileOperations = SystemFileOperations(),
         home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.guards = guards
        self.log = log
        self.ops = fileOperations
        self.home = home
    }

    init(context: ScanContext, log: CleanupLog, fileOperations: FileOperations = SystemFileOperations()) {
        self.init(guards: context.pathGuards(), log: log, fileOperations: fileOperations)
    }

    /// True when `url` is strictly inside the user's Trash: `~/.Trash`, or `/Volumes/<drive>/.Trashes/<uid>`.
    static func isInTrash(_ url: URL, home: URL, uid: uid_t = getuid()) -> Bool {
        let resolved = url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
        for path in Set([url.path, resolved.path].map(PathFormat.canonical)) {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !parts.contains(".."), !parts.contains(".") else { return false }
            let homeParts = PathFormat.canonical(home.path).split(separator: "/").map(String.init)
            let inHomeTrash = parts.count > homeParts.count + 1
                && Array(parts.prefix(homeParts.count)) == homeParts && parts[homeParts.count] == ".Trash"
            let inVolumeTrash = parts.count > 4 && parts[0] == "Volumes" && parts[2] == ".Trashes" && parts[3] == String(uid)
            if !(inHomeTrash || inVolumeTrash) { return false }
        }
        return true
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
            if let why = entry.refusal {
                failures.append(.init(path: entry.displayPath, reason: "Refused: \(why)"))
                failedHere = 1
                continue
            }
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
                if let scannedAt = entry.scannedAt, entry.category.checksReplacement, Self.created(url, after: scannedAt) {
                    failures.append(.init(path: url.path, reason: "Replaced since the last scan. Rescan, then clean it"))
                    failedHere += 1
                    continue
                }
                if dryRun {
                    progress?.touched(url.path)
                    moved.append(.init(original: url.path, destination: nil))
                    continue
                }
                // Asked again at the item's real location just before each operation.
                let stillAllowed: (URL) -> Bool = { pathGuard.check($0) == nil }
                do {
                    switch action {
                    case .trash:
                        progress?.touched(url.path)
                        let result = try ops.trash(url, allowed: stillAllowed)
                        moved.append(.init(original: url.path, destination: result?.path))
                    case .delete:
                        progress?.touched(url.path)
                        var n = 0
                        try ops.remove(url, allowed: stillAllowed, onFile: progress.map { p in
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
                        try ops.move(url, to: target, allowed: stillAllowed)
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
                // The log is a plain file: only move things out of a Trash, back to a place cleanup may touch.
                if !Self.isInTrash(trashed, home: home) {
                    failures.append(.init(path: item.original, reason: "Refused: the logged Trash location isn't in a Trash"))
                    failed += 1
                } else if let violation = (guards[record.category] ?? PathGuard(allowedRoots: [], exclusions: GlobMatcher(patterns: []))).check(original) {
                    failures.append(.init(path: item.original, reason: "Refused: \(violation.description)"))
                    failed += 1
                } else if !ops.exists(trashed) {
                    failures.append(.init(path: item.original, reason: "No longer in the Trash"))
                    failed += 1
                } else if ops.exists(original) {
                    failures.append(.init(path: item.original, reason: "Something else is at the original path now"))
                    failed += 1
                } else {
                    do {
                        try ops.createDirectory(original.deletingLastPathComponent())
                        try ops.move(trashed, to: original, allowed: { Self.isInTrash($0, home: home) })
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

    /// Whether the item at `url` itself (not a symlink's target) was created after `date`. False when the
    /// volume doesn't record creation dates.
    static func created(_ url: URL, after date: Date) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_birthtimespec.tv_sec > 0 else { return false }
        let born = Date(timeIntervalSince1970: TimeInterval(st.st_birthtimespec.tv_sec) + TimeInterval(st.st_birthtimespec.tv_nsec) / 1e9)
        return born > date
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
