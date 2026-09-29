# 0008. Work follows the limit

Status: accepted, 2026-09-29

## Context

When an open window reached its limit, the user had to open **Continue work…**, pick sessions, pick a window and wait while each session was imported by a `claude://` link. On 29 September 2026 that went wrong in several ways at once: a folder rule silently kept 19 sessions out of every other window, 42 cards marked by Remote Control stayed with their window long after Remote Control could reach them, a group of 64 sessions and 15 pins stayed behind, the 8 sessions the limit cut mid-turn didn't continue, and a link into a window that had not loaded a card imported it under a new id, which breaks sessions that message each other by id. The owner wants the handover to happen by itself, like magic, with one line saying what happened and no sheet of choices.

## Decision

When an open window reaches its limit while the user works there, Baton moves its work by itself (`baton handover auto off` turns this off; `baton handover` does it by hand):

- **Where.** The signed-in window with the most room, by four times its weekly usage plus its five-hour usage, that the folder rules of the sessions to resume allow; a closed or idle window is preferred when it is within 40 points of the best.
- **Same session once its window is closed.** A session moves as itself, with its card, group and pin, only once the window at its limit is closed, so no session runs in two windows. A window where Claude Code works is waited for, up to 10 minutes, then closed; if it still works then, or stays open, every session open there continues as a copy ([amendment](#amendment-2026-09-29-idle-processes-and-a-reset-soon)).
- **A reset soon is waited for.** When Claude's own reset time for the window's limit is within 30 minutes, nothing moves: the line says it is at its limit until then and that work continues there then, and Claude's own auto-continue resumes the cut sessions there.
- **Groups and pins follow.** The moved sessions' groups, pins and pin order are written into the destination while it is closed. A group new to the destination's account is added with Claude's own `|migrate` marker, so Claude syncs that group's name and id to the owner's own account, as it does for a group made by hand ([ADR 0002 amendment](0002-no-network-code.md#amendment-2026-09-29-a-new-group-follows-the-work)).
- **Cut sessions continue.** Claude's own auto-continue is turned off for the moved sessions in the window at its limit and seeded, with its reset passed, in the destination; Baton then shows each cut session in turn so Claude continues it. When Claude can't continue them by itself there, they are opened and named.
- **Nothing is imported by link.** Links go only to a window started after its cards were shared. A busy destination is never interrupted: it restarts once nothing works there, checked every 10 seconds, and the wait survives a restart of Baton.
- **Remote Control decides from Claude's own state.** A card marked by Remote Control stays with a window only while that window's `remote-control-state.json` serves its folder or the session is live there; copies never carry Remote Control's keys ([ADR 0006 amendment](0006-local-only-by-default.md#amendment-2026-09-29-pinned-folders-are-emptied-too)).
- **Nothing is hidden.** The one line names what stayed and why: a folder rule, Remote Control, copies, sessions that didn't resume. `baton doctor` lists the rest.

The **Continue work…** sheet is the same operation by hand: one list of what moves, one button to the window with the most room, and a small **Change** link.

## Consequences

- Claude Code processes stay alive for hours in a running window, idle; they end when the window quits, so they don't make copies. A handover may take up to 10 minutes longer while the window at its limit finishes its current step. When it doesn't finish in time, every session open there continues as a copy, and the window is closed later, once nothing works there, never forced. A cut session still open there, with its auto-continue on there, keeps running there and continues there at the reset: its copy is made in the destination but never seeded or resumed, so one cut turn never continues twice, and the line names it.
- A busy destination may wait long; the ranking's preference for closed or idle windows avoids most waits.
- Whether a seeded auto-continue fires depends on a server flag whose cache key isn't known yet. Baton seeds and then watches: a session that didn't continue is named, never assumed.
- Revisit if Claude Desktop hands sessions between accounts itself, locks sessions across windows, or changes how its sidebar store and auto-continue entries are kept.

## Amendment 2026-09-29: idle processes and a reset soon

Measured on this Mac the same evening: Claude Desktop keeps one Claude Code process alive for every session opened since it started, for hours, whether or not anything runs. A window at its limit had 30 of them, and 27 had no child process and said `"status": "idle"` in Claude Code's registry. Counting any live process as work kept every source open and made nearly every session a copy, which breaks sessions that message each other by id.

Measured again later that evening, 10 of that window's 30 processes counted as working by a registry `"busy"` alone or by any child process, most of them left over: `"busy"` set hours before with the transcript quiet since, and a `shasum` waiting on its input for 3.5 hours. Counted so, that window would never close at a limit. One of the busy ones ran a workflow: its own transcript had been quiet for 13 minutes while its workflow agents' transcripts were written every few seconds.

- **Working, not live.** A Claude Code process works when its session's transcript, or one of its subagents' or workflow agents', was written in the last 60 seconds, when the registry says `"status": "busy"` and set it in the last 10 minutes, or when it has a descendant started in the last 30 minutes (a shell, a tool, a background task or a Monitor). A direct child that already ran 10 seconds after the process started is a server started with the session and doesn't count. Older descendants with a quiet transcript don't count either; they end when the window quits. A window is busy only while one of its processes works.
- **Nothing moves as itself while its window is open.** An idle process wakes when a sibling session messages its session by id, the user types there, or a timer fires, so a session moved as itself out of an open window could run in two. A busy source is waited out: checked every 10 seconds for up to 10 minutes, while the line says, for example, "PAY finishes its current step, then your work moves to BRAVO." Then it is asked to quit, never forced; its idle processes end with it and every session moves as itself. If it still works after 10 minutes, or stays open because Claude asks something, every session open there continues as a copy, as before, and the line says so.
- **A reset soon.** When the source's binding limit has an exact reset time (Claude's own) in the future within 30 minutes, Baton doesn't hand over; the line says, for example, "PAY is at its limit until 23:40; work continues there then." An estimated reset time, a time already past, or none at all is handed over as before.
