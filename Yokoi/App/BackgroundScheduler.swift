import Foundation
import Observation
import ServiceManagement
import UserNotifications

/// Scheduled scans, the screenshot auto rule, launch at login and notifications (PRD §7–8).
/// Uses `NSBackgroundActivityScheduler`, so macOS runs the work at low priority when convenient.
@MainActor
@Observable
final class BackgroundScheduler {
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let store: ScanStore
    @ObservationIgnored private var scanActivity: NSBackgroundActivityScheduler?
    @ObservationIgnored private var screenshotActivity: NSBackgroundActivityScheduler?
    @ObservationIgnored private var configured: (autoScan: Bool, frequency: ScanFrequency, rule: Bool)?

    private(set) var lastAutoRun: Date?
    /// What macOS says about Yokoi's login item. The source of truth for the Settings toggle, since the
    /// user can also change it in System Settings → General → Login Items.
    private(set) var loginItem: LoginItemState = .off
    private(set) var loginItemError: String?

    init(settings: SettingsStore, store: ScanStore) {
        self.settings = settings
        self.store = store
    }

    static func interval(_ f: ScanFrequency) -> TimeInterval {
        switch f {
        case .daily: 86_400
        case .weekly: 7 * 86_400
        case .monthly: 30 * 86_400
        }
    }

    /// Next scheduled scan, estimated from the last scan and the frequency.
    var nextScan: Date? {
        guard settings.data.autoScan else { return nil }
        let base = store.lastScan?.date ?? Date()
        return max(base.addingTimeInterval(Self.interval(settings.data.scanFrequency)), Date())
    }

    /// (Re)creates the background activities to match the settings. Cheap to call often.
    func configure() {
        let d = settings.data
        let wanted = (d.autoScan, d.scanFrequency, d.screenshotAutoRule)
        if let c = configured, c.autoScan == wanted.0, c.frequency == wanted.1, c.rule == wanted.2 { return }
        configured = wanted

        scanActivity?.invalidate()
        scanActivity = nil
        if d.autoScan {
            let a = NSBackgroundActivityScheduler(identifier: "com.yokoi.scan")
            a.repeats = true
            a.interval = Self.interval(d.scanFrequency)
            a.tolerance = a.interval * 0.1
            a.qualityOfService = .utility
            a.schedule(Self.handler { [weak self] in await self?.runScheduledScan() })
            scanActivity = a
        }

        screenshotActivity?.invalidate()
        screenshotActivity = nil
        if d.screenshotAutoRule {
            let a = NSBackgroundActivityScheduler(identifier: "com.yokoi.screenshots")
            a.repeats = true
            a.interval = 86_400
            a.tolerance = 3_600
            a.qualityOfService = .utility
            a.schedule(Self.handler { [weak self] in await self?.runScreenshotRule() })
            screenshotActivity = a
        }
    }

    /// NSBackgroundActivityScheduler calls its block on a background queue. Building the block in a
    /// nonisolated context keeps Swift 6 from asserting it runs on the main actor (a crash),
    /// and the work itself hops to the main actor.
    nonisolated private static func handler(_ work: @escaping @MainActor @Sendable () async -> Void)
        -> @Sendable (@escaping NSBackgroundActivityScheduler.CompletionHandler) -> Void
    {
        { done in
            let completion = CompletionBox(done)
            Task { @MainActor in
                await work()
                completion.call()
            }
        }
    }

    // MARK: Jobs

    func runScheduledScan() async {
        await store.scanAndWait()
        lastAutoRun = Date()
        let d = settings.data
        if d.autoCleanSafeCaches { await runAutoClean(permanent: d.autoCleanPermanent) }
        let threshold = Int64(d.notifyThresholdGB) * 1_000_000_000
        if threshold > 0, store.reclaimableTotal >= threshold {
            await notify(String(localized: "\(ByteFormat.string(store.reclaimableTotal)) can be reclaimed",
                                comment: "Notification title; placeholder is a size like 12 GB"),
                         String(localized: "Open Yokoi to review node_modules, build artifacts and caches.", comment: "Notification body"))
        }
    }

