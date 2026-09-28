# 0004. Share sidebar cards; copy a transcript only when two windows could write to it

Status: accepted

## Context

Local Claude Code transcripts live in `~/.claude/projects`, which every window already reads. What each window lists is a small per-account sidebar card that points at a transcript. Copying transcripts would duplicate history and split one conversation into several. Sharing one transcript between two windows that both write to it would corrupt it.

## Decision

Sharing copies only the cards, between the windows whose accounts may see them (folder rules decide), without the fields that belong to the source account. Continuing opens the same session in the destination window when nothing else is writing to it. When a running Claude Code process has the session open, or it had a message in the last 10 minutes, the session continues as a copy: a new session with the same history, sub-agents, Workflow history, tool outputs, file history and scratchpad notes. Cowork tasks, whose history depends on their original profile, continue as a new task with their history and files attached.

## Consequences

- One conversation stays one conversation in the common case, and nothing is duplicated.
- A copy is a fork: later messages in the two sessions diverge. The copy's title names where it came from.
- Deletions reach other windows only when all windows are closed, because a running Claude can write back a stale list.
- Revisit if Claude Desktop starts locking sessions across windows.
