import Foundation

// What the Continue work sheet lists, keeps selected and says, decided here so it can be tested without the app.

extension ConversationIndex {
    /// How many conversations the Continue sheet lists before a search narrows them down.
    public static let listLimit = 200

    /// The conversations the Continue sheet lists for `query` (by title or folder), and how many match in all: without
    /// a query only the `limit` most recent are listed, and the sheet says how many more there are.
    public static func listed(_ conversations: [Conversation], query: String, limit: Int = listLimit) -> (shown: [Conversation], matching: Int) {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return (Array(conversations.prefix(max(limit, 0))), conversations.count) }
        let matching = conversations.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(query) || conversation.folders.contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return (matching, matching.count)
    }

    /// The selection once the list shows only `shown`: kept while it is listed, otherwise the first listed one, so the
    /// Continue button never acts on a conversation the search has hidden.
    public static func selection(_ current: String?, in shown: [Conversation]) -> String? {
        if let current, shown.contains(where: { $0.id == current }) { return current }
        return shown.first?.id
    }

    /// "Showing the 200 most recent of 340. Search to find an older one."; `nil` when everything is listed.
    public static func listNote(shown: Int, matching: Int) -> String? {
        guard matching > shown else { return nil }
        return "Showing the \(shown) most recent of \(matching). Search to find an older one."
    }
}

extension DestinationRanking {
    /// Why the Continue sheet offers no window for a conversation from `source`, when no folder rule is the reason:
    /// there is no other subscription yet, or the others aren't signed in.
    public static func noDestinationReason(_ statuses: [ProfileStatus], source: String?) -> String {
        guard statuses.count > 1 else {
            return "There is no other subscription to continue in yet. Add one with “Add Subscription…” and sign in inside its window."
        }
        if let waiting = statuses.first(where: { $0.id != source && !$0.isSignedIn }) {
            return "No other window is signed in yet. Sign in inside the Claude \(waiting.displayLabel) window, then come back here."
        }
        return "No other signed-in window can take it. Add another subscription with “Add Subscription…” to continue it elsewhere."
    }
}

/// What the app says after Continue: every warning first, each once, then what Baton did, then the rest. The
/// warnings ask for something before the next message (choose a model, stop another window continuing it), so they
/// never come after a long session title where the text is cut, and none is dropped for another.
public enum ContinueNotice {
    /// - Parameters:
    ///   - result: "Baton passed to Claude WORK: …"
    ///   - leftOut: what was left to its own window, if anything.
    ///   - label: what follows "Claude " for the destination window.
    public static func compose(result: String, leftOut: String? = nil, plans: [ContinuePlan], label: String) -> (text: String, isWarning: Bool) {
        func once(_ messages: [String]) -> [String] { messages.reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
        let autoResume = plans.flatMap(\.autoResume)
        let warnings = once(
            autoResume.filter(\.isWarning).map { $0.message() }
                + plans.compactMap(\.model).filter(\.isWarning).map { $0.message(destination: label) })
        let notes = once(autoResume.filter { !$0.isWarning }.map { $0.message() })
        let parts = warnings + [result] + (leftOut.map { [$0] } ?? []) + notes
        return (parts.joined(separator: " "), !warnings.isEmpty)
    }
}
