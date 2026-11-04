import Foundation

/// The single place that decides whether Yokoi may touch a path (PRD §6).
///
/// A path is allowed only when it is strictly inside an allowed root (scan roots plus known global
/// locations), is not excluded, isn't part of a `.git` folder, and isn't under a protected system folder.
/// Checks run on both the literal path and the path with parent symlinks resolved, so a symlink
/// can't be used to escape a root.
///
/// The deny checks (system folders, personal data, `.git`, exclusions) ignore case, because the default
/// APFS volume does: `~/library/keychains` is the same folder as `~/Library/Keychains`. The allow check
/// (inside a root) stays exact, so a case mismatch there refuses rather than permits.
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

    /// System locations never touched, whatever the roots say. Includes the writable parts of the
    /// system (`/var`, Homebrew's and MacPorts' install trees) that SIP doesn't cover, so a wide scan
    /// root such as `/opt` can't reach the global npm tree or Homebrew's state.
    static let protectedPrefixes = [
        "/System", "/Library", "/bin", "/sbin", "/usr", "/etc", "/private/etc", "/cores", "/dev",
        "/var", "/private/var", "/nix", "/opt/local",
        "/opt/homebrew/Cellar", "/opt/homebrew/Caskroom", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/opt/homebrew/lib",
        "/opt/homebrew/opt", "/opt/homebrew/etc", "/opt/homebrew/share", "/opt/homebrew/include", "/opt/homebrew/var",
        "/opt/homebrew/Frameworks", "/opt/homebrew/Library",
    ]
    /// Inside a protected prefix but owned by the user: the per-user temporary folders.
    static let userWritableSystemPaths = ["/var/folders", "/var/tmp", "/private/var/folders", "/private/var/tmp"]

    /// `path` (already folded) is a protected system location.
    static func isProtectedSystemPath(_ path: String) -> Bool {
        guard path != "/" else { return true }
        guard protectedPrefixes.contains(where: { isAtOrInside(path, fold($0)) }) else { return false }
        return !userWritableSystemPaths.contains(where: { isAtOrInside(path, fold($0)) })
    }

    /// Personal data that is never touched, whatever the roots say (paths relative to home).
    /// Matching is per path component, so `Library/Mail` doesn't also protect `Library/Mailspring`.
    static let protectedHomePaths = [
        "Library/Keychains", "Library/Mail", "Library/Messages", "Library/Mobile Documents",
        "Library/CloudStorage", "Library/Calendars", "Library/Safari", "Library/Accounts",
        "Library/Photos", "Library/Containers/com.apple.mail", "Library/Group Containers/group.com.apple.notes",
        "Library/Application Support/AddressBook", "Library/Application Support/MobileSync",
        ".ssh", ".gnupg", ".aws",
    ]
    /// Apple's own app data under `~/Library`, as globs relative to home. Apple apps can't be
    /// uninstalled from Yokoi, so nothing should ever reach their containers, preferences or storage.
    /// (`Library/Caches/com.apple.*` is not here: Xcode's and the Simulator's caches are cleanable.)
    static let protectedHomeGlobs = [
        "Library/Containers/com.apple.*", "Library/Group Containers/*com.apple.*",
        "Library/Application Support/com.apple.*", "Library/Preferences/com.apple.*",
        "Library/Preferences/ByHost/com.apple.*", "Library/HTTPStorages/com.apple.*",
        "Library/Saved Application State/com.apple.*", "Library/WebKit/com.apple.*", "Library/Cookies/com.apple.*",
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

    /// Case- and normalization-insensitive form of a path, for the deny checks.
    static func fold(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// `path` is `prefix` or inside it. Both must already be folded.
    private static func isAtOrInside(_ path: String, _ prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + "/")
    }

    /// - Parameter path: an already-folded path.
    private func isProtectedUserData(_ path: String) -> Bool {
        let home = Self.fold(self.home)
        if path == home || path == "/applications"
            || PathGuard.protectedHomeFolders.contains(where: { path == home + "/" + Self.fold($0) }) {
            return true
        }
        if PathGuard.protectedHomePaths.contains(where: { Self.isAtOrInside(path, home + "/" + Self.fold($0)) }) { return true }
        // A glob matches the item itself or, with "/*" appended, anything below it (`*` spans `/` without FNM_PATHNAME).
        if PathGuard.protectedHomeGlobs.contains(where: { glob in
            let full = home + "/" + Self.fold(glob)
            return fnmatch(full, path, FNM_CASEFOLD) == 0 || fnmatch(full + "/*", path, FNM_CASEFOLD) == 0
        }) { return true }
        return path.split(separator: "/").contains { comp in PathGuard.protectedSuffixes.contains { comp.hasSuffix($0) } }
    }

    func check(_ url: URL) -> Violation? {
        let literal = PathFormat.canonical(url.path)
        let resolved = PathFormat.canonical(url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).path)

        for path in Set([literal, resolved].map(Self.fold)) {
            if Self.isProtectedSystemPath(path) { return .protectedSystemPath }
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
