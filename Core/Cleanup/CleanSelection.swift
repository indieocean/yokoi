import Foundation

/// What gets cleaned without anyone picking items: Smart Select, scheduled auto-clean and `yokoi clean`.
/// Kept in one place so the three can't drift apart.
enum CleanSelection {
    /// "Smart Select": stale node_modules, artifacts of inactive projects (not opt-in) and Safe caches.
    static func smart(nodeModules: [NodeModulesItem], artifacts: [ArtifactItem], caches: [CacheItem],
                      settings: SettingsData, now: Date = Date()) -> [CleanupEntry] {
        var entries: [CleanupEntry] = []
        entries += nodeModules.filter { $0.isStale(days: settings.staleDays, now: now) }.map { CleanupEntry($0) }
        entries += artifacts
            .filter { !$0.optIn }
            .map { CleanupEntry($0, displayPath: $0.displayPath) }
            .filter { !$0.isRecentlyActive(days: settings.protectRecentDays, now: now) }
        entries += safeCaches(caches)
        return entries
    }

    static func safeCaches(_ caches: [CacheItem]) -> [CleanupEntry] {
        caches.filter { $0.safety == .safe && $0.size > 0 }.map { CleanupEntry($0, displayPath: PathFormat.abbreviate($0.url)) }
    }

    /// For cleaning with nobody watching. Never includes anything that can only be deleted permanently: that's
    /// the Trash itself, and emptying it would destroy whatever the user put there.
    static func unattended(_ scope: AutoCleanScope, nodeModules: [NodeModulesItem], artifacts: [ArtifactItem],
                           caches: [CacheItem], settings: SettingsData, now: Date = Date()) -> [CleanupEntry] {
        let entries = switch scope {
        case .safeCaches: safeCaches(caches)
        case .smartSelect: smart(nodeModules: nodeModules, artifacts: artifacts, caches: caches, settings: settings, now: now)
        }
        return entries.filter { !$0.permanentOnly }
    }
}
