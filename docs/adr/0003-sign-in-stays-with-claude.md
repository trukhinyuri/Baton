# 0003. Sign-in stays inside Claude's own flow

Status: accepted

## Context

Baton's own rule is that sign-in belongs to Claude: Baton offers no Claude sign-in of its own and never collects, stores or passes on Claude credentials or session tokens. You sign in yourself, with your own subscription, inside the Claude app's own sign-in flow. For what Anthropic allows, its [Consumer Terms](https://www.anthropic.com/legal/consumer-terms) and [Usage Policy](https://www.anthropic.com/legal/aup) are the source; this record does not restate them.

Google sign-in in Claude Desktop finishes in the browser and returns through a `claude://` link. macOS delivers that link to the registered copy of Claude, which is the main app, so a new profile window never receives it.

## Decision

Baton never reads, stores or forwards credentials, tokens, cookies or the Keychain, and never sees the sign-in link. While one profile window signs in, it changes only which app copy Launch Services has registered for `claude://` (`lsregister`), and gives the links back to the main app once that window is signed in, after 15 minutes, or if it never started. The link travels from macOS straight to Claude.

Its only reads of Claude's `config.json` are the account id and three appearance keys; it edits those keys in place, preserving the file's permissions, and never copies or backs up that file.

## Consequences

- Each window's sign-in is Claude's own, with Anthropic's protections intact.
- A sign-in interrupted at the wrong moment can leave links routed to a profile copy. The app restores the main app at its next start, and the README gives the one-line fix.
- Revisit if Claude Desktop changes its sign-in return path.
