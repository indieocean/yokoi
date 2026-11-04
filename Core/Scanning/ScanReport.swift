import Foundation

/// A headless, read-only scan summary. Used by the `yokoi` command-line companion and by Shortcuts.
/// Totals follow the same rules as the dashboard (`ScanStore.total`), so the numbers match the app.
struct ScanReport: Codable, Sendable {
    struct Disk: Codable, Sendable {
        let name: String
        let totalBytes: Int64
        let freeBytes: Int64
    }

    struct Item: Codable, Sendable {
        let title: String
        let path: String
        let sizeBytes: Int64
        let safety: SafetyLevel
        let lastTouched: Date?
        let note: String?
    }

    struct Category: Codable, Sendable {
        let id: String
        let title: String
        let reclaimableBytes: Int64
        let count: Int
        var items: [Item]
    }

    let version: Int
    let scannedAt: Date
    let durationSeconds: Double
    let disk: Disk
    let reclaimableBytes: Int64
    var categories: [Category]

    /// Categories a headless scan can cover (packages and external drives need the app).
    static let scannable: [CleanCategory] = [.nodeModules, .buildArtifacts, .caches, .bigFiles, .downloads, .screenshots, .applications]

    /// What a headless scan found, before it's summarized.
    struct Results: Sendable {
        var nodeModules: [NodeModulesItem] = [], artifacts: [ArtifactItem] = [], caches: [CacheItem] = []
        var bigFiles: [BigFileItem] = [], downloads: [DownloadItem] = [], screenshots: [ScreenshotItem] = [], apps: [AppItem] = []
    }

    /// Scans `categories` with the user's settings. Never deletes, moves or runs tools.
    /// With `index`, unchanged folders reuse the last scan's measurements (see `ScanIndex`).
    static func results(settings: SettingsData, categories: Set<CleanCategory>, home: URL,
                        progress: ScanProgress = ScanProgress(), index indexURL: URL? = nil) async -> Results {
        var context = settings.makeContext(home: home)
        let wanted = categories.intersection(scannable)
        if let indexURL { context.index = await ScanIndex.prepare(stored: indexURL, context: context) }
        var found = Results()
        for await event in await ScanEngine().run(context, progress: progress, categories: wanted) {
            switch event {
            case .nodeModules(let i): found.nodeModules.append(i)
            case .artifact(let i): found.artifacts.append(i)
            case .cache(let i): found.caches.append(i)
            case .bigFile(let i): found.bigFiles.append(i)
            case .screenshot(let i): found.screenshots.append(i)
            case .download(let i): found.downloads.append(i)
            case .application(let i): found.apps.append(i)
            case .duplicate, .finished: break
            }
        }
        if let indexURL, let index = context.index {
            index.save(to: indexURL, carryOver: wanted != Set(scannable))
        }
        return found
    }

    /// Runs a scan of `categories` with the user's settings. Never deletes, moves or runs tools.
    /// With `index`, unchanged folders reuse the last scan's measurements (see `ScanIndex`).
    static func run(settings: SettingsData, categories: Set<CleanCategory> = Set(scannable),
                    home: URL = FileManager.default.homeDirectoryForCurrentUser,
                    progress: ScanProgress = ScanProgress(), index indexURL: URL? = nil) async -> ScanReport {
        let start = Date()
        let wanted = categories.intersection(scannable)
        let found = await results(settings: settings, categories: categories, home: home, progress: progress, index: indexURL)
        let (nodeModules, artifacts, caches) = (found.nodeModules, found.artifacts, found.caches)
        let (bigFiles, downloads, screenshots, apps) = (found.bigFiles, found.downloads, found.screenshots, found.apps)

        func item(_ r: some Reclaimable, path: URL, note: String? = nil) -> Item {
            Item(title: r.title, path: path.path, sizeBytes: r.size, safety: r.safety, lastTouched: r.projectLastTouched, note: note)
        }
        var out: [Category] = []
        func add(_ c: CleanCategory, _ items: [Item]) {
            guard wanted.contains(c) else { return }
            let sorted = items.sorted { $0.sizeBytes > $1.sizeBytes }
            out.append(Category(id: c.rawValue, title: c.title, reclaimableBytes: sorted.reduce(0) { $0 + $1.sizeBytes },
                                count: sorted.count, items: sorted))
        }
        add(.nodeModules, nodeModules.map { item($0, path: $0.url, note: $0.isStale(days: settings.staleDays) ? "stale" : nil) })
        add(.buildArtifacts, artifacts.filter { !$0.optIn }.map { item($0, path: $0.projectURL, note: $0.displayPath) })
        add(.caches, caches.map { item($0, path: $0.url, note: $0.permanentOnly ? "permanent delete only" : nil) })
        add(.bigFiles, bigFiles.filter { $0.size >= settings.bigFileThreshold }.map { item($0, path: $0.url, note: $0.kind.rawValue) })
        add(.downloads, downloads.filter { $0.isOld(days: settings.downloadsAgeDays) }
            .map { item($0, path: $0.url, note: $0.note ?? $0.kind.rawValue) })
        add(.screenshots, screenshots.map { item($0, path: $0.url) })
        add(.applications, apps.filter { $0.protectedReason == nil && $0.isUnused(days: 180) }.map { item($0, path: $0.url, note: "unused 180+ days") })

        // Big files inside old downloads are in both lists; count those bytes once.
        let overlap = wanted.isSuperset(of: [.bigFiles, .downloads])
            ? Overlap.bigFileBytesInDownloads(bigFiles, threshold: settings.bigFileThreshold, downloads: downloads, ageDays: settings.downloadsAgeDays)
            : 0
        return ScanReport(version: 1, scannedAt: Date(), durationSeconds: Date().timeIntervalSince(start),
                          disk: currentDisk(home: home), reclaimableBytes: out.reduce(0) { $0 + $1.reclaimableBytes } - overlap,
                          categories: out)
    }

    static func currentDisk(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Disk {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityKey, .volumeLocalizedNameKey]
        let v = try? home.resourceValues(forKeys: keys)
        let free = v?.volumeAvailableCapacityForImportantUsage ?? Int64(v?.volumeAvailableCapacity ?? 0)
        return Disk(name: v?.volumeLocalizedName ?? "Macintosh HD", totalBytes: Int64(v?.volumeTotalCapacity ?? 0), freeBytes: free)
    }

    /// Keeps the `limit` largest items of each category (totals are unchanged).
    func trimmed(to limit: Int?) -> ScanReport {
        guard let limit else { return self }
        var copy = self
        copy.categories = categories.map { var c = $0; c.items = Array(c.items.prefix(max(0, limit))); return c }
        return copy
    }

    func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

extension CleanCategory {
    /// `node-modules`, `build-artifacts`, `big-files`… as typed on the command line. camelCase also works.
    var cliName: String {
        rawValue.reduce(into: "") { s, c in
            if c.isUppercase { s += "-" + c.lowercased() } else { s.append(c) }
        }
    }

    init?(cliName: String) {
        let key = cliName.lowercased().replacingOccurrences(of: "_", with: "-")
        guard let match = CleanCategory.allCases.first(where: { $0.cliName == key || $0.rawValue.lowercased() == key }) else { return nil }
        self = match
    }
}
