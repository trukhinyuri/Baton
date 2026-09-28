# Lane A notes for other lanes

## W2: folder rules gate SessionSync (for lane B, ProfileManager; lane C, CLI)

`SessionSync` gained settable properties; `init(paths:dataDirs:)` and `run(propagateDeletions:now:)` are unchanged.

- `public var isWindowOpen: (@Sendable (URL) -> Bool)?` — given a data directory, whether its window is open.
  `nil` (today's callers) means every window counts as open unless `propagateDeletions` is true. Copies that a
  folder rule no longer allows are retired only from closed windows, so with `nil` they are retired only when no
  Claude Desktop runs. Lane B: pass `{ dataDir in <window of dataDir is open> }` from `ProfileManager`
  (`isWindowOpen(_:)` already answers this per window id) in `syncSessions()` and `prepareSessionsForLaunch()`.
- `public var email: @Sendable (URL, String) -> String?` — (data directory, account UUID) → email. Defaults to
  `DesktopData.email(in:accountID:)`. Lane B may pass its cached `email(in:accountID:)`.
- `public var dryRun = false` — counts what a run would do and writes nothing. Lane C: `sync --dry-run` sets it on
  the `SessionSync` it runs.
- `Report.withheldByRule`, `Report.retiredByRule` — new counts; `retiredByRule` is part of `changes`.
- An unreadable `folder-rules.json` makes `run` throw `ProfileError.rulesUnreadable` before anything is written.
  `folder-rules.json` stays version 1.

## W3: account-scoped fields in cross-account copies (for lane B, Profile and ProfileManager)

- The per-profile opt-in is read from the profile registry (`Paths.registryFile`) as a Bool member
  `carryPermissionMode` of each profile object. Lane B: add `public var carryPermissionMode: Bool?` to `Profile`
  (Codable key `carryPermissionMode`, `nil` = off), and set it ON for the owner's profiles (the owner uses bypass).
  `SessionSync` decodes the registry as raw JSON, so it works before and after that field exists.
- The main window has no `Profile`. If main needs the opt-in, pass
  `public var carriesPermissionMode: (@Sendable (URL) -> Bool)?` on `SessionSync` (data directory → keep
  `permissionMode`); when set it replaces the registry lookup for every window.
- Dropped in a copy for another account: `bridgeSessionIds`, `remoteControl*`, `peerReceipts`,
  `remoteMcpServersConfig`, `chromePermissionMode`, `cuGrantFlags`, `permissionMode` (unless kept), and
  `enabledMcpTools` entries that are not `local:` (local stdio) tools. A window keeps its own value of each of
  these: a value that differs from the incoming card's was set there. Same-account copies are byte-exact.
- Not dropped (the plan did not list them; decide for 1.1): `cuAllowedApps`, `alwaysAllowedReasons`,
  `sessionPermissionUpdates`, `bypassChosenInApp`, `autoChosenInApp`, `steeredByRemoteClient`.
- Copies spread by earlier releases are identical in every window. The first-written file (earliest creation
  date) is taken as the original; when dates tie, the first data directory in `dataDirs` (main) is.
