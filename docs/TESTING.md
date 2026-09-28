# Testing

```sh
make test                 # swift test: the whole suite, in temporary folders (retried once, see below)
make app verify           # universal build, then scripts/verify-build.sh
scripts/check-docs.sh     # docs match 1.0: removed features, links, anchors, VERSION
scripts/check-repo.sh     # contributor and reporter files are in place
scripts/check-cask.sh     # brew style and brew audit on the cask, in a throwaway tap (404s until the first release)
```

## The suite never touches real data

Every piece of logic lives in `BatonKit` and takes a `Paths` value. Tests build a `Sandbox`: a temporary home folder with a main Claude data directory, profile data directories, `~/.claude` and the state folder, filled with the files a test needs. Nothing reads `~/Library/Application Support/Claude*`, `~/Library/Application Support/Baton`, `~/Applications` or `~/.claude`, and nothing opens a real Claude window. `LegacyMigration` takes an `Environment` with stand-ins for the process list, the rename and the Trash, so the tests that rename `~/Applications/Claude Profiles` to Baton, or keep it, run in a temporary home. `Backup` takes a `discard` closure, so pruning is tested without filling the real Trash.

Fixtures in `Tests/BatonKitTests/Fixtures` are shaped like real Claude data with every identifier, email, path and title replaced. A new fixture taken from a real Mac must be sanitized the same way before it is committed; the problem-report tests run a leak scanner over fixtures like these.

## Writing a test

Tests use Swift Testing (`@Test`, `#expect`). For a bug, write the test that fails first, watch it fail, then fix the code. For anything that writes a user's file, test the backup and the closed-window rule as well as the happy path. Keep a test's name a sentence about behavior, such as `crossAccountCopyDropsAccountScopedKeys`.

## Optional suites

| Variable | What it adds | Needs |
|---|---|---|
| `LEVELDB_COMPAT=1` | Reads databases written by the project's LevelDB writer with the real `leveldbutil` | `brew install leveldb` |

CI runs the suite on macOS 14 and macOS 15, builds the universal app and runs its x86_64 CLI under Rosetta, and runs the LevelDB compatibility suite. `swift format lint` (configured in `.swift-format`) and `-warnings-as-errors` are reported in CI.

If `swift test` stops with *plugin for module 'TestingMacros' not found*, trashing `.build` doesn't help: it is an intermittent toolchain error, not a stale cache. Build the tests on one job, repeating until it says *Build complete*, then run them without building:

```sh
swift build --build-tests -j 1
swift test --skip-build
```

Running `swift test -j 2` again also works. `make test` retries once this way when it sees that error.

The Command Line Tools have no plugin for SwiftUI's own macros, so a view that uses `@State` builds only with Xcode. The app keeps view state in an `ObservableObject` held with `@StateObject` instead, which builds with both.

`scripts/install-app.sh --dry-run` prints what an install would do and changes nothing; `--where` prints the folder it would use. Don't give a real run a temporary `HOME` to try it out: the script follows `HOME`, but the `baton migrate` it runs finds the home folder from the user account, as Foundation does on macOS, and would work on the real one.

## Checking a build

`scripts/verify-build.sh` checks that both binaries are universal (`arm64 x86_64`), signed with the hardened runtime, that the signature verifies, that `Info.plist` records the commit, and that `baton --version` runs natively and under Rosetta and reports the bundle's version. When `build/SHA256SUMS.txt` exists, it checks the archive against it.

Changes to the app's windows are also checked by hand: run it with sample data, which needs no accounts:

```sh
open -n --env BATON_DEMO=1 "build/Baton.app"
```
