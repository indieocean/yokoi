import Foundation

/// Global package managers (PRD §5.7). Commands are run through `ProcessRunner`; nothing runs as root.
/// Every argument is passed literally (no shell), so package names can't inject commands.
enum PackageManagerKind: String, Codable, Sendable, CaseIterable, Identifiable {
    // JavaScript
    case npm, pnpm, yarn, bun
    // macOS
    case homebrew, casks, macports, mas
    // Native toolchains
    case cargo, go, dotnet
    // Python
    case pip, pipx, uv, conda
    // Other languages
    case gem, composer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .npm: "npm"
        case .pnpm: "pnpm -g"
        case .yarn: "yarn global"
        case .bun: "bun -g"
        case .homebrew: "Homebrew"
        case .casks: String(localized: "Casks", comment: "Package manager tab: Homebrew casks (apps)")
        case .macports: "MacPorts"
        case .mas: String(localized: "App Store (mas)", comment: "Package manager tab; mas is a command-line tool, keep it")
        case .cargo: "Cargo"
        case .go: "Go"
        case .dotnet: String(localized: ".NET tools", comment: "Package manager tab: .NET global tools")
        case .pip: "pip"
        case .pipx: "pipx"
        case .uv: String(localized: "uv tools", comment: "Package manager tab: tools installed with uv")
        case .conda: String(localized: "conda envs", comment: "Package manager tab: conda environments")
        case .gem: "gem"
        case .composer: "Composer"
        }
    }

    /// The executable whose presence means the manager is installed.
    var tool: String {
        switch self {
        case .npm: "npm"
        case .pnpm: "pnpm"
        case .yarn: "yarn"
        case .bun: "bun"
        case .homebrew, .casks: "brew"
        case .macports: "port"
        case .mas: "mas"
        case .cargo: "cargo"
        case .go: "go"
        case .dotnet: "dotnet"
        case .pip: "python3"
        case .pipx: "pipx"
        case .uv: "uv"
        case .conda: "conda"
        case .gem: "gem"
        case .composer: "composer"
        }
    }

    /// Lists installed packages. Local only, no network. (Go's binary folder is filled in at run time.)
    var listCommand: [String] {
        switch self {
        case .npm: ["npm", "ls", "-g", "--depth=0", "--json"]
        case .pnpm: ["pnpm", "ls", "-g", "--json"]
        case .yarn: ["yarn", "global", "list"]
        case .bun: ["bun", "pm", "ls", "-g"]
        case .homebrew: ["brew", "info", "--json=v2", "--installed"]
        case .casks: ["brew", "list", "--cask", "--versions"]
        case .macports: ["port", "installed", "requested"]
        case .mas: ["mas", "list"]
        case .cargo: ["cargo", "install", "--list"]
        case .go: ["go", "version", "-m", "<GOBIN>"]
        case .dotnet: ["dotnet", "tool", "list", "-g"]
        case .pip: ["python3", "-m", "pip", "list", "--format=json"]
        case .pipx: ["pipx", "list", "--json"]
        case .uv: ["uv", "tool", "list"]
        case .conda: ["conda", "env", "list", "--json"]
        case .gem: ["gem", "list", "--local"]
        case .composer: ["composer", "global", "show", "--format=json"]
        }
    }

    /// May contact the package registry, so it only runs when the user asks. nil = not supported.
    var outdatedCommand: [String]? {
        switch self {
        case .npm: ["npm", "outdated", "-g", "--json"]
        case .pnpm: ["pnpm", "outdated", "-g", "--format", "json"]
        case .homebrew: ["brew", "outdated", "--json=v2"]
        case .casks: ["brew", "outdated", "--cask", "--greedy", "--json=v2"]
        case .macports: ["port", "outdated"]
        case .mas: ["mas", "outdated"]
        case .cargo: ["cargo", "install-update", "-l"]
        case .pip: ["python3", "-m", "pip", "list", "--outdated", "--format=json"]
        case .uv: ["uv", "tool", "list", "--outdated"]
        case .gem: ["gem", "outdated"]
        case .composer: ["composer", "global", "outdated", "--format=json"]
        case .yarn, .bun, .go, .dotnet, .pipx, .conda: nil
        }
    }

    /// False for names a tool could read as an option (`-x`, `--force`) or that can't be passed safely.
    /// Targets come from the tools' own output, so this should never trip; it's a backstop.
    static func isSafeTarget(_ target: String) -> Bool {
        !target.isEmpty && !target.hasPrefix("-") && !target.contains(where: { $0 == "\0" || $0.isNewline })
    }

    /// nil when the manager can't update a single package without root (or the name isn't safe to pass).
    func updateCommand(_ target: String) -> [String]? {
        guard Self.isSafeTarget(target) else { return nil }
        return switch self {
        case .npm: ["npm", "install", "-g", "\(target)@latest"]
        case .pnpm: ["pnpm", "add", "-g", "\(target)@latest"]
        case .yarn: ["yarn", "global", "add", "\(target)@latest"]
        case .bun: ["bun", "add", "-g", "\(target)@latest"]
        case .homebrew: ["brew", "upgrade", target]
        case .casks: ["brew", "upgrade", "--cask", target]
        case .cargo: ["cargo", "install", target]
        case .go: ["go", "install", "\(target)@latest"]
        case .dotnet: ["dotnet", "tool", "update", "-g", target]
        case .pip: ["python3", "-m", "pip", "install", "-U", target]
        case .pipx: ["pipx", "upgrade", target]
        case .uv: ["uv", "tool", "upgrade", target]
        case .gem: ["gem", "update", target]
        case .composer: ["composer", "global", "update", target]
        case .macports, .mas, .conda: nil
        }
    }

    /// nil when there's no safe, root-free uninstall command (or the name isn't safe to pass).
    func uninstallCommand(_ target: String) -> [String]? {
        guard Self.isSafeTarget(target) else { return nil }
        return switch self {
        case .npm: ["npm", "uninstall", "-g", target]
        case .pnpm: ["pnpm", "remove", "-g", target]
        case .yarn: ["yarn", "global", "remove", target]
        case .bun: ["bun", "remove", "-g", target]
        case .homebrew: ["brew", "uninstall", target]
        case .casks: ["brew", "uninstall", "--cask", target]
        case .cargo: ["cargo", "uninstall", target]
        case .dotnet: ["dotnet", "tool", "uninstall", "-g", target]
        case .pip: ["python3", "-m", "pip", "uninstall", "-y", target]
        case .pipx: ["pipx", "uninstall", target]
        case .uv: ["uv", "tool", "uninstall", target]
        case .conda: ["conda", "env", "remove", "-p", target, "-y"]
        case .gem: ["gem", "uninstall", "-x", target]
        case .composer: ["composer", "global", "remove", target]
        case .go, .macports, .mas: nil
        }
    }

    /// Why the whole manager is list-only, if it is.
    var readOnlyReason: String? {
        switch self {
        case .macports: String(localized: "MacPorts needs sudo to change ports. Yokoi never uses sudo; run `sudo port …` yourself.")
        case .mas: String(localized: "mas needs root to update or remove App Store apps. Use the App Store, or the Applications screen to uninstall.")
        default: nil
        }
    }

    /// Shown under the tab when some actions aren't available.
    var note: String? {
        switch self {
        case .go: String(localized: "Go has no uninstall command: delete the binary from your Go bin folder to remove a tool.")
        case .conda: String(localized: "Each row is a conda environment. Removing one deletes everything installed in it.")
        case .yarn, .bun, .pipx, .dotnet: String(localized: "This manager can't check for newer versions; Update installs the latest.")
        default: nil
        }
    }

    /// Summary used in tooltips.
    var commands: (list: String, outdated: String, update: String, uninstall: String) {
        (listCommand.joined(separator: " "), outdatedCommand?.joined(separator: " ") ?? "—",
         updateCommand("<pkg>")?.joined(separator: " ") ?? "—", uninstallCommand("<pkg>")?.joined(separator: " ") ?? "—")
    }
}

