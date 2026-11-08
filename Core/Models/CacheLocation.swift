import Foundation

/// A known cache location (PRD §5.4). Cleaning removes the folder's *contents*, never the folder itself.
struct CacheLocation: Sendable, Identifiable, Hashable {
    enum Section: String, Sendable, CaseIterable, Codable {
        case systemUser = "System & User"
        case javascript = "JavaScript"
        case python = "Python"
        case nativeToolchains = "Native toolchains"
        case xcode = "Xcode"
        case android = "Android"
        case editors = "Editors & IDEs"
        case containers = "Containers"
        case aiAgents = "AI agents"
        case aiModels = "AI models"
        /// No longer used: installers in Downloads moved to the Downloads screen. Kept so older scan caches decode.
        case downloads = "Downloads"
        case browsers = "Browsers"
        /// Shown on its own, above the list: it holds deleted files, not a cache.
        case trash = "Trash"

        /// The heading shown on screen. The raw value is persisted in scan caches, so it stays English.
        var title: String {
            switch self {
            case .systemUser: String(localized: "System & User", comment: "Caches screen section heading")
            case .javascript: "JavaScript"
            case .python: "Python"
            case .nativeToolchains: String(localized: "Native toolchains", comment: "Caches screen section heading")
            case .xcode: "Xcode"
            case .android: "Android"
            case .editors: String(localized: "Editors & IDEs", comment: "Caches screen section heading")
            case .containers: String(localized: "Containers", comment: "Caches screen section heading: Docker, OrbStack")
            case .aiAgents: String(localized: "AI agents", comment: "Caches screen section heading")
            case .aiModels: String(localized: "AI models", comment: "Caches screen section heading")
            case .downloads: String(localized: "Downloads", comment: "Caches screen section heading")
            case .browsers: String(localized: "Browsers", comment: "Caches screen section heading")
            case .trash: String(localized: "Trash", comment: "Caches screen section heading: the macOS Trash")
            }
        }
    }

    let id: String
    let name: String
    let section: Section
    /// Path relative to the home directory.
    let relativePath: String
    let safety: SafetyLevel
    let badge: String
    let colorHex: UInt32
    let restoreHint: String
    /// Child-name globs never removed from this location.
    var keepChildren: [String] = []
    /// If true, children that are covered by other, more specific cache locations are skipped
    /// so sizes aren't counted twice (used by "User caches").
    var excludesNestedLocations: Bool = false
    /// Only these file extensions are removed (e.g. installers in Downloads). Top-level files only.
    var onlyExtensions: [String]? = nil
    /// Moving to the Trash makes no sense (it *is* the Trash): only permanent delete is offered.
    var permanentOnly: Bool = false
    /// How the location's contents are listed under its twisty so single items can be cleaned.
    var breakdown: Breakdown = .children
    /// Apps (bundle names without `.app`), process names, or path fragments (anything with a `/`) that keep this
    /// location open. Cleanup is refused while one of them runs: an editor or Docker writing its cache as it's
    /// removed can corrupt it. Fragments are for tools that can't be told by name: the Claude Code binary's
    /// process is named after its version, and npm-installed agents all run as `node`.
    var usedByApps: [String] = []

    /// How a location's contents become individually selectable rows.
    enum Breakdown: String, Sendable, Codable {
        /// Not broken down: the parts only make sense together (a content-addressed store, the Trash).
        case none
        /// One row per top-level item, largest first.
        case children
        /// One row per simulator, named from its `device.plist`.
        case simulators
        /// One row per `.xcarchive` inside the date folders, named from its `Info.plist`.
        case archives
        /// One row per OS version folder (`iPhone15,2 17.0 (21A329)`).
        case deviceSupport
        /// One row per emulator: `Name.avd` and `Name.ini` together.
        case avds
        /// One row per installed image (`android-34/google_apis/arm64-v8a`).
        case systemImages
        /// One row per model (`models--org--name`).
        case huggingface
        /// One row per workspace: `workspaces/<name>/DerivedData` only, never the workspace's other state.
        case workspaceDerivedData
        /// One row per Claude Code project: its session transcripts only, never its `memory` folder.
        case claudeProjects
        /// One row per working directory (`%2FUsers%2Fme%2Fapp`), named from the decoded path.
        case encodedProjects
        /// One row per download, leaving out whatever a link in the sibling `bin` folder points at: that's the installed version.
        case unlinkedDownloads

        /// Versioned things read best newest first, so the old ones collect at the bottom.
        var sortsByDate: Bool { [.simulators, .archives, .deviceSupport, .systemImages, .avds].contains(self) }
    }

    func url(home: URL) -> URL { home.appendingPathComponent(relativePath) }

    /// Every location by id.
    static let byID: [String: CacheLocation] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// Locations a running process may be using: emulators keep their AVD open, a Gradle daemon keeps its
    /// caches and distribution open between builds, `rustc` reads crate sources from the registry, and a
    /// booted simulator runs from its device folder. Clearing them underneath it can break the build or
    /// corrupt the cache, so cleanup is refused while a process holds a file inside them, like an open project.
    static let inUseGuarded: Set<String> = [
        "android-avd", "android-system-images", "gradle-caches", "gradle-wrapper", "gradle-daemon", "cargo-registry", "cargo-git",
        "simulator-devices", "xctest-devices", "xcode-previews",
        "xcodebuildmcp-deriveddata", "xcodebuildmcp-workspaces", "mobilebuildmcp-deriveddata", "mobilebuildmcp-workspaces",
    ]

    /// JetBrains IDEs by process name (their bundles have many names: `IntelliJ IDEA CE.app`, `PyCharm Professional Edition.app`…).
    static let jetBrainsProcesses = ["idea", "webstorm", "pycharm", "goland", "clion", "rider", "rubymine", "phpstorm",
                                     "datagrip", "rustrover", "dataspell", "aqua", "studio"]

