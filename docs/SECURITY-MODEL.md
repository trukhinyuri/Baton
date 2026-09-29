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
| Auto-continue entries | `claude_desktop_config.json` → `preferences.epitaxyPrefs` → `autoResumeRateLimit.<account>` | Reads reset times; turns `optedIn` off for one session's entry in the closed window that session was continued from, after a backup; `baton doctor` lists each change |
| Local Code transcripts | `~/.claude/projects` | Reads; writes only new copies when continuing, and side files after Claude's own fork |
| Sidebar cards | `claude-code-sessions/` in each data directory | Reads and writes, with backups |
| Desktop settings | `claude_desktop_config.json`, Local Storage, IndexedDB | Writes selected keys (Local only, the settings merge, Auto-continue above) only in closed windows, with backups |
| Cowork tasks | `local-agent-mode-sessions/` | Reads only; a continued task gets a new task with copied history and files |
| History-suppression records | Transcripts | Never writes, edits or removes them |

## Boundaries

- **No network.** No code in the app or CLI opens a connection. Links it hands to macOS (`claude://` to a Claude window, `https://github.com/…` for a problem report) are opened by macOS in the app the user chose; Baton sends nothing itself.
- **No privilege.** No administrator rights, no helper tools, no macOS permissions such as Accessibility, Automation or Full Disk Access. The one prompt it may show is macOS asking whether Baton may post notifications, the first time a window has room again after a limit; declining keeps that notice in Baton's window. It runs as the user and touches only the user's files.
- **Claude's own code.** Every window runs Anthropic's signed code; the app copy differs only by a Finder custom icon. It passes `codesign --verify` and Gatekeeper; `codesign --verify --strict` flags the added icon file. Nothing is injected, patched or preloaded. Baton copies an app into a profile only when its signature meets Anthropic's requirement: bundle id `com.anthropic.claudefordesktop`, signed with a Developer ID of Anthropic's team `Q6L2SF6YDW`. To find Claude Desktop it looks in `/Applications`, then `~/Applications`, and only then at the other copies Launch Services knows, never one on a disk image or another read-only disk, and takes the first one signed that way; a lookalike, such as a newer "Claude" in Downloads, is passed over. `baton doctor` says when the Claude it uses isn't signed that way.
- **Closed-window writes.** Settings, interface stores and Local only keys are written only while that window's process is not running, checked right before the write. The LevelDB writer refuses to write while another process holds the database's `LOCK`, and only ever adds a new log file.
- **Backups before changes.** A replaced or removed card or settings file is copied into `Backups/<date>/` first. A settings file linked into place, say from a dotfiles folder, stays a link: the file it leads to is backed up as content and written, with its own permissions. Removals move to the Trash; nothing is deleted outright. `config.json`, which holds sign-in data, is never copied: its three appearance keys are edited in place with the file's permissions kept.
- **Account separation.** A card copied into another account's window drops that source account's Remote Control, connector and grant fields; folder rules keep a folder's work out of accounts they do not allow, and fail closed when the rules or an account's email cannot be read. Account-owned workers never cross accounts.
- **No inherited Claude settings.** The app and `baton` first remove every environment variable whose name starts with `CLAUDE` or `ANTHROPIC_` from their own process (`InheritedEnvironment.scrub()`), so a window they open never picks up another account's key, endpoint, model or config folder from the terminal or Claude Code session that started Baton. Baton itself reads none of them; the only variables it reads are `BATON_DEMO`, `BATON_DEMO_SHEET` and `BATON_DEMO_SNAPSHOT`.

## Data the app creates

Everything lives in `~/Library/Application Support/Baton`, or, for an install from before 1.0, in `~/Library/Application Support/Claude Profiles`, which keeps that name because Claude's own data points into it (see [ADR 0007](adr/0007-baton-rename.md)). It is readable only by the user: the profile list, folder rules, merge baselines and sync records (hashes and file stamps, not values), backups, copies-and-carry manifests, Local only's previous values, and prepared Cowork continuations (`Handoffs/`, mode `0700`, moved to the Trash after 30 days). Backups can contain MCP definitions and other private setup.

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
