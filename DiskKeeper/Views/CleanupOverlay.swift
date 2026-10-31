import Observation
import SwiftUI

/// A running (or just finished) cleanup, shown by `CleanupOverlay`.
@MainActor
@Observable
final class CleanupActivity: Identifiable {
    let id = UUID()
    let action: CleanupAction
    let dryRun: Bool
    let started = Date()
    var snapshot = CleanupProgress.Snapshot()
    var outcome: CleanupOutcome?
    var lateBlocked: [CleanupRequest.Blocked] = []

    init(action: CleanupAction, dryRun: Bool) {
        self.action = action
        self.dryRun = dryRun
    }

    var isFinished: Bool { outcome != nil }

    var verb: String {
        if dryRun { return "Previewing cleanup" }
        switch action {
        case .trash: return "Moving to Trash"
        case .delete: return "Deleting permanently"
        case .move: return "Moving files"
        }
    }
}

/// Full-window progress for a cleanup: an animated drive whose sectors clear as files go, a live
/// bytes counter and a feed of the paths being removed, so it never looks frozen.
struct CleanupOverlay: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let activity: CleanupActivity

    var body: some View {
        let s = activity.snapshot
        let finished = activity.isFinished
        let outcome = activity.outcome
        let fraction = finished ? 1 : s.fraction
        let shownBytes = outcome?.bytes ?? Int64(Double(s.bytesTotal) * fraction)

        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            Color.black.opacity(0.35).ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [Theme.accent.opacity(finished ? 0.15 : 0.35), .clear], center: .center, startRadius: 10, endRadius: 160))
                        .frame(width: 320, height: 320)
                        .blur(radius: 10)
                    DriveAnimation(fraction: fraction, finished: finished, reduceMotion: reduceMotion)
                        .frame(width: 230, height: 230)
                    if finished {
                        FinishBadge(success: (outcome?.failures.isEmpty ?? true) && activity.lateBlocked.isEmpty)
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    }
                }
                .frame(height: 250)
                .animation(.spring(response: 0.45, dampingFraction: 0.6), value: finished)

                VStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text(ByteFormat.string(shownBytes))
                        .font(Theme.mono(38, .bold))
                        .foregroundStyle(finished ? Theme.success : Theme.textPrimary)
                        .contentTransition(.numericText(value: Double(shownBytes)))
                        .animation(.snappy(duration: 0.25), value: shownBytes)
                    Text(subtitle)
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.textSecondary)
                }

                ProgressTrack(fraction: fraction, finished: finished)
                    .frame(width: 440, height: 6)

                PathFeed(paths: s.recent, finished: finished)
                    .frame(width: 480, height: 150)

                if finished {
                    HStack(spacing: 10) {
                        if activity.dryRun || !(outcome?.failures.isEmpty ?? true) {
                            Button(activity.dryRun ? "See report" : "Details") {
                                app.dismissActivity()
                                app.showOutcomeDetails = true
                            }
                            .buttonStyle(.dkSecondary)
                        }
                        Button("Done") { app.dismissActivity() }
                            .buttonStyle(.dkPrimary)
                            .keyboardShortcut(.defaultAction)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(32)
            .frame(width: 560)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(hex: 0x14161F).opacity(0.92)))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
            .animation(.easeOut(duration: 0.25), value: finished)
        }
        .contentShape(Rectangle())
        .onTapGesture {}  // swallow clicks so nothing underneath changes mid-cleanup
        .accessibilityElement(children: .contain)
        .accessibilityLabel(finished ? "Cleanup finished, \(ByteFormat.string(shownBytes)) freed" : "\(activity.verb), \(Int(fraction * 100)) percent")
    }

    private var title: String {
        guard let outcome = activity.outcome else { return activity.verb + "…" }
        if activity.dryRun { return "Dry run: nothing was changed" }
        let skipped = outcome.failures.count + activity.lateBlocked.count
        if skipped > 0 { return "Done, \(skipped) skipped" }
        switch activity.action {
        case .move: return "Moved"
        case .trash: return "Moved to Trash"
        case .delete: return "Freed"
        }
    }

    private var subtitle: String {
        let s = activity.snapshot
        if let outcome = activity.outcome {
            return "\(CountFormat.plural(outcome.itemCount, "item")) · \(CountFormat.compact(max(s.filesDone, s.filesTotal))) files"
        }
        let current = min(s.entriesDone + 1, max(s.entriesTotal, 1))
        return "item \(current) of \(s.entriesTotal) · \(CountFormat.compact(s.filesDone)) files" + (s.currentLabel.isEmpty ? "" : " · \(s.currentLabel)")
    }
}

// MARK: - Drive animation

