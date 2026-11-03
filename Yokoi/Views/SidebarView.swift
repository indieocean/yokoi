import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        List(selection: Binding(get: { app.screen }, set: { if let s = $0 { app.screen = s } })) {
            Section {
                row(.dashboard)
            } header: { SectionLabel(text: "Overview") }

            Section {
                row(.buildArtifacts)
                row(.caches)
                row(.bigFiles)
                row(.duplicates)
                row(.downloads)
                row(.screenshots)
                row(.applications)
                row(.externalDrives)
            } header: { SectionLabel(text: "Clean") }

            Section {
                row(.packageManagers)
                row(.settings)
            } header: { SectionLabel(text: "Manage") }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(
            LinearGradient(colors: [Theme.bgSidebarTop, Theme.bgSidebarBottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .safeAreaInset(edge: .top, spacing: 0) { brand }
        .safeAreaInset(edge: .bottom, spacing: 0) { DiskCapsule().padding(12) }
        .toolbar(removing: .sidebarToggle)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            AppIconMark(size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text("Yokoi").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("Your Mac, garbage collected").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private func row(_ screen: Screen, indent: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: screen.symbol)
                .font(.system(size: 12.5))
                .frame(width: 18)
                .foregroundStyle(app.screen == screen ? Theme.accentLight : Theme.textSecondary)
            Text(screen.title)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if let count = count(for: screen) {
                Text(count)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textSecondary)
            } else if let category = screen.category, app.store.scanningCategories.contains(category) {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.vertical, 3)
        .padding(.leading, indent ? 16 : 0)
        .tag(screen)
        .accessibilityElement(children: .combine)
    }

    private func count(for screen: Screen) -> String? {
        let store = app.store
        if let category = screen.category, store.scanningCategories.contains(category) { return nil }
        switch screen {
        case .duplicates:
            let total = store.duplicatesReclaimable
            return total > 0 ? ByteFormat.compact(total) : nil
        case .screenshots:
            return store.screenshots.isEmpty ? nil : "\(store.screenshots.count)"
        case .applications:
            return store.applications.isEmpty ? nil : "\(store.applications.count)"
        case .externalDrives:
            let n = app.settings.externalDrives.count
            return n > 0 ? "\(n)" : nil
        case .packageManagers:
            let n = app.packages.totalCount
            return n > 0 ? "\(n)" : nil
        default:
            guard let category = screen.category else { return nil }
            let total = store.total(category)
            return total > 0 ? ByteFormat.compact(total) : nil
        }
    }
}

/// `Macintosh HD   1 TB / [████▓▓░░] / 812 GB used · 188 GB free`
struct DiskCapsule: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let disk = app.store.disk
        let total = Double(max(disk.total, 1))
        let reclaimable = min(Double(app.store.reclaimableTotal), Double(disk.used))
        let otherUsed = Double(disk.used) - reclaimable
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(disk.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(ByteFormat.string(disk.total)).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
            }
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(LinearGradient(colors: [Theme.accentLight, Theme.accentDeep], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * otherUsed / total)
                    Rectangle().fill(Theme.warning).frame(width: geo.size.width * reclaimable / total * 0.6)
                    Rectangle().fill(Theme.accent2).frame(width: geo.size.width * reclaimable / total * 0.4)
                    Spacer(minLength: 0)
                }
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
            }
            .frame(height: 5)
            HStack(spacing: 4) {
                Text("\(ByteFormat.string(disk.used)) used").foregroundStyle(Theme.textSecondary)
                Text("·").foregroundStyle(Theme.textTertiary)
                Text("\(ByteFormat.string(disk.available)) free").foregroundStyle(Theme.success)
            }
            .font(Theme.mono(10.5))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.cardStroke))
        .accessibilityElement(children: .combine)
        .help("Violet: used · amber/cyan: reclaimable")
    }
}
