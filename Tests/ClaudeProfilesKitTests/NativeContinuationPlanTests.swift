import Foundation
import Testing
@testable import ClaudeProfilesKit

@Suite("Reviewed native continuation transfers")
struct NativeContinuationPlanTests {
    private let fm = FileManager.default
    private let sourceURL = URL(string: "https://claude.ai/epitaxy/project/chan_source")!
    private let targetURL = URL(string: "https://claude.ai/epitaxy/project/chan_destination")!

    private func fixture(_ box: Sandbox) throws -> (ContinuityWorkspace, URL) {
        let root = box.root.resolvingSymlinksInPath()
        let workspace = try ContinuityWorkspace.create(in: root.appending(path: "Workspaces"),
                                                     title: "Original work", kind: "codeProject",
                                                     sourceProfileID: "source", sourceURL: sourceURL)
        let file = root.appending(path: "evidence.pdf")
        let original = Data([37, 80, 68, 70, 0, 255, 23, 41])
        try original.write(to: file)
        try workspace.publish(texts: [.init(path: "source/history.md", text: "Original objective; verified result; remaining work")],
                              files: [.init(path: "source/evidence.pdf", fileURL: file,
                                            expectedSHA256: ContinuityWorkspace.sha256(original), expectedSize: original.count)],
                              coverage: [.init(component: "source history", status: .partial, detail: "Only visible history is captured")],
                              limitations: ["Cloud tools need their own account grants"], expectedRevision: 0)
        return (workspace, root.appending(path: "Transfers"))
    }

    private func prepare(_ workspace: ContinuityWorkspace, root: URL,
                         account: String = Sandbox.accountB,
                         kind: NativeContinuationPlan.Kind = .codeProject) throws -> (NativeContinuationPlan.Receipt, URL) {
        try NativeContinuationPlan.prepare(workspace: workspace, expectedRevision: workspace.load().revision,
                                           profileID: "destination", profileLabel: "DESTINATION", accountID: account,
                                           kind: kind, in: root)
    }

