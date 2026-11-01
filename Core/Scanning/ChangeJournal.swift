import CoreServices
import Foundation

/// Folders that changed since an FSEvents event ID, read from the system's event history.
/// Events are folder-level: a changed file shows up as its parent folder.
struct ChangeSet: Sendable {
    /// Folders whose direct contents changed.
    private let changed: Set<String>
    /// Folders FSEvents says to rescan in full (it coalesced or dropped events under them).
    private let subtrees: Set<String>
    /// `changed` and `subtrees` together, sorted, for descendant lookups.
    private let sorted: [String]
    /// The newest event that was read. Events after it are replayed by the next query.
    let throughEventID: UInt64

    init(changed: some Sequence<String>, subtrees: some Sequence<String> = [], throughEventID: UInt64) {
        self.changed = Set(changed.map(Self.normalize))
        self.subtrees = Set(subtrees.map(Self.normalize))
        self.sorted = self.changed.union(self.subtrees).sorted()
        self.throughEventID = throughEventID
    }

    /// True when anything at or under the folder `path` may have changed.
    func touches(directory path: String) -> Bool {
        let path = Self.normalize(path)
        return changed.contains(path) || hasDescendant(of: path) || insideSubtree(path)
    }

    /// True when the file at `path` may have changed (its folder changed).
    func touches(file path: String) -> Bool {
        let parent = (Self.normalize(path) as NSString).deletingLastPathComponent
        return changed.contains(parent) || insideSubtree(parent)
    }

    private func hasDescendant(of path: String) -> Bool {
        let prefix = path == "/" ? "/" : path + "/"
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < prefix { lo = mid + 1 } else { hi = mid }
        }
        return lo < sorted.count && sorted[lo].hasPrefix(prefix)
    }

    private func insideSubtree(_ path: String) -> Bool {
        guard !subtrees.isEmpty else { return false }
        var p = path
        while true {
            if subtrees.contains(p) { return true }
            if p == "/" || p.isEmpty { return false }
            p = (p as NSString).deletingLastPathComponent
        }
    }

    /// FSEvents paths end in `/` and use `/private/var`; scanner paths don't.
    static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return PathFormat.canonical(p)
    }
}

/// Reads FSEvents history. Used by `ScanIndex` to tell which previous measurements are still good.
enum ChangeJournal {
    static func currentEventID() -> UInt64 { FSEventsGetCurrentEventId() }

    /// Identifies the volume's FSEvents database. It changes when the event history is reset.
    static func volumeID(of url: URL) -> String? {
        var st = stat()
        guard lstat(url.path, &st) == 0, let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// Folders under `paths` that changed after `eventID`, or `nil` when the history can't be trusted
    /// (event IDs wrapped, a watched root moved, or no answer within `timeout`).
    static func changes(since eventID: UInt64, under paths: [String], timeout: TimeInterval = 20) async -> ChangeSet? {
        guard eventID > 0, eventID <= currentEventID(), !paths.isEmpty else { return nil }
        return await withCheckedContinuation { continuation in
            HistoryReader(since: eventID, continuation: continuation).start(paths: paths, timeout: timeout)
        }
    }
}

/// Replays FSEvents history up to "history done", then stops. All state lives on `queue`.
private final class HistoryReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.yokoi.change-journal")
    private let since: UInt64
    private var continuation: CheckedContinuation<ChangeSet?, Never>?
    private var stream: FSEventStreamRef?
    private var keepAlive: HistoryReader?
    private var changed = Set<String>()
    private var subtrees = Set<String>()
    private var newest: UInt64
    private var untrusted = false

    init(since: UInt64, continuation: CheckedContinuation<ChangeSet?, Never>) {
        self.since = since
        self.newest = since
        self.continuation = continuation
    }

    func start(paths: [String], timeout: TimeInterval) {
        queue.async { [self] in
            keepAlive = self
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
                guard let info else { return }
                let reader = Unmanaged<HistoryReader>.fromOpaque(info).takeUnretainedValue()
                let list = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray) as? [String] ?? []
                reader.receive(list, flags: UnsafeBufferPointer(start: flags, count: count),
                               ids: UnsafeBufferPointer(start: ids, count: count))
            }
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
            guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray, since, 0, flags) else {
                return finish(nil)
            }
            self.stream = stream
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else { return finish(nil) }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(nil) }
        }
    }

    private func receive(_ paths: [String], flags: UnsafeBufferPointer<FSEventStreamEventFlags>, ids: UnsafeBufferPointer<FSEventStreamEventId>) {
        guard continuation != nil else { return }
        for i in 0..<min(paths.count, flags.count) {
            let f = Int(flags[i])
            if f & kFSEventStreamEventFlagHistoryDone != 0 {
                return finish(untrusted ? nil : ChangeSet(changed: changed, subtrees: subtrees, throughEventID: newest))
            }
            if f & (kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged) != 0 { untrusted = true }
            if f & kFSEventStreamEventFlagMustScanSubDirs != 0 {
                subtrees.insert(paths[i])
            } else {
                changed.insert(paths[i])
            }
            newest = max(newest, ids[i])
        }
    }

    private func finish(_ result: ChangeSet?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: result)
        // Tear down outside the callback that called us.
        queue.async { [self] in
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
            keepAlive = nil
        }
    }
}
