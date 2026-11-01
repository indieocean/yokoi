import Foundation

/// Cleanups that must go through the owning tool rather than deleting files (PRD FR-C3).
enum ToolAction: String, CaseIterable, Sendable, Identifiable {
    case unavailableSimulators
    case localSnapshots
    case dockerImages
    case dockerBuildCache
    case dockerVolumes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unavailableSimulators: "Unavailable simulators"
        case .localSnapshots: "Local Time Machine snapshots"
        case .dockerImages: "Unused Docker images"
        case .dockerBuildCache: "Docker build cache"
        case .dockerVolumes: "Unused Docker volumes"
        }
    }

    var badge: String {
        switch self {
        case .unavailableSimulators: "sim"
        case .localSnapshots: "tm"
        case .dockerImages: "img"
        case .dockerBuildCache: "bk"
        case .dockerVolumes: "vol"
        }
    }

    /// Singular noun for the count column ("3 images").
    var noun: String {
        switch self {
        case .unavailableSimulators: "device"
        case .localSnapshots: "snapshot"
        case .dockerImages: "image"
        case .dockerBuildCache: "record"
        case .dockerVolumes: "volume"
        }
    }

    var isDocker: Bool { [.dockerImages, .dockerBuildCache, .dockerVolumes].contains(self) }

    var explanation: String {
        switch self {
        case .unavailableSimulators: "Simulators whose iOS runtime is no longer installed. Xcode can't boot them."
        case .localSnapshots: "APFS snapshots macOS keeps between Time Machine backups. macOS frees them on its own when space runs low."
        case .dockerImages: "Images no container uses, including dangling layers. `docker pull` or a rebuild brings them back."
        case .dockerBuildCache: "BuildKit layer cache. The next `docker build` is slower while it refills."
        case .dockerVolumes: "Volumes no container is attached to. They can hold database data, which is lost for good."
        }
    }
}

struct ToolActionStatus: Sendable, Identifiable {
    var id: String { action.rawValue }
    let action: ToolAction
    let count: Int
    let size: Int64?
    let items: [String]
    /// The exact commands that will run, shown before confirming.
    let commands: [[String]]
    let note: String?
}

/// Inspects and runs tool-backed cleanups through `ProcessRunner` (never with sudo).
struct ToolActionService: Sendable {
    let runner: ProcessRunner
    let home: URL

    func status(_ action: ToolAction) async -> ToolActionStatus? {
        switch action {
        case .unavailableSimulators:
            guard await runner.which("xcrun") != nil,
                  let r = try? await runner.run(["xcrun", "simctl", "list", "devices", "unavailable", "-j"], timeout: 30),
                  r.succeeded else { return nil }
            let devices = Self.parseUnavailableSimulators(r.stdout)
            guard !devices.isEmpty else { return ToolActionStatus(action: action, count: 0, size: 0, items: [], commands: [], note: nil) }
            let root = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
            let size = devices.reduce(Int64(0)) { $0 + FileWalker.measure(root.appendingPathComponent($1.udid)).size }
            return ToolActionStatus(action: action, count: devices.count, size: size,
                                    items: devices.map { "\($0.name) (\($0.runtime))" },
                                    commands: [["xcrun", "simctl", "delete", "unavailable"]], note: nil)
        case .localSnapshots:
            guard let r = try? await runner.run(["tmutil", "listlocalsnapshots", "/"], timeout: 30), r.succeeded else { return nil }
            let dates = Self.parseSnapshotDates(r.stdout)
            return ToolActionStatus(action: action, count: dates.count, size: nil, items: dates,
                                    commands: dates.map { ["tmutil", "deletelocalsnapshots", $0] },
                                    note: "macOS may require administrator rights for this. Yokoi never uses sudo; if it fails, run `sudo tmutil deletelocalsnapshots /` yourself.")
        case .dockerImages, .dockerBuildCache, .dockerVolumes:
            return await dockerStatus(action)
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
            return ToolActionStatus(action: action, count: count, size: u.reclaimable, items: [],
                                    commands: count > 0 ? [["docker", "image", "prune", "--all", "--force"]] : [], note: nil)
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
                                    items: names, commands: names.isEmpty ? [] : [["docker", "volume", "rm"] + names],
                                    note: "Volume data can't be put back. Check the list for databases you still need.")
        default:
            return nil
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
