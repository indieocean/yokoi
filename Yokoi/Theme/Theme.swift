import AppKit
import SwiftUI

/// The Yokoi palette and type scale (DESIGN.md). Colors live in the asset catalog.
enum Theme {
    static let bgWindow = Color("BgWindow")
    static let bgSidebarTop = Color("BgSidebarTop")
    static let bgSidebarBottom = Color("BgSidebarBottom")
    static let textPrimary = Color("TextPrimary")
    static let textSecondary = Color("TextSecondary")
    static let textTertiary = Color("TextTertiary")
    static let accent = Color("AccentColor")
    static let accentLight = Color("AccentLight")
    static let accentDeep = Color("AccentDeep")
    static let accent2 = Color("Accent2")
    static let danger = Color("Danger")
    static let dangerDeep = Color("DangerDeep")
    static let success = Color("Success")
    static let warning = Color("Warning")
    static let info = Color("Info")

    static let cardFill = LinearGradient(colors: [.white.opacity(0.035), .white.opacity(0.015)], startPoint: .top, endPoint: .bottom)
    static let cardStroke = Color.white.opacity(0.07)
    static let hairline = Color.white.opacity(0.06)
    static let rowHover = Color.white.opacity(0.025)
    static let rowSelected = Color("AccentColor").opacity(0.08)

    static let accentGradient = LinearGradient(colors: [accentLight, accentDeep], startPoint: .top, endPoint: .bottom)
    static let dangerGradient = LinearGradient(colors: [danger, dangerDeep], startPoint: .top, endPoint: .bottom)
    static let brandGradient = LinearGradient(colors: [accentLight, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)

    enum Radius {
        static let card: CGFloat = 12
        static let control: CGFloat = 7
        static let badge: CGFloat = 7
        static let pill: CGFloat = 5
    }

    enum Metrics {
        static let sidebarWidth: CGFloat = 232
        static let headerHeight: CGFloat = 52
        static let contentPadding: CGFloat = 22
        static let cardGap: CGFloat = 16
        static let rowHeight: CGFloat = 38
        static let denseRowHeight: CGFloat = 30
    }

    // MARK: Type

    static let title = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let label = Font.system(size: 11.5)
    static let section = Font.system(size: 10.5, weight: .semibold)

    private static let monoFamily: String? = {
        let families = NSFontManager.shared.availableFontFamilies
        return families.first { $0 == "JetBrains Mono" || $0 == "JetBrainsMono Nerd Font" }
    }()

    /// JetBrains Mono when installed, SF Mono otherwise. Used for paths, sizes, versions and KPIs.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if let monoFamily {
            return Font.custom(monoFamily, size: size).weight(weight).monospacedDigit()
        }
        return Font.system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

extension CleanCategory {
    var color: Color { Color(hex: colorHex) }

    var symbol: String {
        switch self {
        case .nodeModules: "shippingbox"
        case .buildArtifacts: "hammer"
        case .caches: "archivebox"
        case .bigFiles: "externaldrive.badge.exclamationmark"
        case .downloads: "arrow.down.circle"
        case .screenshots: "camera.viewfinder"
        case .applications: "app.dashed"
        case .externalDrives: "externaldrive.connected.to.line.below"
        case .packages: "cube.box"
        }
    }
}

extension Ecosystem {
    var color: Color { Color(hex: colorHex) }
}

extension SafetyLevel {
    var color: Color {
        switch self {
        case .safe: Theme.success
        case .redownload: Theme.accent2
        case .review: Theme.warning
        }
    }
}

extension BigFileKind {
    var color: Color { Color(hex: colorHex) }
}
