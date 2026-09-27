import ApplicationServices
import Foundation
import Testing
@testable import ClaudeProfilesKit

@Suite("Read-only Claude context capture")
struct ClaudeContextCaptureTests {
    typealias Node = ClaudeContextCapture.Node
    let projectURL = "https://claude.ai/epitaxy/project/chan_example?thread=cse_example"

    func document(_ children: [Node], url: String? = nil) -> Node {
        Node(role: "AXWindow", children: [Node(role: "AXWebArea", title: "Claude", url: url ?? projectURL, children: children)])
    }

    @Test func projectTranscriptIncludesVisibleHistoryAndNeverClaimsCompleteness() throws {
        let tree = document([
            Node(role: "AXHeading", value: "Infrastructure plan"),
            Node(role: "AXGroup", title: "Chat messages", children: [
                Node(role: "AXStaticText", value: "User: Preserve the original objective."),
                Node(role: "AXStaticText", value: "Assistant: The first migration is verified."),
                Node(role: "AXStaticText", value: "User: Continue."),
                Node(role: "AXStaticText", value: "User: Continue.")
            ])
        ])
        let snapshot = try ClaudeContextCapture.parse(tree, profileID: "work", profileLabel: "WORK", now: Date(timeIntervalSince1970: 0))
        #expect(snapshot.documentURL == projectURL)
        #expect(snapshot.kind == .codeProject)
        #expect(snapshot.title == "Infrastructure plan")
        #expect(snapshot.text.contains("first migration is verified"))
        #expect(snapshot.text.components(separatedBy: "User: Continue.").count == 3,
                "identical legitimate messages must not be globally deduplicated")
        #expect(snapshot.coverage == .currentViewOnly && !snapshot.isCompleteProject)
        #expect(snapshot.gaps.contains(.historyMayBeVirtualized))
        #expect(snapshot.gaps.contains(.otherViewsNotVisited))
    }

    @Test func coordinatorAndThreadContainersRemainSeparateUnderMainLandmark() throws {
        let tree = document([Node(role: "AXGroup", subrole: "AXLandmarkMain", children: [
            Node(role: "AXGroup", title: "Chat messages", children: [Node(role: "AXStaticText", value: "Coordinator history")]),
            Node(role: "AXGroup", title: "Chat messages", children: [Node(role: "AXStaticText", value: "Selected thread history")])
        ])])
        let snapshot = try ClaudeContextCapture.parse(tree, profileID: "elena", profileLabel: "ELENA")
        #expect(snapshot.sections.count == 2)
        #expect(snapshot.sections[0].text == "Coordinator history")
        #expect(snapshot.sections[1].text == "Selected thread history")
        #expect(snapshot.sections[0].label != snapshot.sections[1].label)
        #expect(snapshot.sections.allSatisfy { $0.label.contains("identity unverified") })
    }

    @Test func sidebarComposerAccountMenusAndSecureFieldsAreExcluded() throws {
        let tree = document([
            Node(role: "AXGroup", title: "Sidebar", children: [Node(role: "AXStaticText", value: "unrelated private conversation")]),
            Node(role: "AXGroup", subrole: "AXLandmarkNavigation", children: [Node(role: "AXStaticText", value: "other account task")]),
            Node(role: "AXMenu", title: "Account menu", children: [Node(role: "AXStaticText", value: "private account secret")]),
            Node(role: "AXGroup", title: "Chat messages", children: [
                Node(role: "AXStaticText", value: "visible source history"),
                Node(role: "AXTextArea", description: "Prompt", value: "unsent private draft"),
                Node(role: "AXTextField", subrole: "AXSecureTextField", title: "Goal", value: "secret password"),
                Node(role: "AXTextArea", description: "Message", value: "unsent memory-edit request"),
                Node(role: "AXGroup", identifier: "account-menu", children: [Node(role: "AXStaticText", value: "nested account secret")])
            ])
        ])
        let snapshot = try ClaudeContextCapture.parse(tree, profileID: "work", profileLabel: "WORK")
        #expect(snapshot.text.contains("visible source history"))
        for secret in ["unrelated private", "other account", "private account", "unsent", "secret password", "nested account"] {
            #expect(!snapshot.text.contains(secret))
        }
    }

    @Test func projectSettingsFieldsAreContextRatherThanUnsentComposer() throws {
        let tree = document([
            Node(role: "AXTextField", title: "Name", value: "Cloud business"),
            Node(role: "AXTextArea", description: "Goal", value: "Measurable reliability improvements"),
            Node(role: "AXTextArea", description: "Project instructions", value: "Preserve promises and verify outcomes."),
            Node(role: "AXTextArea", description: "Write your prompt", value: "do not capture this draft")
        ])
        let snapshot = try ClaudeContextCapture.parse(tree, profileID: "vir", profileLabel: "VIR")
        #expect(snapshot.sections.map(\.label) == ["Project name", "Goal", "Project instructions"])
        #expect(snapshot.text.contains("Measurable reliability improvements"))
        #expect(!snapshot.text.contains("do not capture"))
    }

    @Test func openProjectMemoryFileIsCapturedWithItsReadOnlyBody() throws {
        let tree = document([Node(role: "AXGroup", title: "MEMORY.md", children: [
            Node(role: "AXHeading", value: "Project memory"),
            Node(role: "AXStaticText", value: "# Persistent decisions"),
            Node(role: "AXStaticText", value: "- Finish the verified migration."),
            Node(role: "AXTextArea", description: "Message", value: "private edit request")
        ])])
        let snapshot = try ClaudeContextCapture.parse(tree, profileID: "elena", profileLabel: "ELENA")
        #expect(snapshot.sections.first?.label == "MEMORY.md")
        #expect(snapshot.text.contains("Persistent decisions"))
        #expect(!snapshot.text.contains("private edit request"))
    }

    @Test func paginationCollapsedToolsAndTreeLimitsAreExplicitGaps() throws {
        let tree = document([Node(role: "AXGroup", title: "Chat messages", truncated: true, children: [
            Node(role: "AXStaticText", value: "last visible response", position: 40, setSize: 80),
            Node(role: "AXButton", title: "Load older messages"),
            Node(role: "AXButton", title: "Show tool results", expanded: false),
            Node(role: "AXDisclosureTriangle", title: "Read file", expanded: false)
        ])])
        let snapshot = try ClaudeContextCapture.parse(tree, profileID: "main", profileLabel: "MAIN")
        #expect(snapshot.paginationControls == ["Load older messages"])
        #expect(snapshot.collapsedControls == ["Show tool results", "Read file"])
        #expect(snapshot.gaps.contains(.paginationAvailable))
        #expect(snapshot.gaps.contains(.collapsedContent))
        #expect(snapshot.gaps.contains(.treeReadLimited))
        #expect(!snapshot.isCompleteProject)
    }

    @Test func nativeLibraryRouteAndOutlinePreserveInventoryAndSourceLinks() throws {
        let source = "https://claude.ai/epitaxy/project/chan_example?overviewTab=library"
        let artifact = "https://claude.ai/code/artifact/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let tree = document([
            Node(role: "AXOutline", title: "Sidebar", children: [Node(role: "AXStaticText", value: "unrelated sidebar row")]),
            Node(role: "AXOutline", title: "Library", children: [
                Node(role: "AXRow", title: "Artifacts — Folder"),
                Node(role: "AXRow", children: [
                    Node(role: "AXLink", title: "Infrastructure report", value: "", url: artifact),
                    Node(role: "AXCell", value: "September 27")
                ])
            ])
        ], url: source)
        let snapshot = try ClaudeContextCapture.parse(tree, profileID: "vir", profileLabel: "VIR")
        #expect(snapshot.documentURL == source)
        #expect(snapshot.text.contains("Artifacts — Folder"))
        #expect(snapshot.text.contains("Infrastructure report (\(artifact))"))
        #expect(snapshot.text.contains("September 27"))
        #expect(!snapshot.text.contains("unrelated sidebar row"))
        #expect(!snapshot.isCompleteProject)
    }

    @Test func arbitraryOpenedMemoryFilenameAndUnexpandedToolSummariesAreRetained() throws {
        let tree = document([
            Node(role: "AXGroup", title: "stakeholder-expectations.md", children: [
                Node(role: "AXStaticText", value: "Preserve the actual expectation and decision."),
                Node(role: "AXTextArea", description: "Message", value: "unsent edit")
            ]),
            Node(role: "AXButton", title: "Ran 7 commands and used 2 tools"),
            Node(role: "AXButton", title: "Used 2 tools"),
            Node(role: "AXButton", title: "Message sent to another session")
        ])
        let snapshot = try ClaudeContextCapture.parse(tree, profileID: "elena", profileLabel: "ELENA")
        #expect(snapshot.sections.first?.label == "stakeholder-expectations.md")
        #expect(snapshot.text.contains("actual expectation"))
        #expect(!snapshot.text.contains("unsent edit"))
        #expect(snapshot.collapsedControls.count == 3)
        #expect(snapshot.gaps.contains(.collapsedContent))
    }

    @Test func embeddedArtifactHasAnExplicitUncapturedGapWithoutReadingItsUnverifiedFrame() throws {
        let tree = document([Node(role: "AXGroup", title: "Chat messages", children: [
            Node(role: "AXStaticText", value: "See the attached report."),
            Node(role: "AXWebArea", url: "https://claude.ai/code/artifact/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa?m=dark&chrome=none&org=example#n=0", children: [
                Node(role: "AXWebArea", url: "https://aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.frame.claudeusercontent.com/_f/version", children: [
                    Node(role: "AXStaticText", value: "unverified embedded artifact body")
                ])
            ])
        ])])
        let snapshot = try ClaudeContextCapture.parse(tree, profileID: "vir", profileLabel: "VIR")
        #expect(snapshot.gaps.contains(.embeddedArtifactNotCaptured))
        #expect(!snapshot.text.contains("unverified embedded artifact body"))
        #expect(!snapshot.isCompleteProject)
    }

    @Test func sourceLinkAuthenticationParametersAreNotExported() throws {
        let tree = document([Node(role: "AXGroup", title: "Chat messages", children: [
            Node(role: "AXLink", title: "Private preview", value: "", url: "https://example.test/file?token=credential"),
            Node(role: "AXLink", value: "https://user:password@example.test/file", url: "https://user:password@example.test/file"),
            Node(role: "AXStaticText", value: "safe context")
        ])])
        let snapshot = try ClaudeContextCapture.parse(tree, profileID: "vir", profileLabel: "VIR")
        #expect(snapshot.text.contains("Private preview"))
        #expect(!snapshot.text.contains("credential") && !snapshot.text.contains("password"))
    }

    @Test(arguments: ["https://claude.ai/cowork/local_example", "https://claude.ai/cowork/cse_example", "https://claude.ai/cowork/session_example"])
    func nativeCoworkRoutesAreCapturedWithoutPretendingToCaptureTheWholeTask(url: String) throws {
        let tree = document([Node(role: "AXGroup", title: "Conversation messages", children: [Node(role: "AXStaticText", value: "Cowork result")])], url: url)
        let snapshot = try ClaudeContextCapture.parse(tree, profileID: "work", profileLabel: "WORK")
        #expect(snapshot.kind == .coworkConversation)
        #expect(snapshot.text.contains("Cowork result"))
        #expect(snapshot.coverage == .currentViewOnly)
    }

    @Test(arguments: ["https://claude.ai/", "https://claude.ai/epitaxy", "https://claude.ai/epitaxy/projects/browse",
                      "https://claude.ai/chat/ordinary", "https://claude.ai/login", "https://evil.test/epitaxy/project/chan_example",
                      "https://claude.ai.evil.test/epitaxy/project/chan_example", "https://user:secret@claude.ai/epitaxy/project/chan_example",
                      "https://claude.ai/epitaxy/project/chan_example?token=secret", "https://claude.ai/epitaxy/project/chan_example#token=secret"])
    func unsupportedAndAuthenticationRoutesNeverReturnContent(url: String) {
        let tree = document([Node(role: "AXGroup", title: "Chat messages", children: [Node(role: "AXStaticText", value: "must not escape")])], url: url)
        #expect(throws: ClaudeContextCapture.CaptureError.unsupportedPage) {
            try ClaudeContextCapture.parse(tree, profileID: "work", profileLabel: "WORK")
        }
    }

    @Test func arbitraryApplicationTextAndMultipleDocumentsAreRejected() {
        #expect(throws: ClaudeContextCapture.CaptureError.noContext) {
            try ClaudeContextCapture.parse(document([Node(role: "AXStaticText", value: "unscoped text")]), profileID: "work", profileLabel: "WORK")
        }
        let tree = Node(role: "AXWindow", children: [
            Node(role: "AXWebArea", url: projectURL), Node(role: "AXWebArea", url: "https://claude.ai/epitaxy/project/chan_other")
        ])
        #expect(throws: ClaudeContextCapture.CaptureError.unsupportedPage) {
            try ClaudeContextCapture.parse(tree, profileID: "work", profileLabel: "WORK")
        }
    }

    @Test func embeddedClaudeDocumentIsFoundInsideTheElectronFileShell() throws {
        let inner = Node(role: "AXWebArea", url: projectURL, children: [
            Node(role: "AXGroup", title: "Chat messages", children: [Node(role: "AXStaticText", value: "verified project text")])
        ])
        let tree = Node(role: "AXWindow", children: [Node(role: "AXWebArea", url: "file:///Applications/Claude.app/Contents/Resources/app.asar/index.html", children: [inner])])
        let snapshot = try ClaudeContextCapture.parse(tree, profileID: "work", profileLabel: "WORK")
        #expect(snapshot.documentURL == projectURL)
        #expect(snapshot.text.contains("verified project text"))
        #expect(!snapshot.text.contains("app.asar"))
    }

    @Test func unrelatedEmbeddedFrameCannotContributeContext() throws {
        let tree = document([Node(role: "AXGroup", title: "Chat messages", children: [
            Node(role: "AXStaticText", value: "approved project content"),
            Node(role: "AXWebArea", url: "https://unrelated.example/login", children: [
                Node(role: "AXGroup", title: "Chat messages", children: [Node(role: "AXStaticText", value: "foreign embedded private data")])
            ])
        ])])
        let snapshot = try ClaudeContextCapture.parse(tree, profileID: "work", profileLabel: "WORK")
        #expect(snapshot.text.contains("approved project content"))
        #expect(!snapshot.text.contains("foreign embedded"))
    }

    @Test func exactProcessBundleAndExplicitProfileDataAreRequired() throws {
        let box = try Sandbox()
        let engine = box.paths.engine(for: "work").path
        let proper = RunningClaude(bundlePath: engine, arguments: ["Claude", "--user-data-dir=\(box.work.path)"])
        #expect(ClaudeContextCapture.matches(profileID: "work", running: proper, paths: box.paths))
        #expect(!ClaudeContextCapture.matches(profileID: "work", running: RunningClaude(bundlePath: engine, arguments: ["Claude"]), paths: box.paths))
        #expect(!ClaudeContextCapture.matches(profileID: "work", running: RunningClaude(bundlePath: engine, arguments: nil), paths: box.paths))
        #expect(!ClaudeContextCapture.matches(profileID: "work", running: RunningClaude(bundlePath: box.paths.claudeApp.path, arguments: proper.arguments), paths: box.paths))
        #expect(!ClaudeContextCapture.matches(profileID: "work", running: RunningClaude(bundlePath: engine, arguments: ["Claude", "--user-data-dir=\(box.main.path)"]), paths: box.paths))
    }
}

