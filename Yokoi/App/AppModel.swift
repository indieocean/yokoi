import Foundation
import Observation

enum Screen: String, CaseIterable, Identifiable, Hashable {
    case dashboard, nodeModules, buildArtifacts, caches, bigFiles, duplicates, downloads, screenshots, applications, externalDrives, packageManagers, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .nodeModules: "node_modules"
        case .buildArtifacts: "Build Artifacts"
        case .caches: "Caches & Tooling"
        case .bigFiles: "Big Files"
        case .duplicates: "Duplicates"
        case .downloads: "Downloads"
        case .screenshots: "Screenshots"
        case .applications: "Applications"
        case .externalDrives: "External Drives"
        case .packageManagers: "Package Managers"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .nodeModules: "shippingbox"
        case .buildArtifacts: "hammer"
        case .caches: "archivebox"
        case .bigFiles: "externaldrive.badge.exclamationmark"
        case .duplicates: "doc.on.doc"
        case .downloads: "arrow.down.circle"
        case .screenshots: "camera.viewfinder"
        case .applications: "app.dashed"
        case .externalDrives: "externaldrive.connected.to.line.below"
        case .packageManagers: "cube.box"
        case .settings: "gearshape"
        }
    }

    var category: CleanCategory? {
        switch self {
        case .nodeModules: .nodeModules
        case .buildArtifacts: .buildArtifacts
        case .caches: .caches
        case .bigFiles: .bigFiles
        case .duplicates: .duplicates
        case .downloads: .downloads
        case .screenshots: .screenshots
        case .applications: .applications
        case .externalDrives: .externalDrives
        default: nil
        }
    }
}

/// A pending cleanup waiting for the confirmation sheet (PRD §5.8).
struct CleanupRequest: Identifiable {
    struct Blocked: Identifiable {
        let entry: CleanupEntry
        let process: String
        var id: String { entry.id }
    }

    let id = UUID()
    let title: String
    /// e.g. "You can restore them anytime with `npm install`."
    let restoreHint: String
    var entries: [CleanupEntry]
    /// Items refused because a running process is using them (open projects, running apps).
    var blocked: [Blocked] = []
    /// Only permanent delete is offered (emptying the Trash).
    var forcePermanent = false
    var confirmVerb: String? = nil
    /// A cleanup the owning tool performs (`docker`, `xcrun simctl`, `tmutil`) instead of Yokoi moving files.
    /// Always permanent: the tool deletes them, so they can't go to the Trash.
    var tool: ToolActionStatus? = nil

    var totalSize: Int64 { entries.reduce(0) { $0 + $1.size } }
    var fileCount: Int { entries.reduce(0) { $0 + $1.fileCount } }
    /// "Don't ask again" is only offered when everything is Safe-level (and never for permanent delete).
    var allSafe: Bool { entries.allSatisfy { $0.safety == .safe && $0.category == .caches } }
}

struct Toast: Identifiable, Equatable {
    enum Kind { case success, warning, info }
    let id = UUID()
    let kind: Kind
    let message: String
    var detail: String? = nil
}

/// Top-level app state: navigation, search, the shared store and one view model per screen.
@MainActor
@Observable
final class AppModel {
    let settings: SettingsStore
    let store: ScanStore

    var screen: Screen = .dashboard {
        didSet {
            // node_modules lives in Package Managers → npm (the old screen id still works for deep links).
            if screen == .nodeModules {
                packages.selected = .npm
                packages.npmMode = .projects
                screen = .packageManagers
                return
            }
            if screen != oldValue { search = "" }
        }
    }
    var search = ""
    /// Bumped by ⌘K; the search field focuses itself when it changes.
    var searchFocusToken = 0
    var pendingCleanup: CleanupRequest?
    var lastOutcome: CleanupOutcome?
    var showOutcomeDetails = false
    var toast: Toast?
    /// The cleanup currently shown in the progress overlay.
    var activity: CleanupActivity?
    var showOnboarding = false
    /// True while the main window is on screen. With it closed, the menu bar item is the only way in.
    var isMainWindowOpen = false
    var fullDiskAccess = FullDiskAccess.isGranted

