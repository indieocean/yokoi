import Foundation
import Testing

@Suite("Incremental rescans")
struct IncrementalScanTests {
    // MARK: Helpers

    private func freshIndex(_ ctx: ScanContext, _ f: Fixture) -> ScanIndex {
        ScanIndex(previous: nil, changes: nil, watched: [f.home.path], eventID: 1, volume: nil, bigFileKey: ScanIndex.bigFileKey(ctx))
    }

    /// Saves `index` and loads it back as the previous scan, with `changes` standing in for FSEvents.
    private func reload(_ index: ScanIndex, _ f: Fixture, changes: ChangeSet) throws -> ScanIndex {
        let url = f.home.deletingLastPathComponent().appendingPathComponent("scan-index.json")
        index.save(to: url, carryOver: false)
        let stored = try JSONDecoder().decode(ScanIndex.Stored.self, from: Data(contentsOf: url))
        return ScanIndex(previous: stored, changes: changes, watched: [f.home.path], eventID: 1, volume: nil, bigFileKey: stored.bigFileKey)
    }

    private func nothingChanged() -> ChangeSet { ChangeSet(changed: [String](), throughEventID: 1) }

    /// Every item the engine reports, as "category path size", sorted.
    private func results(_ ctx: ScanContext) async -> [String] {
        var out: [String] = []
        for await event in await ScanEngine().run(ctx, progress: ScanProgress(), categories: Set(ScanReport.scannable)) {
            switch event {
            case .nodeModules(let i): out.append("nm \(i.url.path) \(i.size) \(i.lastTouched?.timeIntervalSince1970 ?? 0)")
            case .artifact(let i): out.append("art \(i.projectURL.path) \(i.ruleID) \(i.size)")
            case .cache(let i): out.append("cache \(i.url.path) \(i.size)")
            case .bigFile(let i): out.append("big \(i.url.path) \(i.size)")
            case .screenshot(let i): out.append("shot \(i.url.path) \(i.size)")
            case .download(let i): out.append("dl \(i.url.path) \(i.size)")
            case .application(let i): out.append("app \(i.url.path) \(i.appSize)")
            case .duplicate, .finished: break
            }
        }
        return out.sorted()
    }

    // MARK: ChangeSet

    @Test func changeSetMatchesFoldersFilesAndSubtrees() {
        let c = ChangeSet(changed: ["/a/b/", "/x/y/z"], subtrees: ["/m"], throughEventID: 5)
        #expect(c.touches(directory: "/a/b"))
        #expect(c.touches(directory: "/a"))           // something under it changed
        #expect(c.touches(directory: "/x/y"))
        #expect(!c.touches(directory: "/a/bc"))       // sibling with a shared name prefix
        #expect(!c.touches(directory: "/a/b/c"))      // only /a/b's own entries changed
        #expect(c.touches(directory: "/m/n/o"))       // inside a must-rescan subtree
        #expect(c.touches(file: "/a/b/f.txt"))
        #expect(!c.touches(file: "/a/f.txt"))
        #expect(c.throughEventID == 5)
    }

    // MARK: ScanIndex

    @Test func unchangedFoldersReuseTheirMeasurement() throws {
        let f = try Fixture.standard()
        let ctx = f.context()
        let nm = f.url("dev/web/node_modules")
        let first = freshIndex(ctx, f)
        let size = first.measure(nm, progress: nil).size

        // Grow the folder without telling the index: a reused value proves nothing was re-measured.
        try f.file("dev/web/node_modules/a/extra.js", bytes: 50_000)
        let unchanged = try reload(first, f, changes: nothingChanged())
        #expect(unchanged.isIncremental)
        #expect(unchanged.measure(nm, progress: nil).size == size)
        #expect(unchanged.reused == 1)

        let changed = try reload(first, f, changes: ChangeSet(changed: [f.url("dev/web/node_modules/a").path + "/"], throughEventID: 2))
        #expect(changed.measure(nm, progress: nil).size > size)
        #expect(changed.reused == 0)

        let rescan = try reload(first, f, changes: ChangeSet(changed: [String](), subtrees: [f.url("dev").path], throughEventID: 2))
        #expect(rescan.measure(nm, progress: nil).size > size)
    }

    @Test func replacedFolderIsMeasuredAgain() throws {
        let f = try Fixture.standard()
        let nm = f.url("dev/web/node_modules")
        let first = freshIndex(f.context(), f)
        let size = first.measure(nm, progress: nil).size

        // A folder moved into place keeps its own contents' events elsewhere; the inode gives it away.
        try f.file("elsewhere/node_modules/big.js", bytes: 90_000)
        try FileManager.default.removeItem(at: nm)
        try FileManager.default.moveItem(at: f.url("elsewhere/node_modules"), to: nm)
        let next = try reload(first, f, changes: nothingChanged())
        #expect(next.measure(nm, progress: nil).size != size)
        #expect(next.reused == 0)
    }

