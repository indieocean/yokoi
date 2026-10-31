import SwiftUI

/// The menu bar helper (PRD §8): free and reclaimable space, last scan, Scan now, Clean Safe caches.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let store = app.store
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AppIconMark(size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Yokoi").font(.system(size: 13, weight: .semibold))
                        .help("Your Mac, garbage collected")
                    Text(store.isScanning ? "Scanning…" : "Last scan \(RelativeDate.ago(store.lastScan?.date))")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                stat("Free", ByteFormat.string(store.disk.available), Theme.success)
                stat("Reclaimable", ByteFormat.string(store.reclaimableTotal), Theme.accentLight)
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

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