@Suite("Bounded native Project collector")
@MainActor
struct ClaudeProjectCollectorTests {
    @Test func visitsGoalInstructionsAllMemoryCollapsedThreadGroupsAndLibraryWithoutSending() async throws {
        let driver = ProjectCaptureScriptDriver()
        var delivered: [ClaudeContextCapture.ProjectView] = []
        let result = try await ClaudeContextCapture.collectProject(driver: driver, profileID: "elena", profileLabel: "ELENA", progress: { delivered.append($0) })
        #expect(result.views == delivered)
        #expect(!result.isCompleteProject)
        #expect(result.inventory.filter { $0.kind == "thread" }.count == 8)
        #expect(result.inventory.filter { $0.kind == "thread" && $0.captured }.count == 8)
        #expect(result.inventory.filter { $0.kind == "memory" && $0.captured }.map(\.label).sorted() == ["MEMORY.md", "stakeholder-expectations.md"])
        #expect(result.views.contains { $0.snapshot.text.contains("Actual project goal") })
        #expect(result.views.contains { $0.snapshot.text.contains("Actual project instructions") })
        #expect(result.views.contains { $0.snapshot.text.contains("Memory content: stakeholder-expectations.md") })
        #expect(result.views.contains { $0.snapshot.text.contains("Original tool result") })
        #expect(result.views.contains { $0.scope.hasPrefix("Library") && $0.snapshot.text.contains("Cost report") })
        #expect(result.inventory.contains { $0.sourceURL?.contains("thread=cmsg_7") == true && $0.capturedURL?.contains("thread=session_7") == true })
        #expect(driver.actions.allSatisfy { !["Send message", "Run command", "Allow", "Create", "Delete"].contains($0.control.label) })
        #expect(result.limitations.contains { $0.contains("off-screen/virtualized") })
    }

