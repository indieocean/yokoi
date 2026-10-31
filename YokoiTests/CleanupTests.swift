import Foundation
import Testing

@Suite("Cleanup service")
struct CleanupTests {
    func service(_ f: Fixture, ctx: ScanContext? = nil) -> (CleanupService, CleanupLog) {
        let log = CleanupLog(url: f.url("support/cleanup.log"))
        return (CleanupService(context: ctx ?? f.context(), log: log), log)
    }

    func entry(_ f: Fixture, _ path: String, category: CleanCategory = .nodeModules, size: Int64 = 100, date: Date? = nil) -> CleanupEntry {
        CleanupEntry(id: path, category: category, label: path, displayPath: "~/" + path, urls: [f.url(path)], size: size, date: date)
    }

    @Test func trashMovesToTrashAndLogs() async throws {
        let f = try Fixture.standard()
        let (svc, log) = service(f)
        let outcome = await svc.perform([entry(f, "dev/web/node_modules", size: 42)], action: .trash, dryRun: false)

        #expect(outcome.failures.isEmpty)
        #expect(!f.exists("dev/web/node_modules"))
        #expect(outcome.bytes == 42)
        let records = await log.readAll()
        #expect(records.count == 1)
        #expect(records.first?.action == "trash")
        #expect(records.first?.size == 42)
        // Tidy up the real Trash.
        if let trashed = records.first?.items.first?.destination {
            try? FileManager.default.removeItem(atPath: trashed)
        }
    }

    @Test func permanentDelete() async throws {
        let f = try Fixture.standard()
        let (svc, _) = service(f)
        let outcome = await svc.perform([entry(f, "dev/rusty/target")], action: .delete, dryRun: false)
        #expect(outcome.failures.isEmpty)
        #expect(!f.exists("dev/rusty/target"))
    }

    @Test func dryRunChangesNothing() async throws {
        let f = try Fixture.standard()
        let (svc, log) = service(f)
        let outcome = await svc.perform([entry(f, "dev/rusty/target")], action: .delete, dryRun: true)
        #expect(f.exists("dev/rusty/target"))
        #expect(outcome.dryRun)
        #expect(outcome.completedIDs == ["dev/rusty/target"])
        let records = await log.readAll()
        #expect(records.first?.dryRun == true)
        #expect(records.freedBytes == 0, "dry runs don't count as freed")
    }

    @Test func refusesOutsideRootsAndExclusions() async throws {
        let f = try Fixture.standard()
        let (svc, _) = service(f, ctx: f.context(exclusions: ["~/dev/web"]))
        let outcome = await svc.perform([
            entry(f, "Downloads/ubuntu.iso"),       // node_modules category: outside its roots
            entry(f, "dev/web/node_modules"),       // excluded
            entry(f, "dev"),                        // a root itself
        ], action: .delete, dryRun: false)

        #expect(outcome.failures.count == 3)
        #expect(outcome.completedIDs.isEmpty)
        #expect(f.exists("Downloads/ubuntu.iso"))
        #expect(f.exists("dev/web/node_modules"))
        #expect(f.exists("dev"))
    }

    @Test func categoriesAreScopedToTheirOwnRoots() async throws {
        let f = try Fixture.standard()
        let (svc, _) = service(f)
        // Big files may touch ~/Downloads, node_modules may not.
        let ok = await svc.perform([entry(f, "Downloads/ubuntu.iso", category: .bigFiles)], action: .delete, dryRun: true)
        #expect(ok.failures.isEmpty)
        let refused = await svc.perform([entry(f, "Downloads/ubuntu.iso", category: .nodeModules)], action: .delete, dryRun: true)
        #expect(refused.failures.count == 1)
    }

