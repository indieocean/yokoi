import QuickLookThumbnailing
import SwiftUI

struct ScreenshotsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var vm = app.screenshotsVM
        let store = app.store
        let items = vm.items(search: app.search)
        let folder = PathFormat.abbreviate(app.settings.context().screenshotFolder)

        VStack(spacing: 0) {
            HeaderBar(title: "Screenshots",
                      subtitle: "\(store.screenshots.count) in \(folder) · \(ByteFormat.string(store.total(.screenshots)))") {
                Button("Select older than \(app.settings.data.screenshotAgeDays)d") { vm.selectOlderThanThreshold() }
                    .buttonStyle(.dkSecondary)
                RescanButton(category: .screenshots)
            }

            HStack(alignment: .top, spacing: Theme.Metrics.cardGap) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        SegmentedTabs(selection: $vm.tab, items: [
                            .init(value: .screenshots, title: "Screenshots", count: "\(vm.screenshotCount)"),
                            .init(value: .recordings, title: "Recordings", count: "\(vm.recordingCount)"),
                        ])
                        HStack(spacing: 4) {
                            Text("Older than").foregroundStyle(Theme.textSecondary)
                            Text("\(app.settings.data.screenshotAgeDays) days").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                            Text("highlighted").foregroundStyle(Theme.textSecondary)
                        }
                        .font(.system(size: 13))
                        Spacer()
                        Button(items.allSatisfy { vm.checked.contains($0.id) } && !items.isEmpty ? "Deselect all" : "Select all") { vm.toggleAll(items) }
                            .buttonStyle(.dkGhost)
                            .disabled(items.isEmpty)
                    }
                    if items.isEmpty {
                        EmptyStateView(symbol: "camera.viewfinder",
                                       title: vm.tab == .screenshots ? "No screenshots in \(folder)" : "No screen recordings",
                                       message: "Disk Keeper looks in the folder macOS saves screenshots to. Change it in Settings.")
                            .card()
                    } else {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14)], spacing: 14) {
                                ForEach(items) { item in
                                    ScreenshotCell(item: item, checked: vm.checked.contains(item.id), old: vm.isOld(item)) { vm.toggle(item.id) }
                                }
                            }
                            .padding(2)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                ActionPanel()
                    .frame(width: 340)
            }
            .padding(Theme.Metrics.contentPadding)
        }
    }
}

private struct ScreenshotCell: View {
    let item: ScreenshotItem
    let checked: Bool
    let old: Bool
    let toggle: () -> Void
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [Theme.accent.opacity(0.3), Theme.accent2.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(Image(systemName: item.isRecording ? "video" : "photo").foregroundStyle(.white.opacity(0.5)))
                }
            }
            .frame(height: 118)
            .frame(maxWidth: .infinity)
            .clipped()

            HStack {
                Text(Self.caption(item.created)).font(Theme.mono(11))
                Spacer()
                Text(compactSize(item.size)).font(Theme.mono(10.5)).foregroundStyle(.white.opacity(0.65))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
        }
        .overlay(alignment: .topLeading) {
            CheckBox(isOn: checked, size: 16, action: toggle).padding(8)
        }
        .overlay(alignment: .topTrailing) {
            if old {
                Text("\(item.ageInDays())d")
                    .font(Theme.mono(10, .bold))
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .padding(8)
                    .help("Older than the highlight threshold")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(checked ? Theme.accent : (hovering ? Color.white.opacity(0.2) : Color.white.opacity(0.08)), lineWidth: checked ? 2.5 : 1)
        )
        .opacity(old || checked ? 1 : 0.75)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Reveal in Finder") { Finder.reveal([item.url]) }
            Button("Open") { NSWorkspace.shared.open(item.url) }
        }
        .help(item.title)
        .task(id: item.id) { thumbnail = await ThumbnailCache.shared.thumbnail(for: item.url) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(checked ? [.isSelected, .isButton] : .isButton)
    }

    static func caption(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH.mm"
        return f.string(from: date)
    }

    private func compactSize(_ bytes: Int64) -> String {
        let (n, u) = ByteFormat.parts(bytes)
        return n + String(u.prefix(1))
    }
}