struct InstalledPackage: Codable, Sendable, Identifiable, Hashable {
    enum Status: String, Codable, Sendable {
        case outdated, upToDate, unknown
    }

    var id: String { "\(manager.rawValue):\(identifier ?? name)" }
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
    /// What commands act on when it isn't the display name (mas app id, Go module path, conda env path).
    var identifier: String? = nil
    /// Why this one package can't be changed (e.g. conda's base environment).
    var locked: String? = nil

    var commandTarget: String { identifier ?? name }

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

    /// `typescript@5.4.5` or `@angular/cli@18.2.11` → (name, version).
    static func splitAtVersion(_ s: Substring) -> (String, String)? {
        guard let at = s.lastIndex(of: "@"), at != s.startIndex else { return nil }
        return (String(s[..<at]), String(s[s.index(after: at)...]))
    }

    static func installed(_ kind: PackageManagerKind, _ output: String) -> [InstalledPackage] {
        func pkg(_ name: String, _ version: String, bins: [String] = [], id: String? = nil, locked: String? = nil) -> InstalledPackage {
            InstalledPackage(manager: kind, name: name, installedVersion: version, latestVersion: nil, status: .unknown,
                             binaries: bins, identifier: id, locked: locked)
        }
        let lines = output.split(separator: "\n")
        switch kind {
        case .npm:
            let deps = (json(output) as? [String: Any])?["dependencies"] as? [String: [String: Any]] ?? [:]
            return deps.map { pkg($0.key, $0.value["version"] as? String ?? "?") }.sorted { $0.name < $1.name }

        case .pnpm:
            var out: [InstalledPackage] = []
            for root in json(output) as? [[String: Any]] ?? [] {
                for key in ["dependencies", "devDependencies"] {
                    for (name, info) in root[key] as? [String: [String: Any]] ?? [:] {
                        out.append(pkg(name, info["version"] as? String ?? "?"))
                    }
                }
            }
            return out.sorted { $0.name < $1.name }

        case .yarn:
            // info "typescript@5.4.5" has binaries:
            return lines.compactMap { line in
                guard line.hasPrefix("info \""), let end = line.dropFirst(6).firstIndex(of: "\""),
                      let (name, version) = splitAtVersion(line[line.index(line.startIndex, offsetBy: 6)..<end]) else { return nil }
                return pkg(name, version)
            }

        case .bun:
            // /Users/x/.bun/install/global node_modules (2)
            // ├── typescript@5.4.5
            // └── @biomejs/biome@1.9.0
            return lines.compactMap { line in
                guard let r = line.range(of: "── ") else { return nil }
                let token = line[r.upperBound...].split(separator: " ").first ?? ""
                guard let (name, version) = splitAtVersion(token) else { return nil }
                return pkg(name, version)
            }

        case .homebrew:
            let formulae = (json(output) as? [String: Any])?["formulae"] as? [[String: Any]] ?? []
            return formulae.compactMap { f in
                guard let name = f["name"] as? String else { return nil }
                let version = ((f["installed"] as? [[String: Any]])?.last?["version"] as? String) ?? "?"
                return pkg(name, version)
            }.sorted { $0.name < $1.name }

        case .casks:
            // iterm2 3.5.4
            return lines.compactMap { line in
                let parts = line.split(separator: " ")
                guard let name = parts.first else { return nil }
                return pkg(String(name), parts.dropFirst().last.map(String.init) ?? "?")
            }

        case .macports:
            //   wget @1.21.4_0 (active)
            return lines.compactMap { line in
                guard line.hasPrefix(" "), line.contains("(active)") else { return nil }
                let parts = line.split(separator: " ")
                guard parts.count >= 2 else { return nil }
                return pkg(String(parts[0]), parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "@")))
            }

