import Foundation
import Testing

@Suite("Scanners")
struct ScannerTests {
    // MARK: node_modules

    @Test func findsNodeModulesWithoutDescendingIntoNested() async throws {
        let f = try Fixture.standard()
        let items = await NodeModulesScanner().collect(f.context())
        let paths = Set(items.map { PathFormat.abbreviate($0.url, home: f.home) })
        #expect(paths == ["~/dev/web/node_modules", "~/dev/mono/packages/ui/node_modules"])
    }

    @Test func nodeModulesMetadata() async throws {
        let f = try Fixture.standard()
        let items = await NodeModulesScanner().collect(f.context())
        let web = try #require(items.first { $0.projectURL.lastPathComponent == "web" })
        #expect(web.projectName == "web-app")
        #expect(web.frameworkHint == "next 14")
        #expect(web.packageManager == .npm)
        #expect(web.size >= 40_000)
        #expect(web.fileCount == 3)
        #expect(!web.isStale(days: 90))

        let ui = try #require(items.first { $0.projectName == "ui" })
        #expect(ui.frameworkHint == "vite")
        #expect(ui.packageManager == .pnpm, "lockfile found in the monorepo root")
        #expect(ui.isStale(days: 90), "only old files outside node_modules")
    }

    @Test func gitLogFallback() throws {
        let f = try Fixture()
        try f.file("p/.git/logs/HEAD", contents: "0000 1111 A <a@b.c> 1600000000 +0000\tcommit: one\n0000 2222 A <a@b.c> 1700000000 +0100\tcommit: two\n")
        #expect(FileWalker.gitLastCommitDate(f.url("p")) == Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: Build artifacts

    @Test func artifactsOnlyMatchNextToMarkers() async throws {
        let f = try Fixture.standard()
        let items = await BuildArtifactScanner().collect(f.context(exclusions: ["~/dev/secret"]))
        let all = items.flatMap(\.targets).map { PathFormat.abbreviate($0, home: f.home) }

        #expect(all.contains("~/dev/rusty/target"))
        #expect(all.contains("~/dev/rusty/crates/core/target"))
        #expect(!all.contains { $0.contains("notrust") }, "target/ without Cargo.toml is not an artifact")
        #expect(!all.contains { $0.contains("secret") }, "excluded folders are never scanned")
        #expect(!all.contains { $0.contains("node_modules") })

        let rust = items.filter { $0.ruleID == "rust" }
        #expect(rust.count == 1, "workspace members are credited to the outermost project")
        #expect(rust.first?.projectName == "rusty")
    }

    @Test func unityAndUnrealRules() async throws {
        let f = try Fixture.standard()
        let items = await BuildArtifactScanner().collect(f.context())

        let unity = try #require(items.first { $0.ruleID == "unity" && !$0.optIn })
        #expect(Set(unity.targets.map(\.lastPathComponent)) == ["Library", "Temp", "Obj"] || Set(unity.targets.map(\.lastPathComponent)) == ["Library", "Temp", "obj"])
        #expect(!items.contains { $0.ruleID == "dotnet" && $0.projectName == "MyUnity" }, ".NET rule is suppressed inside Unity projects")
        let backup = try #require(items.first { $0.ruleID == "unity" && $0.optIn })
        #expect(backup.targets.map(\.lastPathComponent) == ["MyUnity_BackUpThisFolder_ButDontShipItWithYourGame"])

        let unreal = items.filter { $0.ruleID == "unreal" }
        let normal = try #require(unreal.first { !$0.optIn })
        let names = Set(normal.targets.map { $0.path.replacingOccurrences(of: normal.projectURL.path + "/", with: "") })
        #expect(names == ["Intermediate", "DerivedDataCache", "Saved/Logs"], "Saved/Config is kept")
        let optIn = try #require(unreal.first { $0.optIn })
        let optNames = Set(optIn.targets.map { $0.path.replacingOccurrences(of: optIn.projectURL.path + "/", with: "") })
        #expect(optNames == ["Binaries", "Saved/Config"])
        #expect(normal.displayPath.hasSuffix("Orbital/{DerivedDataCache,Intermediate,Saved}"))
    }

    @Test func pythonGradleSwiftDotnet() async throws {
        let f = try Fixture.standard()
        let items = await BuildArtifactScanner().collect(f.context())
        func rel(_ rule: String) -> Set<String> {
            Set(items.filter { $0.ruleID == rule }.flatMap(\.targets).map { PathFormat.abbreviate($0, home: f.home) })
        }
        #expect(rel("python") == ["~/dev/py/.venv", "~/dev/py/pkg/__pycache__"])
        #expect(rel("gradle") == ["~/dev/android/build", "~/dev/android/app/build"])
        #expect(items.filter { $0.ruleID == "gradle" }.count == 1)
        #expect(rel("swiftpm") == ["~/dev/swiftpkg/.build"])
        #expect(rel("dotnet") == ["~/dev/dotnetapp/bin", "~/dev/dotnetapp/obj"])
        #expect(rel("javascript") == ["~/dev/web/.next"])
    }

    @Test func globalArtifacts() async throws {
        let f = try Fixture.standard()
        let items = await BuildArtifactScanner().collect(f.context())
        let xcode = try #require(items.first { $0.ruleID == "xcode-deriveddata" })
        #expect(xcode.isGlobal)
        #expect(xcode.targets.map(\.lastPathComponent) == ["Proj-abc"], "contents are removed, not the DerivedData folder")
    }

    @Test func depthLimit() async throws {
        let f = try Fixture.standard()
        var ctx = f.context()
        ctx.roots = [ScanRoot(path: "~/dev", maxDepth: 1)]
        let items = await NodeModulesScanner().collect(ctx)
        #expect(items.map(\.projectURL.lastPathComponent) == ["web"], "mono/packages/ui is deeper than 1")
    }

    // MARK: Caches

    @Test func cachesAvoidDoubleCounting() async throws {
        let f = try Fixture.standard()
        let items = await CacheScanner().collect(f.context())
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

        let user = try #require(byID["user-caches"])
        let userChildren = Set(user.contents.map(\.lastPathComponent))
        #expect(userChildren == ["com.example.app"], "Homebrew is its own row, com.apple.* is kept, go-build belongs to artifacts")
        #expect(byID["homebrew"]?.contents.map(\.lastPathComponent) == ["downloads"])
        #expect(byID["npm"]?.safety == .safe)
        #expect(byID["cargo-registry"] == nil, "missing locations aren't reported")
    }

    @Test func cacheBreakdownNamesXcodeAndAndroidItems() async throws {
        let f = try Fixture()
        let old = Date(timeIntervalSinceNow: -300 * 86_400), recent = Date(timeIntervalSinceNow: -2 * 86_400)
        func plist(_ path: String, _ dict: [String: Any]) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try f.file(path, contents: String(decoding: data, as: UTF8.self))
        }
        // Two simulators, one old.
        let sims = "Library/Developer/CoreSimulator/Devices"
        try plist("\(sims)/AAA/device.plist", ["name": "iPhone 14", "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-16-4"])
        try f.file("\(sims)/AAA/data/blob", bytes: 4_000, modified: old)
        for path in ["\(sims)/AAA/device.plist", "\(sims)/AAA/data", "\(sims)/AAA"] { try f.setModified(path, old) }
        try plist("\(sims)/BBB/device.plist", ["name": "iPhone 17", "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-26-0"])
        try f.file("\(sims)/BBB/data/blob", bytes: 2_000, modified: recent)
        try f.file("\(sims)/device_set.plist")
        // Archives inside date folders.
        let arch = "Library/Developer/Xcode/Archives"
        try plist("\(arch)/2025-01-02/Orbital 1-2-25.xcarchive/Info.plist",
                  ["Name": "Orbital", "CreationDate": old, "ApplicationProperties": ["CFBundleShortVersionString": "1.0", "CFBundleVersion": "7"]])
        try plist("\(arch)/2026-10-01/Orbital 10-1-26.xcarchive/Info.plist",
                  ["Name": "Orbital", "CreationDate": recent, "ApplicationProperties": ["CFBundleShortVersionString": "2.0", "CFBundleVersion": "40"]])
        // An emulator is a folder plus an .ini; system images are three levels deep.
        try f.file(".android/avd/Pixel_7.avd/config.ini")
        try f.file(".android/avd/Pixel_7.ini")
        try f.file("Library/Android/sdk/system-images/android-34/google_apis_playstore/arm64-v8a/system.img")
        try f.file("Library/Developer/Xcode/iOS DeviceSupport/iPhone15,2 17.0 (21A329)/Symbols/x")

        let items = await CacheScanner().collect(f.context())
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

        let simItem = try #require(byID["simulator-devices"])
        let simRows = try #require(simItem.children)
        #expect(simRows.map(\.name) == ["iPhone 17", "iPhone 14"], "newest first")
        #expect(simRows.map(\.detail) == ["iOS 26.0", "iOS 16.4"])
        #expect(simItem.size == simRows.reduce(0) { $0 + $1.size }, "the location's size is the sum of its rows")
        #expect(Set(simItem.contents) == Set(simRows.flatMap(\.urls)))

        let archives = try #require(byID["xcode-archives"]?.children)
        #expect(archives.map(\.detail) == ["2.0 (40)", "1.0 (7)"])
        #expect(archives.allSatisfy { $0.urls[0].pathExtension == "xcarchive" }, "the archives, not their date folders")

        let avd = try #require(byID["android-avd"]?.children)
        #expect(avd.count == 1)
        #expect(avd.first?.name == "Pixel 7")
        #expect(avd.first?.urls.map(\.lastPathComponent) == ["Pixel_7.avd", "Pixel_7.ini"])

        let image = try #require(byID["android-system-images"]?.children?.first)
        #expect(image.name == "Android API 34")
        #expect(image.detail == "Google Play · arm64-v8a")
        #expect(byID["device-support"]?.children?.first?.name == "17.0 (21A329)")
    }

