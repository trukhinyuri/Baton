import AppKit
import ApplicationServices
import Foundation

/// User-initiated writes to the observed native Code Projects UI. This is deliberately separate
/// from the read-only collector. No web API, credential transfer, feature flag, or TCC change is used.
@MainActor
public enum ClaudeNativeContinuation {
    public enum NativeError: LocalizedError, Equatable {
        case permission, identity, windowChanged, unsupported(String), staleControl, draft, upload(String), timedOut
        public var errorDescription: String? {
            switch self {
            case .permission: "Allow Claude Profiles window access before transferring context."
            case .identity: "The selected signed-in Claude profile could not be pinned, or its account changed."
            case .windowChanged: "The selected Claude window changed. Nothing further was submitted."
            case let .unsupported(detail): "This Claude interface is not supported for assisted transfer: \(detail). Your captured context remains saved."
            case .staleControl: "Claude changed the selected control before it could be used. Stop and inspect the current form before retrying."
            case .draft: "The destination already contains a draft or different attachments. Finish or save it before transferring; Claude Profiles will not overwrite it."
            case let .upload(name): "Claude did not accept \(name), or its upload could not be verified. No file type filter was bypassed and no file was silently omitted."
            case .timedOut: "Claude did not reach the expected state in time. The receipt records the last observed step; inspect it before retrying."
            }
        }
    }

    public static func createContinuation(receiptURL: URL, paths: Paths = .standard,
                                     progress: @escaping (String) -> Void = { _ in }) async throws -> NativeContinuationPlan.Receipt {
        var receipt = try NativeContinuationPlan.loadReceipt(at: receiptURL)
        guard !receipt.isAbandoned else { throw NativeContinuationPlan.TransferError.invalid("this transfer plan was discarded; prepare a new review") }
        let initialPlan = receipt.plan
        try await Task.detached { try initialPlan.validate() }.value
        if initialPlan.operation == .updateExisting { return try await updateContinuation(receiptURL: receiptURL, paths: paths, progress: progress) }
        let driver = try Driver(plan: receipt.plan, paths: paths)
        if receipt.nativeURL != nil { return receipt } // A completed step never creates another Project.
        guard !receipt.creationMayHaveHappened else { throw NativeContinuationPlan.TransferError.uncertainCreation }
        guard try ContinuityWorkspace(directory: initialPlan.workspaceDirectory).load().mirrors[initialPlan.profileID] == nil else {
            throw NativeContinuationPlan.TransferError.changed("a native continuation was registered since preparation")
        }
        do {
            progress("Opening \(receipt.plan.kind == .codeProject ? "Projects" : "Cowork") in \(receipt.plan.profileLabel)…")
            if receipt.plan.kind == .codeProject { try await driver.openNewProject() }
            else { try await driver.openCowork() }
            if receipt.phase == .prepared {
                if receipt.plan.kind == .codeProject { try driver.requireEmptyForm() }
                else { try driver.requireEmptyCowork() }
                receipt = try NativeContinuationPlan.updateReceipt(receipt, at: receiptURL, phase: .fillingForm)
            }
            if receipt.plan.kind == .codeProject {
                try driver.validateForm(plan: receipt.plan, allowMissingFields: receipt.phase == .fillingForm)
                try driver.fillForm(plan: receipt.plan)
            } else { try driver.validateCowork(plan: receipt.plan) }
            if receipt.phase == .fillingForm {
                receipt = try NativeContinuationPlan.updateReceipt(receipt, at: receiptURL, phase: .uploading)
            }
            for upload in receipt.plan.uploads {
                try Task.checkCancellation()
                let plan = receipt.plan
                try await Task.detached { try plan.validate() }.value
                if plan.kind == .codeProject { try driver.validateForm(plan: plan, allowMissingFields: false) }
                else { try driver.validateCowork(plan: plan) }
                if !driver.hasAttachment(upload.name) {
                    progress("Attaching \(upload.name)…")
                    try await driver.attach(upload)
                }
                guard driver.hasAttachment(upload.name) else { throw NativeError.upload(upload.name) }
                if !receipt.uploadedNames.contains(upload.name) {
                    receipt = try NativeContinuationPlan.updateReceipt(receipt, at: receiptURL,
                                                                       uploadedNames: receipt.uploadedNames + [upload.name])
                }
            }
            let plan = receipt.plan
            try await Task.detached { try plan.validate() }.value
            guard try ContinuityWorkspace(directory: plan.workspaceDirectory).load().mirrors[plan.profileID] == nil else {
                throw NativeContinuationPlan.TransferError.changed("a native continuation was registered before creation")
            }
            if plan.kind == .codeProject { try driver.validateForm(plan: plan, allowMissingFields: false) }
            else { try driver.validateCowork(plan: plan) }
            guard driver.attachmentNames().count == plan.uploads.count,
                  Set(driver.attachmentNames()) == Set(plan.uploads.map(\.name)) else { throw NativeError.draft }
            if receipt.phase == .uploading {
                receipt = try NativeContinuationPlan.updateReceipt(receipt, at: receiptURL, phase: .readyToCreate)
            }
            if plan.kind == .coworkConversation {
                let prompt = try driver.control(role: "AXTextArea", label: "Write your prompt to Claude")
                if prompt.value != plan.contextCheck { try driver.set(prompt, value: plan.contextCheck) }
            }
            let create = try driver.control(role: "AXButton", label: plan.kind == .codeProject ? "Create project" : "Start task",
                                            scope: plan.kind == .codeProject ? "New project" : nil)
            guard create.enabled else { throw NativeError.unsupported("Create project is unavailable") }
            // Persist BEFORE the non-idempotent click. A timeout cannot cause a second create.
            receipt = try NativeContinuationPlan.updateReceipt(receipt, at: receiptURL, phase: .creationRequested)
            progress(plan.kind == .codeProject ? "Creating the separate Project. Claude may initialize it using this account's quota…" : "Starting the separate Cowork conversation with the reviewed read-only check…")
            try driver.press(create)
            let nativeURL = try await driver.waitForCreatedContinuation()
            receipt = try NativeContinuationPlan.updateReceipt(receipt, at: receiptURL,
                                                               phase: plan.kind == .codeProject ? .created : .checkSubmitted, nativeURL: nativeURL,
                                                               message: plan.kind == .codeProject ? "Native Project created with the reviewed attachment chips. File contents and capture completeness still require a context check." : "Cowork created with the reviewed read-only check. Inspect Claude's reply; submission does not verify context completeness.")
            progress(plan.kind == .codeProject ? "Project created. Its context has not yet been checked." : "Cowork check submitted. Inspect its reply and gaps.")
            return receipt
        } catch {
            // Retain every observed step. Cancellation does not delete the native form or uploaded files.
            if let current = try? NativeContinuationPlan.loadReceipt(at: receiptURL) {
                _ = try? NativeContinuationPlan.updateReceipt(current, at: receiptURL, message: error.localizedDescription)
            }
            throw error
        }
    }