    @Test func laterTranscriptPageExpandsItsToolSummaryAndLibraryPaginationIsCaptured() async throws {
        let driver = ProjectCaptureScriptDriver(); driver.moreHistoryAndLibrary = true
        let result = try await ClaudeContextCapture.collectProject(driver: driver, profileID: "elena", profileLabel: "ELENA")
        #expect(result.views.contains { $0.snapshot.text.contains("Older tool result") })
        #expect(result.inventory.contains { $0.kind == "library" && $0.label.contains("Second-page budget report") })
        #expect(driver.actions.contains { $0.intent == .toolDetails && $0.control.label == "Used 2 tools" })
        #expect(driver.actions.filter { $0.intent == .pagination }.count == 2)
    }

    @Test func generalAlreadyVisibleIsCapturedEvenWithoutAPressAction() async throws {
        let driver = ProjectCaptureScriptDriver(); driver.generalCannotPress = true
        let result = try await ClaudeContextCapture.collectProject(driver: driver, profileID: "elena", profileLabel: "ELENA")
        #expect(result.views.contains { $0.scope == "Project settings / initially visible context" && $0.snapshot.text.contains("Actual project goal") })
        #expect(result.views.contains { $0.snapshot.text.contains("Actual project instructions") })
    }

    @Test func actualFolderLabelWithActionsSuffixIsOpenedAndInventoried() async throws {
        let driver = ProjectCaptureScriptDriver(); driver.libraryFolderPresent = true
        let result = try await ClaudeContextCapture.collectProject(driver: driver, profileID: "elena", profileLabel: "ELENA")
        #expect(driver.actions.contains { $0.intent == .libraryFolder && $0.control.label == "Artifacts — Folder Actions for Artifacts" })
        #expect(result.inventory.contains { $0.kind == "library" && $0.label.contains("Nested artifact") })
    }

