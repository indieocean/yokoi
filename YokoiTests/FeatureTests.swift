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

    @Test func installersLiveInDownloadsNotCaches() async throws {
        let f = try Fixture()
        try f.file("Downloads/Xcode.xip", bytes: 3_000)
        try f.file("Downloads/Docker.dmg", bytes: 3_000)
        try f.file("Downloads/taxes.pdf", bytes: 3_000)
        try f.file("Downloads/project/setup.pkg", bytes: 3_000)
        let caches = await CacheScanner().collect(f.context())
        #expect(!caches.contains { $0.url.path.hasSuffix("/Downloads") }, "Downloads is its own category, so it isn't counted twice")

        let downloads = await DownloadsScanner().collect(f.context())
        let installers = downloads.filter { $0.kind == .installer }
        #expect(Set(installers.map(\.name)) == ["Xcode.xip", "Docker.dmg"], "top level only")
        #expect(installers.allSatisfy { $0.safety == .redownload })
        #expect(downloads.first { $0.name == "project" }?.kind == .folder)
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

    @Test func putBackRefusesLogEntriesThatDontComeFromATrash() async throws {
        let f = try Fixture.standard()
        try f.file("Documents/secret.txt")
        let log = CleanupLog(url: f.url("support/cleanup.log"))
        let svc = CleanupService(context: f.context(), log: log)
        // A hand-edited log: "put back" ~/Documents/secret.txt into a project folder.
        let forged = CleanupRecord(batchID: "forged", timestamp: Date(), action: "trash", dryRun: false, category: .nodeModules,
                                   label: "x", path: "~/dev/web/stolen", size: 1,
                                   items: [.init(original: f.url("dev/web/stolen").path, destination: f.url("Documents/secret.txt").path)],
                                   failed: 0)
        let out = await svc.restore(batch: [forged])
        #expect(out.failures.count == 1)
        #expect(out.failures.first?.reason.hasPrefix("Refused") == true)
        #expect(f.exists("Documents/secret.txt"))
        #expect(!f.exists("dev/web/stolen"))
    }

    @Test func putBackRefusesOriginalsOutsideTheCategorysRoots() async throws {
        let f = try Fixture.standard()
        let log = CleanupLog(url: f.url("support/cleanup.log"))
        let svc = CleanupService(context: f.context(), log: log)
        let entry = CleanupEntry(id: "x", category: .nodeModules, label: "web", displayPath: "~/dev/web/node_modules",
                                 urls: [f.url("dev/web/node_modules")], size: 10)
        _ = await svc.perform([entry], action: .trash, dryRun: false)
        let real = try #require(await log.readAll().batches.first?.records.first)
        let trashed = try #require(real.items.first?.destination)
        defer { try? FileManager.default.removeItem(atPath: trashed) }
        // Same Trash item, but the log now says it came from ~/Library/LaunchAgents.
        let forged = CleanupRecord(batchID: real.batchID, timestamp: real.timestamp, action: "trash", dryRun: false,
                                   category: .nodeModules, label: real.label, path: real.path, size: real.size,
                                   items: [.init(original: f.url("Library/LaunchAgents/evil").path, destination: trashed)], failed: 0)
        let out = await svc.restore(batch: [forged])
        #expect(out.failures.first?.reason.hasPrefix("Refused") == true)
        #expect(!f.exists("Library/LaunchAgents/evil"))
        #expect(FileManager.default.fileExists(atPath: trashed), "left in the Trash")
    }

    @Test func recognizesTrashLocations() {
        let home = URL(fileURLWithPath: "/Users/maya")
        func inTrash(_ p: String) -> Bool { CleanupService.isInTrash(URL(fileURLWithPath: p), home: home, uid: 501) }
        #expect(inTrash("/Users/maya/.Trash/node_modules"))
        #expect(inTrash("/Users/maya/.Trash/node_modules 2/a/b"))
        #expect(inTrash("/Volumes/USB/.Trashes/501/big.mov"))
        #expect(!inTrash("/Users/maya/.Trash"), "the Trash itself")
        #expect(!inTrash("/Users/maya/.Trash/../Documents/x"))
        #expect(!inTrash("/Users/maya/Documents/x"))
        #expect(!inTrash("/Users/other/.Trash/x"))
        #expect(!inTrash("/Volumes/USB/.Trashes/0/x"), "someone else's Trash")
        #expect(!inTrash("/Volumes/USB/.Trashes/501"))
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
    @Test(arguments: ["-rf", "--force", "--prefix=/", "", "a\nb", "a\0b"])
    func refusesTargetsThatLookLikeOptions(_ target: String) {
        for kind in PackageManagerKind.allCases {
            #expect(kind.updateCommand(target) == nil, "\(kind) update \(target)")
            #expect(kind.uninstallCommand(target) == nil, "\(kind) uninstall \(target)")
        }
    }

    @Test func normalTargetsStillWork() {
        #expect(PackageManagerKind.npm.uninstallCommand("@scope/left-pad") == ["npm", "uninstall", "-g", "@scope/left-pad"])
        #expect(PackageManagerKind.homebrew.updateCommand("ffmpeg") == ["brew", "upgrade", "ffmpeg"])
        #expect(PackageManagerKind.conda.uninstallCommand("/opt/miniconda3/envs/ml") == ["conda", "env", "remove", "-p", "/opt/miniconda3/envs/ml", "-y"])
    }

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
        let refused = """
        Error: Refusing to load cask nikitabobko/tap/aerospace from untrusted tap nikitabobko/tap.
        Run `brew trust --cask nikitabobko/tap/aerospace` or `brew trust nikitabobko/tap` to trust it.
        """
        #expect(PackageParsers.untrustedCasks(refused) == ["aerospace": "nikitabobko/tap"])
        #expect(PackageParsers.untrustedCasks("Error: something else").isEmpty)
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
        let evil = "evil; rm -rf ~"
        for kind in PackageManagerKind.allCases {
            for cmd in [kind.uninstallCommand(evil), kind.updateCommand(evil), kind.outdatedCommand, Optional(kind.listCommand)].compactMap({ $0 }) {
                #expect(!ProcessRunner.forbidden.contains(cmd[0]), "\(kind) uses \(cmd[0])")
                #expect(!cmd.contains("sudo"))
                #expect(!cmd.contains { $0 != evil && $0 != "\(evil)@latest" && $0.contains(";") })
            }
            if let cmd = kind.uninstallCommand(evil) { #expect(cmd.contains(evil), "the package name stays one literal argument") }
        }
        #expect(PackageManagerKind.macports.updateCommand("x") == nil, "MacPorts needs sudo, so no commands")
        #expect(PackageManagerKind.go.uninstallCommand("x") == nil)
    }

    @Test func yarnAndBun() {
        let yarn = "yarn global v1.22.22\ninfo \"typescript@5.4.5\" has binaries:\n   - tsc\ninfo \"@angular/cli@18.2.11\" has binaries:\n   - ng\n"
        let y = PackageParsers.installed(.yarn, yarn)
        #expect(y.map(\.name) == ["typescript", "@angular/cli"])
        #expect(y.last?.installedVersion == "18.2.11")
        let bun = "/Users/x/.bun/install/global node_modules (2)\n├── typescript@5.4.5\n└── @biomejs/biome@1.9.0\n"
        #expect(PackageParsers.installed(.bun, bun).map(\.name) == ["typescript", "@biomejs/biome"])
    }

    @Test func macportsAndMas() {
        let ports = "The following ports are currently installed:\n  wget @1.21.4_0 (active)\n  wget @1.21.3_0\n  git @2.46.0_0+diff_highlight (active)\n"
        #expect(PackageParsers.installed(.macports, ports).map(\.name) == ["wget", "git"])
        #expect(PackageParsers.outdated(.macports, "The following installed ports are outdated:\nwget    1.21.3_0 < 1.21.4_0\n") == ["wget": "1.21.4_0"])
        let mas = "497799835  Xcode            (16.1)\n1451685025 WireGuard        (1.0.16)\n"
        let m = PackageParsers.installed(.mas, mas)
        #expect(m.map(\.name) == ["Xcode", "WireGuard"])
        #expect(m.first?.commandTarget == "497799835")
        #expect(PackageParsers.outdated(.mas, "497799835 Xcode (16.0 -> 16.1)\n") == ["Xcode": "16.1"])
    }

    @Test func goAndDotnet() {
        let go = "/Users/x/go/bin/gopls: go1.23.1\n\tpath\tgolang.org/x/tools/gopls\n\tmod\tgolang.org/x/tools/gopls\tv0.16.2\th1:abc\n\tdep\tgithub.com/x\tv1.0.0\n/Users/x/go/bin/air: go1.22\n\tpath\tgithub.com/air-verse/air\n\tmod\tgithub.com/air-verse/air\tv1.52.3\th1:x\n"
        let g = PackageParsers.installed(.go, go)
        #expect(g.map(\.name) == ["gopls", "air"])
        #expect(g.first?.installedVersion == "0.16.2")
        #expect(g.first.map { PackageManagerKind.go.updateCommand($0.commandTarget) } == ["go", "install", "golang.org/x/tools/gopls@latest"])
        let dn = "Package Id      Version      Commands\n-------------------------------------\ndotnet-ef       8.0.0        dotnet-ef\n"
        #expect(PackageParsers.installed(.dotnet, dn).map(\.name) == ["dotnet-ef"])
    }

    @Test func pythonManagers() {
        let pipx = #"{"venvs":{"black":{"metadata":{"main_package":{"package_version":"24.8.0","apps":["black","blackd"]}}}}}"#
        let p = PackageParsers.installed(.pipx, pipx)
        #expect(p.first?.installedVersion == "24.8.0")
        #expect(p.first?.binaries == ["black", "blackd"])
        let uv = "ruff v0.6.9\n- ruff\nhttpie v3.2.4\n- http\n- https\n"
        let u = PackageParsers.installed(.uv, uv)
        #expect(u.map(\.name) == ["ruff", "httpie"])
        #expect(u.last?.binaries == ["http", "https"])
        #expect(PackageParsers.outdated(.uv, "ruff v0.6.9 [latest: 0.7.0]\n- ruff\n") == ["ruff": "0.7.0"])
        let conda = #"{"envs":["/Users/x/miniconda3","/Users/x/miniconda3/envs/ml"]}"#
        let c = PackageParsers.installed(.conda, conda)
        #expect(c.map(\.name) == ["base", "ml"])
        #expect(c.first?.locked != nil, "base can't be removed")
        #expect(c.last.map { PackageManagerKind.conda.uninstallCommand($0.commandTarget) } == ["conda", "env", "remove", "-p", "/Users/x/miniconda3/envs/ml", "-y"])
    }

    @Test func composer() {
        let show = #"{"installed":[{"name":"laravel/installer","version":"v5.8.3"}]}"#
        #expect(PackageParsers.installed(.composer, show).first?.installedVersion == "5.8.3")
        let out = #"{"installed":[{"name":"laravel/installer","version":"v5.8.3","latest":"v5.9.0"}]}"#
        #expect(PackageParsers.outdated(.composer, out) == ["laravel/installer": "5.9.0"])
    }

    @Test func simulatorsAndSnapshots() {
        let json = #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-16-4":[{"udid":"AAA","name":"iPhone 14","isAvailable":false}],"com.apple.CoreSimulator.SimRuntime.iOS-18-0":[{"udid":"BBB","name":"iPhone 16","isAvailable":true}]}}"#
        let sims = ToolActionService.parseUnavailableSimulators(json)
        #expect(sims == [.init(udid: "AAA", name: "iPhone 14", runtime: "iOS-16-4")])
        let tm = "Snapshots for disk /:\ncom.apple.TimeMachine.2026-10-30-101010.local\ncom.apple.TimeMachine.2026-10-31-090000.local\n"
        #expect(ToolActionService.parseSnapshotDates(tm) == ["2026-10-30-101010", "2026-10-31-090000"])
    }
}
