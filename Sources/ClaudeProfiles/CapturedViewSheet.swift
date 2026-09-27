import AppKit
import ClaudeProfilesKit
import SwiftUI

private struct CapturedViewItem: Identifiable {
    let id = UUID()
    let snapshot: ClaudeContextCapture.Snapshot
    var scope: String = "Current view"
}

private enum PendingCapture { case currentView, availableViews }

@MainActor
private final class CapturedViewForm: ObservableObject {
    @Published var source = "main"
    @Published var captures: [CapturedViewItem] = []
    @Published var workspaceTitle = ""
    @Published var existingWorkspace: URL?
    @Published var existingTitle = ""
    @Published var savedWorkspace: ContinuityWorkspace?
    @Published var savedCount = 0
    @Published var busy = false
    @Published var message = ""
    @Published var projectCapture: ClaudeContextCapture.ProjectCapture?
    var captureTask: Task<Void, Never>?
    let access = AccessibilityAccess.Controller()
    @Published var accessState = AccessibilityAccess.State()
    @Published var pendingCapture: PendingCapture?
    @Published var permissionPollingActive = false
    @Published var permissionPollingGeneration = 0
}

/// Captures existing visible context, with an optional bounded read-only Project sweep. Never sends prompts.
struct CapturedViewSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = CapturedViewForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Project or Cowork context").font(.title2.bold())
            Text("PARTIAL CAPTURE — coverage is reported explicitly").font(.headline).foregroundStyle(.orange)
            Text("Open the desired Project, conversation or project settings in Claude. This reads the text that Claude currently exposes. Other pages, older history, collapsed results and Library files may be missing. It does not ask Claude to generate a response or use your plan's quota.")
                .font(.callout).foregroundStyle(.secondary)
            windowAccess
            HStack {
                Picker("Claude profile", selection: $form.source) {
                    ForEach(model.statuses) { Text($0.label).tag($0.id) }
                }
                Button("Read current view", action: readCurrentView)
                Button("Read available views", action: readProject)
                if form.busy { ProgressView().controlSize(.small) }
            }.disabled(form.busy)
            if form.captureTask != nil { Button("Cancel capture") { form.captureTask?.cancel() } }
            Text("Project capture opens existing settings, memory, threads and Library views. Cowork capture reads the open conversation and available older messages. Leave that Claude window untouched while it runs. It never sends messages or changes project settings; unsupported views and files are reported as gaps.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if form.captures.isEmpty {
                        Text("No context has been read yet.").foregroundStyle(.secondary)
                    }
                    ForEach(form.captures) { item in
                        let snapshot = item.snapshot
                        VStack(alignment: .leading, spacing: 5) {
                            Text(snapshot.title).font(.headline)
                            Text(item.scope).font(.caption).foregroundStyle(.secondary)
                            Text("\(snapshot.profileLabel) · \(snapshot.capturedAt.formatted(date: .abbreviated, time: .standard)) · \(snapshot.sections.count) sections")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(snapshot.documentURL).font(.caption).textSelection(.enabled)
                            ForEach(snapshot.gaps, id: \.self) { gap in
                                Text(Self.description(gap)).font(.caption).foregroundStyle(.orange)
                            }
                            if !snapshot.collapsedControls.isEmpty {
                                Text("Not opened: " + snapshot.collapsedControls.joined(separator: ", ")).font(.caption)
                            }
                            if !snapshot.paginationControls.isEmpty {
                                Text("More content available: " + snapshot.paginationControls.joined(separator: ", ")).font(.caption)
                            }
                            DisclosureGroup("Preview — first 6,000 characters; all captured text is saved") {
                                Text(String(snapshot.text.prefix(6_000))).font(.caption.monospaced()).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 160, maxHeight: 290)
            HStack {
                Button("Append to an existing workspace…", action: chooseWorkspace)
                Button("Use a new workspace", action: useNewWorkspace)
                    .disabled(form.existingWorkspace == nil)
            }.disabled(form.busy)
            if let capture = form.projectCapture {
                if capture.kind == .coworkConversation {
                    Text("Cowork history sweep: \(capture.views.count) captured views; \(capture.inventory.filter { $0.kind == "reference" }.count) source references.").font(.caption)
                } else {
                    Text("Project sweep: \(capture.views.count) captured views; \(capture.inventory.filter { $0.kind == "thread" && $0.captured }.count) threads visited; \(capture.inventory.filter { $0.kind == "memory" && $0.captured }.count) memory files read.")
                        .font(.caption)
                }
                DisclosureGroup("Remaining limits (partial capture)") {
                    ForEach(capture.limitations, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                }
            }
            if let existing = form.existingWorkspace {
                Text("Append to: \(form.existingTitle)").font(.callout)
                Text(existing.path).font(.caption).textSelection(.enabled)
            } else {
                TextField("Workspace title", text: $form.workspaceTitle).disabled(form.busy)
            }
            Text("Earlier captures are retained. These files are saved privately on this Mac; nothing is sent to another profile or uploaded.")
                .font(.caption).foregroundStyle(.secondary)
            if let workspace = form.savedWorkspace {
                Button("Review saved context") { NSWorkspace.shared.activateFileViewerSelecting([workspace.continuationFile]) }
                    .disabled(form.busy)
            }
            if !form.message.isEmpty { Text(form.message).font(.callout).textSelection(.enabled) }
            HStack {
                Button("Close") { form.captureTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save partial capture", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(form.busy || form.captures.count == form.savedCount ||
                              (form.existingWorkspace == nil && form.workspaceTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(22).frame(width: 750)
        .onAppear { refreshPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshPermission() }
        .task(id: form.permissionPollingGeneration) { await monitorPermissionChange() }
        .onDisappear {
            form.permissionPollingActive = false
            form.captureTask?.cancel()
        }
        .onChange(of: form.source) { _, _ in
            form.captureTask?.cancel(); form.projectCapture = nil; form.pendingCapture = nil
            form.captures = []; form.savedCount = 0; form.savedWorkspace = nil; form.message = ""
            if form.existingWorkspace == nil { form.workspaceTitle = "" }
        }
    }

    @ViewBuilder
    private var windowAccess: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                if form.accessState.canCapture {
                    HStack {
                        Label("Claude window access is enabled", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
                        Spacer()
                        if form.pendingCapture != nil { Button("Continue capture", action: checkPermissionAndRetry) }
                    }
                } else {
                    Text("Allow Claude Profiles to read Claude's windows").font(.headline)
                    Text("macOS grants broad access to read and control apps. Claude Profiles uses it here only to capture the Claude profile you select. The setting is called \(form.access.settingsPaneName). It is used here for context capture.")
                        .font(.callout).foregroundStyle(.secondary)
                    if form.accessState.status == .waitingForApproval {
                        Text("Enable Claude Profiles in System Settings, then return here. Access is checked automatically for one minute; you can check again at any time.").font(.caption)
                    } else if form.accessState.status == .notApplied {
                        Text("macOS has not confirmed access for this running copy. An enabled switch alone does not confirm that capture can use it.").font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        if !form.accessState.requested {
                            Button("Request access", action: requestPermission).buttonStyle(.borderedProminent)
                        }
                        Button("Open System Settings", action: openPermissionSettings)
                        Button(form.pendingCapture == nil ? "Check again" : "Check & retry", action: checkPermissionAndRetry)
                        if form.pendingCapture != nil || form.accessState.requested {
                            Button("Not now", action: cancelPermissionWaiting)
                        }
                    }
                    if form.accessState.settingsOpenFailed {
                        Text("System Settings could not be opened. Open it from the Apple menu, then choose Privacy & Security → \(form.access.settingsPaneName).").font(.caption).foregroundStyle(.orange)
                    }
                    if form.accessState.requested || form.accessState.status == .notApplied {
                        DisclosureGroup("Already enabled, or recently updated the app?") {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("In Privacy & Security → \(form.access.settingsPaneName), enable the current Claude Profiles application. If an old entry is still enabled after an update, remove that Claude Profiles entry and add the current application using +. Then check again. If macOS still has not applied access, save any captured context, quit Claude Profiles and reopen it.")
                                if form.access.application.isAdHocSigned == true {
                                    Text("This development build has a signature tied to this version. macOS may require access to be granted again after an update.")
                                }
                                Text(form.access.application.url.path).textSelection(.enabled)
                                Button("Show this application in Finder") { form.access.revealThisApplication() }
                            }.font(.caption)
                        }
                    }
                    Text("No other OS permission is requested here. Profile management and saved workspaces remain available without it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.disabled(form.busy)
    }

    private func refreshPermission() {
        form.accessState = form.access.refresh()
        if form.accessState.canCapture { form.permissionPollingActive = false }
    }
    private func beginPermissionMonitoring() {
        form.permissionPollingActive = !form.accessState.canCapture
        form.permissionPollingGeneration += 1
    }
    private func monitorPermissionChange() async {
        guard form.permissionPollingGeneration > 0 else { return }
        for _ in 0..<60 {
            guard form.permissionPollingActive, !Task.isCancelled else { return }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard !Task.isCancelled else { return }
            refreshPermission()
        }
        form.permissionPollingActive = false
    }
    private func requestPermission() {
        form.accessState = form.access.requestAccess()
        beginPermissionMonitoring()
    }
    private func openPermissionSettings() {
        form.accessState = form.access.openSystemSettings()
        beginPermissionMonitoring()
    }
    private func cancelPermissionWaiting() {
        form.pendingCapture = nil; form.permissionPollingActive = false
        form.accessState = form.access.cancelWaiting()
        form.message = "Capture is paused. Your saved workspaces and already read views remain available."
    }
    private func checkPermissionAndRetry() {
        form.accessState = form.access.checkAfterSettingsChange()
        guard form.accessState.canCapture else { return }
        form.permissionPollingActive = false
        guard let pending = form.pendingCapture else { return }
        form.pendingCapture = nil
        switch pending {
        case .currentView: readCurrentView()
        case .availableViews: readProject()
        }
    }
    private func prepareAccess(for capture: PendingCapture) -> Bool {
        refreshPermission()
        guard form.accessState.canCapture else {
            form.pendingCapture = capture
            form.message = "Window access is needed for this capture. Use Request access above; previously captured views are retained."
            return false
        }
        form.pendingCapture = nil
        return true
    }
    private func captureAccessFailed(_ capture: PendingCapture) {
        form.pendingCapture = capture
        form.accessState = form.access.recordCaptureDenied()
        form.message = "Capture could not use window access. Check the current application in System Settings, then use Check & retry. Already read views are retained."
    }

    private func readProject() {
        guard !form.busy, prepareAccess(for: .availableViews) else { return }
        form.busy = true; form.message = "Reading existing context…"; form.projectCapture = nil
        let source = form.source, paths = model.manager.paths
        form.captureTask = Task { @MainActor in
            defer { form.busy = false; form.captureTask = nil }
            await Task.yield()
            do {
                let capture = try await ClaudeContextCapture.captureAvailableViews(profileID: source, paths: paths) { view in
                    form.captures.append(CapturedViewItem(snapshot: view.snapshot, scope: view.scope))
                    if form.workspaceTitle.isEmpty { form.workspaceTitle = view.snapshot.title }
                    form.message = "Read \(form.captures.count) views; now: \(view.scope)"
                }
                form.projectCapture = capture
                form.message = capture.cancelled
                    ? "Capture cancelled. All previously read views are retained and can be saved."
                    : "Context sweep finished: \(capture.views.count) views read. Review the remaining limits and save the partial context."
            } catch ClaudeContextCapture.CaptureError.accessibilityPermissionRequired {
                captureAccessFailed(.availableViews)
            } catch { form.message = error.localizedDescription }
        }
    }

    private func readCurrentView() {
        guard !form.busy, prepareAccess(for: .currentView) else { return }
        form.busy = true; form.message = ""
        let profileID = form.source, paths = model.manager.paths
        Task { @MainActor in
            defer { form.busy = false }
            // Let the progress indicator draw before the synchronous, read-only Accessibility request.
            await Task.yield()
            do {
                let snapshot = try ClaudeContextCapture.captureCurrentView(profileID: profileID, paths: paths)
                if form.captures.contains(where: {
                    $0.snapshot.profileID == snapshot.profileID && $0.snapshot.documentURL == snapshot.documentURL &&
                    $0.snapshot.sections == snapshot.sections && $0.snapshot.gaps == snapshot.gaps &&
                    $0.snapshot.collapsedControls == snapshot.collapsedControls && $0.snapshot.paginationControls == snapshot.paginationControls
                }) {
                    form.message = "This view is already in the capture. Open another view in Claude to add more context."
                    return
                }
                form.captures.append(CapturedViewItem(snapshot: snapshot))
                if form.workspaceTitle.isEmpty { form.workspaceTitle = snapshot.title }
                form.message = "Read \(snapshot.sections.count) sections. This remains a partial capture; no message was sent and Claude was not changed."
            } catch ClaudeContextCapture.CaptureError.accessibilityPermissionRequired {
                captureAccessFailed(.currentView)
            } catch { form.message = error.localizedDescription }
        }
    }

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Choose a Claude Profiles workspace. Earlier context will be retained."
        panel.directoryURL = model.manager.paths.stateDir.appending(path: "Workspaces")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let snapshot = try ContinuityWorkspace(directory: url).load()
                form.existingWorkspace = url; form.existingTitle = snapshot.title
                form.savedCount = 0; form.savedWorkspace = nil; form.message = ""
            } catch { form.message = error.localizedDescription }
        }
    }

    private func useNewWorkspace() {
        form.existingWorkspace = nil; form.existingTitle = ""; form.savedCount = 0
        form.savedWorkspace = nil; form.message = ""
    }

    private func save() {
        guard !form.busy, form.savedCount < form.captures.count else { return }
        let captures = form.captures.dropFirst(form.savedCount).map(\.snapshot)
        let paths = model.manager.paths, existing = form.existingWorkspace, title = form.workspaceTitle
        let totalCount = form.captures.count, projectCapture = form.projectCapture
        form.busy = true; form.message = ""
        Task {
            defer { form.busy = false }
            do {
                let workspace = try await Task.detached {
                    try Self.save(captures, root: paths.stateDir.appending(path: "Workspaces"), existing: existing, title: title, projectCapture: projectCapture)
                }.value
                form.savedWorkspace = workspace; form.existingWorkspace = workspace.directory
                form.existingTitle = try workspace.load().title; form.savedCount = totalCount
                form.message = "Partial context saved and checked. Earlier context is retained. Missing history, other views and files are still listed as gaps."
            } catch { form.message = error.localizedDescription }
        }
    }

    nonisolated private static func save(_ captures: [ClaudeContextCapture.Snapshot], root: URL, existing: URL?, title: String, projectCapture: ClaudeContextCapture.ProjectCapture?) throws -> ContinuityWorkspace {
        guard let first = captures.first else { throw ContinuityWorkspace.WorkspaceError.invalid("no captured views") }
        let workspace: ContinuityWorkspace
        if let existing { workspace = ContinuityWorkspace(directory: existing) }
        else {
            var identity = URLComponents(string: first.documentURL)
            identity?.query = nil
            workspace = try .create(in: root, title: title, kind: first.kind.rawValue,
                                    sourceProfileID: first.profileID, sourceURL: identity?.url)
        }
        do {
            let previous = try workspace.load()
            var texts: [ContinuityWorkspace.TextDocument] = []
            var coverage: [ContinuityWorkspace.Coverage] = []
            var limitations = ["PARTIAL: only explicitly captured visible views are included. A complete project, full thread history, attachments, cloud Library and live runtime have not been exported."]
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            for capture in captures {
                let prefix = "visible-captures/\(UUID().uuidString)"
                let metadata = String(decoding: try encoder.encode(capture), as: UTF8.self)
                texts.append(.init(path: "\(prefix)/visible-context.md", text: capture.text, sourceURL: URL(string: capture.documentURL)))
                texts.append(.init(path: "\(prefix)/capture.json", text: metadata))
                coverage.append(.init(component: "\(capture.profileID): \(capture.documentURL): visible context", status: .partial,
                                      detail: "\(capture.sections.count) sections read from this view at \(capture.capturedAt.ISO8601Format()). Other content has not been verified."))
                limitations += capture.gaps.map(Self.description)
            }
            if let projectCapture {
                let prefix = "project-captures/\(UUID().uuidString)"
                texts.append(.init(path: "\(prefix)/capture.json", text: String(decoding: try encoder.encode(projectCapture), as: UTF8.self)))
                limitations += projectCapture.limitations
                for item in projectCapture.inventory where item.kind != "reference" {
                    coverage.append(.init(component: "\(prefix): \(item.kind): \(item.label)", status: .partial,
                                          detail: item.captured ? "Visited/read through native UI; full history or original file coverage is not proven." : "Observed but not captured; further reading is required."))
                }
            }
            _ = try workspace.publish(texts: texts, coverage: coverage, limitations: limitations, expectedRevision: previous.revision)
            _ = try workspace.load()
            return workspace
        } catch {
            // Only remove an empty workspace created by this call; existing captures always remain intact.
            if existing == nil, (try? workspace.load().revision) == 0 { try? FileManager.default.removeItem(at: workspace.directory) }
            throw error
        }
    }

    nonisolated private static func description(_ gap: ClaudeContextCapture.Gap) -> String {
        switch gap {
        case .otherViewsNotVisited: "Other project pages, threads, memory and Library files have not been read."
        case .historyMayBeVirtualized: "Claude may expose older messages only after they are opened or scrolled into view."
        case .paginationAvailable: "Claude offers more or older content that has not been opened."
        case .collapsedContent: "Some messages or tool results are collapsed and have not been opened."
        case .treeReadLimited: "The current view could not be read completely."
        case .embeddedArtifactNotCaptured: "An embedded artifact was opened but its rendered content and original file have not been captured."
        }
    }
}