    @Test func cleaningOneCacheItemKeepsTheRest() async throws {
        let f = try Fixture()
        try f.file("Library/Developer/Xcode/iOS DeviceSupport/16.0 (20A362)/Symbols/x", bytes: 3_000)
        try f.file("Library/Developer/Xcode/iOS DeviceSupport/17.0 (21A329)/Symbols/x", bytes: 1_000)
        let item = try #require(await CacheScanner().collect(f.context()).first { $0.id == "device-support" })
        let oldest = try #require(item.children?.first { $0.name.hasPrefix("16") })

        let entry = item.entry(for: oldest)
        let service = CleanupService(context: f.context(), log: CleanupLog(url: f.url("support/cleanup.log")))
        let outcome = await service.perform([entry], action: .delete, dryRun: false)
        #expect(outcome.failures.isEmpty)
        #expect(outcome.completedIDs == [entry.id])
        #expect(!f.exists("Library/Developer/Xcode/iOS DeviceSupport/16.0 (20A362)"))
        #expect(f.exists("Library/Developer/Xcode/iOS DeviceSupport/17.0 (21A329)"))

        let left = try #require(item.removingChildren(entryIDs: outcome.completedIDs))
        #expect(left.children?.map(\.name) == ["17.0 (21A329)"])
        #expect(left.size == item.size - oldest.size)
        #expect(item.removingChildren(entryIDs: [item.id]) == nil, "a whole-location id isn't a child")
    }

