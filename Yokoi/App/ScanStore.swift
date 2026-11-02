import Foundation
import Observation

/// Summary of the last completed scan, persisted between launches.
struct ScanSummary: Codable, Equatable {
    var date: Date
    var duration: TimeInterval
    var filesVisited: Int
    var projectCount: Int
    var reclaimable: Int64
    var previousReclaimable: Int64?
}

/// Everything the last scan found, cached to disk so the app opens with results.
private struct ScanCache: Codable {
    var nodeModules: [NodeModulesItem]
    var artifacts: [ArtifactItem]
    var caches: [CacheItem]
    var bigFiles: [BigFileItem]
    var screenshots: [ScreenshotItem]
    var applications: [AppItem]?
    var downloads: [DownloadItem]?
    var summary: ScanSummary?
    /// When each category's results were scanned, by `CleanCategory.rawValue`.
    var scannedAt: [String: Date]?
}

/// The single source of truth for scan results and cleanup history (PRD §10 "ScanStore").
@MainActor
@Observable
final class ScanStore {
    var nodeModules: [NodeModulesItem] = []
    var artifacts: [ArtifactItem] = []
    var caches: [CacheItem] = []
    var bigFiles: [BigFileItem] = []
    var screenshots: [ScreenshotItem] = []
    var downloads: [DownloadItem] = []
    var applications: [AppItem] = []

    var isScanning = false
    var scanningCategories: Set<CleanCategory> = []
    var progress = ScanProgress.Snapshot()
    var lastScan: ScanSummary?
    /// When the scan behind each category's current results started. Cleanup refuses items replaced since.
    private var scannedAt: [CleanCategory: Date] = [:]
    var records: [CleanupRecord] = []
    var disk = DiskInfo.current()

    let settings: SettingsStore
    private let engine = ScanEngine()
    private let log = CleanupLog()
    private var scanTask: Task<Void, Never>?

    private static var cacheURL: URL {
        CleanupLog.defaultURL.deletingLastPathComponent().appendingPathComponent("last-scan.json")
    }

    /// Demo mode: sample data only; never scans, reads the cache or touches the log.
    let isDemo: Bool

    init(settings: SettingsStore, demo: Bool = false) {
        self.settings = settings
        self.isDemo = demo
        if demo {
            populateDemo()
        } else {
            loadCache()
            Task { await reloadLog() }
        }
    }

    func refreshDisk() {
        if !isDemo { disk = DiskInfo.current() }
    }

    private func populateDemo() {
        nodeModules = DemoData.nodeModules
        artifacts = DemoData.artifacts
        caches = DemoData.caches
        bigFiles = DemoData.bigFiles
        screenshots = DemoData.screenshots()
        downloads = DemoData.downloads
        applications = DemoData.applications
        records = DemoData.records
        disk = DemoData.disk
        var summary = DemoData.summary
        summary.reclaimable = reclaimableTotal
        lastScan = summary
    }

    // MARK: Derived values

    var hasResults: Bool { lastScan != nil || !nodeModules.isEmpty || !artifacts.isEmpty }

    func total(_ category: CleanCategory) -> Int64 {
        switch category {
        case .nodeModules: nodeModules.reduce(0) { $0 + $1.size }
        case .buildArtifacts: artifacts.filter { !$0.optIn }.reduce(0) { $0 + $1.size }
        case .caches: caches.reduce(0) { $0 + $1.size }
        case .bigFiles: bigFiles.filter { $0.size >= settings.data.bigFileThreshold }.reduce(0) { $0 + $1.size }
        case .downloads: downloads.filter { $0.isOld(days: settings.data.downloadsAgeDays) }.reduce(0) { $0 + $1.size }
        case .screenshots: screenshots.reduce(0) { $0 + $1.size }
        case .externalDrives: 0  // a different disk: shown on its own screen, not in the Mac's total
        case .applications: applications.filter { $0.protectedReason == nil && $0.isUnused(days: 180) }.reduce(0) { $0 + $1.size }
        case .packages: packagesReclaimable
        }
    }

