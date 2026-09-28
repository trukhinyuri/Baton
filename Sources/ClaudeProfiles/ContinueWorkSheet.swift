import ClaudeProfilesKit
import SwiftUI

@MainActor
final class ContinueWorkForm: ObservableObject {
    @Published var search = ""
    @Published var selection: String?
    @Published var destination = ""
    @Published var mode: ContinueMode = .auto
    @Published var working = false
    /// The session you confirmed you closed in its window, so the same session may continue elsewhere.
    @Published var stopped: String?
    @Published var alsoNewSession = true
    @Published var problem: String?
    @Published var plan: ContinuePlan?
}

struct ContinueWorkSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = ContinueWorkForm()

    /// How far back “Continue All” looks for sessions in the selected session's folder.
    static let folderWindow: TimeInterval = 24 * 3600

    private var filtered: [Conversation] {
        let query = form.search.trimmingCharacters(in: .whitespaces)
        let all = model.conversations
        guard !query.isEmpty else { return Array(all.prefix(200)) }
        return all.filter { c in
            c.title.localizedCaseInsensitiveContains(query) || c.folders.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var selected: Conversation? { model.conversations.first { $0.id == form.selection } }

    /// The accounts the folder rules allow for the selected conversation; `nil` when no rule applies.
    private var allowed: (accounts: Set<String>, rules: [FolderRule])? {
        selected.flatMap { model.allowedAccounts(for: $0.folders) }
    }

    /// Signed-in windows the selected conversation can move to, within its folder rule.
    private var destinations: [ProfileStatus] {
        model.statuses.filter {
            $0.isSignedIn && $0.id != selected?.ownerID && DestinationRanking.isAllowed($0, accounts: allowed?.accounts)
        }
    }

    /// Why no window is offered, when a folder rule leaves none.
    private var ruleNote: String? {
        guard let allowed, destinations.isEmpty else { return nil }
        let folders = allowed.rules.map { ($0.folder as NSString).abbreviatingWithTildeInPath }.joined(separator: " and ")
        guard model.folderRules != nil else { return "The folder rules can't be read, so nothing continues until they are fixed." }
        return "Work in \(folders) continues only in \(allowed.accounts.sorted().joined(separator: " or ")), and no window is signed in with it. Add that account with “Add Profile”, or change the rule with `claude-profiles rule`."
    }

    private var destinationLabel: String { model.statuses.first { $0.id == form.destination }?.label ?? "" }

    private var forks: Bool { selected.map { form.mode.forks($0) } ?? false }

    /// The same session is about to continue elsewhere although its window may still write to it.
    private func needsStop(_ conversation: Conversation) -> Bool {
        !form.mode.forks(conversation) && conversation.mayStillWrite() && form.stopped != conversation.id
    }

    private var folder: String? { selected?.kind == .cowork ? nil : selected?.folders.first }

    /// The most recent Code sessions in the selected session's folder from the last day, and how many more there are.
    private var folderSelection: (batch: [Conversation], leftOut: Int) {
        guard let folder else { return ([], 0) }
        return ConversationIndex.continueAllBatch(in: folder, since: Date().addingTimeInterval(-Self.folderWindow),
                                                  from: model.conversations, to: form.destination)
    }

    private var folderBatch: [Conversation] { folderSelection.batch }

    /// Whether the chosen window may take the whole batch and the new session under the folder rules.
    private var batchAllowed: Bool {
        guard let folder, let status = model.statuses.first(where: { $0.id == form.destination }) else { return false }
        return DestinationRanking.isAllowed(status, accounts: model.allowedAccounts(for: folderBatch.flatMap(\.folders) + [folder])?.accounts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Continue work in another subscription").font(.title2.bold())
            Text("Choose what to continue and where. The other window opens it for you; nothing is sent on your behalf.")
                .font(.callout).foregroundStyle(.secondary)

            TextField("Search conversations", text: $form.search)
                .textFieldStyle(.roundedBorder)

            List(selection: $form.selection) {
                ForEach(filtered) { conversation in
                    ConversationRow(conversation: conversation, owner: conversation.ownerID.map(model.label(of:)))
                        .tag(conversation.id)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 170)
            .overlay {
                if model.isLoadingConversations && model.conversations.isEmpty {
                    ProgressView("Looking for conversations…")
                } else if filtered.isEmpty {
                    Text(form.search.isEmpty ? "No local conversations yet." : "Nothing matches “\(form.search)”.").foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Text("Continue in")
                Picker("Continue in", selection: $form.destination) {
                    ForEach(destinations) { status in
                        Text(destinationTitle(status)).tag(status.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 360)
                Spacer()
                if let selected, selected.kind != .cowork {
                    Picker("How", selection: $form.mode) {
                        Text("Automatic").tag(ContinueMode.auto)
                        Text("Same session").tag(ContinueMode.same)
                        Text("As a copy").tag(ContinueMode.fork)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 280)
                    .help("Automatic continues sessions still open in a running Claude Code process and sessions with a message in the last 10 minutes as a copy, so two windows never write to one session, and others as the same session.")
                }
            }

            if let selected {
                Text(explanation(selected)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = form.plan?.model, form.plan?.conversation.id == selected.id, form.plan?.destination == form.destination {
                    Label(note.message(destination: destinationLabel), systemImage: note.isWarning ? "exclamationmark.triangle" : "cpu")
                        .font(.callout).foregroundStyle(note.isWarning ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if selected.kind == .cowork && selected.isActive() {
                    Label("This task was working less than a minute ago; the attached history may miss its last steps.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                } else if selected.kind != .cowork && !forks && selected.mayStillWrite() {
                    HStack(spacing: 8) {
                        Label((selected.hasLiveProcess ? "It's open in a running Claude Code process" : "It had a message \(relativeAge(since: selected.lastActivity))")
                              + ", so its window may still write to it. Close it there first, so two windows don't write to one session, or continue as a copy.",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle("I closed it", isOn: Binding(get: { form.stopped == selected.id },
                                                            set: { form.stopped = $0 ? selected.id : nil }))
                            .toggleStyle(.checkbox)
                    }
                }
            }
            if let ruleNote { Text(ruleNote).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if let problem = form.problem { Text(problem).font(.callout).foregroundStyle(.red).textSelection(.enabled) }

            if let folder, !folderBatch.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text("\(folderBatch.count) in \((folder as NSString).lastPathComponent) from the last day"
                         + (folderSelection.leftOut > 0 ? ", the most recent; \(folderSelection.leftOut) older left" : ""))
                        .lineLimit(1).truncationMode(.middle)
                        .help(folderBatch.map(\.title).joined(separator: "\n"))
                    Toggle("Also start a new session there", isOn: $form.alsoNewSession).toggleStyle(.checkbox)
                    Spacer()
                    Button("Continue All in \(destinationLabel.isEmpty ? "…" : destinationLabel)") { goAll() }
                        .disabled(form.working || form.destination.isEmpty || batchNeedsStop || !batchAllowed)
                        .help(!batchAllowed && !form.destination.isEmpty
                              ? "A folder rule doesn't let Claude \(destinationLabel) take all of them."
                              : batchNeedsStop
                              ? "Some of them may still be written to in their window. Choose Automatic or As a copy, or close them there first."
                              : "Opens the \(ConversationIndex.continueAllLimit) most recent Code sessions of this folder with a message in the last day, in one go. Continue older ones one at a time.")
                }
                .font(.callout)
            }

            Divider()
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(primaryTitle) { go() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.working || selected == nil || form.destination.isEmpty
                              || !destinations.contains { $0.id == form.destination } || selected.map(needsStop) == true)
            }
        }
        .padding(22)
        .frame(width: 780, height: 590)
        .onAppear {
            model.loadConversations()
            chooseDefaults()
            refreshPlan()
        }
        .onChange(of: model.conversations) { chooseDefaults(); refreshPlan() }
        .onChange(of: form.selection) {
            form.problem = nil
            if !destinations.contains(where: { $0.id == form.destination }) {
                form.destination = model.bestDestination(excluding: selected?.ownerID, accounts: allowed?.accounts) ?? ""
            }
            refreshPlan()
        }
        .onChange(of: form.destination) { refreshPlan() }
        .onChange(of: form.mode) { refreshPlan() }
    }

    private var batchNeedsStop: Bool { form.mode == .same && folderBatch.contains { $0.mayStillWrite() } }

    private var primaryTitle: String {
        if form.working { return "Opening…" }
        let to = destinationLabel.isEmpty ? "" : " in \(destinationLabel)"
        guard let selected, selected.kind != .cowork else { return "Continue" + to }
        if forks { return "Continue as a Copy" + to }
        if selected.mayStillWrite() { return "Continue Anyway" }
        return "Continue" + to
    }

    private func chooseDefaults() {
        if form.selection == nil || selected == nil { form.selection = model.preselectedConversation ?? model.conversations.first?.id }
        if form.destination.isEmpty || !destinations.contains(where: { $0.id == form.destination }) {
            form.destination = model.bestDestination(excluding: selected?.ownerID, accounts: allowed?.accounts) ?? ""
        }
    }

    /// Model and card details depend on the destination window's own files, so they are read off the main thread.
    private func refreshPlan() {
        guard let selected, selected.kind != .cowork, !form.destination.isEmpty, !model.isDemo else { form.plan = nil; return }
        let manager = model.manager, destination = form.destination, mode = form.mode
        Task {
            let plan = await Task.detached { try? manager.plan([selected], in: destination, mode: mode).first }.value
            if form.selection == selected.id, form.destination == destination, form.mode == mode { form.plan = plan }
        }
    }

    private func destinationTitle(_ status: ProfileStatus) -> String {
        let name = status.isMain ? "Claude (main)" : "Claude \(status.label)"
        if model.isAtLimit(status) { return name + " · limit reached" }
        guard let usage = status.usage, let week = usage.week else { return name }
        return name + " · \(week)% of week · as of \(relativeAge(since: usage.sampledAt))" + (usage.isFresh() ? "" : ", may be higher")
    }

    private func explanation(_ conversation: Conversation) -> String {
        let to = "Claude \(destinationLabel.isEmpty ? "…" : destinationLabel)"
        let from = "Claude \(conversation.ownerID.map(model.label(of:)) ?? "")"
        let why = form.mode == .auto && conversation.kind == .code
            ? (conversation.hasLiveProcess ? " It's open in a running Claude Code process." : " It had a message in the last 10 minutes.") : ""
        switch (conversation.kind, forks) {
        case (.code, false):
            return "Opens this same session in \(to). Its history is shared by all your subscriptions, so nothing is copied."
        case (.code, true):
            return "Opens a copy of this session with its whole history in \(to). The original stays as it is, so its window can keep working on it.\(why)"
        case (.cowork, _):
            return "Starts a new Cowork task in \(to) with this task's history and files attached, for you to review and send. The original task, its connectors and schedules stay with \(from)."
        }
    }

    private func go() {
        guard let conversation = selected, !needsStop(conversation) else { return }
        form.working = true
        form.problem = nil
        let manager = model.manager
        let target = form.destination
        let label = destinationLabel
        let mode = form.mode
        let anyway = form.stopped == conversation.id
        Task {
            do {
                switch try await manager.continueConversation(conversation, in: target, mode: mode, anyway: anyway) {
                case .openedSession(let plan):
                    guard plan.opened != false else {
                        form.problem = "“\(conversation.title)” did not show up in Claude \(label) within \(Int(manager.importWait)) s. Look for it in its sidebar, or try again with the window open."
                        form.working = false
                        return
                    }
                    var text = plan.forks ? "Opened a copy of “\(conversation.title)” in Claude \(label)." : "Opened “\(conversation.title)” in Claude \(label)."
                    if let note = plan.model, note.isWarning { text += " " + note.message(destination: label) }
                    model.show(notice: text)
                case .startedCoworkTask:
                    model.show(notice: "A new Cowork task with the history attached is waiting in Claude \(label). Review it and send it there.")
                }
                model.preselectedConversation = nil
                dismiss()
            } catch {
                form.problem = error.localizedDescription
            }
            form.working = false
        }
    }

    private func goAll() {
        guard let folder, !batchNeedsStop else { return }
        let batch = folderBatch
        form.working = true
        form.problem = nil
        let manager = model.manager
        let target = form.destination
        let label = destinationLabel
        let mode = form.mode
        let newSession = form.alsoNewSession ? folder : nil
        Task {
            do {
                let plans = try await manager.continueAll(batch, in: target, mode: mode, newSessionIn: newSession)
                let missing = plans.filter { $0.opened == false }
                guard missing.isEmpty else {
                    form.problem = "\(missing.count) of \(plans.count) did not show up in Claude \(label) within \(Int(manager.importWait)) s: "
                        + missing.map { "“\($0.conversation.title)”" }.joined(separator: ", ") + ". The others opened; continue these again with the window open."
                    form.working = false
                    model.loadConversations()
                    return
                }
                let copies = plans.filter(\.forks).count
                var text = "Opened \(plans.count) in Claude \(label)" + (copies > 0 ? ", \(copies) as copies" : "")
                    + (newSession == nil ? "." : " and started a new session there.")
                if let warning = plans.compactMap(\.model).first(where: \.isWarning) { text += " " + warning.message(destination: label) }
                model.show(notice: text)
                model.preselectedConversation = nil
                dismiss()
            } catch {
                form.problem = error.localizedDescription
            }
            form.working = false
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    let owner: String?

    private var icon: String {
        switch conversation.kind {
        case .code: "chevron.left.forwardslash.chevron.right"
        case .cowork: "sparkles"
        }
    }

    private var details: String {
        var parts: [String]
        switch conversation.kind {
        case .code: parts = ["Code"]
        case .cowork: parts = ["Cowork · \(owner ?? "")"]
        }
        if let folder = conversation.folders.first {
            parts.append((folder as NSString).abbreviatingWithTildeInPath)
        } else if conversation.kind == .code {
            parts.append("No folder")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title).lineLimit(1).truncationMode(.tail)
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(conversation.lastActivity, format: .relative(presentation: .named))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct DiagnosticsSheet: View {
    let entries: [Diagnostics.Entry]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session readiness").font(.title2.bold())
            Text("Local inventory only. Cloud Projects stay in their account, and Cowork history stays in its original account or local profile. A copied Cowork card does not prove its history can open. This check does not verify cloud access or change settings.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.label).font(.headline)
                            Text("\(entry.localCode) local Code · \(entry.localCowork) Cowork cards")
                            ForEach(entry.issues, id: \.self) { Text($0).foregroundStyle(.orange) }
                            ForEach(entry.missingFolders, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding(22).frame(width: 700, height: 510)
    }
}