    @Test func sourceProjectChangeStopsImmediatelyAndRetainsEarlierViews() async throws {
        let driver = ProjectCaptureScriptDriver(); driver.changeProjectAfterSettings = true
        let result = try await ClaudeContextCapture.collectProject(driver: driver, profileID: "elena", profileLabel: "ELENA")
        #expect(result.views.count == 1)
        #expect(driver.actions.count == 1)
        #expect(result.limitations.contains { $0.contains("selected account") })
        #expect(!result.views.contains { $0.snapshot.documentURL.contains("chan_other") })
    }

    @Test func cancellationReturnsAllPreviouslyDeliveredViews() async throws {
        let driver = ProjectCaptureScriptDriver(); driver.cancelAfterActions = 2
        var delivered: [ClaudeContextCapture.ProjectView] = []
        let result = try await ClaudeContextCapture.collectProject(driver: driver, profileID: "elena", profileLabel: "ELENA", progress: { delivered.append($0) })
        #expect(result.cancelled && !result.views.isEmpty)
        #expect(result.views == delivered)
        #expect(driver.actions.count == 2)
    }

    @Test func unknownControlsAreInventoriedAsDataAndNeverPressed() async throws {
        let driver = ProjectCaptureScriptDriver(); driver.onlyUnknownControls = true
        let result = try await ClaudeContextCapture.collectProject(driver: driver, profileID: "elena", profileLabel: "ELENA")
        #expect(driver.actions.isEmpty)
        #expect(result.views.count == 1)
        #expect(result.limitations.contains { $0.contains("could not be opened") })
        #expect(!result.isCompleteProject)
    }

    @Test func hardLimitReturnsPartialInsteadOfLoopingOrDiscardingEarlierContext() async throws {
        let driver = ProjectCaptureScriptDriver()
        let result = try await ClaudeContextCapture.collectProject(driver: driver, profileID: "elena", profileLabel: "ELENA",
                                                                   limits: .init(views: 2, actions: 100, seconds: 30))
        #expect(result.views.count == 2)
        #expect(result.limitations.contains { $0.contains("limit") })
        #expect(!result.isCompleteProject)
    }
}

