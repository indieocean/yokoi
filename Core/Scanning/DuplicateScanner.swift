import CryptoKit
import Foundation

/// Finds files with identical contents under the big-file locations, or in `ScanContext.duplicateFolder`,
/// skipping what `BigFileScanner` skips.
///
/// Files are narrowed by size, then by a hash of their first and last bytes, and only what's left is read in
/// full. That still reads every real duplicate from start to end, so this category runs when asked for
/// (`CleanCategory.routine` leaves it out), never as part of a routine or background scan.
///
/// Hardlinks to one file count as one file, since removing a link frees nothing. Files whose data is in the
/// cloud are left alone, because reading one would download it, and reported through `ScanProgress.skipped`
/// along with anything unreadable. Groups where removing copies can't free anything (APFS clones of each
/// other) aren't reported.
struct DuplicateScanner: CategoryScanner {
    var category: CleanCategory { .duplicates }

    /// Bytes hashed from each end of a file in the quick pass.
    static let sampleBytes = 64 * 1024
    /// Files read at once. Hashing is limited by the disk, so more doesn't help.
    static let hashConcurrency = 4

    /// A file worth comparing.
    struct Candidate: Sendable {
        let url: URL
        let size: Int64
        let modified: Date
        let device: Int32
        let inode: UInt64
        /// The contents are with a cloud provider. Reading the file would download it.
        let isCloudOnly: Bool

        /// Nil for anything but a regular file.
        init?(_ url: URL) {
            var st = stat()
            guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
            self.url = url
            isCloudOnly = st.st_flags & DuplicateScanner.datalessFlag != 0
            size = Int64(st.st_size)
            modified = FileSnapshot.modified(st)
            device = st.st_dev
            inode = UInt64(st.st_ino)
        }
    }

    /// `SF_DATALESS`: the file's contents live with a cloud provider and reading it fetches them.
    static let datalessFlag: UInt32 = 0x4000_0000

    func scan(_ context: ScanContext, progress: ScanProgress) -> AsyncStream<DuplicateFile> {
        makeStream { yield in
            let home = context.home.standardizedFileURL
            let found = await Self.candidates(context, home: home, progress: progress)
            let sameSize = Self.bucket(Self.oneLinkEach(found), by: \.size).filter { $0.count > 1 }
            let sameEnds = await Self.refine(sameSize, progress: progress) { Self.sampleDigest($0) }
            let identical = await Self.refine(sameEnds.map(\.files), progress: progress) { Self.digest($0.url) }
            guard !Task.isCancelled else { return }

            var repositories = RepositoryFinder(home: home)
            for (digest, files) in identical {
                let copies = files.map { c in
                    DuplicateFile(url: c.url, digest: digest, fileSize: c.size,
                                  size: FileWalker.measure(c.url, reclaimable: true).size, modified: c.modified,
                                  repository: repositories.find(from: c.url.deletingLastPathComponent()))
                }
                if DuplicateGroup(digest: digest, files: copies).reclaimable > 0 { copies.forEach(yield) }
            }
        }
    }

    /// Every file at or over the floor in the big-file locations.
    static func candidates(_ context: ScanContext, home: URL, progress: ScanProgress) async -> [Candidate] {
        let roots = (context.duplicateFolder.map { [$0] } ?? context.bigFileRoots).map(\.standardizedFileURL)
        let unique = Set(roots).filter { r in !roots.contains { o in o != r && r.path.hasPrefix(o.path + "/") } }
        return await withTaskGroup(of: [Candidate].self) { group in
            var top: [Candidate] = []
            for root in unique where !context.isExcluded(root) && !BigFileScanner.isSkippedHomeFolder(root, home: home) {
                for entry in FileWalker.list(root) {
                    if Task.isCancelled { break }
                    if BigFileScanner.shouldDescend(entry, context: context, home: home) {
                        let url = entry.url
                        group.addTask { walk(url, context: context, home: home, progress: progress) }
                    } else if !entry.isDirectory, !entry.isSymlink, !entry.name.hasPrefix("."), !context.isExcluded(entry.url),
                              let c = candidate(entry.url, context: context, progress: progress) {
                        top.append(c)
                    }
                }
            }
            for await part in group { top += part }
            return top
        }
    }

