import Foundation
import Observation

enum Screen: String, CaseIterable, Identifiable, Hashable {
    case dashboard, nodeModules, buildArtifacts, caches, bigFiles, screenshots, applications, externalDrives, packageManagers, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .nodeModules: "node_modules"
        case .buildArtifacts: "Build Artifacts"
        case .caches: "Caches"
        case .bigFiles: "Big Files"
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
        didSet { if screen != oldValue { search = "" } }
    }
    var search = ""
    /// Bumped by ⌘K; the search field focuses itself when it changes.
    var searchFocusToken = 0
    var pendingCleanup: CleanupRequest?
    var lastOutcome: CleanupOutcome?
    var showOutcomeDetails = false
    var toast: Toast?
    var showOnboarding = false
    var fullDiskAccess = FullDiskAccess.isGranted

    let nodeModulesVM: NodeModulesViewModel
    let artifactsVM: ArtifactsViewModel
    let cachesVM: CachesViewModel
    let bigFilesVM: BigFilesViewModel
    let screenshotsVM: ScreenshotsViewModel
    let applicationsVM: ApplicationsViewModel
    let packages: PackagesStore
    let tools: ToolActionsModel
    let scheduler: BackgroundScheduler
    let drivesVM: ExternalDrivesViewModel

    init() {
        let settings = SettingsStore()
        self.settings = settings
        let store = ScanStore(settings: settings)
        self.store = store
        nodeModulesVM = NodeModulesViewModel(store: store)
        artifactsVM = ArtifactsViewModel(store: store)
        cachesVM = CachesViewModel(store: store)
        bigFilesVM = BigFilesViewModel(store: store)
        screenshotsVM = ScreenshotsViewModel(store: store)
        applicationsVM = ApplicationsViewModel(store: store)
        packages = PackagesStore(store: store)
        tools = ToolActionsModel(store: store)
        scheduler = BackgroundScheduler(settings: settings, store: store)
        drivesVM = ExternalDrivesViewModel(settings: settings)
        settings.refreshDrives()
        showOnboarding = !fullDiskAccess && !settings.data.hasCompletedOnboarding
        scheduler.configure()
    }

    func onLaunch() {
        if !store.hasResults && !showOnboarding { store.scan() }
    }

    func refreshFullDiskAccess() {
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
        guard entries.contains(where: { $0.projectRoot != nil }) else { return (entries, []) }
        let snapshot = await Task.detached(priority: .userInitiated) { InUseSnapshot.capture() }.value
        var allowed: [CleanupEntry] = []
        var blocked: [CleanupRequest.Blocked] = []
        for entry in entries {
            if let root = entry.projectRoot, let process = snapshot.blocker(for: root) {
                blocked.append(.init(entry: entry, process: process))
            } else {
                allowed.append(entry)
            }
        }
        return (allowed, blocked)
    }

    func run(_ entries: [CleanupEntry], action: CleanupAction) async {
        // Check again right before acting: something may have opened since the sheet appeared.
        let (entries, lateBlocked) = await Self.splitInUse(entries)
        let outcome = await store.perform(entries, action: action)
        lastOutcome = outcome
        for vm in [nodeModulesVM as any SelectionPruning, artifactsVM, cachesVM, bigFilesVM, screenshotsVM, applicationsVM] {
            vm.prune(outcome.completedIDs)
        }
        let verb: String
        switch action {
        case .trash: verb = outcome.dryRun ? "Would move to Trash" : "Moved to Trash"
        case .delete: verb = outcome.dryRun ? "Would delete" : "Deleted"
        case .move: verb = outcome.dryRun ? "Would move" : "Moved"
        }
        let size = ByteFormat.string(outcome.bytes)
        let message = "\(verb) \(outcome.itemCount) item\(outcome.itemCount == 1 ? "" : "s") · \(size)"
        if outcome.dryRun {
            showOutcomeDetails = true
        } else if !lateBlocked.isEmpty {
            toast = Toast(kind: .warning, message: message, detail: "\(lateBlocked.count) skipped: now open in \(lateBlocked[0].process)")
        } else if !outcome.failures.isEmpty {
            toast = Toast(kind: .warning, message: message, detail: "\(outcome.failures.count) path\(outcome.failures.count == 1 ? "" : "s") skipped")
        } else {
            toast = Toast(kind: .success, message: message)
        }
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
