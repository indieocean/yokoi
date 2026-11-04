import Foundation
import Testing

@Suite("Docker, Android, CLI and headless scan")
struct RoadmapTests {
    // MARK: Docker

    static let dockerDF = """
    {"Active":"2","Reclaimable":"1.21GB (54%)","Size":"2.234GB","TotalCount":"5","Type":"Images"}
    {"Active":"0","Reclaimable":"0B","Size":"0B","TotalCount":"0","Type":"Containers"}
    {"Active":"1","Reclaimable":"143.9MB (100%)","Size":"143.9MB","TotalCount":"2","Type":"Local Volumes"}
    {"Active":"0","Reclaimable":"512.3MB","Size":"512.3MB","TotalCount":"14","Type":"Build Cache"}
    """

    @Test func parsesDockerSystemDF() {
        let usage = ToolActionService.parseDockerDF(Self.dockerDF)
        #expect(usage["Images"] == .init(total: 5, active: 2, size: 2_234_000_000, reclaimable: 1_210_000_000))
        #expect(usage["Build Cache"]?.reclaimable == 512_300_000)
        #expect(usage["Local Volumes"]?.total == 2)
        #expect(usage["Containers"]?.reclaimable == 0)
    }

    @Test func parsesDockerSizes() {
        #expect(ToolActionService.parseDockerSize("0B") == 0)
        #expect(ToolActionService.parseDockerSize("12kB") == 12_000)
        #expect(ToolActionService.parseDockerSize("1.5GB (40%)") == 1_500_000_000)
        #expect(ToolActionService.parseDockerSize("2TB") == 2_000_000_000_000)
        #expect(ToolActionService.parseDockerSize("n/a") == nil)
        #expect(ToolActionService.parseDockerSize("") == nil)
    }

    @Test func dockerIsUnavailableWithoutTheCLI() async {
        let f = try! Fixture()
        let service = ToolActionService(runner: ProcessRunner(path: f.home.path), home: f.home)
        for action in ToolAction.allCases where action.isDocker {
            #expect(await service.status(action) == nil)
        }
    }

    // MARK: Android

    @Test func findsAndroidLocationsAndScopesCleanup() async throws {
        let f = try Fixture()
        try f.file(".android/avd/Pixel_8.avd/userdata-qemu.img", bytes: 5_000)
        try f.file(".android/avd/Pixel_8.ini")
        try f.file("Library/Android/sdk/system-images/android-35/google_apis/arm64-v8a/system.img", bytes: 8_000)
        try f.file("Library/Android/sdk/platform-tools/adb", bytes: 100)
        try f.file(".android/build-cache/x", bytes: 300)
        try f.file(".gradle/wrapper/dists/gradle-8.9-bin/x.zip", bytes: 900)

        let ctx = f.context()
        let items = await CacheScanner().collect(ctx)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        #expect(byID["android-avd"]?.section == .android)
        #expect(byID["android-avd"]?.safety == .review)
        #expect(byID["android-avd"]?.contents.count == 2)
        #expect(byID["android-system-images"]?.size ?? 0 >= 8_000)
        #expect(byID["android-build-cache"]?.safety == .safe)
        #expect(byID["gradle-wrapper"]?.safety == .redownload)

        // Only the listed folders are reachable: the rest of the SDK (platform-tools) is not.
        let guardian = ctx.pathGuard(for: .caches)
        #expect(guardian.isAllowed(f.url(".android/avd/Pixel_8.avd")))
        #expect(!guardian.isAllowed(f.url("Library/Android/sdk/platform-tools/adb")))
        #expect(!guardian.isAllowed(f.url(".android/avd")), "the folder itself is never removed")
    }

