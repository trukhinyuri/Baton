import Foundation
import Testing

@testable import BatonKit

/// The Continue sheet: one list, one button, the same handover as at a limit, asked for by hand.
@Suite("Moving work by hand")
struct MoveWorkTests {
    typealias S = HandoverScene

    /// WORK open with room left, (main) with more.
    func withRoom(_ scene: S) -> [ProfileStatus] {
        var statuses = scene.statuses
        statuses[1].limits = Limits(samples: [UsageSample(at: scene.now.addingTimeInterval(-60), fiveHour: 20, week: 30)])
        statuses[1].usage = Usage(fiveHour: 20, week: 30, sampledAt: scene.now)
        return statuses
    }

    @Test func moveFromAWindowWithRoomSaysOnlyThatItWasClosed() async throws {
        let scene = try S()
        try scene.session(S.a, title: "Fix CI")
        // Seen running in WORK, then ended.
        scene.world.work(S.a, in: "work")
        _ = scene.manager.limitTracker.observe(paths: scene.box.paths, windows: scene.manager.windows)
        scene.world.stopWork()
        scene.world.start("work")
        let statuses = withRoom(scene)
        #expect(throws: HandoverError.notAtLimit("WORK")) {
            try scene.manager.planHandover(from: "work", to: nil, statuses: statuses, now: scene.now)
        }

        let plan = try scene.manager.planHandover(from: "work", to: nil, statuses: statuses, now: scene.now, byHand: true)
        #expect(plan.byHand && !plan.sourceAtLimit && plan.resetsAt == nil)
        #expect(plan.destination == "main")
        #expect(plan.sessions.map(\.transcript) == [S.a])

        let result = try await scene.manager.handOver(plan, dwell: 0.3, lastWait: 0.3)
        #expect(result.state == .done && result.sourceClosed)
        #expect(result.line == "WORK was closed. Your work continues in (main).", "\(result.line)")
    }

    @Test func moveRunsWhenThisLimitWasHandedOverAlready() async throws {
        let scene = try S()
        try scene.session(S.a, title: "Armed")
        try scene.armed([S.a])
        let log = HandoverLog(paths: scene.box.paths)
        try log.save(
            HandoverLog.Entry(
                source: "work", resetsAt: scene.reset, destination: "main", startedAt: scene.now.addingTimeInterval(-60), state: "done", sessions: 1))
        #expect(throws: HandoverError.alreadyHandedOver("WORK")) { try scene.plan() }

        let plan = try scene.manager.planHandover(from: "work", to: nil, statuses: scene.statuses, now: scene.now, byHand: true)
        #expect(plan.sourceAtLimit && plan.resetsAt == scene.reset)
        let result = try await scene.manager.handOver(plan, dwell: 0.3, lastWait: 0.3)
        #expect(result.state == .done)
        #expect(result.line.hasPrefix("WORK is at its limit until "), "\(result.line)")
        #expect(log.entries().count == 2, "still counts as this limit's handover")
    }

    @Test func moveIgnoresAResetWithinMinutes() throws {
        let scene = try S(resetIn: 600)
        try scene.session(S.a, title: "Armed")
        try scene.armed([S.a])
        #expect(try scene.plan().picksUpItself)
        let plan = try scene.manager.planHandover(from: "work", to: nil, statuses: scene.statuses, now: scene.now, byHand: true)
        #expect(!plan.picksUpItself && plan.cut.map(\.transcript) == [S.a], "asked for, so no offer to wait")
    }

    @Test func footerSaysHowManyMoveAndWhatStays() {
        let session = { (id: String, cut: Bool) in
            HandoverSession(card: "local_\(id)", transcript: id, title: id, cut: cut, asCopy: false, lastActivity: Date())
        }
        var plan = HandoverPlan(
            source: "robin", destination: "pay", resetsAt: nil, sessions: (0..<12).map { session("s\($0)", $0 < 3) }, sourceActivity: .closed,
            destinationActivity: .closed, seeding: .seed, leftovers: [.remoteControl(count: 2)])
        let labels = { (id: String) in id.uppercased() }
        #expect(HandoverText.summary(plan, labels: labels) == "12 sessions, 3 to resume. 2 stay in ROBIN: Remote Control reaches them there.")
        plan.leftovers = []
        plan.sessions = [session("one", false)]
        #expect(HandoverText.summary(plan, labels: labels) == "1 session.")
        plan.sessions = []
        #expect(HandoverText.summary(plan, labels: labels) == "No sessions to move.")
    }

    @Test func movingLineByHand() {
        #expect(HandoverText.moving(source: "ROBIN", destination: "PAY", atLimit: false) == "Moving ROBIN's work to PAY…")
    }
}
