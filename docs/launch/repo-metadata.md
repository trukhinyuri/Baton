# Repository metadata

What GitHub and Homebrew show about Baton outside the README. GitHub keeps the About text and topics in the
repository settings, not in a file, so they live here and are set by hand; the release title is set by
`.github/workflows/release.yml`, and the Homebrew description by the cask.

## GitHub About

Description:

> Baton, a Mac app for Claude Desktop accounts: run several side by side on one Mac and hand a local conversation from one of your own windows to another. Not affiliated with Anthropic.

It starts with "Baton, a Mac app for Claude Desktop accounts" because other products and commands are called Baton
too, among them getbaton.dev; the README says right under its title that this one is not related to them.

Website: none (the README is the home page).

Topics (suggested): `macos`, `macos-app`, `menu-bar-app`, `swift`, `swiftui`, `claude`, `claude-desktop`,
`claude-code`, `multi-account`, `session-management`, `homebrew-cask`

Social preview: `docs/images/social-preview.png` (1280 × 640), uploaded under **Settings → General → Social
preview**. Without it, links to the repository show a card GitHub draws from the name and description.

## Repository settings

GitHub keeps these in the repository's settings, not in a file, so only the name is checked, by the release workflow.
Set them by hand before the first tag; [RELEASING.md](../RELEASING.md#repository-settings) has the whole list, including
the rename, private vulnerability reporting, branch protection and secrets. The ones that are about how the
repository looks:

- [ ] The About description, website and topics above.
- [ ] The social preview above.

## Release title

`Baton 1.0.0 — first leg` for 1.0.0 (`Baton 1.0.0-rc.1 — first leg, release candidate` for its release candidate);
later releases are `Baton <version>` unless the workflow's `case` gives them a name of their own. The release notes
are the version's CHANGELOG entry. Its heading must carry the release date, like the entries before it
(`## 1.0.0 — 2026-10-05`), before the tag is pushed; the workflow refuses a tag whose heading has no date. The 1.0.0
entry is the release candidate's entry renamed, so the release keeps its full notes. The steps are in
[RELEASING.md](../RELEASING.md).

## Homebrew

`desc "Run one Claude Desktop window per account and hand sessions between them"`, in
`packaging/homebrew/Casks/baton.rb`.
