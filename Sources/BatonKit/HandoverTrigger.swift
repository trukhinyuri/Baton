import Foundation

/// When the app hands a window's work over by itself: a window that is open, at its limit, whose limit was reached in
/// its sessions within the last half hour (the user was working there), not handed over for this limit yet, and not
/// waited for (`waitedFor`: Claude's own auto-continue picks its work up there at the reset).
public enum HandoverTrigger {
    /// A limit that resets this soon, by Claude's own reset time, isn't handed over: Baton waits, and the window
    /// continues its work then.
    public static let waitsFor: TimeInterval = 30 * 60

    /// The reset Baton waits for instead of handing the work over: the binding limit's, when it is Claude's own reset
    /// time (`LimitReset.Source.exact`) and still ahead, within `waitsFor`. An estimate, or a time already past, is
    /// handed over as usual.
    public static func waitedFor(_ limits: Limits, now: Date = Date()) -> Date? {
        guard let reset = limits.binding(now: now)?.reset, reset.source == .exact else { return nil }
        let left = reset.at.timeIntervalSince(now)
        return left > 0 && left <= waitsFor ? reset.at : nil
    }

    /// A limit reached longer ago than this was not reached while the user worked there.
    public static let recent: TimeInterval = 30 * 60

    /// The windows whose work to hand over now, in the order of `statuses`.
    /// - Parameters:
    ///   - handled: whether a window's work at the limit that resets then was handed over already (`HandoverLog.handled`).
    ///   - busy: whether a handover of a window runs right now.
    public static func due(
        _ statuses: [ProfileStatus], now: Date = Date(), handled: (String, Date?) -> Bool, busy: (String) -> Bool = { _ in false }
    ) -> [String] {
        statuses.compactMap { status in
            guard status.isRunning, DestinationRanking.isAtLimit(status, now: now), let binding = status.limits.binding(now: now) else { return nil }
            // A sample alone says nothing about the sessions; the limit must show in them, and lately.
            guard !binding.sampleOnly, let reached = binding.reachedAt, now.timeIntervalSince(reached) <= recent else { return nil }
            guard waitedFor(status.limits, now: now) == nil, !busy(status.id), !handled(status.id, binding.reset?.at) else { return nil }
            return status.id
        }
    }

    /// What the limit banner says for `status`, a window at its limit, while no handover of it is under way: that it
    /// continues its work there when its reset is waited for (`waitedFor`), that no window has room (`noRoom`), or when
    /// it resets.
    public static func bannerLine(_ status: ProfileStatus, noRoom: String?, now: Date = Date()) -> String {
        if let resetsAt = waitedFor(status.limits, now: now) {
            let until = HandoverText.untilText(resetsAt, now: now, timeZone: .current, locale: .current)
            return "\(status.displayLabel) is at its limit until \(until); work continues there then."
        }
        if let noRoom { return noRoom }
        let asOf = LimitText.asOf(status.limits).map { " \($0)" } ?? ""
        let resets = LimitText.bindingReset(status.limits).map { " It \($0)." } ?? ""
        return "\(status.displayLabel) is at its limit\(asOf).\(resets)"
    }
}

/// Whether the app hands work over by itself when a window reaches its limit: on unless `baton handover auto off`
/// turned it off. Kept in `handover.json` in Baton's state folder.
public struct HandoverAuto: Sendable {
    struct State: Codable { var auto = true }
    let file: URL

    public init(paths: Paths) { file = paths.stateDir.appending(path: "handover.json") }

    public var isOn: Bool {
        guard let data = try? Data(contentsOf: file) else { return true }
        return (try? JSONDecoder().decode(State.self, from: data))?.auto ?? true
    }

    public func set(_ on: Bool) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(State(auto: on)).write(to: file, options: .atomic)
    }
}

extension HandoverText {
    /// "ROBIN is at its limit. Moving your work to PAY…"; "Moving ROBIN's work to PAY…" for a move by hand from a
    /// window with room.
    public static func moving(source: String, destination: String, atLimit: Bool = true) -> String {
        atLimit ? "\(source) is at its limit. Moving your work to \(destination)…" : "Moving \(source)'s work to \(destination)…"
    }

    /// While a handover waits for its busy source: "PAY finishes its current step, then your work moves to BRAVO."
    public static func sourceFinishing(source: String, destination: String) -> String {
        "\(source) finishes its current step, then your work moves to \(destination)."
    }

    /// The Continue sheet's footer: "12 sessions, 3 to resume. 2 stay in ROBIN: Remote Control reaches them there."
    public static func summary(_ plan: HandoverPlan, labels: (String) -> String) -> String {
        let count = plan.sessions.count, resume = plan.cut.count
        var text = count == 0 ? "No sessions to move." : "\(count) session\(count == 1 ? "" : "s")" + (resume > 0 ? ", \(resume) to resume." : ".")
        let clauses = plan.leftovers.compactMap { clause($0, source: labels(plan.source), destination: labels(plan.destination)) }
        var parts = Array(clauses.prefix(maxClauses))
        if clauses.count > maxClauses { parts.append("and more — baton doctor") }
        if !parts.isEmpty { text += " " + capitalized(parts.joined(separator: "; ")) + "." }
        return text
    }

    public static func capitalized(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }
}

extension ProfileManager {
    /// "ROBIN is at its limit until 19:10. No window has room: PAY frees up at 20:00." when no other window has room
    /// for `source`'s work; `nil` when one has.
    public func noRoomLine(for source: String, statuses: [ProfileStatus], now: Date = Date()) -> String? {
        guard let status = statuses.first(where: { $0.id == source }) else { return nil }
        let room = statuses.contains { $0.id != source && $0.isSignedIn && !DestinationRanking.isAtLimit($0, now: now) }
        return room ? nil : noRoomLine(source: status, statuses: statuses, now: now)
    }
}