    private static func walk(_ dir: URL, context: ScanContext, home: URL, progress: ScanProgress) -> [Candidate] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isPackageKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                     errorHandler: { _, _ in true }) else { return [] }
        var found: [Candidate] = []
        var count = 0
        while let url = e.nextObject() as? URL {
            count += 1
            if count % 2048 == 0 {
                if Task.isCancelled { return found }
                progress.visited(files: 2048, path: url.path)
            }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                if v.isPackage != true,
                   ArtifactRule.skippedDirectoryNames.contains(url.lastPathComponent) || context.isExcluded(url)
                    || BigFileScanner.isSkippedHomeFolder(url, home: home) {
                    e.skipDescendants()
                }
                continue
            }
            guard v.isRegularFile == true, Int64(v.fileSize ?? 0) >= context.duplicateFloor, !context.isExcluded(url),
                  let c = candidate(url, context: context, progress: progress) else { continue }
            found.append(c)
        }
        progress.visited(files: count % 2048)
        return found
    }

    /// The file at `url` if it's worth comparing. One that's big enough but only in the cloud is noted as skipped.
    private static func candidate(_ url: URL, context: ScanContext, progress: ScanProgress) -> Candidate? {
        guard let c = Candidate(url), c.size >= context.duplicateFloor else { return nil }
        if c.isCloudOnly {
            progress.skipped(SkippedFile(url: url, reason: .cloudOnly))
            return nil
        }
        return c
    }

    /// Keeps one path per file on disk. Sorted, so which link is kept doesn't depend on walk order.
    static func oneLinkEach(_ files: [Candidate]) -> [Candidate] {
        var seen = Set<String>()
        return files.sorted { $0.url.path < $1.url.path }.filter { seen.insert("\($0.device):\($0.inode)").inserted }
    }

    private static func bucket<Key: Hashable>(_ files: [Candidate], by key: KeyPath<Candidate, Key>) -> [[Candidate]] {
        Array(Dictionary(grouping: files) { $0[keyPath: key] }.values)
    }

    /// Splits each group by `hash` and returns the parts that still hold two or more files. A file that can't
    /// be read is dropped, because nothing can be said about its contents.
    private static func refine(_ groups: [[Candidate]], progress: ScanProgress,
                               hash: @escaping @Sendable (Candidate) -> String?) async -> [(digest: String, files: [Candidate])] {
        struct Key: Hashable { let group: Int; let digest: String }
        let work = groups.enumerated().flatMap { index, files in files.map { (group: index, file: $0) } }
        var parts: [Key: [Candidate]] = [:]
        let hashed = FileWalker.concurrentMap(work, limit: hashConcurrency) { item -> (Key, Candidate)? in
            progress.visited(path: item.file.url.path)
            guard let digest = hash(item.file) else {
                if !Task.isCancelled { progress.skipped(SkippedFile(url: item.file.url, reason: .unreadable)) }
                return nil
            }
            return (Key(group: item.group, digest: digest), item.file)
        }
        for await (key, file) in hashed { parts[key, default: []].append(file) }
        return parts.filter { $0.value.count > 1 }.map { (digest: $0.key.digest, files: $0.value) }
    }

    /// SHA-256 of the file's first and last bytes.
    static func sampleDigest(_ file: Candidate) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            if let head = try handle.read(upToCount: sampleBytes) { hasher.update(data: head) }
            if file.size > Int64(sampleBytes) {
                try handle.seek(toOffset: UInt64(file.size - Int64(sampleBytes)))
                if let tail = try handle.read(upToCount: sampleBytes) { hasher.update(data: tail) }
            }
        } catch {
            return nil
        }
        return hex(hasher.finalize())
    }

    /// SHA-256 of the whole file. Nil if it can't be read, or if the scan was cancelled partway.
    static func digest(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if Task.isCancelled { return nil }
            do {
                // Nil or empty at the end of the file. A failed read throws, and must not pass for the end.
                guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return hex(hasher.finalize()) }
                hasher.update(data: chunk)
            } catch {
                return nil
            }
        }
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Finds the git work tree a folder belongs to. Home itself doesn't count, or a dotfiles repo would claim
    /// everything in it.
    struct RepositoryFinder {
        private let home: String
        private var known: [String: URL?] = [:]

        init(home: URL) { self.home = PathFormat.canonical(home.path) }

        mutating func find(from dir: URL) -> URL? {
            if let answer = known[dir.path] { return answer }
            let parent = dir.deletingLastPathComponent()
            var answer: URL?
            if PathFormat.canonical(dir.path) != home, parent.path != dir.path {
                let isRepository = FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path)
                answer = isRepository ? dir : find(from: parent)
            }
            known[dir.path] = .some(answer)
            return answer
        }
    }
}
