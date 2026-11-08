import Foundation

/// Formats byte counts the way the mockups do: decimal units, about three significant digits.
/// Examples: `846 MB`, `1.42 GB`, `18.4 GB`, `153.3 GB`, `1.42 TB`.
enum ByteFormat {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    static func string(_ bytes: Int64) -> String {
        let (value, unit) = scaled(bytes)
        return "\(number(value, unit: unit)) \(units[unit])"
    }

    /// Compact form for sidebar counters: `18.4G`, `846M`.
    static func compact(_ bytes: Int64) -> String {
        let (value, unit) = scaled(bytes)
        let suffix = String(units[unit].prefix(1))
        if unit == 0 { return "\(bytes)B" }
        if value < 10 { return String(format: "%.1f%@", value, suffix) }
        if value < 100 { return String(format: "%.1f%@", value, suffix) }
        return String(format: "%.0f%@", value, suffix)
    }

    /// Splits a formatted value into number and unit (for KPI tiles that style them separately).
    static func parts(_ bytes: Int64) -> (number: String, unit: String) {
        let (value, unit) = scaled(bytes)
        return (number(value, unit: unit), units[unit])
    }

    private static func scaled(_ bytes: Int64) -> (Double, Int) {
        var value = Double(max(bytes, 0))
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return (value, unit)
    }

    private static func number(_ value: Double, unit: Int) -> String {
        if unit == 0 { return String(format: "%.0f", value) }
        if value < 10 { return String(format: "%.2f", value) }
        if value < 100 { return String(format: "%.1f", value) }
        // Hundreds of GB/TB keep one decimal (153.3 GB); MB and KB don't (846 MB).
        return unit >= 3 ? String(format: "%.1f", value) : String(format: "%.0f", value)
    }
}

enum CountFormat {
    /// `1 folder`, `3 folders`
    static func plural(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }

    /// `412k`, `3.1M`, `1,284`
    static func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return "\(n / 1000)k" }
        return n.formatted(.number)
    }
}

enum PathFormat {
    /// Replaces the home directory prefix with `~`.
    static func abbreviate(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        abbreviate(url.path, home: home.path)
    }

    static func abbreviate(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// One spelling per location: `standardizedFileURL` and `resolvingSymlinksInPath` drop the
    /// `/private` prefix of `/var`, `/tmp` and `/etc`, `realpath` adds it. Always compare canonical paths.
    static func canonical(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        for prefix in ["/private/var", "/private/tmp", "/private/etc"] where p == prefix || p.hasPrefix(prefix + "/") {
            p.removeFirst("/private".count)
        }
        return p
    }

    /// Control characters and the invisible ones that reorder text. File names can hold them, and a name from a
    /// cloned repo must not be able to move the cursor, rewrite a line or disguise itself in a terminal.
    private static func isUnsafe(_ s: Unicode.Scalar) -> Bool {
        s.value < 0x20 || (0x7F...0x9F).contains(s.value) || (0x202A...0x202E).contains(s.value)
            || (0x2066...0x2069).contains(s.value) || s.value == 0x200E || s.value == 0x200F
    }

    static func isPrintable(_ text: String) -> Bool { !text.unicodeScalars.contains(where: isUnsafe) }

    /// `text` with anything unsafe to print written out as `\\u{1B}`.
    static func printable(_ text: String) -> String {
        guard !isPrintable(text) else { return text }
        var out = ""
        for s in text.unicodeScalars {
            if isUnsafe(s) { out += "\\u{" + String(s.value, radix: 16, uppercase: true) + "}" } else { out.unicodeScalars.append(s) }
        }
        return out
    }

    /// Expands a leading `~` to the home directory.
    static func expand(_ path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
        return URL(fileURLWithPath: path)
    }
}

enum RelativeDate {
    /// "Today", "Yesterday", "3 weeks ago", "4 months ago", "2 years ago".
    static func string(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return String(localized: "Unknown", comment: "Date that isn't known") }
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return String(localized: "Today") }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) { return String(localized: "Yesterday") }
        let days = max(1, Int(now.timeIntervalSince(date) / 86_400))
        if days < 14 { return String(localized: "\(days) days ago") }
        let weeks = days / 7
        if days < 60 { return String(localized: "\(weeks) weeks ago") }
        let months = days / 30
        if days < 365 { return String(localized: "\(months) months ago") }
        let years = days / 365
        return years == 1 ? String(localized: "1 year ago") : String(localized: "\(years) years ago")
    }

    /// True when `date` is today or yesterday, the cases where `string` names the day rather than an age.
    static func isTodayOrYesterday(_ date: Date, now: Date = Date()) -> Bool {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return true }
        guard let y = cal.date(byAdding: .day, value: -1, to: now) else { return false }
        return cal.isDate(date, inSameDayAs: y)
    }

    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return String(localized: "never", comment: "Relative time: something has never happened") }
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return String(localized: "just now") }
        let minutes = s / 60, hours = s / 3600, days = s / 86_400
        if s < 3600 { return String(localized: "\(minutes) min ago", comment: "Relative time, abbreviated minutes") }
        if s < 86_400 { return String(localized: "\(hours) h ago", comment: "Relative time, abbreviated hours") }
        return String(localized: "\(days) d ago", comment: "Relative time, abbreviated days")
    }

    /// "Mar 3", or "Nov 2025" when not in the current year.
    static func short(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let cal = Calendar.current
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(cal.component(.year, from: date) == cal.component(.year, from: now) ? "MMMd" : "MMMyyyy")
        return f.string(from: date)
    }
}