    /// Size of global packages unused for over a year (set by the Package Managers screen).
    var packagesReclaimable: Int64 = 0

    /// Big files inside old downloads appear in both lists; their bytes are counted once.
    var reclaimableTotal: Int64 {
        let d = settings.data
        let overlap = Overlap.bigFileBytesInDownloads(bigFiles, threshold: d.bigFileThreshold, downloads: downloads, ageDays: d.downloadsAgeDays)
        return CleanCategory.allCases.reduce(0) { $0 + total($1) } - overlap
    }

    var projectCount: Int {
        Set(nodeModules.map(\.projectURL.path) + artifacts.filter { !$0.isGlobal }.map(\.projectURL.path)).count
    }

    var freedAllTime: Int64 { records.freedBytes }
    var cleanupCount: Int { Set(records.filter { !$0.dryRun }.map(\.batchID)).count }

    /// "Smart Select": stale node_modules, artifacts of inactive projects (not opt-in) and Safe caches.
    func smartSelection() -> [CleanupEntry] {
        let d = settings.data
        var entries: [CleanupEntry] = []
        entries += nodeModules.filter { $0.isStale(days: d.staleDays) }.map { CleanupEntry($0) }
        entries += artifacts
            .filter { !$0.optIn }
            .map { CleanupEntry($0, displayPath: $0.displayPath) }
            .filter { !$0.isRecentlyActive(days: d.protectRecentDays) }
        entries += caches.filter { $0.safety == .safe && $0.size > 0 }.map { CleanupEntry($0, displayPath: PathFormat.abbreviate($0.url)) }
        return entries
    }

    // MARK: Scanning

