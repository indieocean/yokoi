import Foundation
import Observation

/// Tool-backed cleanups shown on the Caches screen (unavailable simulators, local snapshots).
@MainActor
@Observable
final class ToolActionsModel {
    var statuses: [ToolAction: ToolActionStatus] = [:]
    var loading = false
    var loaded = false
    var running = false
    var results: [ProcessRunner.Result] = []
    /// Items picked under each row's twisty. Empty means the whole row.
    var picked: [ToolAction: Set<String>] = [:]
    var expanded: Set<ToolAction> = []

    func togglePick(_ item: ToolActionStatus.Item, in action: ToolAction) {
        guard item.command != nil else { return }
        var ids = picked[action] ?? []
        if ids.contains(item.id) { ids.remove(item.id) } else { ids.insert(item.id) }
        picked[action] = ids.isEmpty ? nil : ids
    }

    func pickAll(_ status: ToolActionStatus) {
        let all = Set(status.items.filter { $0.command != nil }.map(\.id))
        picked[status.action] = (picked[status.action] ?? []) == all ? nil : all
    }

    /// What "Delete…" removes: the picked items, or the whole row when nothing is picked.
    func request(for status: ToolActionStatus) -> ToolActionStatus? {
        if let ids = picked[status.action], !ids.isEmpty { return status.selecting(ids) }
        return status.action.requiresSelection ? nil : status
    }

    /// The shared confirmation dialog's request for `status`: one line per item, permanent only.
    func cleanupRequest(for status: ToolActionStatus) -> CleanupRequest? {
        guard let status = request(for: status), !status.commands.isEmpty else { return nil }
        let title = status.action.title
        let entries: [CleanupEntry] = status.items.isEmpty
            ? [CleanupEntry(id: "tool:\(status.action.rawValue)", category: .caches, label: title,
                            displayPath: CountFormat.plural(status.count, status.action.noun), urls: [], size: status.size ?? 0,
                            fileCount: status.count, safety: .review)]
            : status.items.map { item in
                CleanupEntry(id: "tool:\(status.action.rawValue):\(item.id)", category: .caches, label: item.label,
                             displayPath: [item.label, item.detail].compactMap { $0 }.joined(separator: "  ·  "), urls: [],
                             size: item.size ?? 0, fileCount: 1, safety: .review)
            }
        let tool = status.commands.first?.first ?? "the tool"
        return CleanupRequest(title: "Delete \(CountFormat.plural(status.count, status.action.noun))?",
                              restoreHint: status.action.explanation + " Removed with `\(tool)`, so they can't go to the Trash.",
                              entries: entries, forcePermanent: true, tool: status)
    }

    let store: ScanStore
    private var service: ToolActionService {
        ToolActionService(runner: .shared, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    init(store: ScanStore) { self.store = store }

    func refresh() async {
        if store.isDemo {
            statuses = DemoData.toolStatuses
            loaded = true
            return
        }
        loading = true
        defer { loading = false; loaded = true }
        var next: [ToolAction: ToolActionStatus] = [:]
        for action in ToolAction.allCases {
            if let s = await service.status(action) { next[action] = s }
        }
        statuses = next
        // Forget picks that are gone (deleted, or removed outside Yokoi).
        for (action, ids) in picked {
            let still = ids.intersection(next[action]?.items.map(\.id) ?? [])
            picked[action] = still.isEmpty ? nil : still
        }
    }

    /// Runs a confirmed tool cleanup and reports the result as a toast.
    func confirm(_ status: ToolActionStatus, app: AppModel) async {
        let commands = CountFormat.plural(status.commands.count, "command")
        if store.isDemo || store.settings.data.dryRun {
            app.toast = Toast(kind: .info, message: "Dry run: would run \(commands)",
                              detail: status.commands.first.map { $0.joined(separator: " ") })
            return
        }
        await run(status)
        let failed = results.filter { !$0.succeeded }
        if failed.isEmpty {
            app.toast = Toast(kind: .success, message: "Deleted \(CountFormat.plural(status.count, status.action.noun))"
                                + (status.size.map { " · \(ByteFormat.string($0))" } ?? ""))
        } else {
            app.toast = Toast(kind: .warning, message: "\(failed.count) of \(commands) failed",
                              detail: failed.first?.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func run(_ status: ToolActionStatus) async {
        if store.isDemo { return }
        running = true
        results = await service.run(status)
        // One command per picked item: log each with its own name and size.
        let perItem = status.items.count == status.commands.count && status.items.map(\.command) == status.commands.map { Optional($0) }
        for (i, r) in results.enumerated() {
            let item = perItem && i < status.items.count ? status.items[i] : nil
            await store.logCommand(r, category: .caches,
                                   label: item.map { "\(status.action.title) · \($0.label)" } ?? status.action.title,
                                   size: item?.size ?? (status.size ?? 0) / Int64(max(status.commands.count, 1)))
        }
        picked[status.action] = nil
        running = false
        await refresh()
    }
}
