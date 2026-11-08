import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class ExternalDrivesViewModel {
    var junk: [String: DriveJunk] = [:]
    var scanning: Set<String> = []
    var progress: [String: Int] = [:]
    var ejectError: String?
    /// Drives being unmounted right now (the button shows a spinner).
    var ejecting: Set<String> = []

    let settings: SettingsStore
    init(settings: SettingsStore) { self.settings = settings }

    var drives: [ExternalDrive] { settings.externalDrives }

    func isIncluded(_ drive: ExternalDrive) -> Bool {
        settings.data.scanRoots.contains { $0.path == drive.url.path }
    }

    /// Adds or removes the drive from scan locations and big-file locations.
    func setIncluded(_ on: Bool, _ drive: ExternalDrive) {
        let path = drive.url.path
        if on {
            if !settings.data.scanRoots.contains(where: { $0.path == path }) { settings.data.scanRoots.append(ScanRoot(path: path)) }
            if !settings.data.bigFileRoots.contains(path) { settings.data.bigFileRoots.append(path) }
        } else {
            settings.data.scanRoots.removeAll { $0.path == path }
            settings.data.bigFileRoots.removeAll { $0 == path }
        }
    }

    func scan(_ drive: ExternalDrive) async {
        if settings.demoDrives != nil { junk[drive.id] = DemoData.driveJunk; return }
        guard !scanning.contains(drive.id) else { return }
        scanning.insert(drive.id)
        let exclusions = settings.context().exclusions
        let tracker = ScanProgress()
        let poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.progress[drive.id] = tracker.snapshot.filesVisited
            }
        }
        let result = await Task.detached(priority: .userInitiated) {
            ExternalDrives.scanJunk(drive, exclusions: exclusions, progress: tracker)
        }.value
        poll.cancel()
        junk[drive.id] = result
        scanning.remove(drive.id)
    }

    func request(_ kind: String, _ drive: ExternalDrive) -> CleanupRequest? {
        guard let j = junk[drive.id] else { return nil }
        let urls: [URL], size: Int64, title: String, hint: String
        switch kind {
        case "trash":
            (urls, size) = (j.trashContents, j.trashSize)
            title = String(localized: "Empty the Trash on \(drive.name)?", comment: "Placeholder is a drive name")
            hint = String(localized: "Permanently deletes \(urls.count) items you already deleted from this drive.")
        case "ds":
            (urls, size) = (j.dsStores, j.dsStoreSize)
            title = String(localized: "Delete \(urls.count) .DS_Store files?")
            hint = String(localized: "Finder view settings. Finder recreates them as needed.")
        default:
            (urls, size) = (j.appleDoubles, j.appleDoubleSize)
            title = String(localized: "Delete \(urls.count) AppleDouble (._) files?")
            hint = String(localized: "Mac metadata copies on a non-Mac drive. Removing them drops Finder tags and comments for files on this drive.")
        }
        guard !urls.isEmpty else { return nil }
        let label: String
        switch kind {
        case "trash": label = String(localized: "\(drive.name) · Trash", comment: "Cleanup item: a drive's Trash; placeholder is the drive name")
        case "ds": label = "\(drive.name) · .DS_Store"
        default: label = String(localized: "\(drive.name) · ._ files", comment: "Cleanup item: AppleDouble files on a drive; placeholder is the drive name")
        }
        let entry = CleanupEntry(id: "\(drive.id)|\(kind)", category: .externalDrives, label: label,
                                 displayPath: drive.url.path + (kind == "trash" ? "/.Trashes/*" : kind == "ds" ? "/**/.DS_Store" : "/**/._*"),
                                 urls: urls, size: size, fileCount: urls.count, safety: .safe)
        return CleanupRequest(title: title, restoreHint: hint, entries: [entry], forcePermanent: true, confirmVerb: String(localized: "Delete", comment: "Confirm button verb"))
    }

    func clearResults(for drive: ExternalDrive) { junk[drive.id] = nil }

    /// Unmounts in the background: macOS flushes pending writes and waits for the disk first, which can take
    /// several seconds (it used to run on the main thread and froze the window meanwhile).
    func eject(_ drive: ExternalDrive) {
        if settings.demoDrives != nil || ejecting.contains(drive.id) { return }
        ejecting.insert(drive.id)
        ejectError = nil
        Task {
            do {
                try await FileManager.default.unmountVolume(at: drive.url, options: [.allPartitionsAndEjectDisk, .withoutUI])
                junk[drive.id] = nil
            } catch {
                ejectError = String(localized: "Couldn't eject \(drive.name): \(error.localizedDescription)", comment: "Placeholders are the drive name and the system error")
            }
            ejecting.remove(drive.id)
            settings.refreshDrives()
        }
    }
}

