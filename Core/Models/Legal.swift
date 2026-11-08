import Foundation

/// Copyright and license notice (GPL-3.0), shown in Settings and by `yokoi version`.
enum Legal {
    static let notice = String(localized: """
    Copyright © 2026 The Ranch STEAM Lab. Yokoi is free software under the GNU General Public License v3.0, \
    and comes with absolutely no warranty. You may redistribute it under the terms of that license.
    """, comment: "License notice in Settings and `yokoi version`")
    static let sourceURL = URL(string: "https://github.com/indieocean/yokoi")!
    static let licenseURL = URL(string: "https://github.com/indieocean/yokoi/blob/main/LICENSE")!
}
