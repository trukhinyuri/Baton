# Architecture

Claude Profiles is a thin layer around the official Claude Desktop app. It never changes how Claude talks to Anthropic; it only decides which data directory each Claude window uses and keeps a few local files consistent between them.

```text
                ┌──────────────────────── Claude Profiles.app ────────────────────────┐
                │  SwiftUI window · menu bar · claude-profiles CLI                    │
                │                 └───────── ClaudeProfilesKit ─────────┘             │
                └───────┬──────────────────────┬───────────────────────┬──────────────┘
          creates/opens │                reads │                 syncs │
                        ▼                      ▼                       ▼
   Claude <LABEL>.app launcher      config.json (account ID)    claude-code-sessions/
     └─ open -n engine clone        plan-usage-history.json       <account>/<org>/local_*.json
        --user-data-dir=<profile>   IndexedDB (account email)     deleted_*  archived-sessions.idx
```

## Profiles

A profile is three things, all derived from a registry entry in `~/Library/Application Support/Claude Profiles/profiles.json`:

1. **Engine.** An APFS clone of `/Applications/Claude.app` created with `clonefile(2)`, so it shares disk blocks with the original. The only change is a Finder custom icon, which adds an `Icon\r` file and a Finder flag to the bundle. No code or resource is modified and Anthropic’s signature still verifies with `codesign --verify` (the `--strict` check flags the extra icon file). Because the Dock shows a running app’s icon from its bundle path, each profile window gets its own labeled icon.
2. **Data directory.** Claude Desktop is an Electron app, and Electron keeps everything (cookies, sign-in, window state, caches) in the directory passed with `--user-data-dir`. Each profile gets its own, so each can be signed in to a different account at the same time.
3. **Launcher.** A tiny app bundle whose executable is a shell script calling `claude-profiles open <id>`, with a fallback to `open -n -a <engine> --args --user-data-dir=<dir>`. Launchers can be kept in the Dock and are indexed by Spotlight. An engine opened directly starts without its data directory and shows the main app's account: that happens when a running profile window is kept with **Keep in Dock** and its icon is clicked later, or when macOS reopens windows at login. See [Windows opened without their profile](#windows-opened-without-their-profile).

Engines are rebuilt when `CFBundleVersion` of the installed Claude differs from the clone’s and the profile isn’t running (`ProfileManager.refresh()` and on open).

`EngineInstall` builds a sibling staging bundle with `clonefile` or a copy fallback. It checks the source and staged bundle's version, identifier, executable and code signature before replacement. An existing engine is exchanged atomically with the stage using `renamex_np(RENAME_SWAP)` and kept until the installed copy passes the same checks; if it doesn't, the two are exchanged back, and if even that fails, the previous bundle is kept and its path reported. Only the installer's own staging bundle is ever removed.

## Windows opened without their profile

Every profile runs a copy with the same bundle identifier, so the bundle alone doesn't say which account a window shows. `RunningClaude` reads each copy's command line with `sysctl(KERN_PROCARGS2)`, as `ps` does, and takes `--user-data-dir` the way Chromium parses it (`--name=value` or `-name=value`, the last one wins, nothing after `--`). A copy without it uses the main app's data. A profile counts as open only when its engine runs with its own data directory, and `claude-profiles list` and the app flag a profile whose engine runs without it. If arguments can't be read, the bundle decides, as before.

The app watches `NSWorkspace.didLaunchApplicationNotification` and, at its own start, checks copies started in the last two minutes (macOS may reopen them at login before it). An engine started without its data directory is replaced only after a normal quit: `ProfileManager.open(_:)` asks it to quit and waits up to 10 seconds. It never force-quits that window, even if it just started, because Claude may already have restored active work. If the window refuses to quit, opening stops with an explanation and leaves the existing window running; otherwise the profile opens with its own data directory. Until it is replaced, it runs next to the main app on the main app's data. Without the app running, a Dock icon kept this way still opens the main account; the launcher always works.

## Signing in

Claude Desktop opens Google sign-in in the default browser, which returns the result through a `claude://` link. Launch Services delivers that link to the registered copy of Claude, and every profile runs a copy with the same bundle identifier, so without help the main app receives it and discards it as a sign-in it didn’t start.

