import Foundation
import Observation
import Sparkle

/// App updates through Sparkle. The feed URL and signing key live in `Config/Yokoi-Info.plist`.
///
/// Nothing is checked until the user agrees: Sparkle asks on the second launch whether to check
/// automatically, and "Check for Updates…" always works. Debug builds and demo mode never start it.
@MainActor @Observable
final class Updater {
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    /// Mirrors `SPUUpdater.canCheckForUpdates` (false while a check is already running).
    private(set) var canCheckForUpdates = false

    init(enabled: Bool) {
        #if DEBUG
        let start = false
        #else
        let start = enabled
        #endif
        guard start else { controller = nil; return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let can = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = can }
        }
    }

    /// False in debug builds and demo mode, where the menu item and settings row are hidden.
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
        }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}
