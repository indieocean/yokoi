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
        case .video: String(localized: "Video", comment: "Big-file filter")
        case .archive: String(localized: "Archives", comment: "Big-file filter")
        case .diskImage: String(localized: "Disk images", comment: "Big-file filter")
        case .art: String(localized: "3D / Art", comment: "Big-file filter: 3D models and art files")
        case .vm: String(localized: "VMs", comment: "Big-file filter: virtual machines")
        case .audio: String(localized: "Audio", comment: "Big-file filter")
        case .other: String(localized: "Other", comment: "Big-file filter")
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
    var restoreHint: String { String(localized: "restore from the Trash if you change your mind", comment: "How to get a removed file back") }
    var safety: SafetyLevel { .review }
    var name: String { url.lastPathComponent }
    var location: String { PathFormat.abbreviate(url.deletingLastPathComponent()) }
    var badge: String {
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? String(localized: "FILE", comment: "Badge for a file with no extension; keep it 4 letters or fewer") : String(ext.prefix(4))
    }
}

/// One copy of a file that exists more than once. Each copy is its own item, so a cleanup can only ever name
/// the copies picked: nothing here stands for a whole group.
struct DuplicateFile: Reclaimable, Codable, Hashable {
    var id: String { url.path }
    let url: URL
    /// SHA-256 of the contents. Copies with the same digest are one group.
    let digest: String
    /// Length of the file.
    let fileSize: Int64
    /// What removing this copy frees: nothing for an APFS clone or a file hardlinked elsewhere.
    let size: Int64
    let modified: Date
    /// The git work tree this copy is in. A project may need its copy, so it's never picked automatically.
    let repository: URL?

    var category: CleanCategory { .duplicates }
    var title: String { url.lastPathComponent }
    var urls: [URL] { [url] }
    var fileCount: Int { 1 }
    var restoreHint: String { String(localized: "restore from the Trash if you change your mind", comment: "How to get a removed file back") }
    var safety: SafetyLevel { .review }
    var name: String { url.lastPathComponent }
    var location: String { PathFormat.abbreviate(url.deletingLastPathComponent()) }
}

/// A file the duplicate scan couldn't compare, so it may have copies that aren't listed.
struct SkippedFile: Codable, Hashable, Sendable, Identifiable {
    enum Reason: String, Codable, Sendable {
        case cloudOnly, unreadable

        var label: String {
            switch self {
            case .cloudOnly: String(localized: "In the cloud only", comment: "Why a file couldn't be compared for duplicates")
            case .unreadable: String(localized: "Couldn't be read", comment: "Why a file couldn't be compared for duplicates")
            }
        }
    }

    var id: String { url.path }
    let url: URL
    let reason: Reason
}

/// Copies of one file, with the one best worth keeping first.
struct DuplicateGroup: Identifiable, Hashable, Sendable {
    var id: String { digest }
    let digest: String
    let files: [DuplicateFile]

    init(digest: String, files: [DuplicateFile]) {
        self.digest = digest
        self.files = files.sorted { Self.keepOrder($0) < Self.keepOrder($1) }
    }

    /// Lower is better to keep: anything in a repository, then anything outside Downloads, then the shortest
    /// path ("clip.mov" over "clip copy.mov").
    private static func keepOrder(_ f: DuplicateFile) -> KeepOrder {
        KeepOrder(outsideRepository: f.repository == nil ? 1 : 0, inDownloads: f.url.path.contains("/Downloads/") ? 1 : 0,
                  length: f.url.path.count, path: f.url.path)
    }

    private struct KeepOrder: Comparable {
        let outsideRepository: Int, inDownloads: Int, length: Int, path: String
        static func < (a: KeepOrder, b: KeepOrder) -> Bool {
            (a.outsideRepository, a.inDownloads, a.length, a.path) < (b.outsideRepository, b.inDownloads, b.length, b.path)
        }
    }

