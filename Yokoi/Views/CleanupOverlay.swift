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

/// Full-window progress for a cleanup: an animated SSD whose flash cells erase as files go, a live
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
                        .frame(width: 440, height: 260)
                        .blur(radius: 10)
                    SSDAnimation(fraction: fraction, finished: finished, reduceMotion: reduceMotion)
                        .frame(width: 440, height: 200)
                    if finished {
                        FinishBadge(success: (outcome?.failures.isEmpty ?? true) && activity.lateBlocked.isEmpty)
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    }
                }
                .frame(height: 230)
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

// MARK: - SSD animation

/// A stylized M.2 NVMe SSD: memory cells in four NAND flash chips erase as the cleanup progresses
/// (flash, go dark, release particles), while data pulses run from the controller along the traces.
private struct SSDAnimation: View {
    let fraction: Double
    let finished: Bool
    let reduceMotion: Bool
    @State private var model = SSDModel()

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
private final class SSDModel {
    static let chips = 4
    static let cols = 4
    static let rows = 8
    static let perChip = cols * rows
    static let count = chips * perChip

    private var displayed = 0.0
    private var activity = 1.0
    private var lastTime: Double?
    private var clearedAt: [Int: Double] = [:]
    /// Cells erase in a scattered but stable order, like blocks spread across the flash.
    private let order: [Int] = {
        var rng = SplitMix(seed: 0x55D)
        return (0..<SSDModel.count).shuffled(using: &rng)
    }()

    private let violet = (r: 0.545, g: 0.424, b: 1.0)
    private let cyan = (r: 0.133, g: 0.827, b: 0.933)

    private func cellColor(_ mix: Double) -> Color {
        Color(.sRGB, red: violet.r + (cyan.r - violet.r) * mix,
              green: violet.g + (cyan.g - violet.g) * mix,
              blue: violet.b + (cyan.b - violet.b) * mix)
    }