@MainActor
private final class ProjectCaptureScriptDriver: ClaudeContextCapture.ProjectDriver {
    typealias Node = ClaudeContextCapture.Node
    typealias Action = ClaudeContextCapture.ReadAction
    var actions: [Action] = []
    var page = "overview"
    var memory = ""
    var currentThread: Int?
    var resolvedExpanded = false
    var toolExpanded = false
    var changeProjectAfterSettings = false
    var cancelAfterActions: Int?
    var onlyUnknownControls = false
    var moreHistoryAndLibrary = false
    var historyOlder = false
    var olderToolExpanded = false
    var libraryMore = false
    var generalCannotPress = false
    var libraryFolderPresent = false
    let base = "https://claude.ai/epitaxy/project/chan_test"

    func button(_ title: String, expanded: Bool? = nil) -> Node { Node(role: "AXButton", title: title, expanded: expanded, actions: ["AXPress"]) }
    func transcript(_ text: String) -> Node { Node(role: "AXGroup", title: "Chat messages", children: [Node(role: "AXStaticText", value: text)]) }
    func document(_ nodes: [Node], url: String? = nil) -> Node {
        Node(role: "AXWindow", children: [Node(role: "AXWebArea", url: url ?? base, children: nodes)])
    }
    func settings(_ body: [Node]) -> Node {
        Node(role: "AXGroup", title: "Project settings", children: [
            Node(role: "AXGroup", subrole: "AXLandmarkNavigation", title: "Settings sections", children: [button("General"), button("Memory")]),
            button("Close")
        ] + body)
    }
    func readTree() throws -> Node {
        if page == "other" { return document([transcript("Unrelated project")], url: "https://claude.ai/epitaxy/project/chan_other") }
        if onlyUnknownControls {
            return document([transcript("Available visible context"), button("Send message"), button("Run command"), button("Allow"), button("Create"), button("Delete")])
        }
        if page == "general" {
            return document([settings([Node(role: "AXTextArea", title: "Goal", value: "Actual project goal")])])
        }
        if page == "memory" {
            return document([settings([Node(role: "AXTextArea", title: "Project instructions", value: "Actual project instructions"),
                                       button("Open MEMORY.md"), button("Open stakeholder-expectations.md")])])
        }
        if page == "memoryFile" {
            return document([settings([button("Memory"), Node(role: "AXGroup", title: memory, children: [
                Node(role: "AXStaticText", value: "Memory content: \(memory)"),
                Node(role: "AXTextArea", title: "Message", value: "Unsent edit"), button("Send message")
            ])])])
        }
        let tabs: [Node] = [Node(role: "AXRadioButton", title: "Threads 2 threads waiting on you", selected: page == "overview", actions: ["AXPress"]),
                            Node(role: "AXRadioButton", title: "Library", selected: page == "library", actions: ["AXPress"]),
                            Node(role: "AXRadioButton", title: "Routines", selected: page == "routines", actions: ["AXPress"])]
        if page == "library" {
            var rows = [Node(role: "AXRow", title: "Cost report")]
            if libraryFolderPresent { rows.append(Node(role: "AXRow", title: "Artifacts — Folder Actions for Artifacts", actions: ["AXPress"])) }
            if moreHistoryAndLibrary { rows.append(libraryMore ? Node(role: "AXRow", title: "Second-page budget report") : button("Load more")) }
            return document([transcript("Coordinator context"), Node(role: "AXOutline", title: "Library", children: rows)] + tabs,
                            url: base + "?overviewTab=library")
        }
        if page == "libraryChild" {
            return document([button("Library"), Node(role: "AXOutline", title: "Library", children: [Node(role: "AXRow", title: "Nested artifact")])], url: base + "?overviewTab=library")
        }
        if page == "routines" { return document([Node(role: "AXGroup", title: "Main content", children: [Node(role: "AXStaticText", value: "Existing routine inventory"), button("Run command")])] + tabs) }
        if page == "thread", let currentThread {
            var thread = transcript("Thread \(currentThread) complete visible text")
            if currentThread == 0 {
                thread.children.append(toolExpanded ? Node(role: "AXStaticText", value: "Original tool result") : button("Ran 7 commands"))
                if moreHistoryAndLibrary {
                    if historyOlder { thread.children.append(olderToolExpanded ? Node(role: "AXStaticText", value: "Older tool result") : button("Used 2 tools")) }
                    else { thread.children.append(button("Load older messages")) }
                }
            }
            return document([transcript("Coordinator context"), button("Threads"), thread], url: base + "?thread=session_\(currentThread)")
        }
        let links = (0..<(resolvedExpanded ? 8 : 7)).map { index in
            Node(role: "AXLink", title: "Task \(index)", url: base + "?thread=cmsg_\(index)", actions: ["AXPress"])
        }
        return document([button("Project settings"), transcript("Coordinator context"),
                         button("Waiting on you 2", expanded: true), button("Idle 5", expanded: true), button("Resolved 1", expanded: resolvedExpanded)] + tabs + links)
    }
    func perform(_ action: Action, expectedTree: Node) throws -> Bool {
        #expect(try readTree() == expectedTree)
        actions.append(action)
        switch action.intent {
        case .settings: page = changeProjectAfterSettings ? "other" : "general"
        case .settingsGeneral:
            if generalCannotPress { return false }; page = "general"
        case .settingsMemory, .memoryBack: page = "memory"
        case .memoryFile: page = "memoryFile"; memory = String(action.control.label.dropFirst(5))
        case .closeSettings, .threadBack, .threadsTab: page = "overview"
        case .threadGroup: resolvedExpanded.toggle()
        case .threadLink:
            page = "thread"; currentThread = Int(action.control.label.split(separator: " ").last ?? ""); toolExpanded = false
        case .toolDetails:
            if action.control.label == "Used 2 tools" { olderToolExpanded = true } else { toolExpanded = true }
        case .pagination:
            if page == "library" { libraryMore = true } else { historyOlder = true }
        case .libraryTab, .libraryBack: page = "library"
        case .libraryFolder: page = "libraryChild"
        case .routinesTab: page = "routines"
        default: return false
        }
        return true
    }
    func settle() async throws { if let cancelAfterActions, actions.count >= cancelAfterActions { throw CancellationError() } }
}

