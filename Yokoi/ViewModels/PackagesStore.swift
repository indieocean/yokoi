import Foundation
import Observation

/// State for the Package Managers screen (PRD §5.7). Listing is local; checking for updates may
/// contact registries, so it only runs when the user clicks it. Updates and uninstalls always go
/// through a confirmation sheet that shows the exact commands.
@MainActor
@Observable
final class PackagesStore {
    enum Filter: Hashable { case all, outdated, unused }
    /// The npm tab shows project node_modules folders or global `npm -g` packages.
    enum NpmMode: Hashable { case projects, global }
    enum Action: String { case update = "Update", uninstall = "Uninstall" }

    struct PendingAction: Identifiable {
        let id = UUID()
        let kind: PackageManagerKind
        let action: Action
        let packages: [InstalledPackage]
        /// The manager's absolute path, so the sheet shows exactly what runs. Nil leaves the bare name (demo mode).
        var executable: String? = nil
        var commands: [[String]] {
            packages.compactMap { p -> [String]? in
                guard let c = action == .update ? kind.updateCommand(p.commandTarget) : kind.uninstallCommand(p.commandTarget) else { return nil }
                return executable.map { [$0] + c.dropFirst() } ?? c
            }
        }
    }

    struct CommandLog: Identifiable {
        let id = UUID()
        let package: String
        let result: ProcessRunner.Result?
        let error: String?
        var succeeded: Bool { result?.succeeded ?? false }
    }

    var installed: [PackageManagerKind] = [.npm]
    var npmMode: NpmMode = .projects
    /// Whether the `npm` executable was found (the npm tab exists either way, for node_modules).
    var npmToolFound = false
    var detected = false
    var selected: PackageManagerKind = .npm
    var packages: [PackageManagerKind: [InstalledPackage]] = [:]
    var checkedOutdated: Set<PackageManagerKind> = []
    var readOnly: [PackageManagerKind: String] = [:]
    var loading: Set<PackageManagerKind> = []
    /// The last command run and the last error, per manager, so the strip matches the selected tab.
    var lastCommands: [PackageManagerKind: ProcessRunner.Result] = [:]
    var errors: [PackageManagerKind: String] = [:]
    var lastCommand: ProcessRunner.Result? { lastCommands[selected] }
    var errorMessage: String? { errors[selected] }
    var filter: Filter = .all
    var checked: Set<String> = []
    var pending: PendingAction?
    var running = false
    var runLog: [CommandLog] = []

    let store: ScanStore
    private let runner = ProcessRunner.shared

    init(store: ScanStore) { self.store = store }

    func service(_ kind: PackageManagerKind) -> PackageManagerService { PackageManagerService(kind: kind, runner: runner) }

    /// Detects installed managers, then lists the selected one.
    func loadIfNeeded() async {
        guard !detected else { return }
        detected = true
        if store.isDemo {
            let demo = DemoData.packages()
            packages = demo
            npmToolFound = true
            installed = [.npm, .pnpm, .bun, .homebrew, .casks, .cargo, .go, .pip, .pipx, .uv]
            checkedOutdated = Set(demo.keys)
            for kind in installed {
                lastCommands[kind] = ProcessRunner.Result(command: kind.outdatedCommand ?? kind.listCommand, exitCode: 0, stdout: "",
                                                          stderr: "", duration: 1.4, timedOut: false)
            }
            return
        }
        var found: [PackageManagerKind] = [.npm]
        for kind in PackageManagerKind.allCases where await service(kind).isInstalled() {
            if kind == .npm { npmToolFound = true } else { found.append(kind) }
            readOnly[kind] = await service(kind).readOnlyReason()
        }
        installed = found
        if !found.contains(selected) { selected = .npm }
        if !showingProjects { await refresh(selected) }
    }

    /// The npm tab in node_modules mode shows project folders instead of the package table.
    var showingProjects: Bool { selected == .npm && npmMode == .projects }

    func select(_ kind: PackageManagerKind) async {
        selected = kind
        checked = []
        if !showingProjects, packages[kind] == nil { await refresh(kind) }
    }

    func setNpmMode(_ mode: NpmMode) async {
        npmMode = mode
        checked = []
        if mode == .global, npmToolFound, packages[.npm] == nil { await refresh(.npm) }
    }

