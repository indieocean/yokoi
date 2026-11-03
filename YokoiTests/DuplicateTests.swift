import Foundation
import Testing

@Suite("Duplicate finder")
struct DuplicateTests {
    func context(_ f: Fixture) -> ScanContext {
        var ctx = f.context()
        ctx.duplicateFloor = 1_000
        return ctx
    }

    func contents(_ seed: String, bytes: Int = 4_000) -> String { String(repeating: seed, count: bytes / seed.count) }

    func groups(_ f: Fixture) async -> [DuplicateGroup] {
        DuplicateGroup.groups(await DuplicateScanner().collect(context(f)))
    }

    func paths(_ group: DuplicateGroup?) -> Set<String> { Set(group?.files.map(\.url.lastPathComponent) ?? []) }

    // MARK: Finding

    @Test func groupsFilesWithTheSameContents() async throws {
        let f = try Fixture()
        try f.file("Movies/a.mov", contents: contents("a"))
        try f.file("Desktop/old/b.mov", contents: contents("a"))
        try f.file("Documents/c.mov", contents: contents("b"))
        try f.file("Documents/d.mov", contents: contents("b"))
        try f.file("Documents/single.mov", contents: contents("c"))
        let found = await groups(f)
        #expect(found.count == 2)
        #expect(found.contains { paths($0) == ["a.mov", "b.mov"] })
        #expect(found.contains { paths($0) == ["c.mov", "d.mov"] })
    }

    @Test func sameSizeAndSameEndsIsNotEnough() async throws {
        let f = try Fixture()
        let size = DuplicateScanner.sampleBytes * 3
        let ends = String(repeating: "x", count: DuplicateScanner.sampleBytes)
        let middle = { (c: String) in String(repeating: c, count: size - 2 * DuplicateScanner.sampleBytes) }
        try f.file("Documents/a.bin", contents: ends + middle("a") + ends)
        try f.file("Documents/b.bin", contents: ends + middle("b") + ends)
        #expect(await groups(f).isEmpty)
    }

    @Test func skipsSmallFilesAndWhatBigFilesSkips() async throws {
        let f = try Fixture()
        try f.file("Documents/tiny1.txt", contents: "same")
        try f.file("Documents/tiny2.txt", contents: "same")
        for path in ["Library/x.bin", "Music/Music/x.bin", ".hidden/x.bin", "dev/web/node_modules/x.bin", "Documents/App.app/x.bin"] {
            try f.file(path, contents: contents("a"))
        }
        try f.file("Documents/one.bin", contents: contents("a"))
        #expect(await groups(f).isEmpty)
    }

    @Test func respectsExclusions() async throws {
        let f = try Fixture()
        try f.file("Documents/a.bin", contents: contents("a"))
        try f.file("Private/b.bin", contents: contents("a"))
        var ctx = context(f)
        ctx.exclusions = GlobMatcher(patterns: [f.url("Private").path])
        #expect(await DuplicateScanner().collect(ctx).isEmpty)
    }

    @Test func aHardlinkIsNotACopy() async throws {
        let f = try Fixture()
        let a = try f.file("Documents/a.bin", contents: contents("a"))
        try f.dir("Movies")
        try FileManager.default.linkItem(at: a, to: f.url("Movies/link.bin"))
        #expect(await groups(f).isEmpty)
    }

    @Test func clonesThatFreeNothingAreNotReported() async throws {
        let f = try Fixture()
        let a = try f.file("Documents/a.bin", contents: contents("a", bytes: 400_000))
        try f.dir("Movies")
        try FileManager.default.copyItem(at: a, to: f.url("Movies/clone.bin"))  // a clone on APFS
        guard FileWalker.measure(a, reclaimable: true).size == 0 else { return }  // volume doesn't clone
        #expect(await groups(f).isEmpty)
    }

    @Test func aCloneCountsOnlyWhatRemovingACopyFrees() async throws {
        let f = try Fixture()
        let a = try f.file("Documents/a.bin", contents: contents("a", bytes: 400_000))
        try f.dir("Movies")
        try FileManager.default.copyItem(at: a, to: f.url("Movies/clone.bin"))
        guard FileWalker.measure(a, reclaimable: true).size == 0 else { return }
        try f.file("Desktop/real.bin", contents: contents("a", bytes: 400_000))
        let group = try #require(await groups(f).first)
        #expect(group.files.count == 3)
        #expect(group.reclaimable >= 400_000 && group.reclaimable < 500_000, "only the real copy frees anything")
    }

