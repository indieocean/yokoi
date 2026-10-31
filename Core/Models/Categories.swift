import Foundation

/// Top-level reclaimable categories shown on the dashboard and sidebar.
enum CleanCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case nodeModules, buildArtifacts, caches, bigFiles, screenshots, applications, externalDrives, packages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nodeModules: "node_modules"
        case .buildArtifacts: "Build artifacts"
        case .caches: "Caches"
        case .bigFiles: "Big files"
        case .screenshots: "Screenshots"
        case .applications: "Applications"
        case .externalDrives: "External drives"
        case .packages: "Old packages"
        }
    }

    /// Two-letter badge used in the recent cleanups list.
    var badge: String {
        switch self {
        case .nodeModules: "NM"
        case .buildArtifacts: "BA"
        case .caches: "CA"
        case .bigFiles: "BF"
        case .screenshots: "SS"
        case .applications: "AP"
        case .externalDrives: "EX"
        case .packages: "PK"
        }
    }

    var colorHex: UInt32 {
        switch self {
        case .nodeModules: 0x34D399
        case .buildArtifacts: 0x7C5CFF
        case .caches: 0x22D3EE
        case .bigFiles: 0xF59E0B
        case .screenshots: 0xF472B6
        case .applications: 0xA78BFA
        case .externalDrives: 0xFB923C
        case .packages: 0x60A5FA
        }
    }
}

/// How safe it is to remove a location (PRD §5.4).
enum SafetyLevel: String, Codable, Sendable, CaseIterable, Comparable {
    /// Rebuilt automatically, no data loss.
    case safe
    /// Safe, but refetched over the network.
    case redownload
    /// Might contain things the user wants.
    case review

    var label: String {
        switch self {
        case .safe: "SAFE"
        case .redownload: "RE-DOWNLOAD"
        case .review: "REVIEW"
        }
    }

    var selectedByDefault: Bool { self == .safe }

    private var rank: Int {
        switch self {
        case .safe: 0
        case .redownload: 1
        case .review: 2
        }
    }

    static func < (lhs: SafetyLevel, rhs: SafetyLevel) -> Bool { lhs.rank < rhs.rank }
}

/// Languages, engines and toolchains that produce build artifacts.
enum Ecosystem: String, Codable, Sendable, CaseIterable, Identifiable {
    case rust, xcode, unreal, unity, gradle, swiftPM, python, go, dotnet, javascript, cmake

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rust: "Rust"
        case .xcode: "Xcode"
        case .unreal: "Unreal Engine"
        case .unity: "Unity"
        case .gradle: "Gradle"
        case .swiftPM: "Swift PM"
        case .python: "Python"
        case .go: "Go"
        case .dotnet: ".NET"
        case .javascript: "JS frameworks"
        case .cmake: "CMake"
        }
    }

    /// Short name for the summary chips.
    var shortName: String {
        switch self {
        case .unreal: "Unreal"
        case .javascript: "JS"
        default: displayName
        }
    }

    var badge: String {
        switch self {
        case .rust: "RS"
        case .xcode: "XC"
        case .unreal: "UE"
        case .unity: "U"
        case .gradle: "GR"
        case .swiftPM: "SW"
        case .python: "PY"
        case .go: "GO"
        case .dotnet: ".N"
        case .javascript: "JS"
        case .cmake: "CM"
        }
    }

    var colorHex: UInt32 {
        switch self {
        case .rust: 0xF97316
        case .xcode: 0x60A5FA
        case .unreal: 0xE6E8EE
        case .unity: 0xA78BFA
        case .gradle: 0x34D399
        case .swiftPM: 0xF87171
        case .python: 0xFACC15
        case .go: 0x22D3EE
        case .dotnet: 0xC084FC
        case .javascript: 0xFDE047
        case .cmake: 0x94A3B8
        }
    }
}

/// JavaScript package managers, detected from lockfiles.
enum JSPackageManager: String, Codable, Sendable, CaseIterable {
    case npm, pnpm, yarn, bun

    var installCommand: String {
        switch self {
        case .npm: "npm install"
        case .pnpm: "pnpm install"
        case .yarn: "yarn install"
        case .bun: "bun install"
        }
    }

    var colorHex: UInt32 {
        switch self {
        case .npm: 0xF87171
        case .pnpm: 0xF59E0B
        case .yarn: 0x60A5FA
        case .bun: 0xE6E8EE
        }
    }

    /// Lockfile names in priority order.
    static let lockfiles: [(String, JSPackageManager)] = [
        ("pnpm-lock.yaml", .pnpm),
        ("bun.lockb", .bun),
        ("bun.lock", .bun),
        ("yarn.lock", .yarn),
        ("package-lock.json", .npm),
        ("npm-shrinkwrap.json", .npm),
    ]
}
