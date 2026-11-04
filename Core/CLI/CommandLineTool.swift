import Foundation

/// The `yokoi` command-line companion. It lives inside the app binary: link
/// `Yokoi.app/Contents/MacOS/Yokoi` as `yokoi` somewhere on your PATH, or pass a subcommand directly
/// (`Yokoi.app/Contents/MacOS/Yokoi scan --json`). `scan` is read-only. `clean` previews unless given `--yes`.
enum CommandLineTool {
    static let subcommands: Set<String> = ["scan", "clean", "help", "version", "--help", "--version"]

    /// True when the process was started as a CLI rather than as the app.
    static func isRequested(_ args: [String]) -> Bool {
        let invokedAs = ((args.first ?? "") as NSString).lastPathComponent
        if invokedAs == "yokoi" { return true }  // a symlink named in lowercase; the app binary is "Yokoi"
        return args.count > 1 && subcommands.contains(args[1])
    }

    static let usage = """
    yokoi: find and clean the space your toolchains leave behind.

    USAGE
      yokoi scan [--json] [--category <names>] [--top <n>]
      yokoi clean [--yes] [--permanent] [--dry-run] [--json] [--category <names>]
      yokoi version

    SCAN OPTIONS
      --json              Print the full report as JSON (sizes in bytes, dates in ISO 8601)
      --category <names>  Comma-separated: node-modules, build-artifacts, caches, big-files,
                          downloads, screenshots, applications (default: all)
      --top <n>           Show at most n items per category (default: 5 in text, all in JSON)

    CLEAN OPTIONS
      --yes               Actually clean. Without it, clean only shows what it would do
      --permanent         Delete permanently instead of using the Trash. Can't be undone
      --dry-run           Only show what would happen, even with --yes
      --json              Print the result as JSON
      --category <names>  Comma-separated: node-modules, build-artifacts, caches (default: all)

    clean takes what Smart Select takes: stale node_modules, build artifacts of inactive
    projects and Safe caches. It never empties the Trash. Anything a running process is
    using is left alone, and that includes a project your shell is in.

    Both use the roots, exclusions and thresholds from Yokoi's Settings. Neither runs as root,
    or when started by macOS (`open`, a LaunchAgent) rather than a shell or a script.
    """

    struct Options: Equatable {
        var json = false
        var categories: Set<CleanCategory> = Set(ScanReport.scannable)
        var top: Int?
    }

    struct CleanOptions: Equatable {
        var json = false
        var categories = HeadlessClean.categories
        var yes = false
        var permanent = false
        var dryRun = false

        var willClean: Bool { yes && !dryRun }
        var action: CleanupAction { permanent ? .delete : .trash }
    }

    enum Command: Equatable {
        case scan(Options)
        case clean(CleanOptions)
        case help
        case version
    }

    struct UsageError: Error, Equatable { let message: String }