    @Test func marksCopiesInsideARepository() async throws {
        let f = try Fixture()
        try f.file("dev/game/.git/HEAD")
        try f.file("dev/game/assets/deep/a.bin", contents: contents("a"))
        try f.file("Documents/b.bin", contents: contents("a"))
        let group = try #require(await groups(f).first)
        let inRepo = try #require(group.files.first { $0.name == "a.bin" })
        #expect(inRepo.repository?.path == f.url("dev/game").path)
        #expect(group.files.first { $0.name == "b.bin" }?.repository == nil)
    }

    @Test func aRepositoryAtHomeDoesNotClaimEverything() async throws {
        let f = try Fixture()
        try f.file(".git/HEAD")
        try f.file("Documents/a.bin", contents: contents("a"))
        try f.file("Movies/b.bin", contents: contents("a"))
        let group = try #require(await groups(f).first)
        #expect(group.files.allSatisfy { $0.repository == nil })
    }

    @Test func routineScansLeaveDuplicatesOut() async throws {
        #expect(!CleanCategory.routine.contains(.duplicates))
        #expect(!ScanReport.scannable.contains(.duplicates))
        let f = try Fixture()
        try f.file("Documents/a.bin", contents: contents("a"))
        try f.file("Movies/b.bin", contents: contents("a"))
        var routine = 0, asked = 0
        for await event in await ScanEngine().run(context(f), progress: ScanProgress()) {
            if case .duplicate = event { routine += 1 }
        }
        for await event in await ScanEngine().run(context(f), progress: ScanProgress(), categories: [.duplicates]) {
            if case .duplicate = event { asked += 1 }
        }
        #expect(routine == 0)
        #expect(asked == 2)
    }

    // MARK: Choosing what stays

    func file(_ path: String, size: Int64 = 100, repository: String? = nil, digest: String = "d") -> DuplicateFile {
        DuplicateFile(url: URL(fileURLWithPath: path), digest: digest, fileSize: size, size: size, modified: Date(),
                      repository: repository.map { URL(fileURLWithPath: $0) })
    }

    @Test func keepsTheBestCopy() {
        let group = DuplicateGroup(digest: "d", files: [
            file("/h/Downloads/clip.mov"), file("/h/Movies/clip copy.mov"), file("/h/Movies/clip.mov"),
        ])
        #expect(group.files[0].url.path == "/h/Movies/clip.mov")
        #expect(group.extras.map(\.url.path) == ["/h/Movies/clip copy.mov", "/h/Downloads/clip.mov"])
    }

    @Test func extrasNeverIncludeARepositoryCopy() {
        let outside = DuplicateGroup(digest: "d", files: [file("/h/a.bin"), file("/h/dev/x/deep/er/a.bin", repository: "/h/dev/x")])
        #expect(outside.files[0].repository != nil, "the repository's copy is the one to keep")
        #expect(outside.extras.map(\.url.path) == ["/h/a.bin"])

        let both = DuplicateGroup(digest: "d", files: [file("/h/x/a.bin", repository: "/h/x"), file("/h/y/a.bin", repository: "/h/y")])
        #expect(both.extras.isEmpty)
    }

