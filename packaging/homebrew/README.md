# Homebrew

`Casks/baton.rb` is the source of the cask published in the `trukhinyuri/homebrew-tap` repository.
The release workflow (`.github/workflows/bump-cask.yml`) copies it into the tap on the first release and then
rewrites only `version` and `sha256`, and only for a build that passes Gatekeeper, because Homebrew disables
casks that do not.

Check it locally with `scripts/check-cask.sh`, which runs `brew style` and `brew audit --cask --new --strict` in
a throwaway tap and removes the tap afterwards. It installs nothing.

`cask_renames.json` goes into the tap's root, and `Casks/claude-profiles.rb` out of it, so `brew upgrade` moves
everyone who installed the cask under its old name, `claude-profiles`, to `baton`.

`zap` removes only the app's preferences, caches and the old app copies in `AppBackups`. It never removes
`Profiles/` (each window's sign-in), `Backups/`, the launchers in `~/Applications/Claude Profiles`, `~/.claude`
or Claude's own data in `~/Library/Application Support/Claude`.
