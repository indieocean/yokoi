import Foundation

/// A known cache location (PRD §5.4). Cleaning removes the folder's *contents*, never the folder itself.
struct CacheLocation: Sendable, Identifiable, Hashable {
    enum Section: String, Sendable, CaseIterable, Codable {
        case systemUser = "System & User"
        case javascript = "JavaScript"
        case nativeToolchains = "Native toolchains"
        case xcode = "Xcode"
        case android = "Android"
        case aiModels = "AI models"
        /// No longer used: installers in Downloads moved to the Downloads screen. Kept so older scan caches decode.
        case downloads = "Downloads"
        case browsers = "Browsers"
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

    func url(home: URL) -> URL { home.appendingPathComponent(relativePath) }

    /// Locations a running process may be using (emulators keep their AVD open). Cleanup is refused while
    /// a process holds a file inside them, like an open project.
    static let inUseGuarded: Set<String> = ["android-avd", "android-system-images"]
}

extension CacheLocation {
    static let all: [CacheLocation] = [
        // System & User
        CacheLocation(id: "user-caches", name: "User caches", section: .systemUser, relativePath: "Library/Caches",
                      safety: .safe, badge: "◎", colorHex: 0x7D8597, restoreHint: "apps rebuild their caches automatically",
                      keepChildren: ["com.apple.*", "com.yokoi.*", "com.diskkeeper.*", "CloudKit", "FamilyCircle"], excludesNestedLocations: true),
        CacheLocation(id: "trash", name: "Trash", section: .systemUser, relativePath: ".Trash",
                      safety: .review, badge: "🗑", colorHex: 0xF0565E, restoreHint: "emptying the Trash can't be undone",
                      permanentOnly: true),
        CacheLocation(id: "logs", name: "Logs", section: .systemUser, relativePath: "Library/Logs",
                      safety: .safe, badge: "◎", colorHex: 0x7D8597, restoreHint: "logs are recreated as needed"),
        // JavaScript
        CacheLocation(id: "npm", name: "npm cache", section: .javascript, relativePath: ".npm/_cacache",
                      safety: .safe, badge: "npm", colorHex: 0xF87171, restoreHint: "npm refills it on the next install"),
        CacheLocation(id: "pnpm", name: "pnpm store", section: .javascript, relativePath: "Library/pnpm/store",
                      safety: .redownload, badge: "pn", colorHex: 0xF59E0B, restoreHint: "pnpm re-downloads packages on the next install"),
        CacheLocation(id: "yarn", name: "Yarn cache", section: .javascript, relativePath: "Library/Caches/Yarn",
                      safety: .safe, badge: "y", colorHex: 0x60A5FA, restoreHint: "yarn refills it on the next install"),
        CacheLocation(id: "bun", name: "Bun cache", section: .javascript, relativePath: ".bun/install/cache",
                      safety: .safe, badge: "bun", colorHex: 0xE6E8EE, restoreHint: "bun refills it on the next install"),
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
        CacheLocation(id: "pip", name: "pip", section: .nativeToolchains, relativePath: "Library/Caches/pip",
                      safety: .safe, badge: "pip", colorHex: 0xFACC15, restoreHint: "pip refills it on the next install"),
        // Xcode
        CacheLocation(id: "xcode-cache", name: "Xcode caches", section: .xcode, relativePath: "Library/Caches/com.apple.dt.Xcode",
                      safety: .safe, badge: "xc", colorHex: 0x60A5FA, restoreHint: "Xcode rebuilds it"),
        CacheLocation(id: "simulator-caches", name: "Simulator caches", section: .xcode, relativePath: "Library/Developer/CoreSimulator/Caches",
                      safety: .safe, badge: "sim", colorHex: 0x60A5FA, restoreHint: "the Simulator rebuilds it"),
        CacheLocation(id: "simulator-devices", name: "iOS Simulators (devices)", section: .xcode, relativePath: "Library/Developer/CoreSimulator/Devices",
                      safety: .review, badge: "sim", colorHex: 0x60A5FA, restoreHint: "recreate simulators in Xcode › Devices (their app data is lost)",
                      keepChildren: ["device_set.plist", ".*"]),
        CacheLocation(id: "xcode-archives", name: "Archives", section: .xcode, relativePath: "Library/Developer/Xcode/Archives",
                      safety: .review, badge: "arc", colorHex: 0x60A5FA, restoreHint: "archives contain dSYMs and can't be recreated"),
        CacheLocation(id: "device-support", name: "Device support", section: .xcode, relativePath: "Library/Developer/Xcode/iOS DeviceSupport",
                      safety: .review, badge: "dev", colorHex: 0x60A5FA, restoreHint: "Xcode re-copies symbols when a device connects"),
        // Android
        CacheLocation(id: "android-avd", name: "Android emulators (AVDs)", section: .android, relativePath: ".android/avd",
                      safety: .review, badge: "avd", colorHex: 0x3DDC84, restoreHint: "recreate emulators in Android Studio › Device Manager (their app data is lost)"),
        CacheLocation(id: "android-system-images", name: "Android system images", section: .android, relativePath: "Library/Android/sdk/system-images",
                      safety: .review, badge: "img", colorHex: 0x3DDC84, restoreHint: "reinstall them in Android Studio › SDK Manager; emulators that use them won't boot until then"),
        CacheLocation(id: "android-cache", name: "Android SDK cache", section: .android, relativePath: ".android/cache",
                      safety: .safe, badge: "and", colorHex: 0x3DDC84, restoreHint: "the SDK tools rebuild it"),
        CacheLocation(id: "android-build-cache", name: "Android build cache", section: .android, relativePath: ".android/build-cache",
                      safety: .safe, badge: "and", colorHex: 0x3DDC84, restoreHint: "the Android Gradle plugin rebuilds it on the next build"),
        // AI models (opt-in: unchecked by default)
        CacheLocation(id: "ollama", name: "Ollama models", section: .aiModels, relativePath: ".ollama/models",
                      safety: .review, badge: "ol", colorHex: 0xE6E8EE, restoreHint: "`ollama pull` downloads models again"),
        CacheLocation(id: "huggingface", name: "Hugging Face cache", section: .aiModels, relativePath: ".cache/huggingface/hub",
                      safety: .redownload, badge: "hf", colorHex: 0xFACC15, restoreHint: "models are downloaded again on next use"),
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
