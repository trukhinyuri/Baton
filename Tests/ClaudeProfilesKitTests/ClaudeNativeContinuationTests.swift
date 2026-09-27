import Foundation
import Testing
@testable import ClaudeProfilesKit

@Suite("Native continuation UI matching")
@MainActor
struct ClaudeNativeContinuationTests {
    typealias Control = ClaudeNativeContinuation.Control
    private let selectedURL = URL(fileURLWithPath: "/private/tmp/reviewed-export/files/evidence.pdf")

    private func fileControl(path: [Int] = [0, 0], url: URL? = nil, selected: Bool = true,
                             role: String = "AXTextField", value: String = "evidence.pdf",
                             ancestors: [String] = ["open-panel", "ListView", "file row"]) -> Control {
        Control(path: path, role: role, label: "", identifier: "", value: value, url: url ?? selectedURL,
                enabled: true, selected: selected, ancestors: ancestors)
    }

    private func button(_ label: String, role: String = "AXButton", ancestors: [String] = ["New project"]) -> Control {
        Control(path: [], role: role, label: label, identifier: "", value: nil, url: nil,
                enabled: true, selected: false, ancestors: ancestors)
    }

    @Test func pickerRequiresSelectedFileWithExactURLAndRealPickerAncestry() {
        let selected = fileControl()
        #expect(ClaudeNativeContinuation.selectedFile(in: [selected], expected: selectedURL))
        #expect(!ClaudeNativeContinuation.selectedFile(in: [fileControl(selected: false)], expected: selectedURL))
        #expect(!ClaudeNativeContinuation.selectedFile(in: [fileControl(role: "AXStaticText")], expected: selectedURL))
        #expect(!ClaudeNativeContinuation.selectedFile(in: [fileControl(value: "other.pdf")], expected: selectedURL))
        #expect(!ClaudeNativeContinuation.selectedFile(in: [fileControl(url: selectedURL.deletingLastPathComponent().appending(path: "other.pdf"))], expected: selectedURL))
        #expect(!ClaudeNativeContinuation.selectedFile(in: [fileControl(url: URL(fileURLWithPath: "/private/tmp/unreviewed/evidence.pdf"))], expected: selectedURL))
        #expect(!ClaudeNativeContinuation.selectedFile(in: [fileControl(ancestors: ["ListView"])], expected: selectedURL))
        #expect(!ClaudeNativeContinuation.selectedFile(in: [fileControl(ancestors: ["open-panel"])], expected: selectedURL))
        #expect(!ClaudeNativeContinuation.selectedFile(in: [fileControl(ancestors: ["open-panel-like", "ListView-like"])], expected: selectedURL))
    }

    @Test func misleadingGoToTextAndSidebarFileNameCannotAuthorizeOpen() {
        let goTo = fileControl(value: selectedURL.path, ancestors: ["open-panel", "GoToWindow"])
        let sidebar = fileControl(ancestors: ["open-panel", "Sidebar"])
        var link = fileControl(ancestors: ["open-panel", "ListView"])
        link.url = nil
        #expect(!ClaudeNativeContinuation.selectedFile(in: [goTo, sidebar, link], expected: selectedURL))
        #expect(ClaudeNativeContinuation.selectedFile(in: [goTo, sidebar, fileControl()], expected: selectedURL))
    }

    @Test func ambiguousOrAdditionalSelectedFilesCannotUploadUnreviewedBytes() {
        #expect(!ClaudeNativeContinuation.selectedFile(in: [fileControl(), fileControl(path: [0, 1])], expected: selectedURL))
        let another = fileControl(path: [0, 1], url: URL(fileURLWithPath: "/private/tmp/unreviewed/secret.pdf"), value: "secret.pdf")
        #expect(!ClaudeNativeContinuation.selectedFile(in: [fileControl(), another], expected: selectedURL))
        let unselected = fileControl(path: [0, 1], url: URL(fileURLWithPath: "/private/tmp/unreviewed/secret.pdf"), selected: false, value: "secret.pdf")
        #expect(ClaudeNativeContinuation.selectedFile(in: [fileControl(), unselected], expected: selectedURL))
    }

    @Test func newProjectAttachmentInventoryIsScopedAndKeepsDuplicatesVisible() {
        let controls = [button("Remove CONTEXT.md"), button("Remove evidence.pdf"),
                        button("Remove private-sidebar-file.pdf", ancestors: ["Sidebar"]),
                        button("Remove elsewhere.pdf", ancestors: ["Another project"]),
                        button("Remove CONTEXT.md", role: "AXStaticText"),
                        button("Added fake.pdf"), button("Remove evidence.pdf")]
        #expect(ClaudeNativeContinuation.namesOfAttachments(in: controls) == ["CONTEXT.md", "evidence.pdf", "evidence.pdf"])
        #expect(ClaudeNativeContinuation.namesOfAttachments(in: [button("Remove outside.pdf", ancestors: [])]).isEmpty)
    }

