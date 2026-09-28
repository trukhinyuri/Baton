# Changelog

## 1.0.0 — unreleased

Baton now covers local work only: local Claude Code sessions and Cowork tasks follow between windows, and everything kept in an Anthropic account stays with that account. 0.3.0 was never published; its changes are part of this release.

### Continue work

- **Continue work…** lists the local Code sessions and Cowork tasks of every window, most recent first, with search. Pick one and a subscription to continue in; the one with the most weekly headroom is preselected, those at their limit are marked, and a banner offers this when an open subscription reaches its five-hour or weekly limit
- An idle Code session opens as the same session in the chosen window, which is opened first if needed. The transcript is shared, so nothing is copied
- A session that a running Claude Code process has open, or one with a message in the last 10 minutes, continues as a copy by default, so two windows never write to one session. **Same session** / `--same` needs confirmation that the original was closed (`--anyway`); **As a copy** / `--fork` always copies
- A copy takes the whole session with it: transcript, sub-agents, Workflow history (ids rewritten in `workflows/*.json` too), tool outputs, background task outputs, file history (Rewind checkpoints), and the scratchpad's text files under `from-<old id>/`. What is left behind, such as a git worktree inside the scratchpad, is reported. A copy is reused only while its source is unchanged
- After Claude Desktop forks a session itself, the sub-agents, Workflow history and tool outputs it left behind are brought over to the new session at the next sync, adding files only and never changing the old session; `baton carry [--dry-run]` does it on demand. Rewind to a point before such a fork cannot be restored, and the app says so
- Before you continue, the sheet names what will not follow into that account: remote connectors, a Remote Control connection, scheduled tasks and cloud sessions
- A Cowork task continues as a new task in the chosen window with a continuation prompt, its full history as `history.md` and copies of the files it was given and made. Nothing is sent: you review and send it there
- **Continue All in …** continues the six most recent Code sessions of a folder with a message in the last day in one step, and can start a new session there; `baton continue --folder <path> --to <profile> [--since 24h] [--max 6] [--new] [--dry-run]` does the same and says how many older ones it left out
- Links reach a closed window one by one: the first starts it, the rest follow once its window is on screen, and each continued session is confirmed by the card Claude imports; one that doesn't appear is reported
- Claude imports continued sessions itself, with its own trust and permission checks; when the destination's model differs from the session's, the sheet and `--dry-run` ask you to choose it first
- `baton conversations [--all]` and `baton continue <id|last> --to <profile> [--same [--anyway]|--fork] [--dry-run]` (or `baton pass`, the same command) do the same as **Continue work…** from the command line. Continuing needs no macOS permissions
- Usage shows how old each figure is; figures older than 3 hours are marked. Windows are ordered by weekly usage, lowest first

### Sharing between accounts

- Folder rules (`baton rule <folder> --only <email>`) keep a folder's work in the listed accounts, for continuing and for session sharing alike. An unknown email counts as not allowed, and a damaged rules file stops both until it is fixed. Copies made before a rule are retired only in closed windows, with a backup
- A card copied into another account's window no longer carries that account's Remote Control bridge, remote MCP servers and tools, browser and computer-use grants or permission mode (a profile can opt in to keeping the permission mode). Copies between windows of the same account stay byte-for-byte identical
- A window that was closed while a session was forked can no longer point that session back at its old transcript, and a card whose session is live in another window is not overwritten
- The signed-in email is read from compressed IndexedDB tables too
- A window that opens a conversation it had no card for makes its own card; the older copy in that window is backed up and retired, and deleting either card deletes the conversation
- A closed profile's sessions are shared right before it starts, so launchers don't depend on the app's next background sync
- MCP servers, extensions and SSH connections are merged one by one, keeping what was added or changed only in a profile; SSH host trust stays with each profile

### Local only

- **Local only**, on by default, turns off Remote Control's default and keeping the Mac reachable for it in every managed window, the main one included, while that window is closed, after a dated backup. Turning it off restores the previous values. A running window shows *pending*, and a Claude version without these settings shows *not supported* and gets no write
- `baton local-only on|off|status`, a global and per-profile switch in the app, and a badge on each window
- An optional setting stops the agent from moving a session to the cloud (`permissions.deny` in `~/.claude/settings.json`), written only when you turn it on

### Report a problem and diagnostics

- **Report a problem** in the footer, the menu bar and the Help menu, and `baton report [--save PATH] [--open]`, prepare a redacted report you review first: versions, window states, session check and sync counts, recent errors and the last 200 log entries. Copy it, save it, or open a prefilled GitHub issue in your browser; nothing is sent automatically
- Errors say what failed and what to do; a per-window status panel shows its account, Local only state, pending changes and why sessions were skipped
- `doctor` shows where Claude Desktop was found and its version, whether this Claude version has each Local only setting, and which sessions Claude has marked as moved between accounts
- `baton --version` prints the version and commit
- Claude Desktop is found wherever Launch Services knows it, then in `/Applications` and `~/Applications`, and the app warns when its version is outside the tested range
- The main Claude app gets its `claude://` links back at every start if a profile sign-in was interrupted