    /// Opt-in, and logged like any other cleanup. Nobody confirms this one, so what's in use is held back here
    /// rather than on a sheet, and held-back items simply wait for the next run.
    private func runAutoClean(permanent: Bool) async {
        let (entries, blocked) = await InUseSnapshot.split(store.autoCleanSelection())
        guard !entries.isEmpty else { return }
        let outcome = await store.perform(entries, action: permanent ? .delete : .trash)
        guard !outcome.dryRun, outcome.bytes > 0 else { return }
        let size = ByteFormat.string(outcome.bytes)
        let body: String
        switch (permanent, blocked.count) {
        case (true, 0):
            body = String(localized: "Permanently deleted \(size).", comment: "Auto-clean notification body; placeholder is a size like 1.2 GB")
        case (false, 0):
            body = String(localized: "Moved \(size) to the Trash.", comment: "Auto-clean notification body; placeholder is a size like 1.2 GB")
        case (true, let n):
            body = String(localized: "Permanently deleted \(size). \(n) items in use left alone.",
                          comment: "Auto-clean notification body; first placeholder is a size, second the number of skipped items")
        case (false, let n):
            body = String(localized: "Moved \(size) to the Trash. \(n) items in use left alone.",
                          comment: "Auto-clean notification body; first placeholder is a size, second the number of skipped items")
        }
        await notify(String(localized: "Auto-clean finished", comment: "Notification title"), body)
    }

    /// Daily: move (or trash) screenshots older than N days, as chosen in the Screenshots action panel.
    func runScreenshotRule() async {
        await store.scanAndWait([.screenshots])
        let d = settings.data
        let old = store.screenshots.filter { $0.ageInDays() >= d.screenshotAgeDays }
        guard !old.isEmpty else { return }
        let entries = old.map { CleanupEntry($0, date: $0.created) }
        let action: CleanupAction = d.screenshotAutoAction == .delete
            ? .trash
            : .move(destination: PathFormat.expand(d.screenshotDestination), organizeByDate: d.screenshotOrganizeByDate)
        let outcome = await store.perform(entries, action: action)
        if !outcome.dryRun, outcome.itemCount > 0 {
            let count = outcome.itemCount
            let title = d.screenshotAutoAction == .delete
                ? String(localized: "Moved to Trash \(count) screenshots", comment: "Notification title after the daily screenshot rule trashed screenshots")
                : String(localized: "Filed \(count) screenshots", comment: "Notification title after the daily screenshot rule moved screenshots into a folder")
            await notify(title, String(localized: "Older than \(d.screenshotAgeDays) days.", comment: "Notification body: the screenshot age rule"))
        }
    }

    // MARK: Login item

    enum LoginItemState: Equatable {
        case off, on
        /// Registered, but switched off in Login Items, so it won't launch until the user allows it there.
        case needsApproval

        init(_ status: SMAppService.Status) {
            switch status {
            case .enabled: self = .on
            case .requiresApproval: self = .needsApproval
            default: self = .off  // .notRegistered, .notFound
            }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        refreshLoginItem()
    }

    /// Re-reads the status from macOS and keeps the saved setting in step with it.
    func refreshLoginItem() {
        loginItem = LoginItemState(SMAppService.mainApp.status)
        let on = loginItem != .off
        if settings.data.launchAtLogin != on { settings.data.launchAtLogin = on }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: Notifications

    func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    private func notify(_ title: String, _ body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Carries the scheduler's completion handler across the hop to the main actor.
private final class CompletionBox: @unchecked Sendable {
    private let done: NSBackgroundActivityScheduler.CompletionHandler
    init(_ done: @escaping NSBackgroundActivityScheduler.CompletionHandler) { self.done = done }
    func call() { done(.finished) }
}
