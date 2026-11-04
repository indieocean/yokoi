import Foundation

/// Runs command-line tools (PRD §10 "ProcessRunner").
///
/// - Each tool is looked up once to an absolute path and launched directly, never through `/usr/bin/env`
///   or a shell, and every argument is passed separately, so package names can't inject commands.
/// - `PATH` comes from the user's login shell (Homebrew, nvm, asdf shims), resolved once, and only if that
///   shell is listed in `/etc/shells`. Folders another account could write to are dropped from it, and a
///   tool is only run from a file another account couldn't have replaced (`isTrusted`): whatever Yokoi
///   starts inherits its Full Disk Access.
/// - Only the package-manager and developer tools Yokoi knows (`knownTools`) can be launched. Privilege
///   escalation, shells, interpreters and launchers that run another program (`env`, `xargs`…) are refused.
/// - Every run has a timeout (SIGTERM, then SIGKILL) and keeps its output so the UI can show it. A child
///   process that keeps the output pipe open can't hang a run either.
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
    /// Never run, even when `allowedTools` is nil: privilege escalation, shells, interpreters, and
    /// launchers that would run some other program named in their arguments.
    static let forbidden: Set<String> = [
        "sudo", "su", "doas", "osascript", "launchctl", "rm",
        "sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish",
        "env", "xargs", "nohup", "nice", "exec", "command", "script", "time", "timeout", "caffeinate",
        "perl", "ruby", "osacompile",
    ]
    /// Every tool Yokoi itself runs (package managers and the CLIs behind tool actions).
    static let knownTools: Set<String> = [
        "npm", "pnpm", "yarn", "bun", "brew", "port", "mas", "cargo", "go", "dotnet", "python3", "pipx", "uv",
        "conda", "gem", "composer", "xcrun", "tmutil", "docker",
    ]
    /// After SIGTERM, how long a timed-out process gets before SIGKILL.
    static let killGrace: TimeInterval = 2
    /// After the process exits, how long to wait for the rest of its output (a background child may hold the pipe).
    static let drainTimeout: TimeInterval = 2

    private var resolvedPath: String?
    /// Tool name → absolute path, looked up once.
    private var resolvedTools: [String: String] = [:]
    private let pathOverride: String?
    private let allowedTools: Set<String>?

    /// - Parameter allowedTools: tools that may be launched; nil allows anything not `forbidden` (tests only).
    init(path: String? = nil, allowedTools: Set<String>? = ProcessRunner.knownTools) {
        self.pathOverride = path
        self.allowedTools = allowedTools
    }

    /// Why `command` would be refused, or nil when it may run.
    nonisolated func refusal(_ command: [String]) -> String? {
        guard let tool = command.first, !tool.isEmpty else { return "empty command" }
        let name = (tool as NSString).lastPathComponent
        if Self.forbidden.contains(name) { return "\(name) is never run by Yokoi" }
        if let allowedTools, !allowedTools.contains(name) { return "\(name) isn't a tool Yokoi runs" }
        // python3 is only ever used for pip.
        if name == "python3", Array(command.dropFirst().prefix(2)) != ["-m", "pip"] { return "python3 only runs pip" }
        if command.contains(where: { $0.contains("\0") }) { return "argument contains a NUL byte" }
        return nil
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
                        "\(home)/.volta/bin", "\(home)/.docker/bin", "\(home)/.orbstack/bin", "/Applications/Docker.app/Contents/Resources/bin",
                        "\(home)/Library/Android/sdk/platform-tools", "\(home)/Library/Android/sdk/emulator", "\(home)/.local/share/fnm/aliases/default/bin"]
            + Self.nvmNodeBins(home: home)
            + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var path = fallback.joined(separator: ":")
        let shell = Self.loginShell(ProcessInfo.processInfo.environment["SHELL"])
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
        path = Self.trustedPath(path)
        resolvedPath = path
        return path
    }

    /// `$SHELL` when `/etc/shells` lists it, else zsh: an arbitrary program named in the environment is never started.
    static func loginShell(_ candidate: String?, shells: String? = try? String(contentsOfFile: "/etc/shells", encoding: .utf8)) -> String {
        let listed = Set((shells ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("/") })
        if let candidate, listed.contains(candidate), isTrusted(candidate) { return candidate }
        return "/bin/zsh"
    }

    /// `path` without the folders that are relative, missing, duplicated or writable by another account.
    static func trustedPath(_ path: String) -> String {
        var seen = Set<String>()
        return path.split(separator: ":").map(String.init)
            .filter { $0.hasPrefix("/") && seen.insert($0).inserted && isTrusted($0, directory: true) }
            .joined(separator: ":")
    }

    /// Group ids whose members can already use sudo: a folder they can write to gives nothing away.
    /// (Homebrew makes `/opt/homebrew` writable by `admin` on many Macs.)
    static let privilegedGroups: Set<gid_t> = [0, 80] // wheel, admin

    /// Whether only the user, root or an admin could have put this file or folder there: owned by the user
    /// or root, never world-writable, and group-writable only for wheel/admin. For a file, its real location
    /// (Homebrew links into the Cellar) and that location's folder must pass too.
    static func isTrusted(_ path: String, directory: Bool = false, uid: uid_t = getuid()) -> Bool {
        func ok(_ p: String, dir: Bool) -> Bool {
            var st = stat()
            guard stat(p, &st) == 0 else { return false }
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            guard isDir == dir, st.st_uid == uid || st.st_uid == 0, st.st_mode & S_IWOTH == 0 else { return false }
            return st.st_mode & S_IWGRP == 0 || privilegedGroups.contains(st.st_gid)
        }
        if directory { return ok(path, dir: true) }
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return ok(path, dir: false) && ok(real, dir: false) && ok((real as NSString).deletingLastPathComponent, dir: true)
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

    /// Finds an executable on the search path, or nil when the tool isn't installed (or only in a place
    /// another account could have written to). An absolute path is checked the same way.
    func which(_ tool: String) async -> String? {
        if let known = resolvedTools[tool] { return known }
        var found: String?
        if tool.hasPrefix("/") {
            found = FileManager.default.isExecutableFile(atPath: tool) && Self.isTrusted(tool) ? tool : nil
        } else if !tool.contains("/") {
            for dir in await searchPath().split(separator: ":") {
                let candidate = "\(dir)/\(tool)"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    // The first match is the one a shell would run: if it's untrusted, don't fall through to another.
                    found = Self.isTrusted(candidate) ? candidate : nil
                    break
                }
            }
        }
        if let found { resolvedTools[tool] = found }
        return found
    }

    /// `command` with its tool replaced by the absolute path that will run, for showing before confirming.
    /// Nil when the tool isn't installed in a trusted place.
    func resolved(_ command: [String]) async -> [String]? {
        guard let tool = command.first, let exe = await which(tool) else { return nil }
        return [exe] + command.dropFirst()
    }

    func run(_ command: [String], timeout: TimeInterval = 120, environment extra: [String: String] = [:]) async throws -> Result {
        if let why = refusal(command) { throw RunnerError.refused(why) }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = await searchPath()
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["NO_COLOR"] = "1"
        env["NPM_CONFIG_UPDATE_NOTIFIER"] = "false"
        for (k, v) in extra { env[k] = v }
        guard let exe = await which(command[0]) else {
            throw RunnerError.launchFailed("\((command[0] as NSString).lastPathComponent) isn't installed, or only in a folder another account can write to")
        }
        let arguments = Array(command.dropFirst())
        return try await Self.launch(executable: exe, arguments: arguments, environment: env, timeout: timeout, display: [exe] + arguments)
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

        // Output is collected by the handlers until EOF; nothing ever blocks on reading the pipe.
        let outData = DataBox(), errData = DataBox()
        let drained = DispatchGroup()
        for (pipe, box) in [(out, outData), (err, errData)] {
            drained.enter()
            let eof = Once()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty {
                    h.readabilityHandler = nil
                    if eof.claim() { drained.leave() }
                } else {
                    box.append(d)
                }
            }
        }
        func stopReading() {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
        }

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
                    guard process.isRunning else { return }
                    timedOut.append(Data([1]))
                    process.terminate()
                    // A process that ignores SIGTERM is killed.
                    DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
            }
        } catch {
            stopReading()
            throw error
        }
        // Wait for EOF on both pipes, but not forever: a background child can keep them open.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let resumed = Once()
            drained.notify(queue: .global()) { if resumed.claim() { cont.resume() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + drainTimeout) { if resumed.claim() { cont.resume() } }
        }
        stopReading()

        return Result(command: display ?? [executable] + arguments,
                      exitCode: process.terminationStatus,
                      stdout: String(decoding: outData.data, as: UTF8.self),
                      stderr: String(decoding: errData.data, as: UTF8.self),
                      duration: Date().timeIntervalSince(start),
                      timedOut: !timedOut.data.isEmpty)
    }

    /// `arg` in single quotes whatever it holds, for a command that deletes: nothing in it is left to the shell.
    nonisolated static func alwaysQuoted(_ arg: String) -> String {
        "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func quote(_ arg: String) -> String {
        // Not `^`: with zsh's EXTENDED_GLOB it's a wildcard, so `a^b` would match other files.
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:@,+%"))
        if !arg.isEmpty, arg.unicodeScalars.allSatisfy({ safe.contains($0) }) { return arg }
        return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// True for the first caller of `claim()` only.
final class Once: @unchecked Sendable {
    private var claimed = false
    private let lock = NSLock()

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
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