`SignInRouting` fixes the destination rather than the link. Opening a profile that has no signed-in account unregisters the main app and the other app copies (`lsregister -u`) and registers that profile’s copy, and records this in `sign-in.json`. Each status refresh checks whether the profile is now signed in, has been waiting for more than 15 minutes, or never started; then the copies are unregistered and the main app is registered again. Claude Profiles never sees the link or anything in it. Email sign-in happens inside the window and needs none of this.

## Session sharing

Ordinary local Claude Code conversations are stored in `~/.claude/projects` and can be read by every profile. Their sidebar entries come from small index cards kept per account and organization. These cards are not the cloud Projects database:

```text
<data dir>/claude-code-sessions/<account-uuid>/<org-uuid>/
    local_<session>.json      one card per session
    deleted_<session>         tombstone for a deleted session
    archived-sessions.idx     {"v": 1, "archived": [...]}
```

`SessionSync` gathers these from every account/organization folder of every data directory. It first separates ordinary local conversations from account-owned workers, then synchronizes only eligible records:

- **Ordinary local cards.** The newest copy of each eligible card (by modification time) is written to every folder. The copy keeps the source’s modification time, so it never looks newer than the original.
- **Account-owned workers.** A non-null `remoteControlSpawn`, or a true top-level `projectThreadChild` or `rcChild`, identifies a native Project/Remote Control worker. If its observed and recorded copies have one account/organization scope, it is eligible only in folders of that exact scope. If copies exist across scopes, ownership is ambiguous: the sync leaves them byte-for-byte intact and excludes them from propagation. It reports the ambiguity instead of guessing which copy owns the cloud session. Deletion and archive state for workers is scoped the same way. This is a logical quarantine, not a file move or deletion.
- **"No folder" sessions.** A session started without a project folder runs in a scratch folder inside the data directory of the window that started it, and Claude lists it under "No folder" only if the card's `originCwd` is inside its own data directory; it offers side questions (`/btw`) only if `cwd` is that same path. So every other window gets a symbolic link at the same place in its own data directory, `scratch-workspaces/<account>/<organization>/<folder>`, pointing to the real folder, and its copy of the card names the link as both `cwd` and `originCwd`; the window that started the session keeps the real path. Claude Code resolves the link, so the conversation is filed under the real folder whichever window continues it, and Claude's own clean-up leaves the links alone (it sweeps only real folders of its own account, and deleting a session removes just the link). If the folder is gone or something else is at the link's place, only `originCwd` is changed. Links whose folder is gone are removed on the next sync. Cards are edited in place, byte for byte, and a copy that differs only in these paths is rewritten with its modification time kept.
- **One card per conversation.** Asked to open a conversation it has no loaded card for (a card that arrived after it started), a window imports it under a new card named after the transcript, `local_<cliSessionId>.json`, marked `adoptedFromOtherSurface`. So a folder never gets a second card for a transcript it already has a card for; in the folder where such an imported card appears, other cards for the same transcript are backed up and retired; and a tombstone for either card deletes both. Account-owned workers are left out of this matching.
- **Deletions.** An ordinary local session with a tombstone anywhere is never copied again. Tombstones are copied and deleted cards removed only when no Claude window is running. Worker tombstones never turn into cross-account deletions.
- **Archive.** Archived session lists are merged by union. Removals are not propagated: a running Claude can write back a stale list, which would be indistinguishable from un-archiving many sessions at once.
- **Safety.** Files are written atomically, and a card is re-checked right before it is replaced so a copy Claude has just updated is never overwritten with an older one. Every removed card is copied to `Backups/<date>/` first, and so is the first version of the day of every overwritten file. Backup days older than a week are moved to the Trash.
- **Concurrency.** The app, the CLI and launchers share `flock(2)` locks: a sync that finds another one running is skipped, and engine rebuilds wait for each other. A damaged `profiles.json` is reported and never overwritten; the previous version is kept as `profiles.json.bak`.

Symlinking the folders instead of copying doesn’t work: Claude Desktop creates them with `mkdir` and fails on a symlink.