/// A stylized hard-drive platter: sectors of data (violet→cyan) clear as the cleanup progresses,
/// flashing and throwing off particles, while the platter spins and the head sweeps the tracks.
private struct DriveAnimation: View {
    let fraction: Double
    let finished: Bool
    let reduceMotion: Bool
    @State private var model = DriveModel()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion && finished)) { context in
            Canvas { gc, size in
                model.draw(in: &gc, size: size, time: context.date.timeIntervalSinceReferenceDate,
                           target: fraction, finished: finished, reduceMotion: reduceMotion)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Animation state lives in a reference type so the Canvas can advance it each frame.
private final class DriveModel {
    static let tracks = 4
    static let perTrack = 36
    static let count = tracks * perTrack

    private var displayed = 0.0
    private var angle = 0.0
    private var spin = 1.0
    private var lastTime: Double?
    private var clearedAt: [Int: Double] = [:]
    /// Sectors clear in a scattered but stable order, like files spread over a disk.
    private let order: [Int] = {
        var rng = SplitMix(seed: 0xD15C)
        return (0..<DriveModel.count).shuffled(using: &rng)
    }()

    private let violet = (r: 0.545, g: 0.424, b: 1.0)
    private let cyan = (r: 0.133, g: 0.827, b: 0.933)

    func draw(in gc: inout GraphicsContext, size: CGSize, time t: Double, target: Double, finished: Bool, reduceMotion: Bool) {
        let dt = min(max(t - (lastTime ?? t), 0), 0.1)
        lastTime = t
        // Ease toward the real progress so big single steps still play out sector by sector.
        let goal = finished ? 1.0 : target
        displayed += (goal - displayed) * min(1, dt * (finished ? 4 : 2.2))
        if reduceMotion || (finished && displayed > 0.985) { displayed = goal }
        spin += ((finished ? 0 : 1) - spin) * min(1, dt * 1.2)
        if !reduceMotion { angle += spin * dt * .pi * 1.6 }

        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let R = min(size.width, size.height) / 2 - 6

        // Platter
        let platter = Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
        gc.fill(platter, with: .radialGradient(Gradient(colors: [Color(hex: 0x2A2E3D), Color(hex: 0x11131A)]),
                                               center: c, startRadius: 0, endRadius: R))
        gc.stroke(platter, with: .color(.white.opacity(0.10)), lineWidth: 1.5)
        for k in stride(from: 0.30, through: 0.97, by: 0.045) {
            let r = R * k
            gc.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                      with: .color(.white.opacity(0.025)), lineWidth: 0.6)
        }

        // Sectors
        let clearedCount = Int((displayed * Double(Self.count)).rounded(.down))
        for i in order.prefix(clearedCount) where clearedAt[i] == nil { clearedAt[i] = t }
        let cleared = Set(order.prefix(clearedCount))
        let slot = 2 * Double.pi / Double(Self.perTrack)
        var particles: [(CGPoint, Double, Color)] = []

        for i in 0..<Self.count {
            let track = i / Self.perTrack
            let s = i % Self.perTrack
            let r0 = R * (0.40 + 0.14 * Double(track))
            let r1 = r0 + R * 0.105
            let a0 = angle + Double(s) * slot + 0.035
            let a1 = a0 + slot - 0.07
            var sector = Path()
            sector.addArc(center: c, radius: r1, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
            sector.addArc(center: c, radius: r0, startAngle: .radians(a1), endAngle: .radians(a0), clockwise: true)
            sector.closeSubpath()

            let mix = (Double(s) / Double(Self.perTrack) + Double(track) * 0.12).truncatingRemainder(dividingBy: 1)
            let color = Color(.sRGB, red: violet.r + (cyan.r - violet.r) * mix,
                              green: violet.g + (cyan.g - violet.g) * mix,
                              blue: violet.b + (cyan.b - violet.b) * mix)

            if cleared.contains(i), let when = clearedAt[i] {
                let age = t - when
                if !reduceMotion && age < 0.35 {
                    gc.fill(sector, with: .color(.white.opacity(0.9 * (1 - age / 0.35))))
                } else {
                    gc.stroke(sector, with: .color(.white.opacity(0.06)), lineWidth: 0.7)
                }
                if !reduceMotion && age < 0.9 {
                    let mid = (a0 + a1) / 2
                    let rm = (r0 + r1) / 2 + age * R * 0.75
                    for k in 0..<3 {
                        let jitter = Double(k - 1) * 0.06 + sin(Double(i) * 12.9898 + Double(k)) * 0.04
                        let p = CGPoint(x: c.x + cos(mid + jitter) * (rm + Double(k) * 6), y: c.y + sin(mid + jitter) * (rm + Double(k) * 6))
                        particles.append((p, 1 - age / 0.9, color))
                    }
                }
            } else {
                gc.fill(sector, with: .color(color.opacity(0.85)))
            }
        }

        // Particles (additive glow)
        if !particles.isEmpty {
            var glow = gc
            glow.blendMode = .plusLighter
            for (p, alpha, color) in particles {
                let d = 2.2 + 2.0 * alpha
                glow.fill(Path(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)), with: .color(color.opacity(alpha)))
            }
        }

        // Spindle
        let hub = R * 0.22
        let hubPath = Path(ellipseIn: CGRect(x: c.x - hub, y: c.y - hub, width: 2 * hub, height: 2 * hub))
        gc.fill(hubPath, with: .linearGradient(Gradient(colors: [Color(hex: 0x3A3F52), Color(hex: 0x1A1D27)]),
                                               startPoint: CGPoint(x: c.x, y: c.y - hub), endPoint: CGPoint(x: c.x, y: c.y + hub)))
        gc.stroke(hubPath, with: .color(.white.opacity(0.15)), lineWidth: 1)
        gc.draw(Text("DK").font(.system(size: hub * 0.62, weight: .heavy)).foregroundColor(.white.opacity(0.85)), at: c)

        // Read/write arm sweeping across the tracks
        let pivot = CGPoint(x: c.x + R * 0.98, y: c.y - R * 0.98)
        let sweep = reduceMotion ? 0 : sin(t * 3.1) * spin
        let headR = R * (0.66 + 0.24 * sweep)
        let headAngle = -Double.pi / 4 + 0.35
        let head = CGPoint(x: c.x + cos(headAngle) * headR, y: c.y + sin(headAngle) * headR)
        var arm = Path()
        arm.move(to: pivot)
        arm.addLine(to: head)
        gc.stroke(arm, with: .linearGradient(Gradient(colors: [Color(hex: 0x9AA3B8), Color(hex: 0x5E6578)]), startPoint: pivot, endPoint: head),
                  style: StrokeStyle(lineWidth: 5, lineCap: .round))
        let pivotDot = Path(ellipseIn: CGRect(x: pivot.x - 9, y: pivot.y - 9, width: 18, height: 18))
        gc.fill(pivotDot, with: .color(Color(hex: 0x3A3F52)))
        gc.stroke(pivotDot, with: .color(.white.opacity(0.2)), lineWidth: 1)
        let headDot = Path(ellipseIn: CGRect(x: head.x - 4.5, y: head.y - 4.5, width: 9, height: 9))
        var headGlow = gc
        headGlow.addFilter(.blur(radius: 4))
        headGlow.fill(headDot, with: .color(Color(hex: 0x22D3EE).opacity(0.9 * spin)))
        gc.fill(headDot, with: .color(.white.opacity(0.9)))
    }
}

/// Small deterministic RNG for a stable sector order.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Pieces

private struct FinishBadge: View {
    let success: Bool
    @State private var ring = false

    var body: some View {
        ZStack {
            Circle()
                .stroke((success ? Theme.success : Theme.warning).opacity(ring ? 0 : 0.6), lineWidth: 3)
                .frame(width: ring ? 190 : 80, height: ring ? 190 : 80)
            Circle()
                .fill(success ? Theme.success : Theme.warning)
                .frame(width: 78, height: 78)
                .shadow(color: (success ? Theme.success : Theme.warning).opacity(0.6), radius: 18)
            Image(systemName: success ? "checkmark" : "exclamationmark")
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(.white)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.9)) { ring = true } }
    }
}