    /// Groups copies by contents, biggest saving first. A copy left on its own is no longer a duplicate, and
    /// copies that are all in repositories aren't shown: that's build output and vendored code, which the
    /// projects need or rebuild. A match with a file elsewhere still shows, since that file is the one to remove.
    /// - Parameter includingRepositories: show them anyway, for a folder the user chose to look through.
    static func groups(_ files: [DuplicateFile], includingRepositories: Bool = false) -> [DuplicateGroup] {
        Dictionary(grouping: files, by: \.digest)
            .filter { $0.value.count > 1 && (includingRepositories || $0.value.contains { $0.repository == nil }) }
            .map { DuplicateGroup(digest: $0.key, files: $0.value) }
            .sorted { ($0.reclaimable, $1.digest) > ($1.reclaimable, $0.digest) }
    }

    var name: String { files[0].name }
    var fileSize: Int64 { files[0].fileSize }
    var badge: String {
        let ext = files[0].url.pathExtension.uppercased()
        return ext.isEmpty ? String(localized: "FILE", comment: "Badge for a file with no extension; keep it 4 letters or fewer") : String(ext.prefix(4))
    }

    /// What's freed by keeping the copy that frees least. Clones of each other free nothing between them, so
    /// the result can come out low, never high.
    var reclaimable: Int64 {
        files.reduce(0) { $0 + $1.size } - (files.map(\.size).min() ?? 0)
    }

    /// The copies "select extras" picks: all but the best one, and never one inside a repository.
    var extras: [DuplicateFile] { files.dropFirst().filter { $0.repository == nil } }

    /// The copies in `ids` that may go. If that's every copy, the best one stays.
    func removable(from ids: Set<String>) -> [DuplicateFile] {
        let picked = files.filter { ids.contains($0.id) }
        return picked.count == files.count ? Array(picked.dropFirst()) : picked
    }

    /// Cleanups of the copies in `ids`, each refused by `CleanupService` unless a copy left out survives it.
    func entries(removing ids: Set<String>) -> [CleanupEntry] {
        let removing = removable(from: ids)
        let kept = files.filter { !removing.contains($0) }.map(FileSnapshot.init)
        return removing.map { file in
            var entry = CleanupEntry(file)
            entry.keepCheck = KeepCheck(digest: digest, target: FileSnapshot(file), keep: kept)
            return entry
        }
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
    var restoreHint: String { String(localized: "restore from the Trash if you change your mind", comment: "How to get a removed file back") }

    func ageInDays(now: Date = Date()) -> Int { Int(now.timeIntervalSince(created) / 86_400) }
}

enum DownloadKind: String, Codable, Sendable, CaseIterable {
    case installer, archive, image, video, audio, document, folder, incomplete, other

    var filterTitle: String {
        switch self {
        case .installer: String(localized: "Installers", comment: "Downloads filter")
        case .archive: String(localized: "Archives", comment: "Downloads filter")
        case .image: String(localized: "Images", comment: "Downloads filter")
        case .video: String(localized: "Video", comment: "Downloads filter")
        case .audio: String(localized: "Audio", comment: "Downloads filter")
        case .document: String(localized: "Documents", comment: "Downloads filter")
        case .folder: String(localized: "Folders", comment: "Downloads filter")
        case .incomplete: String(localized: "Incomplete", comment: "Downloads filter: partially downloaded files")
        case .other: String(localized: "Other", comment: "Downloads filter")
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
    var restoreHint: String { String(localized: "restore from the Trash if you change your mind", comment: "How to get a removed file back") }

    /// Safe: leftovers with no value of their own. Re-download: installers. Everything else is yours to review.
    var safety: SafetyLevel {
        if kind == .incomplete || isExtracted { return .safe }
        if kind == .installer { return .redownload }
        return .review
    }

    /// Why it's probably clutter, shown next to the name.
    var note: String? {
        if kind == .incomplete { return String(localized: "Incomplete download", comment: "Note next to a download: the browser never finished it") }
        if isExtracted { return String(localized: "Already extracted", comment: "Note next to a downloaded archive whose contents sit next to it") }
        if kind == .installer { return String(localized: "Installer", comment: "Note next to a downloaded installer (.dmg, .pkg)") }
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
