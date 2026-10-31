import Foundation

/// Matches paths against exclusion globs such as `~/Dropbox`, `**/.git`, `~/work/acme/prod-*` and `*.keep`.
///
/// - A pattern without `/` matches any single path component (`*.keep`, `.git`).
/// - A pattern with `/` is matched against the whole path; `**` spans directories, `*` and `?` don't.
/// - A match on a folder also covers everything inside it.
struct GlobMatcher: Sendable {
    private struct Compiled: Sendable {
        let raw: String
        let componentGlob: String?
        let regex: String?
    }

    private let compiled: [Compiled]
    let patterns: [String]

    init(patterns: [String], home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.patterns = patterns
        self.compiled = patterns.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            var p = trimmed
            if p == "~" || p.hasPrefix("~/") { p = PathFormat.expand(p, home: home).path }
            if p.hasPrefix("/") { p = PathFormat.canonical(p) }
            while p.count > 1, p.hasSuffix("/") { p.removeLast() }
            if !p.contains("/") {
                return Compiled(raw: raw, componentGlob: p, regex: nil)
            }
            return Compiled(raw: raw, componentGlob: nil, regex: Self.regex(for: p))
        }
    }

    var isEmpty: Bool { compiled.isEmpty }

    /// True if the path, or any folder containing it, matches a pattern.
    func matches(_ url: URL) -> Bool { matches(path: url.path) }

    func matches(path rawPath: String) -> Bool {
        guard !compiled.isEmpty else { return false }
        let path = PathFormat.canonical(rawPath)
        let components = path.split(separator: "/").map(String.init)
        for c in compiled {
            if let glob = c.componentGlob {
                if components.contains(where: { fnmatch(glob, $0, 0) == 0 }) { return true }
            } else if let regex = c.regex {
                // Test the path and each ancestor, so a match on a folder covers its contents.
                var prefix = ""
                for comp in components {
                    prefix += "/" + comp
                    if prefix.range(of: regex, options: .regularExpression) != nil { return true }
                }
            }
        }
        return false
    }

    static func regex(for pattern: String) -> String {
        var out = "^"
        var chars = Array(pattern)
        // A leading "**/" may match zero directories.
        if pattern.hasPrefix("**/") {
            out += "(?:.*/)?"
            chars.removeFirst(3)
        }
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "*" {
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    // "**/" spans zero or more directories; a bare "**" spans anything.
                    if i + 2 < chars.count, chars[i + 2] == "/" {
                        out += "(?:.*/)?"
                        i += 3
                    } else {
                        out += ".*"
                        i += 2
                    }
                    continue
                }
                out += "[^/]*"
            } else if ch == "?" {
                out += "[^/]"
            } else if "\\^$.|+()[]{}".contains(ch) {
                out += "\\" + String(ch)
            } else {
                out += String(ch)
            }
            i += 1
        }
        if !pattern.hasPrefix("/") && !pattern.hasPrefix("**") { out = "^(?:.*/)?" + out.dropFirst() }
        return out + "$"
    }
}
