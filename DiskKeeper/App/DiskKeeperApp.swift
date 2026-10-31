import SwiftUI

@main
struct DiskKeeperApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup("Disk Keeper", id: "main") {
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
