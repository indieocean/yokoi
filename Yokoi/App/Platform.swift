import AppKit
import Foundation

/// Used/free space for the volume holding the home folder.
struct DiskInfo: Equatable {
    var name: String
    var total: Int64
    var available: Int64

    var used: Int64 { max(0, total - available) }

    static func current() -> DiskInfo {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeLocalizedNameKey]
        let v = try? home.resourceValues(forKeys: keys)
        let total = Int64(v?.volumeTotalCapacity ?? 0)
        let available = v?.volumeAvailableCapacityForImportantUsage ?? Int64(v?.volumeAvailableCapacity ?? 0)
        return DiskInfo(name: v?.volumeLocalizedName ?? "Macintosh HD", total: total, available: available)
    }
}

/// Full Disk Access can't be queried directly. Reading the TCC database is the standard probe:
/// it only succeeds when the app has been granted access.
enum FullDiskAccess {
    static var isGranted: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probes = [
            home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path,
            home.appendingPathComponent("Library/Safari/Bookmarks.plist").path,
        ]
        for path in probes where FileManager.default.fileExists(atPath: path) {
            let fd = open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return true
            }
            return false
        }
        // Neither probe exists; assume access rather than nagging.
        return true
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum Finder {
    static func reveal(_ urls: [URL]) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(Array(existing.prefix(50)))
    }

    /// `title` and `prompt` are shown as is, so pass localized strings.
    @MainActor
    static func chooseFolder(title: String,
                             prompt: String = String(localized: "Choose", comment: "Open panel button: pick a folder"),
                             startingAt: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = startingAt
        return panel.runModal() == .OK ? panel.url : nil
    }
}
