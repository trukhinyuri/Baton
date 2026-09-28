# Lane B notes for lane C (CLI `main.swift`, app views) and integration

Branch `lane/b`, base a9e512b. Commits: W8 193a1cf, W10 dab82bf, W11 14ebbea, W12 62f6522, W13 2cb8a64.
Everything below is in `ClaudeProfilesKit`; nothing here is wired into the CLI or the app yet.

## Must wire, or behaviour regresses

1. **`--same --anyway` and "Continue Anyway" (W13).** The two-writer check now lives in the kit.
   `plan(...)`, `continueAll(...)` and `continueConversation(...)` throw `ProfileError.mayStillBeWritten([String])`
   (conversation titles) when a session that continues as the same session may still be written to in its window.
   - CLI: pass `anyway: args.contains("--anyway")` to both `manager.plan(...)` (the `--dry-run` path) and
     `manager.continueAll(...)`. `refuseRunning` in main.swift can then go; its message now comes from the kit.
   - App, ContinueWorkSheet: the "Continue Anyway" path must call `continueAll(..., anyway: true)` /
     `continueConversation(..., anyway: true)`. Catch `.mayStillBeWritten` to show that button.
   - Signatures:
     ```swift
     public func plan(_ conversations: [Conversation], in destination: String, mode: ContinueMode = .auto,
                      newSessionIn folder: String? = nil, anyway: Bool = false, now: Date = Date()) throws -> [ContinuePlan]
     public func continueAll(_ conversations: [Conversation], in destination: String, mode: ContinueMode = .auto,
                             newSessionIn folder: String? = nil, anyway: Bool = false, now: Date = Date()) async throws -> [ContinuePlan]
     public func continueConversation(_ conversation: Conversation, in destination: String,
                                      mode: ContinueMode = .auto, anyway: Bool = false) async throws -> ContinueResult
     public static func refuseSecondWriter(_ plans: [ContinuePlan], now: Date = Date()) throws   // ProfileManager
     ```