@Suite("Bounded cloud Cowork capture")
@MainActor
struct ClaudeCoworkCollectorTests {
    @Test func capturesEarlierMessagesAndToolsWithoutAnyProjectAction() async throws {
        let driver = CoworkCaptureScriptDriver()
        var progress: [ClaudeContextCapture.ProjectView] = []
        let result = try await ClaudeContextCapture.collectAvailableViews(driver: driver, profileID: "vir", profileLabel: "VIR", progress: { progress.append($0) })
        #expect(result.kind == .coworkConversation)
        #expect(result.projectURL == driver.sourceURL)
        #expect(result.views == progress && result.views.count >= 3)
        #expect(result.views.contains { $0.snapshot.text.contains("Original Cowork objective") })
        #expect(result.views.contains { $0.snapshot.text.contains("Earlier tool output") })
        #expect(result.views.contains { $0.snapshot.text.contains("Oldest available viewport") })
        #expect(result.inventory.contains { $0.kind == "reference" && $0.sourceURL == "https://example.test/report.pdf" })
        #expect(driver.actions.allSatisfy { [.pagination, .toolDetails, .scrollUp, .scrollDown].contains($0.intent) })
        #expect(!result.isCompleteProject && result.limitations.contains { $0.contains("No local JSONL") })
    }

    @Test func changingCoworkConversationStopsTheSweepAndKeepsReadViews() async throws {
        let driver = CoworkCaptureScriptDriver(); driver.changeConversation = true
        let result = try await ClaudeContextCapture.collectAvailableViews(driver: driver, profileID: "vir", profileLabel: "VIR")
        #expect(result.views.count == 1 && driver.actions.count == 1)
        #expect(result.views.allSatisfy { $0.snapshot.documentURL == driver.sourceURL })
        #expect(result.limitations.contains { $0.contains("conversation changed") })
    }

    @Test func identityFailureFromVerifiedDriverStopsAndPreservesContext() async throws {
        let driver = CoworkCaptureScriptDriver(); driver.identityChanged = true
        let result = try await ClaudeContextCapture.collectAvailableViews(driver: driver, profileID: "vir", profileLabel: "VIR")
        #expect(result.views.count == 1 && driver.actions.count == 1)
        #expect(result.limitations.contains { $0.contains("selected account") })
    }

    @Test func cancellationRetainsEveryDeliveredCoworkView() async throws {
        let driver = CoworkCaptureScriptDriver(); driver.cancelAfterAction = true
        var progress: [ClaudeContextCapture.ProjectView] = []
        let result = try await ClaudeContextCapture.collectAvailableViews(driver: driver, profileID: "vir", profileLabel: "VIR", progress: { progress.append($0) })
        #expect(result.cancelled)
        #expect(result.views == progress && result.views.count == 1)
    }

    @Test func projectOnlyEntryPointStillRejectsCoworkWithoutNavigation() async throws {
        let driver = CoworkCaptureScriptDriver()
        do {
            _ = try await ClaudeContextCapture.collectProject(driver: driver, profileID: "vir", profileLabel: "VIR")
            Issue.record("Project-only capture must reject a Cowork conversation")
        } catch let error as ClaudeContextCapture.CaptureError {
            #expect(error == .unsupportedPage)
        }
        #expect(driver.actions.isEmpty)
    }
}

@MainActor
private final class CoworkCaptureScriptDriver: ClaudeContextCapture.ProjectDriver {
    typealias Node = ClaudeContextCapture.Node
    typealias Action = ClaudeContextCapture.ReadAction
    let sourceURL = "https://claude.ai/cowork/cse_example"
    var actions: [Action] = []
    var page = 0
    var toolExpanded = false
    var changeConversation = false
    var identityChanged = false
    var cancelAfterAction = false

