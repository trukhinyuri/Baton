import Darwin
import Foundation

/// Claude Code sessions that a running `claude` process has open. Such a process can write to its session at any
/// time — when a background task or sub-agent finishes, or a message arrives through Remote Control — even after
/// its transcript has been quiet for a long while, so a quiet transcript alone doesn't make a session safe to
/// continue as itself in another window.
public enum LiveSessions {
    /// Every open session id, lowercased: from the list Claude Code keeps of its running processes
    /// (`~/.claude/sessions/<pid>.json`) and from the `--resume` / `--session-id` arguments of running `claude`
    /// processes, which Claude Desktop starts resumed sessions with.
    public static func ids(claudeDir: URL) -> Set<String> {
        ids(inRegistry: claudeDir.appending(path: "sessions", directoryHint: .isDirectory), isRunning: isClaude)
            .union(idsFromArguments())
    }

    static func ids(inRegistry folder: URL, isRunning: (pid_t) -> Bool) -> Set<String> {
        var found = Set<String>()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".json") {
            guard let pid = pid_t(name.dropLast(".json".count)), pid > 0, isRunning(pid),
                  let data = try? Data(contentsOf: folder.appending(path: name)),
                  let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (record["pid"] as? Int).map({ $0 == Int(pid) }) ?? true,
                  let id = record["sessionId"] as? String, !id.isEmpty else { continue }
            found.insert(id.lowercased())
        }
        return found
    }

    /// Alive and a Claude Code process: a number that another program reuses after Claude Code exits doesn't count.
    static func isClaude(_ pid: pid_t) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 else { return false }
        if processName(pid) == "claude" { return true }
        // An install that runs under Node: `node …/@anthropic-ai/claude-code/cli.js`.
        return ProcessArguments.of(pid)?.contains { $0.contains("claude-code") } ?? false
    }

    static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let end = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func idsFromArguments() -> Set<String> {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        var found = Set<String>()
        for pid in pids.prefix(Int(count)) where pid > 0 && processName(pid) == "claude" {
            if let arguments = ProcessArguments.of(pid) { found.formUnion(sessionIDs(inArguments: arguments)) }
        }
        return found
    }

    /// `--resume=<id>`, `--resume <id>`, `-r <id>`, `--session-id=<id>` or `--session-id <id>`; only UUIDs count.
    static func sessionIDs(inArguments arguments: [String]) -> Set<String> {
        var found = Set<String>()
        func add(_ value: String) { if UUID(uuidString: value) != nil { found.insert(value.lowercased()) } }
        var i = 1
        while i < arguments.count {
            let argument = arguments[i]
            if argument == "--" { break }
            for flag in ["--resume=", "--session-id="] where argument.hasPrefix(flag) { add(String(argument.dropFirst(flag.count))) }
            if ["--resume", "-r", "--session-id"].contains(argument), i + 1 < arguments.count {
                add(arguments[i + 1])
                i += 1
            }
            i += 1
        }
        return found
    }
}
