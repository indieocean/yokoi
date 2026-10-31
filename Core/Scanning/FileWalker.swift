import Foundation

/// Synchronous file-system helpers. They run inside scanner tasks and check `Task.isCancelled`
/// as they go. (Directory enumerators can't be iterated directly from async code in Swift 6.)
enum FileWalker {
    struct Measurement: Sendable, Equatable {
        var size: Int64 = 0
        var files: Int = 0
        var newestModification: Date?

        static func + (a: Measurement, b: Measurement) -> Measurement {
            Measurement(size: a.size + b.size, files: a.files + b.files,
                        newestModification: [a.newestModification, b.newestModification].compactMap { $0 }.max())
        }
    }

    struct Entry: Sendable {
        let url: URL
        let name: String
        let isDirectory: Bool
        let isSymlink: Bool
        let isPackage: Bool
    }

    static let measureKeys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey,
    ]
    static let listKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]

    /// Allocated size and file count of a file or folder. Symlinks are counted as links, never followed.
    static func measure(_ url: URL, progress: ScanProgress? = nil) -> Measurement {
        let fm = FileManager.default
        guard let values = try? url.resourceValues(forKeys: Set(measureKeys)) else { return Measurement() }
        if values.isSymbolicLink == true || values.isDirectory != true {
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            return Measurement(size: size, files: 1, newestModification: values.contentModificationDate)
        }
        var m = Measurement()
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: measureKeys, options: [], errorHandler: { _, _ in true }) else {
            return m
        }
        var tick = 0
        while let item = e.nextObject() as? URL {
            tick += 1
            if tick % 2048 == 0 {
                if Task.isCancelled { break }
                progress?.visited(files: 2048, path: item.path)
            }
            guard let v = try? item.resourceValues(forKeys: Set(measureKeys)) else { continue }
            if v.isDirectory == true && v.isSymbolicLink != true { continue }
            m.size += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            m.files += 1
        }
        progress?.visited(files: tick % 2048)
        return m
    }

    /// Lists a directory's direct children (hidden files included). Returns `[]` when unreadable.
    static func list(_ url: URL) -> [Entry] {
        guard let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: listKeys, options: []) else {
            return []
        }
        return children.map { child in
            let v = try? child.resourceValues(forKeys: Set(listKeys))
            return Entry(url: child, name: child.lastPathComponent,
                         isDirectory: v?.isDirectory ?? false,
                         isSymlink: v?.isSymbolicLink ?? false,
                         isPackage: v?.isPackage ?? false)
        }
    }

    /// Newest modification date of the project's own files, skipping dependency and build folders.
    /// Falls back to the last git commit date (PRD FR-N3). Bounded so huge repos stay fast.
    static func lastTouched(project: URL, skipping skipNames: Set<String>, limit: Int = 25_000) -> Date? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey]
        var newest: Date?
        if let e = FileManager.default.enumerator(at: project, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) {
            var count = 0
            while let item = e.nextObject() as? URL {
                count += 1
                if count > limit || (count % 1024 == 0 && Task.isCancelled) { break }
                let name = item.lastPathComponent
                guard let v = try? item.resourceValues(forKeys: Set(keys)) else { continue }
                if v.isDirectory == true {
                    if skipNames.contains(name) || name == ".git" || name.hasPrefix(".") { e.skipDescendants() }
                    continue
                }
                if name == ".DS_Store" { continue }
                if let d = v.contentModificationDate, d > (newest ?? .distantPast) { newest = d }
            }
        }
        return newest ?? gitLastCommitDate(project)
    }

    /// Reads the timestamp of the last entry in `.git/logs/HEAD` without running git.
    static func gitLastCommitDate(_ project: URL) -> Date? {
        let log = project.appendingPathComponent(".git/logs/HEAD")
        guard let data = try? Data(contentsOf: log), let text = String(data: data, encoding: .utf8) else { return nil }
        guard let last = text.split(separator: "\n").last else { return nil }
        // "<old> <new> Name <email> 1698765432 +0100\tcommit: message"
        let head = last.split(separator: "\t").first ?? last
        let parts = head.split(separator: " ")
        guard parts.count >= 2, let ts = TimeInterval(parts[parts.count - 2]) else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    /// Runs `body` over `items` with at most `limit` tasks in flight, returning results as they finish.
    static func concurrentMap<T: Sendable, R: Sendable>(
        _ items: [T], limit: Int, _ body: @escaping @Sendable (T) async -> R?
    ) -> AsyncStream<R> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: R?.self) { group in
                    var iterator = items.makeIterator()
                    for _ in 0..<max(1, limit) {
                        guard let next = iterator.next() else { break }
                        group.addTask { await body(next) }
                    }
                    while let result = await group.next() {
                        if let result { continuation.yield(result) }
                        if Task.isCancelled { group.cancelAll(); break }
                        if let next = iterator.next() { group.addTask { await body(next) } }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
