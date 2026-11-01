import Charts
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let store = app.store
        VStack(spacing: 0) {
            HeaderBar(title: "Dashboard") {
                if store.isScanning {
                    Button { store.cancelScan() } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.dkSecondary)
                } else {
                    Button { store.scan() } label: {
                        Label("Scan", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.dkSecondary)
                }
            }
            ScrollView {
                VStack(spacing: Theme.Metrics.cardGap) {
                    if !app.fullDiskAccess { FullDiskAccessBanner() }
                    ScanProgressStrip()
                    kpis
                    HStack(alignment: .top, spacing: Theme.Metrics.cardGap) {
                        VStack(spacing: Theme.Metrics.cardGap) {
                            CategoryRingCard()
                            TopOffendersCard()
                        }
                        .frame(maxWidth: .infinity)
                        RecentCleanupsCard()
                            .frame(width: 340)
                    }
                    UpdateStatusBar()
                }
                .padding(Theme.Metrics.contentPadding)
            }
        }
    }

    private var kpis: some View {
        let store = app.store
        let summary = store.lastScan
        let roots = app.settings.data.scanRoots.filter { !ProjectWalker.isSystemRoot($0) }.map(\.path)
        return HStack(spacing: Theme.Metrics.cardGap) {
            KPITile(label: "Reclaimable", value: ByteFormat.string(store.reclaimableTotal)) {
                if let prev = summary?.previousReclaimable {
                    let delta = store.reclaimableTotal - prev
                    HStack(spacing: 4) {
                        Image(systemName: delta >= 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").font(.system(size: 9))
                        Text("\(ByteFormat.string(abs(delta))) since last scan")
                    }
                    .foregroundStyle(delta >= 0 ? Theme.success : Theme.textSecondary)
                } else {
                    Text("across \(CleanCategory.allCases.count - 1) categories").foregroundStyle(Theme.textSecondary)
                }
            }
            KPITile(label: "Projects scanned", value: store.projectCount.formatted()) {
                Text(roots.prefix(3).joined(separator: " · ") + (roots.count > 3 ? " +\(roots.count - 3)" : ""))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            KPITile(label: "Last scan", value: store.isScanning ? "scanning…" : RelativeDate.ago(summary?.date)) {
                if let summary {
                    Text("took \(String(format: "%.1f", summary.duration))s · \(CountFormat.compact(summary.filesVisited)) files")
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text("no scan yet").foregroundStyle(Theme.textSecondary)
                }
            }
            KPITile(label: "Freed all-time", value: ByteFormat.string(store.freedAllTime)) {
                Text("across \(store.cleanupCount) cleanup\(store.cleanupCount == 1 ? "" : "s")")
                    .foregroundStyle(Theme.accentLight)
            }
        }
    }
}

struct KPITile<Footer: View>: View {
    let label: String
    let value: String
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(Theme.mono(24, .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            footer().font(.system(size: 11.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Ring

struct CategoryRingCard: View {
    @Environment(AppModel.self) private var app

    private struct Slice: Identifiable {
        let category: CleanCategory
        let size: Int64
        var id: String { category.rawValue }
    }

    var body: some View {
        let store = app.store
        // node_modules belongs to the package managers (npm, pnpm, yarn, bun), so it's counted in that row
        // together with unused global packages. External drives are a different disk and stay out.
        let shown: [CleanCategory] = [.packages, .buildArtifacts, .caches, .bigFiles, .downloads, .screenshots, .applications]
        let slices = shown.map { c in
            Slice(category: c, size: c == .packages ? store.total(.nodeModules) + store.total(.packages) : store.total(c))
        }
        let total = store.reclaimableTotal
        let maxSize = max(slices.map(\.size).max() ?? 1, 1)
        let smart = store.smartSelection()
        let smartSize = smart.reduce(0) { $0 + $1.size }

        HStack(alignment: .center, spacing: 22) {
            ZStack {
                if total > 0 {
                    Chart(slices.filter { $0.size > 0 }) { slice in
                        SectorMark(angle: .value("Size", slice.size), innerRadius: .ratio(0.8), angularInset: 1.2)
                            .foregroundStyle(slice.category.color)
                    }
                    .chartLegend(.hidden)
                } else {
                    Circle().stroke(Color.white.opacity(0.07), lineWidth: 22).padding(11)
                }
                VStack(spacing: 2) {
                    Text("reclaimable").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    let parts = ByteFormat.parts(total)
                    Text(parts.number).font(Theme.mono(26, .bold)).foregroundStyle(Theme.textPrimary)
                    Text("\(parts.unit) of \(ByteFormat.string(store.disk.used))")
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(width: 190, height: 190)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(ByteFormat.string(total)) reclaimable")

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Reclaimable by category").font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        .fixedSize()
                    Spacer()
                    StatusPill(text: "SMART SELECT", color: Theme.accentLight)
                        .help("Clean selects stale node_modules, artifacts of inactive projects and Safe caches.")
                }
                .padding(.bottom, 10)
                ForEach(slices) { slice in
                    Button {
                        // Package managers opens on the npm tab's node_modules view.
                        app.screen = slice.category == .packages ? .nodeModules : screen(for: slice.category)
                    } label: {
                        HStack(spacing: 10) {
                            Circle().fill(slice.category.color).frame(width: 8, height: 8)
                            Text(slice.category.title).font(.system(size: 13.5)).foregroundStyle(Theme.textPrimary)
                                .fixedSize()
                            Spacer(minLength: 12)
                            SizeBar(fraction: Double(slice.size) / Double(maxSize), color: slice.category.color)
                                .frame(minWidth: 40, maxWidth: 96)
                            SizeText(bytes: slice.size)
                                .frame(width: 76, alignment: .trailing)
                        }
                        .frame(height: 34)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(slice.category == .packages ? "node_modules folders (npm, pnpm, yarn, bun) plus global packages unused for a year" : "")
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
                HStack(spacing: 10) {
                    Button { app.store.scan() } label: {
                        Label(app.store.isScanning ? "Scanning…" : "Scan Again", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.dkPrimary)
                    .disabled(app.store.isScanning)
                    Button {
                        app.requestCleanup(CleanupRequest(
                            title: "Clean \(smart.count) smart-selected item\(smart.count == 1 ? "" : "s")?",
                            restoreHint: "Only stale node_modules, artifacts of inactive projects and Safe caches. All of it can be rebuilt or re-downloaded.",
                            entries: smart))
                    } label: {
                        Label("Clean · \(ByteFormat.string(smartSize))", systemImage: "delete.left")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.dkDanger)
                    .disabled(smart.isEmpty || app.store.isScanning)
                }
                .padding(.top, 18)
            }
        }
        .padding(6)
        .card(padding: 20)
    }

    private func screen(for category: CleanCategory) -> Screen {
        switch category {
        case .nodeModules: .nodeModules
        case .buildArtifacts: .buildArtifacts
        case .caches: .caches
        case .bigFiles: .bigFiles
        case .downloads: .downloads
        case .screenshots: .screenshots
        case .applications: .applications
        case .externalDrives: .externalDrives
        case .packages: .packageManagers
        }
    }
}

// MARK: - Top offenders

struct TopOffendersCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let store = app.store
        let artifact = store.artifacts.max { $0.size < $1.size }
        let file = store.bigFiles.max { $0.size < $1.size }
        let stalest = store.nodeModules.filter { $0.lastTouched != nil }.min { $0.lastTouched! < $1.lastTouched! }

        VStack(alignment: .leading, spacing: 14) {
            Text("Top offenders").font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            HStack(spacing: 12) {
                OffenderTile(label: "Largest artifact",
                             badge: artifact.map { ($0.ecosystem.shortName.uppercased(), $0.ecosystem.color) },
                             name: artifact.map { $0.isGlobal ? $0.projectURL.lastPathComponent + "/" : $0.projectName + "/" },
                             size: artifact?.size) { app.screen = .buildArtifacts }
                OffenderTile(label: "Largest file",
                             badge: file.map { ($0.badge, $0.kind.color) },
                             name: file?.name,
                             size: file?.size) { app.screen = .bigFiles }
                OffenderTile(label: "Stalest project",
                             badge: stalest.map { (Self.age($0.lastTouched), Theme.warning) },
                             name: stalest.map { $0.projectURL.lastPathComponent + "/" },
                             size: stalest?.size) { app.screen = .nodeModules }
            }
        }
        .card(padding: 20)
    }

    static func age(_ date: Date?) -> String {
        guard let date else { return "?" }
        let days = Int(Date().timeIntervalSince(date) / 86_400)
        if days >= 365 { return "\(days / 365)Y" }
        if days >= 30 { return "\(days / 30)MO" }
        return "\(days)D"
    }
}

private struct OffenderTile: View {
    let label: String
    let badge: (String, Color)?
    let name: String?
    let size: Int64?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(label).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    if let badge { StatusPill(text: badge.0, color: badge.1) }
                }
                Text(name ?? "—").font(Theme.mono(12.5)).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                Text(size.map(ByteFormat.string) ?? " ").font(Theme.mono(17, .bold)).foregroundStyle(Theme.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.18)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(name == nil)
    }
}

// MARK: - Recent cleanups

struct RecentCleanupsCard: View {
    @Environment(AppModel.self) private var app
    @State private var showAll = false

    var body: some View {
        let batches = app.store.records.batches
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent cleanups").font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button(showAll ? "Show less" : "View all →") { showAll.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .opacity(batches.count > 6 ? 1 : 0)
            }
            .padding(.bottom, 10)

            if batches.isEmpty {
                Text("Nothing cleaned yet. Cleanups show up here and in the log.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, 18)
            }
            ForEach(showAll ? batches : Array(batches.prefix(6))) { batch in
                RecentCleanupRow(batch: batch, dateLabel: dateLabel(batch.date))
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                    Text("Next scheduled scan").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Theme.textPrimary)
                Text(scheduleLine)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textSecondary)
                if !app.settings.data.autoScan {
                    Button("Turn on in Settings") { app.screen = .settings }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.accentLight)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: [Theme.accent.opacity(0.12), Theme.accent2.opacity(0.05)], startPoint: .leading, endPoint: .trailing)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent.opacity(0.25)))
            .padding(.top, 18)

            Button {
                Finder.reveal([app.store.logURL])
            } label: {
                Label("Reveal cleanup log", systemImage: "doc.text.magnifyingglass")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .padding(.top, 12)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card(padding: 20)
    }

    private var scheduleLine: String {
        let d = app.settings.data
        guard let next = app.scheduler.nextScan else { return "Automatic scans are off" }
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        var parts = [f.string(from: next), d.scanFrequency.rawValue]
        if d.showInMenuBar { parts.append("menu bar helper active") }
        return parts.joined(separator: " · ")
    }

    private func dateLabel(_ date: Date) -> String {
        let r = RelativeDate.string(date)
        return r == "Today" || r == "Yesterday" ? r : RelativeDate.short(date)
    }
}

// MARK: - Version and updates

/// The bottom of the dashboard: the running version, and whether a newer one is out.
/// Quiet when up to date; tinted with the accent and offering "Update…" when there's a new version.
struct UpdateStatusBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let updater = app.updater
        let available: String? = if case .available(let version) = updater.status { version } else { nil }

        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                Text("Yokoi").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Tag(text: updater.currentVersion)
            }
            Rectangle().fill(Theme.hairline).frame(width: 1, height: 18)
            status(updater)
            Spacer(minLength: 12)
            actions(updater, available: available)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            if available != nil {
                shape.fill(LinearGradient(colors: [Theme.accent.opacity(0.16), Theme.accent2.opacity(0.06)],
                                          startPoint: .leading, endPoint: .trailing))
            } else {
                shape.fill(Color.black.opacity(0.18))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(available != nil ? Theme.accent.opacity(0.35) : Color.white.opacity(0.04))
        }
        .animation(.easeOut(duration: 0.25), value: updater.status)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func status(_ updater: Updater) -> some View {
        HStack(spacing: 7) {
            switch updater.status {
            case .development:
                Image(systemName: "hammer").foregroundStyle(Theme.textTertiary)
                Text("Development build").foregroundStyle(Theme.textSecondary)
            case .off:
                Circle().fill(Theme.textTertiary).frame(width: 7, height: 7)
                Text("Automatic update checks are off").foregroundStyle(Theme.textSecondary)
            case .checking:
                ProgressView().controlSize(.mini)
                Text("Checking for updates…").foregroundStyle(Theme.textSecondary)
            case .upToDate:
                Circle().fill(Theme.success).frame(width: 7, height: 7)
                Text("Up to date").foregroundStyle(Theme.success).fontWeight(.medium)
                if let at = updater.checkedAt {
                    TimelineView(.everyMinute) { context in
                        Text("· checked \(RelativeDate.ago(at, now: context.date))").foregroundStyle(Theme.textTertiary)
                    }
                }
            case .available(let version):
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accentLight)
                Text("Yokoi \(version) is available").foregroundStyle(Theme.textPrimary).fontWeight(.semibold)
                StatusPill(text: "NEW", color: Theme.accentLight)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                Text("Couldn't check for updates").foregroundStyle(Theme.textSecondary)
            }
        }
        .font(.system(size: 12.5))
        .lineLimit(1)
    }

    @ViewBuilder private func actions(_ updater: Updater, available: String?) -> some View {
        if available != nil {
            HStack(spacing: 8) {
                Link("What's new", destination: URL(string: "https://github.com/indieocean/yokoi/releases/latest")!)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Button("Update…") { updater.checkForUpdates() }
                    .buttonStyle(DKButtonStyle(kind: .primary, compact: true))
                    .disabled(!updater.canCheckForUpdates)
            }
        } else if updater.isAvailable && updater.status != .checking {
            Button(updater.status == .failed ? "Try Again" : "Check Now") { updater.refreshStatus() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accentLight)
                .disabled(!updater.canCheckForUpdates)
        }
    }
}