`CoworkSync` inventories legacy local Cowork cards without writing anything. Their storage is separate from ordinary Code transcripts:

```text
<data dir>/local-agent-mode-sessions/<account-uuid>/<org-uuid>/
    local_<session>.json                  sidebar card
    local_<session>/.claude/projects/     local transcript tree
    local_<session>/                      working files and local session state
    cowork-*-cache.json, remote-session-spaces.json, scheduled-tasks.json, rpm/, <8 hex chars>/
                                         per-organization state
```

The observed Desktop loader resolves Cowork history inside the current data directory, account and organization, using the session ID. The card's `cwd` does not redirect that transcript lookup. A card copied to another profile can therefore appear in the sidebar yet open without its history; opening it can rewrite that copy. Copying the rewritten card back can damage the original session's metadata. A visible card is not a successful continuation test.

Cowork synchronization is consequently inventory-only: no card propagation, path rewriting, linking, deletion, or synchronization-state writes. Existing cards and former `cowork-sync.json` and native-scope records remain untouched; they are not removed or treated as permission to resume copying. `CoworkSync.removeCards(workingIn:)` does nothing. Modern cloud Cowork sessions, project caches and schedules are also never transferred between profiles.

Continue a local Cowork task in its original profile, or with **Continue work…**, which starts a new task elsewhere from its history and files (below). That does not migrate the original transcript or VM runtime. Diagnostics report missing adjacent local history to help identify old card copies; they cannot reconstruct missing history.

The app synchronizes eligible Code cards at launch and every minute while running (it stays in the menu bar when the window is closed); `claude-profiles sync` does the same on demand. Removing a profile synchronizes Code once more after its window quits, so sessions started in it moments ago are retained. The removed profile's legacy local Cowork files move to the Trash with its data directory. Cowork cards in other profiles remain unchanged and do not preserve those files.

## Sharing the setup

Claude Desktop keeps local setup beside sign-in and account state. `SettingsSync` and `InterfaceSync` run before a profile opens, while its stores are closed. The main app supplies portable defaults; account and device access are not made portable merely because they share the same JSON file. Unknown settings stay with the target. Existing corrupt destination JSON is reported instead of replaced with a guessed empty object.

`SettingsSync`:

- Extensions: `extensions-installations.json` and each package under `Claude Extensions` are one unit and are updated together. Packages are merged one by one, so an extension installed or edited only in the profile survives; a changed package is staged, then swapped in atomically, with a backup. `Claude Extensions Settings` and `claude-ssh-remote` are merged item by item the same way.
- SSH: in `ssh_configs.json`, connection definitions are merged one by one and keep changes made only in the profile; host trust decisions stay with the profile. An unknown file layout is left alone rather than copied without the data that matches it.
- Completed `claude-code/<version>` builds, identified by `.verified`, are cloned under a temporary name and then renamed so profiles cannot see a partial build.
- In `claude_desktop_config.json`, only `mcpServers` and a fixed set of portable preferences are shared: `keepAwakeEnabled`, `dockBounceEnabled`, `sidebarMode`, `quickEntryDictationShortcut`, `coworkPreferredBrowser`, `ccAutoArchiveInactiveDays` and `ccAutoArchiveOnPrClose`. Interface preferences are handled separately. Remote Control registration, connected folders, account and security grants, and new or unknown preferences keep the target's values.
- `mcp-user-tool-toggles.json` is not synchronized or remapped between accounts. Sharing an MCP definition does not mean sharing account-specific tool approval.
- Scheduler switches (`ccdScheduledTasksEnabled`, `coworkScheduledTasksEnabled`) remain per profile. `wakeSchedulerEnabled` stays off in profiles because each copy would register its own macOS wake helper; the main app handles waking.
- In `config.json`, only `userThemeMode`, `windowControlsZoomFactor` and `locale` are shared. This file includes sign-in state, so it is edited with its permissions preserved and is never copied or backed up.
- Portable JSON settings use a three-way merge: a value changed only in the target since the previous synchronization stays there; a conflicting change resolves to the main app. Merge baselines contain SHA-256 hashes, not settings values. Replaced local setup still uses the existing backup mechanism.

