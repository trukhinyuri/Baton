# 0001. Each window runs an APFS clone of the unmodified Claude Desktop

Status: accepted

## Context

Claude Desktop holds one signed-in account per data directory. Electron's `--user-data-dir` gives each process its own directory, but every process launched from `/Applications/Claude.app` shares one Dock icon and one bundle path, so windows cannot be told apart, and macOS reopens them without their arguments.

## Decision

Each profile runs its own copy of `Claude.app`, made with `clonefile(2)` so it shares disk blocks with the original. The only change is a Finder custom icon. No code, resource or entitlement is modified, and Anthropic's signature still verifies. A small launcher bundle per profile starts the copy with its data directory. Copies are rebuilt, staged and verified, whenever Claude Desktop updates.

## Consequences

- A labeled Dock icon per account, launchers that Spotlight finds, and nearly no disk cost.
- Claude's own code runs unchanged, so its sign-in, updates and safety checks apply as shipped.
- Every copy has the same bundle identifier, so `claude://` links need routing during sign-in ([0003](0003-sign-in-stays-with-claude.md)), and a copy opened without its launcher shows the main account; the app detects and reopens such a window.
- Revisit if Claude Desktop gains first-class multi-account support, or if Anthropic objects to icon-only copies.
