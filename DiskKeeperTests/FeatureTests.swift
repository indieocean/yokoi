import Foundation
import Testing

@Suite("Applications, extra caches and undo")
struct FeatureTests {
    func makeApp(_ f: Fixture, _ path: String, id: String, name: String? = nil, appStore: Bool = false) throws {
        var plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": "1.2.3"]
        if let name { plist["CFBundleDisplayName"] = name }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try f.file("\(path)/Contents/Info.plist", contents: String(decoding: data, as: UTF8.self))
        try f.file("\(path)/Contents/MacOS/bin", bytes: 40_000)
        if appStore { try f.file("\(path)/Contents/_MASReceipt/receipt") }
    }

    func appContext(_ f: Fixture) -> ScanContext {
        var ctx = f.context()
        ctx.applicationFolders = [f.url("Applications")]
        return ctx
    }

    @Test func findsAppsAndLeftovers() async throws {
        let f = try Fixture()
        try makeApp(f, "Applications/Figma.app", id: "com.figma.Desktop")
        try makeApp(f, "Applications/Utilities/Tool.app", id: "dev.tool.app", appStore: true)
        try makeApp(f, "Applications/Safari.app", id: "com.apple.Safari")
        try f.file("Library/Application Support/Figma/cache.db", bytes: 5_000)
        try f.file("Library/Caches/com.figma.Desktop/x", bytes: 5_000)
        try f.file("Library/Preferences/com.figma.Desktop.plist")
        try f.file("Library/Preferences/ByHost/com.figma.Desktop.ABC123.plist")
        try f.file("Library/Group Containers/TEAM123.com.figma.Desktop/x")
        try f.file("Library/Saved Application State/com.figma.Desktop.savedState/data")
        try f.file("Library/Application Support/FigmaAgent/x")  // lookalike: must not match
        try f.file("Library/Keychains/com.figma.Desktop/x")    // protected: must never be listed

        let items = await ApplicationScanner().collect(appContext(f))
        #expect(Set(items.map(\.name)) == ["Figma", "Tool", "Safari"])

        let figma = try #require(items.first { $0.bundleID == "com.figma.Desktop" })
        let leftovers = Set(figma.leftovers.map { $0.url.path.replacingOccurrences(of: f.home.path + "/", with: "") })
        #expect(leftovers == [
            "Library/Application Support/Figma", "Library/Caches/com.figma.Desktop", "Library/Preferences/com.figma.Desktop.plist",
            "Library/Preferences/ByHost/com.figma.Desktop.ABC123.plist", "Library/Group Containers/TEAM123.com.figma.Desktop",
            "Library/Saved Application State/com.figma.Desktop.savedState",
        ])
        #expect(figma.protectedReason == nil)
        #expect(figma.urls.first == figma.url)

        #expect(items.first { $0.name == "Safari" }?.protectedReason == "Apple app")
        #expect(items.first { $0.name == "Tool" }?.isAppStore == true)
    }

    @Test func uninstallMovesAppAndLeftoversButNotOtherApps() async throws {
        let f = try Fixture()
        try makeApp(f, "Applications/Figma.app", id: "com.figma.Desktop")
        try makeApp(f, "Applications/Other.app", id: "com.other")
        try f.file("Library/Caches/com.figma.Desktop/x")
        let ctx = appContext(f)
        let figma = try #require(await ApplicationScanner().collect(ctx).first { $0.name == "Figma" })
        let svc = CleanupService(context: ctx, log: CleanupLog(url: f.url("log")))
        let outcome = await svc.perform([CleanupEntry(figma)], action: .delete, dryRun: false)
        #expect(outcome.failures.isEmpty)
        #expect(!f.exists("Applications/Figma.app"))
        #expect(!f.exists("Library/Caches/com.figma.Desktop"))
        #expect(f.exists("Applications/Other.app"))
        #expect(f.exists("Library/Caches"))
    }

    @Test func trashCanOnlyBeDeletedPermanently() async throws {
        let f = try Fixture()
        try f.file(".Trash/old.zip", bytes: 3_000)
        let ctx = f.context()
        let trash = try #require(await CacheScanner().collect(ctx).first { $0.id == "trash" })
        #expect(trash.permanentOnly)
        let svc = CleanupService(context: ctx, log: CleanupLog(url: f.url("log")))
        let refused = await svc.perform([CleanupEntry(trash)], action: .trash, dryRun: false)
        #expect(refused.failures.count == 1)
        #expect(f.exists(".Trash/old.zip"))
        let ok = await svc.perform([CleanupEntry(trash)], action: .delete, dryRun: false)
        #expect(ok.failures.isEmpty)
        #expect(!f.exists(".Trash/old.zip"))
        #expect(f.exists(".Trash"))
    }

    @Test func installersOnlyMatchInstallerFiles() async throws {
        let f = try Fixture()
        try f.file("Downloads/Xcode.xip", bytes: 3_000)
        try f.file("Downloads/Docker.dmg", bytes: 3_000)
        try f.file("Downloads/taxes.pdf", bytes: 3_000)
        try f.file("Downloads/project/setup.pkg", bytes: 3_000)
        let installers = try #require(await CacheScanner().collect(f.context()).first { $0.id == "installers" })
        #expect(Set(installers.contents.map(\.lastPathComponent)) == ["Xcode.xip", "Docker.dmg"])
        #expect(installers.safety == .review)
    }

    @Test func putBackRestoresATrashBatch() async throws {
        let f = try Fixture.standard()
        let ctx = f.context()
        let log = CleanupLog(url: f.url("support/cleanup.log"))
        let svc = CleanupService(context: ctx, log: log)
        let entry = CleanupEntry(id: "x", category: .nodeModules, label: "web", displayPath: "~/dev/web/node_modules",
                                 urls: [f.url("dev/web/node_modules")], size: 10)
        let out = await svc.perform([entry], action: .trash, dryRun: false)
        #expect(!f.exists("dev/web/node_modules"))
        #expect(await log.readAll().freedBytes == 10)

        let batch = try #require(await log.readAll().batches.first)
        #expect(batch.canPutBack)
        let restored = await svc.restore(batch: batch.records)
        #expect(restored.failures.isEmpty)
        #expect(f.exists("dev/web/node_modules/a/index.js"))

        let after = await log.readAll()
        #expect(after.batches.first?.restored == true)
        #expect(after.batches.first?.canPutBack == false)
        #expect(after.freedBytes == 0, "restored batches don't count as freed")
        _ = out
    }

    @Test func putBackNeverOverwrites() async throws {
        let f = try Fixture.standard()
        let log = CleanupLog(url: f.url("support/cleanup.log"))
        let svc = CleanupService(context: f.context(), log: log)
        let entry = CleanupEntry(id: "x", category: .nodeModules, label: "web", displayPath: "~/dev/web/node_modules",
                                 urls: [f.url("dev/web/node_modules")], size: 10)
        _ = await svc.perform([entry], action: .trash, dryRun: false)
        try f.file("dev/web/node_modules/new.js")  // reinstalled in the meantime
        let batch = try #require(await log.readAll().batches.first)
        let restored = await svc.restore(batch: batch.records)
        #expect(restored.failures.count == 1)
        #expect(f.exists("dev/web/node_modules/new.js"))
        if let trashed = batch.records.first?.items.first?.destination { try? FileManager.default.removeItem(atPath: trashed) }
    }
}

