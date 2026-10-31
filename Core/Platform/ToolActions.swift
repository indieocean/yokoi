import Foundation

/// Cleanups that must go through the owning tool rather than deleting files (PRD FR-C3).
enum ToolAction: String, CaseIterable, Sendable, Identifiable {
    case unavailableSimulators
    case localSnapshots

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unavailableSimulators: "Unavailable simulators"
        case .localSnapshots: "Local Time Machine snapshots"
        }
    }

    var badge: String {
        switch self {
        case .unavailableSimulators: "sim"
        case .localSnapshots: "tm"
        }
    }

    var explanation: String {
        switch self {
        case .unavailableSimulators: "Simulators whose iOS runtime is no longer installed. Xcode can't boot them."
        case .localSnapshots: "APFS snapshots macOS keeps between Time Machine backups. macOS frees them on its own when space runs low."
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
