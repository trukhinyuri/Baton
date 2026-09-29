import BatonKit
import SwiftUI

@main
struct BatonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    init() {
        // First, before the model starts anything: Claude or Anthropic settings from whatever started Baton (a
        // terminal, a Claude Code session) must not reach the Claude windows it opens.
        InheritedEnvironment.scrub()
    }

    var body: some Scene {
        Window("Baton", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 900, height: 560)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Baton") {
                    NSApp.orderFrontStandardAboutPanel(options: [.credits: About.credits])
                    NSApp.activate()
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Subscription…") { model.isAdding = true }.keyboardShortcut("n")
            }
            CommandGroup(after: .newItem) {
                Button("Share Sessions Now") { model.syncNow() }.keyboardShortcut("r")
                Button("Continue work…") { model.isContinuing = true }
                Button("Check sessions…") { model.checkSessions() }
            }
            CommandGroup(replacing: .help) {
                Button("Report a problem…") { model.isReporting = true }
            }
        }

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(systemName: About.menuBarSymbol)
                .accessibilityLabel("Baton")
        }
    }
}

/// What the About box and the menu bar show.
enum About {
    /// A runner with the baton; the stack of windows where this macOS can't draw it.
    static let menuBarSymbol =
        NSImage(systemSymbolName: "figure.run", accessibilityDescription: nil) != nil ? "figure.run" : "square.stack.3d.up.fill"

    /// The About box credits, in the panel's own small, centered, theme-aware text.
    static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(
            string: "Baton, formerly Claude Profiles. Built by Yuri Trukhin for his own relay of Claude windows. Not affiliated with Anthropic.",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ])
    }
}

/// Keeps session sharing running in the menu bar after the window is closed.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(model.statuses) { status in
            Button(menuTitle(for: status)) { model.open(status) }
        }
        Divider()
        Button("Open Baton") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Add Subscription…") {
            openWindow(id: "main")
            NSApp.activate()
            model.isAdding = true
        }
        Button("Share Sessions Now") { model.syncNow() }
        Button("Continue work…") {
            openWindow(id: "main")
            NSApp.activate()
            model.isContinuing = true
        }
        Button("Report a problem…") {
            openWindow(id: "main")
            NSApp.activate()
            model.isReporting = true
        }
        Divider()
        Button("Quit Baton") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func menuTitle(for status: ProfileStatus) -> String {
        let name = "Claude \(status.displayLabel)"
        let who = status.email ?? (status.isSignedIn ? "signed in" : "not signed in")
        var usage = ""
        if status.isSignedIn, status.limits.isAtLimit() {
            usage = " · " + LimitText.atLimit(status.limits)
        } else if status.isSignedIn, status.usage != nil {
            usage = " · " + LimitText.describe(status.limits.week)
        }
        // Open or closed in words, as in the window list: VoiceOver reads a dot glyph as "black circle".
        return "\(name) · \(status.isRunning ? "Open" : "Closed") — \(who)\(usage)"
    }
}
