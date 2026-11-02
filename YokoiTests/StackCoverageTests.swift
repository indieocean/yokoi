import Foundation
import Testing

@Suite("Locations for every stack")
struct StackCoverageTests {
    @Test func locationsAreUniqueAndCleanable() throws {
        let f = try Fixture()
        #expect(Set(CacheLocation.all.map(\.id)).count == CacheLocation.all.count, "ids are unique")
        #expect(Set(CacheLocation.all.map(\.relativePath)).count == CacheLocation.all.count, "paths are unique")
        let guardrail = f.context().pathGuard(for: .caches)
        for location in CacheLocation.all {
            // Something inside each location may be cleaned; the location folder itself never is.
            let inside = location.url(home: f.home).appendingPathComponent("x")
            #expect(guardrail.check(inside) == nil, "\(location.id) is cleanable")
            #expect(guardrail.check(location.url(home: f.home)) != nil, "\(location.id) itself is kept")
        }
    }

    @Test func dedicatedRowsAreNotCountedTwice() async throws {
        let f = try Fixture()
        try f.file("Library/Caches/JetBrains/IntelliJIdea2025.2/index/x", bytes: 4_000)
        try f.file("Library/Caches/ms-playwright/chromium-1140/x", bytes: 3_000)
        try f.file("Library/Caches/SomeApp/x", bytes: 2_000)
        try f.file("Library/Logs/JetBrains/idea.log", bytes: 1_000)
        try f.file("Library/Logs/SomeApp.log", bytes: 1_000)
        let items = Dictionary(uniqueKeysWithValues: await CacheScanner().collect(f.context()).map { ($0.id, $0) })

        let userCaches = try #require(items["user-caches"]).contents.map(\.lastPathComponent)
        #expect(userCaches == ["SomeApp"])
        #expect(try #require(items["logs"]).contents.map(\.lastPathComponent) == ["SomeApp.log"])
        #expect(items["jetbrains-caches"] != nil && items["jetbrains-logs"] != nil && items["playwright"] != nil)
    }

    @Test func poetryAndPubKeepWhatIsntCache() async throws {
        let f = try Fixture()
        try f.file("Library/Caches/pypoetry/cache/repositories/pypi/x", bytes: 2_000)
        try f.file("Library/Caches/pypoetry/virtualenvs/app-py3.12/bin/python", bytes: 2_000)
        try f.file(".pub-cache/hosted/pub.dev/http-1.2.0/x", bytes: 2_000)
        try f.file(".pub-cache/bin/melos", bytes: 100)
        try f.file(".pub-cache/global_packages/melos/x", bytes: 100)
        let items = Dictionary(uniqueKeysWithValues: await CacheScanner().collect(f.context()).map { ($0.id, $0) })
        #expect(try #require(items["poetry"]).contents.map(\.lastPathComponent) == ["cache"])
        #expect(try #require(items["pub-cache"]).contents.map(\.lastPathComponent) == ["hosted"])
    }

    @Test func agentWorkspacesOfferOnlyDerivedData() async throws {
        let f = try Fixture()
        try f.file("Library/Developer/XcodeBuildMCP/workspaces/Orbital-1a2b/DerivedData/Build/x", bytes: 5_000)
        try f.dir("Library/Developer/XcodeBuildMCP/workspaces/Orbital-1a2b/filesystem-lifecycle.lock")
        try f.file("Library/Developer/XcodeBuildMCP/workspaces/Empty-3c4d/state.json")
        let item = try #require(await CacheScanner().collect(f.context()).first { $0.id == "xcodebuildmcp-workspaces" })
        #expect(item.contents.map { $0.path.replacingOccurrences(of: f.home.path + "/", with: "") }
                == ["Library/Developer/XcodeBuildMCP/workspaces/Orbital-1a2b/DerivedData"])
        #expect(item.children?.first?.name == "Orbital-1a2b")
        #expect(CacheLocation.inUseGuarded.contains("xcodebuildmcp-workspaces"))
    }

    @Test func editorCachesWaitForTheEditorToQuit() {
        let snapshot = InUseSnapshot(uses: [
            .init(path: "/Applications/Visual Studio Code.app/Contents/MacOS/Code", process: "Code"),
            .init(path: "/Applications/IntelliJ IDEA CE.app/Contents/MacOS/idea", process: "idea"),
        ])
        #expect(snapshot.runningApp(["Visual Studio Code"]) == "Visual Studio Code")
        #expect(snapshot.runningApp(CacheLocation.jetBrainsProcesses) == "idea")
        #expect(snapshot.runningApp(["Cursor"]) == nil)
        #expect(snapshot.runningApp([]) == nil)

        let item = CacheItem(locationID: "vscode-cache", name: "VS Code cache", section: .editors, url: URL(fileURLWithPath: "/tmp/x"),
                             contents: [], safety: .safe, badge: "vs", colorHex: 0, size: 0, fileCount: 0, restoreHint: "")
        #expect(CleanupEntry(item).usedByApps == ["Visual Studio Code"])
    }

    @Test func countsGoModules() throws {
        let f = try Fixture()
        try f.file("go/pkg/mod/github.com/pkg/errors@v0.9.1/errors.go")
        try f.file("go/pkg/mod/golang.org/x/sys@v0.20.0/unix/x.go")
        try f.file("go/pkg/mod/cache/download/github.com/pkg/errors/@v/v0.9.1.zip")
        #expect(ToolActionService.countGoModules(in: f.url("go/pkg/mod")) == 2)
    }

    @Test func angularAndCocoaPods() async throws {
        let f = try Fixture()
        try f.file("dev/ng/package.json", contents: #"{"name":"ng"}"#)
        try f.file("dev/ng/.angular/cache/x", bytes: 3_000)
        try f.file("dev/ios/Podfile")
        try f.file("dev/ios/Pods/Alamofire/x.swift", bytes: 3_000)
        let items = await BuildArtifactScanner().collect(f.context())
        #expect(items.contains { $0.ruleID == "javascript" && $0.targets.contains { $0.lastPathComponent == ".angular" } })
        let pods = try #require(items.first { $0.ruleID == "cocoapods" })
        #expect(pods.optIn, "Pods/ is sometimes committed")
    }
}

@Suite("Big files leave the Music library alone")
struct MusicLibraryTests {
    @Test func musicLibraryIsNotWalked() async throws {
        let f = try Fixture()
        try f.file("Music/Music/Media.localized/Music/album/track.wav", bytes: 2_000_000)
        try f.file("Music/iTunes/iTunes Media/song.aiff", bytes: 2_000_000)
        try f.file("Music/Projects/mixdown.wav", bytes: 2_000_000)
        let items = await BigFileScanner().collect(f.context(bigFileRoots: ["~"]))
        #expect(items.map(\.url.lastPathComponent) == ["mixdown.wav"])

        // Not even when the Music folder itself is a big-file location.
        let deep = await BigFileScanner().collect(f.context(bigFileRoots: ["~/Music"]))
        #expect(deep.map(\.url.lastPathComponent) == ["mixdown.wav"])
    }
}
