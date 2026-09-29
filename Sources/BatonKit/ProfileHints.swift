import Foundation

/// What Add Subscription says under a field it won't accept, so a greyed-out Create button always has a reason.
extension Profile {
    /// `nil` while the field is empty or the address is complete.
    public static func emailHint(_ email: String) -> String? {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isValidEmail(trimmed) else { return nil }
        return "Enter the full email address, like you@example.com."
    }

    /// `nil` while the field is empty or the label can be used.
    public static func labelHint(_ label: String, taken: Set<String>) -> String? {
        guard !label.isEmpty else { return nil }
        if taken.contains(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) { return "Already used by another subscription." }
        return isValidLabel(label) ? nil : "Use 1–\(maxLabelLength) letters, digits, “-” or “_”."
    }
}
