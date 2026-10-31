import CoreServices
import Foundation

/// Finds screenshots and screen recordings in the screenshot folder by filename and by the
/// Spotlight `kMDItemIsScreenCapture` flag (PRD FR-S1).
struct ScreenshotScanner: CategoryScanner {
    var category: CleanCategory { .screenshots }

    static let namePrefixes = [
        "Screenshot", "Screen Shot", "Screen Recording", "CleanShot",
        "Bildschirmfoto", "Bildschirmaufnahme", "Capture d’écran", "Capture d'écran", "Enregistrement de l’écran",
        "Captura de pantalla", "Grabación de pantalla", "Schermafbeelding", "Skärmavbild", "Istantanea",
        "スクリーンショット", "画面収録", "截屏", "屏幕录制", "Снимок экрана",
    ]
    static let movieExtensions: Set<String> = ["mov", "mp4", "m4v"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "pdf"]

    func scan(_ context: ScanContext, progress: ScanProgress) -> AsyncStream<ScreenshotItem> {
        makeStream { yield in
            let folder = context.screenshotFolder
            guard !context.isExcluded(folder) else { return }
            for entry in FileWalker.list(folder) where !entry.isDirectory && !entry.isSymlink {
                if Task.isCancelled { return }
                guard let item = Self.item(for: entry.url, context: context) else { continue }
                yield(item)
            }
        }
    }

    static func item(for url: URL, context: ScanContext) -> ScreenshotItem? {
        let ext = url.pathExtension.lowercased()
        guard movieExtensions.contains(ext) || imageExtensions.contains(ext), !context.isExcluded(url) else { return nil }
        let name = url.lastPathComponent
        let matchesName = namePrefixes.contains { name.hasPrefix($0) }
        guard matchesName || isScreenCapture(url) else { return nil }
        let v = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        let size = Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        let created = v?.creationDate ?? v?.contentModificationDate ?? Date()
        let isRecording = movieExtensions.contains(ext)
        return ScreenshotItem(url: url, size: size, created: created, isRecording: isRecording)
    }

    static func isScreenCapture(_ url: URL) -> Bool {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL),
              let value = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }

    /// The folder macOS saves screenshots to (`defaults read com.apple.screencapture location`), or the Desktop.
    static func systemScreenshotFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !location.isEmpty {
            let url = PathFormat.expand((location as NSString).expandingTildeInPath, home: home)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
        }
        return home.appendingPathComponent("Desktop")
    }
}
