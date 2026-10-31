import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(title: "Settings", showsSearch: false)
            ScrollView {
                HStack(alignment: .top, spacing: Theme.Metrics.cardGap) {
                    VStack(spacing: Theme.Metrics.cardGap) {
                        ScanLocationsCard()
                        SafetyCard()
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: Theme.Metrics.cardGap) {
                        ScreenshotSettingsCard()
                        ScheduleCard()
                        AboutCard()
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(Theme.Metrics.contentPadding)
            }
        }
    }
}

// MARK: - Shared bits

private struct CardTitle: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            if let subtitle { Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    var divider = true
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5)).foregroundStyle(Theme.textPrimary)
                    if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.textSecondary) }
                }
                Spacer()
                control()
            }
            .padding(.vertical, 12)
            if divider { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
    }
}

private struct ChipView: View {
    let text: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(Theme.mono(11.5)).foregroundStyle(Theme.textPrimary)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityLabel("Remove \(text)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.cardStroke))
    }
}

/// Wraps chips onto multiple lines.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Scan locations + exclusions

private struct ScanLocationsCard: View {
    @Environment(AppModel.self) private var app
    @State private var newExclusion = ""

    var body: some View {
        let settings = app.settings
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "Scan locations", subtitle: "Where Yokoi looks for projects and artifacts")
            VStack(spacing: 6) {
                ForEach(settings.data.scanRoots) { root in
                    HStack(spacing: 10) {
                        Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Theme.accentLight)
                        Text(root.path).font(Theme.mono(12.5)).foregroundStyle(Theme.textPrimary)
                        if !FileManager.default.fileExists(atPath: root.url(home: FileManager.default.homeDirectoryForCurrentUser).path) {
                            StatusPill(text: "MISSING", color: Theme.warning)
                        }
                        Spacer()
                        if ProjectWalker.isSystemRoot(root) {
                            Text("system").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                                .help("Cleanup location only; not walked for projects")
                        } else {
                            Menu {
                                Button("Unlimited") { settings.setDepth(nil, for: root) }
                                ForEach([2, 3, 4, 6, 8], id: \.self) { d in
                                    Button("\(d) levels") { settings.setDepth(d, for: root) }
                                }
                            } label: {
                                Text(root.maxDepth.map { "depth \($0)" } ?? "depth ∞").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            }
                            .menuStyle(.button)
                            .buttonStyle(.plain)
                            .menuIndicator(.hidden)
                            .fixedSize()
                        }
                        Button { settings.removeScanRoot(root) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.textSecondary)
                            .accessibilityLabel("Remove \(root.path)")
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 7).fill(.black.opacity(0.2)))
                }
            }
            Button {
                if let url = Finder.chooseFolder(title: "Add a scan location", prompt: "Add") { settings.addScanRoot(url) }
            } label: {
                Label("Add Folder…", systemImage: "plus")
            }
            .buttonStyle(.dkSecondary)

            CardTitle(title: "Big file locations", subtitle: "Searched for large files (Downloads, Movies, VMs…)")
                .padding(.top, 10)
            FlowLayout {
                ForEach(settings.data.bigFileRoots, id: \.self) { path in
                    ChipView(text: path) { settings.data.bigFileRoots.removeAll { $0 == path } }
                }
                Button {
                    if let url = Finder.chooseFolder(title: "Add a big-file location", prompt: "Add") { settings.addBigFileRoot(url) }
                } label: {
                    Label("Add", systemImage: "plus").font(.system(size: 12))
                }
                .buttonStyle(DKButtonStyle(kind: .secondary, compact: true))
            }

            CardTitle(title: "Excluded", subtitle: "Paths and globs never scanned or touched (e.g. ~/Dropbox, **/.git, *.keep)")
                .padding(.top, 10)
            FlowLayout {
                ForEach(settings.data.exclusions, id: \.self) { pattern in
                    ChipView(text: pattern) { settings.removeExclusion(pattern) }
                }
            }
            HStack(spacing: 8) {
                TextField("~/work/acme/prod-*", text: $newExclusion)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(12))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.cardStroke))
                    .onSubmit(addExclusion)
                Button("Add", action: addExclusion).buttonStyle(DKButtonStyle(kind: .secondary, compact: true))
                Button {
                    if let url = Finder.chooseFolder(title: "Exclude a folder", prompt: "Exclude") {
                        settings.addExclusion(PathFormat.abbreviate(url))
                    }
                } label: { Image(systemName: "folder") }
                .buttonStyle(DKButtonStyle(kind: .secondary, compact: true))
                .help("Pick a folder to exclude")
            }
        }
        .card(padding: 22)
    }

    private func addExclusion() {
        app.settings.addExclusion(newExclusion)
        newExclusion = ""
    }
}