    @Test func noHistoryMeansNoReuse() throws {
        let f = try Fixture.standard()
        let first = freshIndex(f.context(), f)
        _ = first.measure(f.url("dev/web/node_modules"), progress: nil)
        let url = f.home.deletingLastPathComponent().appendingPathComponent("scan-index.json")
        first.save(to: url, carryOver: false)
        let stored = try JSONDecoder().decode(ScanIndex.Stored.self, from: Data(contentsOf: url))
        let index = ScanIndex(previous: stored, changes: nil, watched: [f.home.path], eventID: 1, volume: nil, bigFileKey: stored.bigFileKey)
        #expect(!index.isIncremental)
        _ = index.measure(f.url("dev/web/node_modules"), progress: nil)
        #expect(index.reused == 0)
    }

    @Test func oldIndexStartsOver() async throws {
        let f = try Fixture.standard()
        let ctx = f.context()
        let url = f.home.deletingLastPathComponent().appendingPathComponent("scan-index.json")
        let first = freshIndex(ctx, f)
        _ = first.measure(f.url("dev/web/node_modules"), progress: nil)
        first.save(to: url, carryOver: false)
        var stored = try JSONDecoder().decode(ScanIndex.Stored.self, from: Data(contentsOf: url))
        // A previous scan's start time carries forward through incremental saves.
        #expect(try reload(first, f, changes: nothingChanged()).isIncremental)

        stored.fullScanAt = Date(timeIntervalSinceNow: -ScanIndex.maxAge - 60)
        stored.volume = ChangeJournal.volumeID(of: f.home)
        try JSONEncoder().encode(stored).write(to: url)
        let index = await ScanIndex.prepare(stored: url, context: ctx)
        #expect(!index.isIncremental)
    }

    @Test func incrementalScanMatchesAFullScan() async throws {
        let f = try Fixture.standard()
        let plain = await results(f.context())

        var ctx = f.context()
        let first = freshIndex(ctx, f)
        ctx.index = first
        #expect(await results(ctx) == plain)

        let second = try reload(first, f, changes: nothingChanged())
        ctx.index = second
        #expect(await results(ctx) == plain)
        #expect(second.reused > 0)
    }

    @Test func bigFilesAreReusedPerFolder() async throws {
        let f = try Fixture.standard()
        var ctx = f.context()
        let first = freshIndex(ctx, f)
        ctx.index = first
        let before = await BigFileScanner().collect(ctx).map(\.url.lastPathComponent)
        #expect(before.contains("ubuntu.iso"))

        try f.file("Downloads/new.iso", bytes: 2_000_000)
        ctx.index = try reload(first, f, changes: nothingChanged())
        #expect(!(await BigFileScanner().collect(ctx)).map(\.url.lastPathComponent).contains("new.iso"))

        ctx.index = try reload(first, f, changes: ChangeSet(changed: [f.url("Downloads").path], throughEventID: 2))
        #expect((await BigFileScanner().collect(ctx)).map(\.url.lastPathComponent).contains("new.iso"))
    }

    @Test func carryOverKeepsValidEntriesFromPartialScans() throws {
        let f = try Fixture.standard()
        let first = freshIndex(f.context(), f)
        let nm = f.url("dev/web/node_modules")
        let size = first.measure(nm, progress: nil).size
        let url = f.home.deletingLastPathComponent().appendingPathComponent("scan-index.json")

        // A scan that measured nothing, saved with carry-over, still remembers node_modules.
        let partial = try reload(first, f, changes: nothingChanged())
        partial.save(to: url, carryOver: true)
        let stored = try JSONDecoder().decode(ScanIndex.Stored.self, from: Data(contentsOf: url))
        #expect(stored.sizes[ScanIndex.key(nm)]?.size == size)

        partial.save(to: url, carryOver: false)
        let dropped = try JSONDecoder().decode(ScanIndex.Stored.self, from: Data(contentsOf: url))
        #expect(dropped.sizes.isEmpty)
    }

    // MARK: FSEvents

    @Test func journalSeesRealChanges() async throws {
        let f = try Fixture()
        try f.dir("watched")
        let since = ChangeJournal.currentEventID()
        try f.file("watched/new.txt")
        // FSEvents delivers with a short delay; poll instead of sleeping a fixed time.
        var seen = false
        for _ in 0..<20 where !seen {
            try await Task.sleep(for: .milliseconds(250))
            if let changes = await ChangeJournal.changes(since: since, under: [f.home.path], timeout: 5) {
                seen = changes.touches(file: f.url("watched/new.txt").path)
            }
        }
        #expect(seen)
        #expect(ChangeJournal.volumeID(of: f.home) != nil)
    }
}
