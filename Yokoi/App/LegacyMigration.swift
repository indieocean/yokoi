import Foundation

/// One-time move from the app's old name (Disk Keeper, `com.diskkeeper.DiskKeeper`) to Yokoi.
/// Carries over settings, the cleanup log and the last scan. Safe to run on every launch.
enum LegacyMigration {
    static let oldBundleID = "com.diskkeeper.DiskKeeper"
    static let settingsKey = "settings.v1"

    static func run() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent("DiskKeeper")
        let new = support.appendingPathComponent("Yokoi")
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
            try? fm.moveItem(at: old, to: new)
        }

        let defaults = UserDefaults.standard
        if defaults.data(forKey: settingsKey) == nil,
           let oldDefaults = UserDefaults(suiteName: oldBundleID),
           let data = oldDefaults.data(forKey: settingsKey) {
            defaults.set(data, forKey: settingsKey)
        }
    }
}
