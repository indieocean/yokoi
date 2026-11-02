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
        checkedChildren = [:]
    }

    /// The Trash isn't part of the checkbox selection; it has its own "Empty…" action.
    private var selectable: [CacheItem] { store.caches.filter { !$0.permanentOnly } }

    // MARK: Single items

    /// Locations with only some of their items selected, by location id. A location never sits in both
    /// this and `checked`: selecting its last item turns it into a whole-location selection.
    var checkedChildren: [String: Set<String>] = [:]
    /// Locations whose twisty is open.
    var expanded: Set<String> = []

    func toggleExpanded(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    func state(of item: CacheItem) -> CheckState {
        if checked.contains(item.id) { return .on }
        return checkedChildren[item.id]?.isEmpty == false ? .mixed : .off
    }

    func isChecked(_ child: CacheChild, in item: CacheItem) -> Bool {
        checked.contains(item.id) || checkedChildren[item.id]?.contains(child.id) == true
    }

    func toggle(_ child: CacheChild, in item: CacheItem) {
        guard !item.permanentOnly, let children = item.children else { return }
        let all = Set(children.map(\.id))
        var picked = checked.contains(item.id) ? all : (checkedChildren[item.id] ?? [])
        if picked.contains(child.id) { picked.remove(child.id) } else { picked.insert(child.id) }
        checked.remove(item.id)
        checkedChildren[item.id] = nil
        if picked == all { checked.insert(item.id) } else if !picked.isEmpty { checkedChildren[item.id] = picked }
    }

    /// Selects every item in the location except the newest `keep` (lists sort newest first where age matters).
    func selectAllButNewest(_ item: CacheItem, keep: Int = 1) {
        guard let children = item.children, children.count > keep else { return }
        checked.remove(item.id)
        checkedChildren[item.id] = Set(children.dropFirst(keep).map(\.id))
    }

    /// Partly selected locations with their selected items.
    private var partialSelections: [(item: CacheItem, children: [CacheChild])] {
        selectable.compactMap { item in
            guard let ids = checkedChildren[item.id], !ids.isEmpty else { return nil }
            let children = (item.children ?? []).filter { ids.contains($0.id) }
            return children.isEmpty ? nil : (item, children)
        }
    }

    // MARK: Whole locations

    func toggle(_ id: String) {
        guard selectable.contains(where: { $0.id == id }) else { return }
        checkedChildren[id] = nil
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
    }

    var allState: CheckState {
        let ids = Set(selectable.map(\.id))
        let n = ids.intersection(checked).count
        if n == ids.count && !ids.isEmpty { return .on }
        return n == 0 && partialSelections.isEmpty ? .off : .mixed
    }

    func toggleAll() {
        let ids = Set(selectable.map(\.id))
        checkedChildren = [:]
        if ids.isSubset(of: checked) { checked.subtract(ids) } else { checked.formUnion(ids) }
    }

    var selectedItems: [CacheItem] { selectable.filter { checked.contains($0.id) } }

    /// Locations with anything selected, for the selection bar's count.
    var selectedCount: Int { selectedItems.count + partialSelections.count }

    /// What "Reveal in Finder" shows: whole locations, and the single items picked elsewhere.
    var selectedURLs: [URL] {
        selectedItems.map(\.url) + partialSelections.flatMap { $0.children.map { $0.urls[0] } }
    }

    var trash: CacheItem? { store.caches.first { $0.permanentOnly } }

    func emptyTrashRequest() -> CleanupRequest? {
        guard let trash, !trash.contents.isEmpty else { return nil }
        return CleanupRequest(
            title: "Empty the Trash?",
            restoreHint: "Permanently deletes \(CountFormat.plural(trash.contents.count, "item")) in the Trash. This can't be undone.",
            entries: [CleanupEntry(trash, displayPath: "~/.Trash/*")],
            forcePermanent: true, confirmVerb: "Empty Trash")
    }
    var selectedSize: Int64 {
        selectedItems.reduce(0) { $0 + $1.size } + partialSelections.reduce(0) { $0 + $1.children.reduce(0) { $0 + $1.size } }
    }

    func cleanupRequest() -> CleanupRequest {
        let items = selectedItems.sorted { $0.size > $1.size }
        let partial = partialSelections
        let review = (items + partial.map(\.item)).filter { $0.safety == .review }
        let hint = review.isEmpty
            ? "Tools refill these caches as needed. Re-download items are fetched again over the network."
            : "Includes Review items: \(review.map(\.name).joined(separator: ", ")). \(review.first!.restoreHint.prefix(1).uppercased() + review.first!.restoreHint.dropFirst())."
        let singles = partial.flatMap { p in p.children.map { p.item.entry(for: $0) } }
        let title: String
        if partial.isEmpty {
            title = "Clear \(items.count) cache\(items.count == 1 ? "" : "s")?"
        } else if items.isEmpty {
            title = "Delete \(CountFormat.plural(singles.count, "item"))?"
        } else {
            title = "Clear \(CountFormat.plural(items.count, "cache")) and \(CountFormat.plural(singles.count, "item"))?"
        }
        return CleanupRequest(
            title: title,
            restoreHint: hint,
            entries: items.map { CleanupEntry($0, displayPath: PathFormat.abbreviate($0.url) + "/*") } + singles
        )
    }

    func prune(_ ids: Set<String>) {
        checked.subtract(ids)
        // Single-item ids are `locationID#childID`.
        for id in ids {
            guard let hash = id.firstIndex(of: "#") else { continue }
            let location = String(id[..<hash]), child = String(id[id.index(after: hash)...])
            checkedChildren[location]?.remove(child)
            if checkedChildren[location]?.isEmpty == true { checkedChildren[location] = nil }
        }
    }
}