    let nodeModulesVM: NodeModulesViewModel
    let artifactsVM: ArtifactsViewModel
    let cachesVM: CachesViewModel
    let bigFilesVM: BigFilesViewModel
    let duplicatesVM: DuplicatesViewModel
    let screenshotsVM: ScreenshotsViewModel
    let downloadsVM: DownloadsViewModel
    let applicationsVM: ApplicationsViewModel
    let packages: PackagesStore
    let tools: ToolActionsModel
    let scheduler: BackgroundScheduler
    let drivesVM: ExternalDrivesViewModel
    let updater: Updater

    init() {
        let demo = DemoData.isEnabled
        if !demo { LegacyMigration.run() }
        let settings = demo ? SettingsStore(defaults: DemoData.defaults()) : SettingsStore()
        if demo { settings.demoDrives = DemoData.drives }
        self.settings = settings
        let store = ScanStore(settings: settings, demo: demo)
        self.store = store
        nodeModulesVM = NodeModulesViewModel(store: store)
        artifactsVM = ArtifactsViewModel(store: store)
        cachesVM = CachesViewModel(store: store)
        bigFilesVM = BigFilesViewModel(store: store)
        duplicatesVM = DuplicatesViewModel(store: store)
        screenshotsVM = ScreenshotsViewModel(store: store)
        downloadsVM = DownloadsViewModel(store: store)
        applicationsVM = ApplicationsViewModel(store: store)
        packages = PackagesStore(store: store)
        tools = ToolActionsModel(store: store)
        scheduler = BackgroundScheduler(settings: settings, store: store)
        drivesVM = ExternalDrivesViewModel(settings: settings)
        updater = Updater(demo: demo)
        settings.loadDrivesAtLaunch()
        if demo { fullDiskAccess = true }
        showOnboarding = !fullDiskAccess && !settings.data.hasCompletedOnboarding
        scheduler.configure()
        if !demo { scheduler.refreshLoginItem() }
        IntentRouter.attach(self)
        AppDelegate.model = self
    }

    func onLaunch() {
        if !store.hasResults && !showOnboarding { store.scan() }
    }

    func refreshFullDiskAccess() {
        if store.isDemo { return }
        fullDiskAccess = FullDiskAccess.isGranted
    }

    func finishOnboarding() {
        settings.data.hasCompletedOnboarding = true
        showOnboarding = false
        refreshFullDiskAccess()
        if !store.hasResults { store.scan() }
    }

    func rescan() {
        if screen == .externalDrives { settings.refreshDrives(); return }
        if screen == .packageManagers {
            if packages.showingProjects { store.scan([.nodeModules]) } else { Task { await packages.refresh(packages.selected) } }
            return
        }
        if let category = screen.category { store.scan([category]) } else { store.scan() }
    }

    // MARK: Cleanup flow

    /// Opens the confirmation sheet, or runs straight away for Safe caches when "Don't ask again" is on.
    /// Items used by a running process (open projects, running apps) are moved to a "blocked" list first.
    func requestCleanup(_ request: CleanupRequest) {
        guard !request.entries.isEmpty else { return }
        Task {
            let (allowed, blocked) = await Self.splitInUse(request.entries)
            var request = request
            request.entries = allowed
            request.blocked = blocked
            if blocked.isEmpty && request.allSafe && !request.forcePermanent
                && settings.data.skipConfirmForSafe && settings.data.defaultDeleteMode == .trash {
                await run(request.entries, action: .trash)
                return
            }
            pendingCleanup = request
        }
    }

    /// Separates entries whose project or app is in use by a running process.
    nonisolated static func splitInUse(_ entries: [CleanupEntry]) async -> ([CleanupEntry], [CleanupRequest.Blocked]) {
        let split = await InUseSnapshot.split(entries)
        return (split.allowed, split.blocked.map { .init(entry: $0.entry, process: $0.process) })
    }

