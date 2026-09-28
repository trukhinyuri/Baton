import Foundation
import Testing
@testable import ClaudeProfilesKit

extension Sandbox {
    /// Writes the profile registry by hand with `carryPermissionMode` for `work`, the per-profile opt-in.
    func carryPermissionMode(_ on: Bool) throws {
        try FileManager.default.createDirectory(at: paths.stateDir, withIntermediateDirectories: true)
        try write(##"[{"id":"work","label":"WORK","color":"#1971C2","createdAt":"2026-09-01T00:00:00Z","carryPermissionMode":\##(on)}]"##,
                  to: paths.registryFile)
    }
}

private func fixture(_ name: String) throws -> String {
    let url = Bundle.module.resourceURL!.appending(path: "Fixtures/SanitizedCard/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite("Account-scoped fields in shared cards")
struct SessionSyncAccountTests {
    static let card = #"{"sessionId":"local_1","cliSessionId":"\#(Sandbox.cli)","cwd":"/repo","permissionMode":"bypassPermissions","chromePermissionMode":"skip_all_permission_checks","bridgeSessionIds":["bridge-1"],"remoteMcpServersConfig":[{"uuid":"u","name":"Org Slack","url":"https://mcp.example","tools":[]}],"enabledMcpTools":{"org-slack:read":true,"local:stdio:tool-1":true},"cuGrantFlags":{"clipboardRead":true},"peerReceipts":[{"messageId":"m"}],"remoteControlAutoEligible":true,"title":"T"}"#

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
            try box.write(#"{"sessionId":"local_2","permissionMode":"bypassPermissions"}"#, to: a.appending(path: "local_2.json"),
                          modified: Date())
            // The window here chose its own mode for this session; that stays whatever the opt-in.
            try box.write(#"{"sessionId":"local_2","permissionMode":"acceptEdits"}"#, to: b.appending(path: "local_2.json"),
                          modified: Date().addingTimeInterval(-600))

            _ = try box.sync()

            let copied = box.read(b.appending(path: "local_1.json"))
            #expect(copied == (optIn ? #"{"sessionId":"local_1","permissionMode":"bypassPermissions","title":"T"}"# : #"{"sessionId":"local_1","title":"T"}"#))
            #expect(box.read(b.appending(path: "local_2.json")) == (optIn ? #"{"sessionId":"local_2","permissionMode":"bypassPermissions"}"# : #"{"sessionId":"local_2","permissionMode":"acceptEdits"}"#))
        }
    }

    /// A window keeps what its own account set for a session when another account's newer copy comes in.
    @Test func destinationKeepsItsOwnAccountFields() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(#"{"sessionId":"local_1","bridgeSessionIds":["b-own"],"title":"old"}"#, to: b.appending(path: "local_1.json"),
                      modified: Date().addingTimeInterval(-600))
        try box.write(#"{"sessionId":"local_1","bridgeSessionIds":["a-own"],"title":"new"}"#, to: a.appending(path: "local_1.json"))

        _ = try box.sync()

        #expect(box.read(b.appending(path: "local_1.json")) == #"{"sessionId":"local_1","bridgeSessionIds":["b-own"],"title":"new"}"#)
        #expect(box.read(a.appending(path: "local_1.json")) == #"{"sessionId":"local_1","bridgeSessionIds":["a-own"],"title":"new"}"#)
        #expect(try box.sync().changes == 0)
    }

    /// Copies made by earlier releases are the same file everywhere, with the same date. The first one written
    /// is the original; the others lose what came from its account.
    @Test func earlierIdenticalCopiesAreCleanedOnce() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(Self.card, to: b.appending(path: "local_1.json"))
        Thread.sleep(forTimeInterval: 0.05)
        try box.write(Self.card, to: b.appending(path: "local_1.json"))   // saved again, in place
        let modified = try #require(SyncFolders.modificationDate(b.appending(path: "local_1.json")))
        try box.write(Self.card, to: a.appending(path: "local_1.json"), modified: modified)

        let report = try box.sync()

        #expect(report.cardsWritten == 1)
        #expect(box.read(b.appending(path: "local_1.json")) == Self.card, "the original stays as it is")
        #expect(!(box.read(a.appending(path: "local_1.json")) ?? "").contains("bridge-1"))
        #expect(try box.sync().changes == 0)
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
