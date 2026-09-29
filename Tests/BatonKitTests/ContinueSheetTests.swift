import Foundation
import Testing

@testable import BatonKit

@Suite("Continue sheet")
struct ContinueSheetTests {
    private func conversation(_ id: String, _ title: String, folder: String? = nil, minutesAgo: Double = 1) -> Conversation {
        Conversation(
            kind: .code, sessionID: id, title: title, folders: folder.map { [$0] } ?? [], lastActivity: Date().addingTimeInterval(-60 * minutesAgo),
            transcript: URL(fileURLWithPath: "/nonexistent/\(id).jsonl"))
    }

    private func status(_ id: String, signedIn: Bool) -> ProfileStatus {
        ProfileStatus(
            profile: id == "main" ? nil : Profile(id: id, label: id.uppercased(), email: nil, color: "#1971C2"),
            accountID: signedIn ? "account-\(id)" : nil, email: nil, usage: nil, isRunning: true)
    }

    /// Typing a search that hides the selected session moves the selection onto what is listed, so Continue never
    /// acts on a session nobody can see.
    @Test func searchNeverLeavesAHiddenSelection() {
        let all = [conversation("c1", "Refactor auth"), conversation("c2", "billing invoices"), conversation("c3", "Billing export")]
        let shown = ConversationIndex.listed(all, query: " billing ").shown
        #expect(shown.map(\.id) == ["c2", "c3"])
        #expect(ConversationIndex.selection("c1", in: shown) == "c2")
        #expect(ConversationIndex.selection("c3", in: shown) == "c3")
        #expect(ConversationIndex.selection(nil, in: shown) == "c2")
        #expect(ConversationIndex.selection("c1", in: ConversationIndex.listed(all, query: "nothing").shown) == nil)
    }

    /// The sheet looks its selection up by id instead of filtering the list each time: it finds exactly what the
    /// list shows, never one the search or the limit leaves out.
    @Test func theSelectionIsFoundOnlyWhenListed() {
        let all = [
            conversation("c1", "Refactor auth"), conversation("c2", "billing invoices"),
            conversation("c3", "Export", folder: "/Users/alex/src/Billing"), conversation("c4", "Billing export"),
        ]
        for query in ["", " billing ", "BILLING", "auth", "nothing"] {
            for limit in [0, 2, 10] {
                for id in [nil, "c1", "c2", "c3", "c4", "gone"] {
                    let listed = ConversationIndex.listed(all, query: query, limit: limit).shown.first { $0.id == id }
                    #expect(
                        ConversationIndex.listedConversation(id, in: all, query: query, limit: limit) == listed,
                        "\(id ?? "nil") for “\(query)”, limit \(limit)")
                }
            }
        }
        #expect(ConversationIndex.listedConversation("c3", in: all, query: "", limit: 2) == nil)
        #expect(ConversationIndex.listedConversation("c3", in: all, query: "billing", limit: 2)?.id == "c3")
    }

    @Test func searchMatchesFolders() {
        let all = [conversation("c1", "Fix it", folder: "/Users/alex/src/billing"), conversation("c2", "Other", folder: "/Users/alex/web")]
        #expect(ConversationIndex.listed(all, query: "BILLING").shown.map(\.id) == ["c1"])
    }

    /// Without a search the list stops at its limit and says so.
    @Test func aCappedListSaysHowManyMore() {
        let all = (0..<5).map { conversation("c\($0)", "Session \($0)", minutesAgo: Double($0)) }
        let listing = ConversationIndex.listed(all, query: "", limit: 3)
        #expect(listing.shown.map(\.id) == ["c0", "c1", "c2"])
        #expect(listing.matching == 5)
        #expect(ConversationIndex.listNote(shown: 3, matching: 5) == "Showing the 3 most recent of 5. Search to find an older one.")
        #expect(ConversationIndex.listNote(shown: 5, matching: 5) == nil)
        #expect(ConversationIndex.listed(all, query: "Session").matching == 5)
    }

    @Test func saysWhyNoWindowIsOffered() {
        let alone = DestinationRanking.noDestinationReason([status("main", signedIn: true)], source: nil)
        #expect(alone.contains("no other subscription"))
        // The main window runs it, and the only other one isn't signed in yet.
        let notSignedIn = DestinationRanking.noDestinationReason([status("main", signedIn: true), status("work", signedIn: false)], source: "main")
        #expect(notSignedIn.contains("Sign in inside the Claude WORK window"))
        let noneLeft = DestinationRanking.noDestinationReason([status("main", signedIn: true), status("work", signedIn: true)], source: "work")
        #expect(noneLeft.contains("No other signed-in window"))
    }

    private func plan(model: ModelNote? = nil, autoResume: [AutoResumeNote] = []) -> ContinuePlan {
        var plan = ContinuePlan(conversation: conversation("c1", "Add rate limiting to the webhook handler"), destination: "work", forks: true, model: model)
        plan.autoResume = autoResume
        return plan
    }

    /// Every warning comes first, each once, so none is cut after a long title or dropped for another.
    @Test func warningsComeFirstAndNoneIsDropped() {
        let resets = Date().addingTimeInterval(3600)
        let stillOn = AutoResumeNote.stillOn(label: "(main)", resetsAt: resets, copied: true)
        let model = ModelNote(model: "claude-opus-5-5[1m]", kind: .chooseBeforeSending)
        let result = "Baton passed to Claude WORK: opened 2 sessions there."
        let notice = ContinueNotice.compose(
            result: result, leftOut: "Left out “A”: waits.",
            plans: [plan(model: model, autoResume: [stillOn, .turnedOff(label: "LAB")]), plan(model: model, autoResume: [stillOn])], label: "WORK")
        #expect(notice.isWarning)
        #expect(
            notice.text
                == [stillOn.message(), model.message(destination: "WORK"), result, "Left out “A”: waits.", AutoResumeNote.turnedOff(label: "LAB").message()]
                .joined(separator: " "))
    }

    @Test func aPlainResultIsNotAWarning() {
        let notice = ContinueNotice.compose(
            result: "Baton passed to Claude WORK: “X” is open there.", plans: [plan(model: ModelNote(model: "claude-sonnet-5-5", kind: .carried))],
            label: "WORK")
        #expect(!notice.isWarning)
        #expect(notice.text == "Baton passed to Claude WORK: “X” is open there.")
    }
}

