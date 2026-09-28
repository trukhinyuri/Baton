# 0002. The app has no network code

Status: accepted

## Context

Claude Profiles sits next to accounts, transcripts and settings. Any network code, even an update check or crash reporter, would make it a party that could move that data, and would need its own privacy story.

## Decision

The app and the CLI make no network requests: no telemetry, no update check, no crash upload and no call to Anthropic. Updates come from Homebrew or a source build. **Report a problem** prepares text the user reviews and opens GitHub's issue form in the user's browser; the app itself sends nothing.

## Consequences

- Nothing to disclose beyond local file access, and an easy claim to audit: no `URLSession`, sockets or web views in `Sources/`.
- Usage figures come only from what Claude Desktop records locally, so a closed window's figure can be old. The UI shows each figure's age.
- Users learn about new versions from Homebrew or the release page.
- Revisit only with a user-visible, opt-in feature whose value outweighs the loss of this guarantee.