private struct ProgressTrack: View {
    let fraction: Double
    let finished: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: finished ? [Theme.success, Theme.success] : [Theme.accentLight, Theme.accent2],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, geo.size.width * fraction))
                    .shadow(color: Theme.accent2.opacity(finished ? 0 : 0.6), radius: 6)
            }
        }
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

/// The last few paths handled, newest on top, fading out as they age.
private struct PathFeed: View {
    let paths: [String]
    let finished: Bool
    @State private var pulse = false

    private var unique: [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(unique.prefix(6).enumerated()), id: \.element) { index, path in
                HStack(spacing: 8) {
                    Circle()
                        .fill(index == 0 && !finished ? Theme.accent2 : Color.white.opacity(0.25))
                        .frame(width: 5, height: 5)
                        .opacity(index == 0 && !finished ? (pulse ? 1 : 0.3) : 1)
                    Text(PathFormat.abbreviate(path))
                        .font(Theme.mono(11.5, index == 0 ? .semibold : .regular))
                        .foregroundStyle(index == 0 ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if index == 0 && !finished {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.danger.opacity(0.8))
                    }
                }
                .opacity(1 - Double(index) * 0.14)
                .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.06)))
        .animation(.easeOut(duration: 0.12), value: paths.first)
        .onAppear { withAnimation(.easeInOut(duration: 0.5).repeatForever()) { pulse = true } }
    }
}
