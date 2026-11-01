import Foundation
import Observation
import Sparkle

/// App updates through Sparkle. The feed URL and signing key live in `Config/Yokoi-Info.plist`.
///
/// Nothing is checked until the user agrees: Sparkle asks on the second launch whether to check
/// automatically, and "Check for Updates…" always works. Debug builds and demo mode never start it.
@MainActor @Observable
final class Updater {
    enum Status: Equatable {
        /// Debug build: Sparkle isn't running.
        case development
        /// Automatic checks are off and nothing was checked since launch.
        case off
        case checking
        case upToDate
        case available(version: String)
        case failed
    }

    private(set) var status: Status
    /// When the last check this session finished (Sparkle's own `lastUpdateCheckDate` skips silent checks).
    private(set) var checkedAt: Date?
    /// Mirrors `SPUUpdater.canCheckForUpdates` (false while a check is already running).
    private(set) var canCheckForUpdates = false
    let currentVersion: String

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private let events = Events()
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init(demo: Bool) {
        let info = Bundle.main.infoDictionary
        currentVersion = info?["CFBundleShortVersionString"] as? String ?? "?"

        #if DEBUG
        let start = false
        #else
        let start = !demo
        #endif
        guard start else {
            controller = nil
            status = demo ? .upToDate : .development
            if demo { checkedAt = .now.addingTimeInterval(-3 * 3600) }
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: events, userDriverDelegate: nil)
        self.controller = controller
        status = .off
        events.owner = self
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let can = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = can }
        }
        // Only reach the network on launch if the user allowed automatic checks. This check is silent:
        // it only fills in `status`, and Sparkle's own scheduled check still shows its usual window.
        if controller.updater.automaticallyChecksForUpdates { refreshStatus() }
    }

    /// False in debug builds and demo mode, where the menu item and settings card are hidden.
    var isAvailable: Bool { controller != nil }

    var automaticallyChecks: Bool {
        get {
            access(keyPath: \.automaticallyChecks)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecks) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
            if newValue { refreshStatus() }
        }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    /// Sparkle's window: shows the release and installs it, or says Yokoi is up to date.
    func checkForUpdates() { controller?.checkForUpdates(nil) }

    /// Asks the feed whether there's a newer version without showing any window.
    func refreshStatus() {
        guard let updater = controller?.updater, !updater.sessionInProgress else { return }
        status = .checking
        updater.checkForUpdateInformation()
    }

    /// Sparkle calls these on the main thread (the protocol is main-actor isolated).
    private final class Events: NSObject, SPUUpdaterDelegate {
        weak var owner: Updater?

        func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
            owner?.status = .available(version: item.displayVersionString)
            owner?.checkedAt = .now
        }

        func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
            owner?.status = .upToDate
            owner?.checkedAt = .now
        }

        func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
            guard let owner, owner.status == .checking else { return }
            // Still "checking" means neither callback above ran: the feed couldn't be read, or it was cancelled.
            let code = (error as NSError?)?.code
            owner.status = error == nil || code == Int(SUError.noUpdateError.rawValue) ? .upToDate : .failed
        }
    }
}
