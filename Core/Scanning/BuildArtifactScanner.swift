import Foundation

/// Finds rebuildable build output using the `ArtifactRule` table. A rule only matches when its marker
/// file sits in the same folder (PRD FR-B2). Nested matches of the same rule are credited to the
/// outermost project (Rust workspaces, Gradle multi-module builds, Python packages).
struct BuildArtifactScanner: CategoryScanner {
    var category: CleanCategory { .buildArtifacts }
    var rules: [ArtifactRule] = ArtifactRule.all
    var globalRules: [GlobalArtifactRule] = GlobalArtifactRule.all

    struct Hit: Sendable, Hashable {
        let ruleID: String
        let project: URL
        let target: URL
        let optIn: Bool
        let note: String?
    }

    /// Rule id → outermost project root.
    typealias Enclosing = [String: URL]

    func scan(_ context: ScanContext, progress: ScanProgress) -> AsyncStream<ArtifactItem> {
        let rules = self.rules
        let globals = self.globalRules
        return makeStream { yield in
            let hits: [Hit] = await ProjectWalker.walk(context: context, progress: progress, initial: Enclosing()) { dir, entries, enclosing in
                Self.visit(dir: dir, entries: entries, enclosing: enclosing, rules: rules, context: context)
            }

            // Group targets into one item per (rule, project, opt-in).
            struct Key: Hashable, Sendable { let rule: String; let project: URL; let optIn: Bool }
            var groups: [Key: [Hit]] = [:]
            var seen = Set<String>()
            for hit in hits where seen.insert(hit.target.path).inserted {
                groups[Key(rule: hit.ruleID, project: hit.project, optIn: hit.optIn), default: []].append(hit)
            }
            let ruleByID = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
            let skip = NodeModulesScanner.lastTouchedSkips
            let work = Array(groups)

            for await item in FileWalker.concurrentMap(work, limit: context.concurrency, { (pair: (key: Key, value: [Hit])) -> ArtifactItem? in
                let (key, hits) = pair
                guard let rule = ruleByID[key.rule], !Task.isCancelled else { return nil }
                let targets = hits.map(\.target).sorted { $0.path < $1.path }
                let m = targets.reduce(FileWalker.Measurement()) { $0 + context.measure($1, progress: progress, reclaimable: true) }
                guard m.files > 0 || m.size > 0 else { return nil }
                return ArtifactItem(
                    ruleID: rule.id, ecosystem: rule.ecosystem,
                    projectURL: key.project, projectName: key.project.lastPathComponent,
                    targets: targets, optIn: key.optIn, note: hits.first?.note, isGlobal: false,
                    size: m.size, fileCount: m.files,
                    lastTouched: context.lastTouched(project: key.project, skipping: skip.union(rule.rootTargetNames)),
                    restoreHint: rule.restoreHint
                )
            }) {
                yield(item)
            }

            for item in Self.scanGlobals(globals, context: context, progress: progress) {
                yield(item)
            }
        }
    }

    /// Decides what a single folder contributes. Pure apart from reading the folder, so it's easy to test.
    static func visit(dir: URL, entries: [FileWalker.Entry], enclosing: Enclosing, rules: [ArtifactRule], context: ScanContext)
        -> ProjectWalker.Visit<Enclosing, Hit>
    {
        let names = Set(entries.map(\.name))
        // Keyed by lowercased name: APFS is case-insensitive by default, so Unity's `Obj` may be `obj` on disk.
        let dirs = Dictionary(entries.filter { $0.isDirectory && !$0.isSymlink }.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })

        var matched = rules.filter { rule in
            rule.markers.contains { marker in
                switch marker {
                case .file(let path):
                    return path.contains("/")
                        ? FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path)
                        : names.contains(path)
                case .glob(let pattern):
                    return names.contains { fnmatch(pattern, $0, 0) == 0 }
                }
            }
        }
        let matchedIDs = Set(matched.map(\.id))
        matched.removeAll { !Set($0.suppressedBy).isDisjoint(with: matchedIDs) }

        var visit = ProjectWalker.Visit<Enclosing, Hit>(childState: enclosing)
        var claimedPaths = Set<String>()

        func add(_ rule: ArtifactRule, project: URL, url: URL, target: ArtifactRule.Target) {
            guard !context.isExcluded(url), claimedPaths.insert(url.path).inserted else { return }
            visit.found.append(Hit(ruleID: rule.id, project: project, target: url, optIn: target.optIn, note: target.note))
        }

        for rule in matched {
            let project = enclosing[rule.id] ?? dir
            visit.childState[rule.id] = project
            for target in rule.targets where !target.anywhere {
                // `add` ignores paths an earlier rule already claimed (Gradle and CMake both want build/).
                for url in resolve(target, in: dir, dirs: dirs) {
                    add(rule, project: project, url: url, target: target)
                }
                if let first = target.path.split(separator: "/").first {
                    let firstName = String(first)
                    if firstName.contains("*") {
                        for e in dirs.values where fnmatch(firstName, e.name, 0) == 0 { visit.claimed.insert(e.name) }
                    } else if let e = dirs[firstName.lowercased()] {
                        visit.claimed.insert(e.name)
                    }
                }
            }
        }

        // "Anywhere" targets (e.g. __pycache__) for every project we're inside.
        for (ruleID, project) in visit.childState {
            guard let rule = rules.first(where: { $0.id == ruleID }) else { continue }
            for target in rule.targets where target.anywhere {
                if let entry = dirs[target.path.lowercased()] {
                    add(rule, project: project, url: entry.url, target: target)
                    visit.claimed.insert(entry.name)
                }
            }
        }
        return visit
    }

    static func resolve(_ target: ArtifactRule.Target, in dir: URL, dirs: [String: FileWalker.Entry]) -> [URL] {
        let parts = target.path.split(separator: "/").map(String.init)
        guard let last = parts.last else { return [] }
        var candidates: [URL] = []
        if parts.count == 1 {
            if last.contains("*") {
                candidates = dirs.values.filter { fnmatch(last, $0.name, 0) == 0 }.map(\.url)
            } else if let e = dirs[last.lowercased()] {
                candidates = [e.url]
            }
        } else {
            let url = dir.appendingPathComponent(target.path)
            var isDir: ObjCBool = false
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            if attrs?[.type] as? FileAttributeType != .typeSymbolicLink,
               FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                candidates = [url]
            }
        }
        guard !target.keepChildren.isEmpty else { return candidates }
        // Remove the folder's children except the ones to keep.
        return candidates.flatMap { folder in
            FileWalker.list(folder)
                .filter { child in !target.keepChildren.contains { fnmatch($0, child.name, 0) == 0 } }
                .map(\.url)
        }
    }

    static func scanGlobals(_ globals: [GlobalArtifactRule], context: ScanContext, progress: ScanProgress) -> [ArtifactItem] {
        globals.compactMap { rule in
            if Task.isCancelled { return nil }
            let url = context.home.appendingPathComponent(rule.relativePath)
            guard !context.isExcluded(url) else { return nil }
            let children = FileWalker.list(url).filter { $0.name != ".DS_Store" && !context.isExcluded($0.url) }.map(\.url)
            guard !children.isEmpty else { return nil }
            let m = children.reduce(FileWalker.Measurement()) { $0 + context.measure($1, progress: progress, reclaimable: true) }
            return ArtifactItem(
                ruleID: rule.id, ecosystem: rule.ecosystem, projectURL: url, projectName: rule.title,
                targets: children, optIn: false, note: nil, isGlobal: true,
                size: m.size, fileCount: m.files, lastTouched: nil, restoreHint: rule.restoreHint
            )
        }
    }
}
