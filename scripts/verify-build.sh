#!/bin/sh
# Checks a built app before it is packaged or installed. Usage: scripts/verify-build.sh [path/to/Baton.app]
# Exits non-zero at the first failed check and says which one.
set -eu

cd "$(dirname "$0")/.."
. scripts/product.env
APP="${1:-build/$PRODUCT_NAME.app}"
PLIST="$APP/Contents/Info.plist"
MAIN="$APP/Contents/MacOS/Baton"
CLI="$APP/Contents/Helpers/baton"
OLD_CLI="$APP/Contents/Helpers/claude-profiles"
failed=0

check() { # check <description> <command...>
    what="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "ok    $what"; else echo "FAIL  $what" >&2; failed=1; fi
}
old_cli_links() { [ -L "$OLD_CLI" ] && [ "$(readlink "$OLD_CLI")" = baton ]; }
universal() { [ "$(lipo -archs "$1" 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' ')" = "arm64 x86_64 " ]; }
hardened() { codesign -dv "$1" 2>&1 | grep -Eq 'flags=0x[0-9a-f]*\(.*runtime'; }
has_commit() { commit="$(/usr/libexec/PlistBuddy -c 'Print :BatonCommit' "$PLIST" 2>/dev/null)" && [ -n "$commit" ]; }
version_matches() { # the helper reports the bundle's full version (BatonVersion) under the named architecture
    expected="$(/usr/libexec/PlistBuddy -c 'Print :BatonVersion' "$PLIST")"
    arch "-$1" "$CLI" --version | grep -q "^$PRODUCT_NAME $expected ("
}

[ -d "$APP" ] || { echo "No app at $APP. Run scripts/build-app.sh first." >&2; exit 1; }
check "app binary is universal (arm64 x86_64)" universal "$MAIN"
check "helper binary is universal (arm64 x86_64)" universal "$CLI"
check "app is signed with the hardened runtime" hardened "$APP"
check "helper is signed with the hardened runtime" hardened "$CLI"
check "signature verifies (strict, deep)" codesign --verify --strict --deep "$APP"
check "Info.plist has BatonCommit" has_commit
check "Info.plist has BatonVersion" /usr/libexec/PlistBuddy -c 'Print :BatonVersion' "$PLIST"
check "Helpers/claude-profiles links to baton, for 1.x scripts" old_cli_links
# Each slice runs where this Mac can run it: an Intel Mac can't run arm64 code at all, so it checks x86_64 only.
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" != 1 ]; then
    check "helper --version runs natively (x86_64)" version_matches x86_64
    echo "skip  helper --version as arm64: an Intel Mac can't run it; lipo checked the slice is there"
else
    check "helper --version runs natively (arm64)" version_matches arm64
    if arch -x86_64 /usr/bin/true 2>/dev/null; then
        check "helper --version runs under Rosetta (x86_64)" version_matches x86_64
    else
        echo "FAIL  helper --version under Rosetta: Rosetta is not installed (softwareupdate --install-rosetta)" >&2
        failed=1
    fi
fi
# The release archive, when one was made next to the app.
if [ -f build/SHA256SUMS.txt ]; then
    check "build/SHA256SUMS.txt matches the archive" sh -c 'cd build && shasum -a 256 -c SHA256SUMS.txt'
fi
[ "$failed" = 0 ] && echo "Build verified: $APP"
exit "$failed"
