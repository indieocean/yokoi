import Foundation

/// Measures the known cache locations (PRD §5.4). Only locations that exist are reported.
struct CacheScanner: CategoryScanner {
    var category: CleanCategory { .caches }
    var locations: [CacheLocation] = CacheLocation.all

    func scan(_ context: ScanContext, progress: ScanProgress) -> AsyncStream<CacheItem> {
        let locations = self.locations
        return makeStream { yield in
            for await item in FileWalker.concurrentMap(locations, limit: context.concurrency, { location in
                Self.measure(location, all: locations, context: context, progress: progress)
            }) {
                yield(item)
            }
        }
    }

    static func measure(_ location: CacheLocation, all: [CacheLocation], context: ScanContext, progress: ScanProgress) -> CacheItem? {
        if Task.isCancelled { return nil }
        let url = location.url(home: context.home)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
              !context.isExcluded(url) else { return nil }

        // Children covered by more specific locations (e.g. ~/Library/Caches/Homebrew) are skipped
        // so "User caches" doesn't count them twice.
        var nested = Set<String>()
        if location.excludesNestedLocations {
            let prefix = location.relativePath + "/"
            for other in all where other.id != location.id && other.relativePath.hasPrefix(prefix) {
                if let first = other.relativePath.dropFirst(prefix.count).split(separator: "/").first {
                    nested.insert(String(first))
                }
            }
            for rule in GlobalArtifactRule.all where rule.relativePath.hasPrefix(prefix) {
                if let first = rule.relativePath.dropFirst(prefix.count).split(separator: "/").first {
                    nested.insert(String(first))
                }
            }
        }

        let extensions = location.onlyExtensions.map { Set($0.map { $0.lowercased() }) }
        let entries = FileWalker.list(url).filter { child in
            if let extensions {
                guard !child.isSymlink, extensions.contains(child.url.pathExtension.lowercased()) else { return false }
            }
            return child.name != ".DS_Store"
                && !nested.contains(child.name)
                && !location.keepChildren.contains { fnmatch($0, child.name, 0) == 0 }
                && !context.isExcluded(child.url)
        }.map(\.url)

        // Each child is measured on its own; the location's size is their sum.
        let groups = CacheBreakdown.group(entries, as: location.breakdown).filter { group in
            group.urls.allSatisfy { !context.isExcluded($0) }
        }
        var children: [CacheChild] = []
        for group in groups {
            if Task.isCancelled { return nil }
            let m = group.urls.reduce(FileWalker.Measurement()) { $0 + context.measure($1, progress: progress) }
            children.append(CacheChild(urls: group.urls, name: group.name, detail: group.detail,
                                       size: m.size, fileCount: m.files, date: group.date ?? CacheBreakdown.lastChanged(group.urls)))
        }
        children.sort { a, b in
            if location.breakdown.sortsByDate, a.date != b.date { return (a.date ?? .distantPast) > (b.date ?? .distantPast) }
            return a.size != b.size ? a.size > b.size : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }

        return CacheItem(
            locationID: location.id, name: location.name, section: location.section, url: url,
            contents: children.flatMap(\.urls), safety: location.safety, badge: location.badge, colorHex: location.colorHex,
            size: children.reduce(0) { $0 + $1.size }, fileCount: children.reduce(0) { $0 + $1.fileCount },
            restoreHint: location.restoreHint, permanentOnly: location.permanentOnly,
            children: location.breakdown == .none ? nil : children
        )
    }
}

/// Turns a cache location's top-level entries into the rows shown under its twisty, with readable names.
enum CacheBreakdown {
    struct Group: Equatable {
        var urls: [URL]
        var name: String
        var detail: String? = nil
        var date: Date? = nil
    }

    static func group(_ entries: [URL], as breakdown: CacheLocation.Breakdown) -> [Group] {
        let plain = { (u: URL) in Group(urls: [u], name: u.lastPathComponent) }
        switch breakdown {
        case .none, .children:
            return entries.map(plain)
        case .simulators:
            return entries.map(simulator)
        case .archives:
            // Archives sit in date folders (`2026-02-25/App 2-25-26, 3.08 PM.xcarchive`); list the archives.
            return entries.flatMap { entry -> [Group] in
                guard entry.pathExtension != "xcarchive", isDirectory(entry) else { return [entry.pathExtension == "xcarchive" ? archive(entry) : plain(entry)] }
                let inside = FileWalker.list(entry).map(\.url).filter { $0.lastPathComponent != ".DS_Store" }
                // A date folder with nothing in it is removed as itself.
                return inside.isEmpty ? [plain(entry)] : inside.map { $0.pathExtension == "xcarchive" ? archive($0) : plain($0) }
            }
        case .deviceSupport:
            return entries.map(deviceSupport)
        case .avds:
            return avds(entries)
        case .systemImages:
            // `android-34/google_apis/arm64-v8a`: one row per ABI folder.
            return entries.flatMap { api -> [Group] in
                let tags = isDirectory(api) ? FileWalker.list(api).map(\.url).filter { isDirectory($0) } : []
                let leaves = tags.flatMap { tag in FileWalker.list(tag).map(\.url).filter { isDirectory($0) } }
                return leaves.isEmpty ? [plain(api)] : leaves.map(systemImage)
            }
        case .huggingface:
            return entries.map { u in
                let n = u.lastPathComponent
                for prefix in ["models--", "datasets--", "spaces--"] where n.hasPrefix(prefix) {
                    let kind = String(prefix.dropLast(3))
                    return Group(urls: [u], name: n.dropFirst(prefix.count).replacingOccurrences(of: "--", with: "/"),
                                 detail: kind == "models" ? nil : String(kind.dropLast()))
                }
                return plain(u)
            }
        }
    }

