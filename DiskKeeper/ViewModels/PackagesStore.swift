import Foundation
import Observation

/// State for the Package Managers screen (PRD §5.7). Listing is local; checking for updates may
/// contact registries, so it only runs when the user clicks it. Updates and uninstalls always go
/// through a confirmation sheet that shows the exact commands.
@MainActor
@Observable
final class PackagesStore {
    enum Filter: Hashable { case all, outdated, unused }
    enum Action: String { case update = "Update", uninstall = "Uninstall" }

    struct PendingAction: Identifiable {
        let id = UUID()
        let kind: PackageManagerKind
        let action: Action
        let packages: [InstalledPackage]
        var commands: [[String]] {
            packages.map { action == .update ? kind.updateCommand($0.name) : kind.uninstallCommand($0.name) }
        }
    }

    struct CommandLog: Identifiable {
        let id = UUID()
        let package: String
        let result: ProcessRunner.Result?
        let error: String?
        var succeeded: Bool { result?.succeeded ?? false }
    }

    var installed: [PackageManagerKind] = []
    var detected = false
    var selected: PackageManagerKind = .npm
    var packages: [PackageManagerKind: [InstalledPackage]] = [:]
    var checkedOutdated: Set<PackageManagerKind> = []
    var readOnly: [PackageManagerKind: String] = [:]
    var loading: Set<PackageManagerKind> = []
    var lastCommand: ProcessRunner.Result?
    var errorMessage: String?
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
        var found: [PackageManagerKind] = []
        for kind in PackageManagerKind.allCases where await service(kind).isInstalled() {
            found.append(kind)
            readOnly[kind] = await service(kind).readOnlyReason()
        }
        installed = found
        if !found.contains(selected), let first = found.first { selected = first }
        if !found.isEmpty { await refresh(selected) }
    }

    func select(_ kind: PackageManagerKind) async {
        selected = kind
        checked = []
        if packages[kind] == nil { await refresh(kind) }
    }

    func refresh(_ kind: PackageManagerKind) async {
        loading.insert(kind)
        defer { loading.remove(kind) }
        errorMessage = nil
        do {
            let (list, result) = try await service(kind).list()
            lastCommand = result
            if !result.succeeded && list.isEmpty {
                errorMessage = result.stderr.split(separator: "\n").prefix(3).joined(separator: "\n")
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
            errorMessage = error.localizedDescription
        }
    }

    /// Asks the manager which packages are outdated. May contact the package registry.
    func checkOutdated(_ kind: PackageManagerKind) async {
        loading.insert(kind)
        defer { loading.remove(kind) }
        do {
            guard let (latest, result) = try await service(kind).outdated() else {
                errorMessage = kind == .cargo ? "Install cargo-update (`cargo install cargo-update`) to check Cargo packages." : nil
                return
            }
            lastCommand = result
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
            errorMessage = error.localizedDescription
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

    func count(_ kind: PackageManagerKind) -> Int? { packages[kind]?.count }

    var outdatedCount: Int { (packages[selected] ?? []).filter(\.isOutdated).count }
    var unusedCount: Int { (packages[selected] ?? []).filter(\.isUnused).count }
    var totalCount: Int { packages.values.reduce(0) { $0 + $1.count } }

    func toggle(_ id: String) {
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
    }

    var selectedPackages: [InstalledPackage] { (packages[selected] ?? []).filter { checked.contains($0.id) } }

    func request(_ action: Action, _ pkgs: [InstalledPackage]) {
        guard !pkgs.isEmpty, readOnly[selected] == nil else { return }
        pending = PendingAction(kind: selected, action: action, packages: pkgs)
    }

    /// Runs the confirmed commands one at a time, keeping each one's output.
    func perform(_ action: PendingAction) async {
        running = true
        runLog = []
        for (pkg, command) in zip(action.packages, action.commands) {
            do {
                let r = try await runner.run(command, timeout: 900)
                runLog.append(CommandLog(package: pkg.name, result: r, error: nil))
                lastCommand = r
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
