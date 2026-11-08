import Foundation

/// Cleanups that must go through the owning tool rather than deleting files (PRD FR-C3).
enum ToolAction: String, CaseIterable, Sendable, Identifiable {
    case unavailableSimulators
    case simulatorRuntimes
    case localSnapshots
    case dockerImages
    case dockerBuildCache
    case dockerVolumes
    case goModuleCache

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unavailableSimulators: String(localized: "Unavailable simulators", comment: "Tool cleanup row title")
        case .simulatorRuntimes: String(localized: "Simulator runtimes", comment: "Tool cleanup row title")
        case .localSnapshots: String(localized: "Local Time Machine snapshots", comment: "Tool cleanup row title")
        case .dockerImages: String(localized: "Unused Docker images", comment: "Tool cleanup row title")
        case .dockerBuildCache: String(localized: "Docker build cache", comment: "Tool cleanup row title")
        case .dockerVolumes: String(localized: "Unused Docker volumes", comment: "Tool cleanup row title")
        case .goModuleCache: String(localized: "Go module cache", comment: "Tool cleanup row title")
        }
    }

    var badge: String {
        switch self {
        case .unavailableSimulators: "sim"
        case .simulatorRuntimes: "rt"
        case .localSnapshots: "tm"
        case .dockerImages: "img"
        case .dockerBuildCache: "bk"
        case .dockerVolumes: "vol"
        case .goModuleCache: "go"
        }
    }

    /// Singular noun for the count column ("3 images").
    var noun: String {
        switch self {
        case .unavailableSimulators: "device"
        case .simulatorRuntimes: "runtime"
        case .localSnapshots: "snapshot"
        case .dockerImages: "image"
        case .dockerBuildCache: "record"
        case .dockerVolumes: "volume"
        case .goModuleCache: "module"
        }
    }

    var isDocker: Bool { [.dockerImages, .dockerBuildCache, .dockerVolumes].contains(self) }

    /// Deleting everything at once is never what's wanted (every simulator runtime, including the one in use):
    /// only items picked under the twisty can be deleted.
    var requiresSelection: Bool { self == .simulatorRuntimes }

    var explanation: String {
        switch self {
        case .unavailableSimulators: String(localized: "Simulators whose iOS runtime is no longer installed. Xcode can't boot them.")
        case .simulatorRuntimes: String(localized: "iOS, watchOS, tvOS and visionOS simulator images. Pick old ones to delete; Xcode › Settings › Components downloads them again.")
        case .localSnapshots: String(localized: "APFS snapshots macOS keeps between Time Machine backups. macOS frees them on its own when space runs low.")
        case .dockerImages: String(localized: "Images no container uses, including dangling layers. `docker pull` or a rebuild brings them back.")
        case .dockerBuildCache: String(localized: "BuildKit layer cache. The next `docker build` is slower while it refills.")
        case .dockerVolumes: String(localized: "Volumes no container is attached to. They can hold database data, which is lost for good.")
        case .goModuleCache: String(localized: "Go modules downloaded for your builds. The next `go build` downloads what it needs again. Go makes these files read-only, so they're removed with `go clean -modcache` rather than deleted directly.")
        }
    }
}

struct ToolActionStatus: Sendable, Identifiable {
    /// One thing the action would remove: an image, a volume, a simulator, a snapshot.
    struct Item: Sendable, Identifiable, Hashable {
        let id: String
        let label: String
        var detail: String? = nil
        var size: Int64? = nil
        var date: Date? = nil
        /// Removes just this item. Nil when it can't be removed on its own.
        var command: [String]? = nil
    }

    var id: String { action.rawValue }
    let action: ToolAction
    let count: Int
    let size: Int64?
    let items: [Item]
    /// The exact commands that will run, shown before confirming.
    let commands: [[String]]
    let note: String?

    /// Items listed under the row's twisty, each with its own checkbox.
    var hasSelectableItems: Bool { items.contains { $0.command != nil } }

