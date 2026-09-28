# 0005. Never bypass Claude's history suppression

Status: accepted

## Context

When a session is resumed under a different account, Claude Code may append a `history-suppression` record to its transcript and, in Claude Desktop, fork it into a new session. The record is Anthropic's safeguard that keeps one account's history out of another account's remote channels. Desktop's fork copies the transcript but leaves sub-agents, Workflow history and tool outputs behind, and drops Rewind snapshots from before the fork.

## Decision

Baton never writes, edits or removes `history-suppression` records, and its own copies keep them. After a fork made by Desktop, it adds the sidecar files the fork left behind to the new session, adding files only and never touching the old session. It does not restore pre-fork Rewind snapshots into the new session, and it says so instead of implying the whole session moved.

## Consequences

- A tainted session stays tainted, exactly as Claude ships it.
- Rewind before a Desktop-made fork works only in the original session. **Continue work…**, which makes its own copy, keeps Rewind checkpoints.
- If this approach is ever read as working around the safeguard, cross-account continuing of tainted sessions will be refused instead.
