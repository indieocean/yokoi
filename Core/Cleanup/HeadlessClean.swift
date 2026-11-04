import Foundation

/// `yokoi clean`: the same selection and refusals as the app, with no window. Selects with `CleanSelection`,
/// holds back what's in use, then hands the rest to `CleanupService`, which applies `PathGuard` to every path.
enum HeadlessClean {
    /// What the command can clean. Everything else holds the user's own files, which need picking by hand.
    static let categories: Set<CleanCategory> = [.nodeModules, .buildArtifacts, .caches]

    struct Plan: Sendable {
        var entries: [CleanupEntry]
        var blocked: [InUseSnapshot.Blocked]
    }

    static func plan(settings: SettingsData, categories: Set<CleanCategory> = categories,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser, index: URL? = nil,
                     now: Date = Date(), inUse: InUseSnapshot? = nil) async -> Plan {
        let start = Date()
        let found = await ScanReport.results(settings: settings, categories: categories, home: home, index: index)
        let entries = CleanSelection.unattended(.smartSelect, nodeModules: found.nodeModules, artifacts: found.artifacts,
                                                caches: found.caches, settings: settings, now: now)
            .filter { categories.contains($0.category) }
            .map { entry in
                var e = entry
                e.scannedAt = start
                return e
            }
        let split = if let inUse { inUse.split(entries) } else { await InUseSnapshot.split(entries) }
        return Plan(entries: split.allowed, blocked: split.blocked)
    }

    /// Cleans `plan`. The Dry run setting holds here too, as it does in the app.
    static func execute(_ plan: Plan, action: CleanupAction, settings: SettingsData,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser, log: CleanupLog = CleanupLog()) async -> CleanupOutcome {
        let service = CleanupService(context: settings.makeContext(home: home), log: log)
        return await service.perform(plan.entries, action: action, dryRun: settings.dryRun)
    }
}

/// What `yokoi clean` prints with `--json`.
struct CleanReport: Codable, Sendable {
    struct Item: Codable, Sendable {
        let label: String
        let path: String
        let sizeBytes: Int64
    }

    struct Blocked: Codable, Sendable {
        let path: String
        let process: String
    }

    struct Failure: Codable, Sendable {
        let path: String
        let reason: String
    }

    /// `trash` or `delete`.
    let action: String
    /// False for a preview: nothing was touched.
    let applied: Bool
    /// True when the Dry run setting kept a real run from changing anything.
    let dryRun: Bool
    let items: [Item]
    let blocked: [Blocked]
    let failed: [Failure]
    /// For the user to run themselves, for what only an administrator can remove. Never run by Yokoi.
    let adminCommand: String?
    let bytes: Int64

    init(plan: HeadlessClean.Plan, action: CleanupAction, outcome: CleanupOutcome?) {
        self.action = action.logName
        applied = outcome != nil
        dryRun = outcome?.dryRun ?? false
        let done = plan.entries.filter { outcome?.completedIDs.contains($0.id) ?? true }
        items = done.sorted { $0.size > $1.size }.map { Item(label: $0.label, path: $0.displayPath, sizeBytes: $0.size) }
        blocked = plan.blocked.map { Blocked(path: $0.entry.displayPath, process: $0.process) }
        failed = (outcome?.failures ?? []).map { Failure(path: $0.path, reason: $0.reason) }
        adminCommand = outcome?.adminCommand
        bytes = outcome?.bytes ?? done.reduce(0) { $0 + $1.size }
    }

    func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    func text() -> String {
        let permanent = action == "delete"
        var lines: [String] = []
        for item in items { lines.append("\(ByteFormat.string(item.sizeBytes).leftPadded(10))  \(PathFormat.printable(item.path))") }
        if !items.isEmpty { lines.append("") }
        for b in blocked { lines.append(PathFormat.printable("In use by \(b.process): \(b.path)")) }
        for f in failed { lines.append(PathFormat.printable("Failed: \(f.path): \(f.reason)")) }
        if !blocked.isEmpty || !failed.isEmpty { lines.append("") }
        if let adminCommand {
            lines.append("Only an administrator can remove some of these, and Yokoi never uses sudo.")
            lines.append("Check the paths, then run this yourself. It deletes permanently:")
            lines.append("  \(adminCommand)")
            lines.append("")
        }
        let total = ByteFormat.string(bytes), count = CountFormat.plural(items.count, "item")
        if !applied {
            lines.append(items.isEmpty ? "Nothing to clean." : "Would \(permanent ? "permanently delete" : "move to the Trash") \(count), \(total).")
            if !items.isEmpty {
                lines.append("Nothing was changed. Run again with --yes to clean\(permanent ? "; this can't be undone." : ".")")
            }
        } else if dryRun {
            lines.append("Dry run is on in Settings: \(count), \(total). Nothing was changed.")
        } else {
            lines.append(permanent ? "Permanently deleted \(count), \(total)." : "Moved \(count) to the Trash, \(total). Space comes back when the Trash is emptied.")
        }
        return lines.joined(separator: "\n")
    }
}

private extension String {
    func leftPadded(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}
