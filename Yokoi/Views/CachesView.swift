import SwiftUI

struct CachesView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let vm = app.cachesVM
        let store = app.store
        let sections = vm.sections(search: app.search)

        VStack(spacing: 0) {
            HeaderBar(title: "Caches",
                      subtitle: "\(CountFormat.plural(store.caches.count, "location")) · \(ByteFormat.string(store.total(.caches)))") {
                Button("Select safe only") { vm.selectSafeOnly() }.buttonStyle(.dkSecondary)
                RescanButton(category: .caches)
            }

            VStack(spacing: 14) {
                ScanProgressStrip(category: .caches)
                if store.caches.isEmpty && !store.scanningCategories.contains(.caches) {
                    EmptyStateView(symbol: "archivebox", title: "No caches measured yet",
                                   message: "Run a scan to measure npm, Yarn, pnpm, Homebrew, CocoaPods, pip, Cargo, Xcode and browser caches.",
                                   actionTitle: "Scan caches") { store.scan([.caches]) }
                        .card()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(sections) { section in
                                SectionLabel(text: section.section.rawValue)
                                    .padding(.horizontal, 20)
                                    .padding(.top, 16)
                                    .padding(.bottom, 8)
                                ForEach(section.items) { item in
                                    if item.permanentOnly {
                                        CacheRow(item: item, checked: false, toggle: {}) {
                                            Button("Empty…") { if let r = vm.emptyTrashRequest() { app.requestCleanup(r) } }
                                                .buttonStyle(DKButtonStyle(kind: .danger, compact: true))
                                                .disabled(item.contents.isEmpty)
                                        }
                                    } else {
                                        CacheRow(item: item, checked: vm.checked.contains(item.id)) { vm.toggle(item.id) }
                                    }
                                }
                            }
                            ToolActionsSection()
                        }
                        .padding(.bottom, 8)
                    }
                    .card(padding: 0)
                }
            }
            .padding(Theme.Metrics.contentPadding)

            SelectionBar(state: vm.allState, toggleAll: vm.toggleAll,
                         count: vm.checked.count, noun: vm.checked.count == 1 ? "cache" : "caches", size: vm.selectedSize) {
                Button("Reveal in Finder") { Finder.reveal(vm.selectedItems.map(\.url)) }
                    .buttonStyle(.dkSecondary)
                    .disabled(vm.checked.isEmpty)
                Button {
                    app.requestCleanup(vm.cleanupRequest())
                } label: {
                    Label("Clear Caches", systemImage: "delete.left")
                }
                .buttonStyle(.dkDanger)
                .disabled(vm.checked.isEmpty)
                .keyboardShortcut(.delete, modifiers: .command)
            }
        }
        .onAppear { vm.applyDefaults() }
        .onChange(of: store.caches.count) { vm.applyDefaults() }
    }
}

private struct CacheRow<Accessory: View>: View {
    let item: CacheItem
    let checked: Bool
    let toggle: () -> Void
    var accessory: Accessory
    @State private var hovering = false

