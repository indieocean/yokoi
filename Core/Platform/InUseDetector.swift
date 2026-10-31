import Darwin
import Foundation

/// Finds paths that running processes are using, so cleanup can refuse projects that are open
/// (PRD §6: "Projects with a running process — open in Xcode/Unity/Unreal, node cwd — are blocked").
///
/// Uses `libproc` on the user's own processes (no root needed): every process's executable path,
/// working directory and launch arguments, plus open files for known dev tools.
struct InUseSnapshot: Sendable {
    struct Use: Sendable, Hashable {
        let path: String
        let process: String
    }

    let uses: [Use]

    static let empty = InUseSnapshot(uses: [])

    /// Process names whose open files are also inspected (they rarely `cd` into the project).
    static let devTools: Set<String> = [
        "Xcode", "Unity", "UnrealEditor", "UE4Editor", "node", "bun", "deno", "java", "cargo", "rustc",
        "rust-analyzer", "sourcekit-lsp", "swift-build", "gradle", "dotnet", "Rider", "Code Helper",
    ]

    /// The name of a process using `root` or anything inside it, or nil when nothing is.
    func blocker(for root: URL) -> String? {
        let r = PathFormat.canonical(root.path)
        guard r != "/" else { return nil }
        let prefix = r + "/"
        return uses.first { $0.path == r || $0.path.hasPrefix(prefix) }?.process
    }

    /// Captures a snapshot of the current user's processes.
    static func capture(excludingPID: pid_t = getpid()) -> InUseSnapshot {
        var uses = Set<Use>()
        let home = PathFormat.canonical(FileManager.default.homeDirectoryForCurrentUser.path)
        for pid in allPIDs() where pid != excludingPID && pid > 0 {
            let name = processName(pid)
            guard !name.isEmpty else { continue }
            if let exe = executablePath(pid) { uses.insert(Use(path: PathFormat.canonical(exe), process: name)) }
            if let cwd = workingDirectory(pid), cwd != "/", cwd != home {
                uses.insert(Use(path: PathFormat.canonical(cwd), process: name))
            }
            for arg in arguments(pid) where arg.hasPrefix("/") && arg.count > 1 {
                uses.insert(Use(path: PathFormat.canonical(arg), process: name))
            }
            if devTools.contains(name) {
                for path in openFiles(pid) { uses.insert(Use(path: PathFormat.canonical(path), process: name)) }
            }
        }
        return InUseSnapshot(uses: Array(uses))
    }

    // MARK: libproc

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = pids.withUnsafeMutableBufferPointer { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count * MemoryLayout<pid_t>.size))
        }
        return Array(pids.prefix(Int(max(n, 0))))
    }

    static func processName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, UInt32(buf.count))
        return Self.string(buf)
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? Self.string(buf) : nil
    }

    /// C string in a fixed buffer → String (up to the first NUL).
    static func string(_ buf: [CChar]) -> String {
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    /// Launch arguments via `KERN_PROCARGS2` (argc, exec path, then NUL-separated args).
    static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        // Skip the exec path and its padding NULs.
        while i < size, buf[i] != 0 { i += 1 }
        while i < size, buf[i] == 0 { i += 1 }
        var args: [String] = []
        while i < size, args.count < Int(argc) {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return Array(args.dropFirst()) // argv[0]
    }

    static func openFiles(_ pid: pid_t) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let count = Int(bytes) / MemoryLayout<proc_fdinfo>.size
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, bytes) }
        guard got > 0 else { return [] }
        var paths: [String] = []
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if path.hasPrefix("/") { paths.append(path) }
        }
        return paths
    }
}
