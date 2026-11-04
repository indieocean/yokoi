import AppKit
import SwiftUI

struct ApplicationsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var vm = app.applicationsVM
        let store = app.store
        let rows = vm.rows(search: app.search)
        let counts = vm.counts
        let maxSize = Double(max(vm.maxSize, 1))
        let total = store.applications.reduce(Int64(0)) { $0 + $1.size }

        VStack(spacing: 0) {
            HeaderBar(title: "Applications", subtitle: "\(CountFormat.plural(counts.all, "app")) · \(ByteFormat.string(total))") {
                RescanButton(category: .applications)
            }

            VStack(spacing: 14) {
                ScanProgressStrip(category: .applications)
                HStack(spacing: 12) {
                    SegmentedTabs(selection: $vm.filter, items: [
                        .init(value: .all, title: "All", count: "\(counts.all)"),
                        .init(value: .unused, title: "Unused > 6 mo", count: "\(counts.unused)"),
                        .init(value: .appStore, title: "App Store", count: "\(counts.appStore)"),
                    ])
                    Spacer()
                    Label("Apple apps and running apps can't be selected", systemImage: "lock")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }

                if store.applications.isEmpty && !store.scanningCategories.contains(.applications) {
                    EmptyStateView(symbol: "app.dashed", title: "No apps scanned yet",
                                   message: "Scan /Applications and ~/Applications for apps, their size, when you last opened them and what they keep in ~/Library.",
                                   actionTitle: "Scan apps") { store.scan([.applications]) }
                        .card()
                } else {
                    Table(rows, sortOrder: $vm.sortOrder) {
                        TableColumn("") { row in
                            if vm.canSelect(row.item) {
                                CheckBox(isOn: vm.checked.contains(row.id)) { vm.toggle(row.item) }
                            } else {
                                Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                                    .frame(width: 16)
                                    .help(row.running ? "Quit the app first" : (row.item.protectedReason ?? ""))
                            }
                        }
                        .width(24)
                        TableColumn("App", value: \.name) { row in
                            HStack(spacing: 10) {
                                AppIconView(url: row.item.url)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(row.name).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                        if row.item.isAppStore { Tag(text: "App Store", color: Theme.info) }
                                    }
                                    Text("\(row.item.version.isEmpty ? "" : "v\(row.item.version) · ")\(row.item.bundleID)")
                                        .font(Theme.mono(10.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                                }
                            }
                            .help(row.item.url.path)
                        }
                        .width(min: 240)
                        TableColumn("Status") { row in
                            if row.running {
                                StatusPill(text: "RUNNING", color: Theme.success)
                            } else if let reason = row.item.protectedReason {
                                StatusPill(text: reason == "Apple app" ? "APPLE" : "PROTECTED", color: Theme.textSecondary)
                            } else if row.item.isUnused(days: ApplicationsViewModel.unusedDays) {
                                StatusPill(text: "UNUSED", color: Theme.warning)
                            }
                        }
                        .width(90)
                        TableColumn("Last opened", value: \.lastUsed) { row in
                            Text(row.item.lastUsed.map { RelativeDate.string($0) } ?? "Never")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                        }
                        .width(110)
                        TableColumn("Leftovers", value: \.leftoverSize) { row in
                            LeftoversButton(item: row.item)
                        }
                        .width(120)
                        TableColumn("Size", value: \.size) { row in
                            HStack(spacing: 12) {
                                SizeBar(fraction: Double(row.size) / maxSize, color: CleanCategory.applications.color)
                                SizeText(bytes: row.size).frame(width: 72, alignment: .trailing)
                            }
                        }
                        .width(170)
                    }
                    .tableStyle(.inset(alternatesRowBackgrounds: false))
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 40)
                    .contextMenu(forSelectionType: String.self) { ids in
                        Button("Reveal in Finder") { Finder.reveal(store.applications.filter { ids.contains($0.id) }.map(\.url)) }
                    }
                    .card(padding: 4)
                }
            }
            .padding(Theme.Metrics.contentPadding)

            SelectionBar(state: vm.checkState(for: rows), toggleAll: { vm.toggleAll(rows) },
                         count: vm.checked.count, noun: vm.checked.count == 1 ? "app" : "apps", size: vm.selectedSize) {
                Button("Reveal in Finder") { Finder.reveal(vm.selectedItems.map(\.url)) }
                    .buttonStyle(.dkSecondary)
                    .disabled(vm.checked.isEmpty)
                Button {
                    vm.refreshRunning()
                    app.requestCleanup(vm.cleanupRequest())
                } label: {
                    Label("Uninstall", systemImage: "delete.left")
                }
                .buttonStyle(.dkDanger)
                .disabled(vm.checked.isEmpty)
                .keyboardShortcut(.delete, modifiers: .command)
            }
        }
        .onAppear { vm.refreshRunning() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in vm.refreshRunning() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            vm.refreshRunning()
            vm.checked = vm.checked.filter { id in !vm.selectedItems.contains { $0.id == id && vm.isRunning($0) } }
        }
    }
}

private struct AppIconView: View {
    let url: URL

    var body: some View {
        Group {
            if FileManager.default.fileExists(atPath: url.path) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                // Not on disk (e.g. demo data): a tidy letter tile instead of a blank document icon.
                let name = url.deletingPathExtension().lastPathComponent
                let hue = Double(name.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 360 }) / 360
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.85),
                                                  Color(hue: hue, saturation: 0.7, brightness: 0.55)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(Text(String(name.prefix(1))).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.white))
                    .padding(2)
            }
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }
}

private struct LeftoversButton: View {
    @Environment(AppModel.self) private var app
    let item: AppItem
    @State private var showing = false

    var body: some View {
        if item.leftovers.isEmpty {
            Text("none").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
        } else {
            Button {
                showing.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text("\(item.removableLeftovers.count)").font(Theme.mono(11.5, .semibold))
                    Text("· \(ByteFormat.string(item.leftoverSize))").font(Theme.mono(11.5))
                    if uncertain.count > 0 { Text("+\(uncertain.count)?").font(Theme.mono(11.5)) }
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    if item.leftovers.count > uncertain.count {
                        Text("Removed with the app").font(.system(size: 12.5, weight: .semibold))
                        ForEach(item.leftovers.filter { !$0.isUncertain }, id: \.url) { row($0) }
                    }
                    if !uncertain.isEmpty {
                        Text("May belong to another app").font(.system(size: 12.5, weight: .semibold)).padding(.top, 4)
                        Text("These only match on a name or id any app can claim. They stay unless you tick them.")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                        ForEach(uncertain, id: \.url) { l in
                            HStack(spacing: 10) {
                                CheckBox(isOn: app.applicationsVM.chosenLeftovers.contains(l.url.path)) { app.applicationsVM.toggleLeftover(l) }
                                row(l)
                            }
                        }
                    }
                }
                .padding(16)
                .frame(width: 560)
            }
        }
    }

    private var uncertain: [AppLeftover] { item.leftovers.filter(\.isUncertain) }

    private func row(_ l: AppLeftover) -> some View {
        HStack(spacing: 10) {
            Text(l.kind).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).frame(width: 130, alignment: .leading)
            Text(PathFormat.abbreviate(l.url)).font(Theme.mono(11)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 10)
            SizeText(bytes: l.size, size: 11)
        }
    }
}
