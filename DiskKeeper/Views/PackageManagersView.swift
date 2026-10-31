import SwiftUI

/// Global packages for npm, pnpm, Homebrew, Casks, Cargo, pip and gem (PRD §5.7, mockup 07).
struct PackageManagersView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var pm = app.packages
        let rows = pm.visible(search: app.search)
        let busy = pm.loading.contains(pm.selected)
        let readOnly = pm.readOnly[pm.selected]

        VStack(spacing: 0) {
            HeaderBar(title: "Package Managers", subtitle: pm.installed.isEmpty ? nil : pm.selected.title) {
                Button {
                    Task { await pm.checkOutdated(pm.selected) }
                } label: {
                    Label("Check for Updates", systemImage: "arrow.up.circle")
                }
                .buttonStyle(.dkSecondary)
                .disabled(busy || pm.installed.isEmpty)
                .help("Asks the package registry for newer versions")
                Button {
                    Task { await pm.refresh(pm.selected) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.dkPrimary)
                .disabled(busy || pm.installed.isEmpty)
            }

            VStack(spacing: 14) {
                if !pm.detected || (pm.installed.isEmpty && busy) {
                    ProgressView("Looking for package managers…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if pm.installed.isEmpty {
                    EmptyStateView(symbol: "cube.box", title: "No package managers found",
                                   message: "Disk Keeper looks for npm, pnpm, Homebrew, Cargo, pip and gem on your login shell's PATH.")
                        .card()
                } else {
                    HStack(spacing: 12) {
                        SegmentedTabs(selection: Binding(get: { pm.selected }, set: { k in Task { await pm.select(k) } }),
                                      items: pm.installed.map { .init(value: $0, title: $0.title, count: pm.count($0).map(String.init)) })
                        Spacer()
                        Text("Show").font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                        SegmentedTabs(selection: $pm.filter, items: [
                            .init(value: .all, title: "All"),
                            .init(value: .outdated, title: "Outdated", count: "\(pm.outdatedCount)"),
                            .init(value: .unused, title: "Unused", count: "\(pm.unusedCount)"),
                        ], compact: true)
                    }

                    TerminalStrip(result: pm.lastCommand, busy: busy, outdated: pm.outdatedCount, unused: pm.unusedCount,
                                  checked: pm.checkedOutdated.contains(pm.selected))

                    if let readOnly {
                        Label(readOnly, systemImage: "lock")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.warning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let error = pm.errorMessage {
                        Text(error).font(Theme.mono(11.5)).foregroundStyle(Theme.warning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Table(rows) {
                        TableColumn("") { p in
                            CheckBox(isOn: pm.checked.contains(p.id)) { pm.toggle(p.id) }.disabled(readOnly != nil)
                        }
                        .width(24)
                        TableColumn("Package") { p in
                            Text(p.name).font(Theme.mono(13, .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        }
                        .width(min: 180)
                        TableColumn("Installed") { p in
                            Text(p.installedVersion).font(Theme.mono(12.5)).foregroundStyle(Theme.textPrimary)
                        }
                        .width(110)
                        TableColumn("Latest") { p in
                            if let latest = p.latestVersion {
                                Text(p.isOutdated ? "→ \(latest)" : latest)
                                    .font(Theme.mono(12.5))
                                    .foregroundStyle(p.isOutdated ? Theme.success : Theme.textTertiary)
                            } else {
                                Text("—").foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .width(120)
                        TableColumn("Status") { p in
                            HStack(spacing: 4) {
                                switch p.status {
                                case .outdated: StatusPill(text: "OUTDATED", color: Theme.warning)
                                case .upToDate: StatusPill(text: "UP TO DATE", color: Theme.success)
                                case .unknown: EmptyView()
                                }
                                if p.isUnused { StatusPill(text: "UNUSED", color: Theme.danger) }
                            }
                        }
                        .width(180)
                        TableColumn("Last used") { p in
                            Text(p.lastUsed.map { RelativeDate.string($0) } ?? "—")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                                .help("Approximate: from when its command was last run")
                        }
                        .width(100)
                        TableColumn("Size") { p in
                            Text(p.size.map(ByteFormat.string) ?? "—").font(Theme.mono(12, .medium))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .width(80)
                        TableColumn("") { p in
                            Button(p.isOutdated ? "Update" : "Uninstall") {
                                pm.request(p.isOutdated ? .update : .uninstall, [p])
                            }
                            .buttonStyle(DKButtonStyle(kind: .secondary, compact: true))
                            .disabled(readOnly != nil || busy)
                        }
                        .width(90)
                    }
                    .tableStyle(.inset(alternatesRowBackgrounds: false))
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 36)
                    .overlay { if busy && rows.isEmpty { ProgressView() } }
                    .card(padding: 4)
                }
            }
            .padding(Theme.Metrics.contentPadding)

            let selected = pm.selectedPackages
            SelectionBar(state: selected.isEmpty ? .off : (selected.count == rows.count ? .on : .mixed),
                         toggleAll: {
                             let ids = Set(rows.map(\.id))
                             if ids.isSubset(of: pm.checked) { pm.checked.subtract(ids) } else { pm.checked.formUnion(ids) }
                         },
                         count: selected.count, noun: "", size: 0, sizeSuffix: "") {
                Button("Uninstall…") { pm.request(.uninstall, selected) }
                    .buttonStyle(.dkSecondary)
                    .disabled(selected.isEmpty || readOnly != nil)
                Button {
                    pm.request(.update, selected.filter(\.isOutdated))
                } label: {
                    Label("Update Selected", systemImage: "arrow.up")
                }
                .buttonStyle(.dkPrimary)
                .disabled(!selected.contains(where: \.isOutdated) || readOnly != nil)
            }
        }
        .task { await pm.loadIfNeeded() }
        .sheet(item: $pm.pending) { action in PackageActionSheet(action: action) }
    }
}

private struct TerminalStrip: View {
    let result: ProcessRunner.Result?
    let busy: Bool
    let outdated: Int
    let unused: Int
    let checked: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("$").font(Theme.mono(13, .bold)).foregroundStyle(Theme.success)
            if let result {
                Text(result.commandLine).font(Theme.mono(12.5)).foregroundStyle(Theme.textPrimary).lineLimit(1).textSelection(.enabled)
                Text("· \(result.succeeded ? "resolved" : "exit \(result.exitCode)") in \(String(format: "%.1f", result.duration))s")
                    .font(Theme.mono(11.5)).foregroundStyle(Theme.textSecondary)
            } else {
                Text(busy ? "running…" : "nothing run yet").font(Theme.mono(12.5)).foregroundStyle(Theme.textSecondary)
            }
            if busy { ProgressView().controlSize(.small) }
            Spacer()
            if checked { StatusPill(text: "\(outdated) OUTDATED", color: Theme.warning) }
            if unused > 0 { StatusPill(text: "\(unused) UNUSED > 1Y", color: Theme.danger) }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.3)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.cardStroke))
    }
}

/// Lists the packages, version changes and exact commands; nothing runs until confirmed (FR-P6).
struct PackageActionSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let action: PackagesStore.PendingAction
    @State private var started = false

    var body: some View {
        let pm = app.packages
        VStack(alignment: .leading, spacing: 14) {
            Text("\(action.action.rawValue) \(CountFormat.plural(action.packages.count, "package"))?")
                .font(.system(size: 17, weight: .semibold))
            Text(action.action == .update ? "Each package is updated to its latest version." : "These packages are removed from \(action.kind.title).")
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(zip(action.packages, action.commands)), id: \.0.id) { pkg, command in
                        HStack {
                            Text(pkg.name).font(Theme.mono(12.5, .medium))
                            if action.action == .update, let latest = pkg.latestVersion {
                                Text("\(pkg.installedVersion) → \(latest)").font(Theme.mono(12)).foregroundStyle(Theme.success)
                            }
                            Spacer()
                            if let log = pm.runLog.first(where: { $0.package == pkg.name }) {
                                Image(systemName: log.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                    .foregroundStyle(log.succeeded ? Theme.success : Theme.danger)
                            }
                        }
                        Text("$ " + command.map(ProcessRunner.quote).joined(separator: " "))
                            .font(Theme.mono(11.5)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .frame(maxHeight: 180)
            .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.25)))

            if started {
                Text("Output").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                ScrollView {
                    Text(pm.runLog.map { log in
                        "▸ \(log.package)\n" + (log.error ?? ((log.result?.stdout ?? "") + (log.result?.stderr ?? "")))
                    }.joined(separator: "\n"))
                    .font(Theme.mono(11))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
                }
                .frame(height: 160)
                .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.35)))
            }

            HStack {
                if pm.running { ProgressView().controlSize(.small); Text("Running…").font(.system(size: 12.5)) }
                Spacer()
                Button(started && !pm.running ? "Done" : "Cancel") { dismiss() }
                    .buttonStyle(.dkSecondary)
                    .disabled(pm.running)
                    .keyboardShortcut(.cancelAction)
                if !started {
                    Button(action.action == .update ? "Update" : "Uninstall") {
                        started = true
                        Task { await pm.perform(action) }
                    }
                    .buttonStyle(action.action == .update ? DKButtonStyle(kind: .primary) : DKButtonStyle(kind: .danger))
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 600)
        .background(Color(hex: 0x1A1D27))
        .interactiveDismissDisabled(pm.running)
    }
}