`InterfaceSync` operates on selected values for the `https://claude.ai` origin in Local Storage, `preferences.epitaxyPrefs`, and the `keyval` IndexedDB store. It shares display/editor/transcript preferences and local Code pins only when every pin has a valid known ordinary local Code card. A `local_` prefix alone is insufficient because native Project workers use that prefix too; unknown, mixed or account-owned pin lists leave the target record unchanged. Account-keyed settings, cloud Project/Cowork-space/routine pins, pane state, permission choices and unknown fields remain untouched. A cloud ID is not translated into a different account's ID.

Only the allowlisted records are written, and only when the destination store is closed and its format supports the write. IndexedDB values must use the same plain-string representation and compatible store version, with no blobs, indexes or key generator that a `put` would also need to update. The rest of the database, including account sign-in keys, is neither copied nor backed up; replaced selected values are backed up separately.

The main app wins an interface conflict, except for a value changed only in the profile since the previous run. `Interface/<profile>.json` records prior comparisons independently for Local Storage, preferences and IndexedDB; a failed stage cannot become a successful baseline. Opening a profile uses `open.lock` so the app and CLI cannot merge into the same profile simultaneously.

`LevelDBStore` reads Chromium's LevelDB databases directly: `CURRENT`, the manifest, `.ldb` tables (with Snappy) and `.log` files, newest sequence number wins. It writes by adding one new, higher-numbered `.log` file holding one batch; LevelDB replays it the next time Claude opens the database, and existing files are never changed. It refuses to write while another process holds the database's `LOCK`. `LocalStorage` and `IndexedDBStore` sit on top of it. `IndexedDBStore` follows Chromium's key encoding (`indexed_db_leveldb_coding`): it finds the database and object store by name, and writes a record the way IndexedDB's own `put` does — the record under a new version number, its exists entry, and the store's last version. New `.log` files are readable by the user only, like Chromium's own.

Claude reads sessions and per-account settings only at launch, and a new profile doesn't know its account until it is signed in. So when the app sees a profile's window go from signed out to signed in, it shares eligible Code sessions, creates that account's Code session folders, quits the window normally and opens it again. A window that doesn't quit within 20 seconds is left alone.

## Account ownership and compatibility

New Code Projects and cloud Cowork live with their Claude account. Local sidebar cards cannot reproduce a coordinator, its memory, Library, cloud environment or account connectors. Project workers created through Remote Control must keep their owning account and organization even when their transcript is on disk. Use the owning profile's native Projects UI to continue them. Legacy local Cowork has an additional dependency on its original profile and local runtime; it is not portable through card synchronization even when the files are on the same Mac.

