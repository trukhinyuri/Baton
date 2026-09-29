import Foundation
import Testing

@testable import BatonKit

extension Sandbox {
    /// Writes the profile registry by hand with `carryPermissionMode` for `work`, the per-profile opt-in.
    func carryPermissionMode(_ on: Bool) throws {
        try FileManager.default.createDirectory(at: paths.stateDir, withIntermediateDirectories: true)
        try write(
            ##"[{"id":"work","label":"WORK","color":"#1971C2","createdAt":"2026-09-01T00:00:00Z","carryPermissionMode":\##(on)}]"##,
            to: paths.registryFile)
    }
}

private func fixture(_ name: String) throws -> String {
    let url = Bundle.module.resourceURL!.appending(path: "Fixtures/SanitizedCard/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite("Account-scoped fields in shared cards")
struct SessionSyncAccountTests {
    static let card =
        #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)","cwd":"/repo","permissionMode":"bypassPermissions","chromePermissionMode":"skip_all_permission_checks","bridgeSessionIds":["bridge-1"],"remoteMcpServersConfig":[{"uuid":"u","name":"Org Slack","url":"https://mcp.example","tools":[]}],"enabledMcpTools":{"org-slack:read":true,"local:stdio:tool-1":true},"cuGrantFlags":{"clipboardRead":true},"peerReceipts":[{"messageId":"m"}],"remoteControlAutoEligible":true,"title":"T"}"#

    @Test func crossAccountCopyDropsAccountScopedKeys() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(Self.card, to: a.appending(path: "local_1.json"))

        _ = try box.sync()

        let copied = box.read(b.appending(path: "local_1.json")) ?? ""
        #expect(copied == #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)","cwd":"/repo","enabledMcpTools":{"local:stdio:tool-1":true},"title":"T"}"#)
        #expect(!copied.contains("bridge-1"), "Remote Control bridge ids of account A are not copied into account B's card")
        #expect(!copied.contains("skip_all_permission_checks"), "the browser permission bypass is not copied to account B")
        #expect(!copied.contains("mcp.example"), "account A's connectors are not copied into account B")
        #expect(box.read(a.appending(path: "local_1.json")) == Self.card, "the source is untouched")
        #expect(try box.sync().changes == 0)
    }

    /// Computer-use app grants and the session's allow rules are what one account granted; another account's window
    /// starts without them. With the permission mode opt-in the mode and the choice of it come along, the grants and
    /// rules still don't.
    @Test func crossAccountCopyDropsComputerUseGrantsAndPermissionRules() throws {
        let grants =
            #""cuAllowedApps":[{"bundleId":"com.apple.Terminal","displayName":"Terminal","grantedAt":1790000000000,"tier":"full"}],"cuFlagsGrantedAt":1790000000000,"cuFutureGrant":{"x":1}"#
        let mode = #""permissionMode":"acceptEdits","bypassChosenInApp":true,"autoChosenInApp":"auto""#
        let rules =
            #""sessionPermissionUpdates":[{"type":"addRules","behavior":"allow","destination":"session","rules":[{"toolName":"Bash","ruleContent":"git push:*"}]},{"type":"addDirectories","destination":"session","directories":["/Users/me/lib"]}],"alwaysAllowedReasons":["r"]"#
        let card = #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)",\#(grants),\#(mode),\#(rules),"customTitle":"T"}"#
        for optIn in [false, true] {
            let box = try Sandbox()
            let a = try box.pair(box.main, account: Sandbox.accountA)
            let b = try box.pair(box.work, account: Sandbox.accountB)
            let same = try box.pair(box.work, account: Sandbox.accountA, org: "org-2")
            try box.carryPermissionMode(optIn)
            try box.write(card, to: a.appending(path: "local_1.json"))

            _ = try box.sync()

            let kept = optIn ? #",\#(mode)"# : ""
            #expect(box.read(b.appending(path: "local_1.json")) == #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)"\#(kept),"customTitle":"T"}"#)
            #expect(box.read(same.appending(path: "local_1.json")) == card, "the same account's window gets it all")
            #expect(try box.sync().changes == 0)
        }
    }

    @Test func sameAccountCopyIsByteExact() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let same = try box.pair(box.work, account: Sandbox.accountA)
        try box.write(Self.card, to: a.appending(path: "local_1.json"))

        _ = try box.sync()

        #expect(box.read(same.appending(path: "local_1.json")) == Self.card)
    }

    @Test func permissionModeResetUnlessOptIn() throws {
        for optIn in [false, true] {
            let box = try Sandbox()
            let a = try box.pair(box.main, account: Sandbox.accountA)
            let b = try box.pair(box.work, account: Sandbox.accountB)
            try box.carryPermissionMode(optIn)
            try box.write(#"{"sessionId":"local_1","permissionMode":"bypassPermissions","title":"T"}"#, to: a.appending(path: "local_1.json"))
            try box.write(
                #"{"sessionId":"local_2","permissionMode":"bypassPermissions"}"#, to: a.appending(path: "local_2.json"),
                modified: Date())
            // The window here chose its own mode for this session; that stays whatever the opt-in.
            try box.write(
                #"{"sessionId":"local_2","permissionMode":"acceptEdits"}"#, to: b.appending(path: "local_2.json"),
                modified: Date().addingTimeInterval(-600))

            _ = try box.sync()

            let copied = box.read(b.appending(path: "local_1.json"))
            #expect(copied == (optIn ? #"{"sessionId":"local_1","permissionMode":"bypassPermissions","title":"T"}"# : #"{"sessionId":"local_1","title":"T"}"#))
            #expect(
                box.read(b.appending(path: "local_2.json"))
                    == (optIn ? #"{"sessionId":"local_2","permissionMode":"bypassPermissions"}"# : #"{"sessionId":"local_2","permissionMode":"acceptEdits"}"#))
        }
    }

    /// A window keeps what its own account set for a session when another account's newer copy comes in.
    @Test func destinationKeepsItsOwnAccountFields() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(
            #"{"sessionId":"local_1","bridgeSessionIds":["b-own"],"title":"old"}"#, to: b.appending(path: "local_1.json"),
            modified: Date().addingTimeInterval(-600))
        try box.write(#"{"sessionId":"local_1","bridgeSessionIds":["a-own"],"title":"new"}"#, to: a.appending(path: "local_1.json"))

        _ = try box.sync()

        #expect(box.read(b.appending(path: "local_1.json")) == #"{"sessionId":"local_1","bridgeSessionIds":["b-own"],"title":"new"}"#)
        #expect(box.read(a.appending(path: "local_1.json")) == #"{"sessionId":"local_1","bridgeSessionIds":["a-own"],"title":"new"}"#)
        #expect(try box.sync().changes == 0)
    }

    /// Copies made by earlier releases are the same file everywhere, with the same date. The first one written
    /// is the original; the others lose what came from its account. Its computer-use grant and permission mode are
    /// in both accounts' copies, so which account gave them can't be told: they go from the original too.
    @Test func earlierIdenticalCopiesAreCleanedOnce() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(Self.card, to: b.appending(path: "local_1.json"))
        Thread.sleep(forTimeInterval: 0.05)
        try box.write(Self.card, to: b.appending(path: "local_1.json"))  // saved again, in place
        let modified = try #require(SyncFolders.modificationDate(b.appending(path: "local_1.json")))
        try box.write(Self.card, to: a.appending(path: "local_1.json"), modified: modified)

        let report = try box.sync()

        #expect(report.cardsWritten == 2 && report.grantsRemoved == 2)
        let original = Self.card.replacingOccurrences(of: #""permissionMode":"bypassPermissions","#, with: "")
            .replacingOccurrences(of: #""cuGrantFlags":{"clipboardRead":true},"#, with: "")
        #expect(box.read(b.appending(path: "local_1.json")) == original, "the original keeps everything else")
        #expect(!(box.read(a.appending(path: "local_1.json")) ?? "").contains("bridge-1"))
        #expect(try box.sync().changes == 0)
    }

    /// Older releases copied computer-use grants and session rules into other accounts. When the session was used
    /// in the other account since, its copy is the newest; which account gave the grants can't be told from the
    /// cards, so they go from every copy, once, and a later grant in one account stays there.
    @Test func grantsOlderReleasesCopiedGoFromEveryAccount() throws {
        let grants =
            #""cuAllowedApps":[{"bundleId":"com.apple.Terminal","displayName":"Terminal","grantedAt":1790000000000,"tier":"full"}],"sessionPermissionUpdates":[{"type":"addRules","behavior":"allow","destination":"session","rules":[{"toolName":"Bash","ruleContent":"git push:*"}]}]"#
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(
            #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)",\#(grants),"bridgeSessionIds":["x"],"title":"T"}"#, to: a.appending(path: "local_1.json"),
            modified: Date().addingTimeInterval(-3_600))
        try box.write(#"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)",\#(grants),"title":"T2"}"#, to: b.appending(path: "local_1.json"))

        let report = try box.sync()

        #expect(report.grantsRemoved == 2)
        #expect(box.read(b.appending(path: "local_1.json")) == #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)","title":"T2"}"#)
        #expect(
            box.read(a.appending(path: "local_1.json")) == #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)","title":"T2","bridgeSessionIds":["x"]}"#)
        let list = box.paths.stateDir.appending(path: "cross-account-grants.json")
        #expect(box.read(list)?.contains("local_1") == false, "every copy has lost them")
        #expect(try box.sync().changes == 0)

        // A grant made again in A stays in A and is not copied to B.
        try box.write(
            #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)",\#(grants),"title":"T3"}"#, to: a.appending(path: "local_1.json"),
            modified: Date().addingTimeInterval(60))
        _ = try box.sync()
        #expect(box.read(a.appending(path: "local_1.json"))?.contains("git push") == true)
        #expect(box.read(b.appending(path: "local_1.json")) == #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)","title":"T3"}"#)
    }

    /// The clean-up takes a grant out of each copy once. One given again in an account afterwards stays there, while its
    /// window and every other one stay open, and still isn't copied to the other account.
    @Test func aGrantGivenAgainAfterTheCleanUpStaysWhileWindowsStayOpen() throws {
        let grants =
            #""permissionMode":"acceptEdits","sessionPermissionUpdates":[{"type":"addRules","behavior":"allow","destination":"session","rules":[{"toolName":"Bash","ruleContent":"git push:*"}]}]"#
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(
            #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)",\#(grants),"title":"T"}"#, to: a.appending(path: "local_1.json"),
            modified: Date().addingTimeInterval(-3_600))
        try box.write(#"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)",\#(grants),"title":"T2"}"#, to: b.appending(path: "local_1.json"))
        #expect(try box.sync().grantsRemoved == 2)

        for round in 1...3 {
            // Asked again, the user allows it again in WORK, and Claude saves the card.
            let again = #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)",\#(grants),"title":"T\#(round + 2)"}"#
            try box.write(again, to: b.appending(path: "local_1.json"), modified: Date().addingTimeInterval(Double(round) * 60))

            let report = try box.sync()

            #expect(report.grantsRemoved == 0)
            #expect(box.read(b.appending(path: "local_1.json")) == again, "round \(round)")
            #expect(box.read(a.appending(path: "local_1.json")) == #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)","title":"T\#(round + 2)"}"#)
        }
        #expect(box.read(box.paths.stateDir.appending(path: "cross-account-grants.json")) == #"{"cards":{},"version":2}"#)
    }

    /// A copy the clean-up has to leave for now, here one whose conversation a running `claude` has open, doesn't make
    /// the copies it is done with lose a grant given again there.
    @Test func eachCopyLosesTheGrantsOnceEvenWhileAnotherWaits() throws {
        let grants =
            #""sessionPermissionUpdates":[{"type":"addRules","behavior":"allow","destination":"session","rules":[{"toolName":"Bash","ruleContent":"git push:*"}]}]"#
        let other = "99999999-8888-4777-8666-555555555555"
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(#"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)",\#(grants),"title":"T"}"#, to: a.appending(path: "local_1.json"))
        let waiting = #"{"sessionId":"local_1","cliSessionId":"\#(other)",\#(grants),"title":"live"}"#
        try box.write(waiting, to: b.appending(path: "local_1.json"), modified: Date().addingTimeInterval(-3_600))

        let first = try box.sync { $0.liveSessionIDs = [other] }

        #expect(first.grantsRemoved == 1 && first.keptLive == 1)
        #expect(box.read(a.appending(path: "local_1.json")) == #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)","title":"T"}"#)
        #expect(box.read(b.appending(path: "local_1.json")) == waiting)

        let again = #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)",\#(grants),"title":"again"}"#
        try box.write(again, to: a.appending(path: "local_1.json"), modified: Date().addingTimeInterval(60))
        _ = try box.sync { $0.liveSessionIDs = [other] }
        #expect(box.read(a.appending(path: "local_1.json")) == again, "MAIN's copy lost it once already")

        // Once that process is gone, the waiting copy gets the card without MAIN's grant, and the list is done.
        let last = try box.sync { $0.liveSessionIDs = [] }
        #expect(last.grantsRemoved == 1)
        #expect(box.read(a.appending(path: "local_1.json")) == again)
        #expect(box.read(b.appending(path: "local_1.json")) == #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)","title":"again"}"#)
        #expect(box.read(box.paths.stateDir.appending(path: "cross-account-grants.json")) == #"{"cards":{},"version":2}"#)
    }

    /// Each allowed app, change to the session's rules and computer-use flag is matched on its own, so one that older
    /// releases copied into another account is taken out even after either account added its own; those stay.
    @Test func grantsOlderReleasesCopiedGoEvenAfterEitherAccountAddedItsOwn() throws {
        let terminal = #"{"bundleId":"com.apple.Terminal","displayName":"Terminal","grantedAt":1790000000000,"tier":"full"}"#
        let notes = #"{"bundleId":"com.apple.Notes","displayName":"Notes","grantedAt":1790000500000,"tier":"full"}"#
        let push = #"{"type":"addRules","behavior":"allow","destination":"session","rules":[{"toolName":"Bash","ruleContent":"git push:*"}]}"#
        let make = #"{"type":"addRules","behavior":"allow","destination":"session","rules":[{"toolName":"Bash","ruleContent":"make:*"}]}"#
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(
            #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)","cuAllowedApps":[\#(terminal)],"cuGrantFlags":{"clipboardRead":true},"#
                + #""sessionPermissionUpdates":[\#(push)],"title":"T"}"#,
            to: a.appending(path: "local_1.json"), modified: Date().addingTimeInterval(-3_600))
        // Continued in B, where Claude added an app, a flag and a rule.
        try box.write(
            #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)","cuAllowedApps":[\#(terminal), \#(notes)],"#
                + #""cuGrantFlags":{"clipboardRead":true,"systemKeyCombos":true},"sessionPermissionUpdates":[\#(push),\#(make)],"title":"T2"}"#,
            to: b.appending(path: "local_1.json"))

        let report = try box.sync()

        #expect(report.grantsRemoved == 2)
        #expect(
            box.read(b.appending(path: "local_1.json"))
                == #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)","cuAllowedApps":[\#(notes)],"#
                + #""cuGrantFlags":{"systemKeyCombos":true},"sessionPermissionUpdates":[\#(make)],"title":"T2"}"#)
        #expect(box.read(a.appending(path: "local_1.json")) == #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)","title":"T2"}"#)
        #expect(try box.sync().changes == 0)
    }

    /// A list an earlier build saved after matching whole values only is looked for again, entry by entry: the grants it
    /// missed because either account added its own go now, and what it already named stays on it, such as a grant that
    /// build took out of both accounts and one window wrote back.
    @Test func aListFromWholeValueMatchingIsLookedForAgain() throws {
        let terminal = #"{"bundleId":"com.apple.Terminal","displayName":"Terminal","grantedAt":1790000000000,"tier":"full"}"#
        let notes = #"{"bundleId":"com.apple.Notes","displayName":"Notes","grantedAt":1790000500000,"tier":"full"}"#
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(
            #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)","cuAllowedApps":[\#(terminal)],"title":"T"}"#,
            to: a.appending(path: "local_1.json"), modified: Date().addingTimeInterval(-3_600))
        try box.write(
            #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)","cuAllowedApps":[\#(terminal), \#(notes)],"title":"T2"}"#,
            to: b.appending(path: "local_1.json"))
        try box.write(#"{"sessionId":"local_9","cuAllowedApps":[\#(terminal)],"title":"N"}"#, to: a.appending(path: "local_9.json"))
        try box.write(#"{"sessionId":"local_9","title":"N"}"#, to: b.appending(path: "local_9.json"), modified: Date().addingTimeInterval(-3_600))
        let item = try #require(SessionSync.facts(of: Data(#"{"cuAllowedApps":[\#(terminal)]}"#.utf8)).grants["cuAllowedApps"]?.first)
        // The two lists differ as whole values, so that build found nothing for local_1.
        let list = box.paths.stateDir.appending(path: "cross-account-grants.json")
        try box.write(#"{"cards":{"local_9.json":["\#(item)"]},"version":1}"#, to: list)

        let report = try box.sync()

        #expect(report.grantsRemoved == 3)
        #expect(box.read(a.appending(path: "local_9.json")) == #"{"sessionId":"local_9","title":"N"}"#)
        #expect(
            box.read(b.appending(path: "local_1.json"))
                == #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)","cuAllowedApps":[\#(notes)],"title":"T2"}"#)
        #expect(box.read(a.appending(path: "local_1.json")) == #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)","title":"T2"}"#)
        #expect(box.read(list) == #"{"cards":{},"version":2}"#, "every copy has lost them")
        #expect(try box.sync().changes == 0, "looked for once")
    }

    @Test func listElementsKeepTheirBytes() {
        func elements(_ json: String) -> [String]? { JSONMembers.elements(Array(json.utf8)[...])?.map { String(decoding: $0, as: UTF8.self) } }
        #expect(elements(#" [ {"a":"x,]\"y"} , [1,[2]],"s" ,null ] "#) == [#"{"a":"x,]\"y"}"#, "[1,[2]]", #""s""#, "null"])
        #expect(elements("[]") == [])
        #expect(elements("[1,]") == nil)
        #expect(elements(#"["open]"#) == nil)
        #expect(elements("{}") == nil)
        #expect(String(decoding: JSONMembers.array([Array("1".utf8)[...], Array(#""b""#.utf8)[...]]), as: UTF8.self) == #"[1,"b"]"#)
    }

    /// The list is saved before any copy loses a grant, so a first run that stops partway doesn't lose track of a grant
    /// it already took out of one account.
    @Test func aFirstRunThatStopsPartwayKeepsTheList() throws {
        let grants =
            #""cuAllowedApps":[{"bundleId":"com.apple.Terminal","displayName":"Terminal","grantedAt":1790000000000,"tier":"full"}],"sessionPermissionUpdates":[{"type":"addRules","behavior":"allow","destination":"session","rules":[{"toolName":"Bash","ruleContent":"git push:*"}]}]"#
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(
            #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)",\#(grants),"title":"T"}"#, to: a.appending(path: "local_1.json"),
            modified: Date().addingTimeInterval(-3_600))
        try box.write(#"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)",\#(grants),"title":"T2"}"#, to: b.appending(path: "local_1.json"))
        // WORK's session folder can't be written, so the run stops once MAIN's copy has lost the grants.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: b.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: b.path) }
        #expect(throws: (any Error).self) { try box.sync() }
        #expect(box.read(a.appending(path: "local_1.json"))?.contains("git push") == false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: b.path)

        _ = try box.sync()

        #expect(box.read(b.appending(path: "local_1.json")) == #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)","title":"T2"}"#)
    }

    /// Values Claude writes into every card allow nothing and are no sign of a copy from another account; a
    /// permission mode two windows keep by the opt-in isn't either.
    @Test func defaultsAndKeptModesAreNotTakenOut() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.carryPermissionMode(true)
        let card =
            #"{"sessionId":"local_1","permissionMode":"acceptEdits","sessionPermissionUpdates":[],"cuGrantFlags":{"clipboardRead":false},"bypassChosenInApp":false,"title":"T"}"#
        try box.write(card, to: a.appending(path: "local_1.json"))
        try box.write(card, to: b.appending(path: "local_1.json"))

        let report = try box.sync()

        #expect(report.grantsRemoved == 0)
        #expect(box.read(a.appending(path: "local_1.json")) == card)
        #expect(box.read(box.paths.stateDir.appending(path: "cross-account-grants.json")) == #"{"cards":{},"version":2}"#)
    }

    @Test func goldenSanitizedRealCard() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        let same = try box.pair(box.work, account: Sandbox.accountA)
        let card = try fixture("card.json")
        try box.write(card, to: a.appending(path: "local_1.json"))

        _ = try box.sync()

        #expect(box.read(b.appending(path: "local_1.json")) == (try fixture("other-account.json")))
        #expect(box.read(same.appending(path: "local_1.json")) == card)
    }
}