    /// Newest modification of the items and their direct children. Cheap, unlike a full walk, and it
    /// follows use: a simulator rewrites `device.plist` and its `data` folder each time it boots.
    static func lastChanged(_ urls: [URL]) -> Date? {
        let fm = FileManager.default
        return urls.flatMap { url -> [Date] in
            let own = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let inside = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [])) ?? []
            return ([own] + inside.map { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }).compactMap { $0 }
        }.max()
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false
    }

    private static func plist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-17-5` → `iOS 17.5`.
    static func runtimeName(_ identifier: String) -> String {
        let short = identifier.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
        guard let dash = short.firstIndex(of: "-") else { return short }
        let os = short[..<dash] == "xrOS" ? "visionOS" : String(short[..<dash])
        return os + " " + short[short.index(after: dash)...].replacingOccurrences(of: "-", with: ".")
    }

    static func simulator(_ url: URL) -> Group {
        guard let info = plist(url.appendingPathComponent("device.plist")) else { return Group(urls: [url], name: url.lastPathComponent) }
        let runtime = (info["runtime"] as? String).map(runtimeName)
        return Group(urls: [url], name: info["name"] as? String ?? url.lastPathComponent, detail: runtime)
    }

    static func archive(_ url: URL) -> Group {
        guard let info = plist(url.appendingPathComponent("Info.plist")) else {
            return Group(urls: [url], name: url.deletingPathExtension().lastPathComponent)
        }
        let app = info["ApplicationProperties"] as? [String: Any]
        let name = info["Name"] as? String ?? (app?["ApplicationPath"] as? String).map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ?? url.deletingPathExtension().lastPathComponent
        var detail: String?
        if let version = app?["CFBundleShortVersionString"] as? String {
            detail = (app?["CFBundleVersion"] as? String).map { "\(version) (\($0))" } ?? version
        }
        return Group(urls: [url], name: name, detail: detail, date: info["CreationDate"] as? Date)
    }

    /// `iPhone15,2 17.0 (21A329)` → name `17.0 (21A329)`, detail `iPhone15,2`. Older folders are just `17.0 (21A329)`.
    static func deviceSupport(_ url: URL) -> Group {
        let n = url.lastPathComponent
        let parts = n.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[0].contains(","), parts[1].first?.isNumber == true {
            return Group(urls: [url], name: parts[1], detail: parts[0])
        }
        return Group(urls: [url], name: n)
    }

    /// `Pixel_7.avd` and `Pixel_7.ini` are one emulator.
    static func avds(_ entries: [URL]) -> [Group] {
        var byName: [String: [URL]] = [:]
        var order: [String] = []
        for u in entries {
            let key = ["avd", "ini"].contains(u.pathExtension) ? u.deletingPathExtension().lastPathComponent : u.lastPathComponent
            if byName[key] == nil { order.append(key) }
            byName[key, default: []].append(u)
        }
        return order.map { key in
            // The folder first: it's the one shown, revealed and checked for an open emulator.
            let urls = byName[key]!.sorted { ($0.pathExtension == "avd" ? 0 : 1) < ($1.pathExtension == "avd" ? 0 : 1) }
            return Group(urls: urls, name: key.replacingOccurrences(of: "_", with: " "))
        }
    }

    /// `…/android-34/google_apis_playstore/arm64-v8a` → `Android API 34`, detail `Google Play · arm64-v8a`.
    static func systemImage(_ url: URL) -> Group {
        let abi = url.lastPathComponent
        let tag = url.deletingLastPathComponent().lastPathComponent
        let api = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        let tags = ["default": "AOSP", "google_apis": "Google APIs", "google_apis_playstore": "Google Play",
                    "google_atd": "Google ATD", "aosp_atd": "AOSP ATD", "android-wear": "Wear OS", "android-tv": "Android TV"]
        let name = api.hasPrefix("android-") ? "Android API " + api.dropFirst("android-".count) : api
        return Group(urls: [url], name: name, detail: "\(tags[tag] ?? tag) · \(abi)")
    }
}