The upstream capabilities change independently of this application: [Code Projects](https://code.claude.com/docs/en/claude-projects), [Remote Control](https://code.claude.com/docs/en/remote-control), [Cowork architecture](https://support.claude.com/en/articles/14479288-claude-cowork-architecture-overview), and [local versus cloud settings](https://code.claude.com/docs/en/settings). Account-specific rollout differences are expected. The local card and preference formats used here are observed Desktop implementation details, not an Anthropic compatibility API; new formats must be examined and tested before being added to a synchronization allowlist.

## Continuing a conversation elsewhere

`ConversationIndex` lists local conversations from files only: every window's Code cards with a transcript in `~/.claude/projects`, and Cowork cards whose own folder holds the transcript under `.claude/projects`. Archived cards are skipped. A Code card is listed once however many windows share it; an account-owned worker card (native Project or Remote Control worker) is not listed at all, so it is never offered for continuing.

`ProfileManager.continueConversation` checks that the destination exists, is signed in and, for Cowork, is not the owner. Then it hands the destination window a `claude://` link with `NSWorkspace.open(_:withApplicationAt:configuration:)`. Launch Services delivers it to the running instance of that app copy, and every profile has its own copy, so no other window receives it and no permission (Accessibility, Automation) is needed. A closed window is started with its `--user-data-dir` and the first link, after the usual session and settings preparation. Claude keeps only one link that arrives before its main window exists, so the others are sent after `CGWindowListCopyWindowInfo` shows a window of that process on screen (no permission needed); if none appears within 90 seconds, the continuation fails and names what was not sent.

- **Code sessions** use `claude://resume?session=<cliSessionId>`. Claude opens the session if the window has loaded its card, and imports it otherwise (see *One card per conversation*) through its own import path, which checks folder trust and resolves the permission mode; Claude Profiles never writes a card for it. The transcript is shared. `continueAll` confirms each session by the `local_<cliSessionId>.json` card that appears in the destination after the link, and reports those that don't. Claude shows a session when its import finishes, which replaces the current view, so a new-session link is sent only after the imports are confirmed.
- **Copies.** A session that `LiveSessions` finds open in a running `claude` process (`~/.claude/sessions/<pid>.json`, checked against the live process, and the `--resume` / `--session-id` arguments of running `claude` processes), or a session written to in the last 10 minutes continues as a copy: `TranscriptFork` writes a new transcript with a new session id, copies the session's tool-results and sub-agent folder with ids rewritten, and hard-links `file-history/<id>` and `session-env/<id>` to the new id (copying if a link fails), as the CLI does when it forks. The transcript is written last, and a failure removes everything made so far. The copy's title is suffixed with " · from <LABEL>" naming the source window when it is known, or " · copy" otherwise.
- **Folder rules.** `FolderRules` keeps `folder-rules.json` in the state folder: for a folder, the email addresses of the accounts that may continue its work. `ProfileManager.plan` looks up the closest rule for every conversation's folder and the new-session folder, takes the accounts all of them allow, and refuses a destination whose signed-in email isn't among them. An unreadable file or an unknown destination email refuses as well.
- **Cowork tasks** use `claude://cowork/new?q=<prompt>&file=<path>…`, which opens a new task with the prompt typed in and the files attached, without sending it. `CoworkHandoff` first writes a folder under `Handoffs/` (mode `0700`): `history.md` (mode `0600`) with the task's title, folders, which files are attached or left out, what is not carried over, and the conversation. `TranscriptText` keeps what the user wrote, Claude's replies and compaction summaries; tool calls become a list of tool names, and thinking, tool output, sub-agent runs and meta records are left out. Past 400,000 characters the first message and the latest ones are kept. Copies of the task's `uploads` and `outputs` (regular files only, up to 10 files, 25 MB each, 50 MB in total) are attached after the history. Handoff folders older than 30 days move to the Trash. The `folder=` parameter is not used: it makes Claude ask for folder access, and the prompt names the folders instead.

Query values are percent-encoded except for unreserved characters, because Claude parses the query with `URLSearchParams`, which reads `+` as a space. A Cowork task whose transcript changed in the last minute is treated as possibly running: the app warns, and the CLI requires `--anyway`.

## Diagnostics

**Check sessions** and `claude-profiles doctor [--json]` inspect the local installation without changing it. The report inventories ordinary local Code and Cowork cards separately from account-owned workers, and identifies ambiguous worker copies, missing working folders and missing adjacent Cowork history. Counts describe local inventory, not cross-profile portability. It is a local consistency check, not an authenticated test of cloud Project access or a promise that a Cowork session can resume elsewhere. After a Desktop update, use the report and a small real continuation task to validate the workflow you need.

## Reading Claude Desktop data

`DesktopData` reads, and never writes:

| Fact | Source | Notes |
|---|---|---|
| Signed-in account | `config.json` → `lastKnownAccountUuid` | The file also holds OAuth token caches; `DesktopData` reads only this key, and `SettingsSync` only the three appearance keys. |
| Usage | `plan-usage-history.json` → latest sample `u.fh` (5-hour %) and `u.sd` (weekly %) | Recorded by Claude Desktop itself; the 5-hour value is shown as “reset” once five hours have passed. |
| Email | IndexedDB cache of the claude.ai profile (scanned; only the email is kept, cached per account) | The address must follow `email_address` within 140 bytes and the account UUID must appear within the 80 bytes before it, so addresses of teammates in the same cache are ignored. |

## Testing

All logic lives in `ClaudeProfilesKit` and takes a `Paths` value, so tests run against a temporary home directory and never touch real data. `Backup` accepts a `discard` closure so pruning can be tested without filling the real Trash.
