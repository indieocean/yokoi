import Foundation

/// One scanner per category. Results stream out as they're found so the UI fills in live.
/// Cancelling the consuming task cancels the scan.
protocol CategoryScanner: Sendable {
    associatedtype Item: Reclaimable
    var category: CleanCategory { get }
    func scan(_ context: ScanContext, progress: ScanProgress) -> AsyncStream<Item>
}

extension CategoryScanner {
    /// Convenience for tests and one-shot callers.
    func collect(_ context: ScanContext, progress: ScanProgress = ScanProgress()) async -> [Item] {
        var out: [Item] = []
        for await item in scan(context, progress: progress) { out.append(item) }
        return out
    }

    /// Wraps an async producer in a cancellable stream.
    func makeStream(_ body: @escaping @Sendable (_ yield: @escaping @Sendable (Item) -> Void) async -> Void) -> AsyncStream<Item> {
        AsyncStream { continuation in
            let task = Task {
                await body { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Parallel, pruning directory walk used to discover projects.
/// The root itself is visited inline; each child subtree is walked in its own task (`TaskGroup`).
enum ProjectWalker {
    struct Visit<State: Sendable, Found: Sendable>: Sendable {
        var found: [Found] = []
        /// Child names that must not be descended into (matched targets).
        var claimed: Set<String> = []
        var childState: State
    }

    typealias Visitor<State: Sendable, Found: Sendable> =
        @Sendable (_ dir: URL, _ entries: [FileWalker.Entry], _ state: State) -> Visit<State, Found>

    static func walk<State: Sendable, Found: Sendable>(
        context: ScanContext,
        progress: ScanProgress,
        initial: State,
        visit: @escaping Visitor<State, Found>
    ) async -> [Found] {
        let home = context.home.standardizedFileURL
        let roots = context.roots.filter { !isSystemRoot($0) }.map { ($0.url(home: home), $0.maxDepth) }
        // Skip roots nested inside other roots so nothing is reported twice.
        let unique = roots.filter { r in !roots.contains { o in o.0 != r.0 && r.0.path.hasPrefix(o.0.path + "/") } }

        return await withTaskGroup(of: [Found].self) { group in
            for (rootURL, maxDepth) in unique {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDir), isDir.boolValue,
                      !context.isExcluded(rootURL) else { continue }
                let entries = FileWalker.list(rootURL)
                progress.visited(folders: 1, path: rootURL.path)
                let result = visit(rootURL, entries, initial)
                let rootFound = result.found
                group.addTask { rootFound }
                if let maxDepth, maxDepth < 1 { continue }
                for child in descendable(entries, claimed: result.claimed, context: context, home: home) {
                    let state = result.childState
                    group.addTask {
                        subtree(child, state: state, depth: 1, maxDepth: maxDepth, context: context, home: home, progress: progress, visit: visit)
                    }
                }
            }
            var all: [Found] = []
            for await part in group { all += part }
            return all
        }
    }

    /// Roots under `~/Library` (e.g. `~/Library/Developer`) are cleanup locations, not project folders.
    static func isSystemRoot(_ root: ScanRoot) -> Bool {
        root.path.hasPrefix("~/Library") || root.path.hasPrefix("/Library")
    }

    private static func subtree<State: Sendable, Found: Sendable>(
        _ start: URL, state: State, depth: Int, maxDepth: Int?,
        context: ScanContext, home: URL, progress: ScanProgress, visit: Visitor<State, Found>
    ) -> [Found] {
        var found: [Found] = []
        var stack: [(URL, State, Int)] = [(start, state, depth)]
        var folders = 0
        while let (dir, st, d) = stack.popLast() {
            if Task.isCancelled { break }
            let entries = FileWalker.list(dir)
            folders += 1
            if folders % 64 == 0 { progress.visited(files: 0, folders: 64, path: dir.path) }
            let result = visit(dir, entries, st)
            found += result.found
            if let maxDepth, d + 1 > maxDepth { continue }
            for child in descendable(entries, claimed: result.claimed, context: context, home: home) {
                stack.append((child, result.childState, d + 1))
            }
        }
        progress.visited(folders: folders % 64)
        return found
    }

    private static func descendable(_ entries: [FileWalker.Entry], claimed: Set<String>, context: ScanContext, home: URL) -> [URL] {
        let library = PathFormat.canonical(home.appendingPathComponent("Library").path)
        return entries.compactMap { e in
            guard e.isDirectory, !e.isSymlink, !e.isPackage,
                  !e.name.hasPrefix("."),
                  !claimed.contains(e.name),
                  !ArtifactRule.skippedDirectoryNames.contains(e.name),
                  PathFormat.canonical(e.url.path) != library,
                  !context.isExcluded(e.url) else { return nil }
            return e.url
        }
    }
}

/// Events emitted by the scan engine as results arrive.
enum ScanEvent: Sendable {
    case nodeModules(NodeModulesItem)
    case artifact(ArtifactItem)
    case cache(CacheItem)
    case bigFile(BigFileItem)
    case screenshot(ScreenshotItem)
    case download(DownloadItem)
    case application(AppItem)
    case finished(CleanCategory)
}

/// Runs every category scanner in parallel and funnels results into one stream.
actor ScanEngine {
    private(set) var isRunning = false
    private(set) var lastDuration: TimeInterval = 0

    func run(_ context: ScanContext, progress: ScanProgress, categories: Set<CleanCategory> = Set(CleanCategory.allCases)) -> AsyncStream<ScanEvent> {
        isRunning = true
        let start = Date()
        let (stream, continuation) = AsyncStream<ScanEvent>.makeStream()
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                if categories.contains(.nodeModules) {
                    group.addTask { await Self.forward(NodeModulesScanner(), context, progress, continuation, ScanEvent.nodeModules) }
                }
                if categories.contains(.buildArtifacts) {
                    group.addTask { await Self.forward(BuildArtifactScanner(), context, progress, continuation, ScanEvent.artifact) }
                }
                if categories.contains(.caches) {
                    group.addTask { await Self.forward(CacheScanner(), context, progress, continuation, ScanEvent.cache) }
                }
                if categories.contains(.bigFiles) {
                    group.addTask { await Self.forward(BigFileScanner(), context, progress, continuation, ScanEvent.bigFile) }
                }
                if categories.contains(.downloads) {
                    group.addTask { await Self.forward(DownloadsScanner(), context, progress, continuation, ScanEvent.download) }
                }
                if categories.contains(.screenshots) {
                    group.addTask { await Self.forward(ScreenshotScanner(), context, progress, continuation, ScanEvent.screenshot) }
                }
                if categories.contains(.applications) {
                    group.addTask { await Self.forward(ApplicationScanner(), context, progress, continuation, ScanEvent.application) }
                }
            }
            self.finish(duration: Date().timeIntervalSince(start))
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func finish(duration: TimeInterval) {
        isRunning = false
        lastDuration = duration
    }

    private static func forward<S: CategoryScanner>(
        _ scanner: S, _ context: ScanContext, _ progress: ScanProgress,
        _ continuation: AsyncStream<ScanEvent>.Continuation, _ wrap: @Sendable (S.Item) -> ScanEvent
    ) async {
        for await item in scanner.scan(context, progress: progress) {
            progress.found()
            continuation.yield(wrap(item))
        }
        continuation.yield(.finished(scanner.category))
    }
}