    /// The same action narrowed to `ids`: only their commands run. Picking every item keeps the
    /// original commands (a prune also catches dangling layers no list shows).
    func selecting(_ ids: Set<String>) -> ToolActionStatus {
        let picked = items.filter { ids.contains($0.id) && $0.command != nil }
        if !action.requiresSelection, !commands.isEmpty, picked.count == items.count { return self }
        let sizes = picked.compactMap(\.size)
        return ToolActionStatus(action: action, count: picked.count, size: sizes.count == picked.count ? sizes.reduce(0, +) : nil,
                                items: picked, commands: picked.compactMap(\.command), note: note)
    }
}

/// Inspects and runs tool-backed cleanups through `ProcessRunner` (never with sudo).
struct ToolActionService: Sendable {
    let runner: ProcessRunner
    let home: URL

    /// What `action` would remove, with every command already pointing at the absolute path that will run,
    /// so the confirmation shows exactly that. Commands whose tool can't be found in a trusted place are dropped.
    func status(_ action: ToolAction) async -> ToolActionStatus? {
        guard let s = await rawStatus(action) else { return nil }
        var commands: [[String]] = []
        for c in s.commands { if let r = await runner.resolved(c) { commands.append(r) } }
        var items: [ToolActionStatus.Item] = []
        for var item in s.items {
            if let c = item.command { item.command = await runner.resolved(c) }
            items.append(item)
        }
        return ToolActionStatus(action: s.action, count: s.count, size: s.size, items: items, commands: commands, note: s.note)
    }

    private func rawStatus(_ action: ToolAction) async -> ToolActionStatus? {
        switch action {
        case .unavailableSimulators:
            guard await runner.which("xcrun") != nil,
                  let r = try? await runner.run(["xcrun", "simctl", "list", "devices", "unavailable", "-j"], timeout: 30),
                  r.succeeded else { return nil }
            let devices = Self.parseUnavailableSimulators(r.stdout)
            guard !devices.isEmpty else { return ToolActionStatus(action: action, count: 0, size: 0, items: [], commands: [], note: nil) }
            let root = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
            let items = devices.map { d in
                let folder = root.appendingPathComponent(d.udid)
                let m = FileWalker.measure(folder)
                return ToolActionStatus.Item(id: d.udid, label: d.name, detail: d.runtime, size: m.size, date: m.newestModification,
                                             command: ["xcrun", "simctl", "delete", d.udid])
            }
            return ToolActionStatus(action: action, count: devices.count, size: items.reduce(0) { $0 + ($1.size ?? 0) },
                                    items: items, commands: [["xcrun", "simctl", "delete", "unavailable"]], note: nil)
        case .simulatorRuntimes:
            guard await runner.which("xcrun") != nil,
                  let r = try? await runner.run(["xcrun", "simctl", "runtime", "list", "-j"], timeout: 30),
                  r.succeeded else { return nil }
            let runtimes = Self.parseSimulatorRuntimes(r.stdout)
            let items = runtimes.map { rt in
                ToolActionStatus.Item(id: rt.identifier, label: "\(rt.platform) \(rt.version)",
                                      detail: rt.deletable ? rt.build : String(localized: "\(rt.build) · managed by macOS", comment: "Simulator runtime detail: build number, and macOS manages (and protects) it"),
                                      size: rt.size, date: rt.lastUsed,
                                      command: rt.deletable ? ["xcrun", "simctl", "runtime", "delete", rt.identifier] : nil)
            }
            return ToolActionStatus(action: action, count: runtimes.count, size: runtimes.reduce(0) { $0 + $1.size },
                                    items: items, commands: [],
                                    note: String(localized: "Simulators that use a deleted runtime stop booting until it's downloaded again."))
        case .localSnapshots:
            guard let r = try? await runner.run(["tmutil", "listlocalsnapshots", "/"], timeout: 30), r.succeeded else { return nil }
            let dates = Self.parseSnapshotDates(r.stdout)
            return ToolActionStatus(action: action, count: dates.count, size: nil,
                                    items: dates.map { .init(id: $0, label: $0, command: ["tmutil", "deletelocalsnapshots", $0]) },
                                    commands: dates.map { ["tmutil", "deletelocalsnapshots", $0] },
                                    note: String(localized: "macOS may require administrator rights for this. Yokoi never uses sudo; if it fails, run `sudo tmutil deletelocalsnapshots /` yourself."))
        case .dockerImages, .dockerBuildCache, .dockerVolumes:
            return await dockerStatus(action)
        case .goModuleCache:
            guard await runner.which("go") != nil,
                  let r = try? await runner.run(["go", "env", "GOMODCACHE"], timeout: 30), r.succeeded else { return nil }
            let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/") else { return nil }
            let cache = URL(fileURLWithPath: path)
            let count = Self.countGoModules(in: cache)
            guard count > 0 else { return ToolActionStatus(action: action, count: 0, size: 0, items: [], commands: [], note: nil) }
            return ToolActionStatus(action: action, count: count, size: FileWalker.measure(cache, reclaimable: true).size, items: [],
                                    commands: [["go", "clean", "-modcache"]],
                                    note: String(localized: "Cached at \(PathFormat.abbreviate(cache)).", comment: "Where the Go module cache is; the placeholder is a folder path"))
        }
    }