@Suite("Package manager and tool parsers")
struct ParserTests {
    @Test func npm() {
        let ls = #"{"dependencies":{"typescript":{"version":"5.4.5"},"eslint":{"version":"8.57.0"}}}"#
        let pkgs = PackageParsers.installed(.npm, ls)
        #expect(pkgs.map(\.name) == ["eslint", "typescript"])
        let outdated = #"{"typescript":{"current":"5.4.5","wanted":"5.6.3","latest":"5.6.3"}}"#
        #expect(PackageParsers.outdated(.npm, outdated) == ["typescript": "5.6.3"])
    }

    @Test func pnpm() {
        let ls = #"[{"path":"/x","dependencies":{"vercel":{"version":"32.7.2"}}}]"#
        #expect(PackageParsers.installed(.pnpm, ls).map(\.installedVersion) == ["32.7.2"])
    }

    @Test func homebrew() {
        let info = #"{"formulae":[{"name":"wget","installed":[{"version":"1.24.5"}]}],"casks":[]}"#
        #expect(PackageParsers.installed(.homebrew, info).first?.installedVersion == "1.24.5")
        let out = #"{"formulae":[{"name":"wget","installed_versions":["1.24.5"],"current_version":"1.25.0"}],"casks":[{"name":"iterm2","installed_versions":["3.5"],"current_version":"3.6"}]}"#
        #expect(PackageParsers.outdated(.homebrew, out) == ["wget": "1.25.0", "iterm2": "3.6"])
        #expect(PackageParsers.installed(.casks, "iterm2 3.5.4\nvisual-studio-code 1.95.0\n").map(\.name) == ["iterm2", "visual-studio-code"])
    }

