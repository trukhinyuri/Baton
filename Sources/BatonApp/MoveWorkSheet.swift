import BatonKit
import SwiftUI

@MainActor
final class MoveWorkForm: ObservableObject {
    /// The window whose work moves.
    @Published var source = ""
    /// Where it goes: the window with the most room, or the one picked with “Change”.
    @Published var destination: String?
    /// The window with the most room, as the plan first chose it.
    @Published var best: String?
    @Published var plan: HandoverPlan?
    @Published var problem: String?
    @Published var isPlanning = false
}

/// “Continue work…”: the sessions that will move from one window, and one button that moves them to the window with
/// the most room, as a handover at a limit does. The window can be changed with a small “Change” link; nothing else is
/// asked. Single sessions and the choice of same session or copy stay in the CLI (`baton continue`).
struct MoveWorkSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = MoveWorkForm()

    /// One row of the list: a session that moves, or what stays and why.
    struct Row: Identifiable {
        var id: String
        var title: String
        var detail: String
        var resumes = false
        var stays = false
    }

    private var rows: [Row] {
        if model.isDemo { return DemoData.moveRows }
        guard let plan = form.plan else { return [] }
        let later = Set(plan.resumeInSource.map(\.card))
        let moving = plan.sessions.sorted { ($0.cut ? 0 : 1, $1.lastActivity) < ($1.cut ? 0 : 1, $0.lastActivity) }.map { session in
            let folder = session.folders.first.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "No folder"
            let how =
                later.contains(session.card)
                ? (session.asCopy
                    ? " · keeps running in \(model.displayLabel(of: plan.source)) and continues there at its reset; its copy moves"
                    : " · continues in \(model.displayLabel(of: plan.source)) at its reset")
                : session.asCopy ? " · continues as a copy" : ""
            return Row(id: session.card, title: session.title, detail: folder + how, resumes: session.cut && !later.contains(session.card))
        }
        let source = model.displayLabel(of: plan.source), destination = model.displayLabel(of: plan.destination)
        let staying = plan.leftovers.enumerated().compactMap { index, leftover -> Row? in
            guard case .copies = leftover else {
                return HandoverText.clause(leftover, source: source, destination: destination).map {
                    Row(id: "stays-\(index)", title: HandoverText.capitalized($0), detail: "", stays: true)
                }
            }
            return nil  // the copies are marked in their own rows
        }
        return moving + staying
    }

    /// Windows the work may go to instead: signed in, with room, and allowed by the folder rules for every session to
    /// resume, or all with room when none is.
    private var others: [ProfileStatus] {
        let room = model.statuses.filter { $0.isSignedIn && $0.id != form.source && !model.isAtLimit($0) }
        let folders = form.plan?.cut.map(\.folders) ?? []
        let allowed = room.filter { status in
            folders.allSatisfy { DestinationRanking.isAllowed(status, accounts: model.allowedAccounts(for: $0)?.accounts) }
        }
        return allowed.isEmpty ? room : allowed
    }

    private var destinationLabel: String { form.destination.map(model.displayLabel(of:)) ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Continue work").font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text(
                "The work of Claude \(model.displayLabel(of: form.source)) continues in the window with the most room: its sessions open there, and those its limit cut pick up where they stopped."
            )
            .font(.callout).foregroundStyle(Color.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            List(rows) { row in
                HStack(spacing: 10) {
                    Image(systemName: row.stays ? "pin" : "chevron.left.forwardslash.chevron.right")
                        .foregroundStyle(.secondary).frame(width: 20).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).lineLimit(row.stays ? 2 : 1).truncationMode(.tail)
                        if !row.detail.isEmpty {
                            Text(row.detail).font(.caption).foregroundStyle(Color.secondaryText).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer()
                    if row.resumes { Text("resumes").font(.caption.weight(.medium)).foregroundStyle(Color.secondaryText) }
                }
                .foregroundStyle(row.stays ? Color.secondaryText : Color.primary)
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .accessibilityLabel("Sessions that move")
            .frame(minHeight: 200)
            .overlay {
                if form.isPlanning && rows.isEmpty {
                    ProgressView("Looking for the work…")
                } else if rows.isEmpty, form.problem == nil {
                    Text("Nothing to move: Claude \(model.displayLabel(of: form.source)) has no local sessions.").foregroundStyle(Color.secondaryText)
                }
            }

            if let plan = form.plan {
                Text(HandoverText.summary(plan, labels: model.displayLabel(of:)))
                    .font(.callout).foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = form.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Color.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Divider()
            HStack(spacing: 8) {
                Spacer()
                if form.plan != nil || model.isDemo, others.count > 1 {
                    Menu("Change") {
                        ForEach(others) { status in
                            Button("Claude \(status.displayLabel)" + (status.id == form.best ? " (most room)" : "")) { choose(status.id) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Continue in another window than the one with the most room")
                }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(destinationLabel.isEmpty ? "Continue" : "Continue in \(destinationLabel)") { go() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.isDemo && (form.plan == nil || form.isPlanning || (form.plan?.sessions.isEmpty ?? true)))
            }
        }
        .padding(22)
        .frame(minWidth: 640, idealWidth: 700, minHeight: 460, idealHeight: 560)
        .onAppear {
            form.source = model.moveSource
            if model.isDemo {
                form.destination = model.bestDestination(excluding: form.source)
                form.best = form.destination
            } else {
                plan(to: nil)
            }
        }
    }

    private func choose(_ destination: String) {
        guard destination != form.destination else { return }
        plan(to: destination)
    }

    /// Plans the move off the main thread: it reads every session of the source.
    private func plan(to destination: String?) {
        let manager = model.manager, source = form.source
        form.isPlanning = true
        form.problem = nil
        Task {
            do {
                let plan = try await Task.detached { try manager.planMove(from: source, to: destination) }.value
                form.plan = plan
                form.destination = plan.destination
                if destination == nil { form.best = plan.destination }
            } catch {
                form.problem = error.localizedDescription
            }
            form.isPlanning = false
        }
    }

    private func go() {
        guard let destination = form.destination, form.plan != nil, !model.isDemo else { return dismiss() }
        model.move(from: form.source, to: destination)
        dismiss()
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
