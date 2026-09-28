import AppKit
import ClaudeProfilesKit
import SwiftUI

@MainActor
final class ContinueWorkForm: ObservableObject {
    @Published var search = ""
    @Published var selection: String?
    @Published var destination = ""
    @Published var working = false
    @Published var confirmedActive: String?
    @Published var problem: String?
    @Published var copied = false
}

struct ContinueWorkSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = ContinueWorkForm()

    private var filtered: [Conversation] {
        let query = form.search.trimmingCharacters(in: .whitespaces)
        let all = model.conversations
        guard !query.isEmpty else { return Array(all.prefix(200)) }
        return all.filter { c in
            c.title.localizedCaseInsensitiveContains(query) || c.folders.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var selected: Conversation? { model.conversations.first { $0.id == form.selection } }

    /// Signed-in windows the selected conversation can move to.
    private var destinations: [ProfileStatus] {
        model.statuses.filter { $0.isSignedIn && (selected?.kind == .code || $0.id != selected?.ownerID) }
    }

    private var destinationLabel: String { model.statuses.first { $0.id == form.destination }?.label ?? "" }

    private var needsConfirmation: Bool {
        guard let selected else { return false }
        return selected.isActive() && form.confirmedActive != selected.id
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
            .frame(minHeight: 180)
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
                .frame(maxWidth: 320)
                Spacer()
            }

            if let selected {
                Text(explanation(selected)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if selected.isActive() {
                    Label(selected.kind == .cowork
                          ? "This task was working less than a minute ago; the attached history may miss its last steps."
                          : "This session was working less than a minute ago. Stop it in its window first, so two windows don't write to it at once.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            if let problem = form.problem { Text(problem).font(.callout).foregroundStyle(.red).textSelection(.enabled) }

            Divider()
            HStack(spacing: 8) {
                Button(form.copied ? "Request copied" : "Copy handoff request") { copyRequest() }
                    .help("For a claude.ai chat or a cloud Project, which are not on this Mac: paste the request in that chat, then paste its answer into a new chat in the other subscription.")
                Text("for claude.ai chats").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(primaryTitle) { go() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.working || selected == nil || form.destination.isEmpty || !destinations.contains { $0.id == form.destination })
            }
        }
        .padding(22)
        .frame(width: 740, height: 500)
        .onAppear {
            model.loadConversations()
            chooseDefaults()
        }
        .onChange(of: model.conversations) { chooseDefaults() }
        .onChange(of: form.selection) {
            form.problem = nil
            if !destinations.contains(where: { $0.id == form.destination }) { form.destination = model.bestDestination(excluding: selected?.ownerID) ?? "" }
        }
    }

    private var primaryTitle: String {
        if form.working { return "Opening…" }
        if needsConfirmation && selected?.kind != .cowork { return "Continue Anyway" }
        return destinationLabel.isEmpty ? "Continue" : "Continue in \(destinationLabel)"
    }

    private func chooseDefaults() {
        if form.selection == nil || selected == nil { form.selection = model.preselectedConversation ?? model.conversations.first?.id }
        if form.destination.isEmpty || !destinations.contains(where: { $0.id == form.destination }) {
            form.destination = model.bestDestination(excluding: selected?.ownerID) ?? ""
        }
    }

    private func destinationTitle(_ status: ProfileStatus) -> String {
        let name = status.isMain ? "Claude (main)" : "Claude \(status.label)"
        if model.isAtLimit(status) { return name + " · limit reached" }
        guard let week = status.usage?.week else { return name }
        return name + " · \(week)% of week used"
    }

    private func explanation(_ conversation: Conversation) -> String {
        let to = "Claude \(destinationLabel.isEmpty ? "…" : destinationLabel)"
        let from = "Claude \(conversation.ownerID.map(model.label(of:)) ?? "")"
        switch conversation.kind {
        case .code:
            return "Opens this same session in \(to). Its history is shared by all your subscriptions, so nothing is copied."
        case .projectBranch:
            return "Opens this branch's history as a regular Code session in \(to). The Project and its other branches stay with \(from)."
        case .cowork:
            return "Starts a new Cowork task in \(to) with this task's history and files attached, for you to review and send. The original task, its connectors and schedules stay with \(from)."
        }
    }

    private func copyRequest() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Handoff.request, forType: .string)
        form.copied = true
    }

    private func go() {
        guard let conversation = selected else { return }
        if needsConfirmation && conversation.kind != .cowork { form.confirmedActive = conversation.id; return }
        form.working = true
        form.problem = nil
        let manager = model.manager
        let target = form.destination
        let label = destinationLabel
        Task {
            do {
                let result = try await manager.continueConversation(conversation, in: target)
                switch result {
                case .openedSession:
                    model.show(notice: "Opened “\(conversation.title)” in Claude \(label).")
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
}

struct ConversationRow: View {
    let conversation: Conversation
    let owner: String?

    private var icon: String {
        switch conversation.kind {
        case .code: "chevron.left.forwardslash.chevron.right"
        case .projectBranch: "arrow.triangle.branch"
        case .cowork: "sparkles"
        }
    }

    private var details: String {
        var parts: [String]
        switch conversation.kind {
        case .code: parts = ["Code"]
        case .projectBranch: parts = ["Project branch · \(owner ?? "")"]
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
                            Text("\(entry.localCode) local Code · \(entry.localCowork) Cowork cards · \(entry.accountBoundWorkers) account-linked workers")
                            Text("Remote Control: \(entry.remoteControlEnabled.map { $0 ? "enabled" : "disabled" } ?? "not recorded") · \(entry.listedRemoteFolders) listed folders")
                                .foregroundStyle(.secondary)
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