    @Test(arguments: [NativeContinuationPlan.Kind.codeProject, .coworkConversation])
    func existingConversationAttachmentsStayInsideTheObservedComposer(_ kind: NativeContinuationPlan.Kind) {
        let controls = composer(kind: kind)
        #expect(ClaudeNativeContinuation.composerScope(in: controls, kind: kind) == [0, 2])
        #expect(ClaudeNativeContinuation.namesOfAttachments(in: controls, kind: kind, operation: .updateExisting) == ["CONTEXT.md", "evidence.pdf"])
        if kind == .coworkConversation {
            #expect(ClaudeNativeContinuation.namesOfAttachments(in: controls, kind: kind, operation: .create) == ["CONTEXT.md", "evidence.pdf"])
        }
    }

    @Test func libraryAddOutsideTheNearestComposerDoesNotMakeItsFilesUploadEvidence() {
        let kind = NativeContinuationPlan.Kind.codeProject
        var controls = composer(kind: kind)
        controls.append(Control(path: [0], role: "AXGroup", label: "Main", identifier: "", value: nil, url: nil,
                                enabled: true, selected: false, ancestors: []))
        controls.append(Control(path: [0, 1, 1], role: "AXPopUpButton", label: "Add", identifier: "", value: nil, url: nil,
                                enabled: true, selected: false, ancestors: ["Library"]))
        #expect(ClaudeNativeContinuation.composerScope(in: controls, kind: kind) == [0, 2])
        #expect(ClaudeNativeContinuation.namesOfAttachments(in: controls, kind: kind, operation: .updateExisting) == ["CONTEXT.md", "evidence.pdf"])
    }

    @Test(arguments: ["missing-prompt", "missing-add", "duplicate-prompt", "duplicate-add", "wrong-parent-role", "unrelated-root"])
    func ambiguousComposerNeverClaimsAnAttachmentWasUploaded(_ mode: String) {
        let kind = NativeContinuationPlan.Kind.coworkConversation
        var controls = composer(kind: kind)
        switch mode {
        case "missing-prompt": controls.removeAll { $0.role == "AXTextArea" }
        case "missing-add": controls.removeAll { $0.role == "AXPopUpButton" }
        case "duplicate-prompt":
            var duplicate = controls.first { $0.role == "AXTextArea" }!
            duplicate.path = [0, 4, 0]
            controls.append(duplicate)
        case "duplicate-add":
            var duplicate = controls.first { $0.role == "AXPopUpButton" }!
            duplicate.path = [0, 2, 1, 3]
            controls.append(duplicate)
        case "wrong-parent-role": controls[0].role = "AXWebArea"
        default:
            let index = controls.firstIndex { $0.role == "AXPopUpButton" }!
            controls[index].path = [9, 2, 1]
        }
        #expect(ClaudeNativeContinuation.composerScope(in: controls, kind: kind) == nil)
        #expect(ClaudeNativeContinuation.namesOfAttachments(in: controls, kind: kind).isEmpty)
    }

    @Test func uncertainNewProjectRecoveryRequiresAnExactUnambiguousNameAndDoesNotClaimItsCheckWasRead() throws {
        let receipt = recoveryReceipt()
        var view = recoveryView(receipt)
        let match = try ClaudeNativeContinuation.recoveryMatch(receipt: receipt, view: view)
        #expect(match.nativeURL == view.documentURL && match.phase == .created)
        #expect(match.evidenceDescription.contains("has not been confirmed"))
        view.projectTitles = [receipt.plan.title + " copy"]
        #expect(throws: (any Error).self) { try ClaudeNativeContinuation.recoveryMatch(receipt: receipt, view: view) }
        view.projectTitles = [receipt.plan.title, receipt.plan.title]
        #expect(throws: (any Error).self) { try ClaudeNativeContinuation.recoveryMatch(receipt: receipt, view: view) }
        view.projectTitles = []
        #expect(throws: (any Error).self) { try ClaudeNativeContinuation.recoveryMatch(receipt: receipt, view: view) }
    }

