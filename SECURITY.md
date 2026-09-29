# Security

Baton runs locally, has no network code, and never reads sign-in credentials or tokens. [docs/SECURITY-MODEL.md](docs/SECURITY-MODEL.md) describes what the app can reach and what it never does.

## Reporting a problem

Report it privately through a [GitHub security advisory](https://github.com/trukhinyuri/Baton/security/advisories/new), not in a public issue. I aim to respond within a week. Please give me time to publish a fix before you disclose it; the advisory credits you unless you would rather not be named.

## Supported versions

| Version | Security fixes |
|---|---|
| The latest release | Yes |
| A release candidate, such as 1.0.0-rc.1 | Until its final release is out; then update to that |
| Claude Profiles 0.x | No; upgrade to Baton |

## In scope

Anything that breaks the [boundaries](docs/SECURITY-MODEL.md#boundaries) Baton promises, for example:

- Baton reads, copies or sends a sign-in token, cookie or Keychain item, or opens a network connection.
- A window's settings or data are written while that window is running.
- A user's file is replaced or removed without a backup, or deleted instead of moved to the Trash.
- A session, connector or Remote Control field of one account reaches a window that account separation or a folder rule should keep it out of.
- The problem report leaks something it says it replaces or leaves out.
- A way to use Baton to get around how Anthropic meters usage: report it privately too, so it isn't spread before it is fixed.

## Out of scope

- Problems in Claude Desktop or Claude Code that also happen without Baton: report them to Anthropic under its [responsible disclosure policy](https://www.anthropic.com/responsible-disclosure-policy).
- Attacks that need someone who can already run code as you or change your files: they could change Baton too.