    @Test func storesWithoutMeaningfulPartsAreNotBrokenDown() async throws {
        let f = try Fixture()
        try f.file(".npm/_cacache/content-v2/a")
        try f.file(".npm/_cacache/index-v5/b")
        let npm = try #require(await CacheScanner().collect(f.context()).first { $0.id == "npm" })
        #expect(npm.children == nil)
        #expect(npm.contents.count == 2)
    }

    // MARK: Big files

    @Test func bigFiles() async throws {
        let f = try Fixture.standard()
        let items = await BigFileScanner().collect(f.context())
        let names = Set(items.map(\.name))
        #expect(names == ["ubuntu.iso"], "~/Library, node_modules and small files are skipped")
        #expect(items.first?.kind == .diskImage)
    }

    @Test func bigFileKinds() {
        #expect(BigFileScanner.kind(for: URL(fileURLWithPath: "/a/b.mov")) == .video)
        #expect(BigFileScanner.kind(for: URL(fileURLWithPath: "/a/b.tar.gz")) == .archive)
        #expect(BigFileScanner.kind(for: URL(fileURLWithPath: "/a/win11.utm")) == .vm)
        #expect(BigFileScanner.kind(for: URL(fileURLWithPath: "/a/key.psd")) == .art)
        #expect(BigFileScanner.kind(for: URL(fileURLWithPath: "/a/x.dmg")) == .diskImage)
    }

    // MARK: Screenshots

    @Test func screenshots() async throws {
        let f = try Fixture.standard()
        let items = await ScreenshotScanner().collect(f.context())
        #expect(items.count == 2)
        #expect(items.filter(\.isRecording).count == 1)
        #expect(!items.contains { $0.title == "notes.txt" })
    }

    // MARK: Downloads