    /// Docker is asked through its own CLI. Nil when Docker isn't installed or its engine isn't running.
    private func dockerStatus(_ action: ToolAction) async -> ToolActionStatus? {
        guard await runner.which("docker") != nil,
              let r = try? await runner.run(["docker", "system", "df", "--format", "{{json .}}"], timeout: 30),
              r.succeeded else { return nil }
        let usage = Self.parseDockerDF(r.stdout)
        switch action {
        case .dockerImages:
            guard let u = usage["Images"] else { return nil }
            let count = max(0, u.total - u.active)
            let items = count > 0 ? await unusedDockerImages() : []
            return ToolActionStatus(action: action, count: count, size: u.reclaimable, items: items,
                                    commands: count > 0 ? [["docker", "image", "prune", "--all", "--force"]] : [],
                                    note: items.isEmpty ? nil : String(localized: "Sizes include layers images share, so single items can add up to more than the total."))
        case .dockerBuildCache:
            guard let u = usage["Build Cache"] else { return nil }
            let count = u.reclaimable > 0 ? max(u.total - u.active, 1) : 0
            return ToolActionStatus(action: action, count: count, size: u.reclaimable, items: [],
                                    commands: count > 0 ? [["docker", "builder", "prune", "--all", "--force"]] : [], note: nil)
        case .dockerVolumes:
            guard let ls = try? await runner.run(["docker", "volume", "ls", "--quiet", "--filter", "dangling=true"], timeout: 30),
                  ls.succeeded else { return nil }
            let names = ls.stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            // Named volumes are listed one by one, so exactly these and nothing created since are removed.
            return ToolActionStatus(action: action, count: names.count, size: names.isEmpty ? 0 : usage["Local Volumes"]?.reclaimable,
                                    items: names.map { .init(id: $0, label: $0, command: ["docker", "volume", "rm", $0]) }, commands: names.isEmpty ? [] : [["docker", "volume", "rm"] + names],
                                    note: String(localized: "Volume data can't be put back. Check the list for databases you still need."))
        default:
            return nil
        }
    }