struct ExternalDrivesView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let vm = app.drivesVM
        VStack(spacing: 0) {
            HeaderBar(title: "External Drives", subtitle: "\(vm.drives.count) drives", showsSearch: false) {
                Button {
                    app.settings.refreshDrives()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.dkSecondary)
            }
            ScrollView {
                VStack(spacing: Theme.Metrics.cardGap) {
                    if let error = vm.ejectError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning).font(.system(size: 12.5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if vm.drives.isEmpty {
                        EmptyStateView(symbol: "externaldrive.badge.questionmark", title: "No external drives connected",
                                       message: "Plug in a USB, Thunderbolt or SD drive. Yokoi finds its Trash, .DS_Store and ._ files, and can include it in project and big-file scans.")
                            .card()
                    }
                    ForEach(vm.drives) { drive in
                        DriveCard(drive: drive)
                    }
                }
                .padding(Theme.Metrics.contentPadding)
            }
        }
        .onAppear { app.settings.refreshDrives() }
    }
}

private struct DriveCard: View {
    @Environment(AppModel.self) private var app
    let drive: ExternalDrive

    var body: some View {
        let vm = app.drivesVM
        let junk = vm.junk[drive.id]
        let scanning = vm.scanning.contains(drive.id)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Group {
                    if FileManager.default.fileExists(atPath: drive.url.path) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: drive.url.path)).resizable()
                    } else {
                        Image(systemName: "externaldrive.fill").resizable().scaledToFit()
                            .foregroundStyle(CleanCategory.externalDrives.color).padding(4)
                    }
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(drive.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Tag(text: drive.format)
                        if let reason = drive.lockReason { StatusPill(text: reason.localizedUppercase, color: Theme.textSecondary) }
                    }
                    Text(drive.url.path).font(Theme.mono(11.5)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                if drive.isEjectable {
                    let ejecting = vm.ejecting.contains(drive.id)
                    Button { vm.eject(drive) } label: {
                        if ejecting {
                            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Ejecting…") }
                        } else {
                            Label("Eject", systemImage: "eject")
                        }
                    }
                    .buttonStyle(DKButtonStyle(kind: .secondary, compact: true))
                    .disabled(ejecting || vm.scanning.contains(drive.id))
                    .help(vm.scanning.contains(drive.id) ? "Wait for the scan of this drive to finish" : "")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SizeBar(fraction: Double(drive.used) / Double(max(drive.total, 1)), color: CleanCategory.externalDrives.color, height: 6)
                HStack(spacing: 4) {
                    Text("\(ByteFormat.string(drive.used)) used ·").foregroundStyle(Theme.textSecondary)
                    Text("\(ByteFormat.string(drive.available)) free").foregroundStyle(Theme.success)
                    Text("of \(ByteFormat.string(drive.total))").foregroundStyle(Theme.textSecondary)
                }
                .font(Theme.mono(11))
            }

            if drive.canClean {
                HStack {
                    Toggle(isOn: Binding(get: { vm.isIncluded(drive) }, set: { vm.setIncluded($0, drive) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Include in scans").font(.system(size: 13.5)).foregroundStyle(Theme.textPrimary)
                            Text("Find node_modules, build artifacts and big files on this drive (shown in those screens)")
                                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .toggleStyle(.dk)
                }

                Rectangle().fill(Theme.hairline).frame(height: 1)

                HStack {
                    Text("Drive junk").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    if scanning {
                        ProgressView().controlSize(.small)
                        Text("\(CountFormat.compact(vm.progress[drive.id] ?? 0)) files").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                    } else if let junk {
                        (junk.truncated
                            ? Text("\(CountFormat.compact(junk.filesVisited)) files checked (stopped early)", comment: "Placeholder is an abbreviated file count such as 412k")
                            : Text("\(CountFormat.compact(junk.filesVisited)) files checked", comment: "Placeholder is an abbreviated file count such as 412k"))
                            .font(Theme.mono(11)).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    Button(junk == nil ? "Scan drive" : "Rescan") { Task { await vm.scan(drive) } }
                        .buttonStyle(DKButtonStyle(kind: .primary, compact: true))
                        .disabled(scanning)
                }

                if let junk {
                    junkRow("Trash on this drive", "Items deleted from \(drive.name) that are still taking space",
                            count: junk.trashContents.count, size: junk.trashSize, kind: "trash")
                    junkRow(".DS_Store files", "Finder view settings, recreated automatically",
                            count: junk.dsStores.count, size: junk.dsStoreSize, kind: "ds")
                    if !drive.isAppleFormat {
                        junkRow("AppleDouble ._ files", "Mac metadata copies on a \(drive.format) drive",
                                count: junk.appleDoubles.count, size: junk.appleDoubleSize, kind: "ad")
                    }
                }
            }
        }
        .card(padding: 20)
    }

    private func junkRow(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey, count: Int, size: Int64, kind: String) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5)).foregroundStyle(Theme.textPrimary)
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            (count == 0 ? Text("none", comment: "Drive junk row: nothing found") : Text("\(count) items")).font(Theme.mono(11.5)).foregroundStyle(Theme.textSecondary)
                .frame(width: 100, alignment: .trailing)
            SizeText(bytes: size).frame(width: 80, alignment: .trailing)
            Button("Delete…") {
                if let r = app.drivesVM.request(kind, drive) {
                    app.requestCleanup(r)
                }
            }
            .buttonStyle(DKButtonStyle(kind: .danger, compact: true))
            .disabled(count == 0)
        }
        .padding(.vertical, 4)
    }
}
