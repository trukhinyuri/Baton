# Changelog

## 1.0.0-rc.1 — 2026-09-29

A release candidate, not notarized yet: open it once with System Settings → Privacy & Security → Open Anyway, or build it with `make install`. The signed 1.0.0 and the Homebrew cask follow.

**Baton takes the track.** Claude Profiles is now Baton: same app, same windows, a name that keeps "Claude", Anthropic's trademark, out of the product's own name. Your profiles and sessions carry over; what changes for you is listed under "Upgrading from Claude Profiles" just below.

Baton now covers local work only: local Claude Code sessions and Cowork tasks follow between windows, and everything kept in an Anthropic account stays with that account. 0.3.0 was never published; its changes are part of this release.

### Upgrading from Claude Profiles

- Your windows, profiles, sessions, folder rules and backups carry over untouched. Baton's data folder keeps the name it was created with, `~/Library/Application Support/Claude Profiles`, so nothing inside it moves; new installs use `~/Library/Application Support/Baton`
- The launchers folder `~/Applications/Claude Profiles` becomes `~/Applications/Baton` the first time Baton starts with every Claude window closed, or when you run `baton migrate`. Each launcher is updated in place, and an old `Claude Profiles.app` left in the folder goes to the Trash
- `baton migrate` exits with 0 once the folder is renamed or there is nothing to do, 3 when it keeps its old name for now (the printed line says why) and 1 on an error. When Baton runs from inside the old folder, quit it, close every Claude window and run the `baton` inside the app: `"$HOME/Applications/Claude Profiles/Baton.app/Contents/Helpers/baton" migrate`
- `make install` installs into the folder you already have, renames it when no Claude window is open or prints the exact command to finish later, points the launchers at the new app, and prints the exact `ln -sf` for every old `claude-profiles` or `baton` link it finds in `/usr/local/bin` or `/opt/homebrew/bin`
- The command is now `baton`, and `baton pass` works too. Homebrew links it; a link you made yourself to the old `claude-profiles` stops working once the old app is gone: `ln -sf ~/Applications/Baton/Baton.app/Contents/Helpers/baton /usr/local/bin/baton`. Scripts that still call `claude-profiles` can link `Contents/Helpers/claude-profiles`, which 1.x keeps
- Installed Claude Profiles from the ZIP? Quit it and move `Claude Profiles.app` to the Trash. If it was inside `~/Applications/Claude Profiles`, put `Baton.app` in `/Applications` (or run `make install`); otherwise put it where the old app was. If Claude Profiles is in your Dock, remove it and add Baton. If Claude Profiles opens at login, replace it with Baton in System Settings → General → Login Items
- An older copy that still starts (from a Login Item, the ZIP or the Trash) is asked to quit when Baton starts, instead of Baton handing over to it
- The app keeps its bundle id, `io.github.trukhinyuri.claudeprofiles`, so macOS keeps treating it as the same app. The Homebrew cask is `baton`, from the signed 1.0.0; if you had the `claude-profiles` cask, `brew update && brew upgrade` moves you to it then (the tap's `cask_renames.json`); don't install `baton` next to it

### Continue work

- **Continue work…** lists the local Code sessions and Cowork tasks of every window, most recent first, with search. Pick one and a subscription to continue in; the signed-in subscription with the most room left (by the higher of its five-hour and weekly usage) is preselected, those at their limit are marked, and a banner offers this when an open subscription reaches its five-hour or weekly limit
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
- Usage shows how old each figure is; figures older than 3 hours are marked

### Limits and resets

- A window at its limit shows when it resets, in your Mac's time format ("resets at 2:10 AM", "resets tomorrow at 2:10 AM", or "resets Wed at about 5:00 AM" when Baton can only estimate it), from Claude's own limit messages and Auto-continue when limits reset. Reset times appear for limits reached while Baton is running; one reached before that shows no time, and a limit held back only by an old sample reads "at its limit as of 10:12 PM". A closed window is sampled again about 9 s after you open it, and a closed window whose estimate has passed says to open it
- A reset Claude reports early frees the window at once. So does a reply Claude gives in that window to a request sent at least a minute after the limit, shown as "Claude answered since", since extra usage may be what paid for it; a reply to a request Claude admitted before the limit doesn't count, and an estimate never frees a window
- A window that has stayed free for a minute after its limit is announced as having room again, in Baton's window and, if you allow it, as a macOS notification; macOS asks once, the first time, and that is the only permission Baton may ask for
- When a session continues elsewhere, Baton turns off Claude's Auto-continue when limits reset for it in the window it left, if that window is closed, and otherwise once that window closes: at once while the Baton app runs, or when that window is next opened from Baton. `baton doctor` lists what Baton turned off
- When the window a session came from picks it up by itself within minutes, **Continue work…** and `baton continue` offer to wait; **Continue All** and `baton continue --folder` leave only those sessions there, name them, and continue the rest (with `--new` or **Also start a new session there**, the new session starts even when all of them are left there); `baton continue --folder` exits with 3 only when nothing continued

### Sharing between accounts

- Folder rules (`baton rule <folder> --only <email>`) keep a folder's work in the listed accounts, for continuing and for session sharing alike. An unknown email counts as not allowed, and a damaged rules file stops both until it is fixed. Copies made before a rule are retired only in closed windows, with a backup
- A card copied into another account's window no longer carries that account's Remote Control bridge, remote MCP servers and tools, browser and computer-use grants or permission mode (a profile can opt in to keeping the permission mode). Copies between windows of the same account stay byte-for-byte identical
- A window that was closed while a session was forked can no longer point that session back at its old transcript, and a card whose session is live in another window is not overwritten
- The signed-in email is read from compressed IndexedDB tables too
- A window that opens a conversation it had no card for makes its own card; the older copy in that window is backed up and retired, and deleting either card deletes the conversation
- A closed profile's sessions are shared right before it starts, so launchers don't depend on the app's next background sync
- MCP servers, extensions and SSH connections are merged one by one, keeping what was added or changed only in a profile; SSH host trust stays with each profile

### Local only

- **Local only**, on by default, turns off two Remote Control settings in every managed window, the main one included: the default for new sessions and, where Claude has it, staying reachable. It writes them only while that window is closed, after a dated backup, and turning it off restores the previous values. A running window shows *pending*, and a Claude version without these settings shows *not supported* and gets no write
- `baton local-only on|off|status`, a global and per-profile switch in the app, and a badge on each window
- An optional setting stops the agent from moving a session to the cloud (`permissions.deny` in `~/.claude/settings.json`), written only when you turn it on

### Report a problem and diagnostics

- **Report a problem** in the footer, the menu bar and the Help menu, and `baton report [--save PATH] [--open]`, prepare a redacted report you review first: versions, window states, session check and sync counts, recent errors and the last 200 lines of Baton's own log. Copy it, save it, or open a prefilled GitHub issue in your browser; nothing is sent automatically
- Errors say what failed and what to do; a per-window status panel shows its account, Local only state, pending changes and why sessions were skipped
- `doctor` shows where Claude Desktop was found and its version, whether this Claude version has each Local only setting, and which sessions Claude has marked as moved between accounts
- `baton --version` prints the version and commit
- Claude Desktop is found wherever Launch Services knows it, then in `/Applications` and `~/Applications`, and the app warns when its version is newer or older than the tested major.minor, can't be read, or is known not to work: every 2.9939.x build counts as tested
- Baton keeps its own text log, `Logs/baton.log` in its data folder (up to 1 MB, three files), written by the app and `baton` next to the macOS log; a problem report attaches its last lines after the same redaction as the rest
- The main Claude app gets its `claude://` links back at every start if a profile sign-in was interrupted

### Safety

- Creating profiles at the same time from the app and the CLI keeps both, and removing a profile refuses while its window is running instead of quitting it
- Only the current and the previous downloaded Claude Code build are kept in each profile
- The app warns when a second copy of it is installed, since two copies would each run their own sync
- App copies are rebuilt in a staging bundle, verified and swapped in atomically; the previous copy is restored if the new one fails verification. They are rebuilt only for a newer Claude Desktop, versions compared part by part as numbers, and never replaced with an older one
- If Baton's data or launchers folder of the earlier name is a link that leads nowhere right now (a disk not connected), the app and `baton` stop with a line naming the link and where it leads, instead of starting a new, empty folder
- An idle refresh reads no session card or transcript again; only files that changed are read. A remembered Continue copy whose transcript is gone is forgotten at the next sync
- The window status and the footer's "all windows are up to date" count a running window that the app shared sessions into since the app started as waiting for a restart
- Opening a profile no longer fails when sessions can't be shared first; the window opens and the problem is reported
- A session whose transcript file is empty is dated by the file instead of being listed last
- The app and `baton` drop every `CLAUDE…` and `ANTHROPIC_…` variable they inherit before starting anything, so a Claude window opened from a terminal or a Claude Code session starts the way a Dock launch starts it, without an API key, proxy or model override from that shell

### Install and release

- Universal build for Apple silicon and Intel, signed with the hardened runtime; releases are notarized, stapled, published with `SHA256SUMS.txt` and a build-provenance attestation
- Homebrew: `brew install --cask trukhinyuri/tap/baton`
- The installer keeps the previous app as a ZIP in `AppBackups` inside Baton's data folder (the three latest) instead of runnable `.previous-*.app` copies beside the app, and moves those left by 0.2.0 to the Trash. Each ZIP is named after the app and its folder and never overwrites another; `make uninstall` moves Baton.app to the Trash
- A release is published only when it can be notarized, and its last job points the Homebrew tap at it

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
- “No folder” sessions started in another window are listed under “No folder” instead of their scratch folder's name, and offer side questions (`/btw`) there too
- A profile window closed right after its first sign-in is no longer reopened, and a profile removed while it was being opened isn't rebuilt
- Each window keeps its own account's local scheduled tasks and scheduler switches (0.1.0 copied the main app's into profiles); waking the Mac for tasks stays with the main app
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
