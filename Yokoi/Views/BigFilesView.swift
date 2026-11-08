import QuickLook
import SwiftUI

struct BigFilesView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var vm = app.bigFilesVM
        let store = app.store
        let rows = vm.rows(search: app.search)
        let visible = vm.visibleTotal

        VStack(spacing: 0) {
            HeaderBar(title: "Big Files",
                      subtitle: "\(visible.count) files ≥ \(ByteFormat.string(vm.threshold)) · \(ByteFormat.string(visible.size))") {
                Button {
                    Finder.reveal(vm.selectedItems.map(\.url))
                } label: {
                    Label("Reveal in Finder", systemImage: "magnifyingglass")
                }
                .buttonStyle(.dkSecondary)
                .disabled(vm.checked.isEmpty)
                RescanButton(category: .bigFiles)
            }

            VStack(spacing: 14) {
                ScanProgressStrip(category: .bigFiles)
                ThresholdCard()

                if store.bigFiles.isEmpty && !store.scanningCategories.contains(.bigFiles) {
                    EmptyStateView(symbol: "externaldrive", title: "No big files found",
                                   message: "Nothing over 100 MB in your big-file locations (Settings → Big file locations).")
                        .card()
                } else {
                    Table(rows, sortOrder: $vm.sortOrder) {
                        TableColumn("") { row in
                            CheckBox(isOn: vm.checked.contains(row.id)) { vm.toggle(row.id) }
                        }
                        .width(24)
                        TableColumn("") { row in
                            Badge(text: row.item.badge, color: row.item.kind.color, size: 30, fontSize: 10)
                        }
                        .width(40)
                        TableColumn("Name", value: \.name) { row in
                            Text(row.name).font(.system(size: 13.5)).foregroundStyle(Theme.textPrimary)
                                .lineLimit(1).truncationMode(.middle)
                                .help(row.item.url.path)
                        }
                        .width(min: 180)
                        TableColumn("Location", value: \.location) { row in
                            Text(row.location).font(Theme.mono(11.5)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                        }
                        .width(220)
                        TableColumn("Modified", value: \.modified) { row in
                            Text(RelativeDate.short(row.item.modified)).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                        }
                        .width(100)
                        TableColumn("Size", value: \.size) { row in
                            SizeText(bytes: row.size).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .width(80)
                        TableColumn("") { row in
                            HStack(spacing: 10) {
                                Button { Finder.reveal([row.item.url]) } label: { Image(systemName: "magnifyingglass") }
                                    .help("Reveal in Finder")
                                Button { vm.previewURL = row.item.url } label: { Image(systemName: "eye") }
                                    .help("Quick Look")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.textSecondary)
                        }
                        .width(50)
                    }
                    .tableStyle(.inset(alternatesRowBackgrounds: false))
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 36)
                    .card(padding: 4)
                }
            }
            .padding(Theme.Metrics.contentPadding)

            SelectionBar(state: vm.checkState(for: rows), toggleAll: { vm.toggleAll(rows) },
                         count: vm.checked.count, selection: "**\(vm.checked.count) files** selected", size: vm.selectedSize,
                         reclaim: "**\(ByteFormat.string(vm.selectedSize))** will be reclaimed") {
                Button("Reveal in Finder") { Finder.reveal(vm.selectedItems.map(\.url)) }
                    .buttonStyle(.dkSecondary)
                    .disabled(vm.checked.isEmpty)
                Button {
                    if let dest = Finder.chooseFolder(title: String(localized: "Move \(vm.checked.count) files to…", comment: "Folder picker title"),
                                                        prompt: String(localized: "Move Here", comment: "Folder picker button")) {
                        let entries = vm.selectedItems.map { CleanupEntry($0) }
                        Task { await app.run(entries, action: .move(destination: dest, organizeByDate: false)) }
                    }
                } label: {
                    Label("Move to…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.dkSecondary)
                .disabled(vm.checked.isEmpty)
                Button {
                    app.requestCleanup(vm.cleanupRequest())
                } label: {
                    Label("Move to Trash", systemImage: "delete.left")
                }
                .buttonStyle(.dkDanger)
                .disabled(vm.checked.isEmpty)
                .keyboardShortcut(.delete, modifiers: .command)
            }
        }
        .quickLookPreview($vm.previewURL)
    }
}

private struct ThresholdCard: View {
    @Environment(AppModel.self) private var app

    private let ticks: [(String, Double)] = [
        ("100 MB", 100_000_000), ("500 MB", 500_000_000), ("1 GB", 1_000_000_000), ("5 GB", 5_000_000_000), ("10 GB+", 10_000_000_000),
    ]

    var body: some View {
        @Bindable var vm = app.bigFilesVM
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Minimum size").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Text("≥ " + thresholdLabel(vm.threshold))
                    .font(Theme.mono(22, .bold))
                    .foregroundStyle(Theme.accentLight)
            }
            .frame(width: 130, alignment: .leading)

            VStack(spacing: 4) {
                Slider(value: $vm.sliderPosition, in: 0...1)
                    .controlSize(.small)
                    .accessibilityLabel("Minimum file size")
                    .accessibilityValue(thresholdLabel(vm.threshold))
                GeometryReader { geo in
                    ForEach(ticks, id: \.0) { tick in
                        let x = geo.size.width * BigFilesViewModel.position(for: tick.1)
                        Text(tick.0)
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize()
                            .frame(width: 60, alignment: tick.1 >= 10_000_000_000 ? .trailing : (tick.1 <= 100_000_000 ? .leading : .center))
                            .position(x: tick.1 >= 10_000_000_000 ? x - 30 : (tick.1 <= 100_000_000 ? x + 30 : x), y: 6)
                    }
                }
                .frame(height: 12)
            }
            .frame(maxWidth: 560)

            Spacer(minLength: 0)

            SegmentedTabs(selection: $vm.kindFilter, items:
                [.init(value: .all, title: "All")] + BigFileKind.filters.map { .init(value: .kind($0), verbatim: $0.filterTitle) },
                compact: true)
        }
        .card(padding: 18)
    }

    private func thresholdLabel(_ bytes: Int64) -> String {
        if bytes >= 1_000_000_000 { return String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }
        return "\(bytes / 1_000_000) MB"
    }
}