2. **Removing a profile (W13).** `remove(_:)` no longer quits or force-quits. While the profile's app copy runs it
   throws `ProfileError.profileOpen(label)` ("Claude WORK is open. Quit it first (⌘Q in that window), then remove the
   profile. Nothing was removed."). The app's confirm dialog and `claude-profiles remove` must stop saying the
   window will be quit, and show this error as is.
3. **Start-up checks (W12).** Call once at app launch and at every CLI start (before the command runs), print or show
   each string as a warning; never block on them:
   ```swift
   public func startUpChecks() -> [String]          // ProfileManager
   ```
   It re-registers the main Claude with `lsregister -f` when no sign-in is in progress (or one was abandoned
   for over 15 minutes), reports an `lsregister` failure with its exit code, and adds the version warning.

## Local only (W10)

```swift
public var localOnly: LocalOnly { get }                                                   // ProfileManager
public func localOnlyStatus() -> [(window: String, label: String, status: LocalOnly.Status)]  // ProfileManager, MAIN first
@discardableResult
public func setLocalOnly(_ enabled: Bool, window: String?) throws -> [String: LocalOnly.Status] // ProfileManager
public enum LocalOnly.Status: String { case on, off, pending, notSupported = "not-supported" }
public static func LocalOnly.missingKeys(in claudeApp: URL) -> [String]?   // nil: Claude.app unreadable
public func LocalOnly.isEnabled(window: String) -> Bool
```

- CLI `claude-profiles local-only on|off [PROFILE|main]` → `try manager.setLocalOnly(true|false, window: id)`; no id →
  `window: nil` (every window without its own choice). Print one line per returned window:
  `"\(manager.label(of: id)): \(status.rawValue)"`. `setLocalOnly` throws `ProfileError.notFound` for an unknown id.
- CLI `claude-profiles local-only status [--json]` → `manager.localOnlyStatus()`; JSON:
  `[{"window": id, "label": label, "status": status.rawValue}]`.
- Wording for each status (app badge next to each window and CLI):
  - `on`: "Local only: Remote Control off for new sessions"
  - `off`: "Local only off"
  - `pending`: "Local only applies when this window next starts" (window is open, or its settings drifted)
  - `not-supported`: "Local only not available in this Claude Desktop version"
- `doctor` line: `LocalOnly.missingKeys(in: manager.paths.claudeApp)`: nil → "Claude.app unreadable: Local only can't check
  its settings"; `[]` → "Local only keys present: ccRemoteControlDefaultEnabled, remoteControlStayReachable"; otherwise
  "missing in this Claude Desktop: <keys>".
- Already wired in the kit: `open(_:links:)` and `openMain(links:)` call `localOnly.reconcile(window:)` inside
  `open.lock`, after SettingsSync and InterfaceSync, so it happens at every cold start. A failure lands in
  `lastOpenWarning` as "Local only: …".
- Writes only `ccRemoteControlDefaultEnabled` (added if missing) and `remoteControlStayReachable` (only where
  Claude already wrote it) in `<data dir>/claude_desktop_config.json` → `preferences`; state in
  `~/Library/Application Support/Claude Profiles/local-only.json`, backups in `Backups/<date>/`.

## Doctor lines (W12)

```swift
public static func Paths.findClaude(home: URL, systemApplications: URL = /Applications, lookup: (String) -> [URL]) -> URL
public enum ClaudeVersion {
    public static let bundleIdentifier: String               // "com.anthropic.claudefordesktop"
    public static let tested: ClosedRange<ClaudeVersion.Version>   // "2.9939.2"..."2.9939.2"
    public static func installed(at app: URL) -> String?     // CFBundleShortVersionString
    public static func warning(for version: String?) -> String?   // nil inside the tested range
}
public var claudeVersionWarning: String? { get }             // ProfileManager
```

- `doctor`: "Claude Desktop: \(manager.paths.claudeApp.path), version \(ClaudeVersion.installed(at:) ?? "unknown")
  (tested \(ClaudeVersion.tested.lowerBound)–\(ClaudeVersion.tested.upperBound))", then `claudeVersionWarning` if any.
- App: show `claudeVersionWarning` as a one-line banner in the window list.
- `Paths.standard` now finds Claude through Launch Services, then /Applications, then ~/Applications, skipping
  profile engines and launchers.

## Continue sheet (W8, W11)

```swift
public var ContinuePlan.wontFollow: [Continuation.WontFollowItem]    // filled by plan()
public struct Continuation.WontFollowItem { kind: Kind; detail: String; names: [String] }
public enum Kind: String { case remoteConnectors, remoteControlBridge, accountBoundWorker, scheduledTasks, rewindLimit }
public static func Continuation.wontFollow(card: URL, target: URL, paths: Paths) -> [WontFollowItem]
public var ContinuePlan.carried: TranscriptFork.Report?   // after prepare(): scratchCopied, leftBehind, worktrees
```

- Sheet, before the Continue button: a "Won't come along" list, one row per item: `detail`, plus
  `names.joined(separator: ", ")` when not empty. CLI `continue`/`continue-all --dry-run`: print each as
  `"      stays behind: \(detail)\(names.isEmpty ? "" : " (\(names.joined(separator: ", ")))")"` under its plan line.
- After a copy: when `plan.carried?.leftBehind` or `.worktrees` is not empty, one line
  "Left in the original scratchpad: <leftBehind…>; git worktrees (not copied): <worktrees…>".

## Profile

- `Profile.carryPermissionMode: Bool?` (Codable key `carryPermissionMode`, missing = off), `Profile.carriesPermissionMode`
  (nil read as off), and `Profile(id:label:email:color:createdAt:carryPermissionMode:)`. Lane A's SessionSync already
  reads this key from `profiles.json`. At W25, set it on for the owner's profiles.
- App: a per-profile checkbox "Keep the permission mode when continuing here". No CLI command is needed for 1.0.

## Integration notes

- Lane A's `SessionSync.isWindowOpen`, `carriesPermissionMode`, `email`, `dryRun` and `liveSessionIDs` are not on the
  lane B base. At merge, set `isWindowOpen` in `ProfileManager.syncSessions()` and `prepareSessionsForLaunch()` to
  `{ dataDir in windows.first { $0.dataDir == dataDir }.map { isWindowOpen($0.id) } ?? true }`.
- Not done: the optional `permissions.deny` for `move_to_cloud` (§4).
