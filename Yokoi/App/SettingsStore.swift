import Foundation
import Observation

/// Observable wrapper around `SettingsData`, persisted to `UserDefaults` on every change.
@MainActor
@Observable
final class SettingsStore {
    var data: SettingsData {
        didSet { if data != oldValue { save() } }
    }

    private let defaults: UserDefaults
    private static let key = "settings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        data = Self.load(defaults.data(forKey: Self.key))
    }

    /// Saved values laid over the defaults, so settings added in a newer version never reset old ones.
    nonisolated static func load(_ raw: Data?) -> SettingsData {
        let base = SettingsData.defaults()
        guard let raw,
              let stored = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let baseData = try? JSONEncoder().encode(base),
              let baseDict = (try? JSONSerialization.jsonObject(with: baseData)) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: baseDict.merging(stored) { _, new in new }),
              let decoded = try? JSONDecoder().decode(SettingsData.self, from: merged) else { return base }
        return decoded
    }

    private func save() {
        if let raw = try? JSONEncoder().encode(data) {
            defaults.set(raw, forKey: Self.key)
        }
    }

    /// Mounted external drives. Refreshed on mount/unmount, never during a view update.
    var externalDrives: [ExternalDrive] = []

    /// Set in demo mode instead of reading real volumes.
    var demoDrives: [ExternalDrive]?

    func refreshDrives() {
        let drives = demoDrives ?? ExternalDrives.mounted()
        if drives != externalDrives { externalDrives = drives }
    }

    func context() -> ScanContext {
        var ctx = data.makeContext()
        ctx.externalVolumes = externalDrives.filter(\.canClean).map(\.url)
        return ctx
    }

    // MARK: Editing helpers

    func addScanRoot(_ url: URL) {
        let path = PathFormat.abbreviate(url)
        guard !data.scanRoots.contains(where: { $0.path == path }) else { return }
        data.scanRoots.append(ScanRoot(path: path))
    }

    func removeScanRoot(_ root: ScanRoot) {
        data.scanRoots.removeAll { $0 == root }
    }

    func setDepth(_ depth: Int?, for root: ScanRoot) {
        guard let i = data.scanRoots.firstIndex(of: root) else { return }
        data.scanRoots[i].maxDepth = depth
    }

    func addBigFileRoot(_ url: URL) {
        let path = PathFormat.abbreviate(url)
        guard !data.bigFileRoots.contains(path) else { return }
        data.bigFileRoots.append(path)
    }

    func addExclusion(_ pattern: String) {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, !data.exclusions.contains(p) else { return }
        data.exclusions.append(p)
    }

    func removeExclusion(_ pattern: String) {
        data.exclusions.removeAll { $0 == pattern }
    }
}

extension SettingsStore {
    /// The saved settings, readable outside the main actor (CLI, Shortcuts).
    nonisolated static func loadStandard() -> SettingsData {
        let raw = UserDefaults.standard.data(forKey: "settings.v1")
        return load(raw)
    }
}
