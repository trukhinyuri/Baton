# Releasing

Pushing a `v<version>` tag runs `.github/workflows/release.yml`: it tests, builds the universal app, signs it with a
Developer ID, notarizes and staples it, and publishes the ZIP with `SHA256SUMS.txt` and a build-provenance
attestation. Its last job, `tap`, then points the Homebrew tap's `Casks/baton.rb` at the new version and sha256 by
running `.github/workflows/bump-cask.yml`. That job needs the `HOMEBREW_TAP_PAT` secret; without it the job is skipped
with a warning. A release published by the workflow starts no other workflow on its own, so `bump-cask.yml` is never
triggered by the release event: if the `tap` job was skipped or failed, run **Actions → Bump Homebrew cask → Run
workflow** with the tag.

## Before the first tag

The README offers Homebrew as the main way to install, so a final release is tagged only when all three of these are
in place. Without notarization there is no final tag: Homebrew disables a cask that fails Gatekeeper, and everyone who
downloads the ZIP would have to override macOS to open it. A release candidate is the exception; see
[Release candidates](#release-candidates).

1. **The repository is `trukhinyuri/Baton`.** Rename it on GitHub first; GitHub redirects the old URLs. The cask,
   the README badges, the issue links in the app and `scripts/product.env` already point there.
2. **The tap exists:** `trukhinyuri/homebrew-tap`, set up by hand as
   [packaging/homebrew/README.md](../packaging/homebrew/README.md#setting-up-the-tap) describes: `cask_renames.json`,
   no `Casks/claude-profiles.rb`, and no `Casks/baton.rb` until the first release adds it with the real sha256.
3. **Signing and notarization secrets are set** in the repository's Actions secrets: `MACOS_CERTIFICATE` (a
   Developer ID Application certificate as a base64 `.p12`), `MACOS_CERTIFICATE_PWD`, `KEYCHAIN_PASSWORD`,
   `APPLE_TEAM_ID`, `AC_API_KEY_ID`, `AC_API_ISSUER_ID`, `AC_API_KEY` (an App Store Connect API key as a base64
   `.p8`) and `HOMEBREW_TAP_PAT`. `scripts/set-release-secrets.sh <certificate.p12> <AuthKey_KEYID.p8> <team id>
   <key id> <issuer id>` checks the certificate and sets all of them through the GitHub CLI without showing a value;
   it asks for the `.p12` password and the tap token. With `MACOS_CERTIFICATE` missing the workflow stops before building and publishes
   nothing. Only a run started by hand for the tag with `allow_unsigned` ticked publishes an ad-hoc signed, not
   notarized build, with a note saying so in the release, and leaves the tap unchanged.

## Release candidates

A release candidate goes out before the signed release, unsigned (ad-hoc signed, not notarized): `1.0.0-rc.1` comes
before `1.0.0`.

1. Set `VERSION` to `<major.minor.patch>-rc.<N>`, such as `1.0.0-rc.1`, and head its `CHANGELOG.md` entry
   `## 1.0.0-rc.1 — 2026-09-29`. The app's `CFBundleShortVersionString` and `CFBundleVersion` get the numbers only
   (`1.0.0`); `BatonVersion` in its `Info.plist` holds the full version, which `baton --version` and the problem report
   show. The ZIP is `Baton-v1.0.0-rc.1.zip`.
2. Run the green bar as for any release (step 4 below), then tag and push the tag: `git tag v1.0.0-rc.1 && git push
   origin v1.0.0-rc.1`. Without the signing secrets that run stops before building.
3. Run the workflow by hand for the tag: **Actions → Release → Run workflow**, pick the tag, tick `allow_unsigned`.
   It publishes a GitHub prerelease, never marked Latest, titled "Baton 1.0.0-rc.1 — first leg, release candidate",
   with a note on how to open a build that isn't notarized (Open Anyway in System Settings → Privacy & Security, or
   `make install`).
4. The `tap` job is skipped: the cask follows signed final releases only, and `bump-cask.yml` refuses a `-rc.` tag.

## Each release

1. Set `VERSION` to the new version. Give its `CHANGELOG.md` entry the release date in the heading, like the entries
   before it: `## 1.0.0 — unreleased` becomes `## 1.0.0 — 2026-10-05`. The workflow refuses a tag that doesn't match
   `VERSION` or whose heading has no date.
2. Check the release title for the version in `docs/launch/repo-metadata.md` and the workflow's `case`.
3. Make sure the screenshots in `docs/images` show the current app: after `make app`, run `scripts/screenshots.sh`,
   which draws them from the sample data ([TESTING.md](TESTING.md#checking-a-build)), and look at each one.
4. Run the green bar locally: `make test`, `swift build -Xswiftc -warnings-as-errors`,
   `swift format lint -r --strict Sources Tests Package.swift`, `scripts/check-docs.sh`, `scripts/check-repo.sh` and
   `scripts/check-cask.sh`, then `make app verify`.
5. Commit, then tag and push the tag: `git tag v1.0.0 && git push origin v1.0.0`.
6. When the workflow finishes, check the release: the ZIP, `SHA256SUMS.txt`, the attestation, the notes and the
   title. Check that the `tap` job ran (not skipped), that the tap's `Casks/baton.rb` has the new `version` and the
   sha256 from `SHA256SUMS.txt`, that its `cask_renames.json` still sends `claude-profiles` to `baton` and that it has
   no `Casks/claude-profiles.rb` (the job fails if either is wrong). Then install it on a Mac that doesn't have Baton:
   `brew install --cask trukhinyuri/tap/baton`.
