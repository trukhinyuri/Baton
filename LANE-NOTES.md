# Lane D notes for the other lanes and W24

What lane D (build, CI, Homebrew, docs) assumed from other lanes, and what it left for integration.

## Lane C (app, CLI, reporting)

- **Issue form fields.** `.github/ISSUE_TEMPLATE/bug_report.yml` has these field ids: `what-happened` (textarea, required), `steps` (textarea), `diagnostics` (textarea, required), `reviewed` (required checkbox). GitHub issue forms are prefilled by field id, not by `body`, so **Open GitHub** should build
  `https://github.com/trukhinyuri/ClaudeProfiles/issues/new?template=bug_report.yml&title=<summary>&diagnostics=<report markdown or summary>`
  and put the user's own description in `what-happened=`. Check this in the Browser pane at W16 acceptance; if GitHub ignores the field params, fall back to `body=` and tell lane D to adjust the form.
- **Report headings.** The Diagnostics field's description names the report's `###` sections as `FeedbackReport` writes them on lane/c at c27e69b: Environment, Windows, Sessions check, Last sync, Recent errors, Log.
- **CLI spellings the README and CHANGELOG document:** `sync [--dry-run]`, `carry [--dry-run]`, `local-only on|off|status`, `report [--save PATH] [--open]`, `remove <profile>` refusing while the window runs (W13), `--version`. `continue --folder` no longer takes `--folder-only`. If a spelling changes, change README "Command line" too.
- **Repository slug in Swift.** `Views.swift` links `https://github.com/trukhinyuri/ClaudeProfiles#staying-within-anthropics-terms`, and the report URL will need the same slug. `scripts/check-docs.sh` fails if the README loses a heading that `Sources/` or `.github/` links to. Suggest one constant for the slug (for example in `BuildInfo` or `FeedbackReport`) so a rename touches one Swift line.
- **Screenshot.** `docs/images/continue-work.png` still shows a Project branch and **Copy handoff request**. The README no longer uses it; retake it with `CLAUDE_PROFILES_DEMO=1` after W18 and add it back under "Continue work in another window".

## Lane A (sharing)

- **LevelDB compatibility job.** CI runs `LEVELDB_COMPAT=1 swift test --filter LevelDBCompat` after `brew install leveldb`, which installs `leveldbutil` into `$(brew --prefix)/bin`. The W7 suite's name must contain `LevelDBCompat`, and it should skip when `LEVELDB_COMPAT` is not `1`.
- README and ARCHITECTURE describe W2–W4 as specified in the plan (folder rules gate sharing and fail closed; account-scoped fields dropped in cross-account copies; lineage wins over mtime; live sessions not overwritten).
- README "Known limitations" still says un-archiving does not stick. Remove that line in W24 if W5 lands.

## Lane B (transfer, Local only)

- README, ARCHITECTURE, ADR 0006 and the CHANGELOG describe W8–W13 as the plan specifies: `continue-copies.json` v2, `carried.json` in the state folder, `local-only.json` with prior values, Local only on by default and applied to main too while main is closed, `remoteControlStayReachable` only when present, "not supported by this Claude version" when a key is missing from `app.asar`, Claude found through Launch Services then `/Applications` then `~/Applications`. W24 should read these sections against the merged code.

## W24 (integration)

- **Strict lint and warnings.** CI reports `swift format lint` (config `.swift-format`: 4 spaces, 160 columns, semicolons and one-line multiple declarations allowed, as the code uses them) and `swift build -Xswiftc -warnings-as-errors` with `continue-on-error: true`. On this branch lint prints 823 lines. Remove the two `continue-on-error` lines to make them fail.
- **Release date.** CHANGELOG says `## 1.0.0 — unreleased`; `release.yml` refuses to publish until that line carries the date.
- **Hardened runtime.** `verify-build.sh` passes on this Mac, but the hardened app was not launched here, because a second running copy would start a second sync timer against real data. Launch it once in W25 after `install-app.sh`.
- **Not run:** the workflows (no push, and `act` is not installed); notarization (no Developer ID on this Mac: `security find-identity` finds 0 identities); `brew install` of the cask (forbidden on this Mac while the owner's copy is installed).
- **Homebrew audit.** `scripts/check-cask.sh` passes `brew style`. `brew audit --cask --new --strict` fails only on the download (404 until v1.0.0 is published). Pointed at the published v0.2.0 zip, it fails only on the Gatekeeper signature (needs Developer ID and notarization) and on homebrew/cask notability (does not apply to a personal tap).
- **Name and slug** live in: `scripts/product.env` (scripts and workflows), `packaging/homebrew/Casks/claude-profiles.rb`, README, SECURITY.md, CODE_OF_CONDUCT.md, docs/SECURITY-MODEL.md, `.github/ISSUE_TEMPLATE/*.yml`, `.github/CODEOWNERS`, and in Swift `Views.swift`, `Log.swift` (subsystem), `ProfileManager.swift` (launcher bundle ids).