    /// Runs a confirmed cleanup with the animated progress overlay.
    func run(_ entries: [CleanupEntry], action: CleanupAction) async {
        guard activity == nil || activity?.isFinished == true else { return }
        let activity = CleanupActivity(action: action, dryRun: settings.data.dryRun)
        self.activity = activity

        // Check again right before acting: something may have opened since the sheet appeared.
        let (entries, lateBlocked) = await Self.splitInUse(entries)
        activity.lateBlocked = lateBlocked

        let progress = CleanupProgress()
        if store.isDemo {
            await runDemo(entries, action: action, activity: activity, progress: progress)
            return
        }
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                activity.snapshot = progress.snapshot
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
        let outcome = await store.perform(entries, action: action, progress: progress)

        // Keep the animation on screen long enough to read, even for instant cleanups.
        let minimum: TimeInterval = 1.8
        let elapsed = Date().timeIntervalSince(activity.started)
        if elapsed < minimum { try? await Task.sleep(for: .seconds(minimum - elapsed)) }
        poll.cancel()
        activity.snapshot = progress.snapshot
        activity.outcome = outcome
        lastOutcome = outcome

        for vm in [nodeModulesVM as any SelectionPruning, artifactsVM, cachesVM, bigFilesVM, duplicatesVM, downloadsVM, screenshotsVM, applicationsVM] {
            vm.prune(outcome.completedIDs)
        }
    }

    func dismissActivity() {
        activity = nil
    }

    /// Demo mode: plays the real overlay with plausible paths. No file is touched.
    private func runDemo(_ entries: [CleanupEntry], action: CleanupAction, activity: CleanupActivity, progress: CleanupProgress) async {
        progress.begin(entries: entries.count, files: entries.reduce(0) { $0 + $1.fileCount }, bytes: entries.reduce(0) { $0 + $1.size })
        let perStep = max(0.02, 3.2 / Double(max(entries.count * 14, 1)))
        for entry in entries {
            progress.startEntry(label: entry.label)
            for path in DemoData.files(in: entry) {
                progress.touched(path, countsAsFile: true)
                progress.addFiles(max(0, entry.fileCount / 14 - 1))
                activity.snapshot = progress.snapshot
                try? await Task.sleep(for: .seconds(perStep))
            }
            progress.finishEntry(bytes: entry.size, files: entry.fileCount, filesAlreadyCounted: entry.fileCount, failed: false)
        }
        try? await Task.sleep(for: .milliseconds(300))
        activity.snapshot = progress.snapshot
        activity.outcome = CleanupOutcome(batchID: "demo", action: action, dryRun: false, records: [], failures: [],
                                          completedIDs: Set(entries.map(\.id)), bytes: entries.reduce(0) { $0 + $1.size })
    }
}

extension AppModel {
    func putBack(_ batch: CleanupBatch) async {
        let outcome = await store.putBack(batch)
        lastOutcome = outcome
        if outcome.failures.isEmpty {
            toast = Toast(kind: .success, message: "Put back \(CountFormat.plural(outcome.records.count, "item")) · \(ByteFormat.string(outcome.bytes))",
                          detail: "Rescan to see them again")
        } else {
            toast = Toast(kind: .warning, message: "Put back \(CountFormat.plural(outcome.records.count, "item"))",
                          detail: "\(outcome.failures.count) couldn't be restored")
        }
    }

    /// Opens the main window's confirmation sheet for Safe caches (used by the menu bar helper).
    func requestSafeCacheClean() {
        let entries = store.caches.filter { $0.safety == .safe && $0.size > 0 && !$0.permanentOnly }
            .map { CleanupEntry($0, displayPath: PathFormat.abbreviate($0.url) + "/*") }
        screen = .caches
        requestCleanup(CleanupRequest(title: "Clear \(CountFormat.plural(entries.count, "Safe cache"))?",
                                      restoreHint: "Tools refill these caches as needed.", entries: entries))
    }
}

/// View models that track a selection drop cleaned items from it.
@MainActor
protocol SelectionPruning: AnyObject {
    func prune(_ ids: Set<String>)
}
