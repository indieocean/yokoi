import Foundation

/// Runs command-line tools (PRD §10 "ProcessRunner").
///
/// - Executables are launched directly via `/usr/bin/env`, never through a shell, and every argument is
///   passed separately, so package names can't inject commands.
/// - `PATH` comes from the user's login shell (Homebrew, nvm, asdf shims), resolved once.
/// - Privilege escalation is refused outright: Yokoi never runs `sudo`, `su`, `doas` or `osascript`.
/// - Every run has a timeout and keeps its output so the UI can show it.
actor ProcessRunner {
    struct Result: Sendable, Equatable {
        let command: [String]
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let duration: TimeInterval
        let timedOut: Bool

        var succeeded: Bool { exitCode == 0 && !timedOut }
        var commandLine: String { command.map(ProcessRunner.quote).joined(separator: " ") }
    }

    enum RunnerError: Error, LocalizedError, Equatable {
        case refused(String)
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .refused(let why): "Refused: \(why)"
            case .launchFailed(let why): "Couldn't start: \(why)"
            }
        }
    }

    static let shared = ProcessRunner()
    static let forbidden: Set<String> = ["sudo", "su", "doas", "osascript", "launchctl", "rm", "sh", "bash", "zsh"]

    private var resolvedPath: String?
    private let pathOverride: String?

    init(path: String? = nil) {
        self.pathOverride = path
    }

    /// Login-shell PATH plus common tool locations, so GUI launches find `brew`, `npm`, `cargo`…
    func searchPath() async -> String {
        if let pathOverride { return pathOverride }
        if let resolvedPath { return resolvedPath }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallback = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "\(home)/.cargo/bin", "\(home)/.bun/bin",
                        "\(home)/Library/pnpm", "\(home)/Library/pnpm/bin", "\(home)/.local/bin", "\(home)/go/bin", "/usr/local/go/bin", "/opt/local/bin",
                        "\(home)/.dotnet/tools", "/usr/local/share/dotnet", "\(home)/miniconda3/bin", "\(home)/miniforge3/bin",
                        "\(home)/anaconda3/bin", "/opt/homebrew/anaconda3/bin", "\(home)/.composer/vendor/bin",
                        "\(home)/.volta/bin", "\(home)/.local/share/fnm/aliases/default/bin"]
            + Self.nvmNodeBins(home: home)
            + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var path = fallback.joined(separator: ":")
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // Interactive *and* login, so tools set up in ~/.zshrc (nvm, pyenv, conda init) are found too.
        // stdin is closed and there's a timeout, and markers cut out any greeting the rc files print.
        let script = "printf '__DKPATH__%s__DKEND__' \"$PATH\""
        if let out = try? await Self.launch(executable: shell, arguments: ["-i", "-l", "-c", script],
                                            environment: ["HOME": home, "PATH": path, "TERM": "dumb"], timeout: 5),
           let start = out.stdout.range(of: "__DKPATH__"),
           let end = out.stdout.range(of: "__DKEND__", range: start.upperBound..<out.stdout.endIndex) {
            // Shell entries first, then anything from the fallback list it didn't include.
            var parts = out.stdout[start.upperBound..<end.lowerBound].split(separator: ":").map(String.init)
            for p in fallback where !parts.contains(p) { parts.append(p) }
            path = parts.joined(separator: ":")
        }
        resolvedPath = path
        return path
    }

    /// `~/.nvm/versions/node/<newest>/bin`, so global npm packages are found even if nvm isn't loaded.
    static func nvmNodeBins(home: String) -> [String] {
        let root = "\(home)/.nvm/versions/node"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        let newest = versions.filter { $0.hasPrefix("v") }.max { a, b in
            a.dropFirst().split(separator: ".").compactMap { Int($0) }.lexicographicallyPrecedes(b.dropFirst().split(separator: ".").compactMap { Int($0) })
        }
        return newest.map { ["\(root)/\($0)/bin"] } ?? []
    }

    /// Finds an executable on the search path, or nil when the tool isn't installed.
    func which(_ tool: String) async -> String? {
        let path = await searchPath()
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    func run(_ command: [String], timeout: TimeInterval = 120, environment extra: [String: String] = [:]) async throws -> Result {
        guard let tool = command.first, !tool.isEmpty else { throw RunnerError.refused("empty command") }
        let name = (tool as NSString).lastPathComponent
        guard !Self.forbidden.contains(name) else { throw RunnerError.refused("\(name) is never run by Yokoi") }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = await searchPath()
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["NO_COLOR"] = "1"
        env["NPM_CONFIG_UPDATE_NOTIFIER"] = "false"
        for (k, v) in extra { env[k] = v }
        return try await Self.launch(executable: "/usr/bin/env", arguments: command, environment: env, timeout: timeout, display: command)
    }

    private static func launch(executable: String, arguments: [String], environment: [String: String],
                               timeout: TimeInterval, display: [String]? = nil) async throws -> Result {
        let start = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let outData = DataBox(), errData = DataBox()
        out.fileHandleForReading.readabilityHandler = { h in outData.append(h.availableData) }
        err.fileHandleForReading.readabilityHandler = { h in errData.append(h.availableData) }

        let timedOut = DataBox()
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in cont.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    cont.resume(throwing: RunnerError.launchFailed(error.localizedDescription))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        timedOut.append(Data([1]))
                        process.terminate()
                    }
                }
            }
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        outData.append(out.fileHandleForReading.readDataToEndOfFile())
        errData.append(err.fileHandleForReading.readDataToEndOfFile())

        return Result(command: display ?? [executable] + arguments,
                      exitCode: process.terminationStatus,
                      stdout: String(decoding: outData.data, as: UTF8.self),
                      stderr: String(decoding: errData.data, as: UTF8.self),
                      duration: Date().timeIntervalSince(start),
                      timedOut: !timedOut.data.isEmpty)
    }

    nonisolated static func quote(_ arg: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:@,+%^"))
        if !arg.isEmpty, arg.unicodeScalars.allSatisfy({ safe.contains($0) }) { return arg }
        return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Thread-safe byte buffer for pipe handlers.
final class DataBox: @unchecked Sendable {
    private var storage = Data()
    private let lock = NSLock()

    func append(_ d: Data) {
        guard !d.isEmpty else { return }
        lock.lock(); storage.append(d); lock.unlock()
    }

    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
