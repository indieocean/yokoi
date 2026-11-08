import Foundation
import Testing

@Suite("Process runner and in-use detection")
struct PlatformTests {
    @Test func runsCommandsWithoutAShell() async throws {
        let runner = ProcessRunner(path: "/usr/bin:/bin", allowedTools: nil)
        let r = try await runner.run(["echo", "a;b", "$HOME"])
        #expect(r.succeeded)
        #expect(r.stdout == "a;b $HOME\n", "arguments are passed literally, never shell-expanded")
        #expect(r.commandLine == "/bin/echo 'a;b' '$HOME'", "the log shows the absolute path that ran")
    }

    // MARK: Trusted tool paths

    func chmod(_ url: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    @Test func runsAToolFromItsAbsolutePathOnly() async throws {
        let f = try Fixture()
        try script(f, "bin/tool", "echo real")
        let runner = ProcessRunner(path: f.url("bin").path + ":/usr/bin:/bin", allowedTools: nil)
        let exe = try #require(await runner.which("tool"))
        #expect(exe == f.url("bin/tool").path)
        #expect(await runner.resolved(["tool", "-v"]) == [exe, "-v"])
        let r = try await runner.run(["tool"])
        #expect(r.stdout == "real\n")
        #expect(r.command.first == exe)
        #expect(await runner.which("../bin/tool") == nil, "relative paths are never looked up")
    }

    @Test func skipsFoldersAndFilesOtherAccountsCanWrite() async throws {
        let f = try Fixture()
        try script(f, "open/tool", "echo planted")
        try chmod(f.url("open"), 0o777)
        try script(f, "safe/tool", "echo safe")
        #expect(!ProcessRunner.isTrusted(f.url("open").path, directory: true))
        #expect(ProcessRunner.trustedPath(f.url("open").path + ":" + f.url("safe").path + ":relative") == f.url("safe").path)

        let runner = ProcessRunner(path: ProcessRunner.trustedPath(f.url("open").path + ":" + f.url("safe").path), allowedTools: nil)
        #expect(try await runner.run(["tool"]).stdout == "safe\n", "the world-writable folder is dropped from PATH")

        // A world-writable file in a good folder is refused, and the search doesn't fall through to a later copy.
        try script(f, "first/tool2", "echo writable")
        try chmod(f.url("first/tool2"), 0o777)
        try script(f, "later/tool2", "echo later")
        let shadowed = ProcessRunner(path: f.url("first").path + ":" + f.url("later").path, allowedTools: nil)
        #expect(await shadowed.which("tool2") == nil)
        await #expect(throws: ProcessRunner.RunnerError.self) { try await shadowed.run(["tool2"]) }
    }

    @Test func followsSymlinksToCheckTheRealFile() throws {
        let f = try Fixture()
        try script(f, "cellar/tool", "echo hi")
        try chmod(f.url("cellar"), 0o777)
        try f.dir("bin")
        try FileManager.default.createSymbolicLink(atPath: f.url("bin/tool").path, withDestinationPath: f.url("cellar/tool").path)
        #expect(!ProcessRunner.isTrusted(f.url("bin/tool").path), "the link is fine, but its target sits in a world-writable folder")
        #expect(ProcessRunner.isTrusted("/bin/ls"))
        #expect(ProcessRunner.isTrusted("/usr/bin", directory: true))
        #expect(!ProcessRunner.isTrusted("/tmp", directory: true), "/tmp is world-writable")
    }

    @Test func onlyTrustsShellsListedInEtcShells() {
        let shells = "# comment\n/bin/zsh\n/bin/bash\n"
        #expect(ProcessRunner.loginShell("/bin/bash", shells: shells) == "/bin/bash")
        #expect(ProcessRunner.loginShell("/tmp/evil", shells: shells) == "/bin/zsh")
        #expect(ProcessRunner.loginShell(nil, shells: shells) == "/bin/zsh")
        #expect(ProcessRunner.loginShell("# comment", shells: shells) == "/bin/zsh")
    }

    @Test func refusesPrivilegeEscalation() async {
        let runner = ProcessRunner(path: "/usr/bin:/bin")
        for tool in ["sudo", "/usr/bin/sudo", "su", "osascript", "rm"] {
            await #expect(throws: ProcessRunner.RunnerError.self) { try await runner.run([tool, "-h"]) }
        }
    }

    @Test func reportsFailuresAndTimeouts() async throws {
        let runner = ProcessRunner(path: "/usr/bin:/bin", allowedTools: nil)
        let fail = try await runner.run(["ls", "/definitely/not/here"])
        #expect(fail.exitCode != 0)
        #expect(!fail.stderr.isEmpty)
        let slow = try await runner.run(["sleep", "5"], timeout: 0.5)
        #expect(slow.timedOut)
    }

    @Test func onlyRunsYokoisOwnTools() {
        let runner = ProcessRunner(path: "/usr/bin:/bin")
        #expect(runner.refusal(["npm", "ls", "-g"]) == nil)
        #expect(runner.refusal(["/opt/homebrew/bin/brew", "outdated"]) == nil)
        #expect(runner.refusal(["python3", "-m", "pip", "list"]) == nil)
        #expect(runner.refusal(["echo", "hi"]) != nil, "not a tool Yokoi runs")
        #expect(runner.refusal(["python3", "-c", "import os"]) != nil, "python3 only runs pip")
        #expect(runner.refusal(["python3"]) != nil)
        #expect(runner.refusal(["npm", "i", "a\0b"]) != nil)
        #expect(runner.refusal([]) != nil)
    }

    @Test(arguments: [["env", "sudo", "id"], ["/usr/bin/env", "rm", "-rf", "x"], ["xargs", "rm"], ["nohup", "sh"],
                      ["perl", "-e", "1"], ["dash", "-c", "id"], ["time", "sudo"]])
    func launchersAreRefusedEvenWithoutAnAllowlist(_ command: [String]) async {
        let runner = ProcessRunner(path: "/usr/bin:/bin", allowedTools: nil)
        #expect(runner.refusal(command) != nil)
        await #expect(throws: ProcessRunner.RunnerError.self) { try await runner.run(command) }
    }

    /// An executable script in the fixture's home, which is also the runner's whole PATH.
    func script(_ f: Fixture, _ name: String, _ body: String) throws {
        let url = try f.file(name, contents: "#!/bin/sh\n" + body + "\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test func killsAProcessThatIgnoresSIGTERM() async throws {
        let f = try Fixture()
        try script(f, "stubborn", "trap '' TERM\necho started\nwhile :; do sleep 1; done")
        let runner = ProcessRunner(path: f.home.path + ":/usr/bin:/bin", allowedTools: nil)
        let clock = ContinuousClock(), start = clock.now
        // Long enough for the script to reach its trap: the first launch of a freshly written script can
        // take a moment while macOS assesses it, and a SIGTERM before the trap would just end it.
        let timeout: TimeInterval = 2.5
        let r = try await runner.run(["stubborn"], timeout: timeout)
        let elapsed = clock.now - start
        #expect(r.timedOut)
        #expect(!r.succeeded)
        #expect(r.stdout.contains("started"), "the script ran, ignored SIGTERM, and was killed")
        #expect(elapsed >= .seconds(timeout + ProcessRunner.killGrace - 0.5), "SIGTERM alone didn't end it")
        #expect(elapsed < .seconds(timeout + ProcessRunner.killGrace + ProcessRunner.drainTimeout + 3))
    }

    @Test func returnsWhenABackgroundChildKeepsThePipeOpen() async throws {
        let f = try Fixture()
        // The background sleep inherits stdout, so EOF only comes when it exits, 20s later.
        try script(f, "forks", "sleep 20 &\necho started")
        let runner = ProcessRunner(path: f.home.path + ":/usr/bin:/bin", allowedTools: nil)
        let clock = ContinuousClock(), start = clock.now
        let r = try await runner.run(["forks"], timeout: 30)
        let elapsed = clock.now - start
        #expect(r.succeeded)
        #expect(!r.timedOut)
        #expect(r.stdout == "started\n")
        #expect(!r.reachedEOF, "the drain timeout ended the wait")
        #expect(elapsed < .seconds(ProcessRunner.drainTimeout + 4), "didn't wait for the background child")
    }

    @Test func collectsAllOutputOfAQuickCommand() async throws {
        let runner = ProcessRunner(path: "/usr/bin:/bin", allowedTools: nil)
        let r = try await runner.run(["seq", "1", "20000"])
        #expect(r.succeeded)
        #expect(r.stdout.split(separator: "\n").count == 20000)
        #expect(r.stdout.hasSuffix("20000\n"))
        // Not a stopwatch check: on a loaded CI runner a correct run can take longer than the drain timeout.
        #expect(r.reachedEOF, "EOF arrives on both pipes; the drain timeout isn't what ends the wait")
    }

    @Test func detectsAProcessWorkingInAFolder() async throws {
        let f = try Fixture()
        let project = try f.dir("dev/busy")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        process.currentDirectoryURL = project
        try process.run()
        defer { process.terminate() }
        try await Task.sleep(for: .milliseconds(200))

        let snapshot = InUseSnapshot.capture()
        #expect(snapshot.blocker(for: project) == "sleep")
        #expect(snapshot.blocker(for: f.url("dev/idle")) == nil)
        #expect(snapshot.blocker(for: f.home.deletingLastPathComponent()) != nil, "parents of a busy folder are busy too")
    }
}
