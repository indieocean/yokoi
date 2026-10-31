import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class ApplicationsViewModel: SelectionPruning {
    enum Filter: Hashable { case all, unused, appStore }

    struct Row: Identifiable, Hashable {
        let item: AppItem
        let running: Bool
        var id: String { item.id }
        var name: String { item.name }
        var lastUsed: Date { item.lastUsed ?? .distantPast }
        var size: Int64 { item.size }
        var leftoverSize: Int64 { item.leftoverSize }
    }

    static let unusedDays = 180

    var filter: Filter = .all
    var sortOrder: [KeyPathComparator<Row>] = [KeyPathComparator(\Row.size, order: .reverse)]
    var checked: Set<String> = []
    var expanded: String?
    private(set) var runningBundleIDs: Set<String> = []

    let store: ScanStore
    init(store: ScanStore) { self.store = store }

    func refreshRunning() {
        runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    func isRunning(_ item: AppItem) -> Bool { runningBundleIDs.contains(item.bundleID) }

    func rows(search: String) -> [Row] {
        store.applications
            .filter {
                switch filter {
                case .all: true
                case .unused: $0.isUnused(days: Self.unusedDays)
                case .appStore: $0.isAppStore
                }
            }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search) }
            .map { Row(item: $0, running: isRunning($0)) }
            .sorted(using: sortOrder)
    }

    var counts: (all: Int, unused: Int, appStore: Int) {
        let apps = store.applications
        return (apps.count, apps.filter { $0.isUnused(days: Self.unusedDays) }.count, apps.filter(\.isAppStore).count)
    }

    var maxSize: Int64 { store.applications.map(\.size).max() ?? 1 }

    func canSelect(_ item: AppItem) -> Bool { item.protectedReason == nil && !isRunning(item) }

    func toggle(_ item: AppItem) {
        guard canSelect(item) else { return }
        if checked.contains(item.id) { checked.remove(item.id) } else { checked.insert(item.id) }
    }

    func checkState(for rows: [Row]) -> CheckState {
        let ids = Set(rows.filter { canSelect($0.item) }.map(\.id))
        let n = ids.intersection(checked).count
        return n == 0 ? .off : (n == ids.count ? .on : .mixed)
    }

    func toggleAll(_ rows: [Row]) {
        let ids = Set(rows.filter { canSelect($0.item) }.map(\.id))
        if ids.isSubset(of: checked) { checked.subtract(ids) } else { checked.formUnion(ids) }
    }

    var selectedItems: [AppItem] { store.applications.filter { checked.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    func cleanupRequest() -> CleanupRequest {
        let items = selectedItems.sorted { $0.size > $1.size }
        let leftovers = items.reduce(0) { $0 + $1.leftovers.count }
        return CleanupRequest(
            title: "Uninstall \(CountFormat.plural(items.count, "app"))?",
            restoreHint: "Moves each app and its \(CountFormat.plural(leftovers, "support file")) in ~/Library to the Trash. Put Back restores everything.",
            entries: items.map { CleanupEntry($0, displayPath: PathFormat.abbreviate($0.url)) }
        )
    }

    func prune(_ ids: Set<String>) { checked.subtract(ids) }
}