// MARK: - Safety

private struct SafetyCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        VStack(alignment: .leading, spacing: 4) {
            CardTitle(title: "Safety")
            SettingRow(title: "Default delete action", subtitle: "Preselected in the confirmation sheet") {
                SegmentedTabs(selection: $settings.data.defaultDeleteMode, items: [
                    .init(value: .trash, title: "Trash"),
                    .init(value: .permanent, title: "Permanent"),
                ], compact: true)
            }
            SettingRow(title: "Protect projects touched within", subtitle: "Unselected by default and need an extra confirmation") {
                daysMenu(value: settings.data.protectRecentDays, options: [7, 14, 30, 60, 90]) { settings.data.protectRecentDays = $0 }
            }
            SettingRow(title: "Stale after", subtitle: "node_modules untouched this long are marked stale") {
                daysMenu(value: settings.data.staleDays, options: [30, 60, 90, 180, 365]) { settings.data.staleDays = $0 }
            }
            SettingRow(title: "Dry run", subtitle: "Show what would happen without changing anything") {
                Toggle("", isOn: $settings.data.dryRun).toggleStyle(.dk).fixedSize()
            }
            SettingRow(title: "Skip confirmation for Safe caches", subtitle: "Trash only. Never applies to permanent delete", divider: false) {
                Toggle("", isOn: $settings.data.skipConfirmForSafe).toggleStyle(.dk).fixedSize()
            }
        }
        .card(padding: 22)
    }
}

@MainActor
private func daysMenu(value: Int, options: [Int], set: @escaping @MainActor (Int) -> Void) -> some View {
    Menu {
        ForEach(options, id: \.self) { d in Button("\(d) days") { set(d) } }
    } label: {
        HStack(spacing: 6) {
            Text("\(value) days").font(Theme.mono(12.5, .medium)).foregroundStyle(Theme.textPrimary)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.cardStroke))
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
}

// MARK: - Screenshots

private struct ScreenshotSettingsCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        let detected = PathFormat.abbreviate(ScreenshotScanner.systemScreenshotFolder())
        VStack(alignment: .leading, spacing: 4) {
            CardTitle(title: "Screenshots")
            SettingRow(title: "Screenshot folder", subtitle: settings.data.screenshotFolderOverride == nil ? "Detected from macOS: \(detected)" : "Custom") {
                HStack(spacing: 8) {
                    Text(settings.data.screenshotFolderOverride ?? detected).font(Theme.mono(12)).foregroundStyle(Theme.textPrimary)
                    Button("Change…") {
                        if let url = Finder.chooseFolder(title: "Where are your screenshots?") {
                            settings.data.screenshotFolderOverride = PathFormat.abbreviate(url)
                        }
                    }
                    .buttonStyle(DKButtonStyle(kind: .secondary, compact: true))
                    if settings.data.screenshotFolderOverride != nil {
                        Button("Reset") { settings.data.screenshotFolderOverride = nil }
                            .buttonStyle(DKButtonStyle(kind: .ghost, compact: true))
                    }
                }
            }
            SettingRow(title: "Move to", subtitle: settings.data.screenshotOrganizeByDate ? "Into YYYY/MM subfolders" : "One folder") {
                HStack(spacing: 8) {
                    Text(settings.data.screenshotDestination).font(Theme.mono(12)).foregroundStyle(Theme.textPrimary)
                    Button("Change…") {
                        if let url = Finder.chooseFolder(title: "Move screenshots to…") {
                            settings.data.screenshotDestination = PathFormat.abbreviate(url)
                        }
                    }
                    .buttonStyle(DKButtonStyle(kind: .secondary, compact: true))
                }
            }
            SettingRow(title: "Organize by date") {
                Toggle("", isOn: $settings.data.screenshotOrganizeByDate).toggleStyle(.dk).fixedSize()
            }
            SettingRow(title: "Highlight older than", divider: false) {
                daysMenu(value: settings.data.screenshotAgeDays, options: [1, 3, 7, 14, 30]) { settings.data.screenshotAgeDays = $0 }
            }
        }
        .card(padding: 22)
    }
}

