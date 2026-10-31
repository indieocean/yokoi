#if DEBUG
import AppKit
import SwiftUI

/// Debug-only: `DiskKeeper -DKSnapshotDir /path` waits for a scan, renders every screen to PNG
/// and quits. Used to compare the build against the mockups without screen-recording permission.
@MainActor
enum SnapshotDriver {
    static var outputDirectory: URL? {
        UserDefaults.standard.string(forKey: "DKSnapshotDir").map { URL(fileURLWithPath: $0) }
    }

    static func run(_ app: AppModel) async {
        guard let dir = outputDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        app.showOnboarding = false
        if !app.store.isScanning { app.store.scan() }
        let deadline = Date().addingTimeInterval(240)
        while app.store.isScanning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(500))
        }
        try? await Task.sleep(for: .seconds(1))

        for (i, screen) in Screen.allCases.enumerated() {
            app.screen = screen
            try? await Task.sleep(for: .milliseconds(900))
            capture(dir.appendingPathComponent(String(format: "%02d-%@.png", i + 1, screen.rawValue)))
        }

        // The confirmation sheet, using whatever node_modules are selected (or the first few).
        app.screen = .nodeModules
        try? await Task.sleep(for: .milliseconds(500))
        let vm = app.nodeModulesVM
        if vm.checked.isEmpty { vm.checked = Set(app.store.nodeModules.prefix(5).map(\.id)) }
        if !vm.checked.isEmpty {
            app.pendingCleanup = vm.cleanupRequest()
            try? await Task.sleep(for: .milliseconds(1200))
            capture(dir.appendingPathComponent("10-confirm.png"), sheet: true)
            app.pendingCleanup = nil
        }
        // The cleanup overlay, driven by a *dry run* so nothing on disk changes.
        let wasDryRun = app.settings.data.dryRun
        app.settings.data.dryRun = true
        app.screen = .dashboard
        let entries = Array(app.store.smartSelection().prefix(12))
        if !entries.isEmpty {
            let run = Task { await app.run(entries, action: .delete) }
            try? await Task.sleep(for: .milliseconds(650))
            capture(dir.appendingPathComponent("11-cleaning.png"))
            await run.value
            try? await Task.sleep(for: .milliseconds(1200))
            capture(dir.appendingPathComponent("12-cleaned.png"))
            app.dismissActivity()
        }
        app.settings.data.dryRun = wasDryRun

        try? await Task.sleep(for: .milliseconds(300))
        NSApp.terminate(nil)
    }

    private static func capture(_ url: URL, sheet: Bool = false) {
        guard let main = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil && $0.contentView != nil }) else { return }
        let window = sheet ? (main.attachedSheet ?? main) : main
        // Prefer a real window-server capture (includes vibrancy). An app may always capture its own
        // windows. The API is obsoleted in the current SDK, so it's looked up at runtime.
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let create = unsafeBitCast(sym, to: CreateImage.self)
            // .optionIncludingWindow = 1 << 3, .boundsIgnoreFraming = 1 << 0
            if let image = create(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue() {
                let rep = NSBitmapImageRep(cgImage: image)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: url)
                    return
                }
            }
        }
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }
}
#endif
