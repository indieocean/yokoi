import Foundation
import Testing

@Suite("Findings from the security review")
struct SecurityReviewTests {
    func outcome(_ paths: String...) -> CleanupOutcome {
        CleanupOutcome(batchID: "b", action: .delete, dryRun: false, records: [],
                       failures: paths.map { .init(path: $0, reason: "", needsAdmin: true) }, completedIDs: [], bytes: 0)
    }

    // MARK: Shell quoting

    @Test func caretIsQuoted() {
        #expect(ProcessRunner.quote("/h/a^b") == "'/h/a^b'")
        #expect(ProcessRunner.quote("/h/plain.txt") == "/h/plain.txt")
    }

    @Test func everyPathInTheCommandIsQuoted() {
        #expect(outcome("/h/plain", "/h/a^b").adminCommand == "sudo rm -rf -- '/h/plain' '/h/a^b'")
    }

    /// The real shell, with the option that made this dangerous. Nothing here deletes: `print` only shows the words.
    @Test func zshSeesExactlyThePath() throws {
        let f = try Fixture()
        for name in ["a^b", "apple", "aardvark"] { try f.file("x/\(name)") }
        let quoted = ProcessRunner.alwaysQuoted(f.url("x/a^b").path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-f", "-c", "setopt extendedglob; print -rl -- \(quoted)"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let words = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
        #expect(words == [Substring(f.url("x/a^b").path)])
    }

    @Test func aPathThatCantBeReadIsNeverACommand() {
        #expect(outcome("/h/a\u{1B}[2Kb").adminCommand == nil)
        #expect(outcome("/h/a\nb").adminCommand == nil)
        #expect(outcome("/h/\u{202E}gnp.exe").adminCommand == nil)
        #expect(outcome("/h/ok", "/h/a\u{1B}b").adminCommand == "sudo rm -rf -- '/h/ok'")
        #expect(outcome("/h/café 日本語 👩‍💻").adminCommand != nil, "ordinary Unicode is fine")
    }

    // MARK: Terminal output

    @Test func escapesAreWrittenOut() {
        #expect(PathFormat.printable("evil\u{1B}[2K") == "evil\\u{1B}[2K")
        #expect(PathFormat.printable("a\u{202E}b") == "a\\u{202E}b")
        #expect(PathFormat.printable("a\u{9B}b") == "a\\u{9B}b")
        #expect(PathFormat.printable("plain café 👩‍💻") == "plain café 👩‍💻")
    }

    @Test func scanTextHasNoRawEscapes() {
        let item = ScanReport.Item(title: "x", path: "/h/evil\u{1B}[2Kproj", sizeBytes: 1, safety: .safe, lastTouched: nil, note: nil)
        let category = ScanReport.Category(id: "c", title: "C", reclaimableBytes: 1, count: 1, items: [item])
        let report = ScanReport(version: 1, scannedAt: Date(), durationSeconds: 0,
                                disk: .init(name: "D", totalBytes: 1, freeBytes: 1), reclaimableBytes: 1, categories: [category])
        let text = CommandLineTool.text(report, top: 5)
        #expect(!text.unicodeScalars.contains("\u{1B}"))
        #expect(text.contains("\\u{1B}"))
    }

    @Test func cleanTextHasNoRawEscapes() {
        var entry = CleanupEntry(id: "a", category: .caches, label: "a", displayPath: "/h/\u{1B}]0;x", urls: [], size: 1)
        entry.scannedAt = nil
        let plan = HeadlessClean.Plan(entries: [entry], blocked: [.init(entry: entry, process: "p\u{1B}")])
        #expect(!CleanReport(plan: plan, action: .delete, outcome: nil).text().unicodeScalars.contains("\u{1B}"))
    }

    // MARK: Who may run the command line

    @Test func macOSStartingItIsRefused() {
        let scan = CommandLineTool.Command.scan(.init()), clean = CommandLineTool.Command.clean(.init())
        #expect(CommandLineTool.refusal(clean, parent: 1, user: 501) != nil)
        #expect(CommandLineTool.refusal(scan, parent: 1, user: 501) != nil)
        #expect(CommandLineTool.refusal(clean, parent: 4242, user: 501) == nil, "shells, cron, SSH and CI have their own parent")
        #expect(CommandLineTool.refusal(.version, parent: 1, user: 501) == nil)
        #expect(CommandLineTool.refusal(.help, parent: 1, user: 501) == nil)
    }

    @Test func rootIsRefused() {
        #expect(CommandLineTool.refusal(.clean(.init()), parent: 4242, user: 0) != nil)
        #expect(CommandLineTool.refusal(.scan(.init()), parent: 4242, user: 0) != nil)
    }

    // MARK: Claiming another app's files

    func info(_ f: Fixture, id: String, name: String = "Fake") -> ApplicationScanner.Info {
        ApplicationScanner.Info(url: f.url("Applications/Fake.app"), name: name, bundleID: id, version: "1", isAppStore: false)
    }

    func removed(_ f: Fixture, _ info: ApplicationScanner.Info, sharedID: Bool = false) -> Set<String> {
        let all = ApplicationScanner.leftovers(for: info, home: f.home, matchName: true, sharedID: sharedID, context: f.context())
        return Set(all.filter { !$0.isUncertain }.map { $0.url.lastPathComponent })
    }

    @Test func aNameMatchIsOnlyASuggestion() throws {
        let f = try Fixture()
        try f.file("Library/Application Support/Google/Chrome/Cookies")
        let i = info(f, id: "com.fake.app", name: "Google")
        #expect(removed(f, i).isEmpty)
        let all = ApplicationScanner.leftovers(for: i, home: f.home, matchName: true, context: f.context())
        #expect(all.map(\.isUncertain) == [true], "still shown, for the user to pick")
    }

    @Test func aPickedSuggestionGoesWithTheApp() throws {
        let f = try Fixture()
        let support = f.url("Library/Application Support/Figma")
        let leftover = AppLeftover(url: support, kind: "Application Support", size: 500, uncertain: true)
        var app = AppItem(url: f.url("Applications/Figma.app"), name: "Figma", bundleID: "com.figma", version: "1", appSize: 100,
                          leftovers: [leftover], lastUsed: nil, isAppStore: false, protectedReason: nil, fileCount: 1)
        #expect(app.urls == [app.url])
        #expect(app.size == 100)
        app.chosenUncertain = [support.path]
        #expect(app.urls == [app.url, support])
        #expect(app.size == 600)
    }

    @Test func aSharedBundleIDProvesNothing() throws {
        let f = try Fixture()
        try f.file("Library/Containers/com.victim.vault/Data/db")
        let i = info(f, id: "com.victim.vault")
        #expect(removed(f, i) == ["com.victim.vault"])
        #expect(removed(f, i, sharedID: true).isEmpty, "two apps claim this id")
    }

    @Test func launchAgentsNeedTheWholeID() throws {
        let f = try Fixture()
        try f.file("Library/LaunchAgents/com.adobe.acc.plist")
        try f.file("Library/LaunchAgents/com.adobe.accmac.plist")
        try f.file("Library/LaunchAgents/com.adobe.acc.helper.plist")
        let i = info(f, id: "com.adobe.acc")
        let all = ApplicationScanner.leftovers(for: i, home: f.home, matchName: false, context: f.context())
        #expect(Set(all.map { $0.url.lastPathComponent }) == ["com.adobe.acc.plist", "com.adobe.acc.helper.plist"], "not accmac")
        #expect(removed(f, i) == ["com.adobe.acc.plist"], "the helper is only a suggestion")
    }

    @Test func aMalformedBundleIDMatchesNothing() throws {
        for bad in ["com", "", "a..b", ".com.x", "x/../y", "com.foo bar", "com.foo/bar"] {
            #expect(!ApplicationScanner.isValidBundleID(bad), "\(bad)")
        }
        for good in ["com.figma.Desktop", "org.mozilla.firefox", "com.foo-bar.baz_1"] {
            #expect(ApplicationScanner.isValidBundleID(good), "\(good)")
        }
        let f = try Fixture()
        try f.file("Library/LaunchAgents/com.dropbox.agent.plist")
        #expect(ApplicationScanner.leftovers(for: info(f, id: "com"), home: f.home, matchName: false, context: f.context()).isEmpty)
    }

    // MARK: Settings and protected folders

    @Test func unsafeSavedRootsAreDropped() throws {
        let f = try Fixture()
        var s = SettingsData(scanRoots: [ScanRoot(path: "/"), ScanRoot(path: "/System"), ScanRoot(path: "~/dev")])
        s.bigFileRoots = ["/", f.home.deletingLastPathComponent().path, "~"]
        let ctx = s.makeContext(home: f.home)
        #expect(ctx.roots.map(\.path) == ["~/dev"])
        #expect(ctx.bigFileRoots == [f.home])
    }

    @Test func secretsFoldersAreProtected() throws {
        let f = try Fixture()
        let guardrail = PathGuard(allowedRoots: [f.home], exclusions: GlobMatcher(patterns: []), home: f.home)
        for path in [".ssh/id_ed25519", ".gnupg/private-keys-v1.d/x", ".aws/credentials", ".SSH/id_rsa"] {
            #expect(guardrail.check(f.url(path)) == .protectedUserData, "\(path)")
        }
        #expect(guardrail.check(f.url(".sshfoo/x")) == nil, "matched by whole folder name")
    }

    // MARK: Global artifacts

    @Test func runningXcodeHoldsBackDerivedData() {
        let item = ArtifactItem(ruleID: "xcode-deriveddata", ecosystem: .xcode, projectURL: URL(fileURLWithPath: "/h/DerivedData"),
                                projectName: "All", targets: [URL(fileURLWithPath: "/h/DerivedData/x")], optIn: false, note: nil,
                                isGlobal: true, size: 1, fileCount: 1, lastTouched: nil, restoreHint: "")
        let entry = CleanupEntry(item)
        let split = InUseSnapshot(uses: [.init(path: "/Applications/Xcode.app/Contents/MacOS/Xcode", process: "Xcode")]).split([entry])
        #expect(split.allowed.isEmpty)
        #expect(split.blocked.first?.process == "Xcode")
    }
}
