import SwiftUI

struct NodeModulesView: View {
    @Environment(AppModel.self) private var app
    /// Shown inside the Package Managers npm tab, which provides the header.
    var embedded = false

    var body: some View {
        @Bindable var vm = app.nodeModulesVM
        let store = app.store
        let rows = vm.rows(search: app.search)
        let counts = vm.counts
        let maxSize = Double(max(vm.maxSize, 1))

        VStack(spacing: 0) {
            if !embedded {
                HeaderBar(title: "node_modules",
                          subtitle: "\(store.nodeModules.count) folders · \(ByteFormat.string(store.total(.nodeModules)))") {
                    RescanButton(category: .nodeModules)
                }
            }

            VStack(spacing: 14) {
                ScanProgressStrip(category: .nodeModules)
                HStack(spacing: 12) {
                    SegmentedTabs(selection: $vm.filter, items: [
                        .init(value: .all, title: "All", count: "\(counts.all)"),
                        .init(value: .stale, title: "Stale", count: "\(counts.stale)"),
                        .init(value: .active, title: "Active", count: "\(counts.active)"),
                    ])
                    StaleThresholdMenu()
                    Spacer()
                    if !vm.packageManagers.isEmpty {
                        Text("Package manager:").font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                        ForEach(vm.packageManagers, id: \.self) { pm in
                            StatusPill(text: pm.rawValue, color: Color(hex: pm.colorHex))
                        }
                    }
                }

                if store.nodeModules.isEmpty && !store.scanningCategories.contains(.nodeModules) {
                    EmptyStateView(symbol: "shippingbox", title: "No node_modules found",
                                   message: "Nothing under your scan locations. Add folders in Settings → Scan locations.",
                                   actionTitle: "Open Settings") { app.screen = .settings }
                        .card()
                } else {
                    Table(rows, sortOrder: $vm.sortOrder) {
                        TableColumn("") { row in
                            CheckBox(isOn: vm.checked.contains(row.id)) { vm.toggle(row.id) }
                        }
                        .width(24)
                        TableColumn("Project", value: \.name) { row in
                            HStack(spacing: 8) {
                                Text(row.name).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                Tag(text: row.item.frameworkHint)
                            }
                        }
                        .width(220)
                        TableColumn("Path", value: \.path) { row in
                            Text(row.path).font(Theme.mono(11.5)).foregroundStyle(Theme.textSecondary)
                                .lineLimit(1).truncationMode(.middle)
                                .help(row.item.url.path)
                        }
                        .width(min: 160)
                        TableColumn("Status", value: \.statusRank) { row in
                            StatusPill(text: row.isStale ? "STALE" : "ACTIVE", color: row.isStale ? Theme.warning : Theme.success)
                        }
                        .width(70)
                        TableColumn("Last touched", value: \.lastTouched) { row in
                            Text(RelativeDate.string(row.item.lastTouched)).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                        }
                        .width(110)
                        TableColumn("Size", value: \.size) { row in
                            HStack(spacing: 14) {
                                SizeBar(fraction: Double(row.size) / maxSize, color: Theme.success)
                                SizeText(bytes: row.size).frame(width: 72, alignment: .trailing)
                            }
                        }
                        .width(170)
                    }
                    .tableStyle(.inset(alternatesRowBackgrounds: false))
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 34)
                    .contextMenu(forSelectionType: String.self) { ids in
                        Button("Reveal in Finder") { Finder.reveal(store.nodeModules.filter { ids.contains($0.id) }.map(\.url)) }
                    }
                    .card(padding: 4)
                }
            }
            .padding(.horizontal, Theme.Metrics.contentPadding)
            .padding(.top, embedded ? 14 : Theme.Metrics.contentPadding)
            .padding(.bottom, Theme.Metrics.contentPadding)

            SelectionBar(state: vm.checkState(for: rows), toggleAll: { vm.toggleAll(rows) },
                         count: vm.checked.count, selection: "**\(vm.checked.count) folders** selected", size: vm.selectedSize,
                         reclaim: "**\(ByteFormat.string(vm.selectedSize))** will be reclaimed") {
                Button("Reveal in Finder") { Finder.reveal(vm.selectedItems.map(\.url)) }
                    .buttonStyle(.dkSecondary)
                    .disabled(vm.checked.isEmpty)
                Button {
                    app.requestCleanup(vm.cleanupRequest())
                } label: {
                    Label("Delete node_modules", systemImage: "delete.left")
                }
                .buttonStyle(.dkDanger)
                .disabled(vm.checked.isEmpty)
                .keyboardShortcut(.delete, modifiers: .command)
            }
        }
        .onAppear { vm.applyDefaults() }
        .onChange(of: store.nodeModules.count) { vm.applyDefaults() }
    }
}

struct StaleThresholdMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let days = app.settings.data.staleDays
        Menu {
            ForEach([30, 60, 90, 180, 365], id: \.self) { d in
                Button {
                    app.settings.data.staleDays = d
                } label: {
                    if d == days { Label("\(d) days", systemImage: "checkmark") } else { Text("\(d) days") }
                }
            }
        } label: {
            HStack(spacing: 6) {
                let threshold = Text("\(days)d", comment: "Stale threshold in days, e.g. 90d").font(Theme.mono(13, .bold))
                Text("Untouched > \(threshold)", comment: "Stale threshold menu; placeholder is a number of days like 90d")
                    .font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.cardStroke))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("node_modules in projects untouched for longer than this are marked stale")
    }
}

struct RescanButton: View {
    @Environment(AppModel.self) private var app
    let category: CleanCategory

    var body: some View {
        let scanning = app.store.scanningCategories.contains(category)
        Button {
            if scanning { app.store.cancelScan() } else { app.store.scan([category]) }
        } label: {
            Label(scanning ? String(localized: "Stop") : String(localized: "Rescan"), systemImage: scanning ? "stop.fill" : "arrow.clockwise")
        }
        .buttonStyle(.dkPrimary)
        .disabled(app.store.isScanning && !scanning)
    }
}
