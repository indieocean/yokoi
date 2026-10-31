import Foundation
import Observation

@MainActor
@Observable
final class CachesViewModel: SelectionPruning {
    struct Section: Identifiable {
        let section: CacheLocation.Section
        let items: [CacheItem]
        var id: String { section.rawValue }
    }

    var checked: Set<String> = []
    private var defaultsApplied: Set<String> = []

    let store: ScanStore
    init(store: ScanStore) { self.store = store }

    func applyDefaults() {
        for item in store.caches where !defaultsApplied.contains(item.id) {
            defaultsApplied.insert(item.id)
            if item.safety.selectedByDefault && item.size > 0 { checked.insert(item.id) }
        }
    }

    func sections(search: String) -> [Section] {
        let order = Dictionary(uniqueKeysWithValues: CacheLocation.all.enumerated().map { ($1.id, $0) })
        let items = store.caches
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.url.path.localizedCaseInsensitiveContains(search) }
            .sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        return CacheLocation.Section.allCases.compactMap { s in
            let inSection = items.filter { $0.section == s }
            return inSection.isEmpty ? nil : Section(section: s, items: inSection)
        }
    }

    func selectSafeOnly() {
        checked = Set(store.caches.filter { $0.safety == .safe && $0.size > 0 }.map(\.id))
    }

    /// The Trash isn't part of the checkbox selection; it has its own "Empty…" action.
    private var selectable: [CacheItem] { store.caches.filter { !$0.permanentOnly } }

    func toggle(_ id: String) {
        guard selectable.contains(where: { $0.id == id }) else { return }
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
    }

    var allState: CheckState {
        let ids = Set(selectable.map(\.id))
        let n = ids.intersection(checked).count
        return n == 0 ? .off : (n == ids.count ? .on : .mixed)
    }

    func toggleAll() {
        let ids = Set(selectable.map(\.id))
        if ids.isSubset(of: checked) { checked.subtract(ids) } else { checked.formUnion(ids) }
    }

    var selectedItems: [CacheItem] { selectable.filter { checked.contains($0.id) } }

    var trash: CacheItem? { store.caches.first { $0.permanentOnly } }

    func emptyTrashRequest() -> CleanupRequest? {
        guard let trash, !trash.contents.isEmpty else { return nil }
        return CleanupRequest(
            title: "Empty the Trash?",
            restoreHint: "Permanently deletes \(CountFormat.plural(trash.contents.count, "item")) in the Trash. This can't be undone.",
            entries: [CleanupEntry(trash, displayPath: "~/.Trash/*")],
            forcePermanent: true, confirmVerb: "Empty Trash")
    }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    func cleanupRequest() -> CleanupRequest {
        let items = selectedItems.sorted { $0.size > $1.size }
        let review = items.filter { $0.safety == .review }
        let hint = review.isEmpty
            ? "Tools refill these caches as needed. Re-download items are fetched again over the network."
            : "Includes Review items: \(review.map(\.name).joined(separator: ", ")). \(review.first!.restoreHint.prefix(1).uppercased() + review.first!.restoreHint.dropFirst())."
        return CleanupRequest(
            title: "Clear \(items.count) cache\(items.count == 1 ? "" : "s")?",
            restoreHint: hint,
            entries: items.map { CleanupEntry($0, displayPath: PathFormat.abbreviate($0.url) + "/*") }
        )
    }

    func prune(_ ids: Set<String>) { checked.subtract(ids) }
}
