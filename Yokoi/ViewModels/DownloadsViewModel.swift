import Foundation
import Observation

@MainActor
@Observable
final class DownloadsViewModel: SelectionPruning {
    enum KindFilter: Hashable {
        case all, old
        case kind(DownloadKind)
    }

    struct Row: Identifiable, Hashable {
        let item: DownloadItem
        let isOld: Bool
        var id: String { item.id }
        var name: String { item.name }
        var kind: String { item.kind.filterTitle }
        var added: Date { item.added ?? .distantPast }
        var lastOpened: Date { item.lastOpened ?? .distantPast }
        var size: Int64 { item.size }
    }

    var filter: KindFilter = .all
    var sortOrder: [KeyPathComparator<Row>] = [KeyPathComparator(\Row.size, order: .reverse)]
    var checked: Set<String> = []
    var previewURL: URL?

    let store: ScanStore
    init(store: ScanStore) { self.store = store }

    static let ageOptions = [7, 14, 30, 60, 90, 180, 365]

    var ageDays: Int {
        get { store.settings.data.downloadsAgeDays }
        set { store.settings.data.downloadsAgeDays = newValue }
    }

    var folder: URL { store.settings.context().downloadsURL }

    func rows(search: String) -> [Row] {
        let days = ageDays
        return store.downloads
            .map { Row(item: $0, isOld: $0.isOld(days: days)) }
            .filter {
                switch filter {
                case .all: true
                case .old: $0.isOld
                case .kind(let k): $0.item.kind == k || (k == .installer && $0.item.kind == .incomplete)
                }
            }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
    }

    var totals: (count: Int, size: Int64, oldCount: Int, oldSize: Int64) {
        let old = store.downloads.filter { $0.isOld(days: ageDays) }
        return (store.downloads.count, store.downloads.reduce(0) { $0 + $1.size }, old.count, old.reduce(0) { $0 + $1.size })
    }

    /// Leftovers worth clearing first: incomplete downloads, extracted archives and installers, any age.
    var leftovers: [DownloadItem] { store.downloads.filter { $0.safety != .review } }

    func selectOld() { checked.formUnion(store.downloads.filter { $0.isOld(days: ageDays) }.map(\.id)) }
    func selectLeftovers() { checked.formUnion(leftovers.map(\.id)) }

    func toggle(_ id: String) {
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
    }

    func checkState(for rows: [Row]) -> CheckState {
        let ids = Set(rows.map(\.id))
        let n = ids.intersection(checked).count
        return n == 0 ? .off : (n == ids.count && !ids.isEmpty ? .on : .mixed)
    }

    func toggleAll(_ rows: [Row]) {
        let ids = Set(rows.map(\.id))
        if ids.isSubset(of: checked) { checked.subtract(ids) } else { checked.formUnion(ids) }
    }

    var selectedItems: [DownloadItem] { store.downloads.filter { checked.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    func cleanupRequest() -> CleanupRequest {
        let items = selectedItems.sorted { $0.size > $1.size }
        return CleanupRequest(
            title: "Move \(CountFormat.plural(items.count, "download")) to the Trash?",
            restoreHint: "Files you downloaded. They stay in the Trash until you empty it, and Put Back restores them.",
            entries: items.map { CleanupEntry($0) }
        )
    }

    func prune(_ ids: Set<String>) { checked.subtract(ids) }
}