@Suite("Operations in flight")
struct OperationsInFlightTests {
    /// Show on an open window, a quick action, ends while an app copy is still being made: the footer keeps saying so.
    @Test func aQuickActionDoesNotClearASlowOnesMessage() {
        var operations = OperationsInFlight()
        let create = operations.start("Creating Claude WORK…")
        let show = operations.start(nil, window: "lab")
        #expect(operations.message == "Creating Claude WORK…")
        operations.finish(show)
        #expect(operations.message == "Creating Claude WORK…")
        operations.finish(create)
        #expect(operations.message == nil)
        #expect(operations.isEmpty)
    }

    @Test func theNewestMessageShowsUntilItsActionEnds() {
        var operations = OperationsInFlight()
        let first = operations.start("Opening Claude WORK…", window: "work")
        let second = operations.start("Removing Claude LAB…", window: "lab")
        #expect(operations.message == "Removing Claude LAB…")
        operations.finish(first)
        #expect(operations.message == "Removing Claude LAB…")
        #expect(!operations.isBusy(window: "work"))
        #expect(operations.isBusy(window: "lab"))
        operations.finish(second)
        #expect(!operations.isBusy(window: "lab"))
    }
}

@Suite("Add Subscription hints")
struct ProfileHintsTests {
    @Test func saysWhyAnEmailIsNotAccepted() {
        #expect(Profile.emailHint("") == nil)
        #expect(Profile.emailHint("me@gmail.com ") == nil)
        #expect(Profile.emailHint("me@gmail") == "Enter the full email address, like you@example.com.")
    }

    @Test func saysWhyALabelIsNotAccepted() {
        #expect(Profile.labelHint("", taken: []) == nil)
        #expect(Profile.labelHint("TEAM-2", taken: []) == nil)
        #expect(Profile.labelHint("WORK TEAM", taken: []) == "Use 1–8 letters, digits, “-” or “_”.")
        #expect(Profile.labelHint("A.B", taken: []) == "Use 1–8 letters, digits, “-” or “_”.")
        #expect(Profile.labelHint("WORK", taken: ["work"]) == "Already used by another subscription.")
        #expect(Profile.labelHint("MAIN", taken: []) == "Names the main Claude.")
        #expect(Profile.labelHint("CLAUDE", taken: []) == "Names the main Claude.")
    }
}
