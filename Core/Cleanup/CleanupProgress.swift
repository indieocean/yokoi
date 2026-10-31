import Foundation
import os

/// Live, thread-safe progress of a running cleanup. `CleanupService` reports into it; the UI polls
/// `snapshot` to drive the progress overlay (files being removed, bytes freed).
final class CleanupProgress: Sendable {
    struct Snapshot: Sendable, Equatable {
        var entriesTotal = 0
        var entriesDone = 0
        var filesTotal = 0
        var filesDone = 0
        var bytesTotal: Int64 = 0
        var bytesDone: Int64 = 0
        var currentLabel = ""
        var currentPath = ""
        /// Most recent paths handled, newest first.
        var recent: [String] = []
        var failures = 0

        /// 0…1, by files when known (smooth for big folders), otherwise by entries.
        var fraction: Double {
            if filesTotal > 0 { return min(1, Double(filesDone) / Double(filesTotal)) }
            if entriesTotal > 0 { return min(1, Double(entriesDone) / Double(entriesTotal)) }
            return 0
        }
    }

    static let recentLimit = 8
    private let state = OSAllocatedUnfairLock(initialState: Snapshot())

    init() {}

    var snapshot: Snapshot { state.withLock { $0 } }

    func begin(entries: Int, files: Int, bytes: Int64) {
        state.withLock {
            $0.entriesTotal = entries
            $0.filesTotal = files
            $0.bytesTotal = bytes
        }
    }

    func startEntry(label: String) {
        state.withLock { $0.currentLabel = label }
    }

    /// A path is being handled (a folder moved to the Trash, or one file of a permanent delete).
    func touched(_ path: String, countsAsFile: Bool = false) {
        state.withLock {
            $0.currentPath = path
            if countsAsFile { $0.filesDone += 1 }
            $0.recent.insert(path, at: 0)
            if $0.recent.count > Self.recentLimit { $0.recent.removeLast($0.recent.count - Self.recentLimit) }
        }
    }

    /// Several files at once (e.g. a folder moved to the Trash in one step).
    func addFiles(_ n: Int) {
        state.withLock { $0.filesDone += n }
    }

    func finishEntry(bytes: Int64, files: Int, filesAlreadyCounted: Int, failed: Bool) {
        state.withLock {
            $0.entriesDone += 1
            $0.bytesDone += bytes
            // Top up to the entry's known file count so progress lines up after per-file deletes.
            $0.filesDone += max(0, files - filesAlreadyCounted)
            if failed { $0.failures += 1 }
        }
    }
}