    func button(_ name: String) -> Node { Node(role: "AXButton", title: name, actions: ["AXPress"]) }
    func readTree() throws -> Node {
        if identityChanged && !actions.isEmpty { throw ClaudeContextCapture.CollectorError.sourceChanged }
        let url = changeConversation && !actions.isEmpty ? "https://claude.ai/cowork/cse_other" : sourceURL
        var messages: [Node] = [Node(role: "AXStaticText", value: "Current Cowork response")]
        if page == 0 { messages.append(button("Load older messages")) }
        else if page == 1 {
            messages.append(Node(role: "AXStaticText", value: "Original Cowork objective"))
            messages.append(toolExpanded ? Node(role: "AXStaticText", value: "Earlier tool output") : button("Used 2 tools"))
        } else {
            messages.append(Node(role: "AXStaticText", value: "Oldest available viewport"))
            messages.append(Node(role: "AXLink", title: "Report", url: "https://example.test/report.pdf", actions: ["AXPress"]))
        }
        // Deliberately include Project-like and consequential controls: Cowork must ignore them.
        let unrelated = [button("Project settings"), button("Library"), button("Threads"), button("Run command"), button("Send message")]
        return Node(role: "AXWindow", children: [Node(role: "AXWebArea", url: url, children: unrelated + [
            Node(role: "AXScrollArea", actions: page > 0 ? ["AXScrollUpByPage"] : [], children: [
                Node(role: "AXGroup", title: "Conversation messages", children: messages)
            ])
        ])])
    }
    func perform(_ action: Action, expectedTree: Node) throws -> Bool {
        #expect(try readTree() == expectedTree)
        actions.append(action)
        switch action.intent {
        case .pagination: page = 1
        case .toolDetails: toolExpanded = true
        case .scrollUp: page = 2
        default: Issue.record("Cowork collector requested an unrelated or consequential action"); return false
        }
        return true
    }
    func settle() async throws { if cancelAfterAction { throw CancellationError() } }
}

@Suite("Scoped native capture control validation")
struct ClaudeScopedCaptureControlTests {
    typealias Node = ClaudeContextCapture.Node
    typealias Action = ClaudeContextCapture.ReadAction
    let source = "https://claude.ai/cowork/cse_scoped"

    func tree(url: String? = nil, clock: String = "12:00", message: String = "Existing context",
              label: String = "Ran 5 commands", identifier: String? = "tools-1", actionNames: [String] = ["AXPress"],
              extraBefore: Bool = false, duplicate: Bool = false, group: String = "Tool group", groupID: String = "message-1") -> Node {
        let target = Node(role: "AXButton", title: label, identifier: identifier, actions: actionNames)
        var controls = [target]
        if extraBefore { controls.insert(Node(role: "AXStaticText", value: "New unrelated row"), at: 0) }
        if duplicate { controls.append(target) }
        return Node(role: "AXWindow", title: "Claude", children: [
            Node(role: "AXWebArea", title: "Claude", url: url ?? source, children: [
                Node(role: "AXStaticText", value: clock),
                Node(role: "AXGroup", title: "Chat messages", children: [
                    Node(role: "AXStaticText", value: message),
                    Node(role: "AXGroup", title: group, identifier: groupID, children: controls)
                ])
            ])
        ])
    }
    func action(_ tree: Node) throws -> Action {
        let target = try #require(ClaudeContextCapture.controls(tree).first { $0.role == "AXButton" })
        return Action(intent: .toolDetails, control: target)
    }
    func validate(_ before: Node, _ after: Node, sourceURL: String? = nil,
                  nativeIdentity: ClaudeContextCapture.NativeTargetIdentity = .unavailable) throws -> String? {
        try ClaudeContextCapture.validatedNativeAction(action(before), expectedTree: before, freshTree: after,
                                                       sourceURL: sourceURL ?? source, nativeIdentity: nativeIdentity)
    }

    @Test func unrelatedClockAndMessageUpdatesDoNotBlockStableDisclosure() throws {
        let before = tree()
        let after = tree(clock: "12:01", message: "Existing context with a live timestamp", actionNames: ["AXShowMenu", "AXPress"])
        #expect(before != after)
        #expect(try validate(before, after) == "AXPress")
    }

    @Test func movedOrReplacedControlIsRejected() {
        #expect(throws: ClaudeContextCapture.CollectorError.staleControl) { try validate(tree(), tree(extraBefore: true)) }
        #expect(throws: ClaudeContextCapture.CollectorError.staleControl) { try validate(tree(), tree(identifier: "different-tools")) }
        #expect(throws: ClaudeContextCapture.CollectorError.staleControl) { try validate(tree(), tree(label: "Ran 6 commands")) }
    }

    @Test func ambiguousEquivalentControlsAreRejectedEvenWhenOriginalPathStillExists() {
        #expect(throws: ClaudeContextCapture.CollectorError.staleControl) { try validate(tree(), tree(duplicate: true)) }
        #expect(throws: ClaudeContextCapture.CollectorError.staleControl) { try validate(tree(duplicate: true), tree(duplicate: true)) }
    }

