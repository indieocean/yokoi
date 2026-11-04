import Foundation
import Testing

@Suite("Unattended cleaning")
struct UnattendedCleanTests {
    func cache(_ id: String = "pip", safety: SafetyLevel = .safe, permanentOnly: Bool = false) -> CacheItem {
        let url = URL(fileURLWithPath: "/h/\(id)")
        return CacheItem(locationID: id, name: id, section: .trash, url: url, contents: [url], safety: safety, badge: "",
                         colorHex: 0, size: 100, fileCount: 1, restoreHint: "", permanentOnly: permanentOnly)
    }

    func settings(_ f: Fixture) -> SettingsData {
        var s = SettingsData(scanRoots: [ScanRoot(path: "~/dev")])
        s.bigFileRoots = ["~"]
        s.screenshotFolderOverride = "~/Desktop"
        return s
    }

    /// A project untouched for a long time, and one edited just now.
    func projects() throws -> Fixture {
        let f = try Fixture()
        for name in ["old", "new"] {
            try f.file("dev/\(name)/package.json", contents: #"{"name":"\#(name)"}"#)
            try f.file("dev/\(name)/package-lock.json")
            try f.file("dev/\(name)/node_modules/a/index.js", bytes: 5_000)
        }
        try f.setModified("dev/old/package.json", Fixture.longAgo)
        try f.setModified("dev/old/package-lock.json", Fixture.longAgo)
        return f
    }

    func plan(_ f: Fixture, _ s: SettingsData? = nil, inUse: InUseSnapshot = .empty) async -> HeadlessClean.Plan {
        await HeadlessClean.plan(settings: s ?? settings(f), categories: [.nodeModules], home: f.home, inUse: inUse)
    }

    func log(_ f: Fixture) -> CleanupLog { CleanupLog(url: f.url("support/cleanup.log")) }

    // MARK: Selection

    @Test func neverIncludesTheTrashEvenIfItWereSafe() {
        let trash = cache("trash", safety: .safe, permanentOnly: true)
        for scope in AutoCleanScope.allCases {
            let picked = CleanSelection.unattended(scope, nodeModules: [], artifacts: [], caches: [trash, cache()],
                                                   settings: SettingsData(scanRoots: []))
            #expect(picked.map(\.id) == ["pip"], "\(scope)")
        }
    }

    @Test func leavesOutReviewAndRedownloadCaches() {
        let picked = CleanSelection.unattended(.smartSelect, nodeModules: [], artifacts: [],
                                               caches: [cache("a", safety: .review), cache("b", safety: .redownload)],
                                               settings: SettingsData(scanRoots: []))
        #expect(picked.isEmpty)
    }

    @Test func safeCachesScopeLeavesProjectsAlone() {
        let stale = NodeModulesItem(url: URL(fileURLWithPath: "/h/dev/x/node_modules"), projectURL: URL(fileURLWithPath: "/h/dev/x"),
                                    projectName: "x", frameworkHint: "", packageManager: .npm, size: 1, fileCount: 1, lastTouched: Fixture.longAgo)
        let s = SettingsData(scanRoots: [])
        #expect(CleanSelection.unattended(.safeCaches, nodeModules: [stale], artifacts: [], caches: [cache()], settings: s).map(\.id) == ["pip"])
        #expect(CleanSelection.unattended(.smartSelect, nodeModules: [stale], artifacts: [], caches: [cache()], settings: s).count == 2)
    }

    // MARK: Holding back what's in use

    @Test func aRunningProcessHoldsBackItsProject() async throws {
        let f = try projects()
        let busy = InUseSnapshot(uses: [.init(path: PathFormat.canonical(f.url("dev/old").path), process: "node")])
        let p = await plan(f, inUse: busy)
        #expect(p.entries.isEmpty)
        #expect(p.blocked.map(\.process) == ["node"])
    }

    @Test func aRunningAppHoldsBackItsCache() {
        var entry = CleanupEntry(cache())
        entry.usedByApps = ["Docker"]
        let split = InUseSnapshot(uses: [.init(path: "/Applications/Docker.app/Contents/MacOS/x", process: "x")]).split([entry])
        #expect(split.allowed.isEmpty)
        #expect(split.blocked.first?.process == "Docker")
    }

    // MARK: yokoi clean

    @Test func picksOnlyStaleProjects() async throws {
        let f = try projects()
        #expect(await plan(f).entries.map(\.displayPath).allSatisfy { $0.contains("old") })
        #expect(await plan(f).entries.count == 1)
    }

    @Test func permanentDeleteRemovesWhatWasPlannedAndNothingElse() async throws {
        let f = try projects()
        let p = await plan(f)
        let outcome = await HeadlessClean.execute(p, action: .delete, settings: settings(f), home: f.home, log: log(f))
        #expect(outcome.failures.isEmpty)
        #expect(!f.exists("dev/old/node_modules"))
        #expect(f.exists("dev/old/package.json"))
        #expect(f.exists("dev/new/node_modules"))
        #expect(await log(f).readAll().first?.action == "delete")
    }

    @Test func theDryRunSettingHolds() async throws {
        let f = try projects()
        var s = settings(f)
        s.dryRun = true
        let p = await plan(f, s)
        let outcome = await HeadlessClean.execute(p, action: .delete, settings: s, home: f.home, log: log(f))
        #expect(outcome.dryRun)
        #expect(f.exists("dev/old/node_modules"))
        #expect(CleanReport(plan: p, action: .delete, outcome: outcome).text().contains("Nothing was changed"))
    }

    @Test func pathGuardStillApplies() async throws {
        let f = try projects()
        let p = await plan(f)
        var s = settings(f)
        s.scanRoots = [ScanRoot(path: "~/elsewhere")]  // the plan's paths are no longer allowed
        let outcome = await HeadlessClean.execute(p, action: .delete, settings: s, home: f.home, log: log(f))
        #expect(f.exists("dev/old/node_modules"))
        #expect(outcome.failures.first?.reason.contains("outside the scan locations") == true)
    }

    @Test func aPreviewSaysNothingWasTouched() async throws {
        let f = try projects()
        let report = CleanReport(plan: await plan(f), action: .delete, outcome: nil)
        #expect(!report.applied)
        #expect(report.items.count == 1)
        #expect(report.text().contains("Would permanently delete"))
        #expect(report.text().contains("--yes"))
        #expect(f.exists("dev/old/node_modules"))
    }

    @Test func aReportOnlyListsWhatWasCleaned() async throws {
        let f = try projects()
        let p = await plan(f)
        try FileManager.default.removeItem(at: f.url("dev/old/node_modules"))
        let outcome = await HeadlessClean.execute(p, action: .delete, settings: settings(f), home: f.home, log: log(f))
        let report = CleanReport(plan: p, action: .delete, outcome: outcome)
        #expect(report.items.isEmpty)
        #expect(report.failed.count == 1)
        #expect(report.bytes == 0)
    }

    // MARK: Arguments

    @Test func cleanDefaultsToAPreviewInTheTrash() throws {
        #expect(CommandLineTool.isRequested(["/Applications/Yokoi.app/Contents/MacOS/Yokoi", "clean"]))
        guard case .clean(let o) = try CommandLineTool.parse(["yokoi", "clean"]) else { Issue.record("not clean"); return }
        #expect(!o.yes && !o.permanent && !o.dryRun)
        #expect(o.categories == HeadlessClean.categories)
        #expect(!o.willClean)
        #expect(o.action == .trash)
    }

    @Test func parsesCleanFlags() throws {
        let args = ["yokoi", "clean", "--permanent", "--yes", "--json", "--category", "caches"]
        guard case .clean(let o) = try CommandLineTool.parse(args) else { Issue.record("not clean"); return }
        #expect(o.willClean && o.json)
        #expect(o.action == .delete)
        #expect(o.categories == [.caches])
    }

    @Test func dryRunBeatsYes() throws {
        guard case .clean(let o) = try CommandLineTool.parse(["yokoi", "clean", "--yes", "--dry-run"]) else { Issue.record("not clean"); return }
        #expect(!o.willClean)
    }

    @Test func refusesCategoriesOfYourOwnFiles() {
        for name in ["big-files", "downloads", "screenshots", "applications"] {
            #expect(throws: CommandLineTool.UsageError.self) { try CommandLineTool.parse(["yokoi", "clean", "--category", name]) }
        }
    }

    @Test func flagsStayWithTheirCommand() {
        #expect(throws: CommandLineTool.UsageError.self) { try CommandLineTool.parse(["yokoi", "scan", "--yes"]) }
        #expect(throws: CommandLineTool.UsageError.self) { try CommandLineTool.parse(["yokoi", "scan", "--permanent"]) }
        #expect(throws: CommandLineTool.UsageError.self) { try CommandLineTool.parse(["yokoi", "clean", "--top", "3"]) }
    }
}
