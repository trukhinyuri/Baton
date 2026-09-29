# Security model

What Baton can reach, what it does with it, and what it never does. Report a weakness privately through a [security advisory](../SECURITY.md).

## Assets

| Asset | Where | Baton |
|---|---|---|
| Sign-in: tokens, cookies, Keychain items | Each data directory, the Keychain | Never reads, copies, backs up or forwards them |
| Account id | `config.json` → `lastKnownAccountUuid` | Reads this one key |
| Account email | Claude's local IndexedDB cache | Reads the email that belongs to the account id, nothing else |
| Usage | `plan-usage-history.json` | Reads its samples |
| Limit messages and replies | Transcripts in `~/.claude/projects` | Reads when a session was refused at a limit, the reset time Claude gave, and when Claude last answered, to show when a window has room again |
| Auto-continue entries | `claude_desktop_config.json` → `preferences.epitaxyPrefs` → `autoResumeRateLimit.<account>`, and its Local Storage copy `LSS-persisted.autoResumeRateLimit.<account>` | Reads reset times; turns `optedIn` off for one session's entry in the closed window that session was continued from, in both places, after a backup; adds an entry, reset two minutes past, in both places, for a session the limit cut that continues in a closed window, so Claude continues it there, never where the account turned the option off in either window; `baton doctor` lists each change and `undo` removes it |
| Sidebar pins | IndexedDB `keyval-store` → `store:pin-state:dframe-starred-code`, its Local Storage copy `LSS-persisted.starred-local-code-sessions` and `starred-local-code-sessions` in the settings | Reads in every window; writes the moved sessions' pins into the closed window the work moves to, keeping its own, after a backup of the replaced record; read back, and the backups restored on a mismatch. Pins stay local: Claude doesn't sync local session ids, and Baton sets no marker for them |
| Groups and pin order in the sidebar | Local Storage `dframe-store` (`customGroupsByScope`, `pinnedOrder`), its copies `LSS-persisted.dframe-group-scopes` and `LSS-persisted.dframe-local-slice`, and the same keys in the settings | Reads; writes the moved sessions' groups, assignments and pin order into the closed window the work moves to, merged with what it has, after a backup, and reads them back. A group new to that account also gets Claude's `\|migrate` marker (see Boundaries) |
| Remote Control state | `remote-control-state.json`, `remoteControlPinnedFolders` in the settings | Reads which folders Claude's Remote Control serves, to keep a card it can reach with its window; an unreadable file counts as reaching everything. Local only empties the pinned folders (above) |
| Cached server flags | `fcache` in each data directory | Reads the header and the flags' values to tell whether Claude can continue a session by itself there; never writes it |
| Local Code transcripts | `~/.claude/projects` | Reads; writes only new copies when continuing, and side files after Claude's own fork |
| Sidebar cards | `claude-code-sessions/` in each data directory | Reads and writes, with backups |
| Desktop settings | `claude_desktop_config.json`, Local Storage, IndexedDB | Writes selected keys (Local only, the settings merge, Auto-continue above) only in closed windows, with backups |
| Cowork tasks | `local-agent-mode-sessions/` | Reads only; a continued task gets a new task with copied history and files |
| History-suppression records | Transcripts | Never writes, edits or removes them |

## Boundaries

