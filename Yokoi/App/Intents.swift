import AppIntents
import Foundation

// Shortcuts and Siri actions. They scan, report and navigate; none of them deletes anything.
// Cleaning always goes through the app's confirmation sheet.

enum ScanCategoryOption: String, AppEnum {
    case nodeModules, buildArtifacts, caches, bigFiles, downloads, screenshots, applications

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Category"
    static let caseDisplayRepresentations: [ScanCategoryOption: DisplayRepresentation] = [
        .nodeModules: "node_modules",
        .buildArtifacts: "Build artifacts",
        .caches: "Caches & Tooling",
        .bigFiles: "Big files",
        .downloads: "Downloads",
        .screenshots: "Screenshots",
        .applications: "Applications",
    ]

    var category: CleanCategory { CleanCategory(rawValue: rawValue)! }
}

enum ScreenOption: String, AppEnum {
    case dashboard, caches, buildArtifacts, packageManagers, bigFiles, downloads, screenshots, applications, externalDrives

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Screen"
    static let caseDisplayRepresentations: [ScreenOption: DisplayRepresentation] = [
        .dashboard: "Dashboard",
        .caches: "Caches & Tooling",
        .buildArtifacts: "Build Artifacts",
        .packageManagers: "Package Managers",
        .bigFiles: "Big Files",
        .downloads: "Downloads",
        .screenshots: "Screenshots",
        .applications: "Applications",
        .externalDrives: "External Drives",
    ]

    var screen: Screen { Screen(rawValue: rawValue) ?? .dashboard }
}

/// Scans in the background and returns the reclaimable space in bytes.
struct ScanReclaimableSpaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan for Reclaimable Space"
    static let description = IntentDescription(
        "Scans your Mac with Yokoi's settings and returns how many bytes could be reclaimed. Nothing is deleted.")
    static let openAppWhenRun = false

    @Parameter(title: "Only these categories", description: "Leave empty to scan everything.")
    var categories: [ScanCategoryOption]?

    static var parameterSummary: some ParameterSummary {
        Summary("Scan \(\.$categories) for reclaimable space")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let wanted = categories.map { Set($0.map(\.category)) }.flatMap { $0.isEmpty ? nil : $0 } ?? Set(ScanReport.scannable)
        let report = await ScanReport.run(settings: SettingsStore.loadStandard(), categories: wanted, index: ScanIndex.defaultURL)
        let top = report.categories.filter { $0.reclaimableBytes > 0 }.sorted { $0.reclaimableBytes > $1.reclaimableBytes }.prefix(3)
        // The report's titles are for the English-only CLI, so take the category's own (localized) title here.
        let breakdown = top.map { c in
            let title = CleanCategory(rawValue: c.id)?.title ?? c.title
            return String(localized: "\(title) \(ByteFormat.string(c.reclaimableBytes))",
                          comment: "Shortcuts dialog breakdown entry: category name, then a size like 1.2 GB")
        }.joined(separator: ", ")
        let total = ByteFormat.string(report.reclaimableBytes)
        let dialog = if report.reclaimableBytes == 0 {
            String(localized: "Nothing to reclaim right now.", comment: "Shortcuts dialog")
        } else if breakdown.isEmpty {
            String(localized: "\(total) reclaimable.", comment: "Shortcuts dialog; placeholder is a size like 12 GB")
        } else {
            String(localized: "\(total) reclaimable: \(breakdown).",
                   comment: "Shortcuts dialog; first placeholder is a size like 12 GB, second a list of categories with sizes")
        }
        return .result(value: Int(report.reclaimableBytes), dialog: IntentDialog(stringLiteral: dialog))
    }
}

/// Free space on the startup volume, in bytes.
struct GetFreeSpaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Free Disk Space"
    static let description = IntentDescription("Returns the free space on the disk that holds your home folder, in bytes.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let disk = ScanReport.currentDisk()
        return .result(value: Int(disk.freeBytes),
                       dialog: IntentDialog(stringLiteral: String(
                           localized: "\(ByteFormat.string(disk.freeBytes)) free of \(ByteFormat.string(disk.totalBytes)) on \(disk.name).",
                           comment: "Shortcuts dialog: free size, total size, disk name")))
    }
}

/// Opens Yokoi on a screen, ready to review and clean.
struct OpenYokoiScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Yokoi"
    static let description = IntentDescription("Opens Yokoi on the screen you choose.")
    static let openAppWhenRun = true

    @Parameter(title: "Screen", default: .dashboard)
    var screen: ScreenOption

    static var parameterSummary: some ParameterSummary {
        Summary("Open Yokoi on \(\.$screen)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.open(screen.screen)
        return .result()
    }
}

struct YokoiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ScanReclaimableSpaceIntent(),
                    phrases: ["How much space can \(.applicationName) free?", "Scan my Mac with \(.applicationName)"],
                    shortTitle: "Reclaimable Space", systemImageName: "internaldrive")
        AppShortcut(intent: GetFreeSpaceIntent(),
                    phrases: ["How much disk space is free in \(.applicationName)?"],
                    shortTitle: "Free Space", systemImageName: "chart.pie")
        AppShortcut(intent: OpenYokoiScreenIntent(),
                    phrases: ["Open \(.applicationName)", "Show \(\.$screen) in \(.applicationName)"],
                    shortTitle: "Open Yokoi", systemImageName: "macwindow")
    }
}

/// Hands navigation from an intent to the app model, even if the intent runs before the window exists.
@MainActor
enum IntentRouter {
    private static weak var model: AppModel?
    private static var pending: Screen?

    static func attach(_ model: AppModel) {
        self.model = model
        if let pending { model.screen = pending; self.pending = nil }
    }

    static func open(_ screen: Screen) {
        if let model { model.screen = screen } else { pending = screen }
    }
}