struct FullDiskAccessBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield").font(.system(size: 18)).foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Full Disk Access is off").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("Some caches and folders can't be measured. Yokoi still works, but results may be incomplete.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button("Open System Settings") { FullDiskAccess.openSystemSettings() }.buttonStyle(.dkSecondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.warning.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.warning.opacity(0.3)))
    }
}

private struct RecentCleanupRow: View {
    @Environment(AppModel.self) private var app
    let batch: CleanupBatch
    let dateLabel: String
    @State private var hovering = false
    @State private var working = false

    var body: some View {
        HStack(spacing: 12) {
            Badge(text: batch.category.badge, color: batch.category.color, size: 28, fontSize: 10.5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(batch.title).font(.system(size: 13.5)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if batch.restored { Tag(text: "restored") }
                }
                Text(dateLabel).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            if batch.canPutBack && (hovering || working) {
                Button(working ? "…" : "Put Back") {
                    working = true
                    Task {
                        await app.putBack(batch)
                        working = false
                    }
                }
                .buttonStyle(DKButtonStyle(kind: .secondary, compact: true))
                .disabled(working)
                .help("Move these items out of the Trash, back where they were")
            }
            Text(batch.action == "move" || batch.restored ? ByteFormat.string(batch.size) : "-" + ByteFormat.string(batch.size))
                .font(Theme.mono(12.5, .medium))
                .foregroundStyle(batch.action == "move" || batch.restored ? Theme.textSecondary : Theme.success)
                .strikethrough(batch.restored)
                .frame(width: 72, alignment: .trailing)
        }
        .frame(height: 50)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if batch.canPutBack { Button("Put Back") { Task { await app.putBack(batch) } } }
            Button("Reveal Log") { Finder.reveal([app.store.logURL]) }
        }
    }
}
