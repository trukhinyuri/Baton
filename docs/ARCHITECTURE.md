# Architecture

Claude Profiles is a thin layer around the official Claude Desktop app. It never changes how Claude talks to Anthropic. It selects each window's data directory, synchronizes eligible local data, and can save explicitly selected context for a new native conversation in another account.

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

`EngineInstall` builds a sibling staging bundle with `clonefile` or a copy fallback. It checks the source and staged bundle's version, identifier, executable and code signature before replacement. An existing destination is exchanged atomically with the stage using `renamex_np(RENAME_SWAP)`, preserving the old engine until post-install validation succeeds. Failed validation exchanges it back; a failed rollback retains the previous bundle and reports its path. Only the installer's own staging bundle is disposable. The profile manager serializes engine changes and ensures the profile is closed. This engine rollback is distinct from the application installer, which retains `.previous-<date>-<id>.app` beside Claude Profiles itself.

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

Continue the original legacy local Cowork session in its original profile, or explicitly capture its available context for a new conversation elsewhere. The capture described below saves transcript bytes as reference data; it does not register those transcripts as another account's original native conversation or migrate the VM runtime. Diagnostics report missing adjacent local history to help identify old card copies; they cannot reconstruct missing history.

The app synchronizes eligible Code cards at launch and every minute while running (it stays in the menu bar when the window is closed); `claude-profiles sync` does the same on demand. Removing a profile synchronizes Code once more after its window quits, so sessions started in it moments ago are retained. The removed profile's legacy local Cowork files move to the Trash with its data directory. Cowork cards in other profiles remain unchanged and do not preserve those files.

## Sharing the setup

Claude Desktop keeps local setup beside sign-in and account state. `SettingsSync` and `InterfaceSync` run before a profile opens, while its stores are closed. The main app supplies portable defaults; account and device access are not made portable merely because they share the same JSON file. Unknown settings stay with the target. Existing corrupt destination JSON is reported instead of replaced with a guessed empty object.

`SettingsSync`:

- `Claude Extensions`, `Claude Extensions Settings`, `extensions-installations.json`, `ssh_configs.json` and `claude-ssh-remote` retain their existing file-copy behavior (APFS clones with backups).
- Completed `claude-code/<version>` builds, identified by `.verified`, are cloned under a temporary name and then renamed so profiles cannot see a partial build.
- In `claude_desktop_config.json`, only `mcpServers` and a fixed set of portable preferences are shared: `keepAwakeEnabled`, `dockBounceEnabled`, `sidebarMode`, `quickEntryDictationShortcut`, `coworkPreferredBrowser`, `ccAutoArchiveInactiveDays` and `ccAutoArchiveOnPrClose`. Interface preferences are handled separately. Remote Control registration, connected folders, account and security grants, and new or unknown preferences keep the target's values.
- `mcp-user-tool-toggles.json` is not synchronized or remapped between accounts. Sharing an MCP definition does not mean sharing account-specific tool approval.
- Scheduler switches (`ccdScheduledTasksEnabled`, `coworkScheduledTasksEnabled`) remain per profile. `wakeSchedulerEnabled` stays off in profiles because each copy would register its own macOS wake helper; the main app handles waking.
- In `config.json`, only `userThemeMode`, `windowControlsZoomFactor` and `locale` are shared. This file includes sign-in state, so it is edited with its permissions preserved and is never copied or backed up.
- Portable JSON settings use a three-way merge: a value changed only in the target since the previous synchronization stays there; a conflicting change resolves to the main app. Merge baselines contain SHA-256 hashes, not settings values. Replaced local setup still uses the existing backup mechanism.

`InterfaceSync` operates on selected values for the `https://claude.ai` origin in Local Storage, `preferences.epitaxyPrefs`, and the `keyval` IndexedDB store. It shares display/editor/transcript preferences and local Code pins only when every pin has a valid known ordinary local Code card. A `local_` prefix alone is insufficient because native Project workers use that prefix too; unknown, mixed or account-owned pin lists leave the target record unchanged. Account-keyed settings, cloud Project/Cowork-space/routine pins, custom groups, pane state, permission choices and unknown fields remain untouched. A cloud ID is not translated into a different account's ID.

