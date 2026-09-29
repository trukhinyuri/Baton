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
                    // Baton's own version, with a suffix such as -rc.1, and its commit: AppKit would show
                    // CFBundleShortVersionString and CFBundleVersion, which hold only the numbers.
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: About.credits, .applicationVersion: BuildInfo.current.version, .version: BuildInfo.current.commit,
                    ])
                    NSApp.activate()
                }
            }
            // Each command that shows a sheet opens the window first: with it closed, the sheet would wait unseen.
            CommandGroup(replacing: .newItem) {
                Button("Add Subscription…") {
                    model.bringWindowForward()
                    model.isAdding = true
                }
                .keyboardShortcut("n")
            }
            CommandGroup(after: .newItem) {
                Button("Share Sessions Now") { model.syncNow(asked: true) }.keyboardShortcut("r")
                Button("Continue work…") {
                    model.bringWindowForward()
                    model.isContinuing = true
                }
                Button("Check sessions…") {
                    model.bringWindowForward()
                    model.checkSessions()
                }
            }
            CommandGroup(replacing: .help) {
                Button("Report a problem…") {
                    model.bringWindowForward()
                    model.isReporting = true
                }
            }
        }

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(model: model)
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

/// The menu bar icon. It is there from launch, with the window open or not, so errors can open the window from the start:
/// Baton may start with its window closed and meet an error before any item or the window sets that up.
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: About.menuBarSymbol)
            .accessibilityLabel("Baton")
            .onAppear { model.letErrorsOpenTheWindow(with: openWindow) }
    }
}

struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(model.statuses) { status in
            Button(menuTitle(for: status)) {
                model.letErrorsOpenTheWindow(with: openWindow)
                model.open(status)
            }
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
        Button("Share Sessions Now") {
            model.letErrorsOpenTheWindow(with: openWindow)
            model.syncNow(asked: true)
        }
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
            usage = " · " + LimitText.describe(status.limits.week, fullNames: true)
        }
        // Open or closed in words, as in the window list: VoiceOver reads a dot glyph as "black circle".
        return "\(name) · \(status.isRunning ? "Open" : "Closed") — \(who)\(usage)"
    }
}
