# 0006. Local only is on by default

Status: accepted

## Context

Baton shares local work between accounts on one Mac. Remote Control connects a window's sessions to its Anthropic account, and a session reachable through one account's Remote Control while it is open under another may be what makes Claude fork it or add history suppression; that is suspected, not confirmed. The owner decided that 1.0 covers local sessions only.

## Decision

In every managed window, Local only sets `ccRemoteControlDefaultEnabled` to false, and `remoteControlStayReachable` to false where that key exists (and, since the amendment below, empties `remoteControlPinnedFolders`). It writes only while the window is closed, after a dated backup, keeps every other byte of the file, and records the previous values so turning it off restores them. It is switched from the command line, for every window or one (`baton local-only on|off [PROFILE|main]`); the app has no switch and only shows each window's state in its status sheet. It never touches local scheduled tasks, waking the Mac, the user's own Cowork and permission choices, organization-managed preferences, internal keys, sign-in data or servers. Stopping the agent from moving a session to the cloud is a separate opt-in, because it lives in `~/.claude/settings.json`, which every window shares.

## Consequences

- Cloud features that cannot be switched off locally, such as Claude's **Move to cloud** button, the Chat tab and connectors, are named in the "won't follow" list and the README rather than claimed as covered.
- A user who turns Remote Control back on inside Claude sees it switched off again once that window is closed while Baton runs or when Baton next opens it; until then the window's status lists it under "Waiting for a restart".
- A Claude version that drops one of these keys gets no write; `baton local-only status` says Local only is not available in it, and `baton doctor` names the missing key.
- Revisit if Claude Desktop offers a documented per-window setting, or once Remote Control across accounts is known not to cause forks.

## Amendment 2026-09-29: pinned folders are emptied too

A window with both switches off still kept serving Remote Control for the folders pinned in its settings
(`remoteControlPinnedFolders`), so Local only now also empties that list where Claude wrote it, with the same
closed-window rule, dated backup and record. Turning Local only off puts the earlier list back only where the list is
still empty; a list the user changed inside Claude stays theirs. Local only's record is still no proof that Remote
Control is off in a window: Baton reads Claude's own Remote Control state before it treats a session as out of
Remote Control's reach.
