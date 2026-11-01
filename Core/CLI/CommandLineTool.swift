import Foundation

/// The `yokoi` command-line companion. It lives inside the app binary: link
/// `Yokoi.app/Contents/MacOS/Yokoi` as `yokoi` somewhere on your PATH, or pass a subcommand directly
/// (`Yokoi.app/Contents/MacOS/Yokoi scan --json`). It is read-only: it scans and reports, never cleans.
enum CommandLineTool {
    static let subcommands: Set<String> = ["scan", "help", "version", "--help", "--version"]

    /// True when the process was started as a CLI rather than as the app.
    static func isRequested(_ args: [String]) -> Bool {
        let invokedAs = ((args.first ?? "") as NSString).lastPathComponent
        if invokedAs == "yokoi" { return true }  // a symlink named in lowercase; the app binary is "Yokoi"
        return args.count > 1 && subcommands.contains(args[1])
    }

    static let usage = """
    yokoi: find the space your toolchains leave behind (read-only).

    USAGE
      yokoi scan [--json] [--category <names>] [--top <n>]
      yokoi version

    OPTIONS
      --json              Print the full report as JSON (sizes in bytes, dates in ISO 8601)
      --category <names>  Comma-separated: node-modules, build-artifacts, caches, big-files,
                          screenshots, applications (default: all)
      --top <n>           Show at most n items per category (default: 5 in text, all in JSON)

    Scans use the roots, exclusions and thresholds from Yokoi's Settings.
    Nothing is ever deleted from the command line: clean from the app.
    """

    struct Options: Equatable {
        var json = false
        var categories: Set<CleanCategory> = Set(ScanReport.scannable)
        var top: Int?
    }

    enum Command: Equatable {
        case scan(Options)
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
        case "scan": break
        default: throw UsageError(message: "unknown command '\(sub)'")
        }
        var options = Options()
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < rest.count else { throw UsageError(message: "\(flag) needs a value") }
            return rest[i]
        }
        while i < rest.count {
            let arg = rest[i]
            switch arg {
            case "--json": options.json = true
            case "--category", "--categories", "-c":
                var set = Set<CleanCategory>()
                for name in try value(arg).split(separator: ",") {
                    guard let c = CleanCategory(cliName: String(name).trimmingCharacters(in: .whitespaces)),
                          ScanReport.scannable.contains(c) else {
                        throw UsageError(message: "unknown category '\(name)'")
                    }
                    set.insert(c)
                }
                options.categories = set
            case "--top", "-n":
                guard let n = Int(try value(arg)), n >= 0 else { throw UsageError(message: "--top needs a number") }
                options.top = n
            case "-h", "--help": return .help
            default: throw UsageError(message: "unknown option '\(arg)'")
            }
            i += 1
        }
        return .scan(options)
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
        switch command {
        case .help:
            print(usage)
            return 0
        case .version:
            let info = Bundle.main.infoDictionary
            print("yokoi \(info?["CFBundleShortVersionString"] as? String ?? "dev") (\(info?["CFBundleVersion"] as? String ?? "0"))")
            return 0
        case .scan(let options):
            let settings = loadSettings()
            let interactive = isatty(STDERR_FILENO) != 0
            if interactive { FileHandle.standardError.write(Data("Scanning…\n".utf8)) }
            let box = ReportBox()
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                box.report = await ScanReport.run(settings: settings, categories: options.categories)
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
        }
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
                let path = PathFormat.abbreviate(URL(fileURLWithPath: item.path))
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

private extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}
