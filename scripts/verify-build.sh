#!/bin/sh
# Checks a built app before it is packaged or installed. Usage: scripts/verify-build.sh [path/to/Claude Profiles.app]
# Exits non-zero at the first failed check and says which one.
set -eu

cd "$(dirname "$0")/.."
APP="${1:-build/Claude Profiles.app}"
PLIST="$APP/Contents/Info.plist"
MAIN="$APP/Contents/MacOS/ClaudeProfiles"
CLI="$APP/Contents/Helpers/claude-profiles"
failed=0

check() { # check <description> <command...>
    what="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "ok    $what"; else echo "FAIL  $what" >&2; failed=1; fi
}
universal() { [ "$(lipo -archs "$1" 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' ')" = "arm64 x86_64 " ]; }
hardened() { codesign -dv "$1" 2>&1 | grep -Eq 'flags=0x[0-9a-f]*\(.*runtime'; }
has_commit() { commit="$(/usr/libexec/PlistBuddy -c 'Print :ClaudeProfilesCommit' "$PLIST" 2>/dev/null)" && [ -n "$commit" ]; }
version_matches() { # the helper reports the bundle's version under the named architecture
    expected="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
    arch "-$1" "$CLI" --version | grep -q "^Claude Profiles $expected ("
}

[ -d "$APP" ] || { echo "No app at $APP. Run scripts/build-app.sh first." >&2; exit 1; }
check "app binary is universal (arm64 x86_64)" universal "$MAIN"
check "helper binary is universal (arm64 x86_64)" universal "$CLI"
check "app is signed with the hardened runtime" hardened "$APP"
check "helper is signed with the hardened runtime" hardened "$CLI"
check "signature verifies (strict, deep)" codesign --verify --strict --deep "$APP"
check "Info.plist has ClaudeProfilesCommit" has_commit
check "helper --version runs natively (arm64)" version_matches arm64
if arch -x86_64 /usr/bin/true 2>/dev/null; then
    check "helper --version runs under Rosetta (x86_64)" version_matches x86_64
else
    echo "FAIL  helper --version under Rosetta: Rosetta is not installed (softwareupdate --install-rosetta)" >&2
    failed=1
fi
# The release archive, when one was made next to the app.
if [ -f build/SHA256SUMS.txt ]; then
    check "build/SHA256SUMS.txt matches the archive" sh -c 'cd build && shasum -a 256 -c SHA256SUMS.txt'
fi
[ "$failed" = 0 ] && echo "Build verified: $APP"
exit "$failed"
