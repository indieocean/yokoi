import Foundation
import UniformTypeIdentifiers

/// Finds large files under the big-file locations (home by default). Skips `~/Library`, the Trash,
/// hidden folders, `node_modules` and app bundle internals (PRD FR-F5). VM and media bundles
/// (`.utm`, `.sparsebundle`…) are reported as single items.
struct BigFileScanner: CategoryScanner {
    var category: CleanCategory { .bigFiles }

    static let bundleExtensions: Set<String> = ["utm", "pvm", "vmwarevm", "sparsebundle", "fcpbundle", "logicx", "band"]

    static let kinds: [BigFileKind: Set<String>] = [
        .video: ["mov", "mp4", "m4v", "mkv", "avi", "webm", "mxf", "mts", "braw", "r3d", "fcpbundle"],
        .archive: ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "xip", "zst", "lz4", "jar", "war"],
        .diskImage: ["dmg", "iso", "img", "sparseimage", "sparsebundle", "toast", "ipsw"],
        .art: ["psd", "psb", "fbx", "blend", "obj", "uasset", "umap", "exr", "tif", "tiff", "kra", "ma", "mb", "max",
               "usd", "usdz", "usdc", "glb", "gltf", "abc", "spp", "sbsar", "ztl", "c4d", "hdr", "raw", "dng", "aep", "prproj"],
        .vm: ["utm", "vmdk", "vdi", "qcow2", "pvm", "vmwarevm", "vhd", "vhdx", "ova", "ovf", "hdd", "box"],
        .audio: ["wav", "aif", "aiff", "flac", "mp3", "m4a", "caf", "logicx", "band"],
    ]

    static func kind(for url: URL) -> BigFileKind {
        let ext = url.pathExtension.lowercased()
        for (kind, exts) in kinds where exts.contains(ext) { return kind }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .diskImage) { return .diskImage }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .image) || type.conforms(to: .threeDContent) { return .art }
        return .other
    }

    func scan(_ context: ScanContext, progress: ScanProgress) -> AsyncStream<BigFileItem> {
        makeStream { yield in
            let home = context.home.standardizedFileURL
            let roots = context.bigFileRoots.map(\.standardizedFileURL)
            let unique = roots.filter { r in !roots.contains { o in o != r && r.path.hasPrefix(o.path + "/") } }
            await withTaskGroup(of: Void.self) { group in
                for root in unique where !context.isExcluded(root) {
                    for entry in FileWalker.list(root) {
                        if Task.isCancelled { break }
                        if let item = Self.check(entry: entry, context: context, home: home, progress: progress) {
                            yield(item)
                        } else if Self.shouldDescend(entry, context: context, home: home) {
                            let url = entry.url
                            group.addTask { Self.walkCached(url, depth: 1, context: context, home: home, progress: progress, yield: yield) }
                        }
                    }
                }
            }
        }
    }

    static func shouldDescend(_ e: FileWalker.Entry, context: ScanContext, home: URL) -> Bool {
        e.isDirectory && !e.isSymlink && !e.isPackage && !e.name.hasPrefix(".")
            && !ArtifactRule.skippedDirectoryNames.contains(e.name)
            && PathFormat.canonical(e.url.path) != PathFormat.canonical(home.appendingPathComponent("Library").path)
            && !context.isExcluded(e.url)
    }

    /// Returns an item if this entry is itself a big file or a big bundle.
    static func check(entry e: FileWalker.Entry, context: ScanContext, home: URL, progress: ScanProgress) -> BigFileItem? {
        if e.isSymlink || e.name.hasPrefix(".") || context.isExcluded(e.url) { return nil }
        if e.isDirectory {
            guard e.isPackage, bundleExtensions.contains(e.url.pathExtension.lowercased()) else { return nil }
        }
        let m = FileWalker.measure(e.url)
        guard m.size >= context.bigFileFloor else { return nil }
        let modified = (try? e.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return BigFileItem(url: e.url, kind: kind(for: e.url), size: m.size, modified: modified, isBundle: e.isDirectory)
    }

    /// Folders this many levels below a big-file location (e.g. `~/Documents/Projects/game`) are the
    /// smallest units reused by incremental rescans, so one busy project doesn't force a rewalk of the rest.
    static let cachedDepth = 3

    /// `walk`, reusing the last scan's results for folders where nothing changed. Returns what it found.
    @discardableResult
    static func walkCached(_ dir: URL, depth: Int, context: ScanContext, home: URL, progress: ScanProgress,
                           yield: (BigFileItem) -> Void) -> [BigFileItem] {
        guard let index = context.index else {
            walk(dir, context: context, home: home, progress: progress, yield: yield)
            return []
        }
        if let cached = index.bigFiles(under: dir) {
            cached.forEach(yield)
            return cached
        }
        var found: [BigFileItem] = []
        if depth >= cachedDepth {
            walk(dir, context: context, home: home, progress: progress) { found.append($0); yield($0) }
        } else {
            let entries = FileWalker.list(dir)
            progress.visited(files: entries.count, path: dir.path)
            for entry in entries {
                if Task.isCancelled { break }
                if let item = check(entry: entry, context: context, home: home, progress: progress) {
                    found.append(item)
                    yield(item)
                } else if shouldDescend(entry, context: context, home: home) {
                    found += walkCached(entry.url, depth: depth + 1, context: context, home: home, progress: progress, yield: yield)
                }
            }
        }
        index.store(bigFiles: found, under: dir)
        return found
    }

    static func walk(_ dir: URL, context: ScanContext, home: URL, progress: ScanProgress, yield: (BigFileItem) -> Void) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isRegularFileKey,
                                      .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                     errorHandler: { _, _ in true }) else { return }
        var count = 0
        while let url = e.nextObject() as? URL {
            count += 1
            if count % 2048 == 0 {
                if Task.isCancelled { return }
                progress.visited(files: 2048, path: url.path)
            }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { continue }
            if v.isDirectory == true {
                let name = url.lastPathComponent
                if v.isPackage == true {
                    if bundleExtensions.contains(url.pathExtension.lowercased()), !context.isExcluded(url) {
                        let m = FileWalker.measure(url)
                        if m.size >= context.bigFileFloor {
                            yield(BigFileItem(url: url, kind: kind(for: url), size: m.size, modified: v.contentModificationDate, isBundle: true))
                        }
                    }
                    continue
                }
                if ArtifactRule.skippedDirectoryNames.contains(name) || context.isExcluded(url) {
                    e.skipDescendants()
                }
                continue
            }
            let size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            if size >= context.bigFileFloor, !context.isExcluded(url) {
                yield(BigFileItem(url: url, kind: kind(for: url), size: size, modified: v.contentModificationDate, isBundle: false))
            }
        }
        progress.visited(files: count % 2048)
    }
}
