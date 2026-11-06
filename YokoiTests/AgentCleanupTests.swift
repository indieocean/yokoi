import Foundation
import Testing

@Suite("AI agent cleanup")
struct AgentCleanupTests {
    private let session = "0b6f2a54-3c1e-4d7a-9f10-2a8e7c5d1b33"

    private func item(_ id: String, in f: Fixture) async throws -> CacheItem {
        let items = await CacheScanner().collect(f.context())
        return try #require(items.first { $0.id == id })
    }

    /// Anything holding history is only ever removed by hand: Safe is what Smart Select and auto-clean take.
    @Test func historyIsNeverCleanedUnattended() {
        let history = ["claude-cowork-vm", "claude-code-paste-cache", "claude-code-file-history", "claude-code-transcripts",
                       "grok-sessions", "gemini-sessions", "copilot-sessions"]
        for id in history { #expect(CacheLocation.byID[id]?.safety == .review, "\(id) needs a person to choose it") }
    }

    @Test func everyAgentLocationWaitsForItsAgent() {
        for location in CacheLocation.all where location.section == .aiAgents {
            #expect(!location.usedByApps.isEmpty, "\(location.id) is refused while its agent runs")
        }
    }

    /// Logins, settings and the things people build up by hand aren't in any location.
    @Test func credentialsAndConfigAreOutOfReach() throws {
        let f = try Fixture()
        let guardrail = f.context().pathGuard(for: .caches)
        for path in [".claude/.credentials.json", ".claude/settings.json", ".claude/skills/x", ".claude/plugins/x", ".claude/history.jsonl",
                     ".codex/auth.json", ".codex/config.toml", ".codex/sessions/2026/x.jsonl", ".codex/state_5.sqlite",
                     ".grok/auth.json", ".grok/config.toml", ".grok/bin/grok", ".gemini/settings.json", ".copilot/config.json",
                     "Library/Application Support/Cursor/User/globalStorage/state.vscdb",
                     "Library/Application Support/com.openai.chat/x", "Library/Application Support/Claude/config.json"] {
            #expect(guardrail.check(f.url(path)) == .outsideAllowedRoots, "\(path) can't be cleaned")
        }
    }

    @Test func claudeTranscriptsLeaveProjectMemory() async throws {
        let f = try Fixture()
        let project = ".claude/projects/-Users-me-Code-app"
        try f.file("\(project)/\(session).jsonl", bytes: 1_000)
        try f.file("\(project)/\(session).jsonl.superseded-1790000000", bytes: 100)
        try f.file("\(project)/\(session)/subagents/agent-1.jsonl", bytes: 500)
        try f.file("\(project)/memory/MEMORY.md", bytes: 900_000)
        try f.file("\(project)/memory/notes.jsonl", bytes: 900_000)
        try f.file("\(project)/added-by-a-later-version/x", bytes: 900_000)
        try f.file(".claude/projects/-Users-me-Code-only-memory/memory/MEMORY.md", bytes: 9_000)

        let found = try await item("claude-code-transcripts", in: f)
        let child = try #require(found.children?.first)
        #expect(found.children?.count == 1, "a project with only memory has nothing to clean")
        #expect(child.name == "Code-app")
        #expect(child.detail == "2 transcripts")
        #expect(Set(found.contents.map(\.lastPathComponent)) == [session, "\(session).jsonl", "\(session).jsonl.superseded-1790000000"])
        #expect(found.size < 100_000, "memory isn't counted as reclaimable")
    }

    @Test func installedGrokIsKept() async throws {
        let f = try Fixture()
        try f.file(".grok/downloads/grok-1.0.60-macos-aarch64", bytes: 1_000)
        let live = try f.file(".grok/downloads/grok-1.0.62-macos-aarch64", bytes: 1_000)
        try f.dir(".grok/bin")
        try FileManager.default.createSymbolicLink(at: f.url(".grok/bin/grok"), withDestinationURL: live)

        let found = try await item("grok-downloads", in: f)
        #expect(found.contents.map(\.lastPathComponent) == ["grok-1.0.60-macos-aarch64"])
    }

    @Test func noGrokDownloadIsOfferedWithoutKnowingTheInstalledOne() throws {
        let f = try Fixture()
        let download = try f.file(".grok/downloads/grok-1.0.62-macos-aarch64")
        #expect(CacheBreakdown.unlinkedDownloads([download]).isEmpty)
    }

    @Test func grokSessionsAreNamedByProject() throws {
        let group = CacheBreakdown.encodedProject(URL(fileURLWithPath: "/h/.grok/sessions/%2FUsers%2Fme%2FCode%2Fmy%20app"))
        #expect(group.name == "my app")
        #expect(group.detail == "/Users/me/Code/my app")
    }

    /// The native Claude Code binary's process is named after its version, and npm-installed agents run as `node`.
    @Test func agentsAreFoundWhateverTheirProcessIsCalled() {
        let native = InUseSnapshot(uses: [.init(path: "/Users/me/.local/share/claude/versions/2.1.319", process: "2.1.319")])
        #expect(native.runningApp(CacheLocation.claudeCodeProcesses) == "claude")

        let npm = InUseSnapshot(uses: [.init(path: "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js", process: "node")])
        #expect(npm.runningApp(CacheLocation.claudeCodeProcesses) == "claude")

        // `node /opt/homebrew/bin/gemini`: the shim is in the arguments as it was typed, its link unresolved.
        let shim = InUseSnapshot(uses: [.init(path: "/opt/homebrew/bin/gemini", process: "node")])
        #expect(shim.runningApp(CacheLocation.geminiProcesses) == "gemini")

        let grok = InUseSnapshot(uses: [.init(path: "/Users/me/.grok/downloads/grok-1.0.62-macos-aarch64", process: "grok-1.0.62-macos")])
        #expect(grok.runningApp(CacheLocation.grokProcesses) == "grok")

        let desktop = InUseSnapshot(uses: [.init(path: "/Applications/Claude.app/Contents/MacOS/Claude", process: "Claude")])
        #expect(desktop.runningApp(CacheLocation.claudeCodeProcesses) == "Claude")
        #expect(desktop.runningApp(CacheLocation.codexProcesses) == nil)
    }

    @Test func rowsMovedOutOfUserCachesAreNotCountedTwice() async throws {
        let f = try Fixture()
        try f.file("Library/Caches/claude-cli-nodejs/-Users-me/mcp.log", bytes: 1_000)
        try f.file("Library/Caches/SomeApp/x", bytes: 1_000)
        let found = try await item("user-caches", in: f)
        #expect(found.contents.map(\.lastPathComponent) == ["SomeApp"])
    }
}
