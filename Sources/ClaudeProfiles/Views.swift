import ClaudeProfilesKit
import SwiftUI

extension Color {
    init(hex: String) { self.init(nsColor: NSColor(hex: hex)) }
}

struct ProfileBadge: View {
    let label: String
    let color: String
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(Color(hex: color).gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(label)
                    .font(.system(size: size * 0.3, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .padding(.horizontal, size * 0.1)
            }
            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
    }
}

struct UsageMeter: View {
    let title: String
    let percent: Int?
    var isStale = false

    private var tint: Color {
        guard let percent, !isStale else { return .secondary }
        return percent >= 90 ? .red : percent >= 70 ? .orange : .green
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(minWidth: 48, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(tint)
                        .frame(width: isStale ? 0 : proxy.size.width * CGFloat(min(percent ?? 0, 100)) / 100)
                }
            }
            .frame(height: 5)
            Text(isStale ? "reset" : percent.map { "\($0)%" } ?? "–")
                .monospacedDigit()
                .foregroundStyle(isStale ? .secondary : .primary)
                .frame(minWidth: 36, alignment: .trailing)
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) usage")
        .accessibilityValue(isStale ? "reset" : percent.map { "\($0) percent" } ?? "unknown")
    }
}

struct UsageColumn: View {
    let status: ProfileStatus

