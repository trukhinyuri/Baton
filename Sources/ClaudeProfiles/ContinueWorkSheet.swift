import AppKit
import ClaudeProfilesKit
import SwiftUI

@MainActor
final class ContinueWorkForm: ObservableObject {
    @Published var source = "main"
    @Published var destination = ""
    @Published var title = ""
    @Published var context = ""
    @Published var folder = ""
    @Published var sourceURL = ""
    @Published var message = ""
    @Published var opening = false
}

struct ContinueWorkSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = ContinueWorkForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Continue work in another profile").font(.title2.bold())
            Text("Local Code: stop the current turn, sync, then open the same session in your chosen profile. If it was already open, restart that Claude window after its tasks finish.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Share local sessions now") { model.syncNow() }
            }
            Divider()
            Text("Projects and Cowork: continue with context").font(.headline)
            Text("Cloud history stays with its account; local Cowork history and runtime stay in their original profile. Continue in a new conversation with reviewed context: ask the source Claude for a handoff, paste it below, and choose the destination. Files and connector access must be available there separately.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Copy handoff request for source Claude") {
                copy(Handoff.request); form.message = "Request copied. Paste it in the original conversation, then review and paste its answer below. If its limit is reached, use your own summary from the visible history and files."
            }
            HStack {
                Picker("From", selection: $form.source) { ForEach(model.statuses) { Text($0.label).tag($0.id) } }
                Picker("To", selection: $form.destination) {
                    Text("Choose a profile").tag("")
                    ForEach(model.statuses.filter { $0.isSignedIn }) { Text($0.label).tag($0.id) }
                }
            }
            TextField("Task title", text: $form.title)
            TextField("Original claude.ai conversation or project link (optional)", text: $form.sourceURL)
            TextField("Existing working folder, absolute path (optional)", text: $form.folder)
            Text("Reviewed context: objective, decisions, evidence, remaining work and next action").font(.caption)
            TextEditor(text: $form.context).frame(minHeight: 150).border(.separator)
            Text("Pause work in the source before continuing. Review what you share with the destination account. Nothing is sent automatically.")
                .font(.caption).foregroundStyle(.secondary)
            if !form.message.isEmpty { Text(form.message).font(.callout).textSelection(.enabled) }
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(form.opening ? "Opening…" : "Save handoff & open destination") { saveAndOpen() }
                    .buttonStyle(.borderedProminent)
                    .disabled(form.opening || form.title.isEmpty || form.context.isEmpty || form.destination.isEmpty || form.destination == form.source)
            }
        }
        .padding(22).frame(width: 680)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveAndOpen() {
        guard let target = model.statuses.first(where: { $0.id == form.destination && $0.isSignedIn }),
              let origin = model.statuses.first(where: { $0.id == form.source }) else { return }
        let handoff = Handoff(title: form.title, source: origin.label, destination: target.label,
                              context: form.context, folder: form.folder, sourceURL: form.sourceURL)
        do {
            let file = try handoff.save(paths: model.manager.paths)
            copy(handoff.prompt)
            form.message = "Saved to \(file.path). Continuation prompt copied. Paste it in a new conversation in \(target.label); review it before sending."
            form.opening = true
            Task {
                defer { form.opening = false }
                do {
                    if target.isMain { try await model.manager.openMain() }
                    else { try await model.manager.open(target.id) }
                    if !target.isMain, let warning = model.manager.lastOpenWarning { form.message += "\n" + warning }
                } catch { form.message += "\nThe profile could not be opened: \(error.localizedDescription). The handoff is saved." }
            }
        } catch { form.message = error.localizedDescription }
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
