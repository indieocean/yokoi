import Foundation

/// The single place that decides whether Disk Keeper may touch a path (PRD §6).
///
/// A path is allowed only when it is strictly inside an allowed root (scan roots plus known global
/// locations), is not excluded, isn't part of a `.git` folder, and isn't under a protected system folder.
/// Checks run on both the literal path and the path with parent symlinks resolved, so a symlink
/// can't be used to escape a root.
struct PathGuard: Sendable {
    enum Violation: Error, Equatable, CustomStringConvertible, Sendable {
        case outsideAllowedRoots
        case excluded
        case protectedSystemPath
        case isRootItself
        case insideGitFolder
        case protectedUserData

        var description: String {
            switch self {
            case .outsideAllowedRoots: "outside the scan locations"
            case .excluded: "in an excluded folder"
            case .protectedSystemPath: "a protected system location"
            case .isRootItself: "a scan location itself"
            case .insideGitFolder: "inside a .git folder"
            case .protectedUserData: "protected personal data (Keychains, Mail, Messages, iCloud, Photos…)"
            }
        }
    }

    static let protectedPrefixes = ["/System", "/Library", "/bin", "/sbin", "/usr", "/etc", "/private/etc", "/cores", "/dev", "/opt/homebrew/Cellar"]

    /// Personal data that is never touched, whatever the roots say (paths relative to home).
    /// Matching is per path component, so `Library/Mail` doesn't also protect `Library/Mailspring`.
    static let protectedHomePaths = [
        "Library/Keychains", "Library/Mail", "Library/Messages", "Library/Mobile Documents",
        "Library/CloudStorage", "Library/Calendars", "Library/Safari", "Library/Accounts",
        "Library/Photos", "Library/Containers/com.apple.mail", "Library/Group Containers/group.com.apple.notes",
        "Library/Application Support/AddressBook", "Library/Application Support/MobileSync",
    ]
    /// Folders that may contain removable things but must never be removed themselves.
    static let protectedHomeFolders = [
        "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public", "Applications",
        "Library/Caches", "Library/Application Support", "Library/Preferences", "Library/Containers",
    ]
    /// Path components that mark protected data anywhere (Photos libraries, keychain files).
    static let protectedSuffixes = [".photoslibrary", ".keychain", ".keychain-db"]

    let allowedRoots: [URL]
    let exclusions: GlobMatcher
    let home: String

    init(allowedRoots: [URL], exclusions: GlobMatcher, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.allowedRoots = allowedRoots.map { $0.standardizedFileURL }
        self.exclusions = exclusions
        self.home = PathFormat.canonical(home.path)
    }

    private func isProtectedUserData(_ path: String) -> Bool {
        if path == home || PathGuard.protectedHomeFolders.contains(where: { path == home + "/" + $0 }) || path == "/Applications" {
            return true
        }
        for rel in PathGuard.protectedHomePaths {
            let p = home + "/" + rel
            if path == p || path.hasPrefix(p + "/") { return true }
        }
        return path.split(separator: "/").contains { comp in PathGuard.protectedSuffixes.contains { comp.hasSuffix($0) } }
    }

    func check(_ url: URL) -> Violation? {
        let literal = PathFormat.canonical(url.path)
        let resolved = PathFormat.canonical(url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).path)

        for path in Set([literal, resolved]) {
            if path == "/" || Self.protectedPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                return .protectedSystemPath
            }
            if path.split(separator: "/").contains(".git") { return .insideGitFolder }
            if isProtectedUserData(path) { return .protectedUserData }
        }
        if exclusions.matches(path: literal) || exclusions.matches(path: resolved) { return .excluded }

        let roots = allowedRoots.flatMap { [PathFormat.canonical($0.path), PathFormat.canonical($0.resolvingSymlinksInPath().path)] }
        if roots.contains(literal) || roots.contains(resolved) { return .isRootItself }
        // Both the literal and the symlink-resolved path must sit inside an allowed root.
        func inside(_ path: String) -> Bool {
            roots.contains { root in path.hasPrefix(root.hasSuffix("/") ? root : root + "/") }
        }
        return inside(literal) && inside(resolved) ? nil : .outsideAllowedRoots
    }

    func isAllowed(_ url: URL) -> Bool { check(url) == nil }
}
