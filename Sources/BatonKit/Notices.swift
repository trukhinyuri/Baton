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

/// What the footer says about opening windows: each window's warning from its last open, oldest first, so opening or
/// showing another window never hides one. A window's warning changes only when that window is opened again.
public struct OpenWarnings: Equatable, Sendable {
    struct Warning: Equatable, Sendable {
        var window: String
        var text: String
    }

    private var warnings: [Warning] = []

    public init() {}

    /// What an open of `window` left: its warning (`ProfileManager.openWarning(of:)`), or `nil`, which clears the
    /// one from its earlier open.
    public mutating func record(_ warning: String?, for window: String) {
        warnings.removeAll { $0.window == window }
        if let warning { warnings.append(Warning(window: window, text: warning)) }
    }

    /// Every window's warning, one after another; `nil` when there is none.
    public var text: String? { warnings.isEmpty ? nil : warnings.map(\.text).joined(separator: " ") }
}

extension SyncReport {
    /// What the app says after Share Sessions Now: what the sync did, or, with no report, that someone else is
    /// sharing right now.
    public static func notice(_ report: SyncReport?) -> String {
        guard let report else {
            return "Sessions are being shared by a launcher or `baton` right now. Baton shares them again within a minute."
        }
        switch report.changes {
        case 0: return "Sessions are shared: nothing new to copy."
        case 1: return "Sessions are shared: 1 change."
        default: return "Sessions are shared: \(report.changes) changes."
        }
    }
}