    @Test func copiesAllInRepositoriesAreNotShown() {
        #expect(DuplicateGroup.groups([
            file("/h/x/a.bin", repository: "/h/x"), file("/h/y/a.bin", repository: "/h/y"),
        ]).isEmpty)
        #expect(DuplicateGroup.groups([
            file("/h/x/a.bin", repository: "/h/x"), file("/h/x/b.bin", repository: "/h/x"),
        ]).isEmpty, "two copies in one repository")
    }

    @Test func aRepositoryCopyMatchingAFileElsewhereIsShown() {
        let repo = file("/h/x/a.bin", repository: "/h/x")
        let other = file("/h/y/a.bin", repository: "/h/y")
        let outside = file("/h/Movies/a.bin")
        let group = DuplicateGroup.groups([repo, other, outside]).first
        #expect(group?.files.count == 3)
        #expect(group?.extras.map(\.url.path) == ["/h/Movies/a.bin"])
        // Once the outside copy is gone, only the repositories' own copies are left.
        #expect(DuplicateGroup.groups([repo, other]).isEmpty)
    }

    @Test func hiddenGroupsDontCountTowardsTheSaving() async throws {
        let f = try Fixture()
        try f.file("dev/game/.git/HEAD")
        try f.file("dev/game/a.bin", contents: contents("a"))
        try f.file("dev/game/vendor/b.bin", contents: contents("a"))
        try f.file("Documents/c.bin", contents: contents("b"))
        try f.file("Movies/d.bin", contents: contents("b"))
        let found = await groups(f)
        #expect(found.count == 1)
        #expect(paths(found.first) == ["c.bin", "d.bin"])
    }

    @Test func aChosenFolderShowsRepositoriesOwnCopies() {
        let copies = [file("/h/x/a.bin", repository: "/h/x"), file("/h/x/b.bin", repository: "/h/x")]
        let group = DuplicateGroup.groups(copies, includingRepositories: true).first
        #expect(group?.files.count == 2)
        #expect(group?.extras.isEmpty == true, "still only ever picked by hand")
    }

    @Test func aChosenFolderIsTheOnlyPlaceSearched() async throws {
        let f = try Fixture()
        try f.file("Documents/in/a.bin", contents: contents("a"))
        try f.file("Documents/in/deep/b.bin", contents: contents("a"))
        try f.file("Documents/out/c.bin", contents: contents("a"))
        var ctx = context(f)
        ctx.duplicateFolder = f.url("Documents/in")
        let found = await DuplicateScanner().collect(ctx)
        #expect(Set(found.map(\.name)) == ["a.bin", "b.bin"])
    }

    @Test func aChosenFolderMustBeInABigFileLocation() throws {
        let f = try Fixture()
        var ctx = context(f)
        ctx.bigFileRoots = [f.url("Documents")]
        #expect(ctx.duplicateFolderRefusal(f.url("Documents")) == nil)
        #expect(ctx.duplicateFolderRefusal(f.url("Documents/in/deep")) == nil)
        #expect(ctx.duplicateFolderRefusal(f.url("Documents2")) != nil, "shares a prefix, isn't inside")
        #expect(ctx.duplicateFolderRefusal(f.url("Movies")) != nil)
    }

    @Test func listsFilesItCouldNotRead() async throws {
        let f = try Fixture()
        try f.file("Documents/a.bin", contents: contents("a"))
        try f.file("Documents/b.bin", contents: contents("a"))
        let locked = try f.file("Movies/locked.bin", contents: contents("a"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let progress = ScanProgress()
        let found = await DuplicateScanner().collect(context(f), progress: progress)
        #expect(Set(found.map(\.name)) == ["a.bin", "b.bin"])
        #expect(progress.skippedFiles == [SkippedFile(url: locked, reason: .unreadable)])
    }

    @Test func aFileNothingMatchesInSizeIsNeverRead() async throws {
        let f = try Fixture()
        let locked = try f.file("Movies/locked.bin", contents: contents("a"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let progress = ScanProgress()
        _ = await DuplicateScanner().collect(context(f), progress: progress)
        #expect(progress.skippedFiles.isEmpty, "nothing shares its size, so it never needed reading")
    }

    @Test func aLoneCopyIsNotAGroup() {
        #expect(DuplicateGroup.groups([file("/h/a.bin")]).isEmpty)
    }

    @Test func biggestSavingComesFirst() {
        let groups = DuplicateGroup.groups([
            file("/h/s1", size: 10, digest: "small"), file("/h/s2", size: 10, digest: "small"),
            file("/h/b1", size: 90, digest: "big"), file("/h/b2", size: 90, digest: "big"),
        ])
        #expect(groups.map(\.digest) == ["big", "small"])
        #expect(groups[0].reclaimable == 90)
    }

    @Test func pickingEveryCopyStillLeavesOne() {
        let group = DuplicateGroup(digest: "d", files: [file("/h/a"), file("/h/bb"), file("/h/ccc")])
        let all = Set(group.files.map(\.id))
        #expect(group.removable(from: all).map(\.url.path) == ["/h/bb", "/h/ccc"])
        let entries = group.entries(removing: all)
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.keepCheck?.keep.map(\.url.path) == ["/h/a"] })
    }

    // MARK: Cleanup

    func twoCopies(_ f: Fixture) async throws -> DuplicateGroup {
        try f.file("Documents/a.bin", contents: contents("a"))
        try f.file("Movies/b.bin", contents: contents("a"))
        return try #require(await groups(f).first)
    }

    func service(_ f: Fixture) -> CleanupService {
        CleanupService(context: context(f), log: CleanupLog(url: f.url("support/cleanup.log")))
    }

    @Test func removesTheCopyPickedAndLeavesTheOther() async throws {
        let f = try Fixture()
        let group = try await twoCopies(f)
        let outcome = await service(f).perform(group.entries(removing: [f.url("Movies/b.bin").path]), action: .delete, dryRun: false)
        #expect(outcome.failures.isEmpty)
        #expect(f.exists("Documents/a.bin"))
        #expect(!f.exists("Movies/b.bin"))
    }

    @Test func refusesWhenTheKeptCopyIsGone() async throws {
        let f = try Fixture()
        let group = try await twoCopies(f)
        try FileManager.default.removeItem(at: f.url("Documents/a.bin"))
        let outcome = await service(f).perform(group.entries(removing: [f.url("Movies/b.bin").path]), action: .delete, dryRun: false)
        #expect(f.exists("Movies/b.bin"), "this is the last copy now")
        #expect(outcome.failures.first?.reason.contains("no unchanged copy") == true)
    }

    @Test func refusesWhenTheKeptCopyChanged() async throws {
        let f = try Fixture()
        let group = try await twoCopies(f)
        try f.file("Documents/a.bin", contents: contents("z", bytes: 5_000))
        let outcome = await service(f).perform(group.entries(removing: [f.url("Movies/b.bin").path]), action: .delete, dryRun: false)
        #expect(f.exists("Movies/b.bin"))
        #expect(outcome.completedIDs.isEmpty)
    }

    @Test func refusesWhenTheCopyItselfChanged() async throws {
        let f = try Fixture()
        let group = try await twoCopies(f)
        try f.setModified("Movies/b.bin", Date(timeIntervalSinceNow: 3_600))
        let outcome = await service(f).perform(group.entries(removing: [f.url("Movies/b.bin").path]), action: .delete, dryRun: false)
        #expect(f.exists("Movies/b.bin"))
        #expect(outcome.failures.first?.reason.contains("Changed since the last scan") == true)
    }

    /// Rewrites `path` with new contents of the same length, keeping its modification date.
    func edit(_ f: Fixture, _ path: String, keeping date: Date) throws {
        try f.file(path, contents: contents("z"))
        try f.setModified(path, date)
    }

    @Test func refusesAKeptCopyEditedWithoutChangingItsSizeOrDate() async throws {
        let f = try Fixture()
        let group = try await twoCopies(f)
        try edit(f, "Documents/a.bin", keeping: try #require(group.files.first { $0.name == "a.bin" }).modified)
        let outcome = await service(f).perform(group.entries(removing: [f.url("Movies/b.bin").path]), action: .delete, dryRun: false)
        #expect(f.exists("Movies/b.bin"), "the other file is no longer a copy of this one")
        #expect(outcome.failures.first?.reason.contains("no unchanged copy") == true)
    }

    @Test func refusesACopyEditedWithoutChangingItsSizeOrDate() async throws {
        let f = try Fixture()
        let group = try await twoCopies(f)
        try edit(f, "Movies/b.bin", keeping: try #require(group.files.first { $0.name == "b.bin" }).modified)
        let outcome = await service(f).perform(group.entries(removing: [f.url("Movies/b.bin").path]), action: .delete, dryRun: false)
        #expect(f.exists("Movies/b.bin"))
        #expect(outcome.failures.first?.reason.contains("Changed since the last scan") == true)
    }

    @Test func oneKeptCopyCoversSeveralRemovals() async throws {
        let f = try Fixture()
        try f.file("Documents/a.bin", contents: contents("a"))
        try f.file("Movies/b.bin", contents: contents("a"))
        try f.file("Desktop/c.bin", contents: contents("a"))
        let group = try #require(await groups(f).first)
        let ids = Set(["Movies/b.bin", "Desktop/c.bin"].map { f.url($0).path })
        let outcome = await service(f).perform(group.entries(removing: ids), action: .delete, dryRun: false)
        #expect(outcome.failures.isEmpty)
        #expect(f.exists("Documents/a.bin"))
        #expect(!f.exists("Movies/b.bin") && !f.exists("Desktop/c.bin"))
    }

    @Test func aCopyInTheSameCleanupDoesNotCountAsKept() async throws {
        let f = try Fixture()
        let group = try await twoCopies(f)
        // Each entry names the other as its survivor, as two stale requests merged into one would.
        let first = group.entries(removing: [f.url("Movies/b.bin").path])
        let second = group.entries(removing: [f.url("Documents/a.bin").path])
        for dryRun in [true, false] {
            let outcome = await service(f).perform(first + second, action: .delete, dryRun: dryRun)
            #expect(outcome.completedIDs.isEmpty)
            #expect(outcome.failures.count == 2)
        }
        #expect(f.exists("Documents/a.bin"))
        #expect(f.exists("Movies/b.bin"))
    }

    @Test func cleanupStaysInsideTheBigFileLocations() async throws {
        let f = try Fixture()
        let group = try await twoCopies(f)
        var ctx = context(f)
        ctx.bigFileRoots = [f.url("Documents")]
        let svc = CleanupService(context: ctx, log: CleanupLog(url: f.url("support/cleanup.log")))
        let outcome = await svc.perform(group.entries(removing: [f.url("Movies/b.bin").path]), action: .delete, dryRun: false)
        #expect(f.exists("Movies/b.bin"))
        #expect(outcome.failures.first?.reason.contains("outside the scan locations") == true)
    }
}