    @Test(arguments: ["account", "profile", "http", "host", "wrong-surface", "browse"])
    func recoveryRefusesTheWrongProfileAccountOrNativeSurface(_ mode: String) {
        let receipt = recoveryReceipt()
        var view = recoveryView(receipt)
        switch mode {
        case "account": view.accountID = Sandbox.accountA
        case "profile": view.profileID = "another-profile"
        case "http": view.documentURL = URL(string: "http://claude.ai/epitaxy/project/chan_recovery")!
        case "host": view.documentURL = URL(string: "https://claude.ai.evil.test/epitaxy/project/chan_recovery")!
        case "wrong-surface": view.documentURL = URL(string: "https://claude.ai/cowork/cse_recovery")!
        default: view.documentURL = URL(string: "https://claude.ai/epitaxy/projects/browse")!
        }
        #expect(throws: (any Error).self) { try ClaudeNativeContinuation.recoveryMatch(receipt: receipt, view: view) }
    }

    @Test(arguments: [NativeContinuationPlan.Phase.prepared, .fillingForm, .uploading, .readyToCreate, .created, .checkSubmitted])
    func recoveryCannotReclassifyAReceiptWithoutAnUncertainSubmission(_ phase: NativeContinuationPlan.Phase) {
        let receipt = recoveryReceipt(phase: phase)
        #expect(throws: (any Error).self) { try ClaudeNativeContinuation.recoveryMatch(receipt: receipt, view: recoveryView(receipt)) }
    }

