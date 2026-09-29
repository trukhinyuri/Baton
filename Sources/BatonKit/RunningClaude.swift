import AppKit
import Darwin

/// A running copy of Claude Desktop (the main app or a profile's engine) and the arguments it was started with.
///
/// The bundle alone doesn't tell which account a window shows: an engine opened straight from a Dock icon kept
/// with “Keep in Dock”, or reopened by macOS at login, starts without `--user-data-dir` and shows the main app's data.
struct RunningClaude {
    var app: NSRunningApplication?
    var bundlePath: String?
    /// `nil` if they couldn't be read.
    var arguments: [String]?
    /// The process, if known; tests give one without an app.
    var pid: pid_t?

    init(app: NSRunningApplication) {
        self.app = app
        bundlePath = app.bundleURL?.standardizedFileURL.path
        arguments = ProcessArguments.of(app.processIdentifier)
        pid = app.processIdentifier
    }

    init(bundlePath: String?, arguments: [String]?, pid: pid_t? = nil) {
        self.bundlePath = bundlePath
        self.arguments = arguments
        self.pid = pid
    }

    /// Whether this copy shows the data in `dataDir`, which `bundle` uses when it is started the usual way.
    /// Without readable arguments the bundle decides, as it did before arguments were checked.
    func uses(dataDir: URL, mainDataDir: URL, bundle: URL) -> Bool {
        guard let arguments else { return bundlePath == bundle.standardizedFileURL.path }
        let used = ProcessArguments.userDataDir(in: arguments).map { URL(fileURLWithPath: $0) } ?? mainDataDir
        return used.standardizedFileURL.path == dataDir.standardizedFileURL.path
    }

    /// Started from `engine` without `--user-data-dir`, so it shows the main app's account instead of the profile's.
    func isStartedWithoutDataDir(engine: URL) -> Bool {
        guard bundlePath == engine.standardizedFileURL.path, let arguments else { return false }
        return ProcessArguments.userDataDir(in: arguments) == nil
    }
}

enum ProcessArguments {
    /// The command line of one of this user's processes, read with `sysctl(KERN_PROCARGS2)` the way `ps` does.
    static func of(_ pid: pid_t) -> [String]? {
        var buffer: [UInt8] = []
        return of(pid, buffer: &buffer)
    }

    /// The same, reusing `buffer` across calls, so reading every process doesn't allocate `KERN_ARGMAX` bytes each time.
    static func of(_ pid: pid_t, buffer: inout [UInt8]) -> [String]? {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var argmaxName: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argmaxName, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
        if buffer.count < Int(argmax) { buffer = [UInt8](repeating: 0, count: Int(argmax)) }
        size = buffer.count
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parse(procargs: buffer.prefix(size))
    }

    /// `KERN_PROCARGS2` holds `argc`, the executable path, NUL padding, then `argc` NUL-terminated arguments
    /// followed by the environment.
    static func parse(procargs buffer: ArraySlice<UInt8>) -> [String]? {
        let bytes = Array(buffer)
        guard bytes.count >= MemoryLayout<Int32>.size else { return nil }
        let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = MemoryLayout<Int32>.size
        while i < bytes.count, bytes[i] != 0 { i += 1 }  // executable path
        while i < bytes.count, bytes[i] == 0 { i += 1 }  // padding
        var arguments: [String] = []
        while arguments.count < argc, i < bytes.count {
            let start = i
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            arguments.append(String(decoding: bytes[start..<i], as: UTF8.self))
            i += 1
        }
        return arguments.count == argc ? arguments : nil
    }

    /// The value of Electron's `--user-data-dir` switch, parsed like Chromium's `CommandLine` on macOS:
    /// `--name=value` or `-name=value`, the last one wins, and nothing after `--` is a switch.
    static func userDataDir(in arguments: [String]) -> String? {
        var found: String?
        for argument in arguments.dropFirst() {
            if argument == "--" { break }
            for prefix in ["--user-data-dir=", "-user-data-dir="] where argument.hasPrefix(prefix) {
                let value = String(argument.dropFirst(prefix.count))
                found = value.isEmpty ? nil : value
            }
        }
        return found
    }
}
