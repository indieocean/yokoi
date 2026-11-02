import SwiftUI

/// The confirmation sheet (PRD §5.8, mockup 08). Move to Trash is the default; permanent delete is
/// red, explicit and needs an extra acknowledgement every time.
struct ConfirmCleanupSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let request: CleanupRequest

    @State private var mode: DeleteMode = .trash
    @State private var includeRecent = false
    @State private var acknowledgedPermanent = false
    @State private var dontAskAgain = false
    @State private var showAllPaths = false
    @State private var running = false

    private var protectDays: Int { app.settings.data.protectRecentDays }
    private var recentEntries: [CleanupEntry] { request.entries.filter { $0.isRecentlyActive(days: protectDays) } }
    private var entries: [CleanupEntry] {
        includeRecent ? request.entries : request.entries.filter { !$0.isRecentlyActive(days: protectDays) }
    }
    private var totalSize: Int64 { entries.reduce(0) { $0 + $1.size } }
    private var fileCount: Int { entries.reduce(0) { $0 + $1.fileCount } }
    private var dryRun: Bool { app.settings.data.dryRun }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            stats
            pathPreview
            if let tool = request.tool { commandPreview(tool) }
            if !request.blocked.isEmpty { blockedNotice }
            if !recentEntries.isEmpty { recentWarning }
            if dryRun { dryRunNotice }

            VStack(spacing: 10) {
                if !request.forcePermanent {
                    RadioCard(selected: mode == .trash, title: "Move to Trash", subtitle: "Recoverable until you empty the Trash") {
                        mode = .trash
                    } extra: { EmptyView() }
                }
                RadioCard(selected: mode == .permanent, title: "Delete permanently",
                          subtitle: request.tool == nil ? "Immediately frees space · cannot be undone"
                                                        : "The tool deletes them · they can't go to the Trash", titleColor: Theme.danger) {
                    mode = .permanent
                } extra: {
                    Toggle(isOn: $acknowledgedPermanent) {
                        Text("I understand these files can't be recovered").font(.system(size: 12.5))
                    }
                    .toggleStyle(.checkbox)
                    .padding(.top, 8)
                }
            }

            footer
        }
        .padding(28)
        .frame(width: 600)
        .background(Color(hex: 0x1A1D27))
        .onAppear {
            mode = request.forcePermanent ? .permanent : app.settings.data.defaultDeleteMode
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.danger.opacity(0.15))
                Image(systemName: "delete.left").font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.danger)
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(request.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(LocalizedStringKey(request.restoreHint))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var stats: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Total size").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                // macOS doesn't report a Time Machine snapshot's size.
                Text(request.tool != nil && totalSize == 0 ? "Unknown" : ByteFormat.string(totalSize))
                    .font(Theme.mono(24, .bold)).foregroundStyle(Theme.accentLight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 14, radius: 10)
            VStack(alignment: .leading, spacing: 4) {
                Text("Items").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(entries.count)").font(Theme.mono(24, .bold)).foregroundStyle(Theme.textPrimary)
                    if request.tool == nil {
                        Text("· \(CountFormat.compact(fileCount)) files").font(Theme.mono(12.5)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 14, radius: 10)
        }
    }

    private var pathPreview: some View {
        let shown = showAllPaths ? entries : Array(entries.prefix(3))
        return VStack(alignment: .leading, spacing: 8) {
            if entries.isEmpty {
                Text(request.blocked.isEmpty ? "Nothing left to clean: every item belongs to a recently changed project." : "Nothing left to clean.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(shown) { entry in
                        HStack {
                            Text(entry.displayPath).font(Theme.mono(11.5)).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 12)
                            SizeText(bytes: entry.size, size: 11.5)
                        }
                    }
                }
            }
            .frame(maxHeight: showAllPaths ? 220 : nil)
            .fixedSize(horizontal: false, vertical: !showAllPaths)
            if entries.count > 3 {
                Button(showAllPaths ? "Show fewer" : "+ \(entries.count - 3) more…") { showAllPaths.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.cardStroke))
    }

    /// The exact commands a tool cleanup runs.
    private func commandPreview(_ tool: ToolActionStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(tool.commands.prefix(6).enumerated()), id: \.offset) { _, cmd in
                Text("$ " + cmd.joined(separator: " ")).font(Theme.mono(11.5)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            if tool.commands.count > 6 {
                Text("+ \(tool.commands.count - 6) more").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
            }
            if let note = tool.note {
                Text(LocalizedStringKey(note)).font(.system(size: 12)).foregroundStyle(Theme.warning).padding(.top, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.cardStroke))
    }

    private var recentWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                Text("\(recentEntries.count) item\(recentEntries.count == 1 ? " belongs" : "s belong") to projects changed in the last \(protectDays) days")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            Text(recentEntries.prefix(4).map(\.label).joined(separator: ", ") + (recentEntries.count > 4 ? "…" : ""))
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.textSecondary)
            Toggle(isOn: $includeRecent) {
                Text("Include them anyway").font(.system(size: 12.5))
            }
            .toggleStyle(.checkbox)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.warning.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.warning.opacity(0.35)))
    }

    private var blockedNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").foregroundStyle(Theme.danger)
                Text("\(CountFormat.plural(request.blocked.count, "item")) skipped: in use right now")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            ForEach(request.blocked.prefix(4)) { b in
                Text("\(b.entry.label) · open in \(b.process)").font(Theme.mono(11.5)).foregroundStyle(Theme.textSecondary)
            }
            Text("Close the project or quit the app, then try again.").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.danger.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.danger.opacity(0.3)))
    }

    private var dryRunNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye").foregroundStyle(Theme.info)
            Text("Dry run is on. Nothing will be changed; you'll see what would happen.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.info.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.info.opacity(0.3)))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if request.allSafe && mode == .trash {
                Toggle(isOn: $dontAskAgain) {
                    Text("Don't ask again for Safe caches").font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                }
                .toggleStyle(.checkbox)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.dkSecondary)
                .keyboardShortcut(.cancelAction)
            Button {
                confirm()
            } label: {
                Text(confirmTitle).padding(.horizontal, 6)
            }
            .buttonStyle(.dkDanger)
            .disabled(entries.isEmpty || running || (mode == .permanent && !acknowledgedPermanent))
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 4)
    }

    private var confirmTitle: String {
        let size = ByteFormat.string(totalSize)
        if running { return "Working…" }
        if dryRun { return "Preview · \(size)" }
        if let verb = request.confirmVerb { return "\(verb) · \(size)" }
        if request.tool != nil && totalSize == 0 { return "Delete permanently" }
        return mode == .trash ? "Move to Trash · \(size)" : "Delete permanently · \(size)"
    }

    private func confirm() {
        running = true
        if dontAskAgain && request.allSafe && mode == .trash {
            app.settings.data.skipConfirmForSafe = true
        }
        if let tool = request.tool {
            dismiss()
            Task { await app.tools.confirm(tool, app: app) }
            return
        }
        let chosen = entries
        let action: CleanupAction = mode == .trash ? .trash : .delete
        // Close the sheet right away; the progress overlay takes over.
        dismiss()
        Task { await app.run(chosen, action: action) }
    }
}

