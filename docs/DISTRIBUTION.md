# macOS distribution and permission continuity

Claude Profiles can build locally without an Apple developer account. Those builds use an **ad-hoc signature** and are not notarized. macOS may require first-launch approval, and updating the app may invalidate a previous window-access grant. The app's contextual permission screen helps the user approve the installed copy; it cannot grant its own privileges or guarantee that macOS retains a grant.

For public distribution, the optional pipeline below uses a Developer ID Application identity and Apple notarization. A stable bundle identifier and signing team let macOS recognize successive versions as the same app. Apple explains why an ad-hoc designated requirement instead depends on the particular build in [TN3127: Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements). The scripts let `codesign` generate its normal designated requirement. They never weaken it or reset privacy settings.

**Implementation status:** the distribution scripts have been tested with fake tools for success and failure handling. No Developer ID identity or notary credentials were available for a real signed release during this work. Do not describe a release as notarized, or claim that permissions survive its updates, until the actual artifact has passed the checks below. Current ad-hoc releases remain ad hoc.

## Local development

The normal source-build path is unchanged:

```sh
scripts/build-app.sh
sh scripts/install-app.sh
```

The build prints its ad-hoc status. `CODESIGN_IDENTITY` alone now selects strict Developer ID mode and also requires the expected `APPLE_TEAM_ID`; it no longer accepts an unchecked distribution identity. Setting `CLAUDE_PROFILES_SIGNING_MODE=developer-id` explicitly makes this choice clear.

## Developer ID build on a maintainer's Mac

The maintainer must already have a valid **Developer ID Application certificate and its private key** in a keychain accessible to `codesign`. This project does not enroll an Apple account, create credentials, or purchase membership.

```sh
CLAUDE_PROFILES_SIGNING_MODE=developer-id \
CODESIGN_IDENTITY='Developer ID Application: YOUR ORGANIZATION (YOURTEAMID)' \
APPLE_TEAM_ID=YOURTEAMID \
scripts/build-app.sh
```

Replace the placeholders with the actual identity and ten-character team ID. `CODESIGN_IDENTITY` may be the certificate's SHA-1 fingerprint to select it unambiguously. For a dedicated keychain, also supply `CODESIGN_KEYCHAIN=/absolute/path/to/signing.keychain-db`; the scripts do not change the login keychain or its search-list configuration.

Both the bundled helper and manager receive hardened runtime and a secure timestamp. Signing happens from the inside out; no `--deep` signing is used. Verification requires the Apple Developer ID Application certificate type, expected team, fixed manager identifier, runtime flag, timestamp, and valid nested signatures. A missing identity, wrong team, invalid signature, or signing failure stops the build. It never retries with ad-hoc signing. These preparations follow [Apple's notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Notarize and package

First store authorized notary credentials in a keychain profile using Apple's `xcrun notarytool store-credentials`. Use its interactive prompts or your organization's established credential handling; never put private keys or passwords in the repository. This script consumes an existing profile:

```sh
APPLE_TEAM_ID=YOURTEAMID \
NOTARY_KEYCHAIN_PROFILE=claudeprofiles-release \
sh scripts/notarize-app.sh \
  'build/Claude Profiles.app' 'build/ClaudeProfiles-notarized.zip'
```

If the profile is in a dedicated keychain, set `NOTARY_KEYCHAIN` to its absolute path. The script verifies the signed input, submits a temporary ZIP, waits up to 20 minutes, and requires Apple's result to be exactly `Accepted`. It then staples and validates the ticket, verifies the code again, checks Gatekeeper assessment, and packages the stapled app into the final ZIP. It does not publish anything. The ZIP itself cannot be stapled. See [Apple's custom notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

The submission result and available service log are retained in `build/notarization/`. Failure or timeout produces no distributable ZIP. A timeout does not cancel Apple's processing: inspect the saved submission ID with `notarytool info` before deciding whether another submission is needed. Existing output archives and result files are never silently replaced. Choose a new output path and `NOTARY_REPORT_DIR` for a separate run.

## GitHub release configuration

The existing release workflow still runs only for a pushed version tag. Configuring signing does not create a tag, merge a pull request, or publish an additional release on its own. Use a protected release workflow and restrict who can change it or push release tags before providing signing credentials.

Repository variables:

| Variable | Value |
| --- | --- |
| `MACOS_SIGNING_MODE` | `developer-id` to enable the signed path; unset or `ad-hoc` retains development distribution |
| `MACOS_SIGNING_IDENTITY` | Exact Developer ID Application name or certificate SHA-1 fingerprint |
| `APPLE_TEAM_ID` | Expected ten-character Apple signing team |

Repository secrets for the signed path:

| Secret | Content |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | Base64-encoded `.p12` containing the certificate and signing private key |
| `MACOS_CERTIFICATE_PASSWORD` | Nonempty password protecting that `.p12` |
| `APPLE_NOTARY_KEY_P8_BASE64` | Base64-encoded App Store Connect **team API key** authorized for notarization |
| `APPLE_NOTARY_KEY_ID` | API key ID |
| `APPLE_NOTARY_ISSUER_ID` | Team API key issuer UUID |

This workflow deliberately supports one CI authentication format: a team API key. Local keychain profiles may use any authentication method supported by `notarytool`. The private key, certificate, and password are never printed by these scripts. An isolated temporary keychain is created on the ephemeral runner, with access limited to signing tools; cleanup removes that keychain and temporary key files even if a later step fails. It does not import credentials into a user's login keychain.

When `developer-id` is selected, every required input must be present and all signing/notarization checks must pass before publication. Missing or rejected credentials do not produce an ad-hoc fallback release. In ad-hoc mode the release notes explicitly label the artifact as a development build and explain the approval limitation. The workflow retains non-secret notary diagnostic JSON as an Actions artifact.

## Acceptance before claiming a smooth update experience

1. Run `sh scripts/tests/distribution-tests.sh`. These fixtures prove fail-closed control flow, tool arguments, and packaging order; they do not prove an Apple certificate is valid.
2. Build with the real authorized Developer ID identity; run `verify-distribution.sh` with the expected `APPLE_TEAM_ID` and notarize successfully. Retain the submission result and Gatekeeper assessment.
3. Download the actual published ZIP through a browser on a clean supported Mac or a fresh test user, extract it, and check first launch with Gatekeeper enabled. Do not strip quarantine or disable security controls to pass this test.
4. Exercise the in-app window-access request, denial, later approval, selected Claude capture, and the unrelated features that should work without access.
5. Install a later build signed by the same team with the same bundle identifier. Check that the app can still capture after the update and that restoring access works if macOS or an administrator revoked it. Repeat on each supported macOS generation before promising broad compatibility.

Notarization does not preapprove Accessibility, Full Disk Access, automation, or any other permission. The signed manager also does not change Claude's own identity, account restrictions, or consent requirements. Downloaded manager releases, locally generated launchers, and Anthropic's Claude app copies are distinct artifacts; each remains subject to its own macOS checks.
