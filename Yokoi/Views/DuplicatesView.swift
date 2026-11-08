import QuickLook
import SwiftUI

struct DuplicatesView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var vm = app.duplicatesVM
        let store = app.store
        let groups = vm.groups(search: app.search)
        let total = store.duplicatesReclaimable
        let selected = vm.selectedItems

        VStack(spacing: 0) {
            HeaderBar(title: "Duplicates", subtitle: "\(subtitle(count: vm.groups.count, total: total))") {
                if store.duplicateFolder != nil {
                    Button {
                        vm.checked = []
                        store.findDuplicates(in: nil)
                    } label: {
                        Label("All Locations", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.dkSecondary)
                    .disabled(store.isScanning)
                    .help("Go back to looking through all your big-file locations")
                }
                Button {
                    chooseFolder()
                } label: {
                    Label("Choose Folder…", systemImage: "folder")
                }
                .buttonStyle(.dkSecondary)
                .disabled(store.isScanning)
                .help("Looks through one folder, including copies that are all inside git repositories")
                RescanButton(category: .duplicates)
            }

            VStack(spacing: 14) {
                ScanProgressStrip(category: .duplicates)

                if vm.groups.isEmpty {
                    if !store.scanningCategories.contains(.duplicates) { emptyState.card() }
                    if !store.duplicateSkips.isEmpty { SkippedFilesCard(files: store.duplicateSkips) }
                    Spacer(minLength: 0)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(groups) { DuplicateGroupCard(group: $0) }
                            if !store.duplicateSkips.isEmpty { SkippedFilesCard(files: store.duplicateSkips) }
                        }
                    }
                }
            }
            .padding(Theme.Metrics.contentPadding)

            SelectionBar(state: vm.checkState(for: groups), toggleAll: { vm.toggleExtras(groups) },
                         count: selected.count, selection: "**\(selected.count) copies** selected", size: vm.selectedSize,
                         reclaim: "**\(ByteFormat.string(vm.selectedSize))** will be reclaimed") {
                Button {
                    vm.toggleExtras(groups)
                } label: {
                    Label("Select Extras", systemImage: "checklist")
                }
                .buttonStyle(.dkSecondary)
                .disabled(groups.isEmpty)
                .help("Picks every copy but the best one in each group, leaving copies in git repositories alone")
                Button("Reveal in Finder") { Finder.reveal(selected.map(\.url)) }
                    .buttonStyle(.dkSecondary)
                    .disabled(selected.isEmpty)
                Button {
                    app.requestCleanup(vm.cleanupRequest())
                } label: {
                    Label("Move to Trash", systemImage: "delete.left")
                }
                .buttonStyle(.dkDanger)
                .disabled(selected.isEmpty)
                .keyboardShortcut(.delete, modifiers: .command)
            }
        }
        .quickLookPreview($vm.previewURL)
    }

    private func subtitle(count: Int, total: Int64) -> String {
        let size = ByteFormat.string(total)
        if let folder = app.store.duplicateFolder {
            return String(localized: "\(PathFormat.abbreviate(folder)) · \(count) files · \(size)",
                          comment: "Duplicates subtitle: scanned folder path, file count, reclaimable size")
        }
        return String(localized: "\(count) files · \(size)", comment: "Duplicates subtitle: file count, reclaimable size")
    }

    private func chooseFolder() {
        guard let folder = Finder.chooseFolder(title: String(localized: "Choose a folder to look through for duplicates"), prompt: String(localized: "Scan Folder", comment: "Folder picker button")) else { return }
        if let why = app.settings.context().duplicateFolderRefusal(folder) {
            app.toast = Toast(kind: .warning, message: String(localized: "Can't scan that folder"), detail: why)
            return
        }
        app.duplicatesVM.checked = []
        app.store.findDuplicates(in: folder)
    }

    @ViewBuilder private var emptyState: some View {
        if app.store.lastScanned(.duplicates) == nil {
            EmptyStateView(symbol: "doc.on.doc", title: "Find duplicate files",
                           message: "Compares files over 1 MB in your big-file locations (Settings → Big file locations). This reads the files, so it can take a while.",
                           actionTitle: "Find Duplicates") { app.store.scan([.duplicates]) }
        } else if let folder = app.store.duplicateFolder {
            EmptyStateView(symbol: "doc.on.doc", title: "No duplicates found",
                           message: "No two files over 1 MB in \(PathFormat.abbreviate(folder)) have the same contents.")
        } else {
            EmptyStateView(symbol: "doc.on.doc", title: "No duplicates found",
                           message: "No two files over 1 MB in your big-file locations have the same contents. Copies that are all inside git repositories aren't listed: use Choose Folder to look through one.")
        }
    }
}

