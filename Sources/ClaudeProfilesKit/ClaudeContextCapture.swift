import AppKit
import ApplicationServices
import Foundation

/// Read-only capture of context Claude is already displaying. This does not generate a summary,
/// navigate, send a message, export a cloud database, or prove that off-screen history was captured.
public enum ClaudeContextCapture {
    public enum CaptureError: LocalizedError, Equatable {
        case accessibilityPermissionRequired, profileNotFound, notSignedIn, profileNotRunning
        case ambiguousProcess, processIdentityUnavailable, noWindow, unreadableWindow, unsupportedPage, noContext

        public var errorDescription: String? {
            switch self {
            case .accessibilityPermissionRequired:
                "Allow the application running Claude Profiles in System Settings → Privacy & Security → Accessibility, then try again. No permission prompt was opened automatically."
            case .profileNotFound: "The selected Claude profile no longer exists."
            case .notSignedIn: "Sign in to the selected Claude profile before capturing its context."
            case .profileNotRunning: "Open the selected Claude profile and the Project or Cowork conversation to capture."
            case .ambiguousProcess: "More than one running window process matches this profile; close the duplicate before capturing."
            case .processIdentityUnavailable: "The running Claude process could not be verified as the selected profile. Open it from Claude Profiles and try again."
            case .noWindow: "The selected Claude profile has no readable focused window."
            case .unreadableWindow: "Claude did not expose a readable window. Open the desired Project or Cowork conversation and try again."
            case .unsupportedPage: "Open a Claude Code Project or a Cowork project or conversation. Home, sign-in, ordinary chats and unrelated pages are not captured."
            case .noContext: "This view exposes no recognized conversation, project context or memory text. Open the desired conversation or Project settings and try again."
            }
        }
    }

    public enum Kind: String, Codable, Sendable { case codeProject, coworkProject, coworkConversation }
    public enum Coverage: String, Codable, Sendable { case currentViewOnly }
    public enum Gap: String, Codable, Sendable, CaseIterable {
        case otherViewsNotVisited, historyMayBeVirtualized, paginationAvailable, collapsedContent, treeReadLimited
        case embeddedArtifactNotCaptured
    }

    public struct Section: Codable, Equatable, Sendable {
        public var label: String
        public var text: String
        public init(label: String, text: String) { self.label = label; self.text = text }
    }

    public struct Snapshot: Codable, Equatable, Sendable {
        public var profileID: String
        public var profileLabel: String
        public var capturedAt: Date
        public var documentURL: String
        public var title: String
        public var kind: Kind
        public var coverage: Coverage = .currentViewOnly
        public var sections: [Section]
        public var gaps: [Gap]
        public var collapsedControls: [String]
        public var paginationControls: [String]

        public var text: String { sections.map { "## \($0.label)\n\n\($0.text)" }.joined(separator: "\n\n") }
        public var isCompleteProject: Bool { false }
    }

    /// A narrow, inert representation also used by deterministic tests. UI values are read only after
    /// the native reader has rejected secure fields, navigation, account menus and input composers.
    public struct Node: Equatable, Sendable {
        public var role: String
        public var subrole: String?
        public var title: String?
        public var description: String?
        public var value: String?
        public var url: String?
        public var identifier: String?
        public var expanded: Bool?
        public var position: Int?
        public var setSize: Int?
        public var truncated: Bool
        public var selected: Bool?
        public var actions: [String]
        public var children: [Node]

        public init(role: String, subrole: String? = nil, title: String? = nil, description: String? = nil,
                    value: String? = nil, url: String? = nil, identifier: String? = nil, expanded: Bool? = nil,
                    position: Int? = nil, setSize: Int? = nil, truncated: Bool = false, selected: Bool? = nil, actions: [String] = [], children: [Node] = []) {
            self.role = role; self.subrole = subrole; self.title = title; self.description = description
            self.value = value; self.url = url; self.identifier = identifier; self.expanded = expanded
            self.position = position; self.setSize = setSize; self.truncated = truncated
            self.selected = selected; self.actions = actions; self.children = children
        }
    }

    public struct Limits: Sendable {
        public var nodes: Int
        public var depth: Int
        public var characters: Int
        public init(nodes: Int = 20_000, depth: Int = 80, characters: Int = 2_000_000) {
            self.nodes = max(1, nodes); self.depth = max(1, depth); self.characters = max(1, characters)
        }
    }

