import Foundation

/// Anything the user can clean. `urls` are the exact paths that get trashed, deleted or moved.
protocol Reclaimable: Sendable, Identifiable where ID == String {
    var category: CleanCategory { get }
    var title: String { get }
    var urls: [URL] { get }
    var size: Int64 { get }
    var fileCount: Int { get }
    /// When the owning project was last changed. Used for active-project protection.
    var projectLastTouched: Date? { get }
    var restoreHint: String { get }
    var safety: SafetyLevel { get }
}

extension Reclaimable {
    var projectLastTouched: Date? { nil }
    var safety: SafetyLevel { .safe }
}

struct NodeModulesItem: Reclaimable, Codable, Hashable {
    var id: String { url.path }
    let url: URL
    let projectURL: URL
    let projectName: String
    let frameworkHint: String
    let packageManager: JSPackageManager?
    let size: Int64
    let fileCount: Int
    let lastTouched: Date?

    var category: CleanCategory { .nodeModules }
    var title: String { projectName }
    var urls: [URL] { [url] }
    var projectLastTouched: Date? { lastTouched }
    var restoreHint: String { (packageManager ?? .npm).installCommand }

    /// Unknown age is *not* stale: when in doubt, don't preselect it for deletion.
    func isStale(days: Int, now: Date = Date()) -> Bool {
        guard let lastTouched else { return false }
        return now.timeIntervalSince(lastTouched) > Double(days) * 86_400
    }
}

struct ArtifactItem: Reclaimable, Codable, Hashable {
    var id: String { "\(ruleID)|\(optIn)|\(projectURL.path)" }
    let ruleID: String
    let ecosystem: Ecosystem
    let projectURL: URL
    let projectName: String
    /// The concrete folders that will be removed.
    let targets: [URL]
    let optIn: Bool
    let note: String?
    let isGlobal: Bool
    let size: Int64
    let fileCount: Int
    let lastTouched: Date?
    let restoreHint: String

    var category: CleanCategory { .buildArtifacts }
    var title: String { projectName }
    var urls: [URL] { targets }
    var projectLastTouched: Date? { isGlobal ? nil : lastTouched }

    /// `~/games/Orbital/{Intermediate,Saved,DerivedDataCache}` style display path.
    var displayPath: String {
        let base = PathFormat.abbreviate(projectURL)
        if isGlobal { return base }
        let rels = targets.map { url -> String in
            let p = url.path
            let root = projectURL.path
            return p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : url.lastPathComponent
        }
        if rels.count == 1 { return "\(base)/\(rels[0])" }
        // Collapse children of the same folder (Saved/Logs, Saved/Crashes → Saved) and nested __pycache__.
        var tops: [String] = []
        for r in rels {
            let top = r.hasSuffix("__pycache__") && r.contains("/")
                ? "**/__pycache__"
                : String(r.split(separator: "/").first ?? Substring(r))
            if !tops.contains(top) { tops.append(top) }
        }
        if tops.count == 1 { return "\(base)/\(tops[0])" }
        return "\(base)/{\(tops.joined(separator: ","))}"
    }
}

struct CacheItem: Reclaimable, Codable, Hashable {
    var id: String { locationID }
    let locationID: String
    let name: String
    let section: CacheLocation.Section
    let url: URL
    /// The children that will be removed (the folder itself is kept).
    var contents: [URL]
    let safety: SafetyLevel
    let badge: String
    let colorHex: UInt32
    var size: Int64
    var fileCount: Int
    let restoreHint: String
    var permanentOnly: Bool = false
    /// The contents as individually selectable rows (an old simulator, one archive). Nil when the location
    /// isn't broken down, or for scans cached before breakdowns existed.
    var children: [CacheChild]? = nil

    var category: CleanCategory { .caches }
    var title: String { name }
    var urls: [URL] { contents }

    /// Cleanup id of one child: distinct from the location's own id, so cleaning a child keeps the location.
    func entryID(for child: CacheChild) -> String { "\(locationID)#\(child.id)" }

