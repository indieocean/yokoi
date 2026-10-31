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
    let contents: [URL]
    let safety: SafetyLevel
    let badge: String
    let colorHex: UInt32
    let size: Int64
    let fileCount: Int
    let restoreHint: String
    var permanentOnly: Bool = false

    var category: CleanCategory { .caches }
    var title: String { name }
    var urls: [URL] { contents }
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