/// Files the scan couldn't compare, so nobody takes "no duplicates" to include them.
private struct SkippedFilesCard: View {
    let files: [SkippedFile]
    /// A cloud-synced Documents folder can hold thousands of these.
    private let limit = 200

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(files.prefix(limit)) { file in
                    HStack(spacing: 12) {
                        Text(PathFormat.abbreviate(file.url))
                            .font(Theme.mono(11.5)).foregroundStyle(Theme.textSecondary)
                            .lineLimit(1).truncationMode(.middle)
                            .help(file.url.path)
                        Spacer(minLength: 12)
                        Text(file.reason.label).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                        Button { Finder.reveal([file.url]) } label: { Image(systemName: "magnifyingglass") }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.textSecondary)
                            .help("Reveal in Finder")
                    }
                }
                if files.count > limit {
                    Text("and \(files.count - limit) more").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(files.count) files not checked")
                    .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("These may have copies that aren't listed.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        }
        .card(padding: 14)
    }
}

private struct DuplicateGroupCard: View {
    @Environment(AppModel.self) private var app
    let group: DuplicateGroup

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Badge(text: group.badge, color: CleanCategory.duplicates.color, size: 30, fontSize: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Text("\(group.files.count) copies · \(ByteFormat.string(group.fileSize)) each")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 12)
                SizeText(bytes: group.reclaimable, size: 13, weight: .semibold, color: Theme.accentLight)
                Text("reclaimable").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ForEach(group.files) { DuplicateCopyRow(file: $0, group: group) }
        }
        .card(padding: 14)
    }
}

private struct DuplicateCopyRow: View {
    @Environment(AppModel.self) private var app
    let file: DuplicateFile
    let group: DuplicateGroup

    var body: some View {
        let vm = app.duplicatesVM
        HStack(spacing: 12) {
            if vm.isLastCopy(file, in: group) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 16)
                    .help("One copy always stays")
                    .accessibilityLabel("Kept: one copy always stays")
            } else {
                CheckBox(isOn: vm.checked.contains(file.id)) { vm.toggle(file, in: group) }
            }
            Text(PathFormat.abbreviate(file.url))
                .font(Theme.mono(11.5)).foregroundStyle(Theme.textSecondary)
                .lineLimit(1).truncationMode(.middle)
                .help(file.url.path)
            if let repository = file.repository {
                Text("git repo")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.warning)
                    .help("Part of \(PathFormat.abbreviate(repository)), which may need this file")
            }
            Spacer(minLength: 12)
            Text(RelativeDate.short(file.modified)).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
            SizeText(bytes: file.size)
                .frame(width: 72, alignment: .trailing)
                .help(file.size < file.fileSize ? "Shares storage with another file, so removing it frees less than its length" : "Freed by removing this copy")
            Button { Finder.reveal([file.url]) } label: { Image(systemName: "magnifyingglass") }
                .help("Reveal in Finder")
            Button { vm.previewURL = file.url } label: { Image(systemName: "eye") }
                .help("Quick Look")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textSecondary)
        .frame(height: 24)
    }
}