    /// A cleanup of just `child`, with the location's safety and restore hint.
    func entry(for child: CacheChild) -> CleanupEntry {
        var entry = CleanupEntry(id: entryID(for: child), category: .caches, label: "\(name) · \(child.name)",
                                 displayPath: PathFormat.abbreviate(child.urls[0]), urls: child.urls, size: child.size,
                                 fileCount: child.fileCount, safety: safety, restoreHint: restoreHint)
        entry.permanentOnly = permanentOnly
        // Only the emulator using this AVD blocks it, not any running emulator.
        if CacheLocation.inUseGuarded.contains(locationID) { entry.projectRoot = child.urls[0] }
        entry.usedByApps = CacheLocation.byID[locationID]?.usedByApps ?? []
        return entry
    }

    /// This location without the children whose entry ids are in `ids`; nil when nothing changed.
    func removingChildren(entryIDs ids: Set<String>) -> CacheItem? {
        guard let children, children.contains(where: { ids.contains(entryID(for: $0)) }) else { return nil }
        var copy = self
        let kept = children.filter { !ids.contains(entryID(for: $0)) }
        copy.children = kept
        copy.contents = kept.flatMap(\.urls)
        copy.size = kept.reduce(0) { $0 + $1.size }
        copy.fileCount = kept.reduce(0) { $0 + $1.fileCount }
        return copy
    }
}

/// One selectable item inside a cache location: a simulator, an archive, a model, or a top-level folder.
struct CacheChild: Codable, Hashable, Sendable, Identifiable {
    var id: String { urls[0].path }
    /// What gets removed. Usually one path; an Android emulator is its `.avd` folder plus its `.ini`.
    let urls: [URL]
    let name: String
    /// Secondary text, e.g. "iOS 17.5" for a simulator or "1.2 (45)" for an archive.
    let detail: String?
    let size: Int64
    let fileCount: Int
    /// When it was made (archives) or last changed.
    let date: Date?
}

enum BigFileKind: String, Codable, Sendable, CaseIterable {
    case video, archive, diskImage, art, vm, audio, other

    var filterTitle: String {
        switch self {
        case .video: "Video"
        case .archive: "Archives"
        case .diskImage: "Disk images"
        case .art: "3D / Art"
        case .vm: "VMs"
        case .audio: "Audio"
        case .other: "Other"
        }
    }

    var colorHex: UInt32 {
        switch self {
        case .video: 0xF472B6
        case .archive: 0xFACC15
        case .diskImage: 0x60A5FA
        case .art: 0xA78BFA
        case .vm: 0xF97316
        case .audio: 0x34D399
        case .other: 0x7D8597
        }
    }

    static let filters: [BigFileKind] = [.video, .archive, .diskImage, .art, .vm]
}

struct BigFileItem: Reclaimable, Codable, Hashable {
    var id: String { url.path }
    let url: URL
    let kind: BigFileKind
    let size: Int64
    let modified: Date?
    let isBundle: Bool

    var category: CleanCategory { .bigFiles }
    var title: String { url.lastPathComponent }
    var urls: [URL] { [url] }
    var fileCount: Int { 1 }
    var restoreHint: String { "restore from the Trash if you change your mind" }
    var safety: SafetyLevel { .review }
    var name: String { url.lastPathComponent }
    var location: String { PathFormat.abbreviate(url.deletingLastPathComponent()) }
    var badge: String {
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "FILE" : String(ext.prefix(4))
    }
}

struct ScreenshotItem: Reclaimable, Codable, Hashable {
    var id: String { url.path }
    let url: URL
    let size: Int64
    let created: Date
    let isRecording: Bool

    var category: CleanCategory { .screenshots }
    var title: String { url.lastPathComponent }
    var urls: [URL] { [url] }
    var fileCount: Int { 1 }
    var restoreHint: String { "restore from the Trash if you change your mind" }

    func ageInDays(now: Date = Date()) -> Int { Int(now.timeIntervalSince(created) / 86_400) }
}

enum DownloadKind: String, Codable, Sendable, CaseIterable {
    case installer, archive, image, video, audio, document, folder, incomplete, other

    var filterTitle: String {
        switch self {
        case .installer: "Installers"
        case .archive: "Archives"
        case .image: "Images"
        case .video: "Video"
        case .audio: "Audio"
        case .document: "Documents"
        case .folder: "Folders"
        case .incomplete: "Incomplete"
        case .other: "Other"
        }
    }

