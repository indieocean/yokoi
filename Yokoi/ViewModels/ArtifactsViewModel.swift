import Foundation
import Observation

@MainActor
@Observable
final class ArtifactsViewModel: SelectionPruning {
    enum Grouping: Hashable { case language, project }

    struct Group: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let badge: String
        let color: UInt32
        let items: [ArtifactItem]
        var size: Int64 { items.reduce(0) { $0 + $1.size } }
    }

    struct Chip: Identifiable {
        let ecosystem: Ecosystem
        let size: Int64
        var id: String { ecosystem.rawValue }
    }

    var grouping: Grouping = .language
    var checked: Set<String> = []
    private var defaultsApplied: Set<String> = []

    let store: ScanStore
    init(store: ScanStore) { self.store = store }

    private var settings: SettingsData { store.settings.data }

    func isRecent(_ item: ArtifactItem) -> Bool {
        CleanupEntry(item).isRecentlyActive(days: settings.protectRecentDays)
    }

    func applyDefaults() {
        for item in store.artifacts where !defaultsApplied.contains(item.id) {
            defaultsApplied.insert(item.id)
            if !item.optIn && !isRecent(item) { checked.insert(item.id) }
        }
    }

    private func filtered(_ search: String) -> [ArtifactItem] {
        store.artifacts.filter {
            search.isEmpty
                || $0.projectName.localizedCaseInsensitiveContains(search)
                || $0.displayPath.localizedCaseInsensitiveContains(search)
                || $0.ecosystem.displayName.localizedCaseInsensitiveContains(search)
        }
    }

    func groups(search: String) -> [Group] {
        let items = filtered(search)
        switch grouping {
        case .language:
            let byEco = Dictionary(grouping: items, by: \.ecosystem)
            return byEco.map { eco, items in
                Group(id: eco.rawValue, title: eco.displayName, subtitle: summary(for: eco),
                      badge: eco.badge, color: eco.colorHex, items: items.sorted { $0.size > $1.size })
            }
            .sorted { $0.size > $1.size }
        case .project:
            let byProject = Dictionary(grouping: items) { $0.isGlobal ? "Global" : $0.projectURL.path }
            return byProject.map { key, items in
                let first = items[0]
                let title = key == "Global" ? String(localized: "Global caches", comment: "Build Artifacts group for caches shared by all projects") : first.projectName
                let ecos = Array(Set(items.map(\.ecosystem))).sorted { $0.rawValue < $1.rawValue }
                return Group(id: key, title: title,
                             subtitle: key == "Global" ? "DerivedData · go-build" : PathFormat.abbreviate(first.projectURL),
                             badge: ecos.count == 1 ? ecos[0].badge : "\(ecos.count)",
                             color: ecos.count == 1 ? ecos[0].colorHex : 0x7D8597,
                             items: items.sorted { $0.size > $1.size })
            }
            .sorted { $0.size > $1.size }
        }
    }

    private func summary(for eco: Ecosystem) -> String {
        if let rule = ArtifactRule.all.first(where: { $0.ecosystem == eco }) { return rule.summary }
        if let rule = GlobalArtifactRule.all.first(where: { $0.ecosystem == eco }) { return rule.summary }
        return ""
    }

    var chips: [Chip] {
        let byEco = Dictionary(grouping: store.artifacts.filter { !$0.optIn }, by: \.ecosystem)
        return byEco.map { Chip(ecosystem: $0.key, size: $0.value.reduce(0) { $0 + $1.size }) }
            .sorted { $0.size > $1.size }
    }

    var toolchainCount: Int { Set(store.artifacts.map(\.ecosystem)).count }

    func toggle(_ id: String) {
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
    }

    func checkState(for items: [ArtifactItem]) -> CheckState {
        let ids = Set(items.map(\.id))
        let n = ids.intersection(checked).count
        return n == 0 ? .off : (n == ids.count ? .on : .mixed)
    }

    func toggleAll(_ items: [ArtifactItem]) {
        let ids = Set(items.map(\.id))
        if ids.isSubset(of: checked) { checked.subtract(ids) } else { checked.formUnion(ids) }
    }

    var selectedItems: [ArtifactItem] { store.artifacts.filter { checked.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    func cleanupRequest() -> CleanupRequest {
        let items = selectedItems.sorted { $0.size > $1.size }
        let hints = Set(items.map(\.restoreHint))
        let hint = hints.count == 1
            ? String(localized: "Rebuild anytime: `\(hints.first!)`.", comment: "Confirmation hint; placeholder is a build command")
            : String(localized: "Everything here is rebuilt by its toolchain on the next build.")
        return CleanupRequest(
            title: String(localized: "Clean \(items.count) build targets?", comment: "Confirmation title"),
            restoreHint: hint,
            entries: items.map { CleanupEntry($0, displayPath: $0.displayPath) }
        )
    }

    func prune(_ ids: Set<String>) { checked.subtract(ids) }
}
