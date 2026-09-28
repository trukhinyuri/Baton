# Changelog

## 0.3.0 — 2026-09-28

- **Continue work…** lists the local Code sessions, Project branches and Cowork tasks of every window, most recent first, with search. Pick one and a subscription to continue in; the one with the most weekly headroom is preselected and those at their limit are marked
- A Code session or Project branch opens as the same session in the chosen window, which is opened first if needed. The transcript is shared, so nothing is copied
- A Cowork task continues as a new task in the chosen window with a continuation prompt, its full history as `history.md` and copies of the files it was given and made. Nothing is sent: you review and send it there. What cannot be carried over (connectors, schedules, Project settings, files over the size limits) is listed in the history
- When an open subscription reaches its five-hour or weekly limit, a banner offers to continue its work in the subscription with the most headroom
- A conversation written to in the last minute is flagged as possibly still running; continuing a Code session then needs confirmation
- `claude-profiles conversations [--all]` and `claude-profiles continue <id|last> --to <profile> [--anyway]` do the same from the command line
- Continuing needs no macOS permissions: the chosen window receives a `claude://` link that only it handles
- A window that opens a conversation it had no card for makes its own card; the older copy in that window is backed up and retired, other windows don't get a second card for the same conversation, and deleting either card deletes the conversation
- Opening a profile no longer fails when sessions can't be shared first; the window opens and the problem is reported
- MCP servers, extensions and SSH connections are merged one by one, keeping what was added or changed only in a profile; SSH host trust stays with each profile
- App copies are rebuilt in a staging bundle, verified and swapped in atomically; the previous copy is restored if the new one fails verification
- A closed profile's sessions are shared right before it starts, so launchers don't depend on the app's next background sync
- The installer keeps the previous app as a ZIP in `~/Library/Application Support/Claude Profiles/AppBackups` (the three latest) instead of runnable `.previous-*.app` copies beside the app, and moves those left by 0.2.0 to the Trash

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