    @Test func moveOrganizesByDateAndNeverOverwrites() async throws {
        let f = try Fixture()
        try f.file("Desktop/Screenshot A.png", contents: "new")
        try f.file("Pictures/Screenshots/2026/10/Screenshot A.png", contents: "old")
        let ctx = f.context()
        let (svc, _) = service(f, ctx: ctx)
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 5))!
        let outcome = await svc.perform(
            [entry(f, "Desktop/Screenshot A.png", category: .screenshots, date: date)],
            action: .move(destination: f.url("Pictures/Screenshots"), organizeByDate: true), dryRun: false)

        #expect(outcome.failures.isEmpty)
        #expect(!f.exists("Desktop/Screenshot A.png"))
        let old = try String(contentsOf: f.url("Pictures/Screenshots/2026/10/Screenshot A.png"), encoding: .utf8)
        let new = try String(contentsOf: f.url("Pictures/Screenshots/2026/10/Screenshot A 2.png"), encoding: .utf8)
        #expect(old == "old")
        #expect(new == "new")
    }

    @Test func cacheContentsAreRemovedButFolderKept() async throws {
        let f = try Fixture.standard()
        let ctx = f.context()
        let caches = await CacheScanner().collect(ctx)
        let brew = try #require(caches.first { $0.id == "homebrew" })
        let (svc, _) = service(f, ctx: ctx)
        let outcome = await svc.perform([CleanupEntry(brew)], action: .delete, dryRun: false)
        #expect(outcome.failures.isEmpty)
        #expect(f.exists("Library/Caches/Homebrew"))
        #expect(!f.exists("Library/Caches/Homebrew/downloads"))
    }

    @Test func recentProjectDetection() {
        let e = CleanupEntry(id: "x", category: .nodeModules, label: "x", displayPath: "x", urls: [], size: 0,
                             projectLastTouched: Date(timeIntervalSinceNow: -3 * 86_400))
        #expect(e.isRecentlyActive(days: 14))
        #expect(!e.isRecentlyActive(days: 2))
    }

    @Test func logBatches() async throws {
        let f = try Fixture()
        let log = CleanupLog(url: f.url("log/cleanup.log"))
        let now = Date()
        try await log.append([
            CleanupRecord(batchID: "a", timestamp: now, action: "trash", dryRun: false, category: .nodeModules, label: "web", path: "~/dev/web/node_modules", size: 10, items: [], failed: 0),
            CleanupRecord(batchID: "a", timestamp: now, action: "trash", dryRun: false, category: .nodeModules, label: "api", path: "~/dev/api/node_modules", size: 5, items: [], failed: 0),
        ])
        try await log.append([
            CleanupRecord(batchID: "b", timestamp: now.addingTimeInterval(10), action: "move", dryRun: false, category: .screenshots, label: "s", path: "~/Desktop/s.png", size: 3, items: [], failed: 0),
        ])
        let records = await log.readAll()
        #expect(records.count == 3)
        #expect(records.freedBytes == 15)
        #expect(records.batches.map(\.title) == ["s", "Cleared 2 node_modules"])
    }
}

@Suite("Cleanup progress")
struct CleanupProgressTests {
    @Test func permanentDeleteReportsEveryFile() async throws {
        let f = try Fixture()
        for i in 0..<25 { try f.file("dev/p/node_modules/pkg\(i)/index.js") }
        try FileManager.default.createSymbolicLink(at: f.url("dev/p/node_modules/link"), withDestinationURL: f.url("dev/keep"))
        try f.file("dev/keep/precious.txt")
        let svc = CleanupService(context: f.context(roots: ["~/dev"]), log: CleanupLog(url: f.url("log")))
        let progress = CleanupProgress()
        let entry = CleanupEntry(id: "nm", category: .nodeModules, label: "p", displayPath: "~/dev/p/node_modules",
                                 urls: [f.url("dev/p/node_modules")], size: 1000, fileCount: 25)
        let out = await svc.perform([entry], action: .delete, dryRun: false, progress: progress)

        #expect(out.failures.isEmpty)
        #expect(!f.exists("dev/p/node_modules"))
        #expect(f.exists("dev/keep/precious.txt"), "symlinks are removed, never followed")
        let s = progress.snapshot
        #expect(s.filesDone >= 25)
        #expect(s.fraction == 1)
        #expect(s.bytesDone == 1000)
        #expect(s.recent.contains { $0.hasSuffix("index.js") }, "individual file paths are streamed")
        #expect(s.recent.count <= CleanupProgress.recentLimit)
    }

    @Test func trashCountsWholeEntries() async throws {
        let f = try Fixture.standard()
        let svc = CleanupService(context: f.context(), log: CleanupLog(url: f.url("log")))
        let progress = CleanupProgress()
        let entry = CleanupEntry(id: "x", category: .buildArtifacts, label: "rusty", displayPath: "~/dev/rusty/target",
                                 urls: [f.url("dev/rusty/target")], size: 50, fileCount: 3)
        let out = await svc.perform([entry], action: .trash, dryRun: false, progress: progress)
        #expect(progress.snapshot.fraction == 1)
        #expect(progress.snapshot.currentPath.hasSuffix("dev/rusty/target"))
        if let trashed = out.records.first?.items.first?.destination { try? FileManager.default.removeItem(atPath: trashed) }
    }
}
