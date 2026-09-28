# Contributing

Thanks for helping. A few ground rules keep the project useful and safe for everyone:

- **Stay within Anthropic’s terms.** Changes that handle credentials or tokens, proxy requests, pool limits or switch accounts automatically won’t be merged. See [Staying within Anthropic’s terms](README.md#staying-within-anthropics-terms).
- **Never lose user data.** Anything that overwrites or removes a file must back it up first or move it to the Trash.
- **Stay local.** No network calls, and no reading of credentials, tokens, cookies or the Keychain. Claude's data is written only while that window is closed.
- **Test what you change.** `make test` runs the suite; logic belongs in `BatonKit`, where it can be tested against a sandboxed home directory. Write the failing test first. [docs/TESTING.md](docs/TESTING.md) has the details.

## Layout

| Path | What |
|---|---|
| `Sources/BatonKit` | Profiles, session sharing, reading Claude Desktop data, icons |
| `Sources/BatonApp` | SwiftUI app and menu bar |
| `Sources/baton` | Command-line tool |
| `Tests/BatonKitTests` | Swift Testing suite |
| `scripts/build-app.sh` | Builds the universal `Baton.app` and signs it with the hardened runtime |
| `scripts/verify-build.sh`, `notarize.sh`, `package.sh` | Checks, notarizes and zips a build (`make release` runs all of them) |
| `scripts/check-docs.sh`, `check-repo.sh`, `check-cask.sh` | Checks the docs, the repository files and the Homebrew cask |
| `scripts/product.env` | The product name, bundle id and repository, in one place for the scripts and workflows |
| `packaging/homebrew` | The Homebrew cask |
| `docs/adr` | Design decisions |

To take screenshots without real accounts, launch the app with sample data:

```sh
open -n --env BATON_DEMO=1 "build/Baton.app"
```
