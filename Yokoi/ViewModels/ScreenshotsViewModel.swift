import Foundation
import Observation

@MainActor
@Observable
final class ScreenshotsViewModel: SelectionPruning {
    enum Tab: Hashable { case screenshots, recordings }
    enum Action: Hashable { case move, delete }

    var tab: Tab = .screenshots
    var action: Action = .move
    var checked: Set<String> = []

    let store: ScanStore
    init(store: ScanStore) { self.store = store }

    private var settings: SettingsData { store.settings.data }

    var screenshotCount: Int { store.screenshots.filter { !$0.isRecording }.count }
    var recordingCount: Int { store.screenshots.filter(\.isRecording).count }

    func items(search: String) -> [ScreenshotItem] {
        store.screenshots
            .filter { tab == .recordings ? $0.isRecording : !$0.isRecording }
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
            .sorted { $0.created > $1.created }
    }

    func isOld(_ item: ScreenshotItem) -> Bool { item.ageInDays() >= settings.screenshotAgeDays }

    func selectOlderThanThreshold() {
        checked = Set(store.screenshots.filter { isOld($0) && (tab == .recordings ? $0.isRecording : !$0.isRecording) }.map(\.id))
    }

    func toggle(_ id: String) {
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
    }

    func toggleAll(_ items: [ScreenshotItem]) {
        let ids = Set(items.map(\.id))
        if ids.isSubset(of: checked) { checked.subtract(ids) } else { checked.formUnion(ids) }
    }

    var selectedItems: [ScreenshotItem] { store.screenshots.filter { checked.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    var destination: URL { PathFormat.expand(settings.screenshotDestination) }

    /// Shows where items will go, e.g. `~/Pictures/Screenshots/2026/10/`.
    var destinationPreview: String {
        let base = settings.screenshotDestination
        guard settings.screenshotOrganizeByDate else { return base + "/" }
        let c = Calendar.current.dateComponents([.year, .month], from: selectedItems.map(\.created).max() ?? Date())
        return base + String(format: "/%04d/%02d/", c.year ?? 2026, c.month ?? 1)
    }

    var entries: [CleanupEntry] {
        selectedItems.sorted { $0.created > $1.created }.map { CleanupEntry($0, date: $0.created) }
    }

    var moveAction: CleanupAction {
        .move(destination: destination, organizeByDate: settings.screenshotOrganizeByDate)
    }

    func deleteRequest() -> CleanupRequest {
        let n = selectedItems.count
        let noun = tab == .recordings ? "recording" : "screenshot"
        return CleanupRequest(
            title: "Delete \(n) \(noun)\(n == 1 ? "" : "s")?",
            restoreHint: "They go to the Trash, so you can put them back until it's emptied.",
            entries: entries
        )
    }

    func prune(_ ids: Set<String>) { checked.subtract(ids) }
}
