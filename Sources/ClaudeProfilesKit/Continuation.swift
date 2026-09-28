import Foundation

/// The readable part of a Claude Code / Cowork transcript: what you wrote, what Claude answered, which tools it used.
public enum TranscriptText {
    public struct Message: Equatable, Sendable {
        public enum Role: String, Sendable { case you = "You", claude = "Claude", summary = "Summary of the earlier conversation" }
        public var role: Role
        public var text: String
    }

    /// Tool calls and results are reduced to the tool names; thinking, sub-agent runs and internal records are left out.
    public static func messages(in transcript: URL) throws -> [Message] {
        let data = try Data(contentsOf: transcript)
        var messages: [Message] = []
        var tools: [String] = []
        func append(_ role: Message.Role, _ text: String) {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if let last = messages.last, last.role == role, role == .claude {
                messages[messages.count - 1].text += "\n\n" + text
            } else {
                messages.append(Message(role: role, text: text))
            }
        }
        func flushTools() {
            guard !tools.isEmpty else { return }
            var counts: [(String, Int)] = []
            for tool in tools {
                if let i = counts.firstIndex(where: { $0.0 == tool }) { counts[i].1 += 1 } else { counts.append((tool, 1)) }
            }
            append(.claude, "_Used " + counts.map { $0.1 > 1 ? "\($0.0) ×\($0.1)" : $0.0 }.joined(separator: ", ") + "_")
            tools = []
        }
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  record["isSidechain"] as? Bool != true, record["isMeta"] as? Bool != true,
                  let type = record["type"] as? String, type == "user" || type == "assistant",
                  let message = record["message"] as? [String: Any] else { continue }
            let blocks: [[String: Any]]
            if let text = message["content"] as? String { blocks = [["type": "text", "text": text]] }
            else { blocks = message["content"] as? [[String: Any]] ?? [] }
            for block in blocks {
                switch (type, block["type"] as? String) {
                case ("assistant", "text"):
                    flushTools(); append(.claude, block["text"] as? String ?? "")
                case ("assistant", "tool_use"):
                    tools.append(block["name"] as? String ?? "a tool")
                case ("user", "text"):
                    flushTools()
                    append(record["isCompactSummary"] as? Bool == true ? .summary : .you, block["text"] as? String ?? "")
                case ("user", "image"):
                    flushTools(); append(.you, "[image]")
                default:
                    continue
                }
            }
        }
        flushTools()
        return messages
    }

    /// Markdown for `messages`. Past `limit` characters, the first message and the latest ones are kept.
    public static func markdown(_ messages: [Message], limit: Int = 400_000) -> String {
        let rendered = messages.map { "**\($0.role.rawValue):**\n\n\($0.text)\n" }
        guard rendered.reduce(0, { $0 + $1.count }) > limit, let first = rendered.first else {
            return rendered.joined(separator: "\n")
        }
        var tail: [String] = []
        var size = first.count
        for part in rendered.dropFirst().reversed() {
            guard size + part.count <= limit else { break }
            tail.insert(part, at: 0); size += part.count
        }
        let omitted = rendered.count - 1 - tail.count
        return ([first, "_… \(omitted) earlier messages left out to keep this file readable. The full transcript stays in the original profile._\n"] + tail)
            .joined(separator: "\n")
    }
}

/// What continuing a Cowork task in another profile hands to the new task: its history as Markdown and copies of
/// the files it was given and made. Prepared under `Handoffs/`, readable only by you.
public struct CoworkHandoff: Sendable {
    public var folder: URL
    public var history: URL
    public var files: [URL]
    public var prompt: String

    public static let maxFiles = 10
    public static let maxFileSize = 25 << 20
    public static let maxTotalSize = 50 << 20

    public var link: URL { ClaudeLink.newCoworkTask(prompt: prompt, files: [history] + files) }

