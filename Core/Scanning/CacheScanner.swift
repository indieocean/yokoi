import Foundation

/// Measures the known cache locations (PRD §5.4). Only locations that exist are reported.
struct CacheScanner: CategoryScanner {
    var category: CleanCategory { .caches }
    var locations: [CacheLocation] = CacheLocation.all

    func scan(_ context: ScanContext, progress: ScanProgress) -> AsyncStream<CacheItem> {
        let locations = self.locations
        return makeStream { yield in
            for await item in FileWalker.concurrentMap(locations, limit: context.concurrency, { location in
                Self.measure(location, all: locations, context: context, progress: progress)
            }) {
                yield(item)
            }
        }
    }

    static func measure(_ location: CacheLocation, all: [CacheLocation], context: ScanContext, progress: ScanProgress) -> CacheItem? {
        if Task.isCancelled { return nil }
        let url = location.url(home: context.home)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
              !context.isExcluded(url) else { return nil }

        // Children covered by more specific locations (e.g. ~/Library/Caches/Homebrew) are skipped
        // so "User caches" doesn't count them twice.
        var nested = Set<String>()
        if location.excludesNestedLocations {
            let prefix = location.relativePath + "/"
            for other in all where other.id != location.id && other.relativePath.hasPrefix(prefix) {
                if let first = other.relativePath.dropFirst(prefix.count).split(separator: "/").first {
                    nested.insert(String(first))
                }
            }
            for rule in GlobalArtifactRule.all where rule.relativePath.hasPrefix(prefix) {
                if let first = rule.relativePath.dropFirst(prefix.count).split(separator: "/").first {
                    nested.insert(String(first))
                }
            }
        }

        let extensions = location.onlyExtensions.map { Set($0.map { $0.lowercased() }) }
        let contents = FileWalker.list(url).filter { child in
            if let extensions {
                guard !child.isSymlink, extensions.contains(child.url.pathExtension.lowercased()) else { return false }
            }
            return child.name != ".DS_Store"
                && !nested.contains(child.name)
                && !location.keepChildren.contains { fnmatch($0, child.name, 0) == 0 }
                && !context.isExcluded(child.url)
        }.map(\.url)

        let m = contents.reduce(FileWalker.Measurement()) { $0 + context.measure($1, progress: progress) }
        return CacheItem(
            locationID: location.id, name: location.name, section: location.section, url: url,
            contents: contents, safety: location.safety, badge: location.badge, colorHex: location.colorHex,
            size: m.size, fileCount: m.files, restoreHint: location.restoreHint,
            permanentOnly: location.permanentOnly
        )
    }
}
