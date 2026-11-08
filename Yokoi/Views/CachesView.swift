import SwiftUI

struct CachesView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let vm = app.cachesVM
        let store = app.store
        let sections = vm.sections(search: app.search)

        VStack(spacing: 0) {
            HeaderBar(title: "\(CleanCategory.caches.title)",
                      subtitle: "\(store.caches.count) locations · \(ByteFormat.string(store.total(.caches)))") {
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
                    // The Trash sits apart, above the list: it holds deleted files, not a cache, and is emptied on its own.
                    if let trash = vm.trash, app.search.isEmpty || trash.name.localizedCaseInsensitiveContains(app.search) {
                        TrashCard(trash: trash) { if let r = vm.emptyTrashRequest() { app.requestCleanup(r) } }
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(sections.filter { $0.section != .trash }) { section in
                                SectionLabel(verbatim: section.section.title)
                                    .padding(.horizontal, 20)
                                    .padding(.top, 16)
                                    .padding(.bottom, 8)
                                ForEach(section.items.filter { !$0.permanentOnly }) { item in
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
                            ToolActionsSection()
                        }
                        .padding(.bottom, 8)
                    }
                    .card(padding: 0)
                }
            }
            .padding(Theme.Metrics.contentPadding)

            SelectionBar(state: vm.allState, toggleAll: vm.toggleAll,
                         count: vm.selectedCount, selection: "**\(vm.selectedCount) caches** selected", size: vm.selectedSize,
                         reclaim: "**\(ByteFormat.string(vm.selectedSize))** will be reclaimed") {
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
                        .help("\(n) items")
                }
            }
            .frame(width: 280, alignment: .leading)
            Text(PathFormat.abbreviate(item.url))
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            StatusPill(text: item.permanentOnly ? String(localized: "PERMANENT", comment: "Status pill: can only be deleted for good") : item.safety.label, color: item.permanentOnly ? Theme.danger : item.safety.color)
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

/// The Trash on its own card above the cache list: deleted files rather than a cache, only ever emptied for good.
private struct TrashCard: View {
    let trash: CacheItem
    let empty: () -> Void

    var body: some View {
        let count = trash.contents.count
        HStack(spacing: 16) {
            Image(systemName: count == 0 ? "trash" : "trash.fill")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Theme.danger)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.danger.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.danger.opacity(0.25)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Trash").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text(count == 0 ? String(localized: "empty", comment: "The Trash has nothing in it") : String(localized: "\(count) items"))
                        .font(Theme.mono(11.5)).foregroundStyle(Theme.textTertiary)
                }
                Text("Files you already deleted, not a cache. Emptying the Trash can't be undone.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 12)
            SizeText(bytes: trash.size, size: 18, weight: .semibold, color: count == 0 ? Theme.textTertiary : Theme.textPrimary)
            Button("Empty Trash…", action: empty)
                .buttonStyle(.dkDanger)
                .disabled(count == 0)
        }
        .card(padding: 16)
        .contextMenu { Button("Reveal in Finder") { Finder.reveal([trash.url]) } }
        .accessibilityElement(children: .contain)
    }
}

/// A disclosure chevron, or a same-width gap so rows without one stay aligned.
struct Twisty: View {
    let expanded: Bool?
    let action: () -> Void
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        Group {
            if let expanded {
                Button(action: action) {
                    // `forward` points left in right-to-left languages, so it turns the other way to point down.
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .rotationEffect(.degrees(expanded ? (direction == .rightToLeft ? -90 : 90) : 0))
                        .frame(width: 14, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? Text("Collapse") : Text("Expand"))
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
                            .help(status == nil && action.isDocker && tools.loaded ? String(localized: "Docker isn't installed or its engine isn't running.") : action.explanation)
                    }
                    Spacer(minLength: 12)
                    Group {
                        if let status {
                            Text(status.count == 0 ? String(localized: "none", comment: "Tool cleanup: nothing to delete")
                                 : picked.isEmpty ? action.countPhrase(status.count)
                                 : String(localized: "\(picked.count) of \(status.count) picked", comment: "Tool cleanup: items picked under the twisty"))
                                .font(Theme.mono(11.5)).foregroundStyle(picked.isEmpty ? Theme.textSecondary : Theme.accentLight)
                        } else {
                            Text(tools.loaded ? String(localized: "unavailable", comment: "Tool cleanup: the tool isn't available") : String(localized: "not checked", comment: "Tool cleanup: not checked yet")).font(Theme.mono(11.5)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .frame(width: 110, alignment: .leading)
                    Button("Delete…") { if let r = status.flatMap({ tools.cleanupRequest(for: $0) }) { app.requestCleanup(r) } }
                        .buttonStyle(DKButtonStyle(kind: .danger, compact: true))
                        .disabled((status?.count ?? 0) == 0 || tools.running || status.flatMap { tools.cleanupRequest(for: $0) } == nil)
                        .help(action.requiresSelection && picked.isEmpty ? String(localized: "Open the list and pick the ones to delete.") : "")
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
            .help(item.command.map { "$ " + $0.joined(separator: " ") } ?? String(localized: "Can't be deleted on its own."))
            Spacer(minLength: 12)
            Text(item.date.map { RelativeDate.string($0) } ?? "")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                .help(item.date.map { String(localized: "Last used or created \($0.formatted(date: .abbreviated, time: .shortened))", comment: "Placeholder is a date and time") } ?? "")
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