    @Test func downloadsListsTopLevelItems() async throws {
        let f = try Fixture()
        try f.file("Downloads/tool.dmg", contents: String(repeating: "x", count: 5000))
        try f.file("Downloads/assets.zip", contents: "zip")
        try f.file("Downloads/assets/a.png", contents: "a")
        try f.file("Downloads/assets/b.png", contents: "b")
        try f.file("Downloads/notes.pdf", contents: "pdf")
        try f.file("Downloads/big.tar.gz", contents: "tgz")
        try f.file("Downloads/data.csv.crdownload", contents: "part")
        try f.file("Downloads/.DS_Store", contents: "ds")
        let items = await DownloadsScanner().collect(f.context())
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })

        #expect(Set(byName.keys) == ["tool.dmg", "assets.zip", "assets", "notes.pdf", "big.tar.gz", "data.csv.crdownload"],
                "direct children only, hidden files skipped")
        #expect(byName["assets"]?.kind == .folder)
        #expect(byName["assets"]?.fileCount == 2, "a folder is one item with its total size")
        #expect(byName["assets.zip"]?.isExtracted == true)
        #expect(byName["assets.zip"]?.safety == .safe)
        #expect(byName["big.tar.gz"]?.isExtracted == false, "no big/ folder next to it")
        #expect(byName["tool.dmg"]?.kind == .installer)
        #expect(byName["tool.dmg"]?.safety == .redownload)
        #expect(byName["data.csv.crdownload"]?.kind == .incomplete)
        #expect(byName["notes.pdf"]?.safety == .review, "your own files are never preselected as safe")
        #expect(items.allSatisfy { !$0.isOld(days: 30) }, "just added")
    }

    @Test func downloadsExtractedNames() {
        #expect(DownloadsScanner.extractedName("foo.zip") == "foo")
        #expect(DownloadsScanner.extractedName("foo.tar.gz") == "foo")
        #expect(DownloadsScanner.extractedName("foo.pdf") == nil)
        #expect(DownloadsScanner.extractedName(".zip") == nil)
    }

    @Test func downloadsAge() {
        let now = Date()
        let old = DownloadItem(url: URL(fileURLWithPath: "/d/a"), kind: .other, size: 1, fileCount: 1,
                               added: now.addingTimeInterval(-40 * 86_400), lastOpened: nil, isExtracted: false)
        let reopened = DownloadItem(url: URL(fileURLWithPath: "/d/b"), kind: .other, size: 1, fileCount: 1,
                                    added: now.addingTimeInterval(-40 * 86_400), lastOpened: now.addingTimeInterval(-2 * 86_400), isExtracted: false)
        let unknown = DownloadItem(url: URL(fileURLWithPath: "/d/c"), kind: .other, size: 1, fileCount: 1,
                                   added: nil, lastOpened: nil, isExtracted: false)
        #expect(old.isOld(days: 30, now: now))
        #expect(!reopened.isOld(days: 30, now: now), "opening a download makes it recent again")
        #expect(!unknown.isOld(days: 30, now: now))
    }

    @Test func bigFilesInsideOldDownloadsAreCountedOnce() {
        let old = Date().addingTimeInterval(-90 * 86_400)
        let downloads = [
            DownloadItem(url: URL(fileURLWithPath: "/h/Downloads/x.iso"), kind: .installer, size: 500, fileCount: 1, added: old, lastOpened: nil, isExtracted: false),
            DownloadItem(url: URL(fileURLWithPath: "/h/Downloads/pack"), kind: .folder, size: 900, fileCount: 2, added: old, lastOpened: nil, isExtracted: false),
            DownloadItem(url: URL(fileURLWithPath: "/h/Downloads/new.mov"), kind: .video, size: 700, fileCount: 1, added: Date(), lastOpened: nil, isExtracted: false),
        ]
        let big = [
            BigFileItem(url: URL(fileURLWithPath: "/h/Downloads/x.iso"), kind: .diskImage, size: 500, modified: nil, isBundle: false),
            BigFileItem(url: URL(fileURLWithPath: "/h/Downloads/pack/inner.zip"), kind: .archive, size: 300, modified: nil, isBundle: false),
            BigFileItem(url: URL(fileURLWithPath: "/h/Downloads/new.mov"), kind: .video, size: 700, modified: nil, isBundle: false),
            BigFileItem(url: URL(fileURLWithPath: "/h/Downloads/package.dmg"), kind: .diskImage, size: 400, modified: nil, isBundle: false),
            BigFileItem(url: URL(fileURLWithPath: "/h/Movies/m.mov"), kind: .video, size: 800, modified: nil, isBundle: false),
        ]
        // x.iso and the file inside pack/ overlap; new.mov isn't old; package.dmg isn't inside "pack".
        #expect(Overlap.bigFileBytesInDownloads(big, threshold: 100, downloads: downloads, ageDays: 30) == 800)
    }

    // MARK: Engine

    @Test func engineStreamsAllCategories() async throws {
        let f = try Fixture.standard()
        let progress = ScanProgress()
        var finished = Set<CleanCategory>()
        var count = 0
        for await event in await ScanEngine().run(f.context(), progress: progress) {
            if case .finished(let c) = event { finished.insert(c) } else { count += 1 }
        }
        #expect(finished == [.nodeModules, .buildArtifacts, .caches, .bigFiles, .downloads, .screenshots, .applications])
        #expect(count > 10)
        #expect(progress.snapshot.itemsFound == count)
    }

    @Test func cancellationStopsTheScan() async throws {
        let f = try Fixture.standard()
        let task = Task {
            var n = 0
            for await _ in await ScanEngine().run(f.context(), progress: ScanProgress()) { n += 1 }
            return n
        }
        task.cancel()
        _ = await task.value // must return rather than hang
    }
}

