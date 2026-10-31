import Foundation

/// A mounted external volume (USB/Thunderbolt drive, SD card).
struct ExternalDrive: Sendable, Identifiable, Hashable, Codable {
    var id: String { url.path }
    let url: URL
    let name: String
    let format: String
    let total: Int64
    let available: Int64
    let isReadOnly: Bool
    let isTimeMachine: Bool
    let isEjectable: Bool
    /// APFS / HFS+: `._` AppleDouble files are rare and meaningful there, so they're left alone.
    let isAppleFormat: Bool

    var used: Int64 { max(0, total - available) }
    /// Read-only volumes and Time Machine backup disks are never cleaned.
    var canClean: Bool { !isReadOnly && !isTimeMachine }
    var lockReason: String? {
        if isTimeMachine { return "Time Machine backup disk" }
        if isReadOnly { return "Read-only volume" }
        return nil
    }
}

/// Junk found on one external drive. Everything here is delete-only: moving files to the Trash on an
/// external drive just moves them into that drive's own `.Trashes`, which frees nothing.
struct DriveJunk: Sendable, Hashable, Codable {
    var trashContents: [URL] = []
    var trashSize: Int64 = 0
    var dsStores: [URL] = []
    var dsStoreSize: Int64 = 0
    var appleDoubles: [URL] = []
    var appleDoubleSize: Int64 = 0
    var filesVisited = 0
    var truncated = false

    var total: Int64 { trashSize + dsStoreSize + appleDoubleSize }
}

enum ExternalDrives {
    static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsReadOnlyKey,
        .volumeIsRootFileSystemKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey, .volumeIsBrowsableKey,
    ]

    /// Folders macOS keeps at a volume's root that are never walked or touched.
    static let systemFolders: Set<String> = [
        ".Spotlight-V100", ".fseventsd", ".Trashes", ".DocumentRevisions-V100", ".TemporaryItems",
        ".MobileBackups", "Backups.backupdb", ".PKInstallSandboxManager", ".vol", "System Volume Information",
    ]

    /// Local, non-boot volumes under `/Volumes` (network shares are skipped).
    static func mounted() -> [ExternalDrive] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard url.path.hasPrefix("/Volumes/"), let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            guard v.volumeIsRootFileSystem != true, v.volumeIsLocal == true, v.volumeIsBrowsable != false else { return nil }
            // Internal non-ejectable volumes (other APFS volumes on the boot disk) aren't "external drives".
            if v.volumeIsInternal == true && v.volumeIsEjectable != true && v.volumeIsRemovable != true { return nil }
            return drive(at: url, values: v)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func drive(at url: URL, values v: URLResourceValues? = nil) -> ExternalDrive {
        let v = v ?? (try? url.resourceValues(forKeys: Set(keys)))
        let format = v?.volumeLocalizedFormatDescription ?? "Unknown"
        let lower = format.lowercased()
        return ExternalDrive(
            url: url,
            name: v?.volumeLocalizedName ?? v?.volumeName ?? url.lastPathComponent,
            format: format,
            total: Int64(v?.volumeTotalCapacity ?? 0),
            available: Int64(v?.volumeAvailableCapacity ?? 0),
            isReadOnly: v?.volumeIsReadOnly ?? false,
            isTimeMachine: isTimeMachine(url),
            // Many USB SSDs report "not ejectable" but are external or removable; they can still be unmounted.
            isEjectable: (v?.volumeIsEjectable ?? false) || (v?.volumeIsRemovable ?? false) || v?.volumeIsInternal == false,
            isAppleFormat: lower.contains("apfs") || lower.contains("mac os") || lower.contains("hfs")
        )
    }

    static func isTimeMachine(_ volume: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: volume.appendingPathComponent("Backups.backupdb").path)
            || fm.fileExists(atPath: volume.appendingPathComponent(".com.apple.timemachine.donotpresent").path) { return true }
        let names = (try? fm.contentsOfDirectory(atPath: volume.path)) ?? []
        return names.contains { $0.hasSuffix(".previous") || $0.hasSuffix(".backupbundle") || $0.hasSuffix(".sparsebundle") && $0.contains("Time Machine") }
    }

    /// The current user's Trash on a volume: `/Volumes/X/.Trashes/<uid>`.
    static func trashFolder(on volume: URL) -> URL {
        volume.appendingPathComponent(".Trashes").appendingPathComponent(String(getuid()))
    }

    /// Finds `.DS_Store` files, `._` AppleDouble files (non-Apple formats only) and the drive's Trash.
    /// Bounded by `limit` files so huge drives stay responsive; `truncated` says when it stopped early.
    static func scanJunk(_ drive: ExternalDrive, exclusions: GlobMatcher, limit: Int = 2_000_000,
                         progress: ScanProgress? = nil) -> DriveJunk {
        var junk = DriveJunk()
        let trash = trashFolder(on: drive.url)
        junk.trashContents = FileWalker.list(trash).map(\.url)
        junk.trashSize = junk.trashContents.reduce(0) { $0 + FileWalker.measure($1).size }

        // Plain readdir/lstat: Foundation's enumerators hide `._` AppleDouble files, which are exactly
        // what we're looking for. Symlinks are never followed.
        var count = 0
        var stack: [(String, Int)] = [(drive.url.path, 0)]
        walk: while let (dir, depth) = stack.popLast() {
            guard let d = opendir(dir) else { continue }
            defer { closedir(d) }
            while let entry = readdir(d) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                if name == "." || name == ".." { continue }
                count += 1
                if count % 4096 == 0 {
                    if Task.isCancelled { break walk }
                    progress?.visited(files: 4096, path: dir)
                }
                if count > limit { junk.truncated = true; break walk }
                let path = dir + "/" + name
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                let type = st.st_mode & S_IFMT
                if type == S_IFDIR {
                    if depth == 0 && systemFolders.contains(name) { continue }
                    if name == ".git" || exclusions.matches(path: path) { continue }
                    stack.append((path, depth + 1))
                    continue
                }
                guard type == S_IFREG else { continue }
                let size = Int64(st.st_blocks) * 512
                if name == ".DS_Store" {
                    junk.dsStores.append(URL(fileURLWithPath: path))
                    junk.dsStoreSize += size
                } else if !drive.isAppleFormat, name.hasPrefix("._"), name.count > 2 {
                    junk.appleDoubles.append(URL(fileURLWithPath: path))
                    junk.appleDoubleSize += size
                }
            }
        }
        junk.filesVisited = count
        return junk
    }
}