Only the allowlisted records are written, and only when the destination store is closed and its format supports the write. IndexedDB values must use the same plain-string representation and compatible store version, with no blobs, indexes or key generator that a `put` would also need to update. The rest of the database, including account sign-in keys, is neither copied nor backed up; replaced selected values are backed up separately.

The main app wins an interface conflict, except for a value changed only in the profile since the previous run. `Interface/<profile>.json` records prior comparisons independently for Local Storage, preferences and IndexedDB; a failed stage cannot become a successful baseline. Opening a profile uses `open.lock` so the app and CLI cannot merge into the same profile simultaneously.

`LevelDBStore` reads Chromium's LevelDB databases directly: `CURRENT`, the manifest, `.ldb` tables (with Snappy) and `.log` files, newest sequence number wins. It writes by adding one new, higher-numbered `.log` file holding one batch; LevelDB replays it the next time Claude opens the database, and existing files are never changed. It refuses to write while another process holds the database's `LOCK`. `LocalStorage` and `IndexedDBStore` sit on top of it. `IndexedDBStore` follows Chromium's key encoding (`indexed_db_leveldb_coding`): it finds the database and object store by name, and writes a record the way IndexedDB's own `put` does — the record under a new version number, its exists entry, and the store's last version. New `.log` files are readable by the user only, like Chromium's own.

Claude reads sessions and per-account settings only at launch, and a new profile doesn't know its account until it is signed in. So when the app sees a profile's window go from signed out to signed in, it shares eligible Code sessions, creates that account's Code session folders, quits the window normally and opens it again. A window that doesn't quit within 20 seconds is left alone.

## Account ownership and compatibility

New Code Projects and cloud Cowork live with their Claude account. Local sidebar cards cannot reproduce a coordinator, its memory, Library, cloud environment or account connectors. Project workers created through Remote Control must keep their owning account and organization even when their transcript is on disk. Use the owning profile's native Projects UI to continue them. Legacy local Cowork has an additional dependency on its original profile and local runtime; it is not portable through card synchronization even when the files are on the same Mac.