@Suite("Staleness")
struct StalenessTests {
    @Test func projectWithOnlyNodeModulesUsesTheFolderDate() async throws {
        let f = try Fixture()
        try f.file("dev/leftover/node_modules/x/index.js", modified: Fixture.longAgo)
        try f.setModified("dev/leftover/node_modules/x", Fixture.longAgo)
        try f.setModified("dev/leftover/node_modules", Fixture.longAgo)
        try f.setModified("dev/leftover", Fixture.longAgo)
        let item = try #require(await NodeModulesScanner().collect(f.context(roots: ["~/dev"])).first)
        #expect(item.lastTouched != nil)
        #expect(item.isStale(days: 90))
    }

    @Test func unknownAgeIsNeverStale() {
        let item = NodeModulesItem(url: URL(fileURLWithPath: "/x/node_modules"), projectURL: URL(fileURLWithPath: "/x"),
                                   projectName: "x", frameworkHint: "node", packageManager: nil, size: 1, fileCount: 1, lastTouched: nil)
        #expect(!item.isStale(days: 90))
    }
}

@Suite("Reclaimable sizes")
struct ReclaimableSizeTests {
    @Test func hardlinksFromOutsideFreeNothing() throws {
        let f = try Fixture()
        let store = try f.file("store/pkg/index.js", bytes: 200_000)
        try f.dir("dev/app/node_modules/pkg")
        let linked = f.url("dev/app/node_modules/pkg/index.js")
        #expect(link(store.path, linked.path) == 0)
        try f.file("dev/app/node_modules/own.js", bytes: 50_000)

        let nm = f.url("dev/app/node_modules")
        let plain = FileWalker.measure(nm)
        let real = FileWalker.measure(nm, reclaimable: true)
        #expect(plain.files == 2 && real.files == 2)
        #expect(plain.size >= 250_000)
        #expect(real.size >= 50_000 && real.size < 100_000, "the linked file stays in the store")
    }

    @Test func hardlinksInsideAreCountedOnce() throws {
        let f = try Fixture()
        let a = try f.file("target/debug/deps/app-1234", bytes: 300_000)
        #expect(link(a.path, f.url("target/debug/app").path) == 0)
        let plain = FileWalker.measure(f.url("target"))
        let real = FileWalker.measure(f.url("target"), reclaimable: true)
        #expect(plain.size >= 600_000)
        #expect(real.size >= 300_000 && real.size < 400_000)
    }

    @Test func clonesShareTheirBlocks() throws {
        let f = try Fixture()
        let original = try f.file("store/big.bin", bytes: 1_000_000)
        try f.dir("dev/app/node_modules")
        let clone = f.url("dev/app/node_modules/big.bin")
        guard copyfile(original.path, clone.path, nil, copyfile_flags_t(COPYFILE_CLONE_FORCE)) == 0 else { return } // not APFS
        let real = FileWalker.measure(f.url("dev/app/node_modules"), reclaimable: true)
        #expect(FileWalker.measure(f.url("dev/app/node_modules")).size >= 1_000_000)
        #expect(real.size < 100_000, "the clone's blocks are still used by the store")
    }
}
