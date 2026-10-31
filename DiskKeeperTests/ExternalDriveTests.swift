import Foundation
import Testing

@Suite("External drives")
struct ExternalDriveTests {
    func drive(_ f: Fixture, appleFormat: Bool) -> ExternalDrive {
        ExternalDrive(url: f.url("Volumes/Stick"), name: "Stick", format: appleFormat ? "APFS" : "ExFAT", total: 1, available: 1,
                      isReadOnly: false, isTimeMachine: false, isEjectable: true, isAppleFormat: appleFormat)
    }

    @Test func findsJunkOnANonMacDrive() throws {
        let f = try Fixture()
        try f.file("Volumes/Stick/.DS_Store")
        try f.file("Volumes/Stick/photos/.DS_Store")
        try f.file("Volumes/Stick/photos/._IMG_1.jpg")
        try f.file("Volumes/Stick/photos/IMG_1.jpg", bytes: 5_000)
        try f.file("Volumes/Stick/.Trashes/\(getuid())/old.mov", bytes: 7_000)
        try f.file("Volumes/Stick/.Spotlight-V100/store")
        let junk = ExternalDrives.scanJunk(drive(f, appleFormat: false), exclusions: GlobMatcher(patterns: []))
        #expect(junk.dsStores.count == 2)
        #expect(junk.appleDoubles.map(\.lastPathComponent) == ["._IMG_1.jpg"])
        #expect(junk.trashContents.map(\.lastPathComponent) == ["old.mov"])
        #expect(!junk.dsStores.contains { $0.path.contains(".Trashes") })
    }

    @Test func leavesAppleDoubleAloneOnMacFormats() throws {
        let f = try Fixture()
        try f.file("Volumes/Stick/._thing")
        let junk = ExternalDrives.scanJunk(drive(f, appleFormat: true), exclusions: GlobMatcher(patterns: []))
        #expect(junk.appleDoubles.isEmpty)
    }

    @Test func cleanupIsScopedToListedDrives() async throws {
        let f = try Fixture()
        try f.file("Volumes/Stick/a/.DS_Store")
        try f.file("Volumes/Other/.DS_Store")
        var ctx = f.context()
        ctx.externalVolumes = [f.url("Volumes/Stick")]
        let svc = CleanupService(context: ctx, log: CleanupLog(url: f.url("log")))
        let entry = CleanupEntry(id: "x", category: .externalDrives, label: "junk", displayPath: "", urls: [
            f.url("Volumes/Stick/a/.DS_Store"), f.url("Volumes/Other/.DS_Store"), f.url("Volumes/Stick"),
        ], size: 1)
        let out = await svc.perform([entry], action: .delete, dryRun: false)
        #expect(!f.exists("Volumes/Stick/a/.DS_Store"))
        #expect(f.exists("Volumes/Other/.DS_Store"), "a drive that isn't listed is never touched")
        #expect(f.exists("Volumes/Stick"), "never the volume itself")
        #expect(out.failures.count == 2)
    }
}
