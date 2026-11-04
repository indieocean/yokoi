import Foundation
import Testing

@Suite("Items that need administrator rights")
struct AdminCommandTests {
    func outcome(_ failures: [CleanupOutcome.Failure]) -> CleanupOutcome {
        CleanupOutcome(batchID: "b", action: .delete, dryRun: false, records: [], failures: failures, completedIDs: [], bytes: 0)
    }

    func posix(_ code: Int32) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }

    func service(_ f: Fixture) -> CleanupService {
        CleanupService(context: f.context(), log: CleanupLog(url: f.url("support/cleanup.log")))
    }

    /// `dev/web/node_modules` with a read-only folder inside, as `sudo npm` leaves behind.
    func lockedFolder(_ f: Fixture) throws -> URL {
        try f.file("dev/web/node_modules/locked/index.js", bytes: 2_000)
        let locked = f.url("dev/web/node_modules/locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        return locked
    }

    func unlock(_ url: URL) { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }

    func entry(_ f: Fixture) -> CleanupEntry {
        CleanupEntry(id: "nm", category: .nodeModules, label: "web", displayPath: "~/dev/web/node_modules",
                     urls: [f.url("dev/web/node_modules")], size: 2_000)
    }

    @Test func aRealPermissionFailureOffersACommand() async throws {
        let f = try Fixture()
        let locked = try lockedFolder(f)
        defer { unlock(locked) }
        let result = await service(f).perform([entry(f)], action: .delete, dryRun: false)
        #expect(f.exists("dev/web/node_modules/locked/index.js"), "Yokoi itself never gets past this")
        #expect(result.failures.first?.needsAdmin == true)
        #expect(result.adminCommand == "sudo rm -rf -- '\(f.url("dev/web/node_modules").path)'")
    }

    @Test func aMoveNeverOffersOne() async throws {
        let f = try Fixture()
        let locked = try lockedFolder(f)
        defer { unlock(locked) }
        let blocked = f.url("Documents/readonly")
        try f.dir("Documents/readonly")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: blocked.path)
        defer { unlock(blocked) }
        let result = await service(f).perform([entry(f)], action: .move(destination: blocked, organizeByDate: false), dryRun: false)
        #expect(!result.failures.isEmpty)
        #expect(result.adminCommand == nil)
    }

    @Test func otherFailuresOfferNothing() async throws {
        let f = try Fixture()
        try f.dir("dev/web")
        let result = await service(f).perform([entry(f)], action: .delete, dryRun: false)
        #expect(result.failures.first?.reason == "No longer exists")
        #expect(result.adminCommand == nil)
    }

    @Test func refusalsOfferNothing() async throws {
        let f = try Fixture()
        try f.file("Library/Keychains/login.keychain-db")
        let protected = CleanupEntry(id: "k", category: .nodeModules, label: "k", displayPath: "k",
                                     urls: [f.url("Library/Keychains/login.keychain-db")], size: 1)
        let result = await service(f).perform([protected], action: .delete, dryRun: false)
        #expect(result.failures.first?.reason.hasPrefix("Refused") == true)
        #expect(result.adminCommand == nil, "what PathGuard refuses never turns into a command")
    }

    @Test func eaccesNeedsAdministrator() throws {
        let f = try Fixture()
        let file = try f.file("a.bin")
        #expect(CleanupService.needsAdministrator(posix(EACCES), at: file))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                              userInfo: [NSUnderlyingErrorKey: posix(EACCES)])
        #expect(CleanupService.needsAdministrator(wrapped, at: file))
    }

    @Test func eppermOnYourOwnFileIsPrivacyNotOwnership() throws {
        let f = try Fixture()
        let file = try f.file("a.bin")
        #expect(!CleanupService.needsAdministrator(posix(EPERM), at: file), "sudo doesn't get past macOS privacy protection")
        #expect(!CleanupService.needsAdministrator(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError), at: file))
    }

    @Test func immutableFilesCantBeRemovedEvenAsRoot() throws {
        let f = try Fixture()
        let file = try f.file("a.bin")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path) }
        #expect(!CleanupService.needsAdministrator(posix(EACCES), at: file))
    }

    @Test func goneOrUnrelatedErrorsDontNeedIt() throws {
        let f = try Fixture()
        #expect(!CleanupService.needsAdministrator(posix(EACCES), at: f.url("missing")))
        #expect(!CleanupService.needsAdministrator(posix(ENOSPC), at: try f.file("a.bin")))
    }

    @Test func pathsAreQuotedForTheShell() {
        let result = outcome([
            .init(path: "/h/it's a; rm -rf ~/x", reason: "", needsAdmin: true),
            .init(path: "/h/$(touch pwned)", reason: "", needsAdmin: true),
            .init(path: "/h/skipped", reason: ""),
        ])
        #expect(result.adminCommand == #"sudo rm -rf -- '/h/it'\''s a; rm -rf ~/x' '/h/$(touch pwned)'"#)
    }

    @Test func theCommandLineShowsItWithoutRunningIt() throws {
        let result = outcome([.init(path: "/h/x", reason: "denied", needsAdmin: true)])
        let plan = HeadlessClean.Plan(entries: [], blocked: [])
        let report = CleanReport(plan: plan, action: .delete, outcome: result)
        #expect(report.adminCommand == "sudo rm -rf -- '/h/x'")
        #expect(report.text().contains("Yokoi never uses sudo"))
        #expect(report.text().contains("sudo rm -rf -- '/h/x'"))
        #expect(report.json().contains("adminCommand"))
        #expect(!CleanReport(plan: plan, action: .delete, outcome: outcome([])).text().contains("sudo"))
    }
}