    /// Images no container (running or stopped) was created from, one item per image.
    private func unusedDockerImages() async -> [ToolActionStatus.Item] {
        guard let ls = try? await runner.run(["docker", "image", "ls", "--no-trunc", "--format", "{{json .}}"], timeout: 30),
              ls.succeeded else { return [] }
        var used = Set<String>()
        if let ps = try? await runner.run(["docker", "container", "ls", "--all", "--quiet", "--no-trunc"], timeout: 30), ps.succeeded {
            let ids = ps.stdout.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
            if !ids.isEmpty,
               let inspect = try? await runner.run(["docker", "container", "inspect", "--format", "{{.Image}}"] + ids, timeout: 30) {
                // A failed inspect (a container removed meanwhile) means "used" is unknown: offer nothing one by one.
                guard inspect.succeeded else { return [] }
                used = Set(inspect.stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
            }
        }
        return Self.parseDockerImages(ls.stdout).filter { !used.contains($0.id) }.map { image in
            // Removing every tag deletes the image; an untagged image is removed by id.
            let refs = image.tags.isEmpty ? [image.id] : image.tags
            return ToolActionStatus.Item(id: image.id, label: image.tags.first ?? "<none>",
                                         detail: image.tags.count > 1 ? String(localized: "+\(image.tags.count - 1) tags", comment: "Docker image with more tags than the one shown") : String(image.id.replacingOccurrences(of: "sha256:", with: "").prefix(12)),
                                         size: image.size, date: image.created, command: ["docker", "image", "rm"] + refs)
        }
    }

    func run(_ status: ToolActionStatus) async -> [ProcessRunner.Result] {
        var results: [ProcessRunner.Result] = []
        for command in status.commands {
            if Task.isCancelled { break }
            if let r = try? await runner.run(command, timeout: 300) { results.append(r) }
        }
        return results
    }

    /// Module versions in a Go module cache: folders named `name@version`, outside `cache/` (the download cache).
    static func countGoModules(in root: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [],
                                                     errorHandler: { _, _ in true }) else { return 0 }
        var count = 0
        while let url = e.nextObject() as? URL {
            if e.level == 1 && url.lastPathComponent == "cache" { e.skipDescendants(); continue }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if url.lastPathComponent.contains("@") { count += 1; e.skipDescendants() }
        }
        return count
    }

    struct Simulator: Sendable, Equatable {
        let udid: String
        let name: String
        let runtime: String
    }

    /// Parses `xcrun simctl list devices unavailable -j`.
    static func parseUnavailableSimulators(_ json: String) -> [Simulator] {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let devices = root["devices"] as? [String: [[String: Any]]] else { return [] }
        return devices.flatMap { runtime, list in
            list.compactMap { d -> Simulator? in
                guard let udid = d["udid"] as? String, (d["isAvailable"] as? Bool) == false else { return nil }
                let short = runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
                return Simulator(udid: udid, name: d["name"] as? String ?? udid, runtime: short)
            }
        }
        .sorted { $0.name < $1.name }
    }

    struct SimulatorRuntime: Sendable, Equatable {
        let identifier: String
        let platform: String
        let version: String
        let build: String
        let size: Int64
        let lastUsed: Date?
        let deletable: Bool
    }