    var body: some View {
        if let usage = status.usage, status.isSignedIn {
            VStack(alignment: .leading, spacing: 5) {
                UsageMeter(title: "5-hour", percent: usage.fiveHour, isStale: usage.isFiveHourStale())
                UsageMeter(title: "Weekly", percent: usage.week)
                (Text("Updated \(usage.sampledAt, format: .relative(presentation: .named))") + Text(usage.isFresh() ? "" : " · may be higher now"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 56)
                    .help(usage.isFresh() ? "" : "Claude records usage only while this window is open and in use, so this sample can be behind.")
            }
        } else {
            Text(status.isSignedIn ? "Usage appears after the first message" : "Usage appears after sign-in")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ProfileRow: View {
    let status: ProfileStatus
    let isSuggested: Bool
    @ObservedObject var model: AppModel

    private var title: String {
        status.email ?? status.profile?.email ?? (status.isSignedIn ? "Signed in" : "Not signed in")
    }

    private var subtitle: String {
        (status.isMain ? "Main Claude app" : "Claude \(status.label)") + (status.isRunning ? " · Open" : " · Closed")
    }

    var body: some View {
        HStack(spacing: 14) {
            ProfileBadge(label: status.label, color: status.color)
                .accessibilityLabel("Dock label \(status.label)")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if isSuggested {
                        Text("Most headroom")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.18)))
                            .foregroundStyle(.green)
                            .help("Lowest weekly usage among your signed-in subscriptions with usage recorded in the last 3 hours")
                    }
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(status.isRunning ? Color.green : Color.secondary.opacity(0.35))
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !status.isSignedIn {
                    Label("Sign in inside the Claude \(status.label) window", systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.orange)
                        .help("While this window signs in, sign-in links from your browser open here instead of in the main Claude app.")
                } else if status.isUnexpectedAccount, let expected = status.profile?.email {
                    Label("Signed in as a different account than \(expected)", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if status.isOpenWithoutProfile {
                    Label(
                        "A Claude \(status.label) window shows the main account — click \(status.isRunning ? "Show" : "Open") to replace it",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption).foregroundStyle(.orange)
                    .help("This app copy was opened without the profile, from its own Dock icon or by macOS at login. Keep the launcher in the Dock instead.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            UsageColumn(status: status)
                .frame(minWidth: 180, idealWidth: 210, maxWidth: 240)

            HStack(spacing: 4) {
                Button(status.isRunning ? "Show" : "Open") { model.open(status) }
                    .frame(minWidth: 64)
                    .accessibilityLabel("\(status.isRunning ? "Show" : "Open") \(status.isMain ? "Claude" : "Claude \(status.label)")")
                Menu {
                    Button("Status…") { model.showStatus(of: status.id) }
                    Divider()
                    if let profile = status.profile {
                        Button("Show Launcher in Finder") { model.revealLauncher(status) }
                        Toggle(
                            "Keep the permission mode when continuing here",
                            isOn: Binding(
                                get: { profile.carriesPermissionMode },
                                set: { model.setCarryPermissionMode($0, for: profile.id) }
                            )
                        )
                        .help(
                            "A conversation continued into this profile keeps its permission mode (for example “accept edits”) instead of falling back to the default. Off unless you turn it on."
                        )
                        Divider()
                        Button("Remove Subscription…", role: .destructive) { model.pendingRemoval = status }
                    } else {
                        Text("The main Claude app can’t be removed")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More actions for \(status.isMain ? "Claude" : "Claude \(status.label)")")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

struct EmptyHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "plus.rectangle.on.rectangle")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
                .frame(minWidth: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Add your next subscription").font(.body.weight(.semibold))
                Text(
                    "Each one gets its own Claude window and a labeled Dock icon, so you always know which account you are in. Your Claude Code sessions show up in every window, so you can pick up any of them in whichever subscription you choose."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4])).foregroundStyle(.separator))
    }
}

struct LimitBanner: View {
    let tired: ProfileStatus
    /// The window to name on the button; `nil` for a plain “Continue work…”.
    let best: String?
    var note = ""
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.100percent").foregroundStyle(.orange).accessibilityHidden(true)
            Text("\(tired.isMain ? "Claude (main)" : "Claude \(tired.label)") has reached its usage limit.")
                .font(.callout.weight(.medium))
            Spacer()
            if !note.isEmpty { Text(note.trimmingCharacters(in: CharacterSet(charactersIn: " ·"))).font(.caption).foregroundStyle(.secondary) }
            Button(best.map { "Continue in \($0)…" } ?? "Continue work…", action: action)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            if let tired = model.limitReached, let best = model.bestDestination(excluding: tired.id) {
                // With folder rules, where work may continue depends on the work; the sheet offers only allowed windows.
                LimitBanner(
                    tired: tired, best: model.folderRules?.isEmpty == true ? model.label(of: best) : nil,
                    note: model.folderRules?.isEmpty == true ? model.staleNote(best) : ""
                ) { model.isContinuing = true }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.statuses) { status in
                        ProfileRow(status: status, isSuggested: status.id == model.suggestedID, model: model)
                    }
                    if model.statuses.count == 1 { EmptyHint() }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 380, idealHeight: 580)
        .sheet(isPresented: $model.isAdding) { AddProfileSheet(model: model) }
        .sheet(isPresented: $model.isContinuing) { ContinueWorkSheet(model: model) }
        .sheet(isPresented: $model.isCheckingSessions) { DiagnosticsSheet(entries: model.diagnostics) }
        .sheet(isPresented: $model.isReporting) { ReportSheet(model: model) }
        .sheet(isPresented: Binding(get: { model.statusWindow != nil }, set: { if !$0 { model.statusWindow = nil } })) {
            WindowStatusSheet(model: model)
        }
        .confirmationDialog(
            "Remove \(model.pendingRemoval.map { $0.email ?? "Claude \($0.label)" } ?? "")?",
            isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } }),
            presenting: model.pendingRemoval
        ) { status in
            Button("Remove", role: .destructive) { model.remove(status) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(
                "Its app copy and sign-in move to the Trash. While its window is open, removing it is refused: quit it first (⌘Q in that window). Ordinary local Code sessions stay available in other windows. Local Cowork data moves to the Trash with the profile; cloud Projects stay with their account."
            )
        }
        .alert(model.errorTitle, isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Subscriptions").font(.title2.weight(.semibold))
                Text("When one subscription reaches its limit, continue any local Code session or Cowork task in another.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Continue work…") { model.isContinuing = true }
            Button {
                model.isAdding = true
            } label: {
                Label("Add Subscription…", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("n")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let message = model.busyMessage {
                ProgressView().controlSize(.small)
                Text(message)
            } else if let notice = model.notice {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(notice).lineLimit(2)
            } else if let problem = model.registryError ?? model.syncError ?? model.setupWarning ?? model.installWarning {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(problem).lineLimit(2).textSelection(.enabled)
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
                if model.statuses.count < 2 {
                    Text("Local Code sessions will be shared when you add a subscription")
                } else if let last = model.lastSync {
                    Text("Local Code synced · \(last, format: .relative(presentation: .named))")
                } else {
                    Text("Sharing local Code sessions…")
                }
            }
            Spacer()
            Menu {
                Toggle(
                    "Also deny moving a session to the cloud",
                    isOn: Binding(
                        get: { model.cloudMoveLockOn },
                        set: { model.setCloudMoveLock($0) }))
            } label: {
                Label("Cloud move lock: \(model.cloudMoveLockOn ? "On" : "Off")", systemImage: "lock.shield")
            }
            .help("Optional, off by default: adds mcp__ccd_session__move_to_cloud to permissions.deny in ~/.claude/settings.json, Mac-wide.")
            Button("Check sessions…") { model.checkSessions() }
            Button("Report a problem…") { model.isReporting = true }
                .help("Shows a redacted report to review, then opens a prefilled GitHub issue. Nothing is sent automatically.")
            Link(destination: URL(string: "https://github.com/\(FeedbackReport.repository)#staying-within-anthropics-terms")!) {
                Label("Fair use", systemImage: "checkmark.shield")
            }
            .help("How Claude Profiles stays within Anthropic’s terms")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
    }
}

/// One window's account, sharing scope and why some work isn't shared, with a restart to apply pending changes.
struct WindowStatusSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var status: WindowStatus? { model.windowStatuses.first { $0.id == model.statusWindow } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let status {
                Text("\(status.isMain ? "Claude" : "Claude \(status.label)") status").font(.title2.bold())
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                    row("Window", status.isRunning ? "Open" : "Closed")
                    row("Account", status.account ?? "Not signed in")
                    row("Sharing scope", status.scope ?? "None until you sign in")
                    row("Scope from", status.scopeSource)
                    row("Local only", status.localOnly.map { $0 ? "On" : "Off" } ?? "Not available in this version")
                    row(
                        "Claude Code running", status.liveSessions == 0 ? "No sessions" : "\(status.liveSessions) session\(status.liveSessions == 1 ? "" : "s")"
                    )
                }
                section("Not shared, and why", status.skipReasons, empty: "Everything local is shared.")
                section("Waiting for a restart", status.pendingChanges, empty: "No changes waiting.")
            } else {
                ProgressView("Checking…")
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                if let status, !status.pendingChanges.isEmpty || status.isRunning {
                    Button(status.restartTitle) { model.restart(status.id) }
                        .disabled(!status.canRestart)
                        .help(status.restartHelp)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 360, idealHeight: 440)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }

    private func section(_ title: String, _ items: [String], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if items.isEmpty { Text(empty).foregroundStyle(.secondary) }
            ForEach(items, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
