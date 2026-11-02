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
                                   message: "Run a scan to measure npm, Yarn, pnpm, Homebrew, CocoaPods, pip, Cargo, Xcode, Android and browser caches.",
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
                                        let open = vm.expanded.contains(item.id)
                                        CacheRow(item: item, state: vm.state(of: item), toggle: { vm.toggle(item.id) },
                                                 expanded: item.children?.isEmpty == false ? open : nil,
                                                 toggleExpanded: { withAnimation(.easeOut(duration: 0.15)) { vm.toggleExpanded(item.id) } })
                                        if open, let children = item.children {
                                            ForEach(children) { child in
                                                CacheChildRow(child: child, checked: vm.isChecked(child, in: item)) { vm.toggle(child, in: item) }
                                            }
                                            if CacheLocation.all.first(where: { $0.id == item.id })?.breakdown.sortsByDate == true, children.count > 1 {
                                                HStack {
                                                    Button("Select all but the newest") { vm.selectAllButNewest(item) }
                                                        .buttonStyle(DKButtonStyle(kind: .ghost, compact: true))
                                                    Spacer()
                                                }
                                                .padding(.leading, 70)
                                                .padding(.vertical, 6)
                                                .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                                            }
                                        }
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
                         count: vm.selectedCount, noun: vm.selectedCount == 1 ? "cache" : "caches", size: vm.selectedSize) {
                Button("Reveal in Finder") { Finder.reveal(vm.selectedURLs) }
                    .buttonStyle(.dkSecondary)
                    .disabled(vm.selectedCount == 0)
                Button {
                    app.requestCleanup(vm.cleanupRequest())
                } label: {
                    Label("Clear Caches", systemImage: "delete.left")
                }
                .buttonStyle(.dkDanger)
                .disabled(vm.selectedCount == 0)
                .keyboardShortcut(.delete, modifiers: .command)
            }
        }
        .onAppear { vm.applyDefaults() }
        .onChange(of: store.caches.count) { vm.applyDefaults() }
    }
}

private struct CacheRow<Accessory: View>: View {
    let item: CacheItem
    let state: CheckState
    let toggle: () -> Void
    /// Nil when the location has no twisty.
    var expanded: Bool?
    var toggleExpanded: () -> Void
    var accessory: Accessory
    @State private var hovering = false

    init(item: CacheItem, state: CheckState, toggle: @escaping () -> Void, expanded: Bool? = nil,
         toggleExpanded: @escaping () -> Void = {}, @ViewBuilder accessory: () -> Accessory) {
        self.item = item
        self.state = state
        self.toggle = toggle
        self.expanded = expanded
        self.toggleExpanded = toggleExpanded
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 14) {
            Twisty(expanded: expanded, action: toggleExpanded)
                .padding(.trailing, -8)
            if Accessory.self == EmptyView.self {
                CheckBox(state: state, action: toggle)
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
            HStack(spacing: 6) {
                Text(item.name)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textPrimary)
                if let n = item.children?.count, n > 0 {
                    Text("\(n)").font(Theme.mono(10.5)).foregroundStyle(Theme.textTertiary)
                        .help(CountFormat.plural(n, "item"))
                }
            }
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
        .background(state != .off ? Theme.rowSelected : (hovering ? Theme.rowHover : .clear))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hovering = $0 }
        .contextMenu { Button("Reveal in Finder") { Finder.reveal([item.url]) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(state == .on ? .isSelected : [])
    }
}

extension CacheRow where Accessory == EmptyView {
    init(item: CacheItem, state: CheckState, toggle: @escaping () -> Void, expanded: Bool? = nil, toggleExpanded: @escaping () -> Void = {}) {
        self.init(item: item, state: state, toggle: toggle, expanded: expanded, toggleExpanded: toggleExpanded) { EmptyView() }
    }

}

extension CacheRow {
    init(item: CacheItem, checked: Bool, toggle: @escaping () -> Void, @ViewBuilder accessory: () -> Accessory) {
        self.init(item: item, state: checked ? .on : .off, toggle: toggle, accessory: accessory)
    }
}

/// A disclosure chevron, or a same-width gap so rows without one stay aligned.
struct Twisty: View {
    let expanded: Bool?
    let action: () -> Void

