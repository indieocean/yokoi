import Foundation
import Testing

@Suite("Globs and path guard")
struct SafetyTests {
    let home = URL(fileURLWithPath: "/Users/maya")

    @Test func componentGlobs() {
        let g = GlobMatcher(patterns: ["*.keep", ".git"], home: home)
        #expect(g.matches(path: "/Users/maya/dev/x.keep"))
        #expect(g.matches(path: "/Users/maya/dev/x.keep/inner/file"))
        #expect(g.matches(path: "/Users/maya/dev/repo/.git/objects"))
        #expect(!g.matches(path: "/Users/maya/dev/keep"))
    }

    @Test func pathGlobs() {
        let g = GlobMatcher(patterns: ["~/dev/hunchwell", "**/.git", "~/work/acme/prod-*", "~/Dropbox"], home: home)
        #expect(g.matches(path: "/Users/maya/dev/hunchwell"))
        #expect(g.matches(path: "/Users/maya/dev/hunchwell/web/node_modules"))
        #expect(!g.matches(path: "/Users/maya/dev/hunchwell-2"))
        #expect(g.matches(path: "/Users/maya/dev/a/.git"))
        #expect(g.matches(path: "/Users/maya/work/acme/prod-api/target"))
        #expect(!g.matches(path: "/Users/maya/work/acme/staging/target"))
        #expect(g.matches(path: "/Users/maya/Dropbox/x"))
    }

    @Test func doubleStarInTheMiddle() {
        let g = GlobMatcher(patterns: ["~/games/**/Raw"], home: home)
        #expect(g.matches(path: "/Users/maya/games/Raw"))
        #expect(g.matches(path: "/Users/maya/games/Orbital/Content/Raw/x.fbx"))
        #expect(!g.matches(path: "/Users/maya/dev/Raw"))
    }

    @Test func guardAllowsOnlyInsideRoots() {
        let g = PathGuard(allowedRoots: [home.appendingPathComponent("dev")], exclusions: GlobMatcher(patterns: ["~/dev/keep"], home: home))
        #expect(g.check(URL(fileURLWithPath: "/Users/maya/dev/web/node_modules")) == nil)
        #expect(g.check(URL(fileURLWithPath: "/Users/maya/dev")) == .isRootItself)
        #expect(g.check(URL(fileURLWithPath: "/Users/maya/Documents/x")) == .outsideAllowedRoots)
        #expect(g.check(URL(fileURLWithPath: "/Users/maya/dev/../Documents/x")) == .outsideAllowedRoots)
        #expect(g.check(URL(fileURLWithPath: "/Users/maya/dev/keep/node_modules")) == .excluded)
        #expect(g.check(URL(fileURLWithPath: "/Users/maya/dev/repo/.git/objects")) == .insideGitFolder)
        #expect(g.check(URL(fileURLWithPath: "/System/Library/x")) == .protectedSystemPath)
        #expect(g.check(URL(fileURLWithPath: "/Library/Caches/x")) == .protectedSystemPath)
    }

    @Test func exclusionsIgnoreCase() {
        let g = GlobMatcher(patterns: ["~/Work/Client", "*.KEEP", "~/dev/Acme/prod-*"], home: home)
        #expect(g.matches(path: "/Users/maya/work/client/node_modules"))
        #expect(g.matches(path: "/Users/maya/WORK/CLIENT"))
        #expect(g.matches(path: "/Users/maya/dev/a.keep"))
        #expect(g.matches(path: "/Users/maya/dev/acme/PROD-api/target"))
        #expect(!g.matches(path: "/Users/maya/work/clients"))
        #expect(!g.matches(path: "/Users/maya/dev/acme/staging/target"))
    }

