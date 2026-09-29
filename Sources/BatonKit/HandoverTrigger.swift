import Foundation

/// When the app hands a window's work over by itself: a window that is open, at its limit, whose limit was reached in
/// its sessions within the last half hour (the user was working there), not handed over for this limit yet, and whose
/// reset isn't within minutes (then it picks its work up by itself).
public enum HandoverTrigger {
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
            let resetsAt = binding.reset?.at
            if let resetsAt, resetsAt.timeIntervalSince(now) <= AutoResumeOffer.within { return nil }
            guard !busy(status.id), !handled(status.id, resetsAt) else { return nil }
            return status.id
        }
    }

    /// What the limit banner says for `status`, a window at its limit, while no handover of it is under way: that it
    /// picks its work up by itself when it resets within minutes, that no window has room (`noRoom`), or when it resets.
    public static func bannerLine(_ status: ProfileStatus, noRoom: String?, now: Date = Date()) -> String {
        let resetsAt = status.limits.binding(now: now)?.reset?.at
        if let resetsAt, resetsAt.timeIntervalSince(now) <= AutoResumeOffer.within {
            let until = HandoverText.untilText(resetsAt, now: now, timeZone: .current, locale: .current)
            return "\(status.displayLabel) is at its limit until \(until) and picks its work up by itself then."
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

    /// The Continue sheet's footer: "12 sessions, 3 to resume. 2 stay in ROBIN: Remote Control reaches them there."
    public static func summary(_ plan: HandoverPlan, labels: (String) -> String) -> String {
        let count = plan.sessions.count, resume = plan.cut.count - plan.resumeInSource.count
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
