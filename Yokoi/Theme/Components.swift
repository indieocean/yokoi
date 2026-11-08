import AppKit
import SwiftUI

// MARK: - Cards

struct CardBackground: ViewModifier {
    var padding: CGFloat = 18
    var radius: CGFloat = Theme.Radius.card

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1))
    }
}

extension View {
    func card(padding: CGFloat = 18, radius: CGFloat = Theme.Radius.card) -> some View {
        modifier(CardBackground(padding: padding, radius: radius))
    }
}

// MARK: - Badges and pills

/// Colored language/tool badge: 13% fill, 27% inner stroke (DESIGN.md).
struct Badge: View {
    let text: String
    let color: Color
    var size: CGFloat = 26
    var fontSize: CGFloat = 11

    var body: some View {
        Text(text)
            .font(Theme.mono(fontSize, .bold))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 2)
            .frame(minWidth: size, minHeight: size)
            .fixedSize(horizontal: true, vertical: false)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous).fill(color.opacity(0.13)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous).strokeBorder(color.opacity(0.27), lineWidth: 1))
    }
}

/// Status pill like `STALE`, `SAFE`, `REVIEW`. Text always carries the meaning, not just color.
struct StatusPill: View {
    let text: Text
    let color: Color

    init(text: LocalizedStringKey, color: Color) {
        self.text = Text(text)
        self.color = color
    }

    /// For text that is already localized, or data such as a package manager's name.
    @_disfavoredOverload
    init(text: String, color: Color) {
        self.text = Text(verbatim: text)
        self.color = color
    }

    var body: some View {
        text
            .font(Theme.mono(10.5, .bold))
            .tracking(0.4)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous).fill(color.opacity(0.13)))
            .fixedSize()
    }
}

/// Small neutral tag, e.g. a framework hint (`next 14`) or a version.
struct Tag: View {
    let text: Text
    var color: Color = Theme.textSecondary

    init(text: LocalizedStringKey, comment: StaticString? = nil, color: Color = Theme.textSecondary) {
        self.text = Text(text, comment: comment)
        self.color = color
    }

    /// For data such as a version or a framework hint, shown as is.
    @_disfavoredOverload
    init(text: String, color: Color = Theme.textSecondary) {
        self.text = Text(verbatim: text)
        self.color = color
    }

    var body: some View {
        text
            .font(Theme.mono(11, .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous).fill(.white.opacity(0.06)))
            .fixedSize()
    }
}

struct SectionLabel: View {
    let text: Text

    init(text: LocalizedStringKey) { self.text = Text(text) }

    /// For text that is already localized.
    init(verbatim text: String) { self.text = Text(verbatim: text) }

    var body: some View {
        text
            .textCase(.uppercase)
            .font(Theme.section)
            .tracking(0.9)
            .foregroundStyle(Theme.textTertiary)
    }
}

// MARK: - Checkbox

enum CheckState { case off, on, mixed }

struct CheckBox: View {
    let state: CheckState
    var size: CGFloat = 16
    let action: () -> Void

    init(isOn: Bool, size: CGFloat = 16, action: @escaping () -> Void) {
        self.state = isOn ? .on : .off
        self.size = size
        self.action = action
    }

    init(state: CheckState, size: CGFloat = 16, action: @escaping () -> Void) {
        self.state = state
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(state == .off ? AnyShapeStyle(Color.white.opacity(0.03)) : AnyShapeStyle(Theme.accentGradient))
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(state == .off ? Color.white.opacity(0.22) : Theme.accentLight.opacity(0.6), lineWidth: 1)
                if state != .off {
                    Image(systemName: state == .on ? "checkmark" : "minus")
                        .font(.system(size: size * 0.58, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state == .on ? Text("Selected", comment: "Checkbox state") : Text("Not selected", comment: "Checkbox state"))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Buttons

struct DKButtonStyle: ButtonStyle {
    enum Kind { case primary, danger, secondary, ghost }
    var kind: Kind = .secondary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, compact: compact)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let kind: Kind
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 12 : 13, weight: .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, compact ? 10 : 14)
                .padding(.vertical, compact ? 4 : 7)
                .background(background)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(stroke, lineWidth: 1))
                .shadow(color: shadow, radius: kind == .primary || kind == .danger ? 8 : 0, y: 2)
                .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
                .onHover { hovering = $0 }
        }

