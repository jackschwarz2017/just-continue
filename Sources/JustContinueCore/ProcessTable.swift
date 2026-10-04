import Darwin
import Foundation

public struct ProcessEntry: Sendable, Hashable {
    public var pid: Int32
    public var ppid: Int32
    public var startTime: TimeInterval
    /// Controlling terminal device name, e.g. "ttys003". Nil for background processes.
    public var tty: String?
    /// Kernel short name (p_comm).
    public var comm: String

    public var key: SessionKey { SessionKey(pid: pid, startTime: startTime) }

    init(_ kp: kinfo_proc) {
        pid = kp.kp_proc.p_pid
        ppid = kp.kp_eproc.e_ppid
        let start = kp.kp_proc.p_starttime
        startTime = TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
        tty = nil
        if kp.kp_eproc.e_tdev != -1, let name = devname(kp.kp_eproc.e_tdev, S_IFCHR) {
            let s = String(cString: name)
            if s != "??" { tty = s }
        }
        comm = withUnsafeBytes(of: kp.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// Reads the process table with sysctl / libproc (no `ps` subprocess).
public enum ProcessTable {
    public static func all() -> [ProcessEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return [] }
        // The table can grow between the two calls.
        size += size / 8
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        let actual = size / MemoryLayout<kinfo_proc>.stride

        return procs.prefix(actual).map(ProcessEntry.init)
    }

    public static func entry(pid: Int32) -> ProcessEntry? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        return ProcessEntry(kp)
    }

    /// argv of a process (KERN_PROCARGS2). Only works for the current user's processes.
    public static func arguments(pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // Skip the executable path and the NUL padding after it.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var args: [String] = []
        while args.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }

    public static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public static func currentDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            let s = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            return s.isEmpty ? nil : s
        }
    }
}