    @Test func emulatorFoldersAreGuardedAgainstRunningProcesses() throws {
        let f = try Fixture()
        try f.file(".android/avd/Pixel_8.ini")
        let avd = CacheItem(locationID: "android-avd", name: "AVDs", section: .android, url: f.url(".android/avd"),
                            contents: [f.url(".android/avd/Pixel_8.ini")], safety: .review, badge: "avd", colorHex: 0,
                            size: 1, fileCount: 1, restoreHint: "")
        #expect(CleanupEntry(avd).projectRoot == f.url(".android/avd"))
        let npm = CacheItem(locationID: "npm", name: "npm", section: .javascript, url: f.url(".npm/_cacache"),
                            contents: [], safety: .safe, badge: "npm", colorHex: 0, size: 0, fileCount: 0, restoreHint: "")
        #expect(CleanupEntry(npm).projectRoot == nil)
        let snapshot = InUseSnapshot(uses: [.init(path: PathFormat.canonical(f.url(".android/avd/Pixel_8.avd/userdata-qemu.img").path), process: "qemu-system-aarch64")])
        #expect(snapshot.blocker(for: f.url(".android/avd")) == "qemu-system-aarch64")
    }

    // MARK: CLI

    @Test func detectsCLIInvocation() {
        #expect(CommandLineTool.isRequested(["/usr/local/bin/yokoi"]))
        #expect(CommandLineTool.isRequested(["/Applications/Yokoi.app/Contents/MacOS/Yokoi", "scan"]))
        #expect(!CommandLineTool.isRequested(["/Applications/Yokoi.app/Contents/MacOS/Yokoi"]))
        #expect(!CommandLineTool.isRequested(["/Applications/Yokoi.app/Contents/MacOS/Yokoi", "-NSDocumentRevisionsDebugMode", "YES"]))
        #expect(!CommandLineTool.isRequested(["/Applications/Yokoi.app/Contents/MacOS/Yokoi", "-YokoiDemo", "YES"]))
    }

    @Test func parsesCLIArguments() throws {
        #expect(try CommandLineTool.parse(["yokoi"]) == .help)
        #expect(try CommandLineTool.parse(["yokoi", "--version"]) == .version)
        #expect(try CommandLineTool.parse(["yokoi", "scan"]) == .scan(.init()))
        let parsed = try CommandLineTool.parse(["yokoi", "scan", "--json", "--category", "caches,node-modules,bigFiles", "--top", "3"])
        #expect(parsed == .scan(.init(json: true, categories: [.caches, .nodeModules, .bigFiles], top: 3)))
        #expect(throws: CommandLineTool.UsageError.self) { try CommandLineTool.parse(["yokoi", "scan", "--category", "packages"]) }
        #expect(throws: CommandLineTool.UsageError.self) { try CommandLineTool.parse(["yokoi", "scan", "--top"]) }
        #expect(throws: CommandLineTool.UsageError.self) { try CommandLineTool.parse(["yokoi", "frobnicate"]) }
    }

    @Test func categoryCLINamesRoundTrip() {
        for c in CleanCategory.allCases { #expect(CleanCategory(cliName: c.cliName) == c) }
        #expect(CleanCategory.buildArtifacts.cliName == "build-artifacts")
        #expect(CleanCategory(cliName: "BIG_FILES") == .bigFiles)
    }

    // MARK: Headless scan

    @Test func headlessScanReportsWithoutTouchingAnything() async throws {
        let f = try Fixture.standard()
        var settings = SettingsData(scanRoots: [ScanRoot(path: "~/dev"), ScanRoot(path: "~/games")])
        settings.bigFileRoots = ["~"]
        settings.screenshotFolderOverride = "~/Desktop"
        let before = try FileManager.default.subpathsOfDirectory(atPath: f.home.path).sorted()

        let report = await ScanReport.run(settings: settings, categories: [.nodeModules, .buildArtifacts, .caches], home: f.home)
        #expect(report.categories.map(\.id) == ["nodeModules", "buildArtifacts", "caches"])
        #expect(report.reclaimableBytes == report.categories.reduce(0) { $0 + $1.reclaimableBytes })
        #expect(report.categories.allSatisfy { c in zip(c.items, c.items.dropFirst()).allSatisfy { $0.sizeBytes >= $1.sizeBytes } })
        #expect(report.categories.first { $0.id == "nodeModules" }!.count > 0)

        let trimmed = report.trimmed(to: 1)
        #expect(trimmed.categories.allSatisfy { $0.items.count <= 1 })
        #expect(trimmed.reclaimableBytes == report.reclaimableBytes)
        #expect(trimmed.json().contains("\"reclaimableBytes\""))

        let after = try FileManager.default.subpathsOfDirectory(atPath: f.home.path).sorted()
        #expect(before == after, "a headless scan is read-only")
    }
}
