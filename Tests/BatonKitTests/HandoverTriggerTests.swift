import Foundation
import Testing

@testable import BatonKit

@Suite("When the app hands work over by itself")
struct HandoverTriggerTests {
    let now = Date()

    /// ROBIN open at its five-hour limit, reached `reachedAgo` seconds ago in its sessions, resetting in `resetsIn`.
    func atLimit(
        _ id: String = "robin", running: Bool = true, reachedAgo: TimeInterval = 120, resetsIn: TimeInterval = 3600, sampleOnly: Bool = false
    ) -> ProfileStatus {
        var limits = Limits(usage: Usage(fiveHour: 100, week: 30, sampledAt: now.addingTimeInterval(-reachedAgo)))
        limits.fiveHour = LimitState(
            kind: .fiveHour, percent: 100, sampledAt: now.addingTimeInterval(-reachedAgo), reachedAt: now.addingTimeInterval(-reachedAgo),
            reset: LimitReset(at: now.addingTimeInterval(resetsIn), source: .exact))
        limits.fiveHour.sampleOnly = sampleOnly
        return ProfileStatus(
            profile: Profile(id: id, label: id.uppercased(), email: nil, color: "#123456"), accountID: "acct-\(id)", email: "\(id)@example.org",
            usage: Usage(fiveHour: 100, week: 30, sampledAt: now), isRunning: running, limits: limits)
    }

    func room(_ id: String = "pay") -> ProfileStatus {
        ProfileStatus(
            profile: Profile(id: id, label: id.uppercased(), email: nil, color: "#123456"), accountID: "acct-\(id)", email: "\(id)@example.org",
            usage: Usage(fiveHour: 10, week: 10, sampledAt: now), isRunning: false)
    }

    let never = { (_: String, _: Date?) in false }

    @Test func openWindowAtItsLimitReachedLatelyIsDue() {
        #expect(HandoverTrigger.due([atLimit(), room()], now: now, handled: never) == ["robin"])
    }

    @Test func closedWindowIsNotDue() {
        #expect(HandoverTrigger.due([atLimit(running: false), room()], now: now, handled: never).isEmpty)
    }

    @Test func limitReachedLongAgoIsNotDue() {
        #expect(HandoverTrigger.due([atLimit(reachedAgo: 45 * 60), room()], now: now, handled: never).isEmpty, "not while the user worked there")
    }

    @Test func sampleAloneIsNotDue() {
        #expect(HandoverTrigger.due([atLimit(sampleOnly: true), room()], now: now, handled: never).isEmpty, "the limit must show in its sessions")
    }

    @Test func resetWithinHalfAnHourIsNotDueAndBannerSaysWorkContinuesThere() {
        let soon = atLimit(resetsIn: 25 * 60)
        #expect(HandoverTrigger.due([soon, room()], now: now, handled: never).isEmpty, "Baton waits for a reset 25 minutes away")
        let line = HandoverTrigger.bannerLine(soon, noRoom: nil, now: now)
        #expect(line.hasPrefix("ROBIN is at its limit until "))
        #expect(line.hasSuffix("; work continues there then."))
        #expect(HandoverTrigger.due([atLimit(resetsIn: 31 * 60), room()], now: now, handled: never) == ["robin"], "not for one 31 away")
    }

    @Test func unknownResetIsHandedOver() {
        var status = atLimit()
        status.limits.fiveHour.reset = nil
        #expect(HandoverTrigger.due([status, room()], now: now, handled: never) == ["robin"], "no reset time: hand over as before")
    }

    @Test func handledOrRunningHandoverIsNotDue() {
        let status = atLimit()
        let reset = status.limits.binding(now: now)?.reset?.at
        #expect(HandoverTrigger.due([status], now: now, handled: { $0 == "robin" && $1 == reset }).isEmpty, "one handover per limit")
        #expect(HandoverTrigger.due([status], now: now, handled: never, busy: { $0 == "robin" }).isEmpty)
    }

    @Test func bannerSaysNoRoomWhenNoWindowHasRoom() {
        let line = "ROBIN is at its limit until 19:10. No window has room: PAY frees up at 20:00."
        #expect(HandoverTrigger.bannerLine(atLimit(), noRoom: line, now: now) == line)
        #expect(!HandoverTrigger.bannerLine(atLimit(), noRoom: nil, now: now).contains("type"))
    }

    @Test func movingLine() {
        #expect(HandoverText.moving(source: "ROBIN", destination: "PAY") == "ROBIN is at its limit. Moving your work to PAY…")
    }

    @Test func autoIsOnUntilTurnedOff() throws {
        let box = try Sandbox()
        let auto = HandoverAuto(paths: box.paths)
        #expect(auto.isOn, "on by default")
        try auto.set(false)
        #expect(!HandoverAuto(paths: box.paths).isOn)
        try auto.set(true)
        #expect(HandoverAuto(paths: box.paths).isOn)
    }

    @Test func autoCommandTakesOneWord() {
        #expect(CLIArguments.problem(in: ["handover", "auto", "off"]) == nil)
        #expect(CLIArguments.problem(in: ["handover", "auto"]) != nil)
        #expect(CLIDispatch.isReadOnly(["handover", "auto", "status"]))
        #expect(!CLIDispatch.isReadOnly(["handover", "auto", "off"]))
    }
}
