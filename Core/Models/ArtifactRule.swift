import Foundation

/// One data-driven build-artifact rule. A rule only fires in a directory that contains one of its
/// `markers`, so `target/` is matched next to `Cargo.toml` and nowhere else (PRD FR-B2).
///
/// Adding a language means adding a single entry to `ArtifactRule.all`.
struct ArtifactRule: Sendable, Identifiable, Hashable {
    enum Marker: Sendable, Hashable {
        /// A file or relative path that must exist, e.g. `Cargo.toml` or `ProjectSettings/ProjectVersion.txt`.
        case file(String)
        /// A glob matched against the names in the directory, e.g. `*.uproject`.
        case glob(String)
    }

    struct Target: Sendable, Hashable {
        /// Relative path from the project root. The last component may contain `*` (e.g. `cmake-build-*`).
        var path: String
        /// Opt-in targets are found but unchecked by default (PRD FR-B4).
        var optIn: Bool = false
        /// When non-empty, the target's *children* are removed except these names
        /// (Unreal `Saved/` keeps `Config`).
        var keepChildren: [String] = []
        /// Matched at any depth below the project root (Python `__pycache__`).
        var anywhere: Bool = false
        /// Shown in a tooltip for opt-in targets.
        var note: String? = nil
    }

    let id: String
    let ecosystem: Ecosystem
    let markers: [Marker]
    let targets: [Target]
    /// Short summary shown next to the group title, e.g. `target/`.
    let summary: String
    let restoreHint: String
    /// Rule ids that, when they also match the same directory, suppress this rule.
    var suppressedBy: [String] = []

    /// Every target name the rule can claim at the project root (used to skip them when walking).
    var rootTargetNames: Set<String> {
        Set(targets.filter { !$0.anywhere }.compactMap { $0.path.split(separator: "/").first.map(String.init) })
    }
}

extension ArtifactRule {
    /// The rule table. Order matters: when two rules claim the same folder, the earlier rule wins.
    static let all: [ArtifactRule] = [
        ArtifactRule(
            id: "rust", ecosystem: .rust,
            markers: [.file("Cargo.toml")],
            targets: [Target(path: "target")],
            summary: "target/", restoreHint: "cargo build"
        ),
        ArtifactRule(
            id: "unreal", ecosystem: .unreal,
            markers: [.glob("*.uproject")],
            targets: [
                Target(path: "Intermediate"),
                Target(path: "DerivedDataCache"),
                Target(path: "Saved", keepChildren: ["Config"]),
                Target(path: "Saved/Config", optIn: true, note: "Project and editor settings. Only remove if you know you don't need them."),
                Target(path: "Binaries", optIn: true, note: "Compiled editor and game binaries. Rebuilding takes a long time."),
            ],
            summary: "Intermediate · Saved · DDC", restoreHint: "reopen the project in Unreal Editor"
        ),
        ArtifactRule(
            id: "unity", ecosystem: .unity,
            markers: [.file("ProjectSettings/ProjectVersion.txt")],
            targets: [
                Target(path: "Library"), Target(path: "Temp"), Target(path: "Obj"), Target(path: "Logs"),
                Target(path: "*_BackUpThisFolder_ButDontShipItWithYourGame", optIn: true,
                       note: "IL2CPP build backup. Unity suggests keeping it to symbolicate crash reports from that build."),
            ],
            summary: "Library · Temp", restoreHint: "reopen the project in Unity"
        ),
        ArtifactRule(
            id: "gradle", ecosystem: .gradle,
            markers: [.file("build.gradle"), .file("build.gradle.kts"), .file("settings.gradle"), .file("settings.gradle.kts")],
            targets: [Target(path: "build"), Target(path: ".gradle")],
            summary: "build · .gradle", restoreHint: "./gradlew build"
        ),
        ArtifactRule(
            id: "swiftpm", ecosystem: .swiftPM,
            markers: [.file("Package.swift")],
            targets: [Target(path: ".build")],
            summary: ".build", restoreHint: "swift build"
        ),
        ArtifactRule(
            id: "python", ecosystem: .python,
            markers: [.file("pyproject.toml"), .file("requirements.txt"), .file("setup.py"), .file("setup.cfg"), .file("Pipfile"), .file("environment.yml")],
            targets: [
                Target(path: ".venv"), Target(path: "venv"),
                Target(path: ".pytest_cache"), Target(path: ".mypy_cache"), Target(path: ".ruff_cache"), Target(path: ".tox"),
                Target(path: "__pycache__", anywhere: true),
            ],
            summary: "__pycache__ · .venv", restoreHint: "recreate the virtualenv and reinstall"
        ),
        ArtifactRule(
            id: "dotnet", ecosystem: .dotnet,
            markers: [.glob("*.csproj"), .glob("*.fsproj"), .glob("*.sln")],
            targets: [Target(path: "bin"), Target(path: "obj")],
            summary: "bin · obj", restoreHint: "dotnet build",
            suppressedBy: ["unity"]
        ),
        ArtifactRule(
            id: "javascript", ecosystem: .javascript,
            markers: [.file("package.json")],
            targets: [
                Target(path: ".next"), Target(path: ".nuxt"), Target(path: ".svelte-kit"), Target(path: ".turbo"),
                Target(path: ".parcel-cache"), Target(path: ".angular"),
                Target(path: "dist", optIn: true, note: "Build output. Some projects commit or publish dist/, so it's opt-in."),
            ],
            summary: ".next · .turbo · dist", restoreHint: "rebuild the project"
        ),
        ArtifactRule(
            id: "cocoapods", ecosystem: .xcode,
            markers: [.file("Podfile")],
            targets: [Target(path: "Pods", optIn: true, note: "Some projects commit Pods/ to git, so it's opt-in.")],
            summary: "Pods", restoreHint: "pod install"
        ),
        ArtifactRule(
            id: "cmake", ecosystem: .cmake,
            markers: [.file("CMakeLists.txt")],
            targets: [Target(path: "build"), Target(path: "cmake-build-*")],
            summary: "build · cmake-build-*", restoreHint: "re-run cmake"
        ),
    ]

    /// Folders that are never descended into while looking for projects.
    static let skippedDirectoryNames: Set<String> = [
        "node_modules", ".git", ".hg", ".svn", ".Trash", ".idea", ".vscode",
    ]
}

/// Global, marker-less artifact locations (Xcode DerivedData, Go build cache).
struct GlobalArtifactRule: Sendable, Identifiable, Hashable {
    let id: String
    let ecosystem: Ecosystem
    /// Path relative to the home directory.
    let relativePath: String
    let title: String
    let summary: String
    let restoreHint: String

    /// What's writing to these folders while it runs. There's no project folder to watch for a global location.
    static func usedByApps(_ ecosystem: Ecosystem) -> [String] {
        switch ecosystem {
        case .xcode: ["Xcode", "xcodebuild"]
        case .go: ["go"]
        default: []
        }
    }

    static let all: [GlobalArtifactRule] = [
        GlobalArtifactRule(
            id: "xcode-deriveddata", ecosystem: .xcode,
            relativePath: "Library/Developer/Xcode/DerivedData",
            title: "All projects", summary: "DerivedData", restoreHint: "build again in Xcode"
        ),
        GlobalArtifactRule(
            id: "go-build", ecosystem: .go,
            relativePath: "Library/Caches/go-build",
            title: "go-build", summary: "build cache", restoreHint: "go build"
        ),
    ]
}