    @Test func recurringDisclosuresNeedTheSameBoundNativeElement() throws {
        let repeated = tree(label: "Ran a command", identifier: nil, duplicate: true, groupID: "")
        // Both buttons have identical labels and ancestry, as in a transcript without AXIdentifiers.
        // Either specific retained element can be used; neither label nor ordinal proves identity.
        let buttons = ClaudeContextCapture.controls(repeated).filter { $0.role == "AXButton" }
        #expect(buttons.count == 2 && buttons[0].path != buttons[1].path)
        for button in buttons {
            let selected = Action(intent: .toolDetails, control: button)
            #expect(try ClaudeContextCapture.validatedNativeAction(selected, expectedTree: repeated, freshTree: repeated,
                                                                   sourceURL: source, nativeIdentity: .sameElement) == "AXPress")
            for absentOrChanged in [ClaudeContextCapture.NativeTargetIdentity.unavailable, .differentElement] {
                #expect(throws: ClaudeContextCapture.CollectorError.staleControl) {
                    try ClaudeContextCapture.validatedNativeAction(selected, expectedTree: repeated, freshTree: repeated,
                                                                   sourceURL: source, nativeIdentity: absentOrChanged)
                }
            }
        }
    }

    @Test func nativeIdentityComparisonUsesTheRetainedReferenceAndRejectsMissingOrDifferentElements() {
        // Creating application references performs no AX read, action or permission request.
        let pid = ProcessInfo.processInfo.processIdentifier
        let original = AXUIElementCreateApplication(pid), same = AXUIElementCreateApplication(pid)
        let different = AXUIElementCreateApplication(pid + 1)
        #expect(ClaudeContextCapture.nativeTargetIdentity(expected: original, current: same) == .sameElement)
        #expect(ClaudeContextCapture.nativeTargetIdentity(expected: original, current: different) == .differentElement)
        #expect(ClaudeContextCapture.nativeTargetIdentity(expected: nil, current: same) == .unavailable)
        #expect(ClaudeContextCapture.nativeTargetIdentity(expected: original, current: nil) == .unavailable)
    }

    @Test func nativeIdentityNeverOverridesMovedChangedOrUnsafeControls() {
        let before = tree(label: "Ran a command", identifier: nil, duplicate: true, groupID: "")
        for after in [
            tree(label: "Ran a command", identifier: nil, extraBefore: true, duplicate: true, groupID: ""),
            tree(label: "Run a command", identifier: nil, duplicate: true, groupID: ""),
            tree(label: "Ran a command", identifier: nil, duplicate: true, group: "Another message", groupID: ""),
            tree(label: "Ran a command", identifier: nil, actionNames: ["AXShowMenu"], duplicate: true, groupID: "")
        ] {
            #expect(throws: ClaudeContextCapture.CollectorError.staleControl) {
                try validate(before, after, nativeIdentity: .sameElement)
            }
        }
        // Replacing even a uniquely labelled target is denied by contrary native identity evidence.
        #expect(throws: ClaudeContextCapture.CollectorError.staleControl) {
            try validate(tree(), tree(), nativeIdentity: .differentElement)
        }
        #expect(throws: ClaudeContextCapture.CollectorError.sourceChanged) {
            try validate(before, tree(url: source + "?thread=another", label: "Ran a command", identifier: nil,
                                      duplicate: true, groupID: ""), nativeIdentity: .sameElement)
        }
    }

    @Test func repeatedDisclosuresStillNeedAnExactNativePressAction() throws {
        let unsupported = tree(label: "Ran a command", identifier: nil, actionNames: ["AXShowMenu"], duplicate: true, groupID: "")
        #expect(try validate(unsupported, unsupported, nativeIdentity: .sameElement) == nil)
        let unsafe = tree(label: "Run a command", identifier: nil, duplicate: true, groupID: "")
        #expect(throws: ClaudeContextCapture.CollectorError.staleControl) {
            try validate(unsafe, unsafe, nativeIdentity: .sameElement)
        }
    }

    @Test func changedConversationThreadTabOrDocumentIsRejected() {
        #expect(throws: ClaudeContextCapture.CollectorError.sourceChanged) { try validate(tree(), tree(url: "https://claude.ai/cowork/cse_other")) }
        let project = "https://claude.ai/epitaxy/project/chan_scoped"
        #expect(throws: ClaudeContextCapture.CollectorError.sourceChanged) {
            try validate(tree(url: project + "?thread=session_one"), tree(url: project + "?thread=session_two"), sourceURL: project)
        }
        #expect(throws: ClaudeContextCapture.CollectorError.sourceChanged) {
            try validate(tree(url: project), tree(url: project + "?overviewTab=library"), sourceURL: project)
        }
        #expect(throws: ClaudeContextCapture.CollectorError.sourceChanged) {
            try validate(tree(), tree(url: "https://example.test/cowork/cse_scoped"))
        }
    }

    @Test func changedAncestorOrRemovedNativeActionIsRejected() {
        #expect(throws: ClaudeContextCapture.CollectorError.staleControl) { try validate(tree(), tree(group: "Different message")) }
        #expect(throws: ClaudeContextCapture.CollectorError.staleControl) { try validate(tree(), tree(groupID: "message-2")) }
        #expect(throws: ClaudeContextCapture.CollectorError.staleControl) { try validate(tree(), tree(actionNames: [])) }
    }

    @Test func unsupportedActionRemainsUnavailableRatherThanInventingAPress() throws {
        let unsupported = tree(actionNames: [])
        #expect(try validate(unsupported, unsupported) == nil)
    }

    @Test func exactObservedSingularSummaryIsAllowedAndRecordedAsACaptureGap() throws {
        let singular = tree(label: "Ran a command")
        #expect(try validate(singular, singular) == "AXPress")
        let snapshot = try ClaudeContextCapture.parse(singular, profileID: "vir", profileLabel: "VIR")
        #expect(snapshot.collapsedControls == ["Ran a command"])
        #expect(snapshot.gaps.contains(.collapsedContent))
        for unsafe in ["Run a command", "Ran a command to change settings"] {
            let unknown = tree(label: unsafe)
            #expect(throws: ClaudeContextCapture.CollectorError.staleControl) { try validate(unknown, unknown) }
        }
    }
}