    /// Parses `xcrun simctl runtime list -j`, newest version first within each platform.
    static func parseSimulatorRuntimes(_ json: String) -> [SimulatorRuntime] {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] else { return [] }
        let platforms = ["iphonesimulator": "iOS", "watchsimulator": "watchOS", "appletvsimulator": "tvOS", "xrsimulator": "visionOS"]
        let iso = ISO8601DateFormatter()
        return root.compactMap { key, r -> SimulatorRuntime? in
            guard let version = r["version"] as? String else { return nil }
            let platformID = (r["platformIdentifier"] as? String ?? "").replacingOccurrences(of: "com.apple.platform.", with: "")
            return SimulatorRuntime(identifier: r["identifier"] as? String ?? key,
                                    platform: platforms[platformID] ?? platformID, version: version,
                                    build: r["build"] as? String ?? "",
                                    size: (r["sizeBytes"] as? NSNumber)?.int64Value ?? 0,
                                    lastUsed: (r["lastUsedAt"] as? String).flatMap { iso.date(from: $0) },
                                    deletable: r["deletable"] as? Bool ?? false)
        }
        .sorted { a, b in
            a.platform != b.platform ? a.platform < b.platform
                : a.version.compare(b.version, options: .numeric) == .orderedDescending
        }
    }

    struct DockerImage: Sendable, Equatable {
        let id: String
        /// `repo:tag` names; empty for an untagged (dangling) image.
        let tags: [String]
        let size: Int64?
        let created: Date?
    }

    /// Parses `docker image ls --no-trunc --format '{{json .}}'`, one item per image id, newest first.
    static func parseDockerImages(_ output: String) -> [DockerImage] {
        let dateFormat = DateFormatter()
        dateFormat.locale = Locale(identifier: "en_US_POSIX")
        dateFormat.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        var byID: [String: DockerImage] = [:]
        var order: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = obj["ID"] as? String, !id.isEmpty else { continue }
            let repo = obj["Repository"] as? String ?? "<none>", tag = obj["Tag"] as? String ?? "<none>"
            // A repository without a tag (pulled by digest) isn't a usable name: `docker image rm foo` means
            // `foo:latest`, a different image. Such images are removed by id instead.
            let ref = repo == "<none>" || tag == "<none>" ? nil : "\(repo):\(tag)"
            // "2024-05-01 10:20:30 +0200 CEST": the trailing zone name isn't parseable, the offset is enough.
            let created = (obj["CreatedAt"] as? String).flatMap { s in
                dateFormat.date(from: s.split(separator: " ").prefix(3).joined(separator: " "))
            }
            if var existing = byID[id] {
                if let ref, !existing.tags.contains(ref) { existing = DockerImage(id: id, tags: existing.tags + [ref], size: existing.size, created: existing.created) }
                byID[id] = existing
            } else {
                order.append(id)
                byID[id] = DockerImage(id: id, tags: ref.map { [$0] } ?? [], size: parseDockerSize(obj["Size"] as? String ?? ""), created: created)
            }
        }
        return order.compactMap { byID[$0] }.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
    }

    struct DockerUsage: Sendable, Equatable {
        let total: Int
        let active: Int
        let size: Int64
        let reclaimable: Int64
    }

    /// Parses `docker system df --format '{{json .}}'` (one JSON object per line), keyed by Type.
    static func parseDockerDF(_ output: String) -> [String: DockerUsage] {
        var out: [String: DockerUsage] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = obj["Type"] as? String else { continue }
            func int(_ k: String) -> Int { (obj[k] as? Int) ?? Int((obj[k] as? String) ?? "") ?? 0 }
            func bytes(_ k: String) -> Int64 { parseDockerSize((obj[k] as? String) ?? "") ?? 0 }
            out[type] = DockerUsage(total: int("TotalCount"), active: int("Active"), size: bytes("Size"), reclaimable: bytes("Reclaimable"))
        }
        return out
    }

    /// Docker's human sizes (`1.21GB (54%)`, `512.3MB`, `0B`, `12kB`) are decimal (1000-based).
    static func parseDockerSize(_ text: String) -> Int64? {
        let s = text.split(separator: " ").first.map(String.init) ?? ""
        guard let split = s.firstIndex(where: { $0.isLetter }), let value = Double(s[..<split]) else { return nil }
        let units: [String: Double] = ["B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12, "PB": 1e15]
        guard let mult = units[s[split...].uppercased()] else { return nil }
        return Int64((value * mult).rounded())
    }

    /// Parses `tmutil listlocalsnapshots /` → snapshot dates like `2026-10-30-101010`.
    static func parseSnapshotDates(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("com.apple.TimeMachine.") else { return nil }
            return s.replacingOccurrences(of: "com.apple.TimeMachine.", with: "")
                .replacingOccurrences(of: ".local", with: "")
        }
    }
}