The upstream capabilities change independently of this application: [Code Projects](https://code.claude.com/docs/en/claude-projects), [Remote Control](https://code.claude.com/docs/en/remote-control), [Cowork architecture](https://support.claude.com/en/articles/14479288-claude-cowork-architecture-overview), and [local versus cloud settings](https://code.claude.com/docs/en/settings). Account-specific rollout differences are expected. The local card and preference formats used here are observed Desktop implementation details, not an Anthropic compatibility API; new formats must be examined and tested before being added to a synchronization allowlist.

## Explicit context handoff

`Handoff` packages user-reviewed text into a new-conversation prompt. It never reads a cloud transcript, copies a Project ID into another account's state, or grants access to source connectors. The optional `https://claude.ai/` source link is a reference, not a navigation or authorization mechanism. An optional working folder must already exist at an absolute path.

**Continue work…** provides a request the user can copy to the source Claude, a context editor and source/destination selectors. If the source is already capped, the user can enter a handoff from known facts without another source-model response. **Save handoff & open destination** saves the file, copies the continuation prompt and opens the selected profile; the user chooses the destination conversation and sends it. The CLI saves the same context with `handoff --from … --to … --title … --context …`, plus optional `--folder` and `--source-url`. It prints the saved path and opens the destination only with `--open`; it does not modify the clipboard.

Handoffs are Markdown files under `Handoffs/` in the Claude Profiles state directory, created with mode `0600` in a `0700` directory. The prompt distinguishes quoted source content from user authorization and asks the destination to verify required files and tools before continuing. A handoff does not migrate the original cloud conversation or legacy local Cowork session, its memory, files, runtime, permissions or background jobs. The source must stop working on the same task before the destination continues it.

## Captured continuity workspaces

`ContinuityWorkspace` is a private canonical context store under `Workspaces/<UUID>`, separate from native Claude storage. `LATEST.json` identifies an immutable snapshot and includes hashes for its manifest and generated `CONTINUE.md` instructions. The manifest contains the workspace identity and revision, source profile/link, entries with provenance/size/SHA-256, component coverage and limitations, a mapping of profiles to separate native conversation links, and one recorded active profile. Payload files use generated names and are stored as data rather than executable instructions. Historical source text remains untrusted context.

Publishing appends new logical paths while retaining earlier entries. An identical path and identical contents are idempotent; changing an existing logical path requires a new capture path. File inputs must match the reviewed size and hash. Private staging completes before an atomic `LATEST.json` update makes the snapshot visible. `FileLock` and an expected revision reject stale writers. Loading verifies the instruction file, manifest and every referenced payload. Relative-path checks and symlink rejection keep supplied paths inside the intended storage; workspace directories use `0700` and files `0600`.

Registering a destination stores a separate native URL, not a rewritten source object ID. Activating it requires a current revision, a recorded destination and caller acknowledgement that the previous source is paused. This is local workflow state, not an execution lock in Claude. The app cannot prevent someone from manually resuming another window or a cloud worker. The destination must verify context and required access before receiving the separate work prompt. New context must be captured and appended before another switch.

### Local Cowork capture

`CoworkHistory` reads the selected task from its configured profile/account/organization root. It rediscovers the card and current transcript identity rather than trusting caller-supplied file paths. The capture includes exact UTF-8 JSONL records in the task's local transcript tree, available rewind/subagent history and supported transcript metadata. It inventories and hashes supported `outputs` and `uploads` files. Scoped parent-project metadata/instructions and local project memory are captured where present. It does not automatically include other tasks, profile-wide memory, external working folders, cloud-only Library content or credentials/configuration. Each missing or excluded component is described in the capture's limitations.

Malformed records, truncated history, ambiguous identities, unsafe paths and size/count limits produce an error rather than a silently shortened transcript. Source identity and contents are checked while reading. `CoworkContinuation.save` repeats the capture after review and requires it to match before publishing. Selected artifact bytes are checked again against the reviewed hashes during workspace publication. A failed save cannot advance the prior workspace revision.

The saved capture contains the quoted overview, each raw transcript, separate project context documents, source metadata and copied task artifacts. Coverage can describe available local history as complete without describing the whole task or Project as complete: artifacts and project context retain their own partial/unavailable status, and runtime/tool grants are unavailable. A saved byte is not proof that the destination model has read it.

The Cowork GUI first copies a read-only bootstrap check. After the user reviews the destination's answer and records its native link, it records that profile as active and copies a separate work prompt. It does not send either prompt. A Project coordinator without local file access may use one read-only helper solely to inspect the supplied context; this is not permission to resume the original task or change external systems.

### Current-view and bounded capture

`ClaudeContextCapture.captureCurrentView` uses macOS Accessibility to read a supported view from the selected profile process without navigation. The parser keeps supported Project/Cowork content and excludes sidebar navigation, account controls, secure fields and unsent composer drafts. It rejects unsupported/authentication routes. Capture does not enable Accessibility, send messages or call a private cloud API.

Each view snapshot records the source URL, visible sections, pagination/collapsed controls and gaps and remains `currentViewOnly`. `captureAvailableViews`, exposed as **Read available views**, collects these snapshots through a bounded allowlist of native actions. Code Project capture visits supported General settings, memory files, observed thread groups/links, older conversation pages/tool disclosures, Library inventory pagination and supported AX scrolling. Cloud Cowork capture stays within the open conversation's pagination, tools and scrolling; Project navigation is forbidden there.

The native driver verifies process, profile data directory, account, window and canonical source identity and re-reads the expected surface before an action. Time/action/view limits, cancellation and source changes stop the sweep while retaining prior views. The result inventories captured references and unresolved gaps; `isCompleteProject` remains false. Virtualized history, hidden branches and original Library/artifact bytes may still be unavailable. A scroll boundary or missing pagination button is not proof of complete history.

`CapturedViewSheet` previews and saves captured text, metadata, inventory and limitations to a workspace. Preview shortening is not payload truncation. Neither capture mode creates a native destination Project. Automated fixtures cover the collector and parser; a live sweep still requires separate verification with Accessibility access.

Artifact links are provenance and inventory, not a download API. The native Project artifact menu inspected during development exposed no Download action. Only separately supplied originals obtained through supported means can close the corresponding file gap; the capture/export layer cannot promise every cloud artifact's bytes.

`WorkspaceSelectedFiles`, exposed as **Add downloaded/selected files…**, appends the explicitly chosen local originals with byte hashes/provenance and partial Library coverage. It preserves prior captures and does not alter source files, execute them or upload them. The GUI invalidates previous review, destination-verification and export references after adding content. Automated tests cover this path; native attachment ingestion remains a separate live check.

### Portable export

`WorkspaceContinuationSheet`, opened through **Open saved workspace…**, provides inspection, export and separate native-link registration for either capture source. Read-only verification may precede native-link registration: a new Cowork conversation does not receive its URL until its first message. Work activation still requires the reviewed context, a registered destination and acknowledgement that source work has stopped. A user-supplied link is not proof that the selected account owns or can access that object.

`workspace-info PATH [--json]` uses the production workspace loader to verify saved bytes and display coverage and known native links. It does not check authenticated destination access. `workspace-export PATH --to NEW_FOLDER --revision N` exports the explicitly reviewed revision to a previously absent directory. `ContinuityWorkspaceExport` retains all payloads referenced by the current manifest, including earlier captures, while excluding obsolete control manifests and unreferenced files. `CONTEXT.md` contains quoted complete text entries. Entries marked as files are also exported under `files/` with safe prefixed filenames retaining their extensions; `ATTACHMENTS.json` maps them to logical paths, sizes and hashes. Users attach supported files individually through Claude's native picker. `workspace.zip` contains a loadable workspace snapshot and all retained payloads for local backup/restoration; it is not a native Claude import format. No upload, import or message is performed by the exporter.

A live development-build test verified capture, native Markdown upload and one-way reading of a local Cowork task's available text in a new Cowork conversation in another profile. The native picker rejected the ZIP. That pilot contained no binary artifacts, so individual attachment ingestion, a return trip and complete cloud Project capture remain unverified. See [CONTINUITY.md](CONTINUITY.md#validation-record) for the anonymized evidence and limits. None of these files change native Project ownership, copy account grants or guarantee complete cloud context.

## Diagnostics

**Check sessions** and `claude-profiles doctor [--json]` inspect the local installation without changing it. The report inventories ordinary local Code and Cowork cards separately from account-owned workers, identifies ambiguous worker copies, missing working folders and missing adjacent Cowork history, and shows per-profile Remote Control configuration. Counts describe local inventory, not cross-profile portability. It is a local consistency check, not an authenticated test of cloud Project access or a promise that a Cowork session can resume elsewhere. After a Desktop update, use the report and a small real continuation task to validate the workflow you need.

## Reading Claude Desktop data

`DesktopData` reads, and never writes:

| Fact | Source | Notes |
|---|---|---|
| Signed-in account | `config.json` → `lastKnownAccountUuid` | The file also holds OAuth token caches; `DesktopData` reads only this key, and `SettingsSync` only the three appearance keys. |
| Usage | `plan-usage-history.json` → latest sample `u.fh` (5-hour %) and `u.sd` (weekly %) | Recorded by Claude Desktop itself; the 5-hour value is shown as “reset” once five hours have passed. |
| Email | IndexedDB cache of the claude.ai profile (scanned; only the email is kept, cached per account) | The address must follow `email_address` within 140 bytes and the account UUID must appear within the 80 bytes before it, so addresses of teammates in the same cache are ignored. |

## Testing

Storage and synchronization logic lives in `ClaudeProfilesKit` and accepts explicit roots or a `Paths` value, so fixture tests run against temporary directories. `Backup` accepts a `discard` closure so pruning can be tested without filling the real Trash. Engine tests inject copy/validation/exchange failures. Continuity tests exercise byte preservation, changes after review, revision conflicts, corruption, unsafe paths and coverage gaps; Accessibility parser tests use synthetic trees. These tests cannot validate a live account's feature rollout or a destination model's actual use of context. Native application checks and a small real round trip are recorded separately.