/// Shows a dry-run report, or the paths that failed in a real cleanup.
struct OutcomeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let outcome: CleanupOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: outcome.dryRun ? "eye" : "exclamationmark.triangle.fill")
                    .foregroundStyle(outcome.dryRun ? Theme.info : Theme.warning)
                    .font(.system(size: 18))
                Text(outcome.dryRun ? "Dry run: nothing was changed" : "Cleanup finished with skipped paths")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            Text(summary).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(outcome.records) { record in
                        HStack {
                            Text(record.path).font(Theme.mono(11.5)).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            SizeText(bytes: record.size, size: 11.5)
                        }
                    }
                    if !outcome.failures.isEmpty {
                        SectionLabel(text: "Skipped").padding(.top, 10)
                        ForEach(outcome.failures, id: \.self) { f in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(PathFormat.abbreviate(f.path)).font(Theme.mono(11.5)).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                                Text(f.reason).font(.system(size: 11.5)).foregroundStyle(Theme.warning)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .frame(height: 260)
            .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.25)))

            HStack {
                Button("Reveal Log") { Finder.reveal([CleanupLog.defaultURL]) }.buttonStyle(.dkSecondary)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.dkPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(Color(hex: 0x1A1D27))
    }

    private var summary: String {
        let verb: String
        switch outcome.action {
        case .trash: verb = "move to the Trash"
        case .delete: verb = "permanently delete"
        case .move(let dest, _): verb = "move to \(PathFormat.abbreviate(dest))"
        }
        if outcome.dryRun {
            return "Yokoi would \(verb) \(outcome.itemCount) item\(outcome.itemCount == 1 ? "" : "s") (\(ByteFormat.string(outcome.bytes))). Turn off Dry run in Settings to do it for real."
        }
        return "\(outcome.itemCount) item\(outcome.itemCount == 1 ? "" : "s") done (\(ByteFormat.string(outcome.bytes))). \(outcome.failures.count) path\(outcome.failures.count == 1 ? " was" : "s were") skipped."
    }
}

/// First-run explainer for Full Disk Access.
struct OnboardingSheet: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                AppIconMark(size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Give Yokoi Full Disk Access").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("So it can measure caches and folders macOS protects.").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Open System Settings → Privacy & Security → Full Disk Access.")
                step(2, "Turn on Yokoi (use + if it isn't listed).")
                step(3, "Come back here. Yokoi notices the change automatically.")
            }
            .card(padding: 16, radius: 10)
            Label("Everything stays on this Mac. No network calls, no telemetry.", systemImage: "lock")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
            HStack {
                Text(app.fullDiskAccess ? "Access granted ✓" : "Not granted yet")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(app.fullDiskAccess ? Theme.success : Theme.warning)
                Spacer()
                Button("Continue without") { app.finishOnboarding() }.buttonStyle(.dkSecondary)
                if app.fullDiskAccess {
                    Button("Start scanning") { app.finishOnboarding() }.buttonStyle(.dkPrimary).keyboardShortcut(.defaultAction)
                } else {
                    Button("Open System Settings") { FullDiskAccess.openSystemSettings() }.buttonStyle(.dkPrimary).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .frame(width: 540)
        .background(Color(hex: 0x1A1D27))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.refreshFullDiskAccess()
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(Theme.mono(12, .bold)).foregroundStyle(Theme.accentLight)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.accent.opacity(0.15)))
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
        }
    }
}
