import CoreServices
import Foundation

/// Lists the direct children of `~/Downloads`: files, folders (sized as a whole), installers and archives.
/// Screenshots saved to Downloads are left to the Screenshots screen.
struct DownloadsScanner: CategoryScanner {
    var category: CleanCategory { .downloads }

    static let ignored: Set<String> = [".DS_Store", ".localized", "Icon\r"]

    func scan(_ context: ScanContext, progress: ScanProgress) -> AsyncStream<DownloadItem> {
        makeStream { yield in
            let folder = context.downloadsURL
            guard !context.isExcluded(folder) else { return }
            let entries = FileWalker.list(folder)
            let names = Set(entries.map(\.name))
            let screenshotsHere = context.screenshotFolder.standardizedFileURL.path == folder.standardizedFileURL.path
            for entry in entries where !entry.isSymlink && !Self.ignored.contains(entry.name) && !entry.name.hasPrefix(".") {
                if Task.isCancelled { return }
                guard !context.isExcluded(entry.url) else { continue }
                if screenshotsHere && ScreenshotScanner.item(for: entry.url, context: context) != nil { continue }
                yield(Self.item(for: entry, siblings: names, context: context, progress: progress))
            }
        }
    }

    static func item(for entry: FileWalker.Entry, siblings: Set<String>, context: ScanContext, progress: ScanProgress? = nil) -> DownloadItem {
        let kind = DownloadKind.of(entry.url, isDirectory: entry.isDirectory, isPackage: entry.isPackage)
        let m = context.measure(entry.url, progress: progress)
        progress?.visited(files: entry.isDirectory ? 0 : 1, path: entry.url.path)
        let v = try? entry.url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
        return DownloadItem(url: entry.url, kind: kind, size: m.size, fileCount: max(m.files, 1),
                            added: v?.addedToDirectoryDate ?? v?.creationDate,
                            lastOpened: lastUsed(entry.url),
                            isExtracted: kind == .archive && extractedName(entry.name).map { siblings.contains($0) } == true)
    }

    /// `foo.zip` → `foo`, `foo.tar.gz` → `foo`. Nil when stripping leaves nothing.
    static func extractedName(_ name: String) -> String? {
        var base = name as NSString
        while DownloadKind.archiveExtensions.contains(base.pathExtension.lowercased()) {
            base = base.deletingPathExtension as NSString
        }
        let out = base as String
        return out.isEmpty || out == name ? nil : out
    }

    static func lastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL),
              let value = MDItemCopyAttribute(item, kMDItemLastUsedDate) else { return nil }
        return value as? Date
    }
}
