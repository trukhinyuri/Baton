# Homebrew

`Casks/baton.rb` is the source of the cask published in the `trukhinyuri/homebrew-tap` repository. The tap is set up
by hand once (below). From then on the release workflow (`.github/workflows/bump-cask.yml`) rewrites only `version`
and `sha256` in the tap's `Casks/baton.rb`, and only for a build that passes Gatekeeper, because Homebrew disables
casks that do not. If the tap has no `Casks/baton.rb` yet, the workflow copies this one; it never copies
`cask_renames.json` and never removes anything from the tap.

Check the cask locally with `scripts/check-cask.sh`, which runs `brew style` and `brew audit --cask --new --strict` in
a throwaway tap and removes the tap afterwards. It installs nothing. Until the `trukhinyuri/Baton` repository and its
first release exist, the audit reports their URLs as not found; that part passes only after the release.

## Setting up the tap

Do this once, before the first release tag ([RELEASING.md](../../docs/RELEASING.md)):

1. Create the public repository `trukhinyuri/homebrew-tap`.
2. Copy `Casks/baton.rb` to `Casks/baton.rb` in the tap, and `cask_renames.json` to the tap's root. The renames file
   sends anyone who installed the cask under its old name, `claude-profiles`, to `baton` on their next `brew upgrade`.
3. If the tap ever had `Casks/claude-profiles.rb`, remove it in the same commit: Homebrew follows `cask_renames.json`
   only once the old cask is gone.
4. Create a fine-grained token that can write the tap's contents and nothing else, and save it as the
   `HOMEBREW_TAP_PAT` Actions secret of `trukhinyuri/Baton`.
5. Check it on a Mac: `brew info --cask trukhinyuri/tap/baton`.

## What the cask removes

`zap` removes only the app's preferences, caches and the old app copies in `AppBackups`, in
`~/Library/Application Support/Baton` and in `~/Library/Application Support/Claude Profiles`, the data folder's name
for anyone who started with Claude Profiles. It never removes `Profiles/` (each window's sign-in), `Backups/`, the
launchers in `~/Applications/Baton` or `~/Applications/Claude Profiles`, `~/.claude` or Claude's own data in
`~/Library/Application Support/Claude`. Baton renames its launchers folder in `~/Applications` itself and never moves
its data folder ([ADR 0007](../../docs/adr/0007-baton-rename.md)); the cask doesn't touch either.
