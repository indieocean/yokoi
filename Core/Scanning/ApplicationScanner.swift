import CoreServices
import Foundation

/// A support file an app leaves in `~/Library`.
struct AppLeftover: Codable, Sendable, Hashable {
    let url: URL
    let kind: String   // "Application Support", "Caches", "Preferences"…
    let size: Int64
    /// Matched on something an app can simply claim, so it may belong to another app: a name, a bundle id another
    /// installed app also uses, or a launch agent's prefix. Stays in place unless the user picks it.
    var uncertain: Bool? = nil

    var isUncertain: Bool { uncertain == true }
}

/// An installed app plus everything it keeps in `~/Library`.
struct AppItem: Reclaimable, Codable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let bundleID: String
    let version: String
    let appSize: Int64
    let leftovers: [AppLeftover]
    let lastUsed: Date?
    let isAppStore: Bool
    /// Apple apps and Yokoi itself can't be uninstalled here. A fixed English identity ("Apple app",
    /// "Yokoi itself") that's compared and cached: show `protectedReasonText` instead.
    let protectedReason: String?
    let fileCount: Int
    /// Paths of the uncertain leftovers the user picked.
    var chosenUncertain: Set<String>? = nil

    var category: CleanCategory { .applications }
    var title: String { name }
    /// What an uninstall takes: everything certain, plus what was picked by hand.
    var removableLeftovers: [AppLeftover] {
        leftovers.filter { !$0.isUncertain || chosenUncertain?.contains($0.url.path) == true }
    }
    var leftoverSize: Int64 { removableLeftovers.reduce(0) { $0 + $1.size } }
    var size: Int64 { appSize + leftoverSize }
    var urls: [URL] { [url] + removableLeftovers.map(\.url) }
    var safety: SafetyLevel { .review }
    var restoreHint: String {
        isAppStore
            ? String(localized: "Put it back from the Trash, or download it again from the App Store.")
            : String(localized: "Put it back from the Trash. Its settings come back with it.")
    }

    /// `protectedReason`, localized for display.
    var protectedReasonText: String? {
        switch protectedReason {
        case nil: nil
        case "Apple app": String(localized: "Apple app", comment: "Why an app can't be uninstalled: it comes with macOS")
        case "Yokoi itself": String(localized: "Yokoi itself", comment: "Why an app can't be uninstalled: it is this app")
        case let other?: other
        }
    }

    func isUnused(days: Int, now: Date = Date()) -> Bool {
        guard let lastUsed else { return true }
        return now.timeIntervalSince(lastUsed) > Double(days) * 86_400
    }
}

/// Lists apps in `/Applications` and `~/Applications` and finds their leftovers in `~/Library`.
/// Leftovers are matched by exact bundle id; the app name is only used for Application Support,
/// Caches and Logs, and only when no other installed app uses the same name. An app's `Info.plist` says whatever
/// its author likes, so a name match is only ever a suggestion, and a malformed bundle id matches nothing.
struct ApplicationScanner: CategoryScanner {
    var category: CleanCategory { .applications }

    /// `~/Library` folders searched for leftovers (also the allowed cleanup roots for this category).
    static let leftoverFolders = [
        "Library/Application Support", "Library/Caches", "Library/Preferences", "Library/Preferences/ByHost",
        "Library/Containers", "Library/Group Containers", "Library/Logs", "Library/Saved Application State",
        "Library/HTTPStorages", "Library/WebKit", "Library/Application Scripts", "Library/Cookies", "Library/LaunchAgents",
    ]

    struct Info: Sendable {
        let url: URL
        let name: String
        let bundleID: String
        let version: String
        let isAppStore: Bool
    }

    func scan(_ context: ScanContext, progress: ScanProgress) -> AsyncStream<AppItem> {
        makeStream { yield in
            let apps = Self.findApps(in: context.applicationFolders, context: context)
            let names = Dictionary(grouping: apps, by: { $0.name.lowercased() })
            let ids = Dictionary(grouping: apps, by: { $0.bundleID.lowercased() })
            let ownID = Bundle.main.bundleIdentifier ?? "com.yokoi.Yokoi"
            for await item in FileWalker.concurrentMap(apps, limit: context.concurrency, { (info: Info) -> AppItem? in
                guard !Task.isCancelled else { return nil }
                let m = context.measure(info.url, progress: progress)
                let uniqueName = (names[info.name.lowercased()]?.count ?? 0) == 1
                let sharedID = (ids[info.bundleID.lowercased()]?.count ?? 0) > 1
                let leftovers = Self.leftovers(for: info, home: context.home, matchName: uniqueName, sharedID: sharedID, context: context)
                let reason: String? = info.bundleID.hasPrefix("com.apple.") ? "Apple app"
                    : (info.bundleID == ownID ? "Yokoi itself" : nil)
                return AppItem(url: info.url, name: info.name, bundleID: info.bundleID, version: info.version,
                               appSize: m.size, leftovers: leftovers, lastUsed: Self.lastUsed(info.url),
                               isAppStore: info.isAppStore, protectedReason: reason,
                               fileCount: m.files + leftovers.count)
            }) {
                yield(item)
            }
        }
    }

