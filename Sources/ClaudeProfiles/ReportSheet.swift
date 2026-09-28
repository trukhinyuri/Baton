import AppKit
import ClaudeProfilesKit
import SwiftUI

/// Shows the exact text of a problem report before anything leaves the app. Nothing is sent from here: Open GitHub
/// hands a prefilled form to the browser, where the user reviews it again and submits it themselves.
@MainActor
final class ReportForm: ObservableObject {
    @Published var report: FeedbackReport?
    @Published var title = ""
    @Published var description = ""
    @Published var note: String?
}

struct ReportSheet: View {
    @ObservedObject var model: AppModel
    @StateObject private var form = ReportForm()
    @Environment(\.dismiss) private var dismiss

    private var text: String { form.report?.document(description: form.description) ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Report a problem").font(.title2.bold())
            Text("Below is exactly what will be shared. Emails, account IDs, profile labels, folder names, session titles and your username are taken out. Nothing is sent until you submit the issue on GitHub yourself.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Summary", text: $form.title, prompt: Text("One line: what went wrong"))
                .textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 4) {
                Text("What happened — shared as you type it, not redacted").font(.callout)
                TextEditor(text: $form.description)
                    .font(.callout)
                    .frame(minHeight: 60, idealHeight: 80)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                    .accessibilityLabel("What happened, not redacted")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Report").font(.callout)
                ScrollView {
                    Text(form.report == nil ? "Collecting…" : text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(RoundedRectangle(cornerRadius: 5).fill(.background.secondary))
                .frame(minHeight: 160)
                .accessibilityLabel("Report text")
            }
            if let note = form.note {
                Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack(spacing: 8) {
                Button("Copy") { copy(text); form.note = "Copied the report." }
                Button("Save…", action: save)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open GitHub", action: openGitHub)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .help("Opens a prefilled issue form in your browser. You review it there and submit it yourself.")
            }
            .disabled(form.report == nil)
        }
        .padding(22)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 520, idealHeight: 640)
        .task { form.report = await model.makeReport() }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Claude Profiles report.md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(text.utf8).write(to: url)
            form.note = "Saved to \((url.path as NSString).abbreviatingWithTildeInPath)."
        } catch { model.show(error) }
    }

    private func openGitHub() {
        guard let report = form.report else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? model.manager.paths.home
        do {
            let shared = try report.share(title: form.title, description: form.description, saveIn: downloads, copy: copy,
                                          open: { NSWorkspace.shared.open($0) })
            if let file = shared.file {
                form.note = "The report is too long for the link, so the form has a summary. The full report is on the clipboard and saved as “\(file.lastPathComponent)” in Downloads: attach it to the issue."
                NSWorkspace.shared.activateFileViewerSelecting([file])
            } else {
                form.note = "Opened the issue form in your browser. Review it there and submit it yourself."
            }
        } catch { model.show(error) }
    }
}
