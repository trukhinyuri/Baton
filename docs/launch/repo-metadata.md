# Repository metadata

What GitHub and Homebrew show about Baton outside the README. GitHub keeps the About text and topics in the
repository settings, not in a file, so they live here and are set by hand; the release title is set by
`.github/workflows/release.yml`, and the Homebrew description by the cask.

## GitHub About

Description:

> Run several Claude Desktop accounts side by side on one Mac and hand a local conversation from one of your own windows to another. Not affiliated with Anthropic.

Website: none (the README is the home page).

Topics (suggested): `macos`, `macos-app`, `menu-bar-app`, `swift`, `swiftui`, `claude`, `claude-desktop`,
`claude-code`, `multi-account`, `homebrew-cask`

## Release title

`Baton 1.0.0 — first leg` for 1.0.0 (`Baton 1.0.0-rc.1 — first leg, release candidate` for its release candidate); later releases are `Baton <version>` unless the workflow's `case` gives them a
name of their own. The release notes are the version's CHANGELOG entry. Its heading reads `## 1.0.0 — unreleased`
until the release and must carry the release date, like the entries before it (`## 1.0.0 — 2026-10-05`), before the
tag is pushed; the workflow refuses a tag whose heading has no date. The steps are in [RELEASING.md](../RELEASING.md).

## Homebrew

`desc "Run one Claude Desktop window per account and hand sessions between them"`, in
`packaging/homebrew/Casks/baton.rb`.
