import Foundation

/// Stores the selected task's complete available local history and files without asking the source
/// model to generate a summary. Native history and runtime stay untouched in their original profile.
public enum CoworkContinuation {
    public static func save(_ capture: CoworkHistory.Capture, paths: Paths,
                            existingWorkspace: URL? = nil) throws -> ContinuityWorkspace {
        guard capture.entry.profile.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil else {
            throw ContinuityWorkspace.WorkspaceError.invalid("source profile identifier")
        }
        let source = capture.entry.profile == "main" ? paths.mainDataDir : paths.dataDir(for: capture.entry.profile)
        let fresh = try CoworkHistory(dataDir: source, profile: capture.entry.profile).capture(capture.entry)
        guard fresh == capture else {
            throw ContinuityWorkspace.WorkspaceError.sourceChanged("Cowork history or project context changed after review. Read the task again.")
        }
        let workspace: ContinuityWorkspace
        if let existingWorkspace { workspace = ContinuityWorkspace(directory: existingWorkspace) }
        else {
            workspace = try ContinuityWorkspace.create(in: paths.stateDir.appending(path: "Workspaces"),
                title: capture.entry.title, kind: "local-cowork", sourceProfileID: capture.entry.profile,
                sourceURL: URL(string: capture.entry.sourceURL))
        }
        let previous = try workspace.load()
        let prefix = "captures/\(UUID().uuidString)"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadata = String(decoding: try encoder.encode(capture.entry), as: UTF8.self)
        var texts = [
            ContinuityWorkspace.TextDocument(path: "\(prefix)/conversation.md", text: capture.transcriptText,
                                            sourceURL: URL(string: capture.entry.sourceURL)),
            ContinuityWorkspace.TextDocument(path: "\(prefix)/source.json", text: metadata)
        ]
        texts += capture.transcripts.map {
            .init(path: "\(prefix)/history/\($0.relativePath)", text: $0.text,
                  sourceURL: URL(string: capture.entry.sourceURL))
        }
        texts += capture.projectContext.map {
            .init(path: "\(prefix)/\($0.relativePath)", text: $0.text,
                  sourceURL: URL(string: capture.entry.sourceURL))
        }
        let files = capture.files.map {
            ContinuityWorkspace.SelectedFile(path: "\(prefix)/\($0.relativePath)",
                fileURL: URL(fileURLWithPath: $0.sourcePath), expectedSHA256: $0.sha256, expectedSize: Int($0.size))
        }
        let component = capture.entry.sourceKey
        _ = try workspace.publish(texts: texts, files: files, coverage: [
            .init(component: "\(component): local history", status: .complete,
                  detail: "\(capture.transcripts.count) transcripts; \(capture.transcripts.reduce(0) { $0 + $1.recordCount }) records, including tool results and available subagents."),
            .init(component: "\(component): local artifacts", status: .partial,
                  detail: "\(capture.files.count) files captured. Credential/configuration files and external working folders are excluded; inspect the limitations."),
            .init(component: "\(component): project instructions and memory",
                  status: !capture.projectContext.isEmpty ? .partial : (capture.entry.spaceID == nil ? .notApplicable : .unavailable),
                  detail: !capture.projectContext.isEmpty
                    ? "\(capture.projectContext.count) local project documents are preserved in conversation.md. Check limitations for missing memory, sibling tasks and cloud Library files."
                    : "No parent project context was available for this task. Profile-wide memory and cloud resources are not included."),
            .init(component: "\(component): tools and active runtime", status: .unavailable,
                  detail: "Use the destination account's tools and permissions. The live VM and account access are not transferred.")
        ], limitations: capture.limitations, expectedRevision: previous.revision)
        _ = try workspace.load()
        return workspace
    }
}
