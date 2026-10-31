import Foundation
import Observation

@MainActor
@Observable
final class NodeModulesViewModel: SelectionPruning {
    enum Filter: Hashable { case all, stale, active }

    struct Row: Identifiable, Hashable {
        let item: NodeModulesItem
        let isStale: Bool
        var id: String { item.id }
        var name: String { item.projectName }
        var path: String { PathFormat.abbreviate(item.url) }
        var lastTouched: Date { item.lastTouched ?? .distantPast }
        var size: Int64 { item.size }
        var statusRank: Int { isStale ? 1 : 0 }
    }

    var filter: Filter = .all
    var sortOrder: [KeyPathComparator<Row>] = [KeyPathComparator(\Row.size, order: .reverse)]
    var checked: Set<String> = []
    private var defaultsApplied: Set<String> = []

    let store: ScanStore
    init(store: ScanStore) { self.store = store }

    private var settings: SettingsData { store.settings.data }

    func allRows() -> [Row] {
        store.nodeModules.map { Row(item: $0, isStale: $0.isStale(days: settings.staleDays)) }
    }

    func rows(search: String) -> [Row] {
        allRows()
            .filter {
                switch filter {
                case .all: true
                case .stale: $0.isStale
                case .active: !$0.isStale
                }
            }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.path.localizedCaseInsensitiveContains(search) || $0.item.frameworkHint.localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
    }

    var counts: (all: Int, stale: Int, active: Int) {
        let rows = allRows()
        let stale = rows.filter(\.isStale).count
        return (rows.count, stale, rows.count - stale)
    }

    var packageManagers: [JSPackageManager] {
        let present = Set(store.nodeModules.compactMap(\.packageManager))
        return JSPackageManager.allCases.filter { present.contains($0) }
    }

    var maxSize: Int64 { store.nodeModules.map(\.size).max() ?? 1 }

    /// Stale folders of projects not touched recently start checked (mockup 02).
    func applyDefaults() {
        for item in store.nodeModules where !defaultsApplied.contains(item.id) {
            defaultsApplied.insert(item.id)
            let recent = CleanupEntry(item).isRecentlyActive(days: settings.protectRecentDays)
            if item.isStale(days: settings.staleDays) && !recent { checked.insert(item.id) }
        }
    }

    func toggle(_ id: String) {
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
    }

    func checkState(for rows: [Row]) -> CheckState {
        let ids = Set(rows.map(\.id))
        let n = ids.intersection(checked).count
        return n == 0 ? .off : (n == ids.count ? .on : .mixed)
    }

    func toggleAll(_ rows: [Row]) {
        let ids = Set(rows.map(\.id))
        if ids.isSubset(of: checked) { checked.subtract(ids) } else { checked.formUnion(ids) }
    }

    var selectedItems: [NodeModulesItem] { store.nodeModules.filter { checked.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    func cleanupRequest() -> CleanupRequest {
        let items = selectedItems.sorted { $0.size > $1.size }
        let managers = Set(items.map { $0.packageManager ?? .npm })
        let hint = managers.count == 1 ? managers.first!.installCommand : "your package manager's install command"
        return CleanupRequest(
            title: "Remove \(items.count) node_modules folder\(items.count == 1 ? "" : "s")?",
            restoreHint: "You can restore them anytime with `\(hint)`.",
            entries: items.map { CleanupEntry($0) }
        )
    }

    func prune(_ ids: Set<String>) { checked.subtract(ids) }
}