### Safety

- Creating profiles at the same time from the app and the CLI keeps both, and removing a profile refuses while its window is running instead of quitting it
- Only the current and the previous downloaded Claude Code build are kept in each profile
- The app warns when a second copy of it is installed, since two copies would each run their own sync
- App copies are rebuilt in a staging bundle, verified and swapped in atomically; the previous copy is restored if the new one fails verification
- Opening a profile no longer fails when sessions can't be shared first; the window opens and the problem is reported
- A session whose transcript file is empty is dated by the file instead of being listed last

### Install and release

- Universal build for Apple silicon and Intel, signed with the hardened runtime; releases are notarized, stapled, published with `SHA256SUMS.txt` and a build-provenance attestation
- Homebrew: `brew install --cask trukhinyuri/tap/baton`
- The installer keeps the previous app as a ZIP in `~/Library/Application Support/Claude Profiles/AppBackups` (the three latest) instead of runnable `.previous-*.app` copies beside the app, and moves those left by 0.2.0 to the Trash

### Removed

- Continuing Code Project branches, the `handoff` command and **Copy handoff request** for claude.ai chats, and shared Code sidebar groups. Code Projects and chats stay with their account; open them in the window of that account

## 0.2.0 — 2026-09-27

- Installation stages and verifies the new app and retains the previous app for rollback; a running manager must be quit first, while Claude windows can remain open
- **Continue work…** saves reviewed context locally, opens the selected destination profile and copies a prompt for a new conversation; `claude-profiles handoff` saves the same context and opens the destination with `--open`. Cloud Project history and permissions remain in the source account, and nothing is sent automatically
- Native Project and Remote Control worker cards in Code storage stay within their owning account and organization; older copies already present across accounts are left untouched, excluded from sync and reported as ambiguous
- **Check sessions** and `claude-profiles doctor [--json]` report local Code/Cowork inventory, account-owned workers, missing working folders or adjacent Cowork history, and per-profile Remote Control setup without modifying data
- Desktop settings synchronization uses an explicit portable preference list; Remote Control registrations, folder access, tool grants, cloud state and unknown preferences remain per profile
- Portable settings use a three-way merge that retains profile-only edits and stores comparison hashes rather than settings values; corrupt destination configuration is reported instead of overwritten
- Cloud Project, Cowork-space and routine pins, account-keyed settings, custom groups and permission choices no longer propagate into another profile; eligible local Code pins and portable display preferences still do
- Cowork synchronization is inventory-only: no cards, paths or state files are written or deleted. Legacy local Cowork history depends on the original profile/account/organization runtime; copied cards can open without history. Existing copies and old synchronization state are preserved
- Documented ordinary local Code continuity, account-owned cloud Projects/Cowork and profile-dependent legacy local Cowork. Continue the latter work in its original profile or use a reviewed handoff for a new conversation
- A profile window opened from an icon pinned with **Keep in Dock**, or reopened by macOS at login, showed the main app's account. Claude Profiles now reopens it with its own profile, and the app and `claude-profiles list` point out a window left that way
- A profile is shown as open only when its window really uses the profile, and opening it no longer brings forward a window that shows the main account
- Profile windows receive supported display preferences, local Code pins, theme, zoom and language from the main app while retaining account-owned interface state
- Eligible local Code pins are synchronized in interface preferences and IndexedDB as well as Local Storage, because Claude reads those stores first
- Portable display preferences follow the main app where the profile has no independent change; account-scoped filters stay with their account
- “No folder” sessions started in another window are listed under “No folder” instead of their scratch folder’s name, and offer side questions (`/btw`) there too
- A profile window closed right after its first sign-in is no longer reopened, and a profile removed while it was being opened isn’t rebuilt
- Each window keeps its own account’s local scheduled tasks and scheduler switches (0.1.0 copied the main app’s into profiles); waking the Mac for tasks stays with the main app
- A profile window restarts once after its first sign-in, so shared sessions show up right away
- New profiles reuse the Claude Code build the main app has already downloaded

## 0.1.0 — 2026-09-25

First public release.

- One Claude Desktop window per subscription, each with a labeled Dock icon and launcher
- Claude Code sessions, deletions and archive shared across all profiles, with backups
- Signed-in email and five-hour/weekly usage for every subscription
- Add, open and remove subscriptions from the app, the menu bar or the `claude-profiles` CLI
- App copies rebuilt automatically after Claude Desktop updates
- Profile windows get the main app's extensions, MCP servers, tool toggles, SSH hosts and preferences when they start
- Google and email sign-in both work in profile windows: while one signs in, `claude://` sign-in links go to it instead of the main app
