import Foundation

/// Global package managers (PRD §5.7). Commands are run through `ProcessRunner`; nothing runs as root.
enum PackageManagerKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case npm, homebrew, casks, cargo, pip, gem, pnpm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .npm: "npm -g"
        case .homebrew: "Homebrew"
        case .casks: "Casks"
        case .cargo: "Cargo"
        case .pip: "pip"
        case .gem: "gem"
        case .pnpm: "pnpm -g"
        }
    }

    /// The executable whose presence means the manager is installed.
    var tool: String {
        switch self {
        case .npm: "npm"
        case .homebrew, .casks: "brew"
        case .cargo: "cargo"
        case .pip: "python3"
        case .gem: "gem"
        case .pnpm: "pnpm"
        }
    }

    var listCommand: [String] {
        switch self {
        case .npm: ["npm", "ls", "-g", "--depth=0", "--json"]
        case .pnpm: ["pnpm", "ls", "-g", "--json"]
        case .homebrew: ["brew", "info", "--json=v2", "--installed"]
        case .casks: ["brew", "list", "--cask", "--versions"]
        case .cargo: ["cargo", "install", "--list"]
        case .pip: ["python3", "-m", "pip", "list", "--format=json"]
        case .gem: ["gem", "list", "--local"]
        }
    }

    /// May contact the package registry, so it only runs when the user asks.
    var outdatedCommand: [String]? {
        switch self {
        case .npm: ["npm", "outdated", "-g", "--json"]
        case .pnpm: ["pnpm", "outdated", "-g", "--format", "json"]
        case .homebrew: ["brew", "outdated", "--json=v2"]
        case .casks: ["brew", "outdated", "--cask", "--greedy", "--json=v2"]
        case .cargo: ["cargo", "install-update", "-l"]
        case .pip: ["python3", "-m", "pip", "list", "--outdated", "--format=json"]
        case .gem: ["gem", "outdated"]
        }
    }

    func updateCommand(_ pkg: String) -> [String] {
        switch self {
        case .npm: ["npm", "install", "-g", "\(pkg)@latest"]
        case .pnpm: ["pnpm", "add", "-g", "\(pkg)@latest"]
        case .homebrew: ["brew", "upgrade", pkg]
        case .casks: ["brew", "upgrade", "--cask", pkg]
        case .cargo: ["cargo", "install", pkg]
        case .pip: ["python3", "-m", "pip", "install", "-U", pkg]
        case .gem: ["gem", "update", pkg]
        }
    }

    func uninstallCommand(_ pkg: String) -> [String] {
        switch self {
        case .npm: ["npm", "uninstall", "-g", pkg]
        case .pnpm: ["pnpm", "remove", "-g", pkg]
        case .homebrew: ["brew", "uninstall", pkg]
        case .casks: ["brew", "uninstall", "--cask", pkg]
        case .cargo: ["cargo", "uninstall", pkg]
        case .pip: ["python3", "-m", "pip", "uninstall", "-y", pkg]
        case .gem: ["gem", "uninstall", "-x", pkg]
        }
    }

    /// Summary used by the v1.0 placeholder text and tooltips.
    var commands: (list: String, outdated: String, update: String, uninstall: String) {
        (listCommand.joined(separator: " "), outdatedCommand?.joined(separator: " ") ?? "—",
         updateCommand("<pkg>").joined(separator: " "), uninstallCommand("<pkg>").joined(separator: " "))
    }
}

struct InstalledPackage: Codable, Sendable, Identifiable, Hashable {
    enum Status: String, Codable, Sendable {
        case outdated, upToDate, unknown
    }

    var id: String { "\(manager.rawValue):\(name)" }
    let manager: PackageManagerKind
    let name: String
    let installedVersion: String
    var latestVersion: String?
    var status: Status
    /// Best effort, from binary access time (labeled approximate in the UI).
    var lastUsed: Date?
    var size: Int64?
    /// Binaries the package installs (used for "last used").
    var binaries: [String] = []

    var isUnused: Bool {
        guard let lastUsed else { return false }
        return Date().timeIntervalSince(lastUsed) > 365 * 86_400
    }

    var isOutdated: Bool { status == .outdated }
}