        private var foreground: Color {
            switch kind {
            case .primary, .danger: .white
            case .secondary, .ghost: Theme.textPrimary
            }
        }

        @ViewBuilder private var background: some View {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            switch kind {
            case .primary: shape.fill(Theme.accentGradient).brightness(hovering ? 0.05 : 0)
            case .danger: shape.fill(Theme.dangerGradient).brightness(hovering ? 0.05 : 0)
            case .secondary: shape.fill(Color.white.opacity(hovering ? 0.08 : 0.05))
            case .ghost: shape.fill(Color.white.opacity(hovering ? 0.05 : 0))
            }
        }

        private var stroke: Color {
            switch kind {
            case .primary: Theme.accentLight.opacity(0.5)
            case .danger: Theme.danger.opacity(0.6)
            case .secondary: Color.white.opacity(0.09)
            case .ghost: .clear
            }
        }

        private var shadow: Color {
            switch kind {
            case .primary: Theme.accent.opacity(0.35)
            case .danger: Theme.danger.opacity(0.25)
            default: .clear
            }
        }
    }
}

extension ButtonStyle where Self == DKButtonStyle {
    static var dkPrimary: DKButtonStyle { DKButtonStyle(kind: .primary) }
    static var dkDanger: DKButtonStyle { DKButtonStyle(kind: .danger) }
    static var dkSecondary: DKButtonStyle { DKButtonStyle(kind: .secondary) }
    static var dkGhost: DKButtonStyle { DKButtonStyle(kind: .ghost) }
}

// MARK: - Segmented tabs

/// Pill segmented control used for filters (`All 64 · Stale 41 · Active 23`).
struct SegmentedTabs<Value: Hashable>: View {
    struct Item {
        let value: Value
        let title: Text
        var count: String? = nil

        init(value: Value, title: LocalizedStringKey, count: String? = nil) {
            self.value = value
            self.title = Text(title)
            self.count = count
        }

        /// For titles that are already localized.
        init(value: Value, verbatim title: String, count: String? = nil) {
            self.value = value
            self.title = Text(verbatim: title)
            self.count = count
        }
    }

    @Binding var selection: Value
    let items: [Item]
    var compact = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                let selected = item.value == selection
                Button {
                    selection = item.value
                } label: {
                    HStack(spacing: 6) {
                        item.title
                        if let count = item.count {
                            Text(count).font(Theme.mono(11.5)).foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        }
                    }
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, compact ? 10 : 12)
                    .padding(.vertical, compact ? 4 : 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selected ? Color.white.opacity(0.09) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.cardStroke))
        .fixedSize()
    }
}

// MARK: - Bars

struct SizeBar: View {
    let fraction: Double
    var color: Color = Theme.success
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.07))
                Capsule().fill(color).frame(width: max(height, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Size text

struct SizeText: View {
    let bytes: Int64
    var size: CGFloat = 12
    var weight: Font.Weight = .medium
    var color: Color = Theme.textPrimary

    var body: some View {
        Text(ByteFormat.string(bytes))
            .font(Theme.mono(size, weight))
            .foregroundStyle(color)
            .monospacedDigit()
            .lineLimit(1)
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var actionTitle: LocalizedStringKey? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(title).font(Theme.title).foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.dkPrimary).padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// Tag for features that land in v1.1.
struct ComingSoonTag: View {
    var body: some View {
        Text(verbatim: "v1.1")
            .font(Theme.mono(10, .bold))
            .foregroundStyle(Theme.accentLight)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.accent.opacity(0.15)))
    }
}

// MARK: - Toggle style

struct DKToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack {
                configuration.label
                Spacer(minLength: 8)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.white.opacity(0.12)))
                        .frame(width: 38, height: 22)
                    Circle().fill(.white).frame(width: 18, height: 18).padding(2)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                }
                .animation(.snappy(duration: 0.15), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension ToggleStyle where Self == DKToggleStyle {
    static var dk: DKToggleStyle { DKToggleStyle() }
}

// MARK: - Brand

/// The app icon, used as the brand mark in the sidebar, menu bar helper and onboarding.
/// (The icon image includes Apple's standard transparent margin, so `size` is the full canvas.)
struct AppIconMark: View {
    var size: CGFloat = 40

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityLabel(Text(verbatim: "Yokoi"))
    }
}