    private static func updateContinuation(receiptURL: URL, paths: Paths,
                                           progress: @escaping (String) -> Void) async throws -> NativeContinuationPlan.Receipt {
        var receipt = try NativeContinuationPlan.loadReceipt(at: receiptURL)
        guard !receipt.isAbandoned else { throw NativeContinuationPlan.TransferError.invalid("this transfer plan was discarded; prepare a new review") }
        let plan = receipt.plan
        guard plan.operation == .updateExisting, let url = plan.existingNativeURL else { throw NativeError.identity }
        let driver = try Driver(plan: plan, paths: paths)
        try driver.requireDestination(url)
        if receipt.phase == .checkSubmitted { return receipt }
        guard receipt.phase != .creationRequested else {
            throw NativeError.unsupported("the previous check may already have been sent; inspect the recorded conversation before sending again")
        }
        do {
            if receipt.phase == .prepared {
                try driver.requireEmptyExisting()
                receipt = try NativeContinuationPlan.updateReceipt(receipt, at: receiptURL, phase: .fillingForm)
            }
            try driver.validateExisting()
            if receipt.phase == .fillingForm { receipt = try NativeContinuationPlan.updateReceipt(receipt, at: receiptURL, phase: .uploading) }
            for upload in plan.uploads {
                try await Task.detached { try plan.validate() }.value
                try driver.validateExisting()
                if !driver.hasAttachment(upload.name) {
                    progress("Attaching latest context to the recorded continuation: \(upload.name)…")
                    try await driver.attach(upload)
                }
                guard driver.hasAttachment(upload.name) else { throw NativeError.upload(upload.name) }
                if !receipt.uploadedNames.contains(upload.name) {
                    receipt = try NativeContinuationPlan.updateReceipt(receipt, at: receiptURL, uploadedNames: receipt.uploadedNames + [upload.name])
                }
            }
            try await Task.detached { try plan.validate() }.value
            try driver.validateExisting()
            guard driver.attachmentNames().count == plan.uploads.count,
                  Set(driver.attachmentNames()) == Set(plan.uploads.map(\.name)) else { throw NativeError.draft }
            if receipt.phase == .uploading { receipt = try NativeContinuationPlan.updateReceipt(receipt, at: receiptURL, phase: .readyToCreate) }
            let prompt = try driver.control(role: "AXTextArea", label: driver.promptLabel)
            if prompt.value != plan.contextCheck { try driver.set(prompt, value: plan.contextCheck) }
            try driver.requireDestination(url)
            let send = try driver.sendControl()
            guard send.enabled else { throw NativeError.unsupported("Claude is not ready to receive the latest context check") }
            // Despite the generic phase name, an update requests only the check, never another object.
            receipt = try NativeContinuationPlan.updateReceipt(receipt, at: receiptURL, phase: .creationRequested)
            progress("Sending the reviewed read-only check to the recorded continuation…")
            try driver.press(send)
            try await driver.waitUntil {
                try driver.requireDestination(url)
                return try driver.control(role: "AXTextArea", label: driver.promptLabel).value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            }
            return try NativeContinuationPlan.updateReceipt(receipt, at: receiptURL, phase: .checkSubmitted, nativeURL: url,
                                                            message: "Latest context attached and its read-only check submitted to the existing continuation. Inspect the reply and gaps; no new native object was created.")
        } catch {
            if let current = try? NativeContinuationPlan.loadReceipt(at: receiptURL) {
                _ = try? NativeContinuationPlan.updateReceipt(current, at: receiptURL, message: error.localizedDescription)
            }
            throw error
        }
    }