/// Parsers for each manager's output. Pure functions so they can be tested with captured output.
enum PackageParsers {
    private static func json(_ s: String) -> Any? {
        guard let data = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func installed(_ kind: PackageManagerKind, _ output: String) -> [InstalledPackage] {
        func pkg(_ name: String, _ version: String, bins: [String] = []) -> InstalledPackage {
            InstalledPackage(manager: kind, name: name, installedVersion: version, latestVersion: nil, status: .unknown, binaries: bins)
        }
        switch kind {
        case .npm:
            let deps = (json(output) as? [String: Any])?["dependencies"] as? [String: [String: Any]] ?? [:]
            return deps.map { pkg($0.key, $0.value["version"] as? String ?? "?") }.sorted { $0.name < $1.name }
        case .pnpm:
            let roots = json(output) as? [[String: Any]] ?? []
            var out: [InstalledPackage] = []
            for root in roots {
                for key in ["dependencies", "devDependencies"] {
                    for (name, info) in root[key] as? [String: [String: Any]] ?? [:] {
                        out.append(pkg(name, info["version"] as? String ?? "?"))
                    }
                }
            }
            return out.sorted { $0.name < $1.name }
        case .homebrew:
            let formulae = (json(output) as? [String: Any])?["formulae"] as? [[String: Any]] ?? []
            return formulae.compactMap { f in
                guard let name = f["name"] as? String else { return nil }
                let version = ((f["installed"] as? [[String: Any]])?.last?["version"] as? String) ?? "?"
                return pkg(name, version)
            }.sorted { $0.name < $1.name }
        case .casks:
            // "iterm2 3.5.4\nvisual-studio-code 1.95.0"
            return output.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: " ")
                guard let name = parts.first else { return nil }
                return pkg(String(name), parts.dropFirst().last.map(String.init) ?? "?")
            }
        case .cargo:
            // "ripgrep v14.1.0:\n    rg\nbat v0.24.0:\n    bat"
            var out: [InstalledPackage] = []
            for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix(" ") || line.hasPrefix("\t") {
                    if !out.isEmpty { out[out.count - 1].binaries.append(line.trimmingCharacters(in: .whitespaces)) }
                } else {
                    let parts = line.trimmingCharacters(in: CharacterSet(charactersIn: ":")).split(separator: " ")
                    guard parts.count >= 2 else { continue }
                    out.append(pkg(String(parts[0]), String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "v:"))))
                }
            }
            return out
        case .pip:
            let list = json(output) as? [[String: Any]] ?? []
            return list.compactMap { p in
                guard let name = p["name"] as? String else { return nil }
                return pkg(name, p["version"] as? String ?? "?")
            }.sorted { $0.name.lowercased() < $1.name.lowercased() }
        case .gem:
            // "rake (13.2.1, 13.0.6)" or "bigdecimal (default: 3.1.8)"
            return output.split(separator: "\n").compactMap { line in
                guard let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")") else { return nil }
                let name = line[..<open].trimmingCharacters(in: .whitespaces)
                let versions = line[line.index(after: open)..<close].replacingOccurrences(of: "default: ", with: "")
                guard !name.isEmpty else { return nil }
                return pkg(name, versions.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "?")
            }
        }
    }

    /// Latest versions by package name.
    static func outdated(_ kind: PackageManagerKind, _ output: String) -> [String: String] {
        var out: [String: String] = [:]
        switch kind {
        case .npm, .pnpm:
            for (name, info) in json(output) as? [String: [String: Any]] ?? [:] {
                if let latest = info["latest"] as? String { out[name] = latest }
            }
        case .homebrew, .casks:
            let root = json(output) as? [String: Any] ?? [:]
            for key in ["formulae", "casks"] {
                for f in root[key] as? [[String: Any]] ?? [] {
                    if let name = f["name"] as? String, let latest = f["current_version"] as? String { out[name] = latest }
                }
            }
        case .cargo:
            // cargo install-update -l table: "ripgrep   v14.0.0   v14.1.0   Yes"
            for line in output.split(separator: "\n") {
                let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if cols.count >= 4, cols.last == "Yes" {
                    out[String(cols[0])] = String(cols[2]).trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                }
            }
        case .pip:
            for p in json(output) as? [[String: Any]] ?? [] {
                if let name = p["name"] as? String, let latest = p["latest_version"] as? String { out[name] = latest }
            }
        case .gem:
            // "rake (13.0.6 < 13.2.1)"
            for line in output.split(separator: "\n") {
                guard let open = line.firstIndex(of: "("), let lt = line.range(of: " < "), let close = line.lastIndex(of: ")") else { continue }
                let name = line[..<open].trimmingCharacters(in: .whitespaces)
                out[name] = String(line[lt.upperBound..<close])
            }
        }
        return out
    }
}

