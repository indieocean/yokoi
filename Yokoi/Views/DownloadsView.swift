import QuickLook
import SwiftUI

/// Everything in `~/Downloads`, one row per file or folder. Old items (untouched for N days) count as
/// reclaimable; leftovers (incomplete downloads, extracted archives, installers) get a note.
struct DownloadsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var vm = app.downloadsVM
        let store = app.store
        let rows = vm.rows(search: app.search)
        let totals = vm.totals

        VStack(spacing: 0) {
            HeaderBar(title: "Downloads",
                      subtitle: "\(totals.count) items · \(ByteFormat.string(totals.size))") {
                Button {
                    NSWorkspace.shared.open(vm.folder)
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
                .buttonStyle(.dkSecondary)
                RescanButton(category: .downloads)
            }

            VStack(spacing: 14) {
                ScanProgressStrip(category: .downloads)
                DownloadsSummaryCard()

                if store.downloads.isEmpty && !store.scanningCategories.contains(.downloads) {
                    EmptyStateView(symbol: "arrow.down.circle", title: "Downloads is empty",
                                   message: "Nothing in \(PathFormat.abbreviate(vm.folder)). Nice.")
                        .card()
                } else {
                    Table(rows, sortOrder: $vm.sortOrder) {
                        TableColumn("") { row in
                            CheckBox(isOn: vm.checked.contains(row.id)) { vm.toggle(row.id) }
                        }
                        .width(24)
                        TableColumn("") { row in
                            Badge(text: badge(row.item), color: Color(hex: row.item.kind.colorHex), size: 30, fontSize: 10)
                        }
                        .width(40)
                        TableColumn("Name", value: \.name) { row in
                            HStack(spacing: 8) {
                                Text(row.name).font(.system(size: 13.5))
                                    .foregroundStyle(row.isOld ? Theme.textPrimary : Theme.textSecondary)
                                    .lineLimit(1).truncationMode(.middle)
                                    .help(row.item.url.path)
                                if let note = row.item.note {
                                    StatusPill(text: note.localizedUppercase, color: noteColor(row.item))
                                }
                            }
                        }
                        .width(min: 220)
                        TableColumn("Kind", value: \.kind) { row in
                            Text(row.item.kind == .folder
                             ? String(localized: "Folder · \(CountFormat.compact(row.item.fileCount)) files",
                                      comment: "Kind column for a folder; placeholder is an abbreviated file count such as 412k")
                             : row.kind)
                                .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        .width(120)
                        TableColumn("Added", value: \.added) { row in
                            Text(RelativeDate.string(row.item.added))
                                .font(.system(size: 12.5))
                                .foregroundStyle(row.isOld ? Theme.warning : Theme.textSecondary)
                        }
                        .width(100)
                        TableColumn("Last opened", value: \.lastOpened) { row in
                            Text(row.item.lastOpened.map { RelativeDate.string($0) } ?? String(localized: "Never", comment: "Last opened: the download was never opened"))
                                .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
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
                         count: vm.checked.count, selection: "**\(vm.checked.count) items** selected", size: vm.selectedSize,
                         reclaim: "**\(ByteFormat.string(vm.selectedSize))** will be reclaimed") {
                Button {
                    if let dest = Finder.chooseFolder(title: String(localized: "Move \(vm.checked.count) downloads to…", comment: "Folder picker title"), prompt: String(localized: "Move Here", comment: "Folder picker button")) {
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

    private func badge(_ item: DownloadItem) -> String {
        if item.kind == .folder { return String(localized: "DIR", comment: "Short badge for a folder, at most 4 letters") }
        let ext = item.url.pathExtension.uppercased()
        return ext.isEmpty ? String(localized: "FILE", comment: "Short badge for a file without an extension, at most 4 letters") : String(ext.prefix(4))
    }

    private func noteColor(_ item: DownloadItem) -> Color {
        switch item.safety {
        case .safe: Theme.success
        case .redownload: Color(hex: DownloadKind.installer.colorHex)
        case .review: Theme.textSecondary
        }
    }
}

/// "38.2 GB untouched for 30+ days" with the age picker, quick selections and kind filters.
private struct DownloadsSummaryCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var vm = app.downloadsVM
        let totals = vm.totals
        let leftovers = vm.leftovers

        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 28) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Untouched for").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        Menu {
                            ForEach(DownloadsViewModel.ageOptions, id: \.self) { d in
                                Button(label(d)) { vm.ageDays = d }
                            }
                        } label: {
                            Text("\(label(vm.ageDays))+", comment: "Age threshold, e.g. 30 days+").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accentLight)
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        .help("Downloads not added or opened for this long count as reclaimable")
                    }
                    Text(ByteFormat.string(totals.oldSize))
                        .font(Theme.mono(22, .bold))
                        .foregroundStyle(Theme.accentLight)
                    Text("\(totals.oldCount) items of \(totals.count)")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                }
                .frame(width: 170, alignment: .leading)

                SizeBar(fraction: Double(totals.oldSize) / Double(max(totals.size, 1)), color: CleanCategory.downloads.color, height: 6)
                    .frame(maxWidth: 260)

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    Button("Select Leftovers · \(leftovers.count)") { vm.selectLeftovers() }
                        .buttonStyle(DKButtonStyle(kind: .secondary, compact: true))
                        .disabled(leftovers.isEmpty)
                        .help("Incomplete downloads, archives you already extracted, and installers")
                    Button("Select Old · \(totals.oldCount)") { vm.selectOld() }
                        .buttonStyle(DKButtonStyle(kind: .secondary, compact: true))
                        .disabled(totals.oldCount == 0)
                }
            }

            SegmentedTabs(selection: $vm.filter, items:
                [.init(value: .all, title: "All"), .init(value: .old, title: "Old")]
                + DownloadKind.filters.map { .init(value: .kind($0), verbatim: $0.filterTitle) },
                compact: true)
        }
        .card(padding: 18)
    }

    private func label(_ days: Int) -> String {
        switch days {
        case 7: String(localized: "1 week")
        case 14: String(localized: "2 weeks")
        case 30: String(localized: "30 days")
        case 60: String(localized: "60 days")
        case 90: String(localized: "3 months")
        case 180: String(localized: "6 months")
        case 365: String(localized: "1 year")
        default: String(localized: "\(days) days")
        }
    }
}
