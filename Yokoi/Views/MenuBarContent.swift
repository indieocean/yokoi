import SwiftUI

/// The menu bar helper (PRD §8): free and reclaimable space, last scan, Scan now, Clean Safe caches,
/// the running version and updates. It stays running after the main window is closed.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let store = app.store
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AppIconMark(size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("Yokoi").font(.system(size: 13, weight: .semibold))
                            .help("Your Mac, garbage collected")
                        Tag(text: app.updater.currentVersion, color: Theme.textTertiary)
                    }
                    Text(store.isScanning ? "Scanning…" : "Last scan \(RelativeDate.ago(store.lastScan?.date))")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                stat("Free", ByteFormat.string(store.disk.available), Theme.success)
                stat("Reclaimable", ByteFormat.string(store.reclaimableTotal), Theme.accentLight)
            }

            if case .available(let version) = app.updater.status {
                updateCard(version)
            }

            if store.isScanning {
                ProgressView(value: nil as Double?) { Text("\(CountFormat.compact(store.progress.filesVisited)) files").font(Theme.mono(10.5)) }
                    .controlSize(.small)
            }

            VStack(spacing: 6) {
                Button {
                    store.isScanning ? store.cancelScan() : store.scan()
                } label: {
                    Label(store.isScanning ? "Stop Scan" : "Scan Now", systemImage: store.isScanning ? "stop.fill" : "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.dkPrimary)
                Button {
                    openMain()
                    app.requestSafeCacheClean()
                } label: {
                    Label("Clean Safe Caches…", systemImage: "delete.left").frame(maxWidth: .infinity)
                }
                .buttonStyle(.dkSecondary)
                .disabled(store.caches.isEmpty || store.isScanning)
                Button {
                    openMain()
                } label: {
                    Label("Open Yokoi", systemImage: "macwindow").frame(maxWidth: .infinity)
                }
                .buttonStyle(.dkSecondary)
            }

            HStack {
                if let next = app.scheduler.nextScan {
                    Text("Next scan \(next.formatted(.dateTime.weekday().hour().minute()))")
                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                updateCheck
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(16)
        .frame(width: 290)
        .background(Theme.bgWindow)
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            Text(value).font(Theme.mono(15, .bold)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
    }

    /// Shown when the feed has a newer version: one click opens Sparkle's update window.
    private func updateCard(_ version: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accentLight)
            VStack(alignment: .leading, spacing: 1) {
                Text("Yokoi \(version) is available").font(.system(size: 12, weight: .semibold))
                Text("You have \(app.updater.currentVersion)").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 4)
            Button("Update…") { installUpdate() }
                .buttonStyle(DKButtonStyle(kind: .primary, compact: true))
                .disabled(!app.updater.canCheckForUpdates)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentLight.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accentLight.opacity(0.30)))
    }

    /// "Check for Updates" in the footer, unless an update is already shown (or this is a debug/demo build).
    @ViewBuilder private var updateCheck: some View {
        let updater = app.updater
        let hasUpdate: Bool = if case .available = updater.status { true } else { false }
        if updater.isAvailable && !hasUpdate {
            Button(updater.status == .checking ? "Checking…" : "Check for Updates") { installUpdate() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.accentLight)
                .disabled(!updater.canCheckForUpdates || updater.status == .checking)
                .padding(.trailing, 6)
        }
    }

    /// Sparkle's window: installs the update, or says Yokoi is up to date. Brought to the front even
    /// when Yokoi is running from the menu bar only.
    private func installUpdate() {
        NSApp.activate(ignoringOtherApps: true)
        app.updater.checkForUpdates()
    }

    private func openMain() {
        DockPresence.windowOpened()
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
