# Changelog

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