    /// `*.app` bundles in each folder and one level of subfolders (`/Applications/Utilities`, vendor folders).
    static func findApps(in folders: [URL], context: ScanContext) -> [Info] {
        var out: [Info] = []
        var seen = Set<String>()
        func consider(_ e: FileWalker.Entry) {
            guard e.isDirectory, !e.isSymlink, e.url.pathExtension == "app", !context.isExcluded(e.url),
                  seen.insert(e.url.path).inserted, let info = readInfo(e.url) else { return }
            out.append(info)
        }
        for folder in folders {
            for e in FileWalker.list(folder) {
                if e.url.pathExtension == "app" {
                    consider(e)
                } else if e.isDirectory, !e.isSymlink, !e.name.hasPrefix(".") {
                    FileWalker.list(e.url).forEach(consider)
                }
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func readInfo(_ app: URL) -> Info? {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty else { return nil }
        let name = (plist["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? app.deletingPathExtension().lastPathComponent
        let version = plist["CFBundleShortVersionString"] as? String ?? plist["CFBundleVersion"] as? String ?? ""
        let isAppStore = FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/_MASReceipt").path)
        return Info(url: app, name: name, bundleID: bundleID, version: version, isAppStore: isAppStore)
    }

    /// Reverse-DNS: at least two parts of letters, digits, `-` and `_`. Anything else can't be used to build a path
    /// or match file names (`com` alone would match every `com.*` launch agent).
    static func isValidBundleID(_ id: String) -> Bool {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }
    }

    static func leftovers(for info: Info, home: URL, matchName: Bool, sharedID: Bool = false, context: ScanContext) -> [AppLeftover] {
        let b = info.bundleID
        let validID = isValidBundleID(b)
        let fileName = info.url.deletingPathExtension().lastPathComponent
        // Names shorter than 4 characters are too generic to match safely.
        let names = matchName ? Set([info.name, fileName].filter { $0.count >= 4 }) : []
        let lib = home.appendingPathComponent("Library")
        var candidates: [(kind: String, url: URL, uncertain: Bool)] = []

        func add(_ folder: String, _ child: String, uncertain: Bool = sharedID) {
            candidates.append((folder, lib.appendingPathComponent(folder).appendingPathComponent(child), uncertain))
        }
        if validID {
            add("Application Support", b)
            add("Caches", b)
            add("Preferences", "\(b).plist")
            add("Containers", b)
            add("Logs", b)
            add("Saved Application State", "\(b).savedState")
            add("HTTPStorages", b)
            add("HTTPStorages", "\(b).binarycookies")
            add("WebKit", b)
            add("Application Scripts", b)
            add("Cookies", "\(b).binarycookies")

            // Pattern matches: ByHost prefs, group containers (TEAMID.bundle.id), launch agents.
            for e in FileWalker.list(lib.appendingPathComponent("Preferences/ByHost")) where e.name.hasPrefix(b + ".") && e.name.hasSuffix(".plist") {
                candidates.append(("Preferences", e.url, sharedID))
            }
            for e in FileWalker.list(lib.appendingPathComponent("Group Containers")) where e.name == b || e.name.hasSuffix("." + b) || e.name == "group." + b {
                candidates.append(("Group Containers", e.url, sharedID))
            }
            for e in FileWalker.list(lib.appendingPathComponent("LaunchAgents")) where e.name.hasSuffix(".plist") {
                if e.name == b + ".plist" {
                    candidates.append(("Launch Agents", e.url, sharedID))
                } else if e.name.hasPrefix(b + ".") {
                    candidates.append(("Launch Agents", e.url, true))  // `com.adobe` would claim every Adobe agent
                }
            }
        }
        for name in names {
            add("Application Support", name, uncertain: true)
            add("Caches", name, uncertain: true)
            add("Logs", name, uncertain: true)
        }

        let guardrail = context.pathGuard(for: .applications)
        var seen = Set<String>()
        return candidates.compactMap { kind, url, uncertain in
            guard seen.insert(url.path.lowercased()).inserted,
                  (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil,
                  guardrail.isAllowed(url) else { return nil }
            return AppLeftover(url: url, kind: kind, size: FileWalker.measure(url).size, uncertain: uncertain ? true : nil)
        }
    }

    /// Spotlight's "last opened" date.
    static func lastUsed(_ app: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, app as CFURL),
              let value = MDItemCopyAttribute(item, kMDItemLastUsedDate) else { return nil }
        return value as? Date
    }
}
