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
        CacheLocation(id: "user-caches", name: "User caches", section: .systemUser, relativePath: "Library/Caches",
                      safety: .safe, badge: "◎", colorHex: 0x7D8597, restoreHint: "apps rebuild their caches automatically",
                      keepChildren: ["com.apple.*", "com.yokoi.*", "com.diskkeeper.*", "CloudKit", "FamilyCircle"], excludesNestedLocations: true),
        CacheLocation(id: "trash", name: "Trash", section: .trash, relativePath: ".Trash",
                      safety: .review, badge: "🗑", colorHex: 0xF0565E, restoreHint: "emptying the Trash can't be undone",
                      permanentOnly: true, breakdown: .none),
        CacheLocation(id: "logs", name: "Logs", section: .systemUser, relativePath: "Library/Logs",
                      safety: .safe, badge: "◎", colorHex: 0x7D8597, restoreHint: "logs are recreated as needed", excludesNestedLocations: true),
        // JavaScript
        CacheLocation(id: "npm", name: "npm cache", section: .javascript, relativePath: ".npm/_cacache",
                      safety: .safe, badge: "npm", colorHex: 0xF87171, restoreHint: "npm refills it on the next install", breakdown: .none),
        CacheLocation(id: "pnpm", name: "pnpm store", section: .javascript, relativePath: "Library/pnpm/store",
                      safety: .redownload, badge: "pn", colorHex: 0xF59E0B, restoreHint: "pnpm re-downloads packages on the next install", breakdown: .none),
        CacheLocation(id: "yarn", name: "Yarn cache", section: .javascript, relativePath: "Library/Caches/Yarn",
                      safety: .safe, badge: "y", colorHex: 0x60A5FA, restoreHint: "yarn refills it on the next install"),
        CacheLocation(id: "bun", name: "Bun cache", section: .javascript, relativePath: ".bun/install/cache",
                      safety: .safe, badge: "bun", colorHex: 0xE6E8EE, restoreHint: "bun refills it on the next install", breakdown: .none),
        CacheLocation(id: "npm-logs", name: "npm logs", section: .javascript, relativePath: ".npm/_logs",
                      safety: .safe, badge: "npm", colorHex: 0xF87171, restoreHint: "npm writes new logs as it runs", breakdown: .none),
        CacheLocation(id: "yarn-xdg", name: "Yarn cache (~/.cache)", section: .javascript, relativePath: ".cache/yarn",
                      safety: .safe, badge: "y", colorHex: 0x60A5FA, restoreHint: "yarn refills it on the next install"),
        CacheLocation(id: "yarn-berry", name: "Yarn Berry global cache", section: .javascript, relativePath: ".yarn/berry/cache",
                      safety: .redownload, badge: "y", colorHex: 0x60A5FA, restoreHint: "Yarn re-downloads packages on the next install", breakdown: .none),
        CacheLocation(id: "pnpm-legacy", name: "pnpm store (~/.pnpm-store)", section: .javascript, relativePath: ".pnpm-store",
                      safety: .redownload, badge: "pn", colorHex: 0xF59E0B, restoreHint: "pnpm re-downloads packages on the next install", breakdown: .none),
        CacheLocation(id: "pnpm-xdg", name: "pnpm store (~/.local/share)", section: .javascript, relativePath: ".local/share/pnpm/store",
                      safety: .redownload, badge: "pn", colorHex: 0xF59E0B, restoreHint: "pnpm re-downloads packages on the next install", breakdown: .none),
        CacheLocation(id: "pnpm-metadata", name: "pnpm metadata cache", section: .javascript, relativePath: ".cache/pnpm",
                      safety: .safe, badge: "pn", colorHex: 0xF59E0B, restoreHint: "pnpm fetches package metadata again"),
        CacheLocation(id: "deno", name: "Deno cache", section: .javascript, relativePath: "Library/Caches/deno",
                      safety: .redownload, badge: "dn", colorHex: 0xE6E8EE, restoreHint: "Deno re-downloads modules on the next run"),
        CacheLocation(id: "deno-xdg", name: "Deno cache (~/.cache)", section: .javascript, relativePath: ".cache/deno",
                      safety: .redownload, badge: "dn", colorHex: 0xE6E8EE, restoreHint: "Deno re-downloads modules on the next run"),
        CacheLocation(id: "node-gyp", name: "node-gyp headers", section: .javascript, relativePath: "Library/Caches/node-gyp",
                      safety: .safe, badge: "gyp", colorHex: 0x34D399, restoreHint: "node-gyp downloads Node headers again for the next native build"),
        CacheLocation(id: "node-gyp-xdg", name: "node-gyp headers (~/.cache)", section: .javascript, relativePath: ".cache/node-gyp",
                      safety: .safe, badge: "gyp", colorHex: 0x34D399, restoreHint: "node-gyp downloads Node headers again for the next native build"),
        CacheLocation(id: "electron", name: "Electron downloads", section: .javascript, relativePath: "Library/Caches/electron",
                      safety: .redownload, badge: "el", colorHex: 0x9FEAF9, restoreHint: "Electron is downloaded again on the next install"),
        CacheLocation(id: "electron-builder", name: "electron-builder downloads", section: .javascript, relativePath: "Library/Caches/electron-builder",
                      safety: .redownload, badge: "el", colorHex: 0x9FEAF9, restoreHint: "electron-builder downloads its tools again on the next build"),
        CacheLocation(id: "puppeteer", name: "Puppeteer browsers", section: .javascript, relativePath: ".cache/puppeteer",
                      safety: .redownload, badge: "pup", colorHex: 0x34D399, restoreHint: "`npx puppeteer browsers install` downloads them again"),
        CacheLocation(id: "playwright", name: "Playwright browsers", section: .javascript, relativePath: "Library/Caches/ms-playwright",
                      safety: .redownload, badge: "pw", colorHex: 0x34D399, restoreHint: "`npx playwright install` downloads them again"),
        CacheLocation(id: "playwright-xdg", name: "Playwright browsers (~/.cache)", section: .javascript, relativePath: ".cache/ms-playwright",
                      safety: .redownload, badge: "pw", colorHex: 0x34D399, restoreHint: "`npx playwright install` downloads them again"),
        // Python
        CacheLocation(id: "pip-xdg", name: "pip (~/.cache)", section: .python, relativePath: ".cache/pip",
                      safety: .safe, badge: "pip", colorHex: 0xFACC15, restoreHint: "pip refills it on the next install"),
        CacheLocation(id: "uv", name: "uv cache", section: .python, relativePath: ".cache/uv",
                      safety: .redownload, badge: "uv", colorHex: 0xDE5FE9, restoreHint: "uv re-downloads packages on the next sync; existing environments keep working", breakdown: .none),
        CacheLocation(id: "uv-library", name: "uv cache (Library)", section: .python, relativePath: "Library/Caches/uv",
                      safety: .redownload, badge: "uv", colorHex: 0xDE5FE9, restoreHint: "uv re-downloads packages on the next sync; existing environments keep working", breakdown: .none),
        // Poetry keeps its virtualenvs inside its cache folder on macOS: those are never touched.
        CacheLocation(id: "poetry", name: "Poetry cache", section: .python, relativePath: "Library/Caches/pypoetry",
                      safety: .redownload, badge: "po", colorHex: 0x60A5FA, restoreHint: "Poetry re-downloads packages on the next install",
                      keepChildren: ["virtualenvs"]),
        CacheLocation(id: "poetry-xdg", name: "Poetry cache (~/.cache)", section: .python, relativePath: ".cache/pypoetry",
                      safety: .redownload, badge: "po", colorHex: 0x60A5FA, restoreHint: "Poetry re-downloads packages on the next install",
                      keepChildren: ["virtualenvs"]),
        // Native toolchains
        CacheLocation(id: "homebrew", name: "Homebrew downloads", section: .nativeToolchains, relativePath: "Library/Caches/Homebrew",
                      safety: .safe, badge: "br", colorHex: 0xF59E0B, restoreHint: "brew downloads bottles again when needed"),
        CacheLocation(id: "cargo-registry", name: "Cargo registry", section: .nativeToolchains, relativePath: ".cargo/registry",
                      safety: .redownload, badge: "cg", colorHex: 0xF97316, restoreHint: "cargo re-downloads crates on the next build"),
        CacheLocation(id: "gradle-caches", name: "Gradle caches", section: .nativeToolchains, relativePath: ".gradle/caches",
                      safety: .redownload, badge: "gr", colorHex: 0x34D399, restoreHint: "Gradle re-downloads dependencies on the next build"),
        CacheLocation(id: "gradle-wrapper", name: "Gradle wrapper distributions", section: .nativeToolchains, relativePath: ".gradle/wrapper/dists",
                      safety: .redownload, badge: "gr", colorHex: 0x34D399, restoreHint: "./gradlew downloads its distribution again on the next build"),
        CacheLocation(id: "cocoapods", name: "CocoaPods", section: .nativeToolchains, relativePath: "Library/Caches/CocoaPods",
                      safety: .safe, badge: "pod", colorHex: 0xF87171, restoreHint: "pod install refills it"),
        CacheLocation(id: "pip", name: "pip", section: .python, relativePath: "Library/Caches/pip",
                      safety: .safe, badge: "pip", colorHex: 0xFACC15, restoreHint: "pip refills it on the next install"),
        CacheLocation(id: "cargo-git", name: "Cargo git dependencies", section: .nativeToolchains, relativePath: ".cargo/git",
                      safety: .redownload, badge: "cg", colorHex: 0xF97316, restoreHint: "cargo clones git dependencies again on the next build"),
        CacheLocation(id: "gradle-daemon", name: "Gradle daemon logs", section: .nativeToolchains, relativePath: ".gradle/daemon",
                      safety: .safe, badge: "gr", colorHex: 0x34D399, restoreHint: "Gradle starts a fresh daemon and log on the next build"),
        CacheLocation(id: "maven", name: "Maven repository", section: .nativeToolchains, relativePath: ".m2/repository",
                      safety: .review, badge: "mvn", colorHex: 0xF87171,
                      restoreHint: "Maven re-downloads dependencies; anything you `mvn install`ed locally is lost"),
        CacheLocation(id: "swiftpm", name: "Swift Package Manager cache", section: .nativeToolchains, relativePath: "Library/Caches/org.swift.swiftpm",
                      safety: .redownload, badge: "spm", colorHex: 0xF05138, restoreHint: "SwiftPM re-downloads packages on the next resolve"),
        // Activated global tools live in bin/ and global_packages/, so they stay.
        CacheLocation(id: "pub-cache", name: "Flutter / Dart pub cache", section: .nativeToolchains, relativePath: ".pub-cache",
                      safety: .redownload, badge: "dt", colorHex: 0x22D3EE, restoreHint: "`flutter pub get` downloads packages again",
                      keepChildren: ["bin", "global_packages"]),
        CacheLocation(id: "nuget-packages", name: "NuGet packages", section: .nativeToolchains, relativePath: ".nuget/packages",
                      safety: .review, badge: "nu", colorHex: 0xA78BFA,
                      restoreHint: "`dotnet restore` downloads them again; packages only added from a local folder are lost"),
        CacheLocation(id: "nuget-http", name: "NuGet HTTP cache", section: .nativeToolchains, relativePath: ".local/share/NuGet/http-cache",
                      safety: .safe, badge: "nu", colorHex: 0xA78BFA, restoreHint: "NuGet refills it on the next restore"),
        CacheLocation(id: "nuget-v3", name: "NuGet v3 cache", section: .nativeToolchains, relativePath: ".local/share/NuGet/v3-cache",
                      safety: .safe, badge: "nu", colorHex: 0xA78BFA, restoreHint: "NuGet refills it on the next restore"),
        CacheLocation(id: "mise", name: "mise cache", section: .nativeToolchains, relativePath: ".cache/mise",
                      safety: .safe, badge: "mi", colorHex: 0xE6E8EE, restoreHint: "mise refills it as needed; installed tools are kept"),
        // Xcode
        CacheLocation(id: "xcode-cache", name: "Xcode caches", section: .xcode, relativePath: "Library/Caches/com.apple.dt.Xcode",
                      safety: .safe, badge: "xc", colorHex: 0x60A5FA, restoreHint: "Xcode rebuilds it"),
        CacheLocation(id: "simulator-caches", name: "Simulator caches", section: .xcode, relativePath: "Library/Developer/CoreSimulator/Caches",
                      safety: .safe, badge: "sim", colorHex: 0x60A5FA, restoreHint: "the Simulator rebuilds it"),
        CacheLocation(id: "simulator-devices", name: "iOS Simulators (devices)", section: .xcode, relativePath: "Library/Developer/CoreSimulator/Devices",
                      safety: .review, badge: "sim", colorHex: 0x60A5FA, restoreHint: "recreate simulators in Xcode › Devices (their app data is lost)",
                      keepChildren: ["device_set.plist", ".*"], breakdown: .simulators),
        CacheLocation(id: "xcode-archives", name: "Archives", section: .xcode, relativePath: "Library/Developer/Xcode/Archives",
                      safety: .review, badge: "arc", colorHex: 0x60A5FA, restoreHint: "archives contain dSYMs and can't be recreated", breakdown: .archives),
        CacheLocation(id: "device-support", name: "Device support", section: .xcode, relativePath: "Library/Developer/Xcode/iOS DeviceSupport",
                      safety: .review, badge: "dev", colorHex: 0x60A5FA, restoreHint: "Xcode re-copies symbols when a device connects", breakdown: .deviceSupport),
        CacheLocation(id: "watch-device-support", name: "watchOS device support", section: .xcode, relativePath: "Library/Developer/Xcode/watchOS DeviceSupport",
                      safety: .review, badge: "dev", colorHex: 0x60A5FA, restoreHint: "Xcode re-copies symbols when a watch connects", breakdown: .deviceSupport),
        CacheLocation(id: "tv-device-support", name: "tvOS device support", section: .xcode, relativePath: "Library/Developer/Xcode/tvOS DeviceSupport",
                      safety: .review, badge: "dev", colorHex: 0x60A5FA, restoreHint: "Xcode re-copies symbols when an Apple TV connects", breakdown: .deviceSupport),
        CacheLocation(id: "xctest-devices", name: "Test simulator clones", section: .xcode, relativePath: "Library/Developer/XCTestDevices",
                      safety: .safe, badge: "sim", colorHex: 0x60A5FA, restoreHint: "Xcode clones simulators again for parallel testing", breakdown: .simulators),
        CacheLocation(id: "xcode-previews", name: "SwiftUI Previews", section: .xcode, relativePath: "Library/Developer/Xcode/UserData/Previews",
                      safety: .safe, badge: "pv", colorHex: 0x60A5FA, restoreHint: "Xcode rebuilds previews when you open them"),
        CacheLocation(id: "xcodebuildmcp-deriveddata", name: "XcodeBuildMCP DerivedData", section: .xcode, relativePath: "Library/Developer/XcodeBuildMCP/DerivedData",
                      safety: .safe, badge: "mcp", colorHex: 0x60A5FA, restoreHint: "the next agent build rebuilds it"),
        CacheLocation(id: "xcodebuildmcp-workspaces", name: "XcodeBuildMCP workspace builds", section: .xcode, relativePath: "Library/Developer/XcodeBuildMCP/workspaces",
                      safety: .safe, badge: "mcp", colorHex: 0x60A5FA, restoreHint: "the next agent build rebuilds it", breakdown: .workspaceDerivedData),
        CacheLocation(id: "mobilebuildmcp-deriveddata", name: "MobileBuildMCP DerivedData", section: .xcode, relativePath: "Library/Developer/MobileBuildMCP/DerivedData",
                      safety: .safe, badge: "mcp", colorHex: 0x60A5FA, restoreHint: "the next agent build rebuilds it"),
        CacheLocation(id: "mobilebuildmcp-workspaces", name: "MobileBuildMCP workspace builds", section: .xcode, relativePath: "Library/Developer/MobileBuildMCP/workspaces",
                      safety: .safe, badge: "mcp", colorHex: 0x60A5FA, restoreHint: "the next agent build rebuilds it", breakdown: .workspaceDerivedData),
        // Android
        CacheLocation(id: "android-avd", name: "Android emulators (AVDs)", section: .android, relativePath: ".android/avd",
                      safety: .review, badge: "avd", colorHex: 0x3DDC84, restoreHint: "recreate emulators in Android Studio › Device Manager (their app data is lost)", breakdown: .avds),
        CacheLocation(id: "android-system-images", name: "Android system images", section: .android, relativePath: "Library/Android/sdk/system-images",
                      safety: .review, badge: "img", colorHex: 0x3DDC84, restoreHint: "reinstall them in Android Studio › SDK Manager; emulators that use them won't boot until then", breakdown: .systemImages),
        CacheLocation(id: "android-cache", name: "Android SDK cache", section: .android, relativePath: ".android/cache",
                      safety: .safe, badge: "and", colorHex: 0x3DDC84, restoreHint: "the SDK tools rebuild it"),
        CacheLocation(id: "android-build-cache", name: "Android build cache", section: .android, relativePath: ".android/build-cache",
                      safety: .safe, badge: "and", colorHex: 0x3DDC84, restoreHint: "the Android Gradle plugin rebuilds it on the next build"),
        // Editors & IDEs: refused while the editor is open.
        CacheLocation(id: "vscode-cache", name: "VS Code cache", section: .editors, relativePath: "Library/Application Support/Code/Cache",
                      safety: .safe, badge: "vs", colorHex: 0x3B82F6, restoreHint: "VS Code rebuilds it", usedByApps: ["Visual Studio Code"]),
        CacheLocation(id: "vscode-cached-data", name: "VS Code compiled code", section: .editors, relativePath: "Library/Application Support/Code/CachedData",
                      safety: .safe, badge: "vs", colorHex: 0x3B82F6, restoreHint: "VS Code rebuilds it; the next start is a little slower", usedByApps: ["Visual Studio Code"]),
        CacheLocation(id: "vscode-vsix", name: "VS Code extension downloads", section: .editors, relativePath: "Library/Application Support/Code/CachedExtensionVSIXs",
                      safety: .safe, badge: "vs", colorHex: 0x3B82F6, restoreHint: "installed extensions are kept; VS Code downloads updates again", usedByApps: ["Visual Studio Code"]),
        CacheLocation(id: "vscode-logs", name: "VS Code logs", section: .editors, relativePath: "Library/Application Support/Code/logs",
                      safety: .safe, badge: "vs", colorHex: 0x3B82F6, restoreHint: "VS Code writes new logs", usedByApps: ["Visual Studio Code"]),
        CacheLocation(id: "cursor-cache", name: "Cursor cache", section: .editors, relativePath: "Library/Application Support/Cursor/Cache",
                      safety: .safe, badge: "cu", colorHex: 0xE6E8EE, restoreHint: "Cursor rebuilds it", usedByApps: ["Cursor"]),
        CacheLocation(id: "cursor-cached-data", name: "Cursor compiled code", section: .editors, relativePath: "Library/Application Support/Cursor/CachedData",
                      safety: .safe, badge: "cu", colorHex: 0xE6E8EE, restoreHint: "Cursor rebuilds it; the next start is a little slower", usedByApps: ["Cursor"]),
        CacheLocation(id: "cursor-logs", name: "Cursor logs", section: .editors, relativePath: "Library/Application Support/Cursor/logs",
                      safety: .safe, badge: "cu", colorHex: 0xE6E8EE, restoreHint: "Cursor writes new logs", usedByApps: ["Cursor"]),
        CacheLocation(id: "windsurf-cache", name: "Windsurf cache", section: .editors, relativePath: "Library/Application Support/Windsurf/Cache",
                      safety: .safe, badge: "ws", colorHex: 0x34D399, restoreHint: "Windsurf rebuilds it", usedByApps: ["Windsurf"]),
        CacheLocation(id: "windsurf-cached-data", name: "Windsurf compiled code", section: .editors, relativePath: "Library/Application Support/Windsurf/CachedData",
                      safety: .safe, badge: "ws", colorHex: 0x34D399, restoreHint: "Windsurf rebuilds it; the next start is a little slower", usedByApps: ["Windsurf"]),
        CacheLocation(id: "windsurf-logs", name: "Windsurf logs", section: .editors, relativePath: "Library/Application Support/Windsurf/logs",
                      safety: .safe, badge: "ws", colorHex: 0x34D399, restoreHint: "Windsurf writes new logs", usedByApps: ["Windsurf"]),
        CacheLocation(id: "jetbrains-caches", name: "JetBrains caches", section: .editors, relativePath: "Library/Caches/JetBrains",
                      safety: .safe, badge: "jb", colorHex: 0xF472B6, restoreHint: "the IDE re-indexes projects on the next open", usedByApps: jetBrainsProcesses),
        CacheLocation(id: "jetbrains-logs", name: "JetBrains logs", section: .editors, relativePath: "Library/Logs/JetBrains",
                      safety: .safe, badge: "jb", colorHex: 0xF472B6, restoreHint: "the IDE writes new logs", usedByApps: jetBrainsProcesses),
        // Containers: refused while Docker Desktop or OrbStack runs.
        CacheLocation(id: "docker-desktop-cache", name: "Docker Desktop cache", section: .containers, relativePath: "Library/Containers/com.docker.docker/Data/cache",
                      safety: .safe, badge: "dk", colorHex: 0x2496ED, restoreHint: "Docker Desktop rebuilds it", usedByApps: ["Docker"]),
        CacheLocation(id: "docker-desktop-logs", name: "Docker Desktop logs", section: .containers, relativePath: "Library/Containers/com.docker.docker/Data/log",
                      safety: .safe, badge: "dk", colorHex: 0x2496ED, restoreHint: "Docker Desktop writes new logs", usedByApps: ["Docker"]),
        CacheLocation(id: "docker-desktop-tmp", name: "Docker Desktop temporary files", section: .containers, relativePath: "Library/Containers/com.docker.docker/Data/tmp",
                      safety: .safe, badge: "dk", colorHex: 0x2496ED, restoreHint: "Docker Desktop recreates what it needs", usedByApps: ["Docker"]),
        CacheLocation(id: "docker-group-caches", name: "Docker shared caches", section: .containers, relativePath: "Library/Group Containers/group.com.docker/Caches",
                      safety: .safe, badge: "dk", colorHex: 0x2496ED, restoreHint: "Docker Desktop rebuilds it", usedByApps: ["Docker"]),
        CacheLocation(id: "docker-cli-plugins", name: "Docker CLI plugin cache", section: .containers, relativePath: ".docker/cli-plugins/.cache",
                      safety: .safe, badge: "dk", colorHex: 0x2496ED, restoreHint: "the Docker CLI refills it"),
        CacheLocation(id: "docker-buildx", name: "Docker buildx cache", section: .containers, relativePath: ".docker/buildx/cache",
                      safety: .redownload, badge: "bk", colorHex: 0x2496ED, restoreHint: "the next `docker buildx build` is slower while it refills"),
        CacheLocation(id: "orbstack-logs", name: "OrbStack logs", section: .containers, relativePath: ".orbstack/log",
                      safety: .safe, badge: "orb", colorHex: 0x8B5CF6, restoreHint: "OrbStack writes new logs", usedByApps: ["OrbStack"]),
        CacheLocation(id: "orbstack-caches", name: "OrbStack cache", section: .containers, relativePath: "Library/Caches/dev.kdrag0n.MacVirt",
                      safety: .safe, badge: "orb", colorHex: 0x8B5CF6, restoreHint: "OrbStack rebuilds it", usedByApps: ["OrbStack"]),
        CacheLocation(id: "orbstack-app-logs", name: "OrbStack app logs", section: .containers, relativePath: "Library/Logs/OrbStack",
                      safety: .safe, badge: "orb", colorHex: 0x8B5CF6, restoreHint: "OrbStack writes new logs", usedByApps: ["OrbStack"]),
        // AI agents. Only what the agent rebuilds is Safe, because Safe is what auto-clean takes. Anything holding
        // history is Review. Left out on purpose: logins, settings, skills and plugins, Codex sessions (indexed in
        // SQLite, so removing the files alone leaves the index wrong) and Cursor's `state.vscdb` (its chats live inside).
        CacheLocation(id: "claude-desktop-cache", name: "Claude app cache", section: .aiAgents, relativePath: "Library/Application Support/Claude/Cache",
                      safety: .safe, badge: "cl", colorHex: 0xD97757, restoreHint: "Claude rebuilds it", usedByApps: claudeDesktopProcesses),
        CacheLocation(id: "claude-desktop-code-cache", name: "Claude app compiled code", section: .aiAgents, relativePath: "Library/Application Support/Claude/Code Cache",
                      safety: .safe, badge: "cl", colorHex: 0xD97757, restoreHint: "Claude rebuilds it; the next start is a little slower", usedByApps: claudeDesktopProcesses),
        CacheLocation(id: "claude-desktop-gpu-cache", name: "Claude app GPU cache", section: .aiAgents, relativePath: "Library/Application Support/Claude/GPUCache",
                      safety: .safe, badge: "cl", colorHex: 0xD97757, restoreHint: "Claude rebuilds it", usedByApps: claudeDesktopProcesses),
        CacheLocation(id: "claude-desktop-caches", name: "Claude app system cache", section: .aiAgents, relativePath: "Library/Caches/com.anthropic.claudefordesktop",
                      safety: .safe, badge: "cl", colorHex: 0xD97757, restoreHint: "Claude rebuilds it", usedByApps: claudeDesktopProcesses),
        CacheLocation(id: "claude-desktop-logs", name: "Claude app logs", section: .aiAgents, relativePath: "Library/Logs/Claude",
                      safety: .safe, badge: "cl", colorHex: 0xD97757, restoreHint: "Claude writes new logs", usedByApps: claudeDesktopProcesses),
        CacheLocation(id: "claude-cowork-vm", name: "Claude Cowork virtual machine", section: .aiAgents, relativePath: "Library/Application Support/Claude/vm_bundles",
                      safety: .review, badge: "cl", colorHex: 0xD97757,
                      restoreHint: "Cowork downloads it again on next use, and whatever its sessions kept inside the VM is lost",
                      breakdown: .none, usedByApps: claudeDesktopProcesses),
        CacheLocation(id: "claude-code-mcp-logs", name: "Claude Code MCP logs", section: .aiAgents, relativePath: "Library/Caches/claude-cli-nodejs",
                      safety: .safe, badge: "cc", colorHex: 0xD97757, restoreHint: "Claude Code writes new logs", usedByApps: claudeCodeProcesses),
        CacheLocation(id: "claude-code-debug", name: "Claude Code debug logs", section: .aiAgents, relativePath: ".claude/debug",
                      safety: .safe, badge: "cc", colorHex: 0xD97757, restoreHint: "Claude Code writes new logs", usedByApps: claudeCodeProcesses),
        CacheLocation(id: "claude-code-paste-cache", name: "Claude Code pasted text", section: .aiAgents, relativePath: ".claude/paste-cache",
                      safety: .review, badge: "cc", colorHex: 0xD97757, restoreHint: "pasted text is lost from prompts you recall later",
                      breakdown: .none, usedByApps: claudeCodeProcesses),
        CacheLocation(id: "claude-code-file-history", name: "Claude Code checkpoints", section: .aiAgents, relativePath: ".claude/file-history",
                      safety: .review, badge: "cc", colorHex: 0xD97757, restoreHint: "past sessions can no longer be rewound to a checkpoint",
                      breakdown: .none, usedByApps: claudeCodeProcesses),
        CacheLocation(id: "claude-code-transcripts", name: "Claude Code transcripts", section: .aiAgents, relativePath: ".claude/projects",
                      safety: .review, badge: "cc", colorHex: 0xD97757, restoreHint: "these sessions can't be resumed; project memory is kept",
                      breakdown: .claudeProjects, usedByApps: claudeCodeProcesses),
        CacheLocation(id: "codex-cache", name: "Codex cache", section: .aiAgents, relativePath: ".codex/cache",
                      safety: .safe, badge: "cx", colorHex: 0x10A37F, restoreHint: "Codex fetches it again", usedByApps: codexProcesses),
        CacheLocation(id: "codex-logs", name: "Codex logs", section: .aiAgents, relativePath: ".codex/log",
                      safety: .safe, badge: "cx", colorHex: 0x10A37F, restoreHint: "Codex writes new logs", usedByApps: codexProcesses),
        CacheLocation(id: "chatgpt-caches", name: "ChatGPT app cache", section: .aiAgents, relativePath: "Library/Caches/com.openai.chat",
                      safety: .safe, badge: "gpt", colorHex: 0x10A37F, restoreHint: "ChatGPT rebuilds it", usedByApps: ["ChatGPT"]),
        CacheLocation(id: "grok-logs", name: "Grok logs", section: .aiAgents, relativePath: ".grok/logs",
                      safety: .safe, badge: "gk", colorHex: 0xE6E8EE, restoreHint: "Grok writes new logs", usedByApps: grokProcesses),
        CacheLocation(id: "grok-marketplace-cache", name: "Grok plugin catalog", section: .aiAgents, relativePath: ".grok/marketplace-cache",
                      safety: .redownload, badge: "gk", colorHex: 0xE6E8EE, restoreHint: "Grok downloads the catalog again; installed plugins are kept", usedByApps: grokProcesses),
        CacheLocation(id: "grok-downloads", name: "Old Grok versions", section: .aiAgents, relativePath: ".grok/downloads",
                      safety: .redownload, badge: "gk", colorHex: 0xE6E8EE, restoreHint: "the installed version is kept; older ones aren't needed to run Grok",
                      breakdown: .unlinkedDownloads, usedByApps: grokProcesses),
        CacheLocation(id: "grok-sessions", name: "Grok sessions", section: .aiAgents, relativePath: ".grok/sessions",
                      safety: .review, badge: "gk", colorHex: 0xE6E8EE, restoreHint: "these sessions can't be resumed; Grok never removes them itself",
                      breakdown: .encodedProjects, usedByApps: grokProcesses),
        CacheLocation(id: "gemini-sessions", name: "Gemini CLI sessions", section: .aiAgents, relativePath: ".gemini/tmp",
                      safety: .review, badge: "gm", colorHex: 0x4285F4, restoreHint: "these sessions can't be resumed; Gemini CLI removes old ones after 30 days by default",
                      usedByApps: geminiProcesses),
        CacheLocation(id: "copilot-logs", name: "Copilot CLI logs", section: .aiAgents, relativePath: ".copilot/logs",
                      safety: .safe, badge: "co", colorHex: 0x8B5CF6, restoreHint: "Copilot CLI writes new logs", usedByApps: copilotProcesses),
        CacheLocation(id: "copilot-sessions", name: "Copilot CLI sessions", section: .aiAgents, relativePath: ".copilot/session-state",
                      safety: .review, badge: "co", colorHex: 0x8B5CF6, restoreHint: "these sessions can't be resumed", usedByApps: copilotProcesses),
        CacheLocation(id: "opencode-logs", name: "OpenCode logs", section: .aiAgents, relativePath: ".local/share/opencode/log",
                      safety: .safe, badge: "oc", colorHex: 0xE6E8EE, restoreHint: "OpenCode writes new logs", usedByApps: ["opencode"]),
        // AI models (opt-in: unchecked by default)
        CacheLocation(id: "ollama", name: "Ollama models", section: .aiModels, relativePath: ".ollama/models",
                      safety: .review, badge: "ol", colorHex: 0xE6E8EE, restoreHint: "`ollama pull` downloads models again", breakdown: .none),
        CacheLocation(id: "huggingface", name: "Hugging Face cache", section: .aiModels, relativePath: ".cache/huggingface/hub",
                      safety: .redownload, badge: "hf", colorHex: 0xFACC15, restoreHint: "models are downloaded again on next use", breakdown: .huggingface),
        CacheLocation(id: "huggingface-datasets", name: "Hugging Face datasets", section: .aiModels, relativePath: ".cache/huggingface/datasets",
                      safety: .redownload, badge: "hf", colorHex: 0xFACC15, restoreHint: "datasets are downloaded again on next use"),
        CacheLocation(id: "huggingface-xet", name: "Hugging Face Xet cache", section: .aiModels, relativePath: ".cache/huggingface/xet",
                      safety: .redownload, badge: "hf", colorHex: 0xFACC15, restoreHint: "files are downloaded again on next use"),
        CacheLocation(id: "ollama-logs", name: "Ollama logs", section: .aiModels, relativePath: ".ollama/logs",
                      safety: .safe, badge: "ol", colorHex: 0xE6E8EE, restoreHint: "Ollama writes new logs"),
        CacheLocation(id: "lmstudio-logs", name: "LM Studio server logs", section: .aiModels, relativePath: ".lmstudio/server-logs",
                      safety: .safe, badge: "lm", colorHex: 0xA78BFA, restoreHint: "LM Studio writes new logs"),
        CacheLocation(id: "lmstudio", name: "LM Studio models", section: .aiModels, relativePath: ".lmstudio/models",
                      safety: .review, badge: "lm", colorHex: 0xA78BFA, restoreHint: "download models again in LM Studio"),
        // Browsers
        CacheLocation(id: "chrome", name: "Chrome", section: .browsers, relativePath: "Library/Caches/Google/Chrome",
                      safety: .safe, badge: "ch", colorHex: 0x34D399, restoreHint: "the browser rebuilds it"),
        CacheLocation(id: "arc", name: "Arc", section: .browsers, relativePath: "Library/Caches/company.thebrowser.Browser",
                      safety: .safe, badge: "ar", colorHex: 0xF472B6, restoreHint: "the browser rebuilds it"),
        CacheLocation(id: "brave", name: "Brave", section: .browsers, relativePath: "Library/Caches/BraveSoftware",
                      safety: .safe, badge: "bv", colorHex: 0xF97316, restoreHint: "the browser rebuilds it"),
        CacheLocation(id: "firefox", name: "Firefox", section: .browsers, relativePath: "Library/Caches/Firefox",
                      safety: .safe, badge: "ff", colorHex: 0xF97316, restoreHint: "the browser rebuilds it"),
        CacheLocation(id: "edge", name: "Edge", section: .browsers, relativePath: "Library/Caches/Microsoft Edge",
                      safety: .safe, badge: "ed", colorHex: 0x22D3EE, restoreHint: "the browser rebuilds it"),
    ]
}