- **No network.** No code in the app or CLI opens a connection. Links it hands to macOS (`claude://` to a Claude window, `https://github.com/…` for a problem report) are opened by macOS in the app the user chose; Baton sends nothing itself. When moved work brings a group in Claude's sidebar that is new to the destination account, Baton sets Claude's own `|migrate` marker, so Claude syncs that group's name and id to the owner's own account as it does for a group made by hand; nothing else is uploaded ([ADR 0002](adr/0002-no-network-code.md#amendment-2026-09-29-a-new-group-follows-the-work)).
- **No privilege.** No administrator rights, no helper tools, no macOS permissions such as Accessibility, Automation or Full Disk Access. The one prompt it may show is macOS asking whether Baton may post notifications, the first time a window has room again after a limit; declining keeps that notice in Baton's window. It runs as the user and touches only the user's files.
- **Claude's own code.** Every window runs Anthropic's signed code; the app copy differs only by a Finder custom icon. It passes `codesign --verify` and Gatekeeper; `codesign --verify --strict` flags the added icon file. Nothing is injected, patched or preloaded. Baton copies an app into a profile only when its signature meets Anthropic's requirement: bundle id `com.anthropic.claudefordesktop`, signed with a Developer ID of Anthropic's team `Q6L2SF6YDW`. To find Claude Desktop it looks in `/Applications`, then `~/Applications`, and only then at the other copies Launch Services knows, never one on a read-only disk such as the disk image Claude comes on, and takes the first one signed that way; a lookalike, such as a newer "Claude" in Downloads, is passed over. When the only Claude it finds isn't signed that way, Baton doesn't open it as the main window or register it for `claude://` links at start, and says so; `baton doctor` says so too.
- **Closed-window writes.** Settings, interface stores, the IndexedDB pin record, auto-continue entries and Local only keys are written only while that window's process is not running, checked right before the write. The LevelDB writer refuses to write while another process holds the database's `LOCK`, and only ever adds a new log file.
- **Quitting windows.** Baton asks a Claude window to quit, as the Dock's Quit does, only when no Claude Code process lives in it: the window at its limit before its work moves, and an idle window the work moves to, so that it restarts with the moved sessions. It never forces one of them and never quits a window where Claude Code works; a window that doesn't quit within 20 seconds is left open. The one exception is a copy of a profile's app started from its Dock icon without the profile's data, which runs on the main app's data: it is asked to quit, and force-quit after 10 seconds only when no Claude Code process runs under it; with Claude Code work under it, it is never forced, and the profile opens once it is gone. Each decision is logged.
- **Backups before changes.** A replaced or removed card or settings file is copied into `Backups/<date>/` first. A settings file linked into place, say from a dotfiles folder, stays a link: the file it leads to is backed up as content and written, with its own permissions. A Claude window's own settings files go through a link only when it leads to a file inside that window's data folder: a link to anywhere else, such as a dotfiles folder or the main app's config, is left as it is by the settings and interface merges, Local only and Auto-continue, since another window may use that file while this one is closed. Local only and Auto-continue say so once. Removals move to the Trash; nothing is deleted outright except Baton's own unfinished copies, such as an app copy or shared setup left half-copied when Baton stopped, which only repeat what is in place or in a backup. `config.json`, which holds sign-in data, is never copied: its three appearance keys are edited in place with the file's permissions kept.
- **Account separation.** A card copied into another account's window drops that source account's Remote Control, connector and grant fields; folder rules keep a folder's work out of accounts they do not allow, and fail closed when the rules or an account's email cannot be read. Account-owned workers never cross accounts.
- **No inherited Claude settings.** The app and `baton` first remove every environment variable whose name starts with `CLAUDE` or `ANTHROPIC_` from their own process (`InheritedEnvironment.scrub()`), so a window they open never picks up another account's key, endpoint, model or config folder from the terminal or Claude Code session that started Baton. Baton itself reads none of them; the only variables it reads are `BATON_DEMO`, `BATON_DEMO_SHEET` and `BATON_DEMO_SNAPSHOT`.

## Data the app creates

Everything lives in `~/Library/Application Support/Baton`, or, for an install from before 1.0, in `~/Library/Application Support/Claude Profiles`, which keeps that name because Claude's own data points into it (see [ADR 0007](adr/0007-baton-rename.md)). It is readable only by the user: the profile list, folder rules, merge baselines and sync records (hashes and file stamps, not values), backups, copies-and-carry manifests, Local only's previous values, the handovers of the last week with what a waiting one still has to write (`handovers.json`: card names, session ids and titles, groups and pins), the replaced pin record of a window that received moved work (`Backups/<date>/Layout/`), and prepared Cowork continuations (`Handoffs/`, mode `0700`, moved to the Trash after 30 days). Backups can contain MCP definitions and other private setup. In a Claude window it writes one marker of Claude's own: `ccd-sync-pending:ccd/dframe-store` = `<account>/<org>|migrate` in Local Storage, only when moved work brings a group new to that account.

## Problem reports

The report is built from facts the app already shows, then redacted: home folder, user name, emails, account and organization ids (hashed with a salt made per report and kept only in memory), profile labels and folder names. Session titles, transcripts, card contents and token-shaped strings are never included. The user sees the exact text first; the app copies it, saves it or opens GitHub's form in the browser, and never submits it.

## The release

Release builds are universal, signed with a Developer ID and the hardened runtime, notarized and stapled, and published with `SHA256SUMS.txt` and a GitHub build-provenance attestation:

```sh
shasum -a 256 -c SHA256SUMS.txt
gh attestation verify Baton-v1.0.0.zip -R trukhinyuri/Baton
spctl --assess --type execute -vv "/Applications/Baton.app"
```

A release candidate, such as 1.0.0-rc.1, is published the same way but signed ad hoc and not notarized, as a GitHub prerelease: the first two commands apply to it, and `spctl` rejects it. A build you make yourself is signed ad hoc, which is enough for your own Mac.
