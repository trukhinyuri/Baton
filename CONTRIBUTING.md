# Contributing

Thanks for helping. A few ground rules keep the project useful and safe for everyone:

- **Stay within Anthropic's terms.** Changes that handle credentials or tokens, proxy requests, pool limits or switch accounts automatically won't be merged. See [Staying within Anthropic's terms](README.md#staying-within-anthropics-terms).
- **Never lose user data.** Anything that overwrites or removes a file must back it up first or move it to the Trash.
- **Stay local.** No network calls, and no reading of credentials, tokens, cookies or the Keychain. Claude's data is written only while that window is closed.
- **Test what you change.** `make test` runs the suite; logic belongs in `BatonKit`, where it can be tested against a sandboxed home directory. Write the failing test first. [docs/TESTING.md](docs/TESTING.md) has the details.

## Getting started

You need macOS 14 or later and Xcode 16 or later, or Command Line Tools with Swift 6 (`xcode-select --install`; `swift --version` shows which Swift you have). These are the checks CI runs, and a pull request passes them all:

```sh
git clone https://github.com/trukhinyuri/Baton.git && cd Baton
make test                                        # the suite, in temporary folders only
swift build -Xswiftc -warnings-as-errors
swift format lint -r --strict Sources Tests Package.swift
scripts/check-docs.sh && scripts/check-repo.sh   # docs, links and repository files
make app verify                                  # the universal app and its signature checks
```

## Scope

Fixes are always welcome. For a new feature or setting, open a **Suggest a change** issue first, so we can agree it fits before you write it. Some things are declined by design, and the [design decisions](docs/adr/README.md) say why: network code ([0002](docs/adr/0002-no-network-code.md)), handling sign-in ([0003](docs/adr/0003-sign-in-stays-with-claude.md)), working around Claude's history suppression ([0005](docs/adr/0005-never-bypass-history-suppression.md)), and anything on the right-hand side of [Staying within Anthropic's terms](README.md#staying-within-anthropics-terms).

## Pull requests

- One change per pull request, with the test that failed before it. The pull request template has the checklist.
- Title the pull request, and write each commit message, as one plain sentence about what changed, such as "Continue All: the six most recent by default, --max to change it".
- Update `README.md` and `CHANGELOG.md` when users will notice the change.

## License

Baton is under the [MIT License](LICENSE). By contributing, you agree that your contribution is licensed under it too; there is no separate agreement to sign.

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
| `scripts/screenshots.sh` | Draws the README's screenshots from sample data into `docs/images` |
| `scripts/product.env` | The product name, bundle id and repository, in one place for the scripts and workflows |
| `packaging/homebrew` | The Homebrew cask |
| `docs/adr` | Design decisions |

To try the app without real accounts, launch it with sample data; it changes nothing on your Mac:

```sh
open -n --env BATON_DEMO=1 "build/Baton.app"
```

`BATON_DEMO_SHEET=1` also opens **Add Subscription**, `continue` **Continue work…**, and `wait` the same sheet with its offer to wait for a reset. After `make app`, `scripts/screenshots.sh` redraws the README's images in `docs/images` from the same sample data; the app draws its own window into each file, so no screen-recording permission is needed.