    @Test func cargo() {
        let list = "ripgrep v14.1.0:\n    rg\nbat v0.24.0:\n    bat\n"
        let pkgs = PackageParsers.installed(.cargo, list)
        #expect(pkgs.map(\.name) == ["ripgrep", "bat"])
        #expect(pkgs.first?.installedVersion == "14.1.0")
        #expect(pkgs.first?.binaries == ["rg"])
        let table = "Package  Installed  Latest   Needs update\nripgrep  v14.0.0    v14.1.0  Yes\nbat      v0.24.0    v0.24.0  No\n"
        #expect(PackageParsers.outdated(.cargo, table) == ["ripgrep": "14.1.0"])
    }

    @Test func pipAndGem() {
        #expect(PackageParsers.installed(.pip, #"[{"name":"requests","version":"2.31.0"}]"#).first?.name == "requests")
        #expect(PackageParsers.outdated(.pip, #"[{"name":"requests","version":"2.31.0","latest_version":"2.32.3"}]"#) == ["requests": "2.32.3"])
        let gems = PackageParsers.installed(.gem, "rake (13.2.1, 13.0.6)\nbigdecimal (default: 3.1.8)\n")
        #expect(gems.map(\.installedVersion) == ["13.2.1", "3.1.8"])
        #expect(PackageParsers.outdated(.gem, "rake (13.0.6 < 13.2.1)\n") == ["rake": "13.2.1"])
    }

    @Test func commandsNeverUseAShell() {
        for kind in PackageManagerKind.allCases {
            let cmd = kind.uninstallCommand("evil; rm -rf ~")
            #expect(cmd.last == "evil; rm -rf ~", "the package name stays one literal argument")
            #expect(!ProcessRunner.forbidden.contains(cmd[0]))
        }
    }

    @Test func simulatorsAndSnapshots() {
        let json = #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-16-4":[{"udid":"AAA","name":"iPhone 14","isAvailable":false}],"com.apple.CoreSimulator.SimRuntime.iOS-18-0":[{"udid":"BBB","name":"iPhone 16","isAvailable":true}]}}"#
        let sims = ToolActionService.parseUnavailableSimulators(json)
        #expect(sims == [.init(udid: "AAA", name: "iPhone 14", runtime: "iOS-16-4")])
        let tm = "Snapshots for disk /:\ncom.apple.TimeMachine.2026-10-30-101010.local\ncom.apple.TimeMachine.2026-10-31-090000.local\n"
        #expect(ToolActionService.parseSnapshotDates(tm) == ["2026-10-30-101010", "2026-10-31-090000"])
    }
}