    init(item: CacheItem, checked: Bool, toggle: @escaping () -> Void, @ViewBuilder accessory: () -> Accessory) {
        self.item = item
        self.checked = checked
        self.toggle = toggle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 14) {
            if Accessory.self == EmptyView.self {
                CheckBox(isOn: checked, action: toggle)
            } else {
                Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Theme.danger).frame(width: 16)
            }
            Group {
                if item.badge == "◎" {
                    Image(systemName: "circle.circle").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.1)))
                } else {
                    Badge(text: item.badge, color: Color(hex: item.colorHex), size: 28, fontSize: 10.5)
                }
            }
            Text(item.name)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 280, alignment: .leading)
            Text(PathFormat.abbreviate(item.url))
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            StatusPill(text: item.permanentOnly ? "PERMANENT" : item.safety.label, color: item.permanentOnly ? Theme.danger : item.safety.color)
                .help(item.restoreHint)
                .frame(width: 110, alignment: .leading)
            accessory
            SizeText(bytes: item.size)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .frame(height: 40)
        .background(checked ? Theme.rowSelected : (hovering ? Theme.rowHover : .clear))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hovering = $0 }
        .contextMenu { Button("Reveal in Finder") { Finder.reveal([item.url]) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

extension CacheRow where Accessory == EmptyView {
    init(item: CacheItem, checked: Bool, toggle: @escaping () -> Void) {
        self.init(item: item, checked: checked, toggle: toggle) { EmptyView() }
    }
}

/// Cleanups that go through the owning tool (simctl, tmutil). Each shows its exact command first.
private struct ToolActionsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let tools = app.tools
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: "Tool cleanups")
                if tools.loading { ProgressView().controlSize(.mini) }
                Spacer()
                Button("Check") { Task { await tools.refresh() } }
                    .buttonStyle(DKButtonStyle(kind: .ghost, compact: true))
                    .disabled(tools.loading)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)
            ForEach(ToolAction.allCases) { action in
                let status = tools.statuses[action]
                HStack(spacing: 14) {
                    Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(Theme.textSecondary).frame(width: 16)
                    Badge(text: action.badge, color: Theme.info, size: 28, fontSize: 10.5)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(action.title).font(.system(size: 13.5)).foregroundStyle(Theme.textPrimary)
                        Text(action.explanation).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    Group {
                        if let status {
                            Text(status.count == 0 ? "none" : CountFormat.plural(status.count, action == .localSnapshots ? "snapshot" : "device"))
                                .font(Theme.mono(11.5)).foregroundStyle(Theme.textSecondary)
                        } else {
                            Text(tools.loaded ? "unavailable" : "not checked").font(Theme.mono(11.5)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .frame(width: 110, alignment: .leading)
                    Button("Delete…") { tools.pending = status }
                        .buttonStyle(DKButtonStyle(kind: .danger, compact: true))
                        .disabled((status?.count ?? 0) == 0 || tools.running)
                    Text(status?.size.map(ByteFormat.string) ?? "—").font(Theme.mono(12, .medium)).foregroundStyle(Theme.textPrimary)
                        .frame(width: 80, alignment: .trailing)
                }
                .padding(.horizontal, 20)
                .frame(height: 44)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            }
        }
        .task { if !tools.loaded { await tools.refresh() } }
    }
}

/// Confirmation for a tool cleanup: what's affected and the exact commands.
struct ToolActionSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let status: ToolActionStatus
    @State private var started = false

    var body: some View {
        let tools = app.tools
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete \(status.action.title.lowercased())?").font(.system(size: 17, weight: .semibold))
            Text(status.action.explanation).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(status.items, id: \.self) { Text($0).font(Theme.mono(11.5)) }
                    Divider().padding(.vertical, 6)
                    ForEach(status.commands.prefix(20), id: \.self) { cmd in
                        Text("$ " + cmd.joined(separator: " ")).font(Theme.mono(11.5)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                    }
                    if status.commands.count > 20 { Text("+ \(status.commands.count - 20) more").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .frame(maxHeight: 200)
            .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.25)))
            if let note = status.note {
                Text(LocalizedStringKey(note)).font(.system(size: 12)).foregroundStyle(Theme.warning)
            }
            if started && !tools.running {
                let failed = tools.results.filter { !$0.succeeded }
                Text(failed.isEmpty ? "Done." : "\(failed.count) command\(failed.count == 1 ? "" : "s") failed: " + (failed.first?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
                    .font(Theme.mono(11.5))
                    .foregroundStyle(failed.isEmpty ? Theme.success : Theme.danger)
                    .textSelection(.enabled)
            }
            HStack {
                if tools.running { ProgressView().controlSize(.small) }
                Spacer()
                Button(started && !tools.running ? "Done" : "Cancel") { dismiss() }
                    .buttonStyle(.dkSecondary)
                    .disabled(tools.running)
                    .keyboardShortcut(.cancelAction)
                if !started {
                    Button("Delete") {
                        started = true
                        Task { await tools.run(status) }
                    }
                    .buttonStyle(.dkDanger)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(Color(hex: 0x1A1D27))
        .interactiveDismissDisabled(tools.running)
    }
}
