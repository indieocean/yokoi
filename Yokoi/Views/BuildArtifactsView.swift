import SwiftUI

struct BuildArtifactsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var vm = app.artifactsVM
        let store = app.store
        let groups = vm.groups(search: app.search)
        let allItems = groups.flatMap(\.items)

        VStack(spacing: 0) {
            HeaderBar(title: "Build Artifacts",
                      subtitle: "\(vm.toolchainCount) toolchains · \(ByteFormat.string(store.total(.buildArtifacts)))") {
                SegmentedTabs(selection: $vm.grouping, items: [
                    .init(value: .language, title: "By language"),
                    .init(value: .project, title: "By project"),
                ], compact: true)
                RescanButton(category: .buildArtifacts)
            }

            VStack(spacing: 14) {
                ScanProgressStrip(category: .buildArtifacts)
                if !vm.chips.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(vm.chips.prefix(6)) { chip in
                            HStack(spacing: 10) {
                                Badge(text: chip.ecosystem.badge, color: chip.ecosystem.color, size: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(chip.ecosystem.shortName).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                                    SizeText(bytes: chip.size, size: 11.5, weight: .regular, color: Theme.textSecondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity)
                            .card(padding: 12)
                        }
                    }
                }

                if store.artifacts.isEmpty && !store.scanningCategories.contains(.buildArtifacts) {
                    EmptyStateView(symbol: "hammer", title: "No build artifacts found",
                                   message: "Yokoi looks for target/, .build/, DerivedData, Unity Library/, Unreal Intermediate/ and more, but only next to their project files.")
                        .card()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: []) {
                            ForEach(groups) { group in
                                GroupHeader(group: group, state: vm.checkState(for: group.items)) { vm.toggleAll(group.items) }
                                ForEach(group.items) { item in
                                    ArtifactRow(item: item, showsEcosystem: vm.grouping == .project,
                                                checked: vm.checked.contains(item.id),
                                                recent: vm.isRecent(item)) { vm.toggle(item.id) }
                                }
                            }
                        }
                    }
                    .card(padding: 0)
                }
            }
            .padding(Theme.Metrics.contentPadding)

            SelectionBar(state: stateFor(allItems), toggleAll: { vm.toggleAll(allItems) },
                         count: vm.checked.count, selection: "**\(vm.checked.count) targets** selected", size: vm.selectedSize,
                         reclaim: "**\(ByteFormat.string(vm.selectedSize))** will be reclaimed") {
                Button("Reveal in Finder") { Finder.reveal(vm.selectedItems.flatMap(\.targets)) }
                    .buttonStyle(.dkSecondary)
                    .disabled(vm.checked.isEmpty)
                Button {
                    app.requestCleanup(vm.cleanupRequest())
                } label: {
                    Label("Clean Builds", systemImage: "delete.left")
                }
                .buttonStyle(.dkDanger)
                .disabled(vm.checked.isEmpty)
                .keyboardShortcut(.delete, modifiers: .command)
            }
        }
        .onAppear { vm.applyDefaults() }
        .onChange(of: store.artifacts.count) { vm.applyDefaults() }
    }

    private func stateFor(_ items: [ArtifactItem]) -> CheckState {
        app.artifactsVM.checkState(for: items)
    }
}

private struct GroupHeader: View {
    let group: ArtifactsViewModel.Group
    let state: CheckState
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Badge(text: group.badge, color: Color(hex: group.color), size: 24, fontSize: 10)
            Text(group.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text(group.subtitle).font(Theme.mono(11.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Spacer()
            SizeText(bytes: group.size, size: 11.5, weight: .regular, color: Theme.textSecondary)
            CheckBox(state: state, size: 14, action: toggle)
                .help("Select or deselect this group")
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Color.white.opacity(0.025))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

private struct ArtifactRow: View {
    let item: ArtifactItem
    let showsEcosystem: Bool
    let checked: Bool
    let recent: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            CheckBox(isOn: checked, action: toggle)
                .padding(.leading, 18)
            if showsEcosystem {
                Badge(text: item.ecosystem.badge, color: item.ecosystem.color, size: 20, fontSize: 9)
            }
            Text(item.projectName)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 210, alignment: .leading)
                .lineLimit(1)
            Text(item.displayPath)
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.targets.map(\.path).joined(separator: "\n"))
            Spacer(minLength: 12)
            if recent {
                StatusPill(text: "ACTIVE", color: Theme.success)
                    .help("Changed recently. Cleaning it needs an extra confirmation.")
            }
            if item.optIn {
                StatusPill(text: "OPT-IN", color: Theme.warning)
                    .help(item.note ?? String(localized: "Unchecked by default"))
            }
            Text(item.optIn ? String(localized: "risky", comment: "Build artifact: may not be rebuildable") : String(localized: "rebuildable", comment: "Build artifact: rebuilt by its toolchain"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 80, alignment: .leading)
            SizeText(bytes: item.size)
                .frame(width: 80, alignment: .trailing)
                .padding(.trailing, 16)
        }
        .frame(height: 38)
        .background(checked ? Theme.rowSelected : (hovering ? Theme.rowHover : .clear))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Reveal in Finder") { Finder.reveal(item.targets) }
            if !item.isGlobal { Button("Reveal Project") { Finder.reveal([item.projectURL]) } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}