    func scan(_ categories: Set<CleanCategory> = Set(CleanCategory.allCases)) {
        if isDemo { populateDemo(); return }
        guard !isScanning else { return }
        let context = settings.context()
        let progress = ScanProgress()
        let start = Date()
        for c in categories { scannedAt[c] = start }
        let previous = reclaimableTotal
        isScanning = true
        scanningCategories = categories.subtracting([.packages, .externalDrives])
        self.progress = .init()

        // Clear the categories being rescanned; results stream back in live.
        if categories.contains(.nodeModules) { nodeModules = [] }
        if categories.contains(.buildArtifacts) { artifacts = [] }
        if categories.contains(.caches) { caches = [] }
        if categories.contains(.bigFiles) { bigFiles = [] }
        if categories.contains(.screenshots) { screenshots = [] }
        if categories.contains(.downloads) { downloads = [] }
        if categories.contains(.applications) { applications = [] }

        let poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                self?.progress = progress.snapshot
            }
        }

        scanTask = Task { [weak self] in
            guard let self else { return }
            let indexURL = ScanIndex.defaultURL
            let index = await ScanIndex.prepare(stored: indexURL, context: context)
            var context = context
            context.index = index
            let stream = await engine.run(context, progress: progress, categories: categories)
            for await event in stream {
                switch event {
                case .nodeModules(let i): nodeModules.append(i)
                case .artifact(let i): artifacts.append(i)
                case .cache(let i): caches.append(i)
                case .bigFile(let i): bigFiles.append(i)
                case .screenshot(let i): screenshots.append(i)
                case .download(let i): downloads.append(i)
                case .application(let i): applications.append(i)
                case .finished(let c): scanningCategories.remove(c)
                }
            }
            poller.cancel()
            self.progress = progress.snapshot
            let cancelled = Task.isCancelled
            let partial = cancelled || !categories.isSuperset(of: ScanReport.scannable)
            Task.detached(priority: .utility) { index.save(to: indexURL, carryOver: partial) }
            isScanning = false
            scanningCategories = []
            refreshDisk()
            if !cancelled {
                lastScan = ScanSummary(date: Date(), duration: Date().timeIntervalSince(start),
                                       filesVisited: progress.snapshot.filesVisited, projectCount: projectCount,
                                       reclaimable: reclaimableTotal, previousReclaimable: lastScan?.reclaimable ?? (previous > 0 ? previous : nil))
            }
            saveCache()
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    /// Starts a scan (if none is running) and waits for it to finish. Used by scheduled scans.
    func scanAndWait(_ categories: Set<CleanCategory> = Set(CleanCategory.allCases)) async {
        if !isScanning { scan(categories) }
        await scanTask?.value
    }

    // MARK: Cleanup

    func perform(_ entries: [CleanupEntry], action: CleanupAction, progress: CleanupProgress? = nil) async -> CleanupOutcome {
        let service = CleanupService(context: settings.context(), log: log)
        let entries = entries.map { entry in
            var e = entry
            e.scannedAt = e.scannedAt ?? scannedAt[e.category]
            return e
        }
        let outcome = await service.perform(entries, action: action, dryRun: settings.data.dryRun, progress: progress)
        if !outcome.dryRun { remove(ids: outcome.completedIDs) }
        await reloadLog()
        refreshDisk()
        saveCache()
        return outcome
    }

    private func remove(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        nodeModules.removeAll { ids.contains($0.id) }
        artifacts.removeAll { ids.contains($0.id) }
        caches.removeAll { ids.contains($0.id) }
        // Single items cleaned from a location: drop them and keep the rest.
        caches = caches.map { $0.removingChildren(entryIDs: ids) ?? $0 }
        bigFiles.removeAll { ids.contains($0.id) }
        screenshots.removeAll { ids.contains($0.id) }
        downloads.removeAll { ids.contains($0.id) }
        applications.removeAll { ids.contains($0.id) }
        lastScan?.reclaimable = reclaimableTotal
    }

    /// Puts a Trash batch back (undo). The restored items reappear after the next scan.
    func putBack(_ batch: CleanupBatch) async -> CleanupOutcome {
        let service = CleanupService(context: settings.context(), log: log)
        let outcome = await service.restore(batch: batch.records)
        await reloadLog()
        refreshDisk()
        return outcome
    }

    /// Records a tool command (simctl, tmutil, package managers) in the cleanup log.
    func logCommand(_ result: ProcessRunner.Result, category: CleanCategory, label: String, size: Int64) async {
        let record = CleanupRecord(batchID: UUID().uuidString, timestamp: Date(), action: "command", dryRun: false,
                                   category: category, label: label, path: result.commandLine,
                                   size: result.succeeded ? size : 0, items: [], failed: result.succeeded ? 0 : 1)
        try? await log.append([record])
        await reloadLog()
    }

    func reloadLog() async {
        if isDemo { return }
        records = await log.readAll()
    }

    var logURL: URL { CleanupLog.defaultURL }

    // MARK: Persistence

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL) else { return }
        let decoder = JSONDecoder()
        guard let cache = try? decoder.decode(ScanCache.self, from: data) else { return }
        nodeModules = cache.nodeModules
        artifacts = cache.artifacts
        caches = cache.caches
        bigFiles = cache.bigFiles
        screenshots = cache.screenshots.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        applications = cache.applications ?? []
        downloads = (cache.downloads ?? []).filter { FileManager.default.fileExists(atPath: $0.url.path) }
        lastScan = cache.summary
        for (raw, date) in cache.scannedAt ?? [:] {
            if let c = CleanCategory(rawValue: raw) { scannedAt[c] = date }
        }
    }

    private func saveCache() {
        let cache = ScanCache(nodeModules: nodeModules, artifacts: artifacts, caches: caches,
                              bigFiles: bigFiles, screenshots: screenshots, applications: applications, downloads: downloads, summary: lastScan,
                              scannedAt: Dictionary(uniqueKeysWithValues: scannedAt.map { ($0.key.rawValue, $0.value) }))
        let url = Self.cacheURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(cache) else { return }
            try? FileManager.default.createPrivateDirectory(at: url.deletingLastPathComponent())
            try? FileManager.default.writePrivately(data, to: url)
        }
    }
}
