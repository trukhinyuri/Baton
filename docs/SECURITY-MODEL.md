# Security model

What Baton can reach, what it does with it, and what it never does. Report a weakness privately through a [security advisory](../SECURITY.md).

## Assets

| Asset | Where | Baton |
|---|---|---|
| Sign-in: tokens, cookies, Keychain items | Each data directory, the Keychain | Never reads, copies, backs up or forwards them |
| Account id | `config.json` → `lastKnownAccountUuid` | Reads this one key |
| Account email | Claude's local IndexedDB cache | Reads the email that belongs to the account id, nothing else |
| Usage | `plan-usage-history.json` | Reads the latest sample |
| Local Code transcripts | `~/.claude/projects` | Reads; writes only new copies when continuing, and side files after Claude's own fork |
| Sidebar cards | `claude-code-sessions/` in each data directory | Reads and writes, with backups |
| Desktop settings | `claude_desktop_config.json`, Local Storage, IndexedDB | Writes selected keys only in closed windows, with backups |
| Cowork tasks | `local-agent-mode-sessions/` | Reads only; a continued task gets a new task with copied history and files |
| History-suppression records | Transcripts | Never writes, edits or removes them |

## Boundaries

- **No network.** No code in the app or CLI opens a connection. Links it hands to macOS (`claude://` to a Claude window, `https://github.com/…` for a problem report) are opened by macOS in the app the user chose; Baton sends nothing itself.
- **No privilege.** No administrator rights, no helper tools, no macOS permissions (Accessibility, Automation, Full Disk Access). It runs as the user and touches only the user's files.
- **Unmodified Claude.** Every window runs Anthropic's signed code; the app copy differs only by a Finder icon, and its signature still verifies. Nothing is injected, patched or preloaded.
- **Closed-window writes.** Settings, interface stores and Local only keys are written only while that window's process is not running, checked right before the write. The LevelDB writer refuses to write while another process holds the database's `LOCK`, and only ever adds a new log file.
- **Backups before changes.** A replaced or removed card or settings file is copied into `Backups/<date>/` first. Removals move to the Trash; nothing is deleted outright. `config.json`, which holds sign-in data, is never copied: its three appearance keys are edited in place with the file's permissions kept.
- **Account separation.** A card copied into another account's window drops that source account's Remote Control, connector and grant fields; folder rules keep a folder's work out of accounts they do not allow, and fail closed when the rules or an account's email cannot be read. Account-owned workers never cross accounts.
- **No inherited Claude settings.** The app and `baton` first remove every environment variable whose name starts with `CLAUDE` or `ANTHROPIC_` from their own process (`InheritedEnvironment.scrub()`), so a window they open never picks up another account's key, endpoint, model or config folder from the terminal or Claude Code session that started Baton. Baton itself reads none of them; the only variables it reads are `BATON_DEMO`, `BATON_DEMO_SHEET` and `BATON_DEMO_SNAPSHOT`.

## Data the app creates

Everything lives in `~/Library/Application Support/Baton`, or, for an install from before 1.0, in `~/Library/Application Support/Claude Profiles`, which keeps that name because Claude's own data points into it (see [ADR 0007](adr/0007-baton-rename.md)). It is readable only by the user: the profile list, folder rules, merge baselines (hashes, not values), backups, copies-and-carry manifests, Local only's previous values, and prepared Cowork continuations (`Handoffs/`, mode `0700`, moved to the Trash after 30 days). Backups can contain MCP definitions and other private setup.

## Problem reports

The report is built from facts the app already shows, then redacted: home folder, user name, emails, account and organization ids (hashed with a salt made per report and kept only in memory), profile labels and folder names. Session titles, transcripts, card contents and token-shaped strings are never included. The user sees the exact text first; the app copies it, saves it or opens GitHub's form in the browser, and never submits it.

## The release

Release builds are universal, signed with a Developer ID and the hardened runtime, notarized and stapled, and published with `SHA256SUMS.txt` and a GitHub build-provenance attestation:

```sh
shasum -a 256 -c SHA256SUMS.txt
gh attestation verify Baton-v1.0.0.zip -R trukhinyuri/Baton
spctl --assess --type execute -vv "/Applications/Baton.app"
```

A build you make yourself is signed ad hoc, which is enough for your own Mac.