    private func encodedPlan(_ plan: NativeContinuationPlan, edit: (inout [String: Any]) -> Void) throws -> NativeContinuationPlan {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        edit(&object)
        return try JSONDecoder().decode(NativeContinuationPlan.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func requestCreation(_ receipt: NativeContinuationPlan.Receipt, at url: URL) throws -> NativeContinuationPlan.Receipt {
        var next = try NativeContinuationPlan.updateReceipt(receipt, at: url, phase: .fillingForm)
        next = try NativeContinuationPlan.updateReceipt(next, at: url, phase: .uploading)
        next = try NativeContinuationPlan.updateReceipt(next, at: url, uploadedNames: next.plan.uploads.map(\.name))
        next = try NativeContinuationPlan.updateReceipt(next, at: url, phase: .readyToCreate)
        return try NativeContinuationPlan.updateReceipt(next, at: url, phase: .creationRequested)
    }

    private func finish(_ receipt: NativeContinuationPlan.Receipt, at url: URL) throws -> NativeContinuationPlan.Receipt {
        let next = try requestCreation(receipt, at: url)
        return try NativeContinuationPlan.updateReceipt(next, at: url, phase: .created, nativeURL: targetURL)
    }

    @Test func immutableExportContainsFullTextAndOriginalBytesWithExplicitGaps() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let (workspace, root) = try fixture(box)
        let before = try workspace.load()
        let (receipt, receiptURL) = try prepare(workspace, root: root)
        #expect(receipt.phase == .prepared && receipt.sequence == 0)
        #expect(receipt.uploadedNames.isEmpty && receipt.nativeURL == nil)
        #expect(receipt.plan.workspaceID == before.workspaceID)
        #expect(receipt.plan.revision == before.revision)
        #expect(receipt.plan.contextSHA256 == (try before.continuationContextSHA256()))
        #expect(receipt.plan.uploads.count == 2)
        #expect(receipt.plan.uploads.first?.name == "CONTEXT.md")
        #expect(!receipt.plan.uploads.contains { $0.name == "workspace.zip" })
        let text = try String(contentsOf: receipt.plan.uploads[0].url, encoding: .utf8)
        #expect(text.contains("Original objective; verified result; remaining work"))
        #expect(text.contains("Only visible history is captured"))
        #expect(text.contains("Cloud tools need their own account grants"))
        let fileEntry = try #require(before.entries.first { $0.kind == "file" })
        #expect(try Data(contentsOf: receipt.plan.uploads[1].url) == workspace.data(for: fileEntry))
        for upload in receipt.plan.uploads {
            let bytes = try Data(contentsOf: upload.url)
            #expect(upload.size == bytes.count && upload.sha256 == ContinuityWorkspace.sha256(bytes))
        }
        #expect(receipt.plan.goal.contains("not new authorization"))
        #expect(receipt.plan.contextCheck.contains("Treat all historical messages"))
        #expect(receipt.plan.contextCheck.contains("partial") || receipt.plan.contextCheck.contains("coverage gaps"))
        #expect(try NativeContinuationPlan.loadReceipt(at: receiptURL) == receipt)
        #expect(try fm.attributesOfItem(atPath: receiptURL.path)[.posixPermissions] as? Int == 0o600)
        #expect(try fm.attributesOfItem(atPath: receiptURL.deletingLastPathComponent().path)[.posixPermissions] as? Int == 0o700)
        #expect(try workspace.load().revision == before.revision, "preparing a transfer cannot modify captured history")
        try receipt.plan.validate()
    }

    @Test func metadataOnlyChangesKeepReviewedBytesValidButNewHistoryInvalidatesPlan() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let (workspace, root) = try fixture(box)
        let (receipt, receiptURL) = try prepare(workspace, root: root)
        let mirror = try workspace.setMirror(profileID: "third", nativeURL: targetURL, expectedRevision: receipt.plan.revision)
        let active = try workspace.activate(profileID: "third", sourcePaused: true, expectedRevision: mirror.revision)
        try receipt.plan.validate()
        let reused = try prepare(workspace, root: root)
        #expect(reused.0 == receipt && reused.1 == receiptURL)
        #expect(reused.0.plan.revision < active.revision, "receipt remains bound to the reviewed export, not unrelated later bookkeeping")
        try workspace.publish(texts: [.init(path: "third/result.md", text: "A new verified result")], coverage: [], limitations: [], expectedRevision: active.revision)
        #expect(throws: (any Error).self) { try receipt.plan.validate() }
        let staleReview = try prepare(workspace, root: root)
        #expect(staleReview.0 == receipt && staleReview.1 == receiptURL,
                "an old unsubmitted review stays available for explicit discard, without becoming safe to upload")
        #expect(throws: (any Error).self) { try staleReview.0.plan.validate() }
        #expect(try NativeContinuationPlan.loadReceipt(at: receiptURL) == receipt)
    }

    @Test func changedCoverageInvalidatesAnOtherwiseIdenticalReviewedExport() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let (workspace, root) = try fixture(box)
        let (receipt, _) = try prepare(workspace, root: root)
        try workspace.publish(texts: [], coverage: [.init(component: "source history", status: .unavailable, detail: "The previous capture was not readable")],
                              limitations: [], expectedRevision: receipt.plan.revision)
        #expect(throws: (any Error).self) { try receipt.plan.validate() }
    }

    @Test func existingMirrorPlansUpdateTheSameObjectAndRejectChangedDestination() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let (workspace, root) = try fixture(box)
        let mirror = try workspace.setMirror(profileID: "destination", nativeURL: targetURL, expectedRevision: workspace.load().revision)
        let (receipt, _) = try prepare(workspace, root: root)
        #expect(receipt.plan.operation == .updateExisting)
        #expect(receipt.plan.existingNativeURL == targetURL)
        try receipt.plan.validate()
        #expect(throws: (any Error).self) { try prepare(workspace, root: root, kind: .coworkConversation) }
        try workspace.setMirror(profileID: "destination", nativeURL: URL(string: "https://claude.ai/epitaxy/project/chan_replacement")!, expectedRevision: mirror.revision)
        #expect(throws: (any Error).self) { try receipt.plan.validate() }
        #expect(throws: (any Error).self) { try prepare(workspace, root: root) }
    }

    @Test func aCompletedTransferWithNewResultsPreparesAnUpdateWithoutLosingItsReceipt() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let (workspace, root) = try fixture(box)
        let (receipt, oldURL) = try prepare(workspace, root: root)
        #expect(receipt.plan.operation == .create && receipt.plan.existingNativeURL == nil)
        let completed = try finish(receipt, at: oldURL)
        let mirror = try workspace.setMirror(profileID: "destination", nativeURL: targetURL, expectedRevision: receipt.plan.revision)
        let unchanged = try prepare(workspace, root: root)
        #expect(unchanged.0 == completed && unchanged.1 == oldURL)
        try workspace.publish(texts: [.init(path: "destination/result.md", text: "Latest destination result preserved for the return trip")],
                              coverage: [], limitations: [], expectedRevision: mirror.revision)
        let (newReceipt, newURL) = try prepare(workspace, root: root)
        #expect(newURL != oldURL && newReceipt.plan.id != completed.plan.id)
        #expect(newReceipt.plan.operation == .updateExisting && newReceipt.plan.existingNativeURL == targetURL)
        #expect(newReceipt.plan.contextSHA256 != completed.plan.contextSHA256)
        #expect(try NativeContinuationPlan.loadReceipt(at: oldURL) == completed)
        let newText = try String(contentsOf: newReceipt.plan.uploads[0].url, encoding: .utf8)
        #expect(newText.contains("Original objective; verified result; remaining work"))
        #expect(newText.contains("Latest destination result preserved for the return trip"))
        try newReceipt.plan.validate()
    }

    @Test func completedCreationCannotBeRecreatedWhileItsNativeLinkIsUnregistered() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let (workspace, root) = try fixture(box)
        let (receipt, receiptURL) = try prepare(workspace, root: root)
        let completed = try finish(receipt, at: receiptURL)
        try workspace.publish(texts: [.init(path: "source/new-result.md", text: "Later result")],
                              coverage: [], limitations: [], expectedRevision: receipt.plan.revision)
        #expect(throws: NativeContinuationPlan.TransferError.uncertainCreation) { try prepare(workspace, root: root) }
        #expect(try NativeContinuationPlan.loadReceipt(at: receiptURL) == completed)
        #expect(try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { UUID(uuidString: $0.lastPathComponent) != nil }.count == 1)
    }

    @Test func completedReceiptCannotSilentlyOverrideAChangedRegisteredLink() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let (workspace, root) = try fixture(box)
        let (receipt, receiptURL) = try prepare(workspace, root: root)
        let completed = try finish(receipt, at: receiptURL)
        try workspace.setMirror(profileID: "destination", nativeURL: URL(string: "https://claude.ai/epitaxy/project/chan_different")!,
                                expectedRevision: receipt.plan.revision)
        #expect(throws: (any Error).self) { try prepare(workspace, root: root) }
        #expect(try NativeContinuationPlan.loadReceipt(at: receiptURL) == completed)
    }

    @Test func manualNativeRegistrationAfterPreparationPreventsASecondCreationPlan() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let (workspace, root) = try fixture(box)
        let (receipt, receiptURL) = try prepare(workspace, root: root)
        try workspace.setMirror(profileID: "destination", nativeURL: targetURL, expectedRevision: receipt.plan.revision)
        #expect(throws: (any Error).self) { try prepare(workspace, root: root) }
        #expect(try NativeContinuationPlan.loadReceipt(at: receiptURL) == receipt)
    }

    @Test func uncertainCreationRemainsRecoverableAfterNewCaptureThenLatestContextUpdatesItsRecoveredObject() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let (workspace, root) = try fixture(box)
        let (initial, receiptURL) = try prepare(workspace, root: root)
        let uncertain = try requestCreation(initial, at: receiptURL)
        let originalBytes = try Data(contentsOf: uncertain.plan.uploads[0].url)
        let newer = try workspace.publish(texts: [.init(path: "source/later.md", text: "Captured after the interrupted creation")],
                                          coverage: [], limitations: [], expectedRevision: initial.plan.revision)
        #expect(throws: (any Error).self) { try uncertain.plan.validate() }
        let resumed = try prepare(workspace, root: root)
        #expect(resumed.0 == uncertain && resumed.1 == receiptURL)
        #expect(resumed.0.plan.revision < newer.revision)
        let observation = NativeContinuationPlan.RecoveryRecord(observedNativeURL: targetURL,
            confirmedAt: Date(timeIntervalSince1970: 100), evidenceDescription: "Exact observed Project name; context still unchecked",
            phase: .created, contextWasNewer: true)
        let recovered = try NativeContinuationPlan.updateReceipt(uncertain, at: receiptURL, phase: .created,
            nativeURL: targetURL, message: "Recovered native identity only", recovery: observation)
        #expect(recovered.recovery == observation && recovered.phase == .created)
        #expect(recovered.plan == uncertain.plan && recovered.plan.revision == initial.plan.revision)
        #expect(try Data(contentsOf: recovered.plan.uploads[0].url) == originalBytes)
        try workspace.setMirror(profileID: "destination", nativeURL: targetURL, expectedRevision: newer.revision)
        let (update, updateURL) = try prepare(workspace, root: root)
        #expect(updateURL != receiptURL && update.plan.id != recovered.plan.id)
        #expect(update.plan.operation == .updateExisting && update.plan.existingNativeURL == targetURL)
        #expect(update.recovery == nil && update.phase == .prepared)
        #expect(update.plan.contextSHA256 != recovered.plan.contextSHA256)
        #expect(try NativeContinuationPlan.loadReceipt(at: receiptURL) == recovered)
        #expect(try String(contentsOf: update.plan.uploads[0].url, encoding: .utf8).contains("Captured after the interrupted creation"))
    }

    @Test func recoveryEvidenceMustMatchTheUncertainPhaseAndPinnedNativeURL() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let (workspace, root) = try fixture(box)
        let (initial, receiptURL) = try prepare(workspace, root: root)
        let evidence = NativeContinuationPlan.RecoveryRecord(observedNativeURL: targetURL,
            confirmedAt: Date(timeIntervalSince1970: 100), evidenceDescription: "Observed transfer reference; reply not reviewed",
            phase: .checkSubmitted, contextWasNewer: false)
        #expect(throws: (any Error).self) { try NativeContinuationPlan.updateReceipt(initial, at: receiptURL, recovery: evidence) }
        let created = try finish(initial, at: receiptURL)
        #expect(throws: (any Error).self) { try NativeContinuationPlan.updateReceipt(created, at: receiptURL, recovery: evidence) }
        let uncertain = try NativeContinuationPlan.updateReceipt(created, at: receiptURL, phase: .checkRequested)
        let before = try Data(contentsOf: receiptURL)
        #expect(throws: (any Error).self) { try NativeContinuationPlan.updateReceipt(uncertain, at: receiptURL, phase: .checkSubmitted,
                                                                                 nativeURL: sourceURL, recovery: evidence) }
        let wrongPhase = NativeContinuationPlan.RecoveryRecord(observedNativeURL: targetURL, confirmedAt: evidence.confirmedAt,
            evidenceDescription: evidence.evidenceDescription, phase: .created, contextWasNewer: false)
        #expect(throws: (any Error).self) { try NativeContinuationPlan.updateReceipt(uncertain, at: receiptURL,
                                                                                 phase: .checkSubmitted, recovery: wrongPhase) }
        #expect(try Data(contentsOf: receiptURL) == before)
        let recovered = try NativeContinuationPlan.updateReceipt(uncertain, at: receiptURL, phase: .checkSubmitted, recovery: evidence)
        #expect(recovered.recovery == evidence && recovered.nativeURL == targetURL)
        #expect(recovered.plan == uncertain.plan)
        #expect(try NativeContinuationPlan.loadReceipt(at: receiptURL) == recovered)
        #expect(throws: NativeContinuationPlan.TransferError.staleReceipt) {
            try NativeContinuationPlan.updateReceipt(uncertain, at: receiptURL, phase: .checkSubmitted, recovery: evidence)
        }
    }

    @Test func abandoningAnUnsubmittedPlanAllowsNewCapturedContextWithoutErasingTheOldAudit() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let (workspace, root) = try fixture(box)
        let (initial, oldURL) = try prepare(workspace, root: root)
        let filling = try NativeContinuationPlan.updateReceipt(initial, at: oldURL, phase: .fillingForm)
        let uploading = try NativeContinuationPlan.updateReceipt(filling, at: oldURL, phase: .uploading,
                                                                uploadedNames: [filling.plan.uploads[0].name])
        let originalBytes = try Data(contentsOf: uploading.plan.uploads[0].url)
        try workspace.publish(texts: [.init(path: "source/newer.md", text: "New work after old preparation")],
                              coverage: [], limitations: [], expectedRevision: initial.plan.revision)
        let staleReview = try prepare(workspace, root: root)
        #expect(staleReview.0 == uploading && staleReview.1 == oldURL)
        #expect(throws: (any Error).self) { try staleReview.0.plan.validate() }
        let abandoned = try NativeContinuationPlan.abandonReceipt(at: oldURL)
        #expect(abandoned.isAbandoned && abandoned.abandonedAt != nil)
        #expect(abandoned.plan == uploading.plan && abandoned.phase == uploading.phase)
        #expect(abandoned.uploadedNames == uploading.uploadedNames)
        #expect(try Data(contentsOf: abandoned.plan.uploads[0].url) == originalBytes)
        let (latest, latestURL) = try prepare(workspace, root: root)
        #expect(latestURL != oldURL && latest.plan.id != abandoned.plan.id)
        #expect(!latest.isAbandoned && latest.phase == .prepared)
        #expect(latest.plan.contextSHA256 != abandoned.plan.contextSHA256)
        #expect(try NativeContinuationPlan.loadReceipt(at: oldURL) == abandoned)
        #expect(throws: (any Error).self) { try NativeContinuationPlan.updateReceipt(abandoned, at: oldURL, phase: .readyToCreate) }
    }

    @Test(arguments: [NativeContinuationPlan.Phase.prepared, .fillingForm, .uploading, .readyToCreate])
    func unsubmittedPhasesCanBeAbandonedWithoutDeletingTheirExport(_ phase: NativeContinuationPlan.Phase) throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let (workspace, root) = try fixture(box)
        var (receipt, url) = try prepare(workspace, root: root)
        if phase != .prepared { receipt = try NativeContinuationPlan.updateReceipt(receipt, at: url, phase: .fillingForm) }
        if [.uploading, .readyToCreate].contains(phase) { receipt = try NativeContinuationPlan.updateReceipt(receipt, at: url, phase: .uploading) }
        if phase == .readyToCreate {
            receipt = try NativeContinuationPlan.updateReceipt(receipt, at: url, phase: .readyToCreate, uploadedNames: receipt.plan.uploads.map(\.name))
        }
        let abandoned = try NativeContinuationPlan.abandonReceipt(at: url)
        #expect(abandoned.isAbandoned && abandoned.phase == phase && abandoned.plan == receipt.plan)
        #expect(fm.fileExists(atPath: abandoned.plan.uploads[0].url.path))
        let (newReceipt, newURL) = try prepare(workspace, root: root)
        #expect(!newReceipt.isAbandoned && newURL != url)
    }

    @Test(arguments: [NativeContinuationPlan.Phase.creationRequested, .created, .checkRequested, .checkSubmitted])
    func submittedOrUncertainPhasesCannotBeAbandonedToPermitDuplicateWrites(_ phase: NativeContinuationPlan.Phase) throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let (workspace, root) = try fixture(box)
        let (initial, url) = try prepare(workspace, root: root)
        var receipt = try requestCreation(initial, at: url)
        if phase != .creationRequested { receipt = try NativeContinuationPlan.updateReceipt(receipt, at: url, phase: .created, nativeURL: targetURL) }
        if [.checkRequested, .checkSubmitted].contains(phase) { receipt = try NativeContinuationPlan.updateReceipt(receipt, at: url, phase: .checkRequested) }
        if phase == .checkSubmitted { receipt = try NativeContinuationPlan.updateReceipt(receipt, at: url, phase: .checkSubmitted) }
        let before = try Data(contentsOf: url)
        #expect(throws: (any Error).self) { try NativeContinuationPlan.abandonReceipt(at: url) }
        #expect(try Data(contentsOf: url) == before)
        #expect(try NativeContinuationPlan.loadReceipt(at: url) == receipt)
    }

    @Test func receiptsWrittenBeforeRecoveryAndDiscardFieldsRemainReadableWithoutInventingEvidence() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let (workspace, root) = try fixture(box)
        let (receipt, url) = try prepare(workspace, root: root)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        object.removeValue(forKey: "recovery")
        object.removeValue(forKey: "abandonedAt")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let restored = try NativeContinuationPlan.loadReceipt(at: url)
        #expect(restored == receipt && restored.recovery == nil && restored.abandonedAt == nil && !restored.isAbandoned)
    }

    @Test(arguments: ["same-size-change", "truncate", "symlink", "hardlink", "missing"])
    func changedExportBytesOrFileIdentityCannotBeUploaded(_ mode: String) throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let (workspace, root) = try fixture(box)
        let (receipt, _) = try prepare(workspace, root: root)
        let upload = receipt.plan.uploads[1]
        let original = try Data(contentsOf: upload.url)
        switch mode {
        case "same-size-change": try Data(repeating: 65, count: original.count).write(to: upload.url)
        case "truncate": try Data(original.prefix(2)).write(to: upload.url)
        case "symlink", "hardlink":
            let outside = box.root.resolvingSymlinksInPath().appending(path: "replacement.pdf")
            try original.write(to: outside)
            try fm.removeItem(at: upload.url)
            if mode == "symlink" { try fm.createSymbolicLink(at: upload.url, withDestinationURL: outside) }
            else { try fm.linkItem(at: outside, to: upload.url) }
        default: try fm.removeItem(at: upload.url)
        }
        #expect(throws: (any Error).self) { try receipt.plan.validate() }
        #expect(try workspace.load().revision == receipt.plan.revision)
    }

    @Test(arguments: ["empty", "duplicate", "outside-root", "renamed"])
    func forgedUploadInventoryIsRejectedBeforeNativeWrites(_ mode: String) throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let (workspace, root) = try fixture(box)
        let (receipt, _) = try prepare(workspace, root: root)
        let altered = try encodedPlan(receipt.plan) { object in
            var uploads = object["uploads"] as! [[String: Any]]
            switch mode {
            case "empty": uploads = []
            case "duplicate": uploads.append(uploads[0])
            case "outside-root": uploads[0]["url"] = workspace.continuationFile.absoluteString
            default: uploads[0]["name"] = "misleading.md"
            }
            object["uploads"] = uploads
        }
        #expect(throws: (any Error).self) { try altered.validate() }
    }

    @Test func retryReusesItsReceiptAndRejectsAccountKindOrDuplicateAttemptChanges() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let (workspace, root) = try fixture(box)
        let (initial, receiptURL) = try prepare(workspace, root: root)
        let filling = try NativeContinuationPlan.updateReceipt(initial, at: receiptURL, phase: .fillingForm)
        let reused = try prepare(workspace, root: root)
        #expect(reused.0 == filling && reused.1 == receiptURL)
        #expect(throws: (any Error).self) { try prepare(workspace, root: root, account: Sandbox.accountA) }
        #expect(throws: (any Error).self) { try prepare(workspace, root: root, kind: .coworkConversation) }
        let duplicate = root.appending(path: UUID().uuidString)
        try fm.createDirectory(at: duplicate, withIntermediateDirectories: false)
        try fm.copyItem(at: receiptURL, to: duplicate.appending(path: "receipt.json"))
        #expect(throws: (any Error).self) { try prepare(workspace, root: root) }
        #expect(try NativeContinuationPlan.loadReceipt(at: receiptURL) == filling)
    }

    @Test func receiptTransitionsRetainUncertainCreationAndRejectStaleWritersOrASecondNativeObject() throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let (workspace, root) = try fixture(box)
        let (initial, receiptURL) = try prepare(workspace, root: root)
        #expect(throws: (any Error).self) { try NativeContinuationPlan.updateReceipt(initial, at: receiptURL, phase: .created, nativeURL: targetURL) }
        var current = try NativeContinuationPlan.updateReceipt(initial, at: receiptURL, phase: .fillingForm)
        #expect(throws: NativeContinuationPlan.TransferError.staleReceipt) {
            try NativeContinuationPlan.updateReceipt(initial, at: receiptURL, message: "stale observer")
        }
        current = try NativeContinuationPlan.updateReceipt(current, at: receiptURL, phase: .uploading)
        let beforeIncomplete = try Data(contentsOf: receiptURL)
        #expect(throws: (any Error).self) { try NativeContinuationPlan.updateReceipt(current, at: receiptURL, phase: .readyToCreate) }
        #expect(try Data(contentsOf: receiptURL) == beforeIncomplete)
        current = try NativeContinuationPlan.updateReceipt(current, at: receiptURL, uploadedNames: current.plan.uploads.map(\.name))
        current = try NativeContinuationPlan.updateReceipt(current, at: receiptURL, phase: .readyToCreate)
        #expect(!current.creationMayHaveHappened)
        current = try NativeContinuationPlan.updateReceipt(current, at: receiptURL, phase: .creationRequested)
        #expect(current.creationMayHaveHappened)
        #expect(throws: (any Error).self) { try NativeContinuationPlan.updateReceipt(current, at: receiptURL, phase: .prepared) }
        #expect(throws: (any Error).self) { try NativeContinuationPlan.updateReceipt(current, at: receiptURL, phase: .created) }
        current = try NativeContinuationPlan.updateReceipt(current, at: receiptURL, phase: .created, nativeURL: targetURL)
        #expect(throws: (any Error).self) { try NativeContinuationPlan.updateReceipt(current, at: receiptURL, nativeURL: sourceURL) }
        current = try NativeContinuationPlan.updateReceipt(current, at: receiptURL, phase: .checkRequested)
        current = try NativeContinuationPlan.updateReceipt(current, at: receiptURL, phase: .checkSubmitted)
        #expect(current.nativeURL == targetURL && current.creationMayHaveHappened)
        #expect(try NativeContinuationPlan.loadReceipt(at: receiptURL) == current)
        #expect(current.lastMessage == nil, "a phase transition is not an assertion that Claude read the context")
    }

    @Test(arguments: [["missing.txt"], ["CONTEXT.md", "CONTEXT.md"]])
    func invalidUploadedNamesNeverReplaceAValidReceipt(_ names: [String]) throws {
        let box = try Sandbox()
        defer { try? fm.removeItem(at: box.root) }
        let (workspace, root) = try fixture(box)
        let (receipt, url) = try prepare(workspace, root: root)
        let before = try Data(contentsOf: url)
        #expect(throws: (any Error).self) { try NativeContinuationPlan.updateReceipt(receipt, at: url, uploadedNames: names) }
        #expect(try Data(contentsOf: url) == before)
        #expect(try NativeContinuationPlan.loadReceipt(at: url) == receipt)
    }

    @Test(arguments: ["http://claude.ai/epitaxy/project/chan_destination", "claude://epitaxy/project/chan_destination",
                      "file:///epitaxy/project/chan_destination", "https://claude.ai.evil.test/epitaxy/project/chan_destination",
                      "https://user:secret@claude.ai/epitaxy/project/chan_destination", "https://claude.ai:443/epitaxy/project/chan_destination",
                      "https://claude.ai/epitaxy/project/chan_destination?thread=cse_another", "https://claude.ai/epitaxy/project/chan_destination#anchor",
                      "https://claude.ai/epitaxy/projects/browse", "https://claude.ai/epitaxy/project/chan_", "https://claude.ai/epitaxy/project/chan_invalid-name",
                      "https://claude.ai/epitaxy//project/chan_destination", "https://claude.ai/epitaxy/project/chan_destination/", "https://claude.ai//epitaxy/project/chan_destination"])
    func unsafeNativeProjectLinksAreRejected(_ value: String) throws {
        #expect(!NativeContinuationPlan.isNativeProjectURL(try #require(URL(string: value))))
    }

    @Test func nativeLinksMustMatchTheChosenSurface() {
        let cowork = URL(string: "https://claude.ai/cowork/cse_destination")!
        #expect(NativeContinuationPlan.isNativeURL(targetURL, kind: .codeProject))
        #expect(!NativeContinuationPlan.isNativeURL(targetURL, kind: .coworkConversation))
        #expect(NativeContinuationPlan.isNativeURL(cowork, kind: .coworkConversation))
        #expect(!NativeContinuationPlan.isNativeURL(cowork, kind: .codeProject))
        #expect(!NativeContinuationPlan.isNativeURL(URL(string: "https://claude.ai/cowork/cse_destination?token=secret")!, kind: .coworkConversation))
        #expect(!NativeContinuationPlan.isNativeURL(URL(string: "http://claude.ai/cowork/cse_destination")!, kind: .coworkConversation))
    }
}