    @Test func guardDenyChecksIgnoreCase() {
        let g = PathGuard(allowedRoots: [home], exclusions: GlobMatcher(patterns: ["~/Dev/Keep"], home: home), home: home)
        #expect(g.check(URL(fileURLWithPath: "/Users/maya/library/keychains/login.keychain-db")) == .protectedUserData)
        #expect(g.check(URL(fileURLWithPath: "/Users/maya/LIBRARY/Mail/V10/x")) == .protectedUserData)
        #expect(g.check(URL(fileURLWithPath: "/Users/maya/pictures/x.PhotosLibrary/db")) == .protectedUserData)
        #expect(g.check(URL(fileURLWithPath: "/Users/maya/documents")) == .protectedUserData)
        #expect(g.check(URL(fileURLWithPath: "/system/library/x")) == .protectedSystemPath)
        #expect(g.check(URL(fileURLWithPath: "/Users/maya/dev/repo/.GIT/objects")) == .insideGitFolder)
        #expect(g.check(URL(fileURLWithPath: "/Users/maya/dev/keep/node_modules")) == .excluded)
        #expect(g.check(URL(fileURLWithPath: "/Users/maya/library/mailspring/cache")) == nil, "lookalikes still aren't protected")
    }

    @Test func allowCheckStaysExact() {
        // Folding the allow check would widen it on case-sensitive volumes: a case mismatch refuses instead.
        let g = PathGuard(allowedRoots: [home.appendingPathComponent("dev")], exclusions: GlobMatcher(patterns: []), home: home)
        #expect(g.check(URL(fileURLWithPath: "/Users/maya/dev/web/node_modules")) == nil)
        #expect(g.check(URL(fileURLWithPath: "/Users/maya/DEV/web/node_modules")) == .outsideAllowedRoots)
    }

    @Test func guardRejectsSymlinkEscape() throws {
        let f = try Fixture()
        try f.dir("dev")
        try f.file("outside/precious.txt")
        try FileManager.default.createSymbolicLink(at: f.url("dev/link"), withDestinationURL: f.url("outside"))
        let g = PathGuard(allowedRoots: [f.url("dev")], exclusions: GlobMatcher(patterns: []))
        #expect(g.check(f.url("dev/link/precious.txt")) == .outsideAllowedRoots)
        #expect(g.check(f.url("dev/link")) == nil, "removing the link itself is fine")
    }

    @Test func byteFormatting() {
        #expect(ByteFormat.string(846_000_000) == "846 MB")
        #expect(ByteFormat.string(1_420_000_000) == "1.42 GB")
        #expect(ByteFormat.string(18_400_000_000) == "18.4 GB")
        #expect(ByteFormat.string(153_300_000_000) == "153.3 GB")
        #expect(ByteFormat.string(1_420_000_000_000) == "1.42 TB")
        #expect(ByteFormat.compact(18_400_000_000) == "18.4G")
    }
}

@Suite("Protected personal data")
struct ProtectedDataTests {
    let home = URL(fileURLWithPath: "/Users/maya")

    var guardEverything: PathGuard {
        // Even with home itself as an allowed root, personal data stays off-limits.
        PathGuard(allowedRoots: [home, URL(fileURLWithPath: "/Applications")], exclusions: GlobMatcher(patterns: []), home: home)
    }

    @Test(arguments: [
        "Library/Keychains/login.keychain-db", "Library/Mail/V10/x", "Library/Messages/chat.db",
        "Library/Mobile Documents/com~apple~CloudDocs/a.txt", "Library/CloudStorage/Dropbox/x",
        "Pictures/Photos Library.photoslibrary/database", "Library/Safari/Bookmarks.plist",
    ])
    func blocksPersonalData(_ rel: String) {
        #expect(guardEverything.check(home.appendingPathComponent(rel)) == .protectedUserData)
    }

    @Test(arguments: ["Documents", "Desktop", "Downloads", "Library", "Library/Caches", "Library/Application Support"])
    func neverRemovesTopLevelFolders(_ rel: String) {
        #expect(guardEverything.check(home.appendingPathComponent(rel)) == .protectedUserData)
    }

    @Test func prefixLookalikesAreNotProtected() {
        #expect(guardEverything.check(home.appendingPathComponent("Library/Mailspring/cache")) == nil)
        #expect(guardEverything.check(home.appendingPathComponent("Library/Keychains2/x")) == nil)
        #expect(guardEverything.check(home.appendingPathComponent("Documents/Projects/web/node_modules")) == nil)
        #expect(guardEverything.check(URL(fileURLWithPath: "/Applications/Foo.app")) == nil)
        #expect(guardEverything.check(URL(fileURLWithPath: "/Applications")) == .protectedUserData)
    }