        case .mas:
            // 497799835  Xcode  (15.0)
            return lines.compactMap { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard let space = t.firstIndex(of: " "), let open = t.lastIndex(of: "("), let close = t.lastIndex(of: ")"),
                      open > space else { return nil }
                let id = String(t[..<space])
                guard Int(id) != nil else { return nil }
                let name = t[space..<open].trimmingCharacters(in: .whitespaces)
                return pkg(name, String(t[t.index(after: open)..<close]), id: id)
            }

        case .cargo:
            // ripgrep v14.1.0:
            //     rg
            var out: [InstalledPackage] = []
            for line in lines {
                if line.hasPrefix(" ") || line.hasPrefix("\t") {
                    if !out.isEmpty { out[out.count - 1].binaries.append(line.trimmingCharacters(in: .whitespaces)) }
                } else {
                    let parts = line.trimmingCharacters(in: CharacterSet(charactersIn: ":")).split(separator: " ")
                    guard parts.count >= 2 else { continue }
                    out.append(pkg(String(parts[0]), String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "v:"))))
                }
            }
            return out

        case .go:
            // /Users/x/go/bin/gopls: go1.23.1
            //     path    golang.org/x/tools/gopls
            //     mod     golang.org/x/tools/gopls    v0.16.2    h1:…
            var out: [InstalledPackage] = []
            var bin: String?
            var path: String?
            func flush(_ version: String) {
                if let bin, let path { out.append(pkg(bin, version, bins: [bin], id: path)) }
                path = nil
            }
            for line in lines {
                if !line.hasPrefix("\t") && !line.hasPrefix(" ") {
                    bin = line.split(separator: ":").first.map { String($0.split(separator: "/").last ?? $0) }
                    path = nil
                    continue
                }
                let cols = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
                if cols.first == "path", cols.count >= 2 { path = String(cols[1]) }
                if cols.first == "mod", cols.count >= 3 { flush(String(cols[2]).trimmingCharacters(in: CharacterSet(charactersIn: "v"))) }
            }
            return out

        case .dotnet:
            // Package Id      Version      Commands
            // ---------------------------------------
            // dotnet-ef       8.0.0        dotnet-ef
            return lines.compactMap { line in
                let cols = line.split(separator: " ")
                guard cols.count >= 2, !line.hasPrefix("Package Id"), !line.hasPrefix("-") else { return nil }
                return pkg(String(cols[0]), String(cols[1]), bins: cols.count > 2 ? [String(cols[2])] : [])
            }

        case .pip:
            return (json(output) as? [[String: Any]] ?? []).compactMap { p in
                guard let name = p["name"] as? String else { return nil }
                return pkg(name, p["version"] as? String ?? "?")
            }.sorted { $0.name.lowercased() < $1.name.lowercased() }

        case .pipx:
            let venvs = (json(output) as? [String: Any])?["venvs"] as? [String: [String: Any]] ?? [:]
            return venvs.map { name, info in
                let main = (info["metadata"] as? [String: Any])?["main_package"] as? [String: Any]
                let bins = main?["apps"] as? [String] ?? []
                return pkg(name, main?["package_version"] as? String ?? "?", bins: bins)
            }.sorted { $0.name < $1.name }

        case .uv:
            // ruff v0.6.9
            // - ruff
            var out: [InstalledPackage] = []
            for line in lines {
                if line.hasPrefix("- ") {
                    if !out.isEmpty { out[out.count - 1].binaries.append(String(line.dropFirst(2))) }
                    continue
                }
                let parts = line.split(separator: " ")
                guard parts.count >= 2, parts[1].hasPrefix("v") else { continue }
                out.append(pkg(String(parts[0]), String(parts[1].dropFirst())))
            }
            return out

        case .conda:
            // {"envs": ["/Users/x/miniconda3", "/Users/x/miniconda3/envs/ml"]}
            let envs = (json(output) as? [String: Any])?["envs"] as? [String] ?? []
            return envs.map { path in
                let url = URL(fileURLWithPath: path)
                let isNamed = url.deletingLastPathComponent().lastPathComponent == "envs"
                return pkg(isNamed ? url.lastPathComponent : "base", "env", id: path,
                           locked: isNamed ? nil : String(localized: "The base environment holds conda itself and can't be removed."))
            }

        case .gem:
            // rake (13.2.1, 13.0.6)  /  bigdecimal (default: 3.1.8)
            return lines.compactMap { line in
                guard let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")") else { return nil }
                let name = line[..<open].trimmingCharacters(in: .whitespaces)
                let versions = line[line.index(after: open)..<close].replacingOccurrences(of: "default: ", with: "")
                guard !name.isEmpty else { return nil }
                return pkg(name, versions.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "?")
            }

        case .composer:
            let list = (json(output) as? [String: Any])?["installed"] as? [[String: Any]] ?? []
            return list.compactMap { p in
                guard let name = p["name"] as? String else { return nil }
                return pkg(name, (p["version"] as? String ?? "?").trimmingCharacters(in: CharacterSet(charactersIn: "v")))
            }
        }
    }

    /// Latest versions by package name (or by `identifier` where that's what's printed).
    /// Casks Homebrew refused to load, by name, with their tap:
    /// "Error: Refusing to load cask nikitabobko/tap/aerospace from untrusted tap nikitabobko/tap."
    static func untrustedCasks(_ stderr: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in stderr.split(separator: "\n") {
            let words = line.split(separator: " ")
            guard let at = words.firstIndex(of: "cask"), at > 0, words[at - 1] == "load",
                  let tapAt = words.firstIndex(of: "tap"), tapAt > at, words[tapAt - 1] == "untrusted",
                  words.indices.contains(at + 1), words.indices.contains(tapAt + 1) else { continue }
            let token = words[at + 1]
            let tap = words[tapAt + 1].trimmingCharacters(in: CharacterSet(charactersIn: "."))
            out[String(token.split(separator: "/").last ?? token)] = tap
        }
        return out
    }

    static func outdated(_ kind: PackageManagerKind, _ output: String) -> [String: String] {
        var out: [String: String] = [:]
        let lines = output.split(separator: "\n")
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
        case .macports:
            // wget   1.21.3_0 < 1.21.4_0
            for line in lines where line.contains(" < ") {
                let cols = line.split(separator: " ")
                if cols.count >= 4, let lt = cols.firstIndex(of: "<"), lt + 1 < cols.count { out[String(cols[0])] = String(cols[lt + 1]) }
            }
        case .mas:
            // 497799835 Xcode (15.0 -> 15.1)
            for line in lines {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard let space = t.firstIndex(of: " "), let open = t.lastIndex(of: "("), let arrow = t.range(of: "-> "),
                      let close = t.lastIndex(of: ")") else { continue }
                let name = t[space..<open].trimmingCharacters(in: .whitespaces)
                out[name] = String(t[arrow.upperBound..<close])
            }
        case .cargo:
            // ripgrep   v14.0.0   v14.1.0   Yes
            for line in lines {
                let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if cols.count >= 4, cols.last == "Yes" {
                    out[String(cols[0])] = String(cols[2]).trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                }
            }
        case .pip:
            for p in json(output) as? [[String: Any]] ?? [] {
                if let name = p["name"] as? String, let latest = p["latest_version"] as? String { out[name] = latest }
            }
        case .uv:
            // ruff v0.6.9 [latest: 0.7.0]
            for line in lines {
                guard let r = line.range(of: "[latest: "), let end = line[r.upperBound...].firstIndex(of: "]") else { continue }
                if let name = line.split(separator: " ").first { out[String(name)] = String(line[r.upperBound..<end]) }
            }
        case .gem:
            // rake (13.0.6 < 13.2.1)
            for line in lines {
                guard let open = line.firstIndex(of: "("), let lt = line.range(of: " < "), let close = line.lastIndex(of: ")") else { continue }
                out[line[..<open].trimmingCharacters(in: .whitespaces)] = String(line[lt.upperBound..<close])
            }
        case .composer:
            for p in (json(output) as? [String: Any])?["installed"] as? [[String: Any]] ?? [] {
                if let name = p["name"] as? String, let latest = p["latest"] as? String {
                    out[name] = latest.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                }
            }
        case .yarn, .bun, .go, .dotnet, .pipx, .conda:
            break
        }
        return out
    }
}

