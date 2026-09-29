import Foundation

/// What Add Subscription says under a field it won't accept, so a greyed-out Create button always has a reason.
extension Profile {
    /// `nil` while the field is empty or the address is complete, and while it is being typed with no “@” yet, so
    /// the hint doesn't show from the first letter.
    public static func emailHint(_ email: String, isTyping: Bool = false) -> String? {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isValidEmail(trimmed), !isTyping || trimmed.contains("@") else { return nil }
        return "Enter the full email address, like you@example.com."
    }

    /// `nil` while the label can be used, and while it is empty and still the suggested one: one emptied by hand says
    /// that a label is needed.
    public static func labelHint(_ label: String, taken: Set<String>, isEdited: Bool = false) -> String? {
        guard !label.isEmpty else { return isEdited ? "Enter a Dock label: 1–\(maxLabelLength) letters, digits, “-” or “_”." : nil }
        if taken.contains(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) { return "Already used by another subscription." }
        if isReservedLabel(label) { return "\(label.trimmingCharacters(in: .whitespaces).uppercased()) is reserved for the main Claude window." }
        return isValidLabel(label) ? nil : "Use 1–\(maxLabelLength) letters, digits, “-” or “_”."
    }
}