// MARK: - Schedule (v1.1)

private struct ScheduleCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        VStack(alignment: .leading, spacing: 4) {
            CardTitle(title: "Schedule & menu bar")
            Group {
                SettingRow(title: "Automatic scan", subtitle: "Runs in the background, low priority") {
                    Toggle("", isOn: $settings.data.autoScan).toggleStyle(.dk).fixedSize()
                }
                SettingRow(title: "Frequency") {
                    SegmentedTabs(selection: $settings.data.scanFrequency, items: [
                        .init(value: .daily, title: "Daily"), .init(value: .weekly, title: "Weekly"), .init(value: .monthly, title: "Monthly"),
                    ], compact: true)
                }
                SettingRow(title: "Auto-clean safe caches", subtitle: "npm, pip, Homebrew, browser caches") {
                    Toggle("", isOn: $settings.data.autoCleanSafeCaches).toggleStyle(.dk).fixedSize()
                }
                SettingRow(title: "Notify when reclaimable exceeds", subtitle: "Checked after each scheduled scan") {
                    Menu {
                        ForEach([10, 25, 50, 100, 200], id: \.self) { gb in Button("\(gb) GB") { settings.data.notifyThresholdGB = gb } }
                        Button("Never") { settings.data.notifyThresholdGB = 0 }
                    } label: {
                        Text(settings.data.notifyThresholdGB == 0 ? "Never" : "\(settings.data.notifyThresholdGB) GB")
                            .font(Theme.mono(12.5, .medium)).foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.cardStroke))
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                }
                SettingRow(title: "Show in menu bar", subtitle: "Free space + one-click clean") {
                    Toggle("", isOn: $settings.data.showInMenuBar).toggleStyle(.dk).fixedSize()
                }
                SettingRow(title: "Launch at login", subtitle: app.scheduler.loginItemError, divider: false) {
                    Toggle("", isOn: Binding(get: { settings.data.launchAtLogin }, set: { on in
                        settings.data.launchAtLogin = on
                        app.scheduler.setLaunchAtLogin(on)
                    }))
                    .toggleStyle(.dk).fixedSize()
                }
            }
        }
        .card(padding: 22)
        .onChange(of: settings.data.autoScan) { _, on in
            if on { Task { await app.scheduler.requestNotificationPermission() } }
        }
    }
}

private struct AboutCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "Privacy & logs", subtitle: "100% local. No network calls, no telemetry.")
            HStack(spacing: 8) {
                Button("Reveal Cleanup Log") { Finder.reveal([app.store.logURL]) }.buttonStyle(DKButtonStyle(kind: .secondary, compact: true))
                Button(app.fullDiskAccess ? "Full Disk Access: On" : "Grant Full Disk Access…") { FullDiskAccess.openSystemSettings() }
                    .buttonStyle(DKButtonStyle(kind: .secondary, compact: true))
            }
            Text(PathFormat.abbreviate(app.store.logURL)).font(Theme.mono(11)).foregroundStyle(Theme.textTertiary).textSelection(.enabled)
        }
        .card(padding: 22)
    }
}
