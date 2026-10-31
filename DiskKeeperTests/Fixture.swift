import Foundation

/// A throwaway fake home directory that mimics real projects. Deleted on deinit.
final class Fixture {
    let home: URL
    private let fm = FileManager.default

    init() throws {
        let tmp = URL(fileURLWithPath: realpath(fm.temporaryDirectory.path, nil).map { String(cString: $0) } ?? fm.temporaryDirectory.path)
        let base = tmp.appendingPathComponent("DiskKeeperTests-\(UUID().uuidString)")
        home = base.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    deinit {
        try? fm.removeItem(at: home.deletingLastPathComponent())
    }

    func url(_ path: String) -> URL { home.appendingPathComponent(path) }

    @discardableResult
    func file(_ path: String, bytes: Int = 16, modified: Date? = nil, contents: String? = nil) throws -> URL {
        let url = url(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = contents.map { Data($0.utf8) } ?? Data(repeating: 0x41, count: bytes)
        try data.write(to: url)
        if let modified { try setModified(path, modified) }
        return url
    }

    @discardableResult
    func dir(_ path: String) throws -> URL {
        let url = url(path)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func setModified(_ path: String, _ date: Date) throws {
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: url(path).path)
    }

    func exists(_ path: String) -> Bool { fm.fileExists(atPath: url(path).path) }

    func context(roots: [String] = ["~/dev", "~/games"], exclusions: [String] = [], bigFileRoots: [String] = ["~"], bigFileFloor: Int64 = 1_000_000) -> ScanContext {
        var settings = SettingsData(scanRoots: roots.map { ScanRoot(path: $0) })
        settings.exclusions = exclusions
        settings.bigFileRoots = bigFileRoots
        settings.screenshotFolderOverride = "~/Desktop"
        var ctx = settings.makeContext(home: home)
        ctx.bigFileFloor = bigFileFloor
        ctx.applicationFolders = [home.appendingPathComponent("Applications")]
        return ctx
    }

    static let longAgo = Date(timeIntervalSinceNow: -400 * 86_400)

    /// The standard fixture: a mix of real-looking projects, decoys and caches.
    static func standard() throws -> Fixture {
        let f = try Fixture()
        // Rust: matched.
        try f.file("dev/rusty/Cargo.toml", contents: "[package]\nname = \"rusty\"")
        try f.file("dev/rusty/src/main.rs", modified: longAgo)
        try f.file("dev/rusty/target/debug/rusty", bytes: 50_000)
        // target/ without Cargo.toml: a decoy, must not match.
        try f.file("dev/notrust/target/keep.txt", bytes: 9_000)
        // Rust workspace member: credited to the workspace root.
        try f.file("dev/rusty/crates/core/Cargo.toml")
        try f.file("dev/rusty/crates/core/target/x", bytes: 8_000)

        // Web app with nested node_modules and a Next.js cache.
        try f.file("dev/web/package.json", contents: #"{"name":"web-app","dependencies":{"next":"^14.1.0","react":"18"}}"#)
        try f.file("dev/web/package-lock.json")
        try f.file("dev/web/src/app.ts")
        try f.file("dev/web/node_modules/a/index.js", bytes: 20_000)
        try f.file("dev/web/node_modules/a/node_modules/b/index.js", bytes: 20_000)
        try f.file("dev/web/.next/cache/x", bytes: 10_000)

        // Old monorepo package, pnpm lockfile at the repo root.
        try f.file("dev/mono/package.json", contents: #"{"name":"mono","workspaces":["packages/*"]}"#)
        try f.file("dev/mono/pnpm-lock.yaml")
        try f.file("dev/mono/packages/ui/package.json", modified: longAgo, contents: #"{"name":"ui","devDependencies":{"vite":"5"}}"#)
        try f.file("dev/mono/packages/ui/node_modules/vite/index.js", bytes: 12_000)
        try f.setModified("dev/mono/package.json", longAgo)
        try f.setModified("dev/mono/pnpm-lock.yaml", longAgo)

        // Unity project with a .csproj (the .NET rule must stay quiet).
        try f.file("games/MyUnity/ProjectSettings/ProjectVersion.txt", contents: "m_EditorVersion: 2022.3")
        try f.file("games/MyUnity/Assets/Player.cs")
        try f.file("games/MyUnity/MyUnity.csproj")
        try f.file("games/MyUnity/Library/ArtifactDB", bytes: 30_000)
        try f.file("games/MyUnity/Temp/x", bytes: 1_000)
        try f.file("games/MyUnity/obj/Debug/x", bytes: 1_000)
        try f.file("games/MyUnity/MyUnity_BackUpThisFolder_ButDontShipItWithYourGame/sym", bytes: 1_000)

        // Unreal project.
        try f.file("games/Orbital/Orbital.uproject", contents: "{}")
        try f.file("games/Orbital/Intermediate/Build/x", bytes: 10_000)
        try f.file("games/Orbital/DerivedDataCache/ddc", bytes: 10_000)
        try f.file("games/Orbital/Saved/Logs/Orbital.log", bytes: 2_000)
        try f.file("games/Orbital/Saved/Config/Game.ini", bytes: 100)
        try f.file("games/Orbital/Binaries/Mac/Orbital", bytes: 5_000)

        // Python project.
        try f.file("dev/py/pyproject.toml")
        try f.file("dev/py/.venv/lib/site.py", bytes: 3_000)
        try f.file("dev/py/pkg/__init__.py")
        try f.file("dev/py/pkg/__pycache__/x.pyc", bytes: 2_000)

        // Gradle multi-module.
        try f.file("dev/android/settings.gradle")
        try f.file("dev/android/build/out", bytes: 2_000)
        try f.file("dev/android/app/build.gradle")
        try f.file("dev/android/app/build/apk", bytes: 4_000)

        // Swift PM + .NET.
        try f.file("dev/swiftpkg/Package.swift")
        try f.file("dev/swiftpkg/.build/debug/x", bytes: 3_000)
        try f.file("dev/dotnetapp/App.csproj")
        try f.file("dev/dotnetapp/bin/Debug/App.dll", bytes: 3_000)
        try f.file("dev/dotnetapp/obj/project.assets.json", bytes: 1_000)

        // Excluded project.
        try f.file("dev/secret/Cargo.toml")
        try f.file("dev/secret/target/x", bytes: 3_000)

        // Caches.
        try f.file("Library/Caches/Homebrew/downloads/bottle.tar.gz", bytes: 7_000)
        try f.file("Library/Caches/com.example.app/cache.db", bytes: 3_000)
        try f.file("Library/Caches/com.apple.Safari/cache.db", bytes: 3_000)
        try f.file(".npm/_cacache/index-v5/x", bytes: 4_000)
        try f.file("Library/Developer/Xcode/DerivedData/Proj-abc/Build/x", bytes: 6_000)

        // Screenshots.
        try f.file("Desktop/Screenshot 2026-10-01 at 10.00.00.png", bytes: 2_000)
        try f.file("Desktop/Screen Recording 2026-10-02 at 11.00.00.mov", bytes: 2_000)
        try f.file("Desktop/notes.txt")

        // Big files.
        try f.file("Downloads/ubuntu.iso", bytes: 2_000_000)
        try f.file("Movies/small.mov", bytes: 10_000)
        try f.file("Library/Big/hidden.bin", bytes: 2_000_000)
        try f.file("dev/web/node_modules/huge.bin", bytes: 2_000_000)
        return f
    }
}
