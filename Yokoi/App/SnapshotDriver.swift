#if DEBUG
import AppKit
import SwiftUI

/// Debug-only: `Yokoi -DKSnapshotDir /path` waits for a scan, renders every screen to PNG
/// and quits. Used to compare the build against the mockups without screen-recording permission.
@MainActor
enum SnapshotDriver {
    static var outputDirectory: URL? {
        UserDefaults.standard.string(forKey: "DKSnapshotDir").map { URL(fileURLWithPath: $0) }
    }

    static func run(_ app: AppModel) async {
        guard let dir = outputDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if app.store.isDemo {
            if UserDefaults.standard.bool(forKey: "DKCaptureCleanupAnimation") {
                await runAnimationCapture(app, dir: dir)
            } else {
                await runReadmeCapture(app, dir: dir)
            }
            return
        }
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

    /// Demo mode: the README screenshot set at the mockups' 1280×820 window size.
    static func runReadmeCapture(_ app: AppModel, dir: URL) async {
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) {
            window.setContentSize(NSSize(width: 1280, height: 820))
            window.center()
        }
        func shot(_ name: String, _ wait: Int = 900) async {
            try? await Task.sleep(for: .milliseconds(wait))
            capture(dir.appendingPathComponent(name + ".png"))
        }
        try? await Task.sleep(for: .seconds(1.5))

        app.screen = .dashboard
        await shot("dashboard", 1200)

        app.packages.npmMode = .projects
        app.screen = .nodeModules            // routes to Package Managers → npm
        await app.packages.loadIfNeeded()
        await shot("npm-node-modules")

        app.screen = .buildArtifacts
        await shot("build-artifacts")

        app.screen = .caches
        await app.tools.refresh()
        await shot("caches")

        // The same screen with old simulators and archives opened and the old ones picked.
        for id in ["simulator-devices", "xcode-archives"] {
            guard let item = app.store.caches.first(where: { $0.id == id }) else { continue }
            app.cachesVM.expanded.insert(id)
            app.cachesVM.selectAllButNewest(item)
        }
        await shot("caches-items")

        app.screen = .duplicates
        await shot("duplicates")

        app.screen = .downloads
        app.downloadsVM.selectLeftovers()
        await shot("downloads")

        app.screen = .applications
        await shot("applications")

        app.screen = .packageManagers
        await app.packages.select(.npm)
        await app.packages.setNpmMode(.global)
        await shot("package-managers")
        app.packages.npmMode = .projects

        app.screen = .externalDrives
        if let drive = app.settings.externalDrives.first { await app.drivesVM.scan(drive) }
        await shot("external-drives")

        app.screen = .screenshots
        app.screenshotsVM.selectOlderThanThreshold()
        await shot("screenshots", 2000)

        // The cleanup overlay (simulated in demo mode).
        app.screen = .dashboard
        try? await Task.sleep(for: .milliseconds(600))
        let entries = app.store.smartSelection()
        let run = Task { await app.run(entries, action: .trash) }
        await shot("cleaning", 1700)
        await run.value
        await shot("cleaned", 1300)
        app.dismissActivity()

        try? await Task.sleep(for: .milliseconds(300))
        NSApp.terminate(nil)
    }

    /// Demo mode: records the cleanup overlay as numbered PNG frames plus an ffmpeg concat list
    /// (`frames.txt`) with each frame's real duration. `scripts/make-cleanup-gif.sh` turns it into a GIF.
    static func runAnimationCapture(_ app: AppModel, dir: URL) async {
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) {
            window.setContentSize(NSSize(width: 1280, height: 820))
            window.center()
        }
        app.screen = .dashboard
        try? await Task.sleep(for: .seconds(1.5))

        let queue = DispatchQueue(label: "frames", qos: .userInitiated)
        var stamps: [(String, Date)] = []
        var index = 0
        func frame() {
            guard let image = windowImage(nominal: true) else { return }
            let name = String(format: "frame-%04d.png", index)
            index += 1
            stamps.append((name, Date()))
            let url = dir.appendingPathComponent(name)
            queue.async {
                if let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try? data.write(to: url)
                }
            }
        }

        // A short beat of the dashboard, then the cleanup, then hold on the result.
        let start = Date()
        while Date().timeIntervalSince(start) < 0.5 { frame(); try? await Task.sleep(for: .milliseconds(66)) }
        let run = Task { await app.run(app.store.smartSelection(), action: .trash) }
        while !(app.activity?.isFinished ?? false) { frame(); try? await Task.sleep(for: .milliseconds(66)) }
        let end = Date()
        while Date().timeIntervalSince(end) < 2.2 { frame(); try? await Task.sleep(for: .milliseconds(66)) }
        await run.value

        var list = "ffconcat version 1.0\n"
        for (i, (name, date)) in stamps.enumerated() {
            let next = i + 1 < stamps.count ? stamps[i + 1].1 : date.addingTimeInterval(1.5)
            list += "file '\(name)'\nduration \(String(format: "%.3f", next.timeIntervalSince(date)))\n"
        }
        // The concat demuxer ignores the last duration unless the file is repeated.
        if let last = stamps.last { list += "file '\(last.0)'\n" }
        queue.sync {}
        try? list.write(to: dir.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
        app.dismissActivity()
        try? await Task.sleep(for: .milliseconds(300))
        NSApp.terminate(nil)
    }

    /// `nominal` captures at 1× (kCGWindowImageNominalResolution), which is much cheaper per frame.
    private static func windowImage(nominal: Bool = false) -> CGImage? {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil && $0.contentView != nil }) else { return nil }
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(sym, to: CreateImage.self)
        return create(.null, 1 << 3, UInt32(window.windowNumber), nominal ? (1 << 0 | 1 << 4) : 1 << 0)?.takeRetainedValue()
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