    func draw(in gc: inout GraphicsContext, size: CGSize, time t: Double, target: Double, finished: Bool, reduceMotion: Bool) {
        let dt = min(max(t - (lastTime ?? t), 0), 0.1)
        lastTime = t
        // Ease toward the real progress so big single steps still play out cell by cell.
        let goal = finished ? 1.0 : target
        displayed += (goal - displayed) * min(1, dt * (finished ? 4 : 2.2))
        if reduceMotion || (finished && displayed > 0.985) { displayed = goal }
        activity += ((finished ? 0 : 1) - activity) * min(1, dt * 1.5)

        // M.2 2280-style board, centered.
        let W = min(size.width, size.height * 2.3) - 8
        let H = W / 2.3
        let board = CGRect(x: (size.width - W) / 2, y: (size.height - H) / 2, width: W, height: H)
        let boardPath = Path(roundedRect: board, cornerRadius: H * 0.06)
        gc.fill(boardPath, with: .linearGradient(Gradient(colors: [Color(hex: 0x1C2130), Color(hex: 0x10131B)]),
                                                 startPoint: CGPoint(x: board.minX, y: board.minY), endPoint: CGPoint(x: board.maxX, y: board.maxY)))
        gc.stroke(boardPath, with: .color(.white.opacity(0.10)), lineWidth: 1.2)

        // Faint PCB grid
        var grid = Path()
        stride(from: board.minX + 10, to: board.maxX, by: 14).forEach { x in
            grid.move(to: CGPoint(x: x, y: board.minY + 4)); grid.addLine(to: CGPoint(x: x, y: board.maxY - 4))
        }
        gc.stroke(grid, with: .color(.white.opacity(0.018)), lineWidth: 0.6)

        // Gold connector fingers on the left edge, with the M-key notch.
        let fingerW = W * 0.045
        let fingers = 18
        let pitch = (H * 0.86) / Double(fingers)
        for i in 0..<fingers where i != 5 {
            let y = board.minY + H * 0.07 + Double(i) * pitch
            let r = CGRect(x: board.minX - fingerW * 0.35, y: y + pitch * 0.18, width: fingerW, height: pitch * 0.64)
            gc.fill(Path(roundedRect: r, cornerRadius: 1.5),
                    with: .linearGradient(Gradient(colors: [Color(hex: 0xF5D27A), Color(hex: 0xB8892E)]),
                                          startPoint: CGPoint(x: r.minX, y: r.minY), endPoint: CGPoint(x: r.maxX, y: r.maxY)))
        }
        // Mounting half-hole on the right edge.
        let hole = H * 0.13
        gc.fill(Path(ellipseIn: CGRect(x: board.maxX - hole, y: board.midY - hole / 2, width: hole, height: hole)),
                with: .color(Color(hex: 0x0B0D13)))

        // Controller
        let ctrl = CGRect(x: board.minX + W * 0.09, y: board.midY - H * 0.22, width: H * 0.44, height: H * 0.44)
        let ctrlPath = Path(roundedRect: ctrl, cornerRadius: 4)
        gc.fill(ctrlPath, with: .linearGradient(Gradient(colors: [Color(hex: 0x3A3F52), Color(hex: 0x1F2330)]),
                                                startPoint: CGPoint(x: ctrl.minX, y: ctrl.minY), endPoint: CGPoint(x: ctrl.maxX, y: ctrl.maxY)))
        gc.stroke(ctrlPath, with: .color(.white.opacity(0.14)), lineWidth: 1)
        gc.draw(Text("YOKOI").font(.system(size: ctrl.height * 0.17, weight: .heavy, design: .rounded)).foregroundColor(.white.opacity(0.85)),
                at: CGPoint(x: ctrl.midX, y: ctrl.midY))

        // NAND chips
        let chipsLeft = ctrl.maxX + W * 0.07
        let chipsRight = board.maxX - hole - W * 0.03
        let gap = W * 0.025
        let chipW = (chipsRight - chipsLeft - gap * Double(Self.chips - 1)) / Double(Self.chips)
        let chipH = H * 0.72
        var chipRects: [CGRect] = []
        for k in 0..<Self.chips {
            chipRects.append(CGRect(x: chipsLeft + Double(k) * (chipW + gap), y: board.midY - chipH / 2, width: chipW, height: chipH))
        }

        // Traces from the controller to each chip, with data pulses while working.
        let start = CGPoint(x: ctrl.maxX, y: ctrl.midY)
        for (k, chip) in chipRects.enumerated() {
            let lane = board.minY + H * (0.08 + 0.025 * Double(k))
            let laneB = board.maxY - H * (0.08 + 0.025 * Double(k))
            for (y, endY) in [(lane, chip.minY), (laneB, chip.maxY)] {
                var trace = Path()
                trace.move(to: start)
                trace.addLine(to: CGPoint(x: start.x + 8 + Double(k) * 3, y: start.y))
                trace.addLine(to: CGPoint(x: start.x + 8 + Double(k) * 3, y: y))
                trace.addLine(to: CGPoint(x: chip.midX, y: y))
                trace.addLine(to: CGPoint(x: chip.midX, y: endY))
                gc.stroke(trace, with: .color(Color(hex: 0x8B6CFF).opacity(0.18)), lineWidth: 1)
                if !reduceMotion && activity > 0.05 {
                    // A pulse travelling along this trace.
                    let length = (8 + Double(k) * 3) + abs(y - start.y) + abs(chip.midX - (start.x + 8 + Double(k) * 3)) + abs(endY - y)
                    let phase = (t * 0.9 + Double(k) * 0.23 + (y < board.midY ? 0 : 0.5)).truncatingRemainder(dividingBy: 1)
                    if let p = Self.point(on: trace, at: phase * length) {
                        var glow = gc
                        glow.blendMode = .plusLighter
                        glow.addFilter(.blur(radius: 3))
                        glow.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)),
                                  with: .color(Color(hex: 0x22D3EE).opacity(0.9 * activity)))
                        gc.fill(Path(ellipseIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)),
                                with: .color(.white.opacity(0.9 * activity)))
                    }
                }
            }
        }

        // Cells
        let clearedCount = Int((displayed * Double(Self.count)).rounded(.down))
        for i in order.prefix(clearedCount) where clearedAt[i] == nil { clearedAt[i] = t }
        let cleared = Set(order.prefix(clearedCount))
        var particles: [(CGPoint, Double, Color)] = []

        for (k, chip) in chipRects.enumerated() {
            let chipPath = Path(roundedRect: chip, cornerRadius: 3)
            gc.fill(chipPath, with: .color(Color(hex: 0x0D1017)))
            gc.stroke(chipPath, with: .color(.white.opacity(0.12)), lineWidth: 1)
            let pad = chipW * 0.1
            let cellW = (chip.width - 2 * pad) / Double(Self.cols)
            let cellH = (chip.height - 2 * pad) / Double(Self.rows)
            for r in 0..<Self.rows {
                for col in 0..<Self.cols {
                    let i = k * Self.perChip + r * Self.cols + col
                    let rect = CGRect(x: chip.minX + pad + Double(col) * cellW + 1, y: chip.minY + pad + Double(r) * cellH + 1,
                                      width: cellW - 2, height: cellH - 2)
                    let cell = Path(roundedRect: rect, cornerRadius: 1.2)
                    let mix = (Double(k) / Double(Self.chips) + Double(col) / Double(Self.cols * Self.chips)).truncatingRemainder(dividingBy: 1)
                    let color = cellColor(mix)
                    if cleared.contains(i), let when = clearedAt[i] {
                        let age = t - when
                        if !reduceMotion && age < 0.3 {
                            gc.fill(cell, with: .color(.white.opacity(0.95 * (1 - age / 0.3))))
                        } else {
                            gc.stroke(cell, with: .color(.white.opacity(0.07)), lineWidth: 0.6)
                        }
                        if !reduceMotion && age < 1.0 {
                            // Erased bits drift up off the chip.
                            for n in 0..<2 {
                                let drift = sin(Double(i) * 7.31 + Double(n) * 2.1) * 8
                                let p = CGPoint(x: rect.midX + drift * age, y: rect.midY - age * H * 0.55 - Double(n) * 5)
                                particles.append((p, 1 - age, color))
                            }
                        }
                    } else {
                        gc.fill(cell, with: .color(color.opacity(0.85)))
                    }
                }
            }
        }

        if !particles.isEmpty {
            var glow = gc
            glow.blendMode = .plusLighter
            for (p, alpha, color) in particles {
                let d = 1.8 + 2.2 * alpha
                glow.fill(Path(roundedRect: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d), cornerRadius: 0.6),
                          with: .color(color.opacity(alpha)))
            }
        }

        // Status LED on the controller: pulsing violet while working, green when done.
        let led = CGRect(x: ctrl.maxX - 9, y: ctrl.minY + 4, width: 5, height: 5)
        let ledColor = finished ? Color(hex: 0x34D399) : Color(hex: 0x8B6CFF)
        let ledAlpha = finished ? 1 : (reduceMotion ? 0.9 : 0.5 + 0.5 * abs(sin(t * 6)))
        var ledGlow = gc
        ledGlow.addFilter(.blur(radius: 3))
        ledGlow.fill(Path(ellipseIn: led.insetBy(dx: -2, dy: -2)), with: .color(ledColor.opacity(ledAlpha)))
        gc.fill(Path(ellipseIn: led), with: .color(ledColor.opacity(ledAlpha)))

        // Label
        gc.draw(Text("NVMe").font(.system(size: H * 0.075, weight: .semibold, design: .monospaced)).foregroundColor(.white.opacity(0.25)),
                at: CGPoint(x: ctrl.midX, y: ctrl.maxY + H * 0.1))
    }

    /// The point at `distance` along a polyline path.
    static func point(on path: Path, at distance: Double) -> CGPoint? {
        var points: [CGPoint] = []
        path.forEach { el in
            switch el {
            case .move(let p), .line(let p): points.append(p)
            default: break
            }
        }
        var remaining = distance
        for (a, b) in zip(points, points.dropFirst()) {
            let seg = hypot(b.x - a.x, b.y - a.y)
            if remaining <= seg, seg > 0 {
                let f = remaining / seg
                return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
            }
            remaining -= seg
        }
        return points.last
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
