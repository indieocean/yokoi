import SwiftUI

/// Starts the `yokoi` command-line companion when asked for, otherwise the app.
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if CommandLineTool.isRequested(args) {
            exit(CommandLineTool.run(args, settings: SettingsStore.loadStandard))
        }
        if SingleInstance.handOffToRunningCopy() { exit(0) }
        YokoiApp.main()
    }
}

/// Only one Yokoi runs at a time, even with several copies on disk (Applications, the mounted DMG,
/// a build folder). A second launch brings the running one forward and quits.
enum SingleInstance {
    static func handOffToRunningCopy() -> Bool {
        #if DEBUG
        return false  // let a debug build run next to the installed app
        #else
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        guard let other = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first(where: { $0.processIdentifier != me && !$0.isTerminated }),
            let url = other.bundleURL else { return false }
        // Opening the running copy's bundle reactivates it and reopens its window if it was closed.
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in done.signal() }
        _ = done.wait(timeout: .now() + 5)
        return true
        #endif
    }
}

struct YokoiApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        // A single window: opening it again (menu bar, Dock) brings it forward instead of adding another.
        Window("Yokoi", id: "main") {
            RootView()
                .environment(app)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .frame(minWidth: 1080, minHeight: 680)
                .onChange(of: app.settings.data) { app.scheduler.configure() }
                .onAppear {
                    #if DEBUG
                    if SnapshotDriver.outputDirectory != nil {
                        Task { await SnapshotDriver.run(app) }
                        return
                    }
                    #endif
                    app.onLaunch()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scan") {
                Button(app.store.isScanning ? "Stop Scan" : "Scan Everything") {
                    app.store.isScanning ? app.store.cancelScan() : app.store.scan()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Rescan This Screen") { app.rescan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(app.store.isScanning)
                Divider()
                Button("Reveal Cleanup Log") { Finder.reveal([app.store.logURL]) }
            }
            CommandGroup(after: .sidebar) {
                // ⌘1…⌘9 for the first nine screens (a "10" key equivalent would trap).
                ForEach(Array(Screen.allCases.enumerated()), id: \.element) { index, screen in
                    if index < 9 {
                        Button(screen.title) { app.screen = screen }
                            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    } else {
                        Button(screen.title) { app.screen = screen }
                    }
                }
            }
        }

        // Only write when the value really changes: MenuBarExtra pushes the value back on every
        // scene update, and an unconditional write re-renders the scene forever (froze the app).
        MenuBarExtra(isInserted: Binding(get: { app.settings.data.showInMenuBar },
                                         set: { if app.settings.data.showInMenuBar != $0 { app.settings.data.showInMenuBar = $0 } })) {
            MenuBarContent()
                .environment(app)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        } label: {
            Image(systemName: "internaldrive")
        }
        .menuBarExtraStyle(.window)
    }
}