    /// Sending is a separate explicit user action. This observes submission, not reply correctness.
    public static func sendContextCheck(receiptURL: URL, paths: Paths = .standard) async throws -> NativeContinuationPlan.Receipt {
        var receipt = try NativeContinuationPlan.loadReceipt(at: receiptURL)
        guard !receipt.isAbandoned else { throw NativeContinuationPlan.TransferError.invalid("this transfer plan was discarded; prepare a new review") }
        guard receipt.plan.kind == .codeProject, receipt.phase == .created, let nativeURL = receipt.nativeURL else {
            throw NativeError.unsupported("the check was already submitted or its outcome needs inspection; it will not be sent twice")
        }
        let plan = receipt.plan
        try await Task.detached { try plan.validate() }.value
        let driver = try Driver(plan: plan, paths: paths)
        try driver.requireProject(nativeURL)
        let prompt = try driver.control(role: "AXTextArea", label: "Prompt")
        guard (prompt.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.value == plan.contextCheck else { throw NativeError.draft }
        if prompt.value != plan.contextCheck { try driver.set(prompt, value: plan.contextCheck) }
        try driver.requireProject(nativeURL)
        let send = try driver.control(role: "AXButton", label: "Send")
        guard send.enabled else { throw NativeError.unsupported("Claude is not ready to send the check") }
        receipt = try NativeContinuationPlan.updateReceipt(receipt, at: receiptURL, phase: .checkRequested)
        try driver.press(send)
        try await driver.waitUntil {
            try driver.requireProject(nativeURL)
            return try driver.control(role: "AXTextArea", label: "Prompt").value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        }
        return try NativeContinuationPlan.updateReceipt(receipt, at: receiptURL, phase: .checkSubmitted,
                                                        message: "Read-only check submitted. Inspect Claude's reply and gaps; submission is not verification of complete context.")
    }

    /// A preview retains the exact native process/window used for observation. It is not a grant
    /// to send anything: recovery only records an already observed external result after review.
    @MainActor
    public final class RecoveryObservation {
        public let nativeURL: URL
        public let evidenceDescription: String
        public let capturedRevision: Int
        public let contextIsNewer: Bool
        fileprivate let receipt: NativeContinuationPlan.Receipt
        fileprivate let receiptURL: URL
        fileprivate let driver: Driver
        fileprivate init(receipt: NativeContinuationPlan.Receipt, receiptURL: URL, driver: Driver,
                         match: RecoveryMatch, contextIsNewer: Bool) {
            self.receipt = receipt; self.receiptURL = receiptURL; self.driver = driver
            nativeURL = match.nativeURL; evidenceDescription = match.evidenceDescription
            capturedRevision = receipt.plan.revision; self.contextIsNewer = contextIsNewer
        }
    }

    public static func inspectRecovery(receiptURL: URL, paths: Paths = .standard) throws -> RecoveryObservation {
        let receipt = try NativeContinuationPlan.loadReceipt(at: receiptURL)
        let driver = try Driver(plan: receipt.plan, paths: paths)
        let match = try recoveryMatch(receipt: receipt, view: driver.recoveryView())
        let newer = try recoveryContextIsNewer(receipt: receipt, observedURL: match.nativeURL)
        return RecoveryObservation(receipt: receipt, receiptURL: receiptURL, driver: driver, match: match, contextIsNewer: newer)
    }

    /// Called only by the explicit Recover observed destination button. Re-read the retained
    /// window, account and message evidence immediately before the compare-and-swap receipt write.
    public static func recover(_ observation: RecoveryObservation, receiptURL: URL) throws -> NativeContinuationPlan.Receipt {
        guard receiptURL.standardizedFileURL == observation.receiptURL.standardizedFileURL else { throw NativeError.identity }
        let current = try NativeContinuationPlan.loadReceipt(at: receiptURL)
        guard current == observation.receipt else { throw NativeContinuationPlan.TransferError.staleReceipt }
        let match = try recoveryMatch(receipt: current, view: observation.driver.recoveryView())
        guard match.nativeURL == observation.nativeURL, match.evidenceDescription == observation.evidenceDescription else { throw NativeError.windowChanged }
        let newer = try recoveryContextIsNewer(receipt: current, observedURL: match.nativeURL)
        let evidence = NativeContinuationPlan.RecoveryRecord(observedNativeURL: match.nativeURL, confirmedAt: Date(),
                                                             evidenceDescription: match.evidenceDescription, phase: match.phase,
                                                             contextWasNewer: newer)
        return try NativeContinuationPlan.updateReceipt(current, at: receiptURL, phase: match.phase, nativeURL: match.nativeURL,
                                                        message: "Recovered an observed native result after your confirmation. Recovery did not create an object or send a message. Context completeness and Claude's reply remain unverified.",
                                                        recovery: evidence)
    }

    struct RecoveryView: Equatable {
        var profileID: String
        var accountID: String
        var documentURL: URL
        var projectTitles: [String]
        var visibleHistory: String
    }
    struct RecoveryMatch: Equatable {
        let nativeURL: URL
        let phase: NativeContinuationPlan.Phase
        let evidenceDescription: String
    }
    static func recoveryMatch(receipt: NativeContinuationPlan.Receipt, view: RecoveryView) throws -> RecoveryMatch {
        let plan = receipt.plan
        guard !receipt.isAbandoned, [.creationRequested, .checkRequested].contains(receipt.phase) else {
            throw NativeError.unsupported("only an interrupted creation or check needs recovery")
        }
        guard view.profileID == plan.profileID, view.accountID == plan.accountID else { throw NativeError.identity }
        guard let canonical = Driver.canonical(view.documentURL), NativeContinuationPlan.isNativeURL(canonical, kind: plan.kind) else {
            throw NativeError.unsupported("open the actual Project or Cowork conversation to recover")
        }
        if let expected = receipt.nativeURL ?? plan.existingNativeURL, canonical != expected { throw NativeError.windowChanged }
        if receipt.phase == .creationRequested, plan.operation == .create, plan.kind == .codeProject {
            guard view.projectTitles == [plan.title] else { throw NativeError.unsupported("the open Project does not have this transfer's exact name") }
            return RecoveryMatch(nativeURL: canonical, phase: .created,
                                 evidenceDescription: "The open Project name exactly matches the reviewed creation: \(plan.title). Its context check has not been confirmed.")
        }
        if plan.kind == .codeProject,
           URLComponents(url: view.documentURL, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "thread" }) == true {
            throw NativeError.unsupported("open the Project coordinator, rather than a helper thread, to inspect the sent check")
        }
        let history = view.visibleHistory.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard history.contains("Check reference: \(plan.id.uuidString).") else {
            throw NativeError.unsupported("this transfer's unique check reference is not visible in conversation history; an unsent draft is not evidence")
        }
        return RecoveryMatch(nativeURL: canonical, phase: .checkSubmitted,
                             evidenceDescription: "This transfer's unique check reference is visible in the recorded conversation's history. Its reply and context completeness still need your review.")
    }
    static func visibleRecoveryHistory(in controls: [Control]) -> String {
        controls.filter { ["AXStaticText", "AXHeading"].contains($0.role) && $0.ancestors.contains("Chat messages") }
            .map { $0.value ?? $0.label }.joined(separator: "\n")
    }
    private static func recoveryContextIsNewer(receipt: NativeContinuationPlan.Receipt, observedURL: URL) throws -> Bool {
        let current = try ContinuityWorkspace(directory: receipt.plan.workspaceDirectory).load()
        guard current.workspaceID == receipt.plan.workspaceID else { throw NativeError.identity }
        if let registered = current.mirrors[receipt.plan.profileID], registered != observedURL {
            throw NativeContinuationPlan.TransferError.changed("the workspace records a different destination; recovery cannot replace it")
        }
        return try current.continuationContextSHA256() != receipt.plan.contextSHA256
    }