    /// The only live entry point. It never requests Accessibility access, changes focus, presses a
    /// control or reads authentication stores. A profile engine without its explicit data dir is rejected.
    @MainActor
    public static func captureCurrentView(profileID: String, paths: Paths = .standard,
                                          limits: Limits = Limits(), now: Date = Date()) throws -> Snapshot {
        guard AXIsProcessTrusted() else { throw CaptureError.accessibilityPermissionRequired }
        let profile = try ProfileRegistry(paths: paths).load().first { $0.id == profileID }
        guard profileID == "main" || profile != nil else { throw CaptureError.profileNotFound }
        let directory = profileID == "main" ? paths.mainDataDir : paths.dataDir(for: profileID)
        let bundle = profileID == "main" ? paths.claudeApp : paths.engine(for: profileID)
        guard DesktopData.accountID(in: directory) != nil else { throw CaptureError.notSignedIn }
        let candidates = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL == bundle.standardizedFileURL }
        guard !candidates.isEmpty else { throw CaptureError.profileNotRunning }
        let matching = candidates.filter { matches(profileID: profileID, running: RunningClaude(app: $0), paths: paths) }
        guard !matching.isEmpty else { throw CaptureError.processIdentityUnavailable }
        guard matching.count == 1, let process = matching.first else { throw CaptureError.ambiguousProcess }
        let app = AXUIElementCreateApplication(process.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)
        guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) else { throw CaptureError.noWindow }
        var reader = Reader(limits: limits, deadline: Date().addingTimeInterval(15))
        let tree = reader.read(window, depth: 0)
        guard reader.count > 1 else { throw CaptureError.unreadableWindow }
        // Do not attach data to a profile if that process closed or changed during the read.
        guard !process.isTerminated, matches(profileID: profileID, running: RunningClaude(app: process), paths: paths) else {
            throw CaptureError.processIdentityUnavailable
        }
        return try parse(tree, profileID: profileID, profileLabel: profile?.label ?? "MAIN", now: now)
    }

    static func matches(profileID: String, running: RunningClaude, paths: Paths) -> Bool {
        let bundle = profileID == "main" ? paths.claudeApp : paths.engine(for: profileID)
        guard running.bundlePath == bundle.standardizedFileURL.path, let arguments = running.arguments else { return false }
        let explicit = ProcessArguments.userDataDir(in: arguments)
        if profileID == "main" {
            return explicit == nil || URL(fileURLWithPath: explicit!).standardizedFileURL == paths.mainDataDir.standardizedFileURL
        }
        guard let explicit else { return false }
        return URL(fileURLWithPath: explicit).standardizedFileURL == paths.dataDir(for: profileID).standardizedFileURL
    }

    /// Parses only explicitly scoped project/conversation text. It intentionally never upgrades an AX
    /// view into a claim of complete history, even when there is no visible "load older" button.
    public static func parse(_ tree: Node, profileID: String, profileLabel: String, now: Date = Date()) throws -> Snapshot {
        let documents = descendants(tree).filter { $0.role == "AXWebArea" && route($0.url) != nil }
        guard documents.count == 1, let document = documents.first, let url = document.url, let kind = route(url) else {
            throw CaptureError.unsupportedPage
        }
        var sections: [Section] = [], collapsed: [String] = [], pagination: [String] = []
        var gaps: Set<Gap> = [.otherViewsNotVisited, .historyMayBeVirtualized]
        var headings: [String] = []
        let supportsProjectFields = kind == .codeProject || kind == .coworkProject
        func visit(_ node: Node, insideContext: Bool = false) {
            guard !excluded(node) else { return }
            if node.role == "AXWebArea", node.url != url {
                if isArtifactURL(node.url) { gaps.insert(.embeddedArtifactNotCaptured) }
                return
            }
            if node.truncated { gaps.insert(.treeReadLimited) }
            let label = displayLabel(node)
            if isPagination(node) { pagination.append(label); gaps.insert(.paginationAvailable) }
            if isCollapsed(node) { collapsed.append(label); gaps.insert(.collapsedContent) }
            if node.role == "AXHeading", let heading = textValue(node) { headings.append(heading) }
            if supportsProjectFields, let field = contextField(node), let text = nonempty(node.value) {
                sections.append(Section(label: field, text: text)); return
            }
            let nestedTranscript = hasNestedTranscript(node, documentURL: url)
            let content = isContentRoot(node) && !nestedTranscript
            if content && !insideContext {
                let text = contextText(node, documentURL: url)
                if !text.isEmpty { sections.append(Section(label: label.isEmpty ? "Visible project context" : label, text: text)) }
            }
            for child in node.children { visit(child, insideContext: insideContext || content) }
        }
        visit(document)
        if tree.truncated { gaps.insert(.treeReadLimited) }
        guard !sections.isEmpty else { throw CaptureError.noContext }
        let repeatedLabels = Set(sections.map(\.label).filter { label in sections.filter { $0.label == label }.count > 1 })
        var ordinals: [String: Int] = [:]
        for index in sections.indices where repeatedLabels.contains(sections[index].label) {
            let label = sections[index].label
            ordinals[label, default: 0] += 1
            sections[index].label = "\(label) — visible stream \(ordinals[label]!) (identity unverified)"
        }
        let title = headings.first { !["project memory", "memory", "library", "settings", "general", "projects"].contains($0.lowercased()) }
            ?? nonempty(document.title).flatMap { $0 == "Claude" ? nil : $0 } ?? "Claude project context"
        return Snapshot(profileID: profileID, profileLabel: profileLabel, capturedAt: now, documentURL: url,
                        title: title, kind: kind, sections: sections,
                        gaps: Gap.allCases.filter { gaps.contains($0) },
                        collapsedControls: collapsed, paginationControls: pagination)
    }

    static func route(_ raw: String?) -> Kind? {
        guard let raw, let url = URLComponents(string: raw), url.scheme == "https", url.host == "claude.ai",
              url.user == nil, url.password == nil, url.port == nil,
              (url.queryItems ?? []).allSatisfy({ ["thread", "msg"].contains($0.name)
                  || ($0.name == "overviewTab" && $0.value == "library") }), url.fragment == nil else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        if parts.count == 3, parts[0] == "epitaxy", parts[1] == "project", validID(parts[2], prefix: "chan_") { return .codeProject }
        if parts.count == 3, parts[0] == "cowork", parts[1] == "project", safeID(parts[2]) { return .coworkProject }
        if parts.count == 2, parts[0] == "cowork", ["local_", "cse_", "session_"].contains(where: { validID(parts[1], prefix: $0) }) { return .coworkConversation }
        return nil
    }

    private static func safeID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,180}$", options: .regularExpression) != nil
    }
    private static func validID(_ value: String, prefix: String) -> Bool { value.hasPrefix(prefix) && value.count > prefix.count && safeID(value) }
    private static func nonempty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }; return text
    }
    private static func normalizedLabel(_ node: Node) -> String { displayLabel(node).lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func displayLabel(_ node: Node) -> String { nonempty(node.title) ?? nonempty(node.description) ?? "" }
    private static func textValue(_ node: Node) -> String? { nonempty(node.value) ?? nonempty(node.title) ?? nonempty(node.description) }
    private static let inputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField"]
    private static func contextField(_ node: Node) -> String? {
        guard inputRoles.contains(node.role) else { return nil }
        switch normalizedLabel(node) {
        case "project instructions": return "Project instructions"
        case "goal": return "Goal"
        case "name", "project name": return "Project name"
        default: return nil
        }
    }
    private static func excluded(_ node: Node) -> Bool {
        if ["AXMenu", "AXMenuBar", "AXMenuItem", "AXToolbar", "AXSecureTextField"].contains(node.role) { return true }
        if node.role == "AXOutline" && normalizedLabel(node) != "library" { return true }
        if node.subrole == "AXLandmarkNavigation" && normalizedLabel(node) != "settings sections" { return true }
        if ["AXSecureTextField", "AXSearchField"].contains(node.subrole ?? "") { return true }
        let label = normalizedLabel(node)
        if ["sidebar", "navigation", "main navigation", "application navigation", "account menu", "profile menu", "user menu", "composer", "message composer", "prompt", "message", "write your prompt", "reply"].contains(label) { return true }
        if ["sidebar", "account-menu", "profile-menu", "message-composer", "prompt-textarea"].contains(node.identifier ?? "") { return true }
        return inputRoles.contains(node.role) && contextField(node) == nil
    }
    private static func isContentRoot(_ node: Node) -> Bool {
        if node.subrole == "AXLandmarkMain" || node.role == "AXMain" { return true }
        let labels: Set<String> = ["chat messages", "conversation messages", "conversation", "messages", "transcript", "main content",
                                   "project context", "project settings", "project memory", "auto memory", "memory files", "library", "project knowledge"]
        if labels.contains(normalizedLabel(node)) { return true }
        // An opened memory file can be named by its filename without a Project memory heading.
        // Only noneditable containers with a Markdown filename are admitted; their composer is pruned.
        if ["AXGroup", "AXSection"].contains(node.role), normalizedLabel(node).hasSuffix(".md") { return true }
        return node.children.contains { child in
            child.role == "AXHeading" && ["project memory", "auto memory", "project instructions", "library"].contains((child.value ?? child.title ?? child.description ?? "").lowercased())
        }
    }
    private static func isPagination(_ node: Node) -> Bool {
        guard node.role == "AXButton" || node.role == "AXLink" else { return false }
        let label = normalizedLabel(node)
        return ["load more", "load older", "older messages", "earlier messages", "previous messages", "show earlier"].contains { label.contains($0) }
    }
    private static func isCollapsed(_ node: Node) -> Bool {
        if node.role == "AXDisclosureTriangle" { return node.expanded != true }
        let label = normalizedLabel(node)
        // Claude's aggregated tool summaries often omit AXExpanded entirely. Their presence is an
        // unresolved capture gap until a future collector opens and verifies the underlying results.
        if node.role == "AXButton", node.expanded != true,
           isToolSummaryLabel(label) { return true }
        guard node.expanded == false else { return false }
        return ["tool", "read", "bash", "command", "result", "details"].contains { label.contains($0) }
    }
    private static func isToolSummaryLabel(_ label: String) -> Bool {
        label == "ran a command" || label.range(of: "^(ran [0-9]+ commands?\\b|used [0-9]+ tools?\\b|message sent to another session\\b)", options: .regularExpression) != nil
    }
    private static func descendants(_ node: Node) -> [Node] {
        guard !excluded(node) else { return [] }
        return [node] + node.children.flatMap(descendants)
    }
    private static func hasNestedTranscript(_ node: Node, documentURL: String) -> Bool {
        node.children.contains { child in
            guard !excluded(child) else { return false }
            if child.role == "AXWebArea", child.url != documentURL { return false }
            if ["chat messages", "conversation messages", "transcript"].contains(normalizedLabel(child)) { return true }
            return hasNestedTranscript(child, documentURL: documentURL)
        }
    }
    private static func contextText(_ node: Node, documentURL: String) -> String {
        guard !excluded(node), !inputRoles.contains(node.role) else { return "" }
        if node.role == "AXWebArea", node.url != documentURL { return "" }
        var texts: [String] = []
        if node.role == "AXLink" {
            let text = textValue(node) ?? ""
            if let raw = node.url, let reference = safeReferenceURL(raw) {
                texts.append(text.isEmpty || text == reference ? reference : "\(text) (\(reference))")
            } else if !text.isEmpty, node.url == nil || text != node.url { texts.append(text) }
        } else if ["AXStaticText", "AXHeading"].contains(node.role), let text = textValue(node) { texts.append(text) }
        else if ["AXRow", "AXCell"].contains(node.role), let text = textValue(node) { texts.append(text) }
        for child in node.children {
            let text = contextText(child, documentURL: documentURL)
            if !text.isEmpty { texts.append(text) }
        }
        return texts.joined(separator: "\n")
    }

    private static func safeReferenceURL(_ raw: String) -> String? {
        guard let url = URLComponents(string: raw), ["https", "http", "file"].contains(url.scheme ?? ""),
              url.user == nil, url.password == nil,
              !(url.queryItems ?? []).contains(where: { ["token", "access_token", "auth", "authorization", "secret", "password", "signature", "x-amz-signature", "code"].contains($0.name.lowercased()) }) else { return nil }
        return raw
    }
    private static func isArtifactURL(_ raw: String?) -> Bool {
        guard let raw, let url = URLComponents(string: raw), url.scheme == "https", url.host == "claude.ai",
              url.user == nil, url.password == nil else { return false }
        let parts = url.path.split(separator: "/")
        return parts.count == 3 && parts[0] == "code" && parts[1] == "artifact" && UUID(uuidString: String(parts[2])) != nil
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private static func element(_ source: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(source, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private struct Reader {
        var limits: Limits
        var count = 0
        var characters = 0
        var elements: [String: AXUIElement] = [:]
        var deadline: Date?
        mutating func read(_ element: AXUIElement, depth: Int, insideDocument: Bool = false, path: [Int] = []) -> Node {
            guard count < limits.nodes, depth < limits.depth, characters < limits.characters, !Task.isCancelled, deadline.map({ Date() < $0 }) ?? true else { return Node(role: "AXGroup", truncated: true) }
            count += 1
            func string(_ key: String) -> String? {
                guard !Task.isCancelled, deadline.map({ Date() < $0 }) ?? true else { return nil }
                return attribute(element, key) as? String
            }
            var node = Node(role: string(kAXRoleAttribute) ?? "", subrole: string(kAXSubroleAttribute),
                            title: string(kAXTitleAttribute), description: string(kAXDescriptionAttribute) ?? string("AXPlaceholderValue"), identifier: string(kAXIdentifierAttribute))
            guard !excluded(node) else { return Node(role: "AXGroup") }
            elements[path.map(String.init).joined(separator: ".")] = element
            var readableContent = insideDocument
            if node.role == "AXWebArea" {
                node.url = (attribute(element, kAXURLAttribute) as? URL)?.absoluteString ?? string(kAXURLAttribute) ?? string(kAXDocumentAttribute)
                readableContent = route(node.url) != nil
                // Electron's file:// shell contains the actual claude.ai document. Traverse the shell
                // to find that document, but do not read values from it or from unrelated child frames.
                if insideDocument && !readableContent { return Node(role: "AXWebArea", url: node.url) }
            }
            if readableContent && (["AXStaticText", "AXHeading", "AXLink", "AXRow", "AXCell"].contains(node.role) || contextField(node) != nil) {
                if let value = string(kAXValueAttribute) {
                    let remaining = max(0, limits.characters - characters)
                    node.value = String(value.prefix(remaining)); characters += node.value?.count ?? 0
                    if value.count > remaining { node.truncated = true }
                }
            }
            if readableContent && node.role == "AXLink" {
                node.url = (attribute(element, kAXURLAttribute) as? URL)?.absoluteString ?? string(kAXURLAttribute)
            }
            node.expanded = (attribute(element, kAXExpandedAttribute) as? NSNumber)?.boolValue
            node.selected = (attribute(element, kAXSelectedAttribute) as? NSNumber)?.boolValue
            if (["AXCheckBox", "AXRadioButton"].contains(node.role) || (node.role == "AXButton" && normalizedLabel(node).hasPrefix("overview "))), node.selected == nil {
                node.selected = (attribute(element, kAXValueAttribute) as? NSNumber)?.boolValue
            }
            if readableContent && ["AXButton", "AXLink", "AXRadioButton", "AXTab", "AXCheckBox", "AXRow", "AXScrollArea", "AXDisclosureTriangle"].contains(node.role) {
                var actionNames: CFArray?
                if AXUIElementCopyActionNames(element, &actionNames) == .success { node.actions = actionNames as? [String] ?? [] }
            }
            node.position = (attribute(element, "AXARIAPosInSet") as? NSNumber)?.intValue
            node.setSize = (attribute(element, "AXARIASetSize") as? NSNumber)?.intValue
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
            if result == .success, let children = value as? [AXUIElement] {
                for child in children {
                    guard count < limits.nodes, characters < limits.characters else { node.truncated = true; break }
                    node.children.append(read(child, depth: depth + 1, insideDocument: readableContent, path: path + [node.children.count]))
                }
            } else if result != .noValue && result != .attributeUnsupported { node.truncated = true }
            return node
        }
    }
}

extension ClaudeContextCapture {
    public struct ProjectLimits: Sendable {
        public var views: Int
        public var actions: Int
        public var scrollsPerConversation: Int
        public var seconds: TimeInterval
        public var tree: Limits
        public init(views: Int = 240, actions: Int = 200, scrollsPerConversation: Int = 12,
                    seconds: TimeInterval = 240, tree: Limits = Limits()) {
            self.views = max(1, views); self.actions = max(1, actions)
            self.scrollsPerConversation = max(0, scrollsPerConversation)
            self.seconds = max(1, seconds); self.tree = tree
        }
    }

    public struct ProjectView: Codable, Equatable, Sendable {
        /// Scope is retained separately from the native URL because settings and memory reuse it.
        public var scope: String
        public var snapshot: Snapshot
    }
    public struct InventoryItem: Codable, Equatable, Sendable {
        public var kind: String
        public var label: String
        public var sourceURL: String?
        public var capturedURL: String?
        public var captured: Bool
    }
    public struct ProjectCapture: Codable, Equatable, Sendable {
        public var profileID: String
        /// Canonical source URL; name retained for compatibility with existing Project captures.
        public var projectURL: String
        public var kind: Kind { ClaudeContextCapture.route(projectURL) ?? .codeProject }
        public var views: [ProjectView] = []
        public var inventory: [InventoryItem] = []
        public var limitations: [String] = []
        public var cancelled = false
        /// AX scroll stopping is not proof that Claude has exported every historical message/file.
        public var isCompleteProject: Bool { false }
    }

    /// Opens existing read-only Project views using a narrow allowlist. It does not send prompts,
    /// change project settings, run tools/routines, download files or consume model quota.
    /// The caller receives each captured view immediately, so cancellation never discards it.
    @MainActor
    public static func captureProject(profileID: String, paths: Paths = .standard,
                                      limits: ProjectLimits = ProjectLimits(),
                                      progress: @escaping @MainActor (ProjectView) -> Void = { _ in }) async throws -> ProjectCapture {
        let driver = try NativeProjectDriver(profileID: profileID, paths: paths, limits: limits, requiredKind: .codeProject)
        return try await collectProject(driver: driver, profileID: profileID,
                                        profileLabel: driver.profileLabel, limits: limits, progress: progress)
    }

    /// Selects a bounded Project or Cowork transcript sweep from the open native route.
    /// Cowork reads existing messages/tool disclosures only; Project navigation is forbidden.
    @MainActor
    public static func captureAvailableViews(profileID: String, paths: Paths = .standard,
                                             limits: ProjectLimits = ProjectLimits(),
                                             progress: @escaping @MainActor (ProjectView) -> Void = { _ in }) async throws -> ProjectCapture {
        let driver = try NativeProjectDriver(profileID: profileID, paths: paths, limits: limits)
        return try await collectAvailableViews(driver: driver, profileID: profileID,
                                               profileLabel: driver.profileLabel, limits: limits, progress: progress)
    }

    enum ReadIntent: String, Sendable {
        case settings, closeSettings, settingsGeneral, settingsMemory, memoryFile, memoryBack
        case overview, threadsTab, threadGroup, threadLink, threadBack, libraryTab, libraryFolder, libraryBack
        case routinesTab, toolDetails, pagination, scrollUp, scrollDown
    }
    struct ReadControl: Equatable, Sendable {
        var path: [Int]
        var role: String
        var label: String
        var url: String?
        var ancestors: [String]
        var identifier: String?
        var ancestorIdentifiers: [String]
        var expanded: Bool?
        var selected: Bool?
        var actions: [String]
        var inTranscript: Bool
        var containsTranscript: Bool
    }
    struct ReadAction: Equatable, Sendable {
        var intent: ReadIntent
        var control: ReadControl
    }
    enum CollectorError: LocalizedError, Equatable {
        case sourceChanged, staleControl, limitReached
        var errorDescription: String? {
            switch self {
            case .sourceChanged: "Capture stopped because the selected account, process, project or conversation changed. Already captured views are retained."
            case .staleControl: "Capture stopped because Claude's view changed before a read-only control could be used. Already captured views are retained."
            case .limitReached: "The bounded capture reached its time, view or action limit. Already captured views are retained; other context remains unverified."
            }
        }
    }
    @MainActor
    protocol ProjectDriver: AnyObject {
        func readTree() throws -> Node
        func perform(_ action: ReadAction, expectedTree: Node) throws -> Bool
        func settle() async throws
    }

    static func canonicalProjectURL(_ raw: String?) -> String? {
        guard let raw, route(raw) == .codeProject, var url = URLComponents(string: raw) else { return nil }
        url.query = nil; return url.string
    }
    static func canonicalSourceURL(_ raw: String?) -> String? {
        guard let raw, let kind = route(raw), [.codeProject, .coworkConversation].contains(kind),
              var url = URLComponents(string: raw) else { return nil }
        url.query = nil; return url.string
    }
    static func projectDocument(_ tree: Node) -> Node? {
        let docs = descendants(tree).filter { $0.role == "AXWebArea" && route($0.url) != nil }
        return docs.count == 1 ? docs[0] : nil
    }
    static func controls(_ tree: Node) -> [ReadControl] {
        var result: [ReadControl] = []
        func walk(_ node: Node, path: [Int], ancestors: [String], ancestorIdentifiers: [String], approved: Bool, inTranscript: Bool) {
            guard !excluded(node) else { return }
            let accepted = node.role == "AXWebArea" ? route(node.url) != nil : approved
            if node.role == "AXWebArea" && approved && !accepted { return }
            let name = displayLabel(node), label = normalizedLabel(node)
            let transcript = ["chat messages", "conversation messages", "transcript"].contains(label)
            if accepted && ["AXButton", "AXLink", "AXRadioButton", "AXTab", "AXCheckBox", "AXRow", "AXScrollArea", "AXDisclosureTriangle"].contains(node.role) {
                result.append(ReadControl(path: path, role: node.role, label: name, url: node.url, ancestors: ancestors,
                                          identifier: node.identifier, ancestorIdentifiers: ancestorIdentifiers,
                                          expanded: node.expanded, selected: node.selected, actions: node.actions,
                                          inTranscript: inTranscript || transcript,
                                          containsTranscript: descendants(node).contains { ["chat messages", "conversation messages", "transcript"].contains(normalizedLabel($0)) }))
            }
            for (index, child) in node.children.enumerated() {
                walk(child, path: path + [index], ancestors: ancestors + (name.isEmpty ? [] : [name]),
                     ancestorIdentifiers: ancestorIdentifiers + [node.identifier ?? ""], approved: accepted, inTranscript: inTranscript || transcript)
            }
        }
        walk(tree, path: [], ancestors: [], ancestorIdentifiers: [], approved: false, inTranscript: false)
        return result
    }
    private static func allowed(_ c: ReadControl, _ intent: ReadIntent, projectURL: String) -> Bool {
        if route(projectURL) == .coworkConversation && ![ReadIntent.toolDetails, .pagination, .scrollUp, .scrollDown].contains(intent) { return false }
        let label = c.label.lowercased(), ancestors = c.ancestors.map { $0.lowercased() }
        let settings = ancestors.contains("project settings")
        let sectionNavigation = ancestors.contains("settings sections")
        let button = c.role == "AXButton"
        let tab = ["AXRadioButton", "AXTab", "AXButton"].contains(c.role)
        let transcript = c.inTranscript || c.containsTranscript
        // Text and artifacts may include arbitrary controls; navigation is never taken from them.
        switch intent {
        case .settings: return button && label == "project settings" && !c.inTranscript && !settings
        case .closeSettings: return button && label == "close" && settings
        case .settingsGeneral: return button && label == "general" && settings
        case .settingsMemory: return button && label == "memory" && settings && sectionNavigation
        case .memoryBack: return button && label == "memory" && settings && !sectionNavigation
        case .memoryFile:
            return button && settings && label.hasPrefix("open ") && label.hasSuffix(".md") && !c.inTranscript
        case .overview:
            return ["AXCheckBox", "AXButton"].contains(c.role) && label.hasPrefix("overview ") && !c.inTranscript && !settings
        case .threadsTab: return tab && (label == "threads" || label.hasPrefix("threads ")) && !c.inTranscript && !settings
        case .threadBack: return button && label == "threads" && !c.inTranscript && !settings
        case .threadGroup:
            return button && !c.inTranscript && !settings && label.range(of: "^(waiting on you|idle|resolved) [0-9]+$", options: .regularExpression) != nil
        case .threadLink:
            guard c.role == "AXLink", !c.inTranscript, !settings, let url = c.url,
                  canonicalProjectURL(url) == projectURL else { return false }
            return URLComponents(string: url)?.queryItems?.contains(where: { $0.name == "thread" && !($0.value ?? "").isEmpty }) == true
        case .libraryTab: return tab && label == "library" && !c.inTranscript && !settings
        case .libraryBack: return button && label == "library" && !c.inTranscript && !settings
        case .libraryFolder:
            return c.role == "AXRow" && ancestors.contains("library") && label.range(of: " — folder(?: actions for .+)?$", options: .regularExpression) != nil
        case .routinesTab: return tab && label == "routines" && !c.inTranscript && !settings
        case .toolDetails:
            guard c.inTranscript, button || c.role == "AXDisclosureTriangle", c.expanded != true else { return false }
            return isToolSummaryLabel(label)
                || ["show tool results", "show tool details"].contains(label)
        case .pagination:
            return (button || c.role == "AXLink") && (transcript || ancestors.contains("library")) &&
                ["load more", "load older messages", "older messages", "earlier messages", "previous messages", "show earlier messages"].contains(label)
        case .scrollUp: return c.role == "AXScrollArea" && transcript && c.actions.contains(where: { ["AXScrollUpByPage", "AXScrollUp"].contains($0) })
        case .scrollDown: return c.role == "AXScrollArea" && transcript && c.actions.contains(where: { ["AXScrollDownByPage", "AXScrollDown"].contains($0) })
        }
    }

    private static func sameSemanticControl(_ lhs: ReadControl, _ rhs: ReadControl) -> Bool {
        lhs.role == rhs.role && lhs.label == rhs.label && lhs.url == rhs.url && lhs.ancestors == rhs.ancestors
            && lhs.identifier == rhs.identifier && lhs.ancestorIdentifiers == rhs.ancestorIdentifiers
            && lhs.expanded == rhs.expanded && lhs.selected == rhs.selected
            && lhs.inTranscript == rhs.inTranscript && lhs.containsTranscript == rhs.containsTranscript
    }

    enum NativeTargetIdentity: Equatable, Sendable {
        case unavailable, sameElement, differentElement
    }

    /// This evidence comes from native element references retained across the two reads, never
    /// from a label, child index or AXIdentifier that could be reused by another control.
    static func nativeTargetIdentity(expected: AXUIElement?, current: AXUIElement?) -> NativeTargetIdentity {
        guard let expected, let current else { return .unavailable }
        return CFEqual(expected, current) ? .sameElement : .differentElement
    }

    /// Validates just the source view and target control, not unrelated clocks, sidebar text or other
    /// messages. Repeated disclosure labels require the same native element at the same path. Without
    /// that evidence, ambiguous controls fail closed. The live driver separately pins the process,
    /// account and window before each read.
    static func validatedNativeAction(_ action: ReadAction, expectedTree: Node, freshTree: Node,
                                      sourceURL: String, nativeIdentity: NativeTargetIdentity = .unavailable) throws -> String? {
        guard let expectedDocument = projectDocument(expectedTree), let freshDocument = projectDocument(freshTree),
              expectedDocument.url == freshDocument.url,
              canonicalSourceURL(expectedDocument.url) == sourceURL,
              canonicalSourceURL(freshDocument.url) == sourceURL else { throw CollectorError.sourceChanged }
        let expected = controls(expectedTree), fresh = controls(freshTree)
        guard nativeIdentity != .differentElement,
              expected.contains(action.control), allowed(action.control, action.intent, projectURL: sourceURL),
              let current = fresh.first(where: { $0.path == action.control.path }),
              sameSemanticControl(current, action.control), allowed(current, action.intent, projectURL: sourceURL) else {
            throw CollectorError.staleControl
        }
        let unambiguous = expected.filter({ sameSemanticControl($0, action.control) }).count == 1
            && fresh.filter({ sameSemanticControl($0, action.control) }).count == 1
        guard unambiguous || (action.intent == .toolDetails && nativeIdentity == .sameElement) else {
            throw CollectorError.staleControl
        }
        let nativeAction: String?
        switch action.intent {
        case .scrollUp: nativeAction = ["AXScrollUpByPage", "AXScrollUp"].first { action.control.actions.contains($0) }
        case .scrollDown: nativeAction = ["AXScrollDownByPage", "AXScrollDown"].first { action.control.actions.contains($0) }
        default: nativeAction = action.control.actions.contains(kAXPressAction) ? kAXPressAction : nil
        }
        guard let nativeAction else { return nil }
        guard current.actions.contains(nativeAction) else { throw CollectorError.staleControl }
        return nativeAction
    }

    @MainActor
    private final class NativeProjectDriver: ProjectDriver {
        let profileID: String, profileLabel: String, paths: Paths, process: NSRunningApplication
        let accountID: String, app: AXUIElement, initialWindow: AXUIElement
        let limits: ProjectLimits, deadline: Date
        let requiredKind: Kind?
        var projectURL: String?
        var lastTree: Node?
        var lastElements: [String: AXUIElement] = [:]

        init(profileID: String, paths: Paths, limits: ProjectLimits, requiredKind: Kind? = nil) throws {
            guard AXIsProcessTrusted() else { throw CaptureError.accessibilityPermissionRequired }
            self.profileID = profileID; self.paths = paths; self.limits = limits; self.requiredKind = requiredKind
            deadline = Date().addingTimeInterval(limits.seconds)
            let profile = try ProfileRegistry(paths: paths).load().first { $0.id == profileID }
            guard profileID == "main" || profile != nil else { throw CaptureError.profileNotFound }
            profileLabel = profile?.label ?? "MAIN"
            let directory = profileID == "main" ? paths.mainDataDir : paths.dataDir(for: profileID)
            guard let accountID = DesktopData.accountID(in: directory) else { throw CaptureError.notSignedIn }
            self.accountID = accountID
            let matching = NSWorkspace.shared.runningApplications.filter { matches(profileID: profileID, running: RunningClaude(app: $0), paths: paths) }
            guard !matching.isEmpty else { throw CaptureError.profileNotRunning }
            guard matching.count == 1, let process = matching.first else { throw CaptureError.ambiguousProcess }
            self.process = process; app = AXUIElementCreateApplication(process.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 1)
            guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) else { throw CaptureError.noWindow }
            initialWindow = window
        }
        private func verify() throws {
            try Task.checkCancellation()
            guard Date() < deadline else { throw CollectorError.limitReached }
            let directory = profileID == "main" ? paths.mainDataDir : paths.dataDir(for: profileID)
            guard !process.isTerminated, matches(profileID: profileID, running: RunningClaude(app: process), paths: paths),
                  DesktopData.accountID(in: directory) == accountID else { throw CollectorError.sourceChanged }
            if let currentWindow = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute),
               !CFEqual(currentWindow, initialWindow) { throw CollectorError.sourceChanged }
        }
        func readTree() throws -> Node {
            try verify()
            var reader = Reader(limits: limits.tree, deadline: min(deadline, Date().addingTimeInterval(15)))
            let tree = reader.read(initialWindow, depth: 0)
            try verify()
            guard let document = projectDocument(tree), let identity = canonicalSourceURL(document.url),
                  requiredKind == nil || route(document.url) == requiredKind else {
                if projectURL == nil { throw CaptureError.unsupportedPage }
                throw CollectorError.sourceChanged
            }
            if let projectURL, identity != projectURL { throw CollectorError.sourceChanged }
            projectURL = identity; lastTree = tree; lastElements = reader.elements
            return tree
        }
        func perform(_ action: ReadAction, expectedTree: Node) throws -> Bool {
            try verify()
            let path = action.control.path.map(String.init).joined(separator: ".")
            // Bind the reference to the exact prior read that produced this action. This is a
            // comparison of retained snapshots, not a requirement that live window text stays still.
            guard lastTree == expectedTree, let expectedTarget = lastElements[path] else { throw CollectorError.staleControl }
            // AX elements are ephemeral. Re-read the pinned view, but unrelated live text must not
            // make a stable, allowlisted disclosure control look stale.
            let fresh = try readTree()
            guard let projectURL else { throw CollectorError.sourceChanged }
            guard let target = lastElements[path] else { throw CollectorError.staleControl }
            guard let nativeAction = try validatedNativeAction(action, expectedTree: expectedTree, freshTree: fresh,
                                                               sourceURL: projectURL,
                                                               nativeIdentity: nativeTargetIdentity(expected: expectedTarget, current: target)) else { return false }
            return AXUIElementPerformAction(target, nativeAction as CFString) == .success
        }
        func settle() async throws { try await Task.sleep(for: .milliseconds(220)); try verify() }
    }

    @MainActor
    static func collectProject(driver: any ProjectDriver, profileID: String, profileLabel: String,
                               limits: ProjectLimits = ProjectLimits(),
                               progress: @escaping @MainActor (ProjectView) -> Void = { _ in }) async throws -> ProjectCapture {
        let initial = try driver.readTree()
        guard let document = projectDocument(initial), let projectURL = canonicalProjectURL(document.url) else { throw CaptureError.unsupportedPage }
        let runner = ProjectRunner(driver: driver, initial: initial, projectURL: projectURL,
                                   profileID: profileID, profileLabel: profileLabel, limits: limits, progress: progress)
        return await runner.run()
    }

    @MainActor
    static func collectAvailableViews(driver: any ProjectDriver, profileID: String, profileLabel: String,
                                      limits: ProjectLimits = ProjectLimits(),
                                      progress: @escaping @MainActor (ProjectView) -> Void = { _ in }) async throws -> ProjectCapture {
        let initial = try driver.readTree()
        guard let document = projectDocument(initial), let sourceURL = canonicalSourceURL(document.url),
              let kind = route(document.url) else { throw CaptureError.unsupportedPage }
        let runner = ProjectRunner(driver: driver, initial: initial, projectURL: sourceURL,
                                   profileID: profileID, profileLabel: profileLabel, limits: limits, kind: kind, progress: progress)
        return await runner.run()
    }

    @MainActor
    private final class ProjectRunner {
        let driver: any ProjectDriver, projectURL: String, profileLabel: String, limits: ProjectLimits
        let progress: @MainActor (ProjectView) -> Void, deadline: Date
        let kind: Kind
        var tree: Node, result: ProjectCapture, actionCount = 0
        var seenViews: Set<String> = []
        var visitedMemory: Set<String> = []
        var visitedThreads: Set<String> = []
        init(driver: any ProjectDriver, initial: Node, projectURL: String, profileID: String,
             profileLabel: String, limits: ProjectLimits, kind: Kind = .codeProject, progress: @escaping @MainActor (ProjectView) -> Void) {
            self.kind = kind
            self.driver = driver; tree = initial; self.projectURL = projectURL; self.profileLabel = profileLabel
            self.limits = limits; self.progress = progress; deadline = Date().addingTimeInterval(limits.seconds)
            let limitations = kind == .coworkConversation
                ? ["PARTIAL: a read-only sweep of the open Cowork conversation. AX scroll boundaries do not prove complete historical messages or tool output.",
                   "Attachment references are inventoried; original files, remote runtime, tool permissions and off-screen results are not exported. No local JSONL history is assumed for cloud Cowork."]
                : ["PARTIAL: a read-only sweep of observed Project views. AX scroll boundaries do not prove complete historical messages, tool output, attachments or Library files.",
                   "Library and attachment references are inventoried; original files and embedded artifact contents are not downloaded."]
            result = ProjectCapture(profileID: profileID, projectURL: projectURL, limitations: limitations)
        }
        func issue(_ text: String) { if !result.limitations.contains(text) { result.limitations.append(text) } }
        func check() throws {
            try Task.checkCancellation()
            guard Date() < deadline, result.views.count < limits.views, actionCount < limits.actions else { throw CollectorError.limitReached }
        }
        func candidates(_ intent: ReadIntent) -> [ReadControl] { controls(tree).filter { allowed($0, intent, projectURL: projectURL) } }
        func refresh() throws {
            try check()
            let next = try driver.readTree()
            guard let document = projectDocument(next), canonicalSourceURL(document.url) == projectURL, route(document.url) == kind else { throw CollectorError.sourceChanged }
            tree = next
        }
        @discardableResult func record(_ scope: String) throws -> Bool {
            try check()
            guard let snapshot = try? parse(tree, profileID: result.profileID, profileLabel: profileLabel) else { return false }
            // Deduplicate entire identical views only. Repeated messages inside a view remain untouched.
            let key = scope + "\u{0}" + snapshot.documentURL + "\u{0}" + snapshot.text
            guard seenViews.insert(key).inserted else { return false }
            let view = ProjectView(scope: scope, snapshot: snapshot)
            if snapshot.sections.contains(where: { $0.label.contains("identity unverified") }) {
                issue("Several conversation streams are visible together. Their ordered text is preserved separately, but coordinator/thread identity is not inferred from their identical accessibility labels.")
            }
            result.views.append(view); progress(view)
            for control in controls(tree) where control.role == "AXLink" {
                guard let raw = control.url, let url = safeReferenceURL(raw), !control.label.isEmpty else { continue }
                inventory(kind: "reference", label: control.label, url: url)
            }
            return true
        }
        func inventory(kind: String, label: String, url: String? = nil, capturedURL: String? = nil, captured: Bool = false) {
            if let index = result.inventory.firstIndex(where: { $0.kind == kind && $0.label == label && $0.sourceURL == url }) {
                if captured { result.inventory[index].captured = true; result.inventory[index].capturedURL = capturedURL }
            } else { result.inventory.append(InventoryItem(kind: kind, label: label, sourceURL: url, capturedURL: capturedURL, captured: captured)) }
        }
        @discardableResult func act(_ intent: ReadIntent, control: ReadControl? = nil) async throws -> Bool {
            try check()
            let choices = candidates(intent)
            let choice: ReadControl
            if let control {
                guard choices.contains(control) else { throw CollectorError.staleControl }; choice = control
            } else {
                guard choices.count == 1, let first = choices.first else {
                    if choices.count > 1 { issue("Ambiguous read-only control for \(intent.rawValue); this view was not navigated.") }
                    return false
                }
                choice = first
            }
            actionCount += 1
            guard try driver.perform(ReadAction(intent: intent, control: choice), expectedTree: tree) else {
                issue("Claude did not expose a supported read-only action for \(choice.label.isEmpty ? intent.rawValue : choice.label).")
                return false
            }
            try await driver.settle(); try refresh()
            return true
        }
        func run() async -> ProjectCapture {
            do {
                if kind == .coworkConversation {
                    _ = try record("Initial Cowork conversation view")
                    try await transcript(scope: "Cowork conversation")
                } else {
                    _ = try record("Initial Project view")
                    try await settings()
                    try await threads()
                    try await library()
                    if try await act(.routinesTab) { _ = try record("Routines inventory — configuration only") }
                }
            } catch is CancellationError {
                result.cancelled = true; issue("Capture was cancelled. All views read before cancellation are retained.")
            } catch { issue(error.localizedDescription) }
            if result.views.isEmpty { issue("Claude exposed no recognized conversation or Project context in the visited views.") }
            return result
        }
        func settings() async throws {
            if !descendants(tree).contains(where: { normalizedLabel($0) == "project settings" && $0.role != "AXButton" }) {
                guard try await act(.settings) else { issue("Project settings could not be opened; goal, instructions and memory remain unverified."); return }
            }
            _ = try record("Project settings / initially visible context")
            if try await act(.settingsGeneral) { _ = try record("Project settings / General") }
            if try await act(.settingsMemory) {
                _ = try record("Project settings / Memory instructions")
                while let open = candidates(.memoryFile).first(where: { !visitedMemory.contains($0.label) }) {
                    let label = open.label
                    visitedMemory.insert(label); inventory(kind: "memory", label: String(label.dropFirst(5)))
                    guard try await act(.memoryFile, control: open) else { continue }
                    let read = try record("Project memory / \(String(label.dropFirst(5)))")
                    inventory(kind: "memory", label: String(label.dropFirst(5)), capturedURL: projectDocument(tree)?.url, captured: read)
                    guard try await act(.memoryBack) else {
                        issue("The memory-file back control was unavailable; remaining memory files were not visited."); break
                    }
                }
            } else { issue("Project Memory tab could not be opened; instructions and memory remain unverified.") }
            guard try await act(.closeSettings) else { throw CollectorError.staleControl }
            _ = try record("Coordinator after Project settings")
        }
        func showThreads() async throws -> Bool {
            if candidates(.threadBack).count == 1 { _ = try await act(.threadBack) }
            if candidates(.threadsTab).isEmpty, let overview = candidates(.overview).first, overview.selected != true {
                _ = try await act(.overview, control: overview)
            }
            if let tab = candidates(.threadsTab).first, tab.selected != true { _ = try await act(.threadsTab, control: tab) }
            return !candidates(.threadGroup).isEmpty || !candidates(.threadLink).isEmpty
        }
        func threadInventory() async throws -> [ReadControl] {
            var expanded = Set<String>(), links: [ReadControl] = []
            func remember() {
                for link in candidates(.threadLink) where !links.contains(where: { $0.url == link.url }) { links.append(link) }
            }
            remember()
            while let group = candidates(.threadGroup).first(where: { $0.expanded != true && !expanded.contains($0.label) }) {
                expanded.insert(group.label)
                let before = candidates(.threadLink).count
                _ = try await act(.threadGroup, control: group)
                remember()
                _ = try record("Threads inventory / \(group.label)")
                // Some builds omit AXExpanded. If pressing hid links, restore the already-open group.
                if group.expanded == nil, candidates(.threadLink).count < before,
                   let restore = candidates(.threadGroup).first(where: { $0.label == group.label }) {
                    _ = try await act(.threadGroup, control: restore); remember()
                }
            }
            for link in links { inventory(kind: "thread", label: link.label, url: link.url) }
            let count = candidates(.threadGroup).compactMap { Int($0.label.split(separator: " ").last ?? "") }.reduce(0, +)
            if count > Set(links.compactMap(\.url)).count {
                issue("Thread groups report \(count) threads, but only \(Set(links.compactMap(\.url)).count) unique links are visible. Additional threads may be paginated or hidden.")
            }
            return links
        }
        func threads() async throws {
            guard try await showThreads() else { issue("The Project thread list could not be opened; other branches remain unverified."); return }
            let links = try await threadInventory()
            _ = try record("Coordinator and expanded thread inventory")
            try await transcript(scope: "Coordinator")
            for link in links {
                guard let url = link.url, visitedThreads.insert(url).inserted else { continue }
                guard try await showThreads() else { issue("Could not return to the thread list."); break }
                _ = try await threadInventory()
                guard let current = candidates(.threadLink).first(where: { $0.url == url }) else { issue("Thread link disappeared before capture: \(link.label)."); continue }
                guard try await act(.threadLink, control: current) else { continue }
                // Keep both the observed cmsg link and the resolved session URL, without guessing identity.
                let read = try record("Thread / \(link.label)")
                inventory(kind: "thread", label: link.label, url: url, capturedURL: projectDocument(tree)?.url, captured: read)
                try await transcript(scope: "Thread / \(link.label)")
            }
            _ = try await showThreads()
        }
        func expandDetails(scope: String, expanded: inout Set<String>) async throws {
            for _ in 0..<min(30, limits.actions) {
                guard let control = candidates(.toolDetails).first(where: { !expanded.contains($0.label + $0.path.description) }) else { break }
                expanded.insert(control.label + control.path.description)
                guard try await act(.toolDetails, control: control) else { continue }
                _ = try record(scope + " / expanded tool details")
            }
        }
        func transcript(scope: String) async throws {
            var expanded = Set<String>()
            try await expandDetails(scope: scope, expanded: &expanded)
            for _ in 0..<limits.scrollsPerConversation {
                guard let pagination = candidates(.pagination).first else { break }
                let old = tree
                guard try await act(.pagination, control: pagination) else { break }
                _ = try record(scope + " / additional messages")
                try await expandDetails(scope: scope, expanded: &expanded)
                if old == tree { issue("More-history control did not expose new content for \(scope)."); break }
            }
            for direction in [ReadIntent.scrollUp, .scrollDown] {
                for _ in 0..<limits.scrollsPerConversation {
                    let targets = candidates(direction)
                    guard targets.count == 1, let area = targets.first else {
                        if !targets.isEmpty { issue("Multiple transcript scroll areas in \(scope) are ambiguous; those areas were not scrolled.") }
                        break
                    }
                    let old = tree
                    guard try await act(direction, control: area) else { break }
                    _ = try record(scope + " / " + direction.rawValue)
                    try await expandDetails(scope: scope, expanded: &expanded)
                    if old == tree { break }
                }
            }
            if candidates(.scrollUp).isEmpty && candidates(.scrollDown).isEmpty {
                issue("No supported AX page-scroll action was exposed for \(scope); off-screen/virtualized messages remain unverified.")
            }
        }
        func library() async throws {
            guard try await act(.libraryTab) else { issue("The Library tab could not be opened; its contents remain unverified."); return }
            try await libraryFolder(path: "Library", depth: 0)
        }
        func libraryFolder(path: String, depth: Int) async throws {
            var folderNames: [String] = []
            for page in 0..<limits.views {
                _ = try record(path + " inventory / page \(page + 1)")
                for row in controls(tree) where row.role == "AXRow" && row.ancestors.map({ $0.lowercased() }).contains("library") {
                    inventory(kind: "library", label: path + "/" + row.label, url: row.url)
                }
                for folder in candidates(.libraryFolder) where !folderNames.contains(folder.label) { folderNames.append(folder.label) }
                guard let more = candidates(.pagination).first else { break }
                let before = tree
                guard try await act(.pagination, control: more) else { break }
                if before == tree { issue("Library pagination did not expose new rows at \(path)."); break }
            }
            guard depth < 8 else { issue("Library nesting limit reached at \(path)."); return }
            for label in folderNames {
                guard let folder = candidates(.libraryFolder).first(where: { $0.label == label }) else {
                    issue("Library folder \(label) is no longer visible after pagination; its children remain unverified."); continue
                }
                let previous = tree
                guard try await act(.libraryFolder, control: folder) else { continue }
                guard previous != tree else { issue("Library folder \(label) did not open via its available AX action."); continue }
                try await libraryFolder(path: path + "/" + label, depth: depth + 1)
                guard try await act(.libraryBack) else { issue("Library parent control is missing; remaining folders were not visited."); return }
            }
        }
    }
}
