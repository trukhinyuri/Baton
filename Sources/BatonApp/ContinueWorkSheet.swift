import BatonKit
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
    /// The source window resets within minutes and continues the session by itself: offered before continuing.
    @Published var offer: AutoResumeOffer?
    /// Whether the offer came from “Continue All”.
    @Published var offerForAll = false
    /// The sheet has closed while a Continue was still running, so its result goes to the window instead.
    @Published var isGone = false
}

struct ContinueWorkSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = ContinueWorkForm()

    /// How far back “Continue All” looks for sessions in the selected session's folder.
    static let folderWindow: TimeInterval = 24 * 3600

    private var listing: (shown: [Conversation], matching: Int) { ConversationIndex.listed(model.conversations, query: form.search) }

    private var filtered: [Conversation] { listing.shown }

    /// Only a listed conversation: one the search has hidden is never what Continue acts on. Found by id, since the
    /// sheet reads it many times per update.
    private var selected: Conversation? {
        ConversationIndex.listedConversation(form.selection, in: model.conversations, query: form.search)
    }

    /// The window the selected conversation belongs to or last ran in: never offered for it.
    private var source: String? { selected.flatMap { $0.ownerID ?? $0.runningIn } }

    /// The accounts the folder rules allow for the selected conversation; `nil` when no rule applies.
    private var allowed: (accounts: Set<String>, rules: [FolderRule])? {
        selected.flatMap { model.allowedAccounts(for: $0.folders) }
    }

    /// Signed-in windows the selected conversation can move to, within its folder rule.
    private var destinations: [ProfileStatus] {
        model.statuses.filter {
            $0.isSignedIn && $0.id != source && DestinationRanking.isAllowed($0, accounts: allowed?.accounts)
        }
    }

    /// Why no window is offered, when a folder rule leaves none.
    private var ruleNote: String? {
        guard let allowed, destinations.isEmpty else { return nil }
        let folders = allowed.rules.map { ($0.folder as NSString).abbreviatingWithTildeInPath }.joined(separator: " and ")
        guard model.folderRules != nil else { return "The folder rules can't be read, so nothing continues until they are fixed." }
        return
            "Work in \(folders) continues only in \(allowed.accounts.sorted().joined(separator: " or ")), and no window is signed in with it. Add that account with “Add Subscription”, or change the rule with `baton rule`."
    }

    /// What follows "Claude " for the chosen window: "(main)" or its label; empty while none is chosen.
    private var destinationLabel: String { model.statuses.first { $0.id == form.destination }?.displayLabel ?? "" }

    /// The chosen window on a button: "Claude (main)" or "Claude WORK".
    private var destinationButton: String { form.destination.isEmpty ? "" : model.buttonLabel(of: form.destination) }

    private var forks: Bool { selected.map { form.mode.forks($0) } ?? false }

    /// The same session is about to continue elsewhere although its window may still write to it.
    private func needsStop(_ conversation: Conversation) -> Bool {
        !form.mode.forks(conversation) && conversation.mayStillWrite() && form.stopped != conversation.id
    }

    private var folder: String? { selected?.kind == .cowork ? nil : selected?.folders.first }

    /// The most recent Code sessions in the selected session's folder from the last day, how many more there are, and
    /// how many are open in the chosen window already.
    private var folderSelection: (batch: [Conversation], leftOut: Int, alreadyThere: Int) {
        guard let folder else { return ([], 0, 0) }
        return ConversationIndex.continueAllBatch(
            in: folder, since: Date().addingTimeInterval(-Self.folderWindow),
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
            // Filtered once per update: with thousands of sessions each pass takes milliseconds.
            let listing = self.listing
            Text("Continue work").font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Pick a session and the window that runs the next leg. That window opens it for you; nothing is sent on your behalf.")
                .font(.callout).foregroundStyle(Color.secondaryText)

            TextField("Search conversations", text: $form.search)
                .textFieldStyle(.roundedBorder)

            List(selection: $form.selection) {
                ForEach(listing.shown) { conversation in
                    ConversationRow(
                        conversation: conversation, owner: conversation.ownerID.map(model.buttonLabel(of:)),
                        isSelected: conversation.id == form.selection
                    )
                    .tag(conversation.id)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .accessibilityLabel("Conversations")
            .frame(minHeight: 170)
            .overlay {
                if model.isLoadingConversations && model.conversations.isEmpty {
                    ProgressView("Looking for conversations…")
                } else if listing.shown.isEmpty {
                    Text(form.search.isEmpty ? "Nothing to hand off yet: there are no local conversations." : "Nothing matches “\(form.search)”.")
                        .foregroundStyle(Color.secondaryText)
                }
            }
            if let note = ConversationIndex.listNote(shown: listing.shown.count, matching: listing.matching) {
                Text(note).font(.caption).foregroundStyle(Color.secondaryText)
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
                    .fixedSize()
                    .help(
                        "Automatic continues sessions still open in a running Claude Code process and sessions with a message in the last 10 minutes as a copy, so two windows never write to one session, and others as the same session."
                    )
                }
            }

            if selected != nil, destinations.isEmpty, ruleNote == nil {
                // Nothing to choose, and no folder rule to blame: say what is missing.
                Label(DestinationRanking.noDestinationReason(model.statuses, source: source), systemImage: "info.circle")
                    .font(.callout).foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let selected {
                Text(explanation(selected)).font(.callout).foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = form.plan?.model, form.plan?.conversation.id == selected.id, form.plan?.destination == form.destination {
                    Label(note.message(destination: destinationLabel), systemImage: note.isWarning ? "exclamationmark.triangle" : "cpu")
                        .font(.callout).foregroundStyle(note.isWarning ? Color.warningText : Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let notes = form.plan?.autoResume, form.plan?.conversation.id == selected.id, form.plan?.destination == form.destination {
                    ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                        Label(note.message(), systemImage: note.isWarning ? "exclamationmark.triangle" : "arrow.uturn.forward")
                            .font(.callout).foregroundStyle(note.isWarning ? Color.warningText : Color.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if selected.kind == .cowork && selected.isActive() {
                    Label(
                        "This task was working less than a minute ago; the attached history may miss its last steps.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout).foregroundStyle(Color.warningText)
                } else if selected.kind != .cowork && !forks && selected.mayStillWrite() {
                    HStack(spacing: 8) {
                        Label(
                            (selected.hasLiveProcess
                                ? "It's open in a running Claude Code process" : "It had a message \(relativeAge(since: selected.lastActivity))")
                                + ", so its window may still write to it. Close it there first, so two windows don't write to one session, or continue as a copy.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.callout).foregroundStyle(Color.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                        Toggle(
                            "I closed it",
                            isOn: Binding(
                                get: { form.stopped == selected.id },
                                set: { form.stopped = $0 ? selected.id : nil })
                        )
                        .toggleStyle(.checkbox)
                    }
                }
            }
            if let ruleNote { Text(ruleNote).font(.callout).foregroundStyle(Color.warningText).fixedSize(horizontal: false, vertical: true) }
            if let problem = form.problem {
                // As the report sheet shows its problem: system red is about 3.5:1 on a light sheet.
                Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Color.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if let folder, !folderBatch.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(
                        "\(folderBatch.count) in \((folder as NSString).lastPathComponent) from the last day"
                            + (folderSelection.leftOut > 0 ? ", the most recent; \(folderSelection.leftOut) older left out" : "")
                            + (folderSelection.alreadyThere > 0
                                ? "; \(folderSelection.alreadyThere) already in Claude \(destinationLabel.isEmpty ? "…" : destinationLabel)" : "")
                    )
                    .lineLimit(1).truncationMode(.middle)
                    .help(folderBatch.map(\.title).joined(separator: "\n"))
                    Toggle("Also start a new session there", isOn: $form.alsoNewSession).toggleStyle(.checkbox)
                    Spacer()
                    Button("Continue All in \(destinationButton.isEmpty ? "…" : destinationButton)") { goAll() }
                        .disabled(form.working || form.destination.isEmpty || batchNeedsStop || !batchAllowed)
                        .help(
                            !batchAllowed && !form.destination.isEmpty
                                ? "A folder rule doesn't let Claude \(destinationLabel) take all of them."
                                : batchNeedsStop
                                    ? "Some of them may still be written to in their window. Choose Automatic or As a copy, or close them there first."
                                    : "Hands the \(ConversationIndex.continueAllLimit) most recent Code sessions of this folder (with a message in the last day) to that window in one go: the whole relay team, not just one runner. Older ones continue one at a time."
                        )
                }
                .font(.callout)
            }

            Divider()
            HStack(spacing: 8) {
                if form.working {
                    // Up to `importWait` while the window imports it: Cancel waits too, since the handover goes on anyway.
                    ProgressView().controlSize(.small)
                    Text("Waiting for Claude \(destinationLabel.isEmpty ? "…" : destinationLabel) to open it…")
                        .font(.callout).foregroundStyle(Color.secondaryText)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(form.working)
                Button(primaryTitle) { go() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        form.working || selected == nil || form.destination.isEmpty
                            || !destinations.contains { $0.id == form.destination } || selected.map(needsStop) == true)
            }
        }
        .padding(22)
        .frame(minWidth: 700, idealWidth: 780, minHeight: 540, idealHeight: 590)
        .interactiveDismissDisabled(form.working)
        .onAppear {
            model.loadConversations()
            chooseDefaults()
            refreshPlan()
        }
        .onDisappear { form.isGone = true }
        .onChange(of: form.search) { form.selection = ConversationIndex.selection(form.selection, in: filtered) }
        .onChange(of: model.conversations) {
            chooseDefaults(); refreshPlan()
        }
        .onChange(of: form.selection) {
            form.problem = nil
            if !destinations.contains(where: { $0.id == form.destination }) {
                form.destination = model.bestDestination(excluding: source, accounts: allowed?.accounts) ?? ""
            }
            refreshPlan()
        }
        .onChange(of: form.destination) { refreshPlan() }
        .onChange(of: form.mode) { refreshPlan() }
        .alert(
            "The limit resets soon", isPresented: Binding(get: { form.offer != nil }, set: { if !$0 { form.offer = nil } }),
            presenting: form.offer
        ) { offer in
            Button("Wait") { wait(offer) }.keyboardShortcut(.defaultAction)
            Button("Continue Now") {
                form.offer = nil
                if form.offerForAll { goAll(now: true) } else { go(now: true) }
            }
        } message: { offer in
            Text(offer.message())
        }
    }

    /// Leaves the session to its own window, which picks it up after the reset; nothing is changed.
    private func wait(_ offer: AutoResumeOffer) {
        form.offer = nil
        model.show(notice: offer.message())
        dismiss()
    }

    /// The offer to wait, when the source window resets within minutes and would continue the work by itself.
    private func offer(for conversations: [Conversation], in target: String) async -> AutoResumeOffer? {
        guard !model.isDemo else { return nil }
        let manager = model.manager
        return await Task.detached { manager.autoResumeOffer(for: conversations, in: target) }.value
    }

    private var batchNeedsStop: Bool { form.mode == .same && folderBatch.contains { $0.mayStillWrite() } }

    private var primaryTitle: String {
        if form.working { return "Opening…" }
        let to = destinationButton.isEmpty ? "" : " in \(destinationButton)"
        guard let selected, selected.kind != .cowork else { return "Continue" + to }
        if forks { return "Continue as a Copy" + to }
        if selected.mayStillWrite() { return "Continue Same Session" + to }
        return "Continue" + to
    }

    private func chooseDefaults() {
        if selected == nil { form.selection = ConversationIndex.selection(model.preselectedConversation, in: filtered) }
        if form.destination.isEmpty || !destinations.contains(where: { $0.id == form.destination }) {
            form.destination = model.bestDestination(excluding: source, accounts: allowed?.accounts) ?? ""
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
        let name = "Claude \(status.displayLabel)"
        if model.isAtLimit(status) {
            return name + " · " + LimitText.atLimit(status.limits) + (LimitText.checkHint(status) == nil ? "" : " (open it to check)")
        }
        guard status.usage != nil else { return name }
        return name + " · " + LimitText.summary(status.limits, usage: status.usage, fullNames: true)
    }

    private func explanation(_ conversation: Conversation) -> String {
        let to = "Claude \(destinationLabel.isEmpty ? "…" : destinationLabel)"
        let from = "Claude \(conversation.ownerID.map(model.displayLabel(of:)) ?? "")"
        let why =
            form.mode == .auto && conversation.kind == .code
            ? (conversation.hasLiveProcess ? " It's open in a running Claude Code process." : " It had a message in the last 10 minutes.") : ""
        switch (conversation.kind, forks) {
        case (.code, false):
            return "Opens this same session in \(to). Its history is shared by all your subscriptions, so nothing is copied."
        case (.code, true):
            return "Opens a copy of this session with its whole history in \(to). The original stays as it is, so its window can keep working on it.\(why)"
        case (.cowork, _):
            return
                "Starts a new Cowork task in \(to) with this task's history and files attached, for you to review and send. The original task, its connectors and schedules stay with \(from)."
        }
    }

    /// A problem in the sheet, read out by VoiceOver; in the window if the sheet has closed meanwhile.
    private func report(_ problem: String) {
        if form.isGone {
            model.show(notice: problem, isWarning: true)
            return
        }
        form.problem = problem
        AppModel.announce(problem)
    }

    private func go(now: Bool = false) {
        guard let conversation = selected, !needsStop(conversation) else { return }
        form.working = true
        form.problem = nil
        let manager = model.manager
        let target = form.destination
        let label = destinationLabel
        let mode = form.mode
        let anyway = form.stopped == conversation.id
        Task {
            if !now, let offer = await offer(for: [conversation], in: target) {
                form.offerForAll = false
                form.offer = offer
                form.working = false
                return
            }
            do {
                switch try await manager.continueConversation(conversation, in: target, mode: mode, anyway: anyway) {
                case .openedSession(let plan):
                    guard plan.opened != false else {
                        report(
                            "“\(conversation.title)” did not show up in Claude \(label) within \(Int(manager.importWait)) s. Look for it in its sidebar, or try again with the window open."
                        )
                        form.working = false
                        return
                    }
                    let result =
                        plan.forks
                        ? "Baton passed to Claude \(label): a copy of “\(conversation.title)” is open there."
                        : "Baton passed to Claude \(label): “\(conversation.title)” is open there."
                    let notice = ContinueNotice.compose(result: result, plans: [plan], label: label)
                    model.show(notice: notice.text, isWarning: notice.isWarning)
                case .startedCoworkTask:
                    model.show(notice: "A new Cowork task with the history attached is waiting in Claude \(label). Review it and send it there.")
                }
                model.preselectedConversation = nil
                dismiss()
            } catch {
                report(error.localizedDescription)
            }
            form.working = false
        }
    }

    private func goAll(now: Bool = false) {
        guard let folder, !batchNeedsStop else { return }
        var batch = folderBatch
        form.working = true
        form.problem = nil
        let manager = model.manager
        let target = form.destination
        let label = destinationLabel
        let mode = form.mode
        let newSession = form.alsoNewSession ? folder : nil
        Task {
            // Sessions their own window picks up within minutes are left there; the rest continue. Only when that is
            // all of them is there nothing to do but offer to wait.
            var waiting: AutoResumeOffer?
            if !now, let offer = await offer(for: batch, in: target) {
                let split = ConversationIndex.splitForWait(batch, offer: offer, alsoNewSession: newSession != nil)
                guard !split.stop else {
                    form.offerForAll = true
                    form.offer = offer
                    form.working = false
                    return
                }
                batch = split.continuing
                waiting = offer
            }
            do {
                let plans = try await manager.continueAll(batch, in: target, mode: mode, newSessionIn: newSession)
                let missing = plans.filter { $0.opened == false }
                guard missing.isEmpty else {
                    report(
                        "\(missing.count) of \(plans.count) did not show up in Claude \(label) within \(Int(manager.importWait)) s: "
                            + missing.map { "“\($0.conversation.title)”" }.joined(separator: ", ")
                            + ". The others opened; continue these again with the window open.")
                    form.working = false
                    model.loadConversations()
                    return
                }
                let notice = ContinueNotice.compose(
                    result: ConversationIndex.passedNotice(
                        label: label, opened: plans.count, copies: plans.filter(\.forks).count, newSession: newSession != nil),
                    leftOut: waiting.map { "Left out \($0.names): " + $0.message() }, plans: plans, label: label)
                model.show(notice: notice.text, isWarning: notice.isWarning)
                model.preselectedConversation = nil
                dismiss()
            } catch {
                report(error.localizedDescription)
            }
            form.working = false
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    let owner: String?
    let isSelected: Bool

    /// The details and time: on a selected row in the title's colour, which the system keeps readable on the blue of a
    /// focused list and the grey of an unfocused one (`TextColors.rowDetail`).
    private var detailStyle: AnyShapeStyle {
        TextColors.rowDetail(isSelected: isSelected).map { AnyShapeStyle(Color(nsColor: .adaptive($0))) } ?? AnyShapeStyle(.primary)
    }

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
            // A fixed column, so Code and Cowork titles start at the same place.
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title).lineLimit(1).truncationMode(.tail)
                Text(details).font(.caption).foregroundStyle(detailStyle).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(conversation.lastActivity, format: .relative(presentation: .named))
                .font(.caption).foregroundStyle(detailStyle)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct DiagnosticsSheet: View {
    let entries: [Diagnostics.Entry]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check sessions").font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text(
                "Local inventory only. Cloud Projects stay in their account, and Cowork history stays in its original account or in its subscription's local data. A copied Cowork card does not prove its history can open. This check does not verify cloud access or change settings."
            )
            .font(.callout).foregroundStyle(Color.secondaryText)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.label).font(.headline).accessibilityAddTraits(.isHeader)
                            Text("\(entry.localCode) local Code · \(entry.localCowork) Cowork cards")
                            ForEach(entry.issues, id: \.self) { Text($0).foregroundStyle(Color.warningText) }
                            ForEach(entry.missingFolders, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding(22).frame(minWidth: 600, idealWidth: 700, minHeight: 420, idealHeight: 510)
    }
}
