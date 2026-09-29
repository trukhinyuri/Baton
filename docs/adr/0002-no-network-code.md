# 0002. The app has no network code

Status: accepted

## Context

Baton sits next to accounts, transcripts and settings. Any network code, even an update check or crash reporter, would make it a party that could move that data, and would need its own privacy story.

## Decision

The app and the CLI make no network requests: no telemetry, no update check, no crash upload and no call to Anthropic. Updates come from Homebrew or a source build. **Report a problem** prepares text the user reviews and opens GitHub's issue form in the user's browser; the app itself sends nothing.

## Consequences

- Nothing to disclose beyond local file access, and an easy claim to audit: no `URLSession`, sockets or web views in `Sources/`.
- Usage figures come only from what Claude Desktop records locally, so a closed window's figure can be old. The UI shows each figure's age.
- Users learn about new versions from Homebrew or the release page.
- Revisit only with a user-visible, opt-in feature whose value outweighs the loss of this guarantee.

## Amendment 2026-09-29: a new group follows the work

Baton still makes no request. When work moves to another window and a group of the moved sessions in Claude's sidebar
is new to that window's account, Baton adds the group there and sets Claude's own `|migrate` marker
(`ccd-sync-pending:ccd/dframe-store`), so Claude itself syncs that group's name and id to the account at its next
start, as it does for a group the user makes by hand in that window. Only the owner's own accounts are involved, and
nothing else is uploaded: Claude leaves session ids, titles, pins and assignments of local sessions out of what it
syncs. The marker is set only when that window's sidebar store last synced with the same account and no marker is
pending already; otherwise the group stays local and Baton says which sessions may lose it. Pins get no marker.
