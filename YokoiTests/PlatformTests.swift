import Foundation
import Testing

@Suite("Process runner and in-use detection")
struct PlatformTests {
    @Test func runsCommandsWithoutAShell() async throws {
        let runner = ProcessRunner(path: "/usr/bin:/bin")
        let r = try await runner.run(["echo", "a;b", "$HOME"])
        #expect(r.succeeded)
        #expect(r.stdout == "a;b $HOME\n", "arguments are passed literally, never shell-expanded")
        #expect(r.commandLine == "echo 'a;b' '$HOME'")
    }

    @Test func refusesPrivilegeEscalation() async {
        let runner = ProcessRunner(path: "/usr/bin:/bin")
        for tool in ["sudo", "/usr/bin/sudo", "su", "osascript", "rm"] {
            await #expect(throws: ProcessRunner.RunnerError.self) { try await runner.run([tool, "-h"]) }
        }
    }

    @Test func reportsFailuresAndTimeouts() async throws {
        let runner = ProcessRunner(path: "/usr/bin:/bin")
        let fail = try await runner.run(["ls", "/definitely/not/here"])
        #expect(fail.exitCode != 0)
        #expect(!fail.stderr.isEmpty)
        let slow = try await runner.run(["sleep", "5"], timeout: 0.5)
        #expect(slow.timedOut)
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