    var body: some View {
        Group {
            if let expanded {
                Button(action: action) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 14, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Collapse" : "Expand")
            } else {
                Color.clear.frame(width: 14, height: 24)
            }
        }
    }
}

/// One item inside a cache location: an old simulator, an archive, a model.
private struct CacheChildRow: View {
    let child: CacheChild
    let checked: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            CheckBox(isOn: checked, size: 14, action: toggle)
            HStack(spacing: 8) {
                Text(child.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = child.detail {
                    Text(detail).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            .help(PathFormat.abbreviate(child.urls[0]))
            Spacer(minLength: 12)
            Text(child.date.map { RelativeDate.string($0) } ?? "")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .help(child.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                .frame(width: 110, alignment: .leading)
            SizeText(bytes: child.size)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.leading, 70)
        .padding(.trailing, 20)
        .frame(height: 32)
        .background(checked ? Theme.rowSelected.opacity(0.7) : (hovering ? Theme.rowHover : Color.white.opacity(0.015)))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline.opacity(0.6)).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hovering = $0 }
        .contextMenu { Button("Reveal in Finder") { Finder.reveal([child.urls[0]]) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

/// Cleanups that go through the owning tool (simctl, tmutil, docker). Each shows its exact command first.
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
                let selectable = status?.hasSelectableItems == true
                let open = selectable && tools.expanded.contains(action)
                let picked = tools.picked[action] ?? []
                HStack(spacing: 14) {
                    Twisty(expanded: selectable ? open : nil) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            if tools.expanded.contains(action) { tools.expanded.remove(action) } else { tools.expanded.insert(action) }
                        }
                    }
                    .padding(.trailing, -8)
                    Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(Theme.textSecondary).frame(width: 16)
                    Badge(text: action.badge, color: Theme.info, size: 28, fontSize: 10.5)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(action.title).font(.system(size: 13.5)).foregroundStyle(Theme.textPrimary)
                        Text(LocalizedStringKey(action.explanation)).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                            .help(status == nil && action.isDocker && tools.loaded ? "Docker isn't installed or its engine isn't running." : action.explanation)
                    }
                    Spacer(minLength: 12)
                    Group {
                        if let status {
                            Text(status.count == 0 ? "none"
                                 : picked.isEmpty ? CountFormat.plural(status.count, action.noun)
                                 : "\(picked.count) of \(status.count) picked")
                                .font(Theme.mono(11.5)).foregroundStyle(picked.isEmpty ? Theme.textSecondary : Theme.accentLight)
                        } else {
                            Text(tools.loaded ? "unavailable" : "not checked").font(Theme.mono(11.5)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .frame(width: 110, alignment: .leading)
                    Button("Delete…") { if let r = status.flatMap({ tools.cleanupRequest(for: $0) }) { app.requestCleanup(r) } }
                        .buttonStyle(DKButtonStyle(kind: .danger, compact: true))
                        .disabled((status?.count ?? 0) == 0 || tools.running || status.flatMap { tools.cleanupRequest(for: $0) } == nil)
                        .help(action.requiresSelection && picked.isEmpty ? "Open the list and pick the ones to delete." : "")
                    Text(status?.size.map(ByteFormat.string) ?? "—").font(Theme.mono(12, .medium)).foregroundStyle(Theme.textPrimary)
                        .frame(width: 80, alignment: .trailing)
                }
                .padding(.horizontal, 20)
                .frame(height: 44)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                if open, let status {
                    ForEach(status.items) { item in
                        ToolItemRow(item: item, checked: picked.contains(item.id)) { tools.togglePick(item, in: action) }
                    }
                }
            }
        }
        .task { if !tools.loaded { await tools.refresh() } }
    }
}

/// One image, volume, simulator or snapshot under a tool cleanup's twisty.
private struct ToolItemRow: View {
    let item: ToolActionStatus.Item
    let checked: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        let enabled = item.command != nil
        HStack(spacing: 14) {
            CheckBox(isOn: checked, size: 14, action: toggle)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.35)
            HStack(spacing: 8) {
                Text(item.label).font(.system(size: 12.5)).foregroundStyle(enabled ? Theme.textPrimary : Theme.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
                if let detail = item.detail {
                    Text(detail).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            .help(item.command.map { "$ " + $0.joined(separator: " ") } ?? "Can't be deleted on its own.")
            Spacer(minLength: 12)
            Text(item.date.map { RelativeDate.string($0) } ?? "")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                .help(item.date.map { "Last used or created " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                .frame(width: 110, alignment: .leading)
            Text(item.size.map(ByteFormat.string) ?? "—").font(Theme.mono(12, .medium)).foregroundStyle(Theme.textPrimary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.leading, 70)
        .padding(.trailing, 20)
        .frame(height: 32)
        .background(checked ? Theme.rowSelected.opacity(0.7) : (hovering ? Theme.rowHover : Color.white.opacity(0.015)))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline.opacity(0.6)).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { if enabled { toggle() } }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}
