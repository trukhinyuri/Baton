import BatonKit
import SwiftUI

@MainActor
final class AddProfileForm: ObservableObject {
    @Published var email = "" { didSet { if !labelEdited { label = suggestedLabel } } }
    @Published var label = ""
    @Published var color: String
    var labelEdited = false
    /// The email field has had the focus and lost it, so its hint may show before an “@” is typed.
    @Published var emailLeft = false
    let taken: Set<String>

    init(taken: Set<String>) {
        self.taken = taken
        self.color = Profile.palette[taken.count % Profile.palette.count]
    }

    var trimmedEmail: String { email.trimmingCharacters(in: .whitespaces) }
    var suggestedLabel: String { trimmedEmail.isEmpty ? "" : Profile.suggestedLabel(for: trimmedEmail, taken: taken) }
    var isValid: Bool { Profile.isValidEmail(trimmedEmail) && Profile.isValidLabel(label) && labelHint == nil }
    var emailHint: String? { Profile.emailHint(email, isTyping: !emailLeft) }
    var labelHint: String? { Profile.labelHint(label, taken: taken, isEdited: labelEdited) }
}

struct AddProfileSheet: View {
    @ObservedObject var model: AppModel
    @StateObject private var form: AddProfileForm
    @Environment(\.dismiss) private var dismiss
    @FocusState private var emailIsFocused: Bool

    init(model: AppModel) {
        self.model = model
        _form = StateObject(wrappedValue: AddProfileForm(taken: model.existingLabels))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                DockIconPreview(label: form.label.isEmpty ? "NEW" : form.label.uppercased(), color: form.color)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add Subscription").font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("A new Claude window opens with its own Dock icon. Sign in there with this account, with Google or with email.")
                        .font(.callout)
                        .foregroundStyle(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                // Each field says why it holds Create and Open back, so the button is never grey without a reason.
                GridRow {
                    Text("Email").gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("you@example.com", text: $form.email)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Email")
                            .accessibilityHint(form.emailHint ?? "")
                            .textContentType(.emailAddress)
                            .focused($emailIsFocused)
                            .onChange(of: emailIsFocused) { if !emailIsFocused { form.emailLeft = true } }
                            .onSubmit(create)
                        if let hint = form.emailHint {
                            Text(hint).font(.caption).foregroundStyle(Color.secondaryText)
                        }
                    }
                }
                GridRow {
                    Text("Dock label")
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField(
                                "WORK",
                                text: Binding(
                                    get: { form.label },
                                    set: {
                                        // The field stops taking letters at the limit: the count says why, and
                                        // VoiceOver, which doesn't read the count, says it when a letter is dropped.
                                        if $0.count > Profile.maxLabelLength {
                                            AppModel.announce("A Dock label takes up to \(Profile.maxLabelLength) characters.")
                                        }
                                        form.label = String($0.uppercased().prefix(Profile.maxLabelLength)); form.labelEdited = true
                                    })
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 100, maxWidth: 140)
                            .accessibilityLabel("Dock label, up to \(Profile.maxLabelLength) characters")
                            .accessibilityHint(form.labelHint ?? "")
                            Text("\(form.label.count) of \(Profile.maxLabelLength)")
                                .font(.caption).monospacedDigit().foregroundStyle(Color.secondaryText)
                                .accessibilityHidden(true)
                        }
                        if let hint = form.labelHint {
                            Text(hint).font(.caption).foregroundStyle(Color.warningText)
                        }
                    }
                }
                GridRow {
                    Text("Color")
                    HStack(spacing: 8) {
                        ForEach(Profile.palette, id: \.self) { hex in
                            Button {
                                form.color = hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 20, height: 20)
                                    .overlay(Circle().strokeBorder(.white, lineWidth: form.color == hex ? 2 : 0))
                                    .overlay(Circle().strokeBorder(Color(hex: hex), lineWidth: form.color == hex ? 1 : 0).padding(-2))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Self.colorName(hex))
                            .accessibilityAddTraits(form.color == hex ? .isSelected : [])
                            .help(Self.colorName(hex))
                        }
                    }
                }
            }

            Label("Baton never sees your password, codes or tokens: you sign in inside the official Claude app.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create and Open", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!form.isValid)
            }
        }
        .padding(22)
        .frame(minWidth: 440, idealWidth: 480)
    }

    /// Names VoiceOver reads for `Profile.palette`, in the same order.
    static func colorName(_ hex: String) -> String {
        let names = ["Blue", "Green", "Violet", "Teal", "Pink", "Orange", "Lime", "Purple"]
        return Profile.palette.firstIndex(of: hex).map { names[$0] } ?? "Color \(hex)"
    }

    private func create() {
        guard form.isValid else { return }
        let (email, label, color) = (form.trimmedEmail, form.label, form.color)
        dismiss()
        model.create(email: email, label: label, color: color)
    }
}

/// Shows the Dock icon the new profile will get, drawn from the locally installed Claude app. Demo mode, which takes
/// the README's pictures, draws it on a neutral placeholder instead, so no published picture shows Claude's icon.
struct DockIconPreview: View {
    let label: String
    let color: String

    var body: some View {
        let base = DemoMode.isOn() ? IconRenderer.placeholderBase() : NSWorkspace.shared.icon(forFile: "/Applications/Claude.app")
        Image(nsImage: IconRenderer.profileIcon(base: base, label: label, color: NSColor(hex: color)))
            .resizable()
            .interpolation(.high)
            .frame(width: 72, height: 72)
            .accessibilityLabel("Dock icon preview")
    }
}