    // What keeps each agent's folders open. An agent writes its session files as it runs, so they wait for it to quit.
    // The `/bin/` fragments are npm installs: `node /opt/homebrew/bin/gemini`, with the link in the arguments unresolved.
    static let claudeDesktopProcesses = ["Claude"]
    /// The desktop app is listed too: it runs Claude Code sessions of its own.
    static let claudeCodeProcesses = ["claude", "Claude", "/.local/share/claude/", "/claude-code/", "/bin/claude"]
    static let codexProcesses = ["codex", "Codex", "/@openai/codex/", "/bin/codex"]
    static let grokProcesses = ["grok", "Grok Bot", "/.grok/downloads/", "/.grok/bin/"]
    static let geminiProcesses = ["gemini", "/@google/gemini-cli/", "/bin/gemini"]
    static let copilotProcesses = ["copilot", "/@github/copilot", "/bin/copilot"]
}

extension CacheLocation {
    static let all: [CacheLocation] = [
        // System & User
        CacheLocation(id: "user-caches", name: String(localized: "User caches", comment: "Cache location name on the Caches screen"), section: .systemUser, relativePath: "Library/Caches",
                      safety: .safe, badge: "◎", colorHex: 0x7D8597, restoreHint: String(localized: "apps rebuild their caches automatically", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"),
                      keepChildren: ["com.apple.*", "com.yokoi.*", "com.diskkeeper.*", "CloudKit", "FamilyCircle"], excludesNestedLocations: true),
        CacheLocation(id: "trash", name: String(localized: "Trash", comment: "Cache location name on the Caches screen"), section: .trash, relativePath: ".Trash",
                      safety: .review, badge: "🗑", colorHex: 0xF0565E, restoreHint: String(localized: "emptying the Trash can't be undone", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"),
                      permanentOnly: true, breakdown: .none),
        CacheLocation(id: "logs", name: String(localized: "Logs", comment: "Cache location name on the Caches screen"), section: .systemUser, relativePath: "Library/Logs",
                      safety: .safe, badge: "◎", colorHex: 0x7D8597, restoreHint: String(localized: "logs are recreated as needed", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), excludesNestedLocations: true),
        // JavaScript
        CacheLocation(id: "npm", name: String(localized: "npm cache", comment: "Cache location name on the Caches screen"), section: .javascript, relativePath: ".npm/_cacache",
                      safety: .safe, badge: "npm", colorHex: 0xF87171, restoreHint: String(localized: "npm refills it on the next install", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), breakdown: .none),
        CacheLocation(id: "pnpm", name: String(localized: "pnpm store", comment: "Cache location name on the Caches screen"), section: .javascript, relativePath: "Library/pnpm/store",
                      safety: .redownload, badge: "pn", colorHex: 0xF59E0B, restoreHint: String(localized: "pnpm re-downloads packages on the next install", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), breakdown: .none),
        CacheLocation(id: "yarn", name: String(localized: "Yarn cache", comment: "Cache location name on the Caches screen"), section: .javascript, relativePath: "Library/Caches/Yarn",
                      safety: .safe, badge: "y", colorHex: 0x60A5FA, restoreHint: String(localized: "yarn refills it on the next install", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "bun", name: String(localized: "Bun cache", comment: "Cache location name on the Caches screen"), section: .javascript, relativePath: ".bun/install/cache",
                      safety: .safe, badge: "bun", colorHex: 0xE6E8EE, restoreHint: String(localized: "bun refills it on the next install", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), breakdown: .none),
        CacheLocation(id: "npm-logs", name: String(localized: "npm logs", comment: "Cache location name on the Caches screen"), section: .javascript, relativePath: ".npm/_logs",
                      safety: .safe, badge: "npm", colorHex: 0xF87171, restoreHint: String(localized: "npm writes new logs as it runs", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), breakdown: .none),
        CacheLocation(id: "yarn-xdg", name: String(localized: "Yarn cache (~/.cache)", comment: "Cache location name on the Caches screen"), section: .javascript, relativePath: ".cache/yarn",
                      safety: .safe, badge: "y", colorHex: 0x60A5FA, restoreHint: String(localized: "yarn refills it on the next install", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "yarn-berry", name: String(localized: "Yarn Berry global cache", comment: "Cache location name on the Caches screen"), section: .javascript, relativePath: ".yarn/berry/cache",
                      safety: .redownload, badge: "y", colorHex: 0x60A5FA, restoreHint: String(localized: "Yarn re-downloads packages on the next install", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), breakdown: .none),
        CacheLocation(id: "pnpm-legacy", name: String(localized: "pnpm store (~/.pnpm-store)", comment: "Cache location name on the Caches screen"), section: .javascript, relativePath: ".pnpm-store",
                      safety: .redownload, badge: "pn", colorHex: 0xF59E0B, restoreHint: String(localized: "pnpm re-downloads packages on the next install", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), breakdown: .none),
        CacheLocation(id: "pnpm-xdg", name: String(localized: "pnpm store (~/.local/share)", comment: "Cache location name on the Caches screen"), section: .javascript, relativePath: ".local/share/pnpm/store",
                      safety: .redownload, badge: "pn", colorHex: 0xF59E0B, restoreHint: String(localized: "pnpm re-downloads packages on the next install", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), breakdown: .none),
        CacheLocation(id: "pnpm-metadata", name: String(localized: "pnpm metadata cache", comment: "Cache location name on the Caches screen"), section: .javascript, relativePath: ".cache/pnpm",
                      safety: .safe, badge: "pn", colorHex: 0xF59E0B, restoreHint: String(localized: "pnpm fetches package metadata again", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "deno", name: String(localized: "Deno cache", comment: "Cache location name on the Caches screen"), section: .javascript, relativePath: "Library/Caches/deno",
                      safety: .redownload, badge: "dn", colorHex: 0xE6E8EE, restoreHint: String(localized: "Deno re-downloads modules on the next run", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "deno-xdg", name: String(localized: "Deno cache (~/.cache)", comment: "Cache location name on the Caches screen"), section: .javascript, relativePath: ".cache/deno",
                      safety: .redownload, badge: "dn", colorHex: 0xE6E8EE, restoreHint: String(localized: "Deno re-downloads modules on the next run", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "node-gyp", name: String(localized: "node-gyp headers", comment: "Cache location name on the Caches screen"), section: .javascript, relativePath: "Library/Caches/node-gyp",
                      safety: .safe, badge: "gyp", colorHex: 0x34D399, restoreHint: String(localized: "node-gyp downloads Node headers again for the next native build", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "node-gyp-xdg", name: String(localized: "node-gyp headers (~/.cache)", comment: "Cache location name on the Caches screen"), section: .javascript, relativePath: ".cache/node-gyp",
                      safety: .safe, badge: "gyp", colorHex: 0x34D399, restoreHint: String(localized: "node-gyp downloads Node headers again for the next native build", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "electron", name: String(localized: "Electron downloads", comment: "Cache location name on the Caches screen"), section: .javascript, relativePath: "Library/Caches/electron",
                      safety: .redownload, badge: "el", colorHex: 0x9FEAF9, restoreHint: String(localized: "Electron is downloaded again on the next install", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "electron-builder", name: String(localized: "electron-builder downloads", comment: "Cache location name on the Caches screen"), section: .javascript, relativePath: "Library/Caches/electron-builder",
                      safety: .redownload, badge: "el", colorHex: 0x9FEAF9, restoreHint: String(localized: "electron-builder downloads its tools again on the next build", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "puppeteer", name: String(localized: "Puppeteer browsers", comment: "Cache location name on the Caches screen"), section: .javascript, relativePath: ".cache/puppeteer",
                      safety: .redownload, badge: "pup", colorHex: 0x34D399, restoreHint: String(localized: "`npx puppeteer browsers install` downloads them again", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "playwright", name: String(localized: "Playwright browsers", comment: "Cache location name on the Caches screen"), section: .javascript, relativePath: "Library/Caches/ms-playwright",
                      safety: .redownload, badge: "pw", colorHex: 0x34D399, restoreHint: String(localized: "`npx playwright install` downloads them again", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "playwright-xdg", name: String(localized: "Playwright browsers (~/.cache)", comment: "Cache location name on the Caches screen"), section: .javascript, relativePath: ".cache/ms-playwright",
                      safety: .redownload, badge: "pw", colorHex: 0x34D399, restoreHint: String(localized: "`npx playwright install` downloads them again", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        // Python
        CacheLocation(id: "pip-xdg", name: String(localized: "pip (~/.cache)", comment: "Cache location name on the Caches screen"), section: .python, relativePath: ".cache/pip",
                      safety: .safe, badge: "pip", colorHex: 0xFACC15, restoreHint: String(localized: "pip refills it on the next install", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "uv", name: String(localized: "uv cache", comment: "Cache location name on the Caches screen"), section: .python, relativePath: ".cache/uv",
                      safety: .redownload, badge: "uv", colorHex: 0xDE5FE9, restoreHint: String(localized: "uv re-downloads packages on the next sync; existing environments keep working", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), breakdown: .none),
        CacheLocation(id: "uv-library", name: String(localized: "uv cache (Library)", comment: "Cache location name on the Caches screen"), section: .python, relativePath: "Library/Caches/uv",
                      safety: .redownload, badge: "uv", colorHex: 0xDE5FE9, restoreHint: String(localized: "uv re-downloads packages on the next sync; existing environments keep working", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), breakdown: .none),
        // Poetry keeps its virtualenvs inside its cache folder on macOS: those are never touched.
        CacheLocation(id: "poetry", name: String(localized: "Poetry cache", comment: "Cache location name on the Caches screen"), section: .python, relativePath: "Library/Caches/pypoetry",
                      safety: .redownload, badge: "po", colorHex: 0x60A5FA, restoreHint: String(localized: "Poetry re-downloads packages on the next install", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"),
                      keepChildren: ["virtualenvs"]),
        CacheLocation(id: "poetry-xdg", name: String(localized: "Poetry cache (~/.cache)", comment: "Cache location name on the Caches screen"), section: .python, relativePath: ".cache/pypoetry",
                      safety: .redownload, badge: "po", colorHex: 0x60A5FA, restoreHint: String(localized: "Poetry re-downloads packages on the next install", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"),
                      keepChildren: ["virtualenvs"]),
        // Native toolchains
        CacheLocation(id: "homebrew", name: String(localized: "Homebrew downloads", comment: "Cache location name on the Caches screen"), section: .nativeToolchains, relativePath: "Library/Caches/Homebrew",
                      safety: .safe, badge: "br", colorHex: 0xF59E0B, restoreHint: String(localized: "brew downloads bottles again when needed", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "cargo-registry", name: String(localized: "Cargo registry", comment: "Cache location name on the Caches screen"), section: .nativeToolchains, relativePath: ".cargo/registry",
                      safety: .redownload, badge: "cg", colorHex: 0xF97316, restoreHint: String(localized: "cargo re-downloads crates on the next build", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "gradle-caches", name: String(localized: "Gradle caches", comment: "Cache location name on the Caches screen"), section: .nativeToolchains, relativePath: ".gradle/caches",
                      safety: .redownload, badge: "gr", colorHex: 0x34D399, restoreHint: String(localized: "Gradle re-downloads dependencies on the next build", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "gradle-wrapper", name: String(localized: "Gradle wrapper distributions", comment: "Cache location name on the Caches screen"), section: .nativeToolchains, relativePath: ".gradle/wrapper/dists",
                      safety: .redownload, badge: "gr", colorHex: 0x34D399, restoreHint: String(localized: "./gradlew downloads its distribution again on the next build", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "cocoapods", name: "CocoaPods", section: .nativeToolchains, relativePath: "Library/Caches/CocoaPods",
                      safety: .safe, badge: "pod", colorHex: 0xF87171, restoreHint: String(localized: "pod install refills it", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "pip", name: "pip", section: .python, relativePath: "Library/Caches/pip",
                      safety: .safe, badge: "pip", colorHex: 0xFACC15, restoreHint: String(localized: "pip refills it on the next install", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "cargo-git", name: String(localized: "Cargo git dependencies", comment: "Cache location name on the Caches screen"), section: .nativeToolchains, relativePath: ".cargo/git",
                      safety: .redownload, badge: "cg", colorHex: 0xF97316, restoreHint: String(localized: "cargo clones git dependencies again on the next build", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "gradle-daemon", name: String(localized: "Gradle daemon logs", comment: "Cache location name on the Caches screen"), section: .nativeToolchains, relativePath: ".gradle/daemon",
                      safety: .safe, badge: "gr", colorHex: 0x34D399, restoreHint: String(localized: "Gradle starts a fresh daemon and log on the next build", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "maven", name: String(localized: "Maven repository", comment: "Cache location name on the Caches screen"), section: .nativeToolchains, relativePath: ".m2/repository",
                      safety: .review, badge: "mvn", colorHex: 0xF87171,
                      restoreHint: String(localized: "Maven re-downloads dependencies; anything you `mvn install`ed locally is lost", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "swiftpm", name: String(localized: "Swift Package Manager cache", comment: "Cache location name on the Caches screen"), section: .nativeToolchains, relativePath: "Library/Caches/org.swift.swiftpm",
                      safety: .redownload, badge: "spm", colorHex: 0xF05138, restoreHint: String(localized: "SwiftPM re-downloads packages on the next resolve", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        // Activated global tools live in bin/ and global_packages/, so they stay.
        CacheLocation(id: "pub-cache", name: String(localized: "Flutter / Dart pub cache", comment: "Cache location name on the Caches screen"), section: .nativeToolchains, relativePath: ".pub-cache",
                      safety: .redownload, badge: "dt", colorHex: 0x22D3EE, restoreHint: String(localized: "`flutter pub get` downloads packages again", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"),
                      keepChildren: ["bin", "global_packages"]),
        CacheLocation(id: "nuget-packages", name: String(localized: "NuGet packages", comment: "Cache location name on the Caches screen"), section: .nativeToolchains, relativePath: ".nuget/packages",
                      safety: .review, badge: "nu", colorHex: 0xA78BFA,
                      restoreHint: String(localized: "`dotnet restore` downloads them again; packages only added from a local folder are lost", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "nuget-http", name: String(localized: "NuGet HTTP cache", comment: "Cache location name on the Caches screen"), section: .nativeToolchains, relativePath: ".local/share/NuGet/http-cache",
                      safety: .safe, badge: "nu", colorHex: 0xA78BFA, restoreHint: String(localized: "NuGet refills it on the next restore", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "nuget-v3", name: String(localized: "NuGet v3 cache", comment: "Cache location name on the Caches screen"), section: .nativeToolchains, relativePath: ".local/share/NuGet/v3-cache",
                      safety: .safe, badge: "nu", colorHex: 0xA78BFA, restoreHint: String(localized: "NuGet refills it on the next restore", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "mise", name: String(localized: "mise cache", comment: "Cache location name on the Caches screen"), section: .nativeToolchains, relativePath: ".cache/mise",
                      safety: .safe, badge: "mi", colorHex: 0xE6E8EE, restoreHint: String(localized: "mise refills it as needed; installed tools are kept", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        // Xcode
        CacheLocation(id: "xcode-cache", name: String(localized: "Xcode caches", comment: "Cache location name on the Caches screen"), section: .xcode, relativePath: "Library/Caches/com.apple.dt.Xcode",
                      safety: .safe, badge: "xc", colorHex: 0x60A5FA, restoreHint: String(localized: "Xcode rebuilds it", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "simulator-caches", name: String(localized: "Simulator caches", comment: "Cache location name on the Caches screen"), section: .xcode, relativePath: "Library/Developer/CoreSimulator/Caches",
                      safety: .safe, badge: "sim", colorHex: 0x60A5FA, restoreHint: String(localized: "the Simulator rebuilds it", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "simulator-devices", name: String(localized: "iOS Simulators (devices)", comment: "Cache location name on the Caches screen"), section: .xcode, relativePath: "Library/Developer/CoreSimulator/Devices",
                      safety: .review, badge: "sim", colorHex: 0x60A5FA, restoreHint: String(localized: "recreate simulators in Xcode › Devices (their app data is lost)", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"),
                      keepChildren: ["device_set.plist", ".*"], breakdown: .simulators),
        CacheLocation(id: "xcode-archives", name: String(localized: "Archives", comment: "Cache location name on the Caches screen"), section: .xcode, relativePath: "Library/Developer/Xcode/Archives",
                      safety: .review, badge: "arc", colorHex: 0x60A5FA, restoreHint: String(localized: "archives contain dSYMs and can't be recreated", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), breakdown: .archives),
        CacheLocation(id: "device-support", name: String(localized: "Device support", comment: "Cache location name on the Caches screen"), section: .xcode, relativePath: "Library/Developer/Xcode/iOS DeviceSupport",
                      safety: .review, badge: "dev", colorHex: 0x60A5FA, restoreHint: String(localized: "Xcode re-copies symbols when a device connects", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), breakdown: .deviceSupport),
        CacheLocation(id: "watch-device-support", name: String(localized: "watchOS device support", comment: "Cache location name on the Caches screen"), section: .xcode, relativePath: "Library/Developer/Xcode/watchOS DeviceSupport",
                      safety: .review, badge: "dev", colorHex: 0x60A5FA, restoreHint: String(localized: "Xcode re-copies symbols when a watch connects", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), breakdown: .deviceSupport),
        CacheLocation(id: "tv-device-support", name: String(localized: "tvOS device support", comment: "Cache location name on the Caches screen"), section: .xcode, relativePath: "Library/Developer/Xcode/tvOS DeviceSupport",
                      safety: .review, badge: "dev", colorHex: 0x60A5FA, restoreHint: String(localized: "Xcode re-copies symbols when an Apple TV connects", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), breakdown: .deviceSupport),
        CacheLocation(id: "xctest-devices", name: String(localized: "Test simulator clones", comment: "Cache location name on the Caches screen"), section: .xcode, relativePath: "Library/Developer/XCTestDevices",
                      safety: .safe, badge: "sim", colorHex: 0x60A5FA, restoreHint: String(localized: "Xcode clones simulators again for parallel testing", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), breakdown: .simulators),
        CacheLocation(id: "xcode-previews", name: String(localized: "SwiftUI Previews", comment: "Cache location name on the Caches screen"), section: .xcode, relativePath: "Library/Developer/Xcode/UserData/Previews",
                      safety: .safe, badge: "pv", colorHex: 0x60A5FA, restoreHint: String(localized: "Xcode rebuilds previews when you open them", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "xcodebuildmcp-deriveddata", name: "XcodeBuildMCP DerivedData", section: .xcode, relativePath: "Library/Developer/XcodeBuildMCP/DerivedData",
                      safety: .safe, badge: "mcp", colorHex: 0x60A5FA, restoreHint: String(localized: "the next agent build rebuilds it", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "xcodebuildmcp-workspaces", name: String(localized: "XcodeBuildMCP workspace builds", comment: "Cache location name on the Caches screen"), section: .xcode, relativePath: "Library/Developer/XcodeBuildMCP/workspaces",
                      safety: .safe, badge: "mcp", colorHex: 0x60A5FA, restoreHint: String(localized: "the next agent build rebuilds it", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), breakdown: .workspaceDerivedData),
        CacheLocation(id: "mobilebuildmcp-deriveddata", name: "MobileBuildMCP DerivedData", section: .xcode, relativePath: "Library/Developer/MobileBuildMCP/DerivedData",
                      safety: .safe, badge: "mcp", colorHex: 0x60A5FA, restoreHint: String(localized: "the next agent build rebuilds it", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "mobilebuildmcp-workspaces", name: String(localized: "MobileBuildMCP workspace builds", comment: "Cache location name on the Caches screen"), section: .xcode, relativePath: "Library/Developer/MobileBuildMCP/workspaces",
                      safety: .safe, badge: "mcp", colorHex: 0x60A5FA, restoreHint: String(localized: "the next agent build rebuilds it", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), breakdown: .workspaceDerivedData),
        // Android
        CacheLocation(id: "android-avd", name: String(localized: "Android emulators (AVDs)", comment: "Cache location name on the Caches screen"), section: .android, relativePath: ".android/avd",
                      safety: .review, badge: "avd", colorHex: 0x3DDC84, restoreHint: String(localized: "recreate emulators in Android Studio › Device Manager (their app data is lost)", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), breakdown: .avds),
        CacheLocation(id: "android-system-images", name: String(localized: "Android system images", comment: "Cache location name on the Caches screen"), section: .android, relativePath: "Library/Android/sdk/system-images",
                      safety: .review, badge: "img", colorHex: 0x3DDC84, restoreHint: String(localized: "reinstall them in Android Studio › SDK Manager; emulators that use them won't boot until then", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), breakdown: .systemImages),
        CacheLocation(id: "android-cache", name: String(localized: "Android SDK cache", comment: "Cache location name on the Caches screen"), section: .android, relativePath: ".android/cache",
                      safety: .safe, badge: "and", colorHex: 0x3DDC84, restoreHint: String(localized: "the SDK tools rebuild it", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "android-build-cache", name: String(localized: "Android build cache", comment: "Cache location name on the Caches screen"), section: .android, relativePath: ".android/build-cache",
                      safety: .safe, badge: "and", colorHex: 0x3DDC84, restoreHint: String(localized: "the Android Gradle plugin rebuilds it on the next build", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        // Editors & IDEs: refused while the editor is open.
        CacheLocation(id: "vscode-cache", name: String(localized: "VS Code cache", comment: "Cache location name on the Caches screen"), section: .editors, relativePath: "Library/Application Support/Code/Cache",
                      safety: .safe, badge: "vs", colorHex: 0x3B82F6, restoreHint: String(localized: "VS Code rebuilds it", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: ["Visual Studio Code"]),
        CacheLocation(id: "vscode-cached-data", name: String(localized: "VS Code compiled code", comment: "Cache location name on the Caches screen"), section: .editors, relativePath: "Library/Application Support/Code/CachedData",
                      safety: .safe, badge: "vs", colorHex: 0x3B82F6, restoreHint: String(localized: "VS Code rebuilds it; the next start is a little slower", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: ["Visual Studio Code"]),
        CacheLocation(id: "vscode-vsix", name: String(localized: "VS Code extension downloads", comment: "Cache location name on the Caches screen"), section: .editors, relativePath: "Library/Application Support/Code/CachedExtensionVSIXs",
                      safety: .safe, badge: "vs", colorHex: 0x3B82F6, restoreHint: String(localized: "installed extensions are kept; VS Code downloads updates again", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: ["Visual Studio Code"]),
        CacheLocation(id: "vscode-logs", name: String(localized: "VS Code logs", comment: "Cache location name on the Caches screen"), section: .editors, relativePath: "Library/Application Support/Code/logs",
                      safety: .safe, badge: "vs", colorHex: 0x3B82F6, restoreHint: String(localized: "VS Code writes new logs", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: ["Visual Studio Code"]),
        CacheLocation(id: "cursor-cache", name: String(localized: "Cursor cache", comment: "Cache location name on the Caches screen"), section: .editors, relativePath: "Library/Application Support/Cursor/Cache",
                      safety: .safe, badge: "cu", colorHex: 0xE6E8EE, restoreHint: String(localized: "Cursor rebuilds it", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: ["Cursor"]),
        CacheLocation(id: "cursor-cached-data", name: String(localized: "Cursor compiled code", comment: "Cache location name on the Caches screen"), section: .editors, relativePath: "Library/Application Support/Cursor/CachedData",
                      safety: .safe, badge: "cu", colorHex: 0xE6E8EE, restoreHint: String(localized: "Cursor rebuilds it; the next start is a little slower", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: ["Cursor"]),
        CacheLocation(id: "cursor-logs", name: String(localized: "Cursor logs", comment: "Cache location name on the Caches screen"), section: .editors, relativePath: "Library/Application Support/Cursor/logs",
                      safety: .safe, badge: "cu", colorHex: 0xE6E8EE, restoreHint: String(localized: "Cursor writes new logs", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: ["Cursor"]),
        CacheLocation(id: "windsurf-cache", name: String(localized: "Windsurf cache", comment: "Cache location name on the Caches screen"), section: .editors, relativePath: "Library/Application Support/Windsurf/Cache",
                      safety: .safe, badge: "ws", colorHex: 0x34D399, restoreHint: String(localized: "Windsurf rebuilds it", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: ["Windsurf"]),
        CacheLocation(id: "windsurf-cached-data", name: String(localized: "Windsurf compiled code", comment: "Cache location name on the Caches screen"), section: .editors, relativePath: "Library/Application Support/Windsurf/CachedData",
                      safety: .safe, badge: "ws", colorHex: 0x34D399, restoreHint: String(localized: "Windsurf rebuilds it; the next start is a little slower", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: ["Windsurf"]),
        CacheLocation(id: "windsurf-logs", name: String(localized: "Windsurf logs", comment: "Cache location name on the Caches screen"), section: .editors, relativePath: "Library/Application Support/Windsurf/logs",
                      safety: .safe, badge: "ws", colorHex: 0x34D399, restoreHint: String(localized: "Windsurf writes new logs", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: ["Windsurf"]),
        CacheLocation(id: "jetbrains-caches", name: String(localized: "JetBrains caches", comment: "Cache location name on the Caches screen"), section: .editors, relativePath: "Library/Caches/JetBrains",
                      safety: .safe, badge: "jb", colorHex: 0xF472B6, restoreHint: String(localized: "the IDE re-indexes projects on the next open", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: jetBrainsProcesses),
        CacheLocation(id: "jetbrains-logs", name: String(localized: "JetBrains logs", comment: "Cache location name on the Caches screen"), section: .editors, relativePath: "Library/Logs/JetBrains",
                      safety: .safe, badge: "jb", colorHex: 0xF472B6, restoreHint: String(localized: "the IDE writes new logs", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: jetBrainsProcesses),
        // Containers: refused while Docker Desktop or OrbStack runs.
        CacheLocation(id: "docker-desktop-cache", name: String(localized: "Docker Desktop cache", comment: "Cache location name on the Caches screen"), section: .containers, relativePath: "Library/Containers/com.docker.docker/Data/cache",
                      safety: .safe, badge: "dk", colorHex: 0x2496ED, restoreHint: String(localized: "Docker Desktop rebuilds it", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: ["Docker"]),
        CacheLocation(id: "docker-desktop-logs", name: String(localized: "Docker Desktop logs", comment: "Cache location name on the Caches screen"), section: .containers, relativePath: "Library/Containers/com.docker.docker/Data/log",
                      safety: .safe, badge: "dk", colorHex: 0x2496ED, restoreHint: String(localized: "Docker Desktop writes new logs", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: ["Docker"]),
        CacheLocation(id: "docker-desktop-tmp", name: String(localized: "Docker Desktop temporary files", comment: "Cache location name on the Caches screen"), section: .containers, relativePath: "Library/Containers/com.docker.docker/Data/tmp",
                      safety: .safe, badge: "dk", colorHex: 0x2496ED, restoreHint: String(localized: "Docker Desktop recreates what it needs", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: ["Docker"]),
        CacheLocation(id: "docker-group-caches", name: String(localized: "Docker shared caches", comment: "Cache location name on the Caches screen"), section: .containers, relativePath: "Library/Group Containers/group.com.docker/Caches",
                      safety: .safe, badge: "dk", colorHex: 0x2496ED, restoreHint: String(localized: "Docker Desktop rebuilds it", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: ["Docker"]),
        CacheLocation(id: "docker-cli-plugins", name: String(localized: "Docker CLI plugin cache", comment: "Cache location name on the Caches screen"), section: .containers, relativePath: ".docker/cli-plugins/.cache",
                      safety: .safe, badge: "dk", colorHex: 0x2496ED, restoreHint: String(localized: "the Docker CLI refills it", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "docker-buildx", name: String(localized: "Docker buildx cache", comment: "Cache location name on the Caches screen"), section: .containers, relativePath: ".docker/buildx/cache",
                      safety: .redownload, badge: "bk", colorHex: 0x2496ED, restoreHint: String(localized: "the next `docker buildx build` is slower while it refills", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "orbstack-logs", name: String(localized: "OrbStack logs", comment: "Cache location name on the Caches screen"), section: .containers, relativePath: ".orbstack/log",
                      safety: .safe, badge: "orb", colorHex: 0x8B5CF6, restoreHint: String(localized: "OrbStack writes new logs", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: ["OrbStack"]),
        CacheLocation(id: "orbstack-caches", name: String(localized: "OrbStack cache", comment: "Cache location name on the Caches screen"), section: .containers, relativePath: "Library/Caches/dev.kdrag0n.MacVirt",
                      safety: .safe, badge: "orb", colorHex: 0x8B5CF6, restoreHint: String(localized: "OrbStack rebuilds it", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: ["OrbStack"]),
        CacheLocation(id: "orbstack-app-logs", name: String(localized: "OrbStack app logs", comment: "Cache location name on the Caches screen"), section: .containers, relativePath: "Library/Logs/OrbStack",
                      safety: .safe, badge: "orb", colorHex: 0x8B5CF6, restoreHint: String(localized: "OrbStack writes new logs", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: ["OrbStack"]),
        // AI agents. Only what the agent rebuilds is Safe, because Safe is what auto-clean takes. Anything holding
        // history is Review. Left out on purpose: logins, settings, skills and plugins, Codex sessions (indexed in
        // SQLite, so removing the files alone leaves the index wrong) and Cursor's `state.vscdb` (its chats live inside).
        CacheLocation(id: "claude-desktop-cache", name: String(localized: "Claude app cache", comment: "Cache location name on the Caches screen"), section: .aiAgents, relativePath: "Library/Application Support/Claude/Cache",
                      safety: .safe, badge: "cl", colorHex: 0xD97757, restoreHint: String(localized: "Claude rebuilds it", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: claudeDesktopProcesses),
        CacheLocation(id: "claude-desktop-code-cache", name: String(localized: "Claude app compiled code", comment: "Cache location name on the Caches screen"), section: .aiAgents, relativePath: "Library/Application Support/Claude/Code Cache",
                      safety: .safe, badge: "cl", colorHex: 0xD97757, restoreHint: String(localized: "Claude rebuilds it; the next start is a little slower", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: claudeDesktopProcesses),
        CacheLocation(id: "claude-desktop-gpu-cache", name: String(localized: "Claude app GPU cache", comment: "Cache location name on the Caches screen"), section: .aiAgents, relativePath: "Library/Application Support/Claude/GPUCache",
                      safety: .safe, badge: "cl", colorHex: 0xD97757, restoreHint: String(localized: "Claude rebuilds it", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: claudeDesktopProcesses),
        CacheLocation(id: "claude-desktop-caches", name: String(localized: "Claude app system cache", comment: "Cache location name on the Caches screen"), section: .aiAgents, relativePath: "Library/Caches/com.anthropic.claudefordesktop",
                      safety: .safe, badge: "cl", colorHex: 0xD97757, restoreHint: String(localized: "Claude rebuilds it", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: claudeDesktopProcesses),
        CacheLocation(id: "claude-desktop-logs", name: String(localized: "Claude app logs", comment: "Cache location name on the Caches screen"), section: .aiAgents, relativePath: "Library/Logs/Claude",
                      safety: .safe, badge: "cl", colorHex: 0xD97757, restoreHint: String(localized: "Claude writes new logs", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: claudeDesktopProcesses),
        CacheLocation(id: "claude-cowork-vm", name: String(localized: "Claude Cowork virtual machine", comment: "Cache location name on the Caches screen"), section: .aiAgents, relativePath: "Library/Application Support/Claude/vm_bundles",
                      safety: .review, badge: "cl", colorHex: 0xD97757,
                      restoreHint: String(localized: "Cowork downloads it again on next use, and whatever its sessions kept inside the VM is lost", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"),
                      breakdown: .none, usedByApps: claudeDesktopProcesses),
        CacheLocation(id: "claude-code-mcp-logs", name: String(localized: "Claude Code MCP logs", comment: "Cache location name on the Caches screen"), section: .aiAgents, relativePath: "Library/Caches/claude-cli-nodejs",
                      safety: .safe, badge: "cc", colorHex: 0xD97757, restoreHint: String(localized: "Claude Code writes new logs", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: claudeCodeProcesses),
        CacheLocation(id: "claude-code-debug", name: String(localized: "Claude Code debug logs", comment: "Cache location name on the Caches screen"), section: .aiAgents, relativePath: ".claude/debug",
                      safety: .safe, badge: "cc", colorHex: 0xD97757, restoreHint: String(localized: "Claude Code writes new logs", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: claudeCodeProcesses),
        CacheLocation(id: "claude-code-paste-cache", name: String(localized: "Claude Code pasted text", comment: "Cache location name on the Caches screen"), section: .aiAgents, relativePath: ".claude/paste-cache",
                      safety: .review, badge: "cc", colorHex: 0xD97757, restoreHint: String(localized: "pasted text is lost from prompts you recall later", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"),
                      breakdown: .none, usedByApps: claudeCodeProcesses),
        CacheLocation(id: "claude-code-file-history", name: String(localized: "Claude Code checkpoints", comment: "Cache location name on the Caches screen"), section: .aiAgents, relativePath: ".claude/file-history",
                      safety: .review, badge: "cc", colorHex: 0xD97757, restoreHint: String(localized: "past sessions can no longer be rewound to a checkpoint", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"),
                      breakdown: .none, usedByApps: claudeCodeProcesses),
        CacheLocation(id: "claude-code-transcripts", name: String(localized: "Claude Code transcripts", comment: "Cache location name on the Caches screen"), section: .aiAgents, relativePath: ".claude/projects",
                      safety: .review, badge: "cc", colorHex: 0xD97757, restoreHint: String(localized: "these sessions can't be resumed; project memory is kept", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"),
                      breakdown: .claudeProjects, usedByApps: claudeCodeProcesses),
        CacheLocation(id: "codex-cache", name: String(localized: "Codex cache", comment: "Cache location name on the Caches screen"), section: .aiAgents, relativePath: ".codex/cache",
                      safety: .safe, badge: "cx", colorHex: 0x10A37F, restoreHint: String(localized: "Codex fetches it again", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: codexProcesses),
        CacheLocation(id: "codex-logs", name: String(localized: "Codex logs", comment: "Cache location name on the Caches screen"), section: .aiAgents, relativePath: ".codex/log",
                      safety: .safe, badge: "cx", colorHex: 0x10A37F, restoreHint: String(localized: "Codex writes new logs", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: codexProcesses),
        CacheLocation(id: "chatgpt-caches", name: String(localized: "ChatGPT app cache", comment: "Cache location name on the Caches screen"), section: .aiAgents, relativePath: "Library/Caches/com.openai.chat",
                      safety: .safe, badge: "gpt", colorHex: 0x10A37F, restoreHint: String(localized: "ChatGPT rebuilds it", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: ["ChatGPT"]),
        CacheLocation(id: "grok-logs", name: String(localized: "Grok logs", comment: "Cache location name on the Caches screen"), section: .aiAgents, relativePath: ".grok/logs",
                      safety: .safe, badge: "gk", colorHex: 0xE6E8EE, restoreHint: String(localized: "Grok writes new logs", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: grokProcesses),
        CacheLocation(id: "grok-marketplace-cache", name: String(localized: "Grok plugin catalog", comment: "Cache location name on the Caches screen"), section: .aiAgents, relativePath: ".grok/marketplace-cache",
                      safety: .redownload, badge: "gk", colorHex: 0xE6E8EE, restoreHint: String(localized: "Grok downloads the catalog again; installed plugins are kept", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: grokProcesses),
        CacheLocation(id: "grok-downloads", name: String(localized: "Old Grok versions", comment: "Cache location name on the Caches screen"), section: .aiAgents, relativePath: ".grok/downloads",
                      safety: .redownload, badge: "gk", colorHex: 0xE6E8EE, restoreHint: String(localized: "the installed version is kept; older ones aren't needed to run Grok", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"),
                      breakdown: .unlinkedDownloads, usedByApps: grokProcesses),
        CacheLocation(id: "grok-sessions", name: String(localized: "Grok sessions", comment: "Cache location name on the Caches screen"), section: .aiAgents, relativePath: ".grok/sessions",
                      safety: .review, badge: "gk", colorHex: 0xE6E8EE, restoreHint: String(localized: "these sessions can't be resumed; Grok never removes them itself", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"),
                      breakdown: .encodedProjects, usedByApps: grokProcesses),
        CacheLocation(id: "gemini-sessions", name: String(localized: "Gemini CLI sessions", comment: "Cache location name on the Caches screen"), section: .aiAgents, relativePath: ".gemini/tmp",
                      safety: .review, badge: "gm", colorHex: 0x4285F4, restoreHint: String(localized: "these sessions can't be resumed; Gemini CLI removes old ones after 30 days by default", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"),
                      usedByApps: geminiProcesses),
        CacheLocation(id: "copilot-logs", name: String(localized: "Copilot CLI logs", comment: "Cache location name on the Caches screen"), section: .aiAgents, relativePath: ".copilot/logs",
                      safety: .safe, badge: "co", colorHex: 0x8B5CF6, restoreHint: String(localized: "Copilot CLI writes new logs", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: copilotProcesses),
        CacheLocation(id: "copilot-sessions", name: String(localized: "Copilot CLI sessions", comment: "Cache location name on the Caches screen"), section: .aiAgents, relativePath: ".copilot/session-state",
                      safety: .review, badge: "co", colorHex: 0x8B5CF6, restoreHint: String(localized: "these sessions can't be resumed", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: copilotProcesses),
        CacheLocation(id: "opencode-logs", name: String(localized: "OpenCode logs", comment: "Cache location name on the Caches screen"), section: .aiAgents, relativePath: ".local/share/opencode/log",
                      safety: .safe, badge: "oc", colorHex: 0xE6E8EE, restoreHint: String(localized: "OpenCode writes new logs", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), usedByApps: ["opencode"]),
        // AI models (opt-in: unchecked by default)
        CacheLocation(id: "ollama", name: String(localized: "Ollama models", comment: "Cache location name on the Caches screen"), section: .aiModels, relativePath: ".ollama/models",
                      safety: .review, badge: "ol", colorHex: 0xE6E8EE, restoreHint: String(localized: "`ollama pull` downloads models again", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), breakdown: .none),
        CacheLocation(id: "huggingface", name: String(localized: "Hugging Face cache", comment: "Cache location name on the Caches screen"), section: .aiModels, relativePath: ".cache/huggingface/hub",
                      safety: .redownload, badge: "hf", colorHex: 0xFACC15, restoreHint: String(localized: "models are downloaded again on next use", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back"), breakdown: .huggingface),
        CacheLocation(id: "huggingface-datasets", name: String(localized: "Hugging Face datasets", comment: "Cache location name on the Caches screen"), section: .aiModels, relativePath: ".cache/huggingface/datasets",
                      safety: .redownload, badge: "hf", colorHex: 0xFACC15, restoreHint: String(localized: "datasets are downloaded again on next use", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "huggingface-xet", name: String(localized: "Hugging Face Xet cache", comment: "Cache location name on the Caches screen"), section: .aiModels, relativePath: ".cache/huggingface/xet",
                      safety: .redownload, badge: "hf", colorHex: 0xFACC15, restoreHint: String(localized: "files are downloaded again on next use", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "ollama-logs", name: String(localized: "Ollama logs", comment: "Cache location name on the Caches screen"), section: .aiModels, relativePath: ".ollama/logs",
                      safety: .safe, badge: "ol", colorHex: 0xE6E8EE, restoreHint: String(localized: "Ollama writes new logs", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "lmstudio-logs", name: String(localized: "LM Studio server logs", comment: "Cache location name on the Caches screen"), section: .aiModels, relativePath: ".lmstudio/server-logs",
                      safety: .safe, badge: "lm", colorHex: 0xA78BFA, restoreHint: String(localized: "LM Studio writes new logs", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "lmstudio", name: String(localized: "LM Studio models", comment: "Cache location name on the Caches screen"), section: .aiModels, relativePath: ".lmstudio/models",
                      safety: .review, badge: "lm", colorHex: 0xA78BFA, restoreHint: String(localized: "download models again in LM Studio", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        // Browsers
        CacheLocation(id: "chrome", name: "Chrome", section: .browsers, relativePath: "Library/Caches/Google/Chrome",
                      safety: .safe, badge: "ch", colorHex: 0x34D399, restoreHint: String(localized: "the browser rebuilds it", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "arc", name: "Arc", section: .browsers, relativePath: "Library/Caches/company.thebrowser.Browser",
                      safety: .safe, badge: "ar", colorHex: 0xF472B6, restoreHint: String(localized: "the browser rebuilds it", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "brave", name: "Brave", section: .browsers, relativePath: "Library/Caches/BraveSoftware",
                      safety: .safe, badge: "bv", colorHex: 0xF97316, restoreHint: String(localized: "the browser rebuilds it", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "firefox", name: "Firefox", section: .browsers, relativePath: "Library/Caches/Firefox",
                      safety: .safe, badge: "ff", colorHex: 0xF97316, restoreHint: String(localized: "the browser rebuilds it", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
        CacheLocation(id: "edge", name: "Edge", section: .browsers, relativePath: "Library/Caches/Microsoft Edge",
                      safety: .safe, badge: "ed", colorHex: 0x22D3EE, restoreHint: String(localized: "the browser rebuilds it", comment: "Shown for a cache location: what happens after it is cleaned, or how to get it back")),
    ]
}