    /// A guard whose roots cover the whole disk: only the protected lists stand between it and a path.
    var guardWholeDisk: PathGuard {
        PathGuard(allowedRoots: [URL(fileURLWithPath: "/")], exclusions: GlobMatcher(patterns: []), home: home)
    }

    @Test(arguments: [
        "/var/db/dslocal/nodes/Default", "/private/var/log/system.log", "/var/root/x", "/opt/homebrew/lib/node_modules/npm",
        "/opt/homebrew/bin/node", "/opt/homebrew/opt/openssl", "/opt/homebrew/Cellar/git/2.0", "/opt/local/bin/port", "/nix/store/x",
    ])
    func blocksWritableSystemLocations(_ path: String) {
        #expect(guardWholeDisk.check(URL(fileURLWithPath: path)) == .protectedSystemPath)
    }

    @Test(arguments: ["/var/folders/zz/abc/T/scratch/node_modules", "/private/var/folders/zz/abc/T/x", "/var/tmp/build", "/opt/projects/x"])
    func userTemporaryFoldersStayReachable(_ path: String) {
        let violation = guardWholeDisk.check(URL(fileURLWithPath: path))
        #expect(violation != .protectedSystemPath, "\(path): \(String(describing: violation))")
    }

    @Test(arguments: [
        "Library/Containers/com.apple.Safari", "Library/Containers/com.apple.Safari/Data/Library/Cookies",
        "Library/Group Containers/group.com.apple.notes/x", "Library/Group Containers/UBF8T346G9.com.apple.mail",
        "Library/Preferences/com.apple.Safari.plist", "Library/Preferences/ByHost/com.apple.finder.ABC.plist",
        "Library/HTTPStorages/com.apple.Safari", "Library/Application Support/com.apple.sharedfilelist",
        "Library/Saved Application State/com.apple.mail.savedState", "Library/Cookies/com.apple.Safari.binarycookies",
    ])
    func blocksAppleAppData(_ rel: String) {
        #expect(guardEverything.check(home.appendingPathComponent(rel)) == .protectedUserData)
    }

    @Test(arguments: [
        "Library/Caches/com.apple.dt.Xcode/x", "Library/Containers/com.vendor.app", "Library/Preferences/com.vendor.app.plist",
        "Library/Application Support/Code/Cache", "Library/Developer/Xcode/DerivedData/App-abc",
    ])
    func thirdPartyAndToolchainDataStaysCleanable(_ rel: String) {
        #expect(guardEverything.check(home.appendingPathComponent(rel)) == nil)
    }

    @Test func scanLocationsCantBeTheDiskOrAboveHome() {
        #expect(ScanRootPolicy.refusal(for: URL(fileURLWithPath: "/"), home: home) != nil)
        #expect(ScanRootPolicy.refusal(for: URL(fileURLWithPath: "/Users"), home: home) != nil)
        #expect(ScanRootPolicy.refusal(for: URL(fileURLWithPath: "/var/db"), home: home) != nil)
        #expect(ScanRootPolicy.refusal(for: URL(fileURLWithPath: "/opt/homebrew/lib"), home: home) != nil)
        #expect(ScanRootPolicy.refusal(for: URL(fileURLWithPath: "/usr/local"), home: home) != nil)
        #expect(ScanRootPolicy.refusal(for: home, home: home) == nil, "the home folder itself is the default big-file location")
        #expect(ScanRootPolicy.refusal(for: home.appendingPathComponent("dev"), home: home) == nil)
        #expect(ScanRootPolicy.refusal(for: URL(fileURLWithPath: "/Users/Shared/projects"), home: home) == nil)
        #expect(ScanRootPolicy.refusal(for: URL(fileURLWithPath: "/opt/projects"), home: home) == nil)
        #expect(ScanRootPolicy.refusal(for: URL(fileURLWithPath: "/Volumes/Work/code"), home: home) == nil)
        #expect(ScanRootPolicy.refusal(for: URL(fileURLWithPath: "/private/var/folders/zz/T/x"), home: home) == nil)
    }
}
