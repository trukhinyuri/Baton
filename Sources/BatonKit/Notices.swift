import Foundation

/// What the main window's banner shows: the result of the last action. A warning asks for something (choose a model,
/// stop another window continuing a session), so it stays until it is dismissed. A later notice that is not a warning
/// shows over it until that one goes, and then the warning shows again, so no warning is lost unread.
public struct Notices: Equatable, Sendable {
    /// Warnings not dismissed yet, oldest first.
    private var warnings: [String] = []
    /// The newest notice that is not a warning, until it is dismissed or goes by itself.
    private var passing: String?

    public init() {}

    /// What the banner shows; `nil` for no banner.
    public var current: (text: String, isWarning: Bool)? {
        if let passing { return (passing, false) }
        return warnings.last.map { ($0, true) }
    }

    public mutating func show(_ text: String, isWarning: Bool) {
        guard isWarning else {
            passing = text
            return
        }
        warnings.removeAll { $0 == text }
        warnings.append(text)
        passing = nil
    }

    /// Closes what the banner shows; the warning under it, if any, shows again.
    public mutating func dismiss() {
        if passing != nil {
            passing = nil
        } else if !warnings.isEmpty {
            warnings.removeLast()
        }
    }

    /// A notice that is not a warning goes by itself after a while: `text` goes if it is still the one showing.
    public mutating func expire(_ text: String) {
        if passing == text { passing = nil }
    }
}