    /// The pure representation keeps matching tests independent of a running Claude installation.
    struct Control: Equatable {
        var path: [Int]
        var role: String
        var label: String
        var identifier: String
        var value: String?
        var url: URL?
        var enabled: Bool
        var selected: Bool
        var ancestors: [String]
    }
    static func selectedFile(in controls: [Control], expected: URL) -> Bool {
        let selected = controls.filter { $0.role == "AXTextField" && $0.selected && $0.url?.isFileURL == true &&
            $0.ancestors.contains("open-panel") && $0.ancestors.contains("ListView") }
        return selected.count == 1 && selected[0].url?.standardizedFileURL == expected.standardizedFileURL && selected[0].value == expected.lastPathComponent
    }
    static func composerScope(in controls: [Control], kind: NativeContinuationPlan.Kind) -> [Int]? {
        let prompts = controls.filter { $0.role == "AXTextArea" && $0.label == (kind == .codeProject ? "Prompt" : "Write your prompt to Claude") }
        let adds = controls.filter { $0.role == "AXPopUpButton" && $0.label == (kind == .codeProject ? "Add" : "Add files, connectors, and more") }
        guard prompts.count == 1 else { return nil }
        let scopes = adds.compactMap { add -> [Int]? in
            var common: [Int] = []
            for (left, right) in zip(prompts[0].path, add.path) { if left != right { break }; common.append(left) }
            guard !common.isEmpty, let parent = controls.first(where: { $0.path == common }), parent.role == "AXGroup" else { return nil }
            return common
        }
        guard let depth = scopes.map(\.count).max() else { return nil }
        let nearest = scopes.filter { $0.count == depth }
        guard nearest.count == 1 else { return nil }
        if kind == .codeProject { return nearest[0] }
        // In the observed Cowork composer the attachment area is a sibling of the prompt-and-
        // buttons group, one level above their nearest shared parent. History is outside this group.
        let outer = Array(nearest[0].dropLast())
        guard !outer.isEmpty, controls.contains(where: { $0.path == outer && $0.role == "AXGroup" }) else { return nil }
        return outer
    }
    static func namesOfAttachments(in controls: [Control], kind: NativeContinuationPlan.Kind = .codeProject,
                                   operation: NativeContinuationPlan.Operation = .create) -> [String] {
        let scope = composerScope(in: controls, kind: kind)
        return controls.filter { node in
            let scoped = kind == .codeProject && operation == .create ? node.ancestors.contains("New project") :
                scope.map { node.path.starts(with: $0) && node.path != $0 } ?? false
            return node.role == "AXButton" && scoped && node.label.hasPrefix("Remove ")
        }
            .map { String($0.label.dropFirst("Remove ".count)) }
    }

