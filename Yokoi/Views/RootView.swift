import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(Theme.Metrics.sidebarWidth)
        } detail: {
            ZStack(alignment: .bottom) {
                Theme.bgWindow.ignoresSafeArea()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let activity = app.activity {
                    CleanupOverlay(activity: activity)
                        .transition(.opacity)
                        .zIndex(10)
                }
                if let toast = app.toast {
                    ToastView(toast: toast) { app.toast = nil }
                        .padding(.bottom, 84)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .id(toast.id)
                }
            }
            .animation(.snappy, value: app.toast)
            .animation(.easeInOut(duration: 0.25), value: app.activity?.id)
            .ignoresSafeArea(.container, edges: .top)
        }
        .toolbar(removing: .sidebarToggle)
        .background(Theme.bgWindow)
        .sheet(item: $app.pendingCleanup) { request in
            ConfirmCleanupSheet(request: request)
        }
        .sheet(isPresented: $app.showOutcomeDetails) {
            if let outcome = app.lastOutcome { OutcomeSheet(outcome: outcome) }
        }
        .sheet(isPresented: $app.showOnboarding) {
            OnboardingSheet()
        }
        .sheet(item: Binding(get: { app.tools.pending }, set: { app.tools.pending = $0 })) { status in
            ToolActionSheet(status: status)
        }
        .background {
            // ⌘K focuses the search field.
            Button("Search") { app.searchFocusToken += 1 }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in app.settings.refreshDrives() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in app.settings.refreshDrives() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.refreshFullDiskAccess()
            app.store.refreshDisk()
        }
    }

    @ViewBuilder private var detail: some View {
        switch app.screen {
        case .dashboard: DashboardView()
        case .nodeModules: NodeModulesView()
        case .buildArtifacts: BuildArtifactsView()
        case .caches: CachesView()
        case .bigFiles: BigFilesView()
        case .screenshots: ScreenshotsView()
        case .applications: ApplicationsView()
        case .externalDrives: ExternalDrivesView()
        case .packageManagers: PackageManagersView()
        case .settings: SettingsView()
        }
    }
}

// MARK: - Header

/// The 52pt screen header: title, subtitle, search (⌘K) and trailing actions.
struct HeaderBar<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var showsSearch = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                if showsSearch { SearchField() }
                trailing()
            }
            .padding(.horizontal, Theme.Metrics.contentPadding)
            .frame(height: Theme.Metrics.headerHeight)
            .padding(.top, 8)
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}

extension HeaderBar where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, showsSearch: Bool = true) {
        self.init(title: title, subtitle: subtitle, showsSearch: showsSearch) { EmptyView() }
    }
}

struct SearchField: View {
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var app = app
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            TextField("Search", text: $app.search)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit { focused = false }
            if app.search.isEmpty {
                Text("⌘K")
                    .font(Theme.mono(10, .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.12)))
            } else {
                Button { app.search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 280, height: 30)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(focused ? Theme.accent.opacity(0.6) : Color.white.opacity(0.08)))
        .onChange(of: app.searchFocusToken) { focused = true }
    }
}

// MARK: - Bottom selection bar

/// `☑ 9 folders selected  5.86 GB  will be reclaimed      [Reveal in Finder] [Delete node_modules]`
struct SelectionBar<Actions: View>: View {
    let state: CheckState
    let toggleAll: () -> Void
    let count: Int
    let noun: String
    let size: Int64
    var sizeSuffix = "will be reclaimed"
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(spacing: 12) {
                CheckBox(state: state, action: toggleAll)
                HStack(spacing: 5) {
                    Text("\(count) \(noun)").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("selected").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
                if !sizeSuffix.isEmpty && (size > 0 || count > 0) {
                    Text(ByteFormat.string(size))
                        .font(Theme.mono(14, .bold))
                        .foregroundStyle(Theme.accentLight)
                        .padding(.leading, 6)
                    Text(sizeSuffix).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                actions()
            }
            .padding(.horizontal, Theme.Metrics.contentPadding)
            .frame(height: 58)
            .background(Color.white.opacity(0.015))
        }
    }
}

// MARK: - Scan progress strip

struct ScanProgressStrip: View {
    @Environment(AppModel.self) private var app
    var category: CleanCategory?

    var body: some View {
        let store = app.store
        if store.isScanning && (category == nil || store.scanningCategories.contains(category!)) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Scanning")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(CountFormat.compact(store.progress.filesVisited)) files · \(store.progress.itemsFound) found")
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.textSecondary)
                Text(PathFormat.abbreviate(store.progress.currentPath))
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Stop") { store.cancelScan() }.buttonStyle(DKButtonStyle(kind: .secondary, compact: true))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accent.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.accent.opacity(0.25)))
        }
    }
}

// MARK: - Toast

struct ToastView: View {
    let toast: Toast
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.kind == .success ? "checkmark.circle.fill" : toast.kind == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(toast.kind == .success ? Theme.success : toast.kind == .warning ? Theme.warning : Theme.info)
            Text(toast.message).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
            if let detail = toast.detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            if toast.kind == .warning {
                Button("Details") { dismiss(); app.showOutcomeDetails = true }
                    .buttonStyle(DKButtonStyle(kind: .secondary, compact: true))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        .task {
            try? await Task.sleep(for: .seconds(toast.kind == .warning ? 8 : 4))
            dismiss()
        }
    }

    @Environment(AppModel.self) private var app
}
