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