    @Test(arguments: [NativeContinuationPlan.Kind.codeProject, .coworkConversation])
    func updatingExistingConversationRecoveryRequiresItsPinnedURLAndExactCheckReference(_ kind: NativeContinuationPlan.Kind) throws {
        let receipt = recoveryReceipt(kind: kind, operation: .updateExisting)
        var view = recoveryView(receipt)
        view.visibleHistory = "Earlier messages\nCheck\n reference:  \(receipt.plan.id.uuidString).\nLater messages"
        let match = try ClaudeNativeContinuation.recoveryMatch(receipt: receipt, view: view)
        #expect(match.nativeURL == receipt.plan.existingNativeURL && match.phase == .checkSubmitted)
        #expect(match.evidenceDescription.contains("still need your review"))
        view.visibleHistory = "Earlier check: Check reference: \(UUID().uuidString)."
        #expect(throws: (any Error).self) { try ClaudeNativeContinuation.recoveryMatch(receipt: receipt, view: view) }
        view.visibleHistory = "Check reference: \(receipt.plan.id.uuidString)"
        #expect(throws: (any Error).self) { try ClaudeNativeContinuation.recoveryMatch(receipt: receipt, view: view) }
        view.visibleHistory = "Check reference: \(receipt.plan.id.uuidString)."
        view.documentURL = URL(string: kind == .codeProject ? "https://claude.ai/epitaxy/project/chan_unrelated" : "https://claude.ai/cowork/cse_unrelated")!
        #expect(throws: ClaudeNativeContinuation.NativeError.windowChanged) {
            try ClaudeNativeContinuation.recoveryMatch(receipt: receipt, view: view)
        }
    }

    @Test func newlyCreatedCoworkNeedsAVisibleReferenceRatherThanOnlyAConversationURL() throws {
        let receipt = recoveryReceipt(kind: .coworkConversation)
        var view = recoveryView(receipt)
        #expect(throws: (any Error).self) { try ClaudeNativeContinuation.recoveryMatch(receipt: receipt, view: view) }
        view.visibleHistory = "Check reference: \(receipt.plan.id.uuidString)."
        let match = try ClaudeNativeContinuation.recoveryMatch(receipt: receipt, view: view)
        #expect(match.phase == .checkSubmitted && match.nativeURL == view.documentURL)
    }

    @Test func uncertainProjectCheckMustBeInThePinnedCoordinatorRatherThanAHelperThread() throws {
        let receipt = recoveryReceipt(phase: .checkRequested)
        var view = recoveryView(receipt)
        view.visibleHistory = "Check reference: \(receipt.plan.id.uuidString)."
        #expect(try ClaudeNativeContinuation.recoveryMatch(receipt: receipt, view: view).phase == .checkSubmitted)
        view.documentURL = URL(string: view.documentURL.absoluteString + "?thread=cse_helper")!
        #expect(throws: (any Error).self) { try ClaudeNativeContinuation.recoveryMatch(receipt: receipt, view: view) }
    }

    @Test func visibleRecoveryEvidenceExcludesComposerDraftsSidebarAndButtonLabels() {
        let nonce = "Check reference: \(UUID().uuidString)."
        func text(_ role: String, _ value: String, _ ancestors: [String]) -> Control {
            Control(path: [], role: role, label: "", identifier: "", value: value, url: nil,
                    enabled: true, selected: false, ancestors: ancestors)
        }
        let forbidden = [text("AXTextArea", nonce, ["Chat messages"]), text("AXTextField", nonce, ["Chat messages"]),
                         text("AXStaticText", nonce, ["Sidebar"]), text("AXHeading", nonce, []),
                         text("AXButton", nonce, ["Chat messages"])]
        #expect(!ClaudeNativeContinuation.visibleRecoveryHistory(in: forbidden).contains(nonce))
        let observed = forbidden + [text("AXHeading", "Historical user message", ["Chat messages"]),
                                    text("AXStaticText", nonce, ["Chat messages"])]
        #expect(ClaudeNativeContinuation.visibleRecoveryHistory(in: observed) == "Historical user message\n" + nonce)
    }

    private func recoveryReceipt(kind: NativeContinuationPlan.Kind = .codeProject,
                                 operation: NativeContinuationPlan.Operation = .create,
                                 phase: NativeContinuationPlan.Phase = .creationRequested) -> NativeContinuationPlan.Receipt {
        let native = URL(string: kind == .codeProject ? "https://claude.ai/epitaxy/project/chan_recovery" : "https://claude.ai/cowork/cse_recovery")!
        let plan = NativeContinuationPlan(id: UUID(), kind: kind, operation: operation,
            existingNativeURL: operation == .updateExisting ? native : nil,
            workspaceID: UUID(), revision: 7, contextSHA256: String(repeating: "a", count: 64),
            workspaceDirectory: URL(fileURLWithPath: "/private/tmp/recovery-workspace"),
            exportDirectory: URL(fileURLWithPath: "/private/tmp/recovery-export"),
            profileID: "destination", profileLabel: "DESTINATION", accountID: Sandbox.accountB,
            title: "Exact reviewed Project name", goal: "Historical data is not new authorization", uploads: [])
        return NativeContinuationPlan.Receipt(schemaVersion: 1, plan: plan, sequence: 5, phase: phase,
            uploadedNames: [], nativeURL: [.created, .checkRequested, .checkSubmitted].contains(phase) ? native : nil,
            lastMessage: nil, updatedAt: Date(timeIntervalSince1970: 100))
    }

    private func recoveryView(_ receipt: NativeContinuationPlan.Receipt) -> ClaudeNativeContinuation.RecoveryView {
        ClaudeNativeContinuation.RecoveryView(profileID: receipt.plan.profileID, accountID: receipt.plan.accountID,
            documentURL: URL(string: receipt.plan.kind == .codeProject ? "https://claude.ai/epitaxy/project/chan_recovery" : "https://claude.ai/cowork/cse_recovery")!,
            projectTitles: [receipt.plan.title], visibleHistory: "")
    }

    private func composer(kind: NativeContinuationPlan.Kind) -> [Control] {
        func node(_ path: [Int], _ role: String, _ label: String) -> Control {
            Control(path: path, role: role, label: label, identifier: "", value: nil, url: nil,
                    enabled: true, selected: false, ancestors: [])
        }
        let composer: [Control]
        if kind == .coworkConversation {
            // Observed Cowork tree: outer group 586 contains attachment group 587 and
            // input group 591; prompt 593 is nested in 592, while Add 595 is beside it.
            composer = [node([0, 2], "AXGroup", ""),
                        node([0, 2, 0], "AXGroup", ""),
                        node([0, 2, 0, 0], "AXButton", "Remove CONTEXT.md"),
                        node([0, 2, 0, 1], "AXButton", "Remove evidence.pdf"),
                        node([0, 2, 1], "AXGroup", ""),
                        node([0, 2, 1, 0], "AXGroup", ""),
                        node([0, 2, 1, 0, 0], "AXTextArea", "Write your prompt to Claude"),
                        node([0, 2, 1, 1], "AXPopUpButton", "Add files, connectors, and more"),
                        node([0, 2, 1, 2], "AXButton", "Send message")]
        } else {
            composer = [node([0, 2], "AXGroup", ""),
                node([0, 2, 0], "AXTextArea", kind == .codeProject ? "Prompt" : "Write your prompt to Claude"),
                node([0, 2, 1], "AXPopUpButton", kind == .codeProject ? "Add" : "Add files, connectors, and more"),
                node([0, 2, 2], "AXButton", "Remove CONTEXT.md"),
                node([0, 2, 3], "AXButton", "Remove evidence.pdf")]
        }
        return composer + [node([0, 1, 0], "AXButton", "Remove earlier-history-attachment.pdf"),
                node([0, 0, 0], "AXButton", "Remove private-sidebar-file.pdf"),
                node([1, 0], "AXButton", "Remove another-sheet.pdf")]
    }
}
