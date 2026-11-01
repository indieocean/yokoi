import Foundation

/// Finds every `node_modules` under the scan roots without descending into nested ones (PRD §5.2).
struct NodeModulesScanner: CategoryScanner {
    var category: CleanCategory { .nodeModules }

    func scan(_ context: ScanContext, progress: ScanProgress) -> AsyncStream<NodeModulesItem> {
        makeStream { yield in
            let projects: [URL] = await ProjectWalker.walk(context: context, progress: progress, initial: ()) { dir, entries, _ in
                var visit = ProjectWalker.Visit<Void, URL>(childState: ())
                if let nm = entries.first(where: { $0.name == "node_modules" && $0.isDirectory && !$0.isSymlink }),
                   !context.isExcluded(nm.url) {
                    visit.found = [dir]
                }
                return visit
            }
            let roots = context.rootURLs().map(\.url)
            let skip = Self.lastTouchedSkips
            for await item in FileWalker.concurrentMap(projects, limit: context.concurrency, { project in
                Self.makeItem(project: project, roots: roots, skip: skip, context: context, progress: progress)
            }) {
                yield(item)
            }
        }
    }

    /// Dependency and build folders ignored when working out "last touched".
    static let lastTouchedSkips: Set<String> = {
        var s: Set<String> = ["node_modules", ".git", "dist", "build", "coverage"]
        for rule in ArtifactRule.all { s.formUnion(rule.rootTargetNames) }
        return s
    }()

    static func makeItem(project: URL, roots: [URL], skip: Set<String>, context: ScanContext, progress: ScanProgress?) -> NodeModulesItem? {
        if Task.isCancelled { return nil }
        let nm = project.appendingPathComponent("node_modules")
        let m = context.measure(nm, progress: progress)
        let pkg = readPackageJSON(project)
        return NodeModulesItem(
            url: nm,
            projectURL: project,
            projectName: (pkg?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? project.lastPathComponent,
            frameworkHint: frameworkHint(project: project, packageJSON: pkg),
            packageManager: packageManager(project: project, roots: roots),
            size: m.size,
            fileCount: m.files,
            lastTouched: context.lastTouched(project: project, skipping: skip)
        )
    }

    static func readPackageJSON(_ project: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: project.appendingPathComponent("package.json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Picks the most telling framework from `package.json` (e.g. `next 14`, `electron`, `vite`).
    static func frameworkHint(project: URL, packageJSON: [String: Any]?) -> String {
        let fm = FileManager.default
        if packageJSON?["workspaces"] != nil
            || ["pnpm-workspace.yaml", "lerna.json", "turbo.json", "nx.json"].contains(where: { fm.fileExists(atPath: project.appendingPathComponent($0).path) }) {
            return "monorepo"
        }
        var deps: [String: String] = [:]
        for key in ["dependencies", "devDependencies", "peerDependencies"] {
            if let d = packageJSON?[key] as? [String: Any] {
                for (k, v) in d { deps[k] = v as? String ?? "" }
            }
        }
        func major(_ name: String) -> String? {
            guard let v = deps[name] else { return nil }
            let digits = v.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
            return digits.isEmpty ? nil : String(digits)
        }
        let table: [(String, String)] = [
            ("next", "next"), ("nuxt", "nuxt"), ("@sveltejs/kit", "sveltekit"), ("astro", "astro"),
            ("@remix-run/react", "remix"), ("expo", "expo"), ("react-native", "react-native"), ("electron", "electron"),
            ("@nestjs/core", "nestjs"), ("@angular/core", "angular"), ("gatsby", "gatsby"), ("vite", "vite"),
            ("vue", "vue"), ("svelte", "svelte"), ("react", "react"), ("express", "express"), ("fastify", "fastify"),
            ("tsup", "tsup"), ("ts-node", "ts-node"), ("typescript", "typescript"),
        ]
        for (dep, label) in table where deps[dep] != nil {
            if dep == "next", let m = major("next") { return "next \(m)" }
            return label
        }
        return "node"
    }

    /// Lockfile in the project or a parent (monorepos), stopping at the scan root.
    static func packageManager(project: URL, roots: [URL]) -> JSPackageManager? {
        let fm = FileManager.default
        var dir = project
        for _ in 0..<6 {
            for (file, pm) in JSPackageManager.lockfiles where fm.fileExists(atPath: dir.appendingPathComponent(file).path) {
                return pm
            }
            if roots.contains(where: { $0.path == dir.path }) { break }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }
}