    @MainActor
    fileprivate final class Driver {
        let plan: NativeContinuationPlan
        let paths: Paths
        let process: NSRunningApplication
        let app: AXUIElement
        let window: AXUIElement
        let deadline = Date().addingTimeInterval(300)
        var tree: [Control] = []
        var elements: [[Int]: AXUIElement] = [:]
        var documentURL: URL?
        let browseURL = URL(string: "https://claude.ai/epitaxy/projects/browse")!
        var promptLabel: String { plan.kind == .codeProject ? "Prompt" : "Write your prompt to Claude" }

        init(plan: NativeContinuationPlan, paths: Paths) throws {
            guard AXIsProcessTrusted() else { throw NativeError.permission }
            self.plan = plan; self.paths = paths
            let candidates = NSWorkspace.shared.runningApplications.filter {
                ClaudeContextCapture.matches(profileID: plan.profileID, running: RunningClaude(app: $0), paths: paths)
            }
            guard candidates.count == 1, let process = candidates.first else { throw NativeError.identity }
            self.process = process; app = AXUIElementCreateApplication(process.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 1)
            guard let window = Self.element(app, kAXMainWindowAttribute) ?? Self.element(app, kAXFocusedWindowAttribute) else { throw NativeError.windowChanged }
            self.window = window
            try verify()
        }
        func verify() throws {
            try Task.checkCancellation()
            guard Date() < deadline else { throw NativeError.timedOut }
            let data = plan.profileID == "main" ? paths.mainDataDir : paths.dataDir(for: plan.profileID)
            guard !process.isTerminated, ClaudeContextCapture.matches(profileID: plan.profileID, running: RunningClaude(app: process), paths: paths),
                  DesktopData.accountID(in: data) == plan.accountID else { throw NativeError.identity }
            guard let current = Self.element(app, kAXMainWindowAttribute), CFEqual(current, window) else { throw NativeError.windowChanged }
        }
        @discardableResult func refresh() throws -> [Control] {
            try verify()
            var result: [Control] = [], found: [[Int]: AXUIElement] = [:], urls: [URL] = []
            var count = 0
            let readDeadline = min(deadline, Date().addingTimeInterval(15))
            func visit(_ element: AXUIElement, path: [Int], ancestors: [String], selected: Bool, depth: Int) throws {
                guard count < 20_000, depth < 90, Date() < readDeadline, !Task.isCancelled else { throw NativeError.timedOut }
                count += 1
                let role = Self.string(element, kAXRoleAttribute)
                guard Self.string(element, kAXSubroleAttribute) != "AXSecureTextField" else { return }
                let title = Self.string(element, kAXTitleAttribute), description = Self.string(element, kAXDescriptionAttribute)
                let identifier = Self.string(element, kAXIdentifierAttribute)
                let label = !title.isEmpty ? title : (!description.isEmpty ? description : Self.string(element, "AXPlaceholderValue"))
                let url = Self.attribute(element, kAXURLAttribute) as? URL ?? URL(string: Self.string(element, kAXURLAttribute))
                let ownSelected = (Self.attribute(element, kAXSelectedAttribute) as? NSNumber)?.boolValue ??
                    (role == "AXRadioButton" ? (Self.attribute(element, kAXValueAttribute) as? NSNumber)?.boolValue ?? false : false)
                let isSelected = selected || ownSelected
                let value = ["AXTextField", "AXTextArea", "AXStaticText", "AXHeading"].contains(role) ? Self.attribute(element, kAXValueAttribute) as? String : nil
                let control = Control(path: path, role: role, label: label, identifier: identifier, value: value, url: url,
                                      enabled: (Self.attribute(element, kAXEnabledAttribute) as? NSNumber)?.boolValue ?? true,
                                      selected: isSelected, ancestors: ancestors)
                result.append(control); found[path] = element
                if role == "AXWebArea", let url, url.scheme == "https", url.host == "claude.ai" { urls.append(url) }
                let children = Self.attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
                let next = ancestors + [label, identifier].filter { !$0.isEmpty }
                for (index, child) in children.enumerated() {
                    try visit(child, path: path + [index], ancestors: next, selected: isSelected, depth: depth + 1)
                }
            }
            try visit(window, path: [], ancestors: [], selected: false, depth: 0)
            try verify()
            guard urls.count == 1 else { throw NativeError.unsupported("the main Claude document is ambiguous or unreadable") }
            tree = result; elements = found; documentURL = urls[0]
            return result
        }
        func control(role: String, label: String, scope: String? = nil) throws -> Control {
            let nodes = try refresh().filter { $0.role == role && $0.label == label && (scope == nil || $0.ancestors.contains(scope!)) }
            guard nodes.count == 1, let node = nodes.first else { throw NativeError.unsupported("expected one \(label) control") }
            return node
        }
        func byID(_ id: String, role: String) throws -> Control {
            let nodes = try refresh().filter { $0.identifier == id && $0.role == role }
            guard nodes.count == 1, let node = nodes.first else { throw NativeError.unsupported("expected native \(id) control") }
            return node
        }
        func target(_ control: Control) throws -> AXUIElement {
            let expectedElement = elements[control.path], expectedURL = documentURL
            _ = try refresh()
            guard expectedURL == documentURL, let current = tree.first(where: { $0.path == control.path }),
                  current == control, let prior = expectedElement, let now = elements[control.path], CFEqual(prior, now) else { throw NativeError.staleControl }
            return now
        }
        func press(_ control: Control) throws {
            let element = try target(control)
            guard control.enabled, AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { throw NativeError.staleControl }
        }
        func set(_ control: Control, value: String) throws {
            let element = try target(control)
            var settable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue,
                  AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString) == .success else {
                throw NativeError.unsupported("\(control.label) does not expose native text input")
            }
            _ = try refresh()
            guard let current = tree.first(where: { $0.path == control.path }), current.value == value else { throw NativeError.staleControl }
        }
        func waitUntil(_ condition: () throws -> Bool) async throws {
            for _ in 0..<240 {
                try verify()
                if try condition() { return }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw NativeError.timedOut
        }
        func openNewProject() async throws {
            _ = try refresh()
            guard !tree.contains(where: { ["AXTextArea", "AXTextField"].contains($0.role) && !$0.ancestors.contains("New project") &&
                !($0.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw NativeError.draft }
            if documentURL != browseURL {
                let modes = tree.filter { $0.role == "AXRadioButton" && ($0.label == "Code" || $0.label.hasPrefix("Code,")) && $0.ancestors.contains("Mode") }
                guard modes.count == 1, let mode = modes.first else { throw NativeError.unsupported("Code mode is not available") }
                try press(mode)
                try await Task.sleep(for: .milliseconds(300)); _ = try refresh()
                if documentURL != browseURL {
                    let projects = try control(role: "AXButton", label: "Projects Beta")
                    try press(projects)
                }
                try await waitUntil { _ = try self.refresh(); return self.documentURL == self.browseURL }
            }
            if !tree.contains(where: { $0.role == "AXTextField" && $0.label == "Name" && $0.ancestors.contains("New project") }) {
                try press(control(role: "AXButton", label: "New project"))
            }
            try await waitUntil { try self.refresh().contains { $0.role == "AXTextField" && $0.label == "Name" && $0.ancestors.contains("New project") } }
        }
        func openCowork() async throws {
            _ = try refresh()
            let newURL = URL(string: "https://claude.ai/new")!
            if documentURL != newURL {
                guard !tree.contains(where: { ["AXTextArea", "AXTextField"].contains($0.role) && !($0.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw NativeError.draft }
                let modes = tree.filter { $0.role == "AXRadioButton" && $0.label == "Chat and Cowork" && $0.ancestors.contains("Mode") }
                guard modes.count == 1, let mode = modes.first else { throw NativeError.unsupported("Chat and Cowork mode is not available") }
                try press(mode)
                try await Task.sleep(for: .milliseconds(300))
                try press(control(role: "AXButton", label: "New"))
                try await waitUntil { _ = try self.refresh(); return self.documentURL == newURL }
            }
            let cowork = try control(role: "AXRadioButton", label: "Cowork", scope: "Surface")
            if !cowork.selected { try press(cowork) }
            try await waitUntil { try self.control(role: "AXRadioButton", label: "Cowork", scope: "Surface").selected }
        }
        func requireEmptyCowork() throws {
            let prompt = try control(role: "AXTextArea", label: "Write your prompt to Claude")
            guard (prompt.value ?? "").isEmpty, attachmentNames().isEmpty else { throw NativeError.draft }
        }
        func validateCowork(plan: NativeContinuationPlan) throws {
            _ = try refresh()
            guard documentURL == URL(string: "https://claude.ai/new"),
                  try control(role: "AXRadioButton", label: "Cowork", scope: "Surface").selected else { throw NativeError.windowChanged }
            let prompt = try control(role: "AXTextArea", label: "Write your prompt to Claude").value ?? ""
            guard composerScope(in: tree, kind: plan.kind) != nil else { throw NativeError.unsupported("the Cowork attachment composer is ambiguous") }
            guard (prompt.isEmpty || prompt == plan.contextCheck), Set(attachmentNames()).isSubset(of: Set(plan.uploads.map(\.name))) else { throw NativeError.draft }
        }
        func requireEmptyExisting() throws {
            let prompt = try control(role: "AXTextArea", label: promptLabel)
            guard (prompt.value ?? "").isEmpty, attachmentNames().isEmpty else { throw NativeError.draft }
        }
        func validateExisting() throws {
            guard let url = plan.existingNativeURL else { throw NativeError.identity }
            try requireDestination(url)
            let prompt = try control(role: "AXTextArea", label: promptLabel).value ?? ""
            guard composerScope(in: tree, kind: plan.kind) != nil else { throw NativeError.unsupported("the attachment composer is ambiguous") }
            guard (prompt.isEmpty || prompt == plan.contextCheck), Set(attachmentNames()).isSubset(of: Set(plan.uploads.map(\.name))) else { throw NativeError.draft }
        }
        func sendControl() throws -> Control {
            // Only labels observed for a supported native destination are accepted.
            try control(role: "AXButton", label: plan.kind == .codeProject ? "Send" : "Send message")
        }
        func requireEmptyForm() throws {
            guard try control(role: "AXTextField", label: "Name", scope: "New project").value?.isEmpty ?? true,
                  try control(role: "AXTextArea", label: "Goal (optional)", scope: "New project").value?.isEmpty ?? true,
                  attachmentNames().isEmpty else { throw NativeError.draft }
        }
        func validateForm(plan: NativeContinuationPlan, allowMissingFields: Bool) throws {
            _ = try refresh()
            guard documentURL == browseURL else { throw NativeError.windowChanged }
            let name = try control(role: "AXTextField", label: "Name", scope: "New project").value ?? ""
            let goal = try control(role: "AXTextArea", label: "Goal (optional)", scope: "New project").value ?? ""
            guard (name == plan.title || (allowMissingFields && name.isEmpty)),
                  (goal == plan.goal || (allowMissingFields && goal.isEmpty)),
                  Set(attachmentNames()).isSubset(of: Set(plan.uploads.map(\.name))) else { throw NativeError.draft }
        }
        func fillForm(plan: NativeContinuationPlan) throws {
            let name = try control(role: "AXTextField", label: "Name", scope: "New project")
            if name.value != plan.title { try set(name, value: plan.title) }
            let goal = try control(role: "AXTextArea", label: "Goal (optional)", scope: "New project")
            if goal.value != plan.goal { try set(goal, value: plan.goal) }
        }
        func attachmentNames() -> [String] { namesOfAttachments(in: tree, kind: plan.kind, operation: plan.operation) }
        func hasAttachment(_ name: String) -> Bool { (try? refresh()) != nil && attachmentNames().contains(name) }
        func composerAdd() throws -> Control {
            _ = try refresh()
            guard let scope = composerScope(in: tree, kind: plan.kind) else { throw NativeError.unsupported("the attachment composer is ambiguous") }
            let label = plan.kind == .codeProject ? "Add" : "Add files, connectors, and more"
            let adds = tree.filter { $0.role == "AXPopUpButton" && $0.label == label && $0.path.starts(with: scope) }
            guard adds.count == 1, let add = adds.first else { throw NativeError.unsupported("the attachment button is ambiguous") }
            return add
        }
        func attach(_ upload: NativeContinuationPlan.Upload) async throws {
            let isProjectForm = plan.kind == .codeProject && plan.operation == .create
            let add = try (isProjectForm ? control(role: "AXPopUpButton", label: "Add", scope: "New project") : composerAdd())
            try press(add)
            try press(control(role: "AXMenuItem", label: isProjectForm ? "Add a file" : "Add files or photos"))
            try await waitUntil { try self.refresh().contains { $0.role == "AXSheet" && $0.identifier == "open-panel" } }
            // The official picker applies its normal filters. No pasteboard is used and keystrokes
            // are posted only to this verified foreground process while its picker is observed.
            process.activate(options: [])
            try await Task.sleep(for: .milliseconds(150))
            try key(5, flags: [.maskCommand, .maskShift], expectedSheet: "open-panel")
            try await waitUntil { try self.refresh().contains { $0.role == "AXSheet" && $0.identifier == "GoToWindow" } }
            try set(byID("PathTextField", role: "AXTextField"), value: upload.url.path)
            try key(36, flags: [], expectedSheet: "GoToWindow")
            try await waitUntil {
                let controls = try self.refresh()
                return !controls.contains { $0.identifier == "GoToWindow" } && ClaudeNativeContinuation.selectedFile(in: controls, expected: upload.url)
            }
            let open = try byID("OKButton", role: "AXButton")
            guard open.enabled, ClaudeNativeContinuation.selectedFile(in: tree, expected: upload.url) else { throw NativeError.upload(upload.name) }
            try press(open)
            try await waitUntil {
                let controls = try self.refresh()
                if controls.contains(where: { ($0.value ?? $0.label).lowercased().contains("unsupported file") || ($0.value ?? $0.label).lowercased().contains("failed to upload") }) {
                    throw NativeError.upload(upload.name)
                }
                let names = self.attachmentNames()
                let formReady = controls.contains { node in
                    let status = node.value ?? node.label
                    return node.role == "AXStaticText" && (status == "Added \(upload.name)" || status == "Added \(names.count) files")
                }
                let stillUploading = controls.contains { $0.role == "AXProgressIndicator" && $0.ancestors.contains("New project") }
                return !controls.contains { $0.identifier == "open-panel" } && names.contains(upload.name) && !stillUploading &&
                    (self.plan.kind == .coworkConversation || self.plan.operation == .updateExisting || formReady)
            }
        }
        func key(_ code: CGKeyCode, flags: CGEventFlags, expectedSheet: String) throws {
            _ = try refresh()
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier,
                  tree.filter({ $0.role == "AXSheet" && $0.identifier == expectedSheet }).count == 1 else { throw NativeError.windowChanged }
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { throw NativeError.unsupported("native keyboard events") }
            down.flags = flags; up.flags = flags
            down.postToPid(process.processIdentifier); up.postToPid(process.processIdentifier)
        }
        func waitForCreatedContinuation() async throws -> URL {
            var result: URL?
            try await waitUntil {
                _ = try self.refresh()
                guard let url = self.documentURL, let canonical = Self.canonical(url), NativeContinuationPlan.isNativeURL(canonical, kind: self.plan.kind) else { return false }
                if self.plan.kind == .codeProject {
                    guard self.tree.contains(where: { $0.role == "AXButton" && $0.label == self.plan.title + ", rename project" }) else { return false }
                } else {
                    guard self.tree.contains(where: { $0.role == "AXTextArea" && $0.label == "Write your prompt to Claude" && ($0.value ?? "").isEmpty }) else { return false }
                }
                result = canonical; return true
            }
            guard let result else { throw NativeError.timedOut }
            return result
        }
        func requireProject(_ url: URL) throws {
            _ = try refresh()
            guard documentURL.flatMap(Self.canonical) == url,
                  !(documentURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.contains { $0.name == "thread" } ?? false) else { throw NativeError.windowChanged }
        }
        func requireDestination(_ url: URL) throws {
            if plan.kind == .codeProject { try requireProject(url) }
            else {
                _ = try refresh()
                guard documentURL.flatMap(Self.canonical) == url else { throw NativeError.windowChanged }
            }
        }
        func recoveryView() throws -> RecoveryView {
            _ = try refresh()
            guard let documentURL else { throw NativeError.windowChanged }
            let suffix = ", rename project"
            let titles = tree.filter { $0.role == "AXButton" && $0.label.hasSuffix(suffix) && !$0.ancestors.contains("Chat messages") }
                .map { String($0.label.dropLast(suffix.count)) }
            return RecoveryView(profileID: plan.profileID, accountID: plan.accountID, documentURL: documentURL,
                                projectTitles: titles, visibleHistory: visibleRecoveryHistory(in: tree))
        }
        static func canonical(_ url: URL) -> URL? {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.query = nil; components?.fragment = nil
            return components?.url
        }
        static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
        }
        static func string(_ element: AXUIElement, _ key: String) -> String { attribute(element, key) as? String ?? "" }
        static func element(_ source: AXUIElement, _ key: String) -> AXUIElement? {
            guard let result = attribute(source, key), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
            return (result as! AXUIElement)
        }
    }
}