/// Lists and checks one manager's packages. Sizes and "last used" are best effort.
struct PackageManagerService: Sendable {
    let kind: PackageManagerKind
    let runner: ProcessRunner

    func isInstalled() async -> Bool {
        await runner.which(kind.tool) != nil
    }

    /// Why updates/uninstalls are disabled for this manager, if they are.
    func readOnlyReason() async -> String? {
        if let reason = kind.readOnlyReason { return reason }
        switch kind {
        case .pip:
            return await runner.which("python3") == "/usr/bin/python3" ? String(localized: "This is Apple's system Python. Yokoi won't change it.") : nil
        case .gem:
            return await runner.which("gem") == "/usr/bin/gem"
                ? String(localized: "This is macOS's system Ruby; changing its gems needs sudo, which Yokoi never uses.") : nil
        default:
            return nil
        }
    }

    func list() async throws -> (packages: [InstalledPackage], result: ProcessRunner.Result) {
        var command = kind.listCommand
        if kind == .go { command = ["go", "version", "-m", await goBin().path] }
        let r = try await runner.run(command, timeout: 90)
        if kind == .casks, !r.succeeded, let fallback = try await casksWithoutLoading(after: r) { return fallback }
        let packages = await enrich(PackageParsers.installed(kind, r.stdout))
        return (packages, r)
    }

