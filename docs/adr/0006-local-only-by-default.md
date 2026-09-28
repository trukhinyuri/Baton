# 0006. Local only is on by default

Status: accepted

## Context

Baton shares local work between accounts on one Mac. Remote Control connects a window's sessions to its Anthropic account, and a session reachable through one account's Remote Control while it is open under another is the likely trigger for Claude's cross-account forks and history suppression. The owner decided that 1.0 covers local sessions only.

## Decision

In every managed window, Local only sets `ccRemoteControlDefaultEnabled` to false, and `remoteControlStayReachable` to false where that key exists. It writes only while the window is closed, after a dated backup, keeps every other byte of the file, and records the previous values so turning it off restores them. It is one switch, globally and per profile. It never touches local scheduled tasks, waking the Mac, the user's own Cowork and permission choices, organization-managed preferences, internal keys, sign-in data or servers. Stopping the agent from moving a session to the cloud is a separate opt-in, because it lives in `~/.claude/settings.json`, which every window shares.

## Consequences

- Cloud features that cannot be switched off locally, such as Claude's **Move to cloud** button, the Chat tab and connectors, are named in the "won't follow" list and the README rather than claimed as covered.
- A user who turns Remote Control back on inside Claude sees it switched off again at that window's next start, with a badge until then.
- A Claude version that drops one of these keys gets "not supported" and no write.
- Revisit if Claude Desktop offers a documented per-window setting, or once Remote Control across accounts is known not to cause forks.