    var colorHex: UInt32 {
        switch self {
        case .installer: 0x60A5FA
        case .archive: 0xFACC15
        case .image: 0xF472B6
        case .video: 0xFB7185
        case .audio: 0x34D399
        case .document: 0xA78BFA
        case .folder: 0x7DD3FC
        case .incomplete: 0xF97316
        case .other: 0x7D8597
        }
    }

    static let filters: [DownloadKind] = [.installer, .archive, .image, .video, .document, .folder]

    static func of(_ url: URL, isDirectory: Bool, isPackage: Bool) -> DownloadKind {
        let ext = url.pathExtension.lowercased()
        if incompleteExtensions.contains(ext) { return .incomplete }
        if installerExtensions.contains(ext) { return .installer }
        if isDirectory && !isPackage { return .folder }
        if archiveExtensions.contains(ext) { return .archive }
        if ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "tif", "svg", "psd", "bmp", "raw", "avif"].contains(ext) { return .image }
        if ["mov", "mp4", "m4v", "mkv", "avi", "webm"].contains(ext) { return .video }
        if ["mp3", "wav", "m4a", "aac", "flac", "aiff", "ogg"].contains(ext) { return .audio }
        if ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "txt", "md", "rtf",
            "csv", "epub", "json", "xml", "html"].contains(ext) { return .document }
        return .other
    }

    /// Browsers' partial files (Chrome, Firefox, Safari's `.download` bundle, Opera).
    static let incompleteExtensions: Set<String> = ["crdownload", "part", "download", "opdownload", "partial"]
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip", "app"]
    static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst"]
}

/// A top-level item in `~/Downloads`. Folders are one item with their total size.
struct DownloadItem: Reclaimable, Codable, Hashable {
    var id: String { url.path }
    let url: URL
    let kind: DownloadKind
    let size: Int64
    let fileCount: Int
    /// When it landed in Downloads (`addedToDirectoryDate`, falling back to the creation date).
    let added: Date?
    /// When it was last opened (Spotlight `kMDItemLastUsedDate`), if ever.
    let lastOpened: Date?
    /// The archive's contents sit next to it (`foo.zip` and `foo/`).
    let isExtracted: Bool

    var category: CleanCategory { .downloads }
    var title: String { url.lastPathComponent }
    var name: String { url.lastPathComponent }
    var urls: [URL] { [url] }
    var restoreHint: String { "restore from the Trash if you change your mind" }

    /// Safe: leftovers with no value of their own. Re-download: installers. Everything else is yours to review.
    var safety: SafetyLevel {
        if kind == .incomplete || isExtracted { return .safe }
        if kind == .installer { return .redownload }
        return .review
    }

    /// Why it's probably clutter, shown next to the name.
    var note: String? {
        if kind == .incomplete { return "Incomplete download" }
        if isExtracted { return "Already extracted" }
        if kind == .installer { return "Installer" }
        return nil
    }

    /// The newer of "added" and "last opened".
    var lastTouched: Date? { [added, lastOpened].compactMap { $0 }.max() }

    /// Unknown age is not old: when in doubt, don't count it or preselect it.
    func isOld(days: Int, now: Date = Date()) -> Bool {
        guard let lastTouched else { return false }
        return now.timeIntervalSince(lastTouched) > Double(days) * 86_400
    }
}

enum Overlap {
    /// Big files already counted inside a reclaimable download (the file itself, or a file in a downloaded
    /// folder). Subtracted from totals so the same bytes aren't counted twice.
    static func bigFileBytesInDownloads(_ bigFiles: [BigFileItem], threshold: Int64, downloads: [DownloadItem], ageDays: Int) -> Int64 {
        let counted = downloads.filter { $0.isOld(days: ageDays) }.map(\.url.path)
        guard !counted.isEmpty else { return 0 }
        return bigFiles.filter { f in
            f.size >= threshold && counted.contains { f.url.path == $0 || f.url.path.hasPrefix($0 + "/") }
        }.reduce(0) { $0 + $1.size }
    }
}
