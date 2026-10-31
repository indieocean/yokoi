import Foundation
import Observation

/// Tool-backed cleanups shown on the Caches screen (unavailable simulators, local snapshots).
@MainActor
@Observable
final class ToolActionsModel {
    var statuses: [ToolAction: ToolActionStatus] = [:]
    var loading = false
    var loaded = false
    var pending: ToolActionStatus?
    var running = false
    var results: [ProcessRunner.Result] = []

    let store: ScanStore
    private var service: ToolActionService {
        ToolActionService(runner: .shared, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    init(store: ScanStore) { self.store = store }

    func refresh() async {
        loading = true
        defer { loading = false; loaded = true }
        var next: [ToolAction: ToolActionStatus] = [:]
        for action in ToolAction.allCases {
            if let s = await service.status(action) { next[action] = s }
        }
        statuses = next
    }

    func run(_ status: ToolActionStatus) async {
        running = true
        results = await service.run(status)
        for r in results {
            await store.logCommand(r, category: .caches, label: status.action.title,
                                   size: (status.size ?? 0) / Int64(max(status.commands.count, 1)))
        }
        running = false
        await refresh()
    }
}
