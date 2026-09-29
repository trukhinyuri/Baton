import Foundation
import Testing

@testable import BatonKit

@Suite("Choosing where a handover goes")
struct HandoverRankingTests {
    let now = Date()

    func status(_ id: String, week: Int, fiveHour: Int = 0) -> ProfileStatus {
        ProfileStatus(
            profile: id == "main" ? nil : Profile(id: id, label: id.uppercased(), email: nil, color: "#123456"),
            accountID: "acct-\(id)", email: "\(id)@example.org",
            usage: Usage(fiveHour: fiveHour, week: week, sampledAt: now.addingTimeInterval(-600)), isRunning: false)
    }

    func idle(_ id: String) -> WindowActivity { .idle }

    @Test func destinationMustAllowEveryCutSession() {
        let statuses = [status("source", week: 100), status("light", week: 5), status("heavy", week: 50)]
        let required: [Set<String>?] = [["heavy@example.org", "light@example.org"], ["heavy@example.org"], nil]
        #expect(DestinationRanking.forHandover(statuses, excluding: "source", required: required, activity: idle) == "heavy")
        #expect(DestinationRanking.forHandover(statuses, excluding: "source", required: [nil], activity: idle) == "light")
    }

    @Test func mostAllowedWhenNoneAllowsAll() {
        let statuses = [status("source", week: 100), status("light", week: 5), status("heavy", week: 50), status("mid", week: 20)]
        let required: [Set<String>?] = [["heavy@example.org"], ["heavy@example.org", "mid@example.org"], ["light@example.org"]]
        #expect(DestinationRanking.forHandover(statuses, excluding: "source", required: required, activity: idle) == "heavy", "two of three")
    }

    @Test func closedOrIdlePreferredWithinFortyPoints() {
        // Keys: best 4 × 10 = 40 (busy), quiet 4 × 20 = 80: 40 points behind.
        let statuses = [status("source", week: 100), status("best", week: 10), status("quiet", week: 20), status("later", week: 21)]
        let activity = { (id: String) -> WindowActivity in id == "best" ? .busy(working: 2) : id == "quiet" ? .closed : .idle }
        #expect(DestinationRanking.forHandover(statuses, excluding: "source", activity: activity) == "quiet")
        let allQuiet = { (_: String) -> WindowActivity in .idle }
        #expect(DestinationRanking.forHandover(statuses, excluding: "source", activity: allQuiet) == "best", "the best, when it isn't busy")
    }

    @Test func busyBestWinsBeyondFortyPoints() {
        // Keys: best 40 (busy), quiet 4 × 20 + 1 = 81: 41 points behind.
        let statuses = [status("source", week: 100), status("best", week: 10), status("quiet", week: 20, fiveHour: 1)]
        let activity = { (id: String) -> WindowActivity in id == "best" ? .busy(working: 1) : .closed }
        #expect(DestinationRanking.forHandover(statuses, excluding: "source", activity: activity) == "best")
    }

    @Test func noWindowWithRoomIsNone() {
        let statuses = [status("source", week: 100), status("full", week: 100)]
        #expect(DestinationRanking.forHandover(statuses, excluding: "source", activity: idle) == nil)
    }
}