/// Lists and checks one manager's packages. Sizes and "last used" are best effort.
struct PackageManagerService: Sendable {
    let kind: PackageManagerKind
    let runner: ProcessRunner

    func isInstalled() async -> Bool {
        guard await runner.which(kind.tool) != nil else { return false }
        if kind == .cargo || kind == .pnpm { return true }
        return true
    }

    /// Why updates/uninstalls are disabled for this manager, if they are (e.g. the system Python).
    func readOnlyReason() async -> String? {
        switch kind {
        case .pip:
            let path = await runner.which("python3")
            return path == "/usr/bin/python3" ? "This is Apple's system Python. Disk Keeper won't change it." : nil
        case .gem:
            let path = await runner.which("gem")
            return path == "/usr/bin/gem" ? "This is macOS's system Ruby; changing its gems needs sudo, which Disk Keeper never uses." : nil
        default:
            return nil
        }
    }

    func list() async throws -> (packages: [InstalledPackage], result: ProcessRunner.Result) {
        let r = try await runner.run(kind.listCommand, timeout: 90)
        var packages = PackageParsers.installed(kind, r.stdout)
        packages = await enrich(packages)
        return (packages, r)
    }

    func outdated() async throws -> (latest: [String: String], result: ProcessRunner.Result)? {
        guard let cmd = kind.outdatedCommand else { return nil }
        if kind == .cargo, await runner.which("cargo-install-update") == nil { return nil }
        // npm/pnpm exit 1 when something is outdated; that's not an error.
        let r = try await runner.run(cmd, timeout: 180)
        return (PackageParsers.outdated(kind, r.stdout), r)
    }

    /// Adds size and approximate last-used dates where the install location is known.
    private func enrich(_ packages: [InstalledPackage]) async -> [InstalledPackage] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var roots: [String: URL] = [:]
        var binDir: URL?
        switch kind {
        case .npm:
            if let r = try? await runner.run(["npm", "root", "-g"], timeout: 20), r.succeeded {
                let root = URL(fileURLWithPath: r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                for p in packages { roots[p.name] = root.appendingPathComponent(p.name) }
                binDir = root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("bin")
            }
        case .homebrew, .casks:
            let sub = kind == .homebrew ? "Cellar" : "Caskroom"
            if let r = try? await runner.run(["brew", "--prefix"], timeout: 20), r.succeeded {
                let prefix = URL(fileURLWithPath: r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                for p in packages { roots[p.name] = prefix.appendingPathComponent(sub).appendingPathComponent(p.name) }
                binDir = prefix.appendingPathComponent("bin")
            }
        case .cargo:
            binDir = home.appendingPathComponent(".cargo/bin")
        default:
            break
        }
        return packages.map { p in
            var p = p
            if let root = roots[p.name] {
                p.size = FileWalker.measure(root).size
                if kind == .npm, p.binaries.isEmpty { p.binaries = Self.npmBinaries(root) }
            } else if kind == .cargo, let binDir {
                p.size = p.binaries.reduce(0) { $0 + FileWalker.measure(binDir.appendingPathComponent($1)).size }
            }
            if let binDir {
                let bins = p.binaries.isEmpty ? [p.name] : p.binaries
                p.lastUsed = bins.compactMap { Self.accessDate(binDir.appendingPathComponent($0)) }.max()
            }
            return p
        }
    }

    static func npmBinaries(_ packageRoot: URL) -> [String] {
        guard let data = try? Data(contentsOf: packageRoot.appendingPathComponent("package.json")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        if let bin = json["bin"] as? [String: Any] { return Array(bin.keys) }
        if json["bin"] is String, let name = json["name"] as? String { return [name.split(separator: "/").last.map(String.init) ?? name] }
        return []
    }

    /// Access time of a binary, following its symlink. Approximate: volumes may not update atime.
    static func accessDate(_ url: URL) -> Date? {
        let target = url.resolvingSymlinksInPath()
        var st = stat()
        guard stat(target.path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_atimespec.tv_sec))
    }
}