    public static func prepare(_ task: Conversation, sourceLabel: String, paths: Paths, now: Date = Date()) throws -> CoworkHandoff {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.handoffsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        pruneOld(in: paths.handoffsDir, now: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let folder = paths.handoffsDir.appending(path: "\(formatter.string(from: now)) \(safeName(task.title, limit: 60))", directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        var attached: [URL] = []
        var notAttached: [String] = []
        var total = 0
        for (kind, source) in taskFiles(task) {
            let size = (try? fm.attributesOfItem(atPath: source.path)[.size] as? Int) ?? 0
            guard attached.count < maxFiles, size <= maxFileSize, total + size <= maxTotalSize else {
                notAttached.append("\(kind): \(source.path)"); continue
            }
            var target = folder.appending(path: safeName(source.lastPathComponent, limit: 120))
            var n = 2
            while fm.fileExists(atPath: target.path) || target.lastPathComponent == "history.md" {
                target = folder.appending(path: "\(n)-" + safeName(source.lastPathComponent, limit: 120)); n += 1
            }
            do { try fm.copyItem(at: source, to: target) } catch { notAttached.append("\(kind): \(source.path)"); continue }
            attached.append(target)
            total += size
        }

        var text = "# \(task.title)\n\n"
        text += "Cowork task continued from Claude \(sourceLabel) on \(now.formatted(date: .abbreviated, time: .shortened)).\n\n"
        if !task.folders.isEmpty {
            text += "Folders the task worked in:\n" + task.folders.map { "- \($0)\n" }.joined() + "\n"
        }
        if !attached.isEmpty {
            text += "Attached copies of the task's files: " + attached.map(\.lastPathComponent).joined(separator: ", ") + ".\n\n"
        }
        if !notAttached.isEmpty {
            text += "Files not attached (too many or too large); they stay in Claude \(sourceLabel):\n" + notAttached.map { "- \($0)\n" }.joined() + "\n"
        }
        text += "Not carried over: connectors, scheduled tasks and Project settings of the original account. The original task stays in Claude \(sourceLabel).\n\n"
        text += "## Conversation\n\n" + TranscriptText.markdown(try TranscriptText.messages(in: task.transcript))
        let history = folder.appending(path: "history.md")
        guard fm.createFile(atPath: history.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var prompt = "Continue the Cowork task “\(task.title)” from Claude \(sourceLabel). "
        prompt += "Its full history is attached as history.md" + (attached.isEmpty ? ". " : ", with copies of the files it used and made. ")
        prompt += "Read it first, then continue from where it stopped."
        if !task.folders.isEmpty {
            prompt += " It worked in " + task.folders.joined(separator: ", ") + "; ask me to connect a folder if you need it."
        }
        return CoworkHandoff(folder: folder, history: history, files: attached, prompt: prompt)
    }

    /// The task's own files: what it was given first, then what it made. Hidden files and links are skipped.
    static func taskFiles(_ task: Conversation) -> [(String, URL)] {
        guard let taskFolder = task.taskFolder else { return [] }
        var result: [(String, URL)] = []
        for (kind, name) in [("Given", "uploads"), ("Made", "outputs")] {
            let root = taskFolder.appending(path: name, directoryHint: .isDirectory)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                              options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values?.isRegularFile == true, values?.isSymbolicLink != true { result.append((kind, url)) }
            }
        }
        return result
    }

    static func safeName(_ name: String, limit: Int) -> String {
        let cleaned = name.map { "/:\\\n\r\t".contains($0) ? "-" : $0 }
        let trimmed = String(cleaned).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        return trimmed.isEmpty ? "task" : String(trimmed.prefix(limit))
    }

    /// Handoffs older than 30 days go to the Trash.
    static func pruneOld(in directory: URL, now: Date) {
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            guard let created = try? item.resourceValues(forKeys: [.creationDateKey]).creationDate,
                  now.timeIntervalSince(created) > 30 * 86_400 else { continue }
            try? fm.trashItem(at: item, resultingItemURL: nil)
        }
    }
}