    static func parse(_ args: [String]) throws -> Command {
        var rest = Array(args.dropFirst())
        guard let sub = rest.first else { return .help }
        rest.removeFirst()
        switch sub {
        case "help", "--help", "-h": return .help
        case "version", "--version": return .version
        case "scan", "clean": break
        default: throw UsageError(message: "unknown command '\(sub)'")
        }
        let cleaning = sub == "clean"
        var options = Options()
        var clean = CleanOptions()
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < rest.count else { throw UsageError(message: "\(flag) needs a value") }
            return rest[i]
        }
        while i < rest.count {
            let arg = rest[i]
            switch arg {
            case "--json":
                options.json = true
                clean.json = true
            case "--category", "--categories", "-c":
                var set = Set<CleanCategory>()
                for name in try value(arg).split(separator: ",") {
                    guard let c = CleanCategory(cliName: String(name).trimmingCharacters(in: .whitespaces)),
                          ScanReport.scannable.contains(c) else {
                        throw UsageError(message: "unknown category '\(name)'")
                    }
                    if cleaning, !HeadlessClean.categories.contains(c) {
                        throw UsageError(message: "clean can't take '\(name)': those are your own files, so clean them in the app")
                    }
                    set.insert(c)
                }
                options.categories = set
                clean.categories = set
            case "--yes", "-y", "--permanent", "--dry-run":
                guard cleaning else { throw UsageError(message: "\(arg) only works with clean") }
                switch arg {
                case "--permanent": clean.permanent = true
                case "--dry-run": clean.dryRun = true
                default: clean.yes = true
                }
            case "--top", "-n":
                guard !cleaning else { throw UsageError(message: "\(arg) only works with scan") }
                guard let n = Int(try value(arg)), n >= 0 else { throw UsageError(message: "--top needs a number") }
                options.top = n
            case "-h", "--help": return .help
            default: throw UsageError(message: "unknown option '\(arg)'")
            }
            i += 1
        }
        return cleaning ? .clean(clean) : .scan(options)
    }

    /// Why `command` won't run, if it won't.
    ///
    /// Started directly, a command has the caller's privacy permissions. Started through LaunchServices
    /// (`open Yokoi.app --args clean --yes`), its parent is launchd and macOS treats it as the app itself, with the
    /// app's Full Disk Access, so any program could borrow that. Cron, SSH and CI have a parent of their own.
    static func refusal(_ command: Command, parent: pid_t = getppid(), user: uid_t = geteuid()) -> String? {
        switch command {
        case .help, .version: nil
        case .scan, .clean:
            if user == 0 { "Yokoi never runs as root. Run this as yourself, without sudo." }
            else if parent == 1 { "Run this from a shell or a script, not through macOS (open, a LaunchAgent)." }
            else { nil }
        }
    }

    /// Runs the command and returns the exit code.
    static func run(_ args: [String], settings loadSettings: () -> SettingsData) -> Int32 {
        let command: Command
        do {
            command = try parse(args)
        } catch let e as UsageError {
            FileHandle.standardError.write(Data("yokoi: \(e.message)\n\n\(usage)\n".utf8))
            return 64
        } catch {
            return 1
        }
        if let why = refusal(command) {
            FileHandle.standardError.write(Data("yokoi: \(why)\n".utf8))
            return 77  // EX_NOPERM
        }
        switch command {
        case .help:
            print(usage)
            return 0
        case .version:
            let info = Bundle.main.infoDictionary
            print("yokoi \(info?["CFBundleShortVersionString"] as? String ?? "dev") (\(info?["CFBundleVersion"] as? String ?? "0"))")
            print(Legal.notice)
            return 0
        case .scan(let options):
            let settings = loadSettings()
            let interactive = isatty(STDERR_FILENO) != 0
            if interactive { FileHandle.standardError.write(Data("Scanning…\n".utf8)) }
            let box = ReportBox()
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                box.report = await ScanReport.run(settings: settings, categories: options.categories, index: ScanIndex.defaultURL)
                done.signal()
            }
            done.wait()
            guard let report = box.report else { return 1 }
            if options.json {
                print(report.trimmed(to: options.top).json())
            } else {
                print(text(report, top: options.top ?? 5))
            }
            return 0
        case .clean(let options):
            return clean(options, settings: loadSettings())
        }
    }

    /// Exit code 1 when anything failed. Items held back because they're in use aren't a failure.
    private static func clean(_ options: CleanOptions, settings: SettingsData) -> Int32 {
        if isatty(STDERR_FILENO) != 0 { FileHandle.standardError.write(Data("Scanning…\n".utf8)) }
        let box = CleanBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let plan = await HeadlessClean.plan(settings: settings, categories: options.categories, index: ScanIndex.defaultURL)
            let outcome = options.willClean ? await HeadlessClean.execute(plan, action: options.action, settings: settings) : nil
            box.report = CleanReport(plan: plan, action: options.action, outcome: outcome)
            done.signal()
        }
        done.wait()
        guard let report = box.report else { return 1 }
        print(options.json ? report.json() : report.text())
        return report.failed.isEmpty ? 0 : 1
    }

    static func text(_ report: ScanReport, top: Int) -> String {
        var lines: [String] = []
        let d = report.disk
        lines.append("\(d.name): \(ByteFormat.string(d.freeBytes)) free of \(ByteFormat.string(d.totalBytes)) · scanned in \(String(format: "%.1f", report.durationSeconds))s")
        lines.append("")
        lines.append("Reclaimable  \(ByteFormat.string(report.reclaimableBytes))")
        for c in report.categories {
            lines.append("")
            lines.append("\(c.title.padding(toLength: 18, withPad: " ", startingAt: 0))\(ByteFormat.string(c.reclaimableBytes).leftPad(10))   \(CountFormat.plural(c.count, "item"))")
            for item in c.items.prefix(top) {
                let path = PathFormat.printable(PathFormat.abbreviate(URL(fileURLWithPath: item.path)))
                lines.append("  \(ByteFormat.string(item.sizeBytes).leftPad(10))  \(item.safety.label.padding(toLength: 11, withPad: " ", startingAt: 0)) \(path)")
            }
            if c.items.count > top, top > 0 { lines.append("  … \(c.items.count - top) more") }
        }
        return lines.joined(separator: "\n")
    }
}

private final class ReportBox: @unchecked Sendable {
    var report: ScanReport?
}

private final class CleanBox: @unchecked Sendable {
    var report: CleanReport?
}

private extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}
