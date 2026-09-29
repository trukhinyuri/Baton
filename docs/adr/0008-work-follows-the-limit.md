# 0008. Work follows the limit

Status: accepted, 2026-09-29

## Context

When an open window reached its limit, the user had to open **Continue work…**, pick sessions, pick a window and wait while each session was imported by a `claude://` link. On 29 September 2026 that went wrong in several ways at once: a folder rule silently kept 19 sessions out of every other window, 42 cards marked by Remote Control stayed with their window long after Remote Control could reach them, a group of 64 sessions and 15 pins stayed behind, the 8 sessions the limit cut mid-turn didn't continue, and a link into a window that had not loaded a card imported it under a new id, which breaks sessions that message each other by id. The owner wants the handover to happen by itself, like magic, with one line saying what happened and no sheet of choices.

## Decision

When an open window reaches its limit while the user works there, Baton moves its work by itself (`baton handover auto off` turns this off; `baton handover` does it by hand):

- **Where.** The signed-in window with the most room, by four times its weekly usage plus its five-hour usage, that the folder rules of the sessions to resume allow; a closed or idle window is preferred when it is within 40 points of the best.
- **Same session unless it works.** A session moves as itself, with its card, group and pin, unless a Claude Code process of it works in the window at its limit; then it continues as a copy. When nothing works there, that window is closed first, so no session runs in two windows ([amendment](#amendment-2026-09-29-idle-processes-and-a-reset-soon)).
- **A reset soon is waited for.** When the window's limit resets within 30 minutes, nothing moves: the line says it is at its limit until then and that work continues there then, and Claude's own auto-continue resumes the cut sessions there.
- **Groups and pins follow.** The moved sessions' groups, pins and pin order are written into the destination while it is closed. A group new to the destination's account is added with Claude's own `|migrate` marker, so Claude syncs that group's name and id to the owner's own account, as it does for a group made by hand ([ADR 0002 amendment](0002-no-network-code.md#amendment-2026-09-29-a-new-group-follows-the-work)).
- **Cut sessions continue.** Claude's own auto-continue is turned off for the moved sessions in the window at its limit and seeded, with its reset passed, in the destination; Baton then shows each cut session in turn so Claude continues it. When Claude can't continue them by itself there, they are opened and named.
- **Nothing is imported by link.** Links go only to a window started after its cards were shared. A busy destination is never interrupted: it restarts once nothing works there, checked every 10 seconds, and the wait survives a restart of Baton.
- **Remote Control decides from Claude's own state.** A card marked by Remote Control stays with a window only while that window's `remote-control-state.json` serves its folder or the session is live there; copies never carry Remote Control's keys ([ADR 0006 amendment](0006-local-only-by-default.md#amendment-2026-09-29-pinned-folders-are-emptied-too)).
- **Nothing is hidden.** The one line names what stayed and why: a folder rule, Remote Control, copies, sessions that didn't resume. `baton doctor` lists the rest.

The **Continue work…** sheet is the same operation by hand: one list of what moves, one button to the window with the most room, and a small **Change** link.

## Consequences

- Claude Code processes stay alive for hours in a running window, idle; only sessions working there when the limit is reached continue as copies, and the window is closed later, once nothing works there, never forced. A working session the limit cut whose auto-continue is on there keeps running there and continues there at the reset: its copy is made in the destination but never seeded or resumed, so one cut turn never continues twice, and the line names it.
- A busy destination may wait long; the ranking's preference for closed or idle windows avoids most waits.
- Whether a seeded auto-continue fires depends on a server flag whose cache key isn't known yet. Baton seeds and then watches: a session that didn't continue is named, never assumed.
- Revisit if Claude Desktop hands sessions between accounts itself, locks sessions across windows, or changes how its sidebar store and auto-continue entries are kept.

## Amendment 2026-09-29: idle processes and a reset soon

Measured on this Mac the same evening: Claude Desktop keeps one Claude Code process alive for every session opened since it started, for hours, whether or not anything runs. A window at its limit had 30 of them, and 27 had no child process and said `"status": "idle"` in Claude Code's registry. Counting any live process as work kept every source open and made nearly every session a copy, which breaks sessions that message each other by id.

- **Working, not live.** A Claude Code process works when it has a descendant started more than 10 seconds after it (a shell, a tool, a background task or a Monitor; a server started with the session doesn't count), when the registry says `"status": "busy"`, or when its session's transcript was written in the last 60 seconds. A window is busy only while one of its processes works. A session is carried as a copy exactly when it works in the source. A source where nothing works is asked to quit, never forced; its idle processes end with it and every session moves as itself. If it stays open because Claude asks something, every session still open there continues as a copy, as before.
- **A reset soon.** When the source's binding limit has a known reset within 30 minutes, Baton doesn't hand over; the line says, for example, "PAY is at its limit until 23:40; work continues there then." With no known reset time, it hands over as before.
- **Consequence.** A busy source stays open with its idle sessions moved as themselves; their idle processes there only hold the session open until Baton quits the window once nothing works there.