    func refresh(_ kind: PackageManagerKind) async {
        if store.isDemo { return }
        loading.insert(kind)
        defer { loading.remove(kind) }
        errors[kind] = nil
        do {
            let (list, result) = try await service(kind).list()
            lastCommands[kind] = result
            if !result.succeeded && list.isEmpty {
                errors[kind] = result.stderr.split(separator: "\n").prefix(3).joined(separator: "\n")
            }
            var merged = list
            // Keep update info from an earlier check.
            if let old = packages[kind] {
                let latest = Dictionary(old.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
                merged = list.map { p in
                    var p = p
                    if let o = latest[p.name], o.status != .unknown {
                        p.latestVersion = o.latestVersion
                        p.status = o.latestVersion == p.installedVersion ? .upToDate : o.status
                    }
                    return p
                }
            }
            packages[kind] = merged
            updateReclaimable()
        } catch {
            errors[kind] = error.localizedDescription
        }
    }

    /// Asks the manager which packages are outdated. May contact the package registry.
    func checkOutdated(_ kind: PackageManagerKind) async {
        if store.isDemo { return }
        loading.insert(kind)
        defer { loading.remove(kind) }
        do {
            guard let (latest, result) = try await service(kind).outdated() else {
                errors[kind] = kind == .cargo ? "Install cargo-update (`cargo install cargo-update`) to check Cargo packages." : nil
                return
            }
            lastCommands[kind] = result
            checkedOutdated.insert(kind)
            packages[kind] = (packages[kind] ?? []).map { p in
                var p = p
                if let v = latest[p.name], v != p.installedVersion {
                    p.latestVersion = v
                    p.status = .outdated
                } else {
                    p.latestVersion = p.installedVersion
                    p.status = .upToDate
                }
                return p
            }
        } catch {
            errors[kind] = error.localizedDescription
        }
    }

    func visible(search: String) -> [InstalledPackage] {
        (packages[selected] ?? [])
            .filter {
                switch filter {
                case .all: true
                case .outdated: $0.isOutdated
                case .unused: $0.isUnused
                }
            }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    func count(_ kind: PackageManagerKind) -> Int? {
        kind == .npm ? store.nodeModules.count : packages[kind]?.count
    }

    var outdatedCount: Int { (packages[selected] ?? []).filter(\.isOutdated).count }
    var unusedCount: Int { (packages[selected] ?? []).filter(\.isUnused).count }
    var totalCount: Int { packages.values.reduce(0) { $0 + $1.count } }

    func toggle(_ id: String) {
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
    }

    var selectedPackages: [InstalledPackage] { (packages[selected] ?? []).filter { checked.contains($0.id) } }

    /// Whether `action` is possible for this package (manager supports it, package isn't locked).
    func can(_ action: Action, _ p: InstalledPackage) -> Bool {
        guard readOnly[p.manager] == nil, p.locked == nil else { return false }
        return action == .update ? p.manager.updateCommand(p.commandTarget) != nil : p.manager.uninstallCommand(p.commandTarget) != nil
    }

    func request(_ action: Action, _ pkgs: [InstalledPackage]) {
        let allowed = pkgs.filter { can(action, $0) }
        guard !allowed.isEmpty else { return }
        let kind = selected
        let pendingAction = PendingAction(kind: kind, action: action, packages: allowed)
        if store.isDemo { pending = pendingAction; return }
        Task {
            // Resolve the tool first: the sheet shows its full path, and that same path is what runs.
            guard let tool = pendingAction.commands.first?.first, let exe = await runner.which(tool) else {
                errors[kind] = "\(kind.title) isn't installed, or only in a folder another account can write to."
                return
            }
            var resolved = pendingAction
            resolved.executable = exe
            pending = resolved
        }
    }

    /// Runs the confirmed commands one at a time, keeping each one's output.
    func perform(_ action: PendingAction) async {
        if store.isDemo { return }
        running = true
        runLog = []
        for (pkg, command) in zip(action.packages, action.commands) {
            do {
                let r = try await runner.run(command, timeout: 900)
                runLog.append(CommandLog(package: pkg.name, result: r, error: nil))
                lastCommands[action.kind] = r
                await store.logCommand(r, category: .packages, label: "\(action.action.rawValue) \(pkg.name)",
                                       size: action.action == .uninstall ? (pkg.size ?? 0) : 0)
            } catch {
                runLog.append(CommandLog(package: pkg.name, result: nil, error: error.localizedDescription))
            }
        }
        running = false
        checked = []
        await refresh(action.kind)
    }

    private func updateReclaimable() {
        store.packagesReclaimable = packages.values.flatMap { $0 }.filter(\.isUnused).reduce(0) { $0 + ($1.size ?? 0) }
    }
}
