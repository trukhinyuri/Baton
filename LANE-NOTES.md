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

## W4: lineage merge

- `SessionSync.liveSessionIDs: Set<String>?` — `nil` reads `LiveSessions.ids(claudeDir: paths.claudeDir)`, only when
  a copy would change its `cliSessionId`. Lane B may pass the set it already computed.
- `Report.keptLive` — copies left alone because their session is open in a running `claude` process.

## W5: archive merge

- `archive-baselines.json` in the state directory (version 1): per window pair, the archived list as last synced.
  An id missing from a window's list since then was unarchived there and stays unarchived everywhere.

## W6: account email

- `DesktopData.email(in:accountID:)` now parses the IndexedDB LevelDB records first (Snappy tables included), then
  falls back to the byte scan. Signature unchanged.

## W7: durability (for lane B; also affects SettingsSync and InterfaceSync)

- `Backup.save(_:)` for an overwrite: after the first copy of the day, each new content of a regular file goes to
  `Backups/<day>/.versions/<sha256>`, stored once whichever file it came from, with a line in `.versions/index.jsonl`
  (`at`, `path`, `sha256`). Folders keep the old behaviour (first copy of the day only). `prune()` moves a day's
  `.versions` to the Trash once the day is two calendar days old; whole days still go after 7.
- Tombstones: with `propagateDeletions` and not `dryRun`, a `deleted_*` marker that every pair has, with no card left
  anywhere and the newest copy older than 90 days, is backed up and removed from every pair
  (`Report.tombstonesExpired`, counted in `changes`). Lane B must pass `propagateDeletions: true` only when every
  target window is closed, as today.
- `LevelDBStore.writeAtomically` re-checks `isInUse` right before the rename and throws
  `LocalStorageError.databaseInUse` (temp file removed) if a window opened the database meanwhile. `willRename` is a
  test hook; production leaves it nil.
