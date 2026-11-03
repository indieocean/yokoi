import Foundation
import Observation

@MainActor
@Observable
final class DuplicatesViewModel: SelectionPruning {
    var checked: Set<String> = []
    var previewURL: URL?

    let store: ScanStore
    init(store: ScanStore) { self.store = store }

    var groups: [DuplicateGroup] { store.duplicateGroups }

    func groups(search: String) -> [DuplicateGroup] {
        guard !search.isEmpty else { return groups }
        return groups.filter { group in
            group.files.contains {
                $0.name.localizedCaseInsensitiveContains(search) || $0.location.localizedCaseInsensitiveContains(search)
            }
        }
    }

    /// `file` is the only copy not picked, so it can't be picked too.
    func isLastCopy(_ file: DuplicateFile, in group: DuplicateGroup) -> Bool {
        !checked.contains(file.id) && group.files.allSatisfy { $0.id == file.id || checked.contains($0.id) }
    }

    func toggle(_ file: DuplicateFile, in group: DuplicateGroup) {
        if checked.contains(file.id) {
            checked.remove(file.id)
        } else if !isLastCopy(file, in: group) {
            checked.insert(file.id)
        }
    }

    func checkState(for groups: [DuplicateGroup]) -> CheckState {
        let ids = Set(groups.flatMap(\.extras).map(\.id))
        let n = ids.intersection(checked).count
        return n == 0 ? .off : (n == ids.count ? .on : .mixed)
    }

    /// Picks the extra copies in `groups`, or clears them if they're all picked already. Copies picked by hand
    /// are cleared first, so a group can't end up with every copy picked.
    func toggleExtras(_ groups: [DuplicateGroup]) {
        let all = Set(groups.flatMap(\.files).map(\.id))
        let extras = Set(groups.flatMap(\.extras).map(\.id))
        let allPicked = extras.isSubset(of: checked)
        checked.subtract(all)
        if !allPicked { checked.formUnion(extras) }
    }

    var selectedItems: [DuplicateFile] { groups.flatMap { $0.removable(from: checked) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    func cleanupRequest() -> CleanupRequest {
        let entries = groups.flatMap { $0.entries(removing: checked) }.sorted { $0.size > $1.size }
        return CleanupRequest(
            title: "Remove \(CountFormat.plural(entries.count, "duplicate"))?",
            restoreHint: "The copies you didn't pick stay where they are. Move to Trash keeps these recoverable until you empty it.",
            entries: entries
        )
    }

    func prune(_ ids: Set<String>) { checked.subtract(ids) }
}
