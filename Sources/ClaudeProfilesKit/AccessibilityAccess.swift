import AppKit
@preconcurrency import ApplicationServices
import Foundation
import Security

/// Permission UX for explicitly requested native window capture. Merely constructing or refreshing
/// this controller never prompts, reads another app, changes TCC, or asks for unrelated permissions.
public enum AccessibilityAccess {
    public enum Status: String, Equatable, Sendable {
        case unknown, notGranted, waitingForApproval, granted, notApplied
    }
    public struct State: Equatable, Sendable {
        public var status: Status = .unknown
        public var requested = false
        public var settingsOpenFailed = false
        public var canCapture: Bool { status == .granted }
        public init() {}
    }
    public struct Application: Equatable, Sendable {
        public var name: String
        public var url: URL
        /// nil means the signature could not be classified; it does not establish a stable identity.
        public var isAdHocSigned: Bool?
        public init(name: String, url: URL, isAdHocSigned: Bool? = nil) {
            self.name = name; self.url = url; self.isAdHocSigned = isAdHocSigned
        }
    }

    public static func settingsPaneName(macOSMajorVersion: Int) -> String {
        macOSMajorVersion >= 27 ? "Device Control and Data Access" : "Accessibility"
    }

    @MainActor
    struct Client {
        var check: () -> Bool
        var request: () -> Bool
        var openSettings: () -> Bool
        var revealApplication: (URL) -> Void
        var application: Application

        static var live: Client {
            let bundle = Bundle.main, url = bundle.bundleURL
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Claude Profiles"
            return Client(check: { AXIsProcessTrusted() }, request: {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                // Apple's prompt is asynchronous: false means access is not currently granted,
                // not that the user denied the prompt, and never means the request itself failed.
                return AXIsProcessTrustedWithOptions(options)
            }, openSettings: {
                // This pane URL is best effort across OS versions; launching Settings is the fallback.
                let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                if NSWorkspace.shared.open(pane) { return true }
                return NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
            }, revealApplication: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
                          application: Application(name: name, url: url, isAdHocSigned: signatureIsAdHoc(at: url)))
        }
    }

    @MainActor
    public final class Controller {
        private let client: Client
        public let application: Application
        public private(set) var state = State()
        public var settingsPaneName: String {
            AccessibilityAccess.settingsPaneName(macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        }

        public convenience init() { self.init(client: .live) }
        init(client: Client) { self.client = client; application = client.application }

        /// Safe on sheet appearance, return from Settings, and a bounded status refresh loop.
        @discardableResult public func refresh() -> State {
            if client.check() { state.status = .granted }
            else if state.status != .notApplied { state.status = state.requested ? .waitingForApproval : .notGranted }
            return state
        }

        /// Call only from the explicit Request access button, never from launch, refresh or retry.
        @discardableResult public func requestAccess() -> State {
            if client.check() { state.status = .granted; return state }
            state.requested = true; state.settingsOpenFailed = false
            state.status = client.request() ? .granted : .waitingForApproval
            return state
        }

        /// The user explicitly says they changed Settings; do not infer a grant from that gesture.
        @discardableResult public func checkAfterSettingsChange() -> State {
            state.status = client.check() ? .granted : .notApplied
            return state
        }

        /// A capture failure is evidence that the running copy could not use access, even if the
        /// Settings switch appears on. A later successful status check is required before retry.
        @discardableResult public func recordCaptureDenied() -> State {
            state.status = .notApplied
            return state
        }

        @discardableResult public func openSystemSettings() -> State {
            state.settingsOpenFailed = !client.openSettings()
            return state
        }
        public func revealThisApplication() {
            guard application.url.isFileURL, application.url.pathExtension == "app" else { return }
            client.revealApplication(application.url)
        }
        /// Cancels this app's waiting UI, not a system dialog or an existing OS grant.
        @discardableResult public func cancelWaiting() -> State {
            state.requested = false
            if state.status != .granted { state.status = .notGranted }
            return state
        }
    }

    private static func signatureIsAdHoc(at url: URL) -> Bool? {
        guard url.isFileURL, url.pathExtension == "app" else { return nil }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(rawValue: 0), &code) == errSecSuccess,
              let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let flags = dict[kSecCodeInfoFlags as String] as? NSNumber else { return nil }
        return SecCodeSignatureFlags(rawValue: flags.uint32Value).contains(.adhoc)
    }
}
