import Foundation
import Observation

@MainActor
@Observable
final class BigFilesViewModel: SelectionPruning {
    enum KindFilter: Hashable {
        case all
        case kind(BigFileKind)
    }

    struct Row: Identifiable, Hashable {
        let item: BigFileItem
        var id: String { item.id }
        var name: String { item.name }
        var location: String { item.location }
        var modified: Date { item.modified ?? .distantPast }
        var size: Int64 { item.size }
    }

    var kindFilter: KindFilter = .all
    var sortOrder: [KeyPathComparator<Row>] = [KeyPathComparator(\Row.size, order: .reverse)]
    var checked: Set<String> = []
    var previewURL: URL?

    let store: ScanStore
    init(store: ScanStore) { self.store = store }

    // MARK: Threshold slider (log scale, 100 MB … 10 GB)

    static let minThreshold: Double = 100_000_000
    static let maxThreshold: Double = 10_000_000_000

    var threshold: Int64 {
        get { store.settings.data.bigFileThreshold }
        set { store.settings.data.bigFileThreshold = newValue }
    }

    /// 0…1 slider position ↔ bytes on a log scale.
    var sliderPosition: Double {
        get { log(Double(threshold) / Self.minThreshold) / log(Self.maxThreshold / Self.minThreshold) }
        set {
            let raw = Self.minThreshold * pow(Self.maxThreshold / Self.minThreshold, min(max(newValue, 0), 1))
            threshold = Self.snap(raw)
        }
    }

    static func position(for bytes: Double) -> Double {
        log(bytes / minThreshold) / log(maxThreshold / minThreshold)
    }

    /// Snaps to friendly values: 100 MB steps below 1 GB, 0.5 GB steps above.
    static func snap(_ bytes: Double) -> Int64 {
        if bytes < 1_000_000_000 { return Int64((bytes / 100_000_000).rounded() * 100_000_000) }
        return Int64((bytes / 500_000_000).rounded() * 500_000_000)
    }

    func rows(search: String) -> [Row] {
        store.bigFiles
            .filter { $0.size >= threshold }
            .filter {
                switch kindFilter {
                case .all: true
                case .kind(let k): $0.kind == k
                }
            }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.location.localizedCaseInsensitiveContains(search) }
            .map(Row.init)
            .sorted(using: sortOrder)
    }

    var visibleTotal: (count: Int, size: Int64) {
        let items = store.bigFiles.filter { $0.size >= threshold }
        return (items.count, items.reduce(0) { $0 + $1.size })
    }

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

    var selectedItems: [BigFileItem] { store.bigFiles.filter { checked.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    func cleanupRequest() -> CleanupRequest {
        let items = selectedItems.sorted { $0.size > $1.size }
        return CleanupRequest(
            title: String(localized: "Remove \(items.count) big files?", comment: "Confirmation title"),
            restoreHint: String(localized: "These are your own files. Move to Trash keeps them recoverable until you empty it."),
            entries: items.map { CleanupEntry($0) }
        )
    }

    func prune(_ ids: Set<String>) { checked.subtract(ids) }
}
