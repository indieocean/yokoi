import SwiftUI

/// Starts the `yokoi` command-line companion when asked for, otherwise the app.
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if CommandLineTool.isRequested(args) {
            // The CLI's output is read by scripts, so it stays English whatever language the app is in.
            // The argument domain outranks the user's language list and is never written to disk.
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments["AppleLanguages"] = ["en"]
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            exit(CommandLineTool.run(args, settings: SettingsStore.loadStandard))
        }
        if SingleInstance.handOffToRunningCopy() { exit(0) }
        LayoutDirection.matchLanguage()
        YokoiApp.main()
    }
}

/// AppKit mirrors the layout only when the system language reads right to left. When just Yokoi is set to
/// Arabic or Hebrew (System Settings → Language & Region → Applications), the text is translated but the
/// layout stays left to right. AppKit reads these flags from the argument domain (as if passed at launch);
/// that domain is never written to disk.
enum LayoutDirection {
    static func matchLanguage() {
        guard let language = Bundle.main.preferredLocalizations.first,
              Locale.Language(identifier: language).characterDirection == .rightToLeft else { return }
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        for key in ["AppleTextDirection", "NSForceRightToLeftWritingDirection"] where arguments[key] == nil {
            arguments[key] = true
        }
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
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

/// Keeps Yokoi alive in the menu bar after its window is closed (otherwise closing the last window quits).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(Self.model?.settings.data.showInMenuBar ?? false)
    }
}

/// With the window closed and the menu bar item on, Yokoi lives in the menu bar only: no Dock icon,
/// no app menu. Opening the window (menu bar, Dock, Spotlight, Shortcuts) makes it a regular app again.
@MainActor
enum DockPresence {
    static func windowOpened() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    static func windowClosed(menuBarShown: Bool) {
        if menuBarShown { NSApp.setActivationPolicy(.accessory) }
    }
}

struct YokoiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
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
                    app.isMainWindowOpen = true
                    DockPresence.windowOpened()
                    #if DEBUG
                    if SnapshotDriver.outputDirectory != nil {
                        Task { await SnapshotDriver.run(app) }
                        return
                    }
                    #endif
                    app.onLaunch()
                }
                .onDisappear {
                    app.isMainWindowOpen = false
                    DockPresence.windowClosed(menuBarShown: app.settings.data.showInMenuBar)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 920)
        .commands {
            CommandGroup(after: .appInfo) {
                if app.updater.isAvailable {
                    Button("Check for Updates…") { app.updater.checkForUpdates() }
                        .disabled(!app.updater.canCheckForUpdates)
                }
            }
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
        MenuBarExtra(isInserted: Binding(get: { app.settings.data.showInMenuBar }, set: { shown in
            guard app.settings.data.showInMenuBar != shown else { return }
            app.settings.data.showInMenuBar = shown
            // ⌘-dragged out of the menu bar while the window is closed: nothing would be left to reach Yokoi.
            if !shown && !app.isMainWindowOpen { NSApp.terminate(nil) }
        })) {
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