    /// Homebrew 7 refuses `brew list --cask --versions` outright when any installed cask comes from an
    /// untrusted tap. Plain `brew list --cask` still works, so take the names from it and each version
    /// from its Caskroom folder. The cask Homebrew named is locked until its tap is trusted.
    private func casksWithoutLoading(after failed: ProcessRunner.Result) async throws -> ([InstalledPackage], ProcessRunner.Result)? {
        let untrusted = PackageParsers.untrustedCasks(failed.stderr)
        guard !untrusted.isEmpty, let prefix = await firstLine(["brew", "--prefix"]) else { return nil }
        let r = try await runner.run(["brew", "list", "--cask"], timeout: 90)
        guard r.succeeded else { return nil }
        let caskroom = URL(fileURLWithPath: prefix).appendingPathComponent("Caskroom")
        let fm = FileManager.default
        let lines = r.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { name in
            // Newest version folder; hidden entries like .metadata are skipped.
            let dir = caskroom.appendingPathComponent(name)
            let versions = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                        options: .skipsHiddenFiles)) ?? []
            let newest = versions.max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
            return "\(name) \(newest?.lastPathComponent ?? "?")"
        }
        var packages = await enrich(PackageParsers.installed(.casks, lines.joined(separator: "\n")))
        for i in packages.indices {
            if let tap = untrusted[packages[i].name] {
                packages[i].locked = String(localized: "Homebrew won't load this cask until you trust its tap: brew trust \(tap)", comment: "The placeholder is a Homebrew tap name; brew trust is a command, keep it")
            }
        }
        return (packages, r)
    }

    func outdated() async throws -> (latest: [String: String], result: ProcessRunner.Result)? {
        guard let cmd = kind.outdatedCommand else { return nil }
        if kind == .cargo, await runner.which("cargo-install-update") == nil { return nil }
        // npm/pnpm exit 1 when something is outdated; that's not an error.
        let r = try await runner.run(cmd, timeout: 180)
        return (PackageParsers.outdated(kind, r.stdout), r)
    }

    private func goBin() async -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let r = try? await runner.run(["go", "env", "GOBIN", "GOPATH"], timeout: 20), r.succeeded {
            let lines = r.stdout.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if let gobin = lines.first, !gobin.isEmpty { return URL(fileURLWithPath: gobin) }
            if lines.count > 1, let gopath = lines[1].split(separator: ":").first, !gopath.isEmpty {
                return URL(fileURLWithPath: String(gopath)).appendingPathComponent("bin")
            }
        }
        return home.appendingPathComponent("go/bin")
    }

    private func firstLine(_ command: [String]) async -> String? {
        guard let r = try? await runner.run(command, timeout: 20), r.succeeded else { return nil }
        let s = r.stdout.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return s.isEmpty ? nil : s
    }

    /// Adds size and approximate last-used dates where the install location is known.
    private func enrich(_ packages: [InstalledPackage]) async -> [InstalledPackage] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var root: ((InstalledPackage) -> URL)?
        var binDir: URL?
        switch kind {
        case .npm:
            if let r = await firstLine(["npm", "root", "-g"]) {
                let nm = URL(fileURLWithPath: r)
                root = { nm.appendingPathComponent($0.name) }
                binDir = nm.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("bin")
            }
        case .yarn:
            if let dir = await firstLine(["yarn", "global", "dir"]) {
                let nm = URL(fileURLWithPath: dir).appendingPathComponent("node_modules")
                root = { nm.appendingPathComponent($0.name) }
            }
            if let bin = await firstLine(["yarn", "global", "bin"]) { binDir = URL(fileURLWithPath: bin) }
        case .bun:
            let nm = home.appendingPathComponent(".bun/install/global/node_modules")
            root = { nm.appendingPathComponent($0.name) }
            binDir = home.appendingPathComponent(".bun/bin")
        case .homebrew, .casks:
            if let prefix = await firstLine(["brew", "--prefix"]) {
                let base = URL(fileURLWithPath: prefix)
                let sub = kind == .homebrew ? "Cellar" : "Caskroom"
                root = { base.appendingPathComponent(sub).appendingPathComponent($0.name) }
                binDir = base.appendingPathComponent("bin")
            }
        case .cargo:
            binDir = home.appendingPathComponent(".cargo/bin")
        case .go:
            binDir = await goBin()
        case .dotnet:
            let store = home.appendingPathComponent(".dotnet/tools/.store")
            root = { store.appendingPathComponent($0.name.lowercased()) }
            binDir = home.appendingPathComponent(".dotnet/tools")
        case .pipx:
            let venvs = home.appendingPathComponent(".local/pipx/venvs")
            root = { venvs.appendingPathComponent($0.name) }
            binDir = home.appendingPathComponent(".local/bin")
        case .uv:
            if let dir = await firstLine(["uv", "tool", "dir"]) {
                let base = URL(fileURLWithPath: dir)
                root = { base.appendingPathComponent($0.name) }
            }
            binDir = home.appendingPathComponent(".local/bin")
        case .conda:
            root = { URL(fileURLWithPath: $0.commandTarget) }
        case .composer:
            if let dir = await firstLine(["composer", "global", "config", "home"]) {
                let vendor = URL(fileURLWithPath: dir).appendingPathComponent("vendor")
                root = { vendor.appendingPathComponent($0.name) }
                binDir = vendor.appendingPathComponent("bin")
            }
        case .pnpm, .macports, .mas, .pip, .gem:
            break
        }

        return packages.map { p in
            var p = p
            if let root {
                let dir = root(p)
                if FileManager.default.fileExists(atPath: dir.path) { p.size = FileWalker.measure(dir).size }
                if kind == .npm || kind == .yarn || kind == .bun, p.binaries.isEmpty { p.binaries = Self.npmBinaries(dir) }
            } else if let binDir, !p.binaries.isEmpty {
                p.size = p.binaries.reduce(0) { $0 + FileWalker.measure(binDir.appendingPathComponent($1)).size }
            }
            if let binDir, kind != .conda {
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