private struct ActionPanel: View {
    @Environment(AppModel.self) private var app
    @State private var running = false

    var body: some View {
        @Bindable var vm = app.screenshotsVM
        @Bindable var settings = app.settings
        let count = vm.checked.count
        let noun = vm.tab == .recordings ? "Recording" : "Screenshot"

        VStack(alignment: .leading, spacing: 14) {
            Text("Action").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)

            RadioCard(selected: vm.action == .move, title: "Move to folder…", subtitle: settings.data.screenshotOrganizeByDate ? "Organize by date" : "Keep in one folder") {
                vm.action = .move
                settings.data.screenshotAutoAction = .move
            } extra: {
                VStack(alignment: .leading, spacing: 10) {
                    Text(vm.destinationPreview)
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 7).fill(.black.opacity(0.25)))
                    HStack {
                        Button("Choose…") {
                            if let url = Finder.chooseFolder(title: "Move screenshots to…", startingAt: vm.destination) {
                                settings.data.screenshotDestination = PathFormat.abbreviate(url)
                            }
                        }
                        .buttonStyle(DKButtonStyle(kind: .secondary, compact: true))
                        Spacer()
                        Toggle("YYYY/MM", isOn: $settings.data.screenshotOrganizeByDate)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))
                            .help("Sort into year/month subfolders")
                    }
                }
                .padding(.top, 6)
            }

            RadioCard(selected: vm.action == .delete, title: "Delete", subtitle: "Move to Trash") {
                vm.action = .delete
                settings.data.screenshotAutoAction = .delete
            } extra: { EmptyView() }

            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 4)

            HStack {
                Text("Auto rule").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Toggle("", isOn: Binding(get: { settings.data.screenshotAutoRule }, set: { on in
                    settings.data.screenshotAutoAction = vm.action == .delete ? .delete : .move
                    settings.data.screenshotAutoRule = on
                }))
                .toggleStyle(.dk).fixedSize()
                .accessibilityLabel("Auto rule")
            }
            Text(settings.data.screenshotAutoAction == .delete && settings.data.screenshotAutoRule
                 ? "Every day, move screenshots older than \(settings.data.screenshotAgeDays) days to the Trash. Logged like any cleanup."
                 : "Every day, move screenshots older than \(settings.data.screenshotAgeDays) days to the folder above. Logged like any cleanup.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button {
                if vm.action == .delete {
                    app.requestCleanup(vm.deleteRequest())
                } else {
                    running = true
                    Task {
                        await app.run(vm.entries, action: vm.moveAction)
                        running = false
                    }
                }
            } label: {
                Text(running ? "Working…" : (vm.action == .move ? "Move \(count) \(noun)\(count == 1 ? "" : "s")" : "Delete \(count) \(noun)\(count == 1 ? "" : "s")"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .buttonStyle(vm.action == .move ? DKButtonStyle(kind: .primary) : DKButtonStyle(kind: .danger))
            .disabled(count == 0 || running)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card(padding: 20)
    }
}

struct RadioCard<Extra: View>: View {
    let selected: Bool
    let title: String
    let subtitle: String
    var titleColor: Color = Theme.textPrimary
    let action: () -> Void
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: action) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle().strokeBorder(selected ? Theme.accent : Color.white.opacity(0.25), lineWidth: 1.5)
                        if selected { Circle().fill(Theme.accent).padding(5) }
                    }
                    .frame(width: 18, height: 18)
                    .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(titleColor)
                        Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if selected { extra().padding(.leading, 30) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.accent.opacity(0.1) : Color.white.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Theme.accent.opacity(0.7) : Theme.cardStroke, lineWidth: selected ? 1.5 : 1))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// QuickLook thumbnails, cached in memory.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [URL: NSImage] = [:]

    func thumbnail(for url: URL) async -> NSImage? {
        if let hit = cache[url] { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 220, height: 140), scale: 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = rep.nsImage
        cache[url] = image
        return image
    }
}
