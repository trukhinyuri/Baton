#!/bin/sh
# Notarizes and staples the built app. Usage: NOTARY_KEYCHAIN_PROFILE=<name> scripts/notarize.sh
# The profile is stored once with `xcrun notarytool store-credentials <name>`; NOTARY_KEYCHAIN names a keychain
# other than the login one (CI). Without a profile this skips and leaves the app as it is.
set -eu

cd "$(dirname "$0")/.."
. scripts/product.env
APP="build/$PRODUCT_NAME.app"
PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"

[ -d "$APP" ] || { echo "No app at $APP. Run scripts/build-app.sh first." >&2; exit 1; }
if [ -z "$PROFILE" ]; then
    echo "Notarization skipped: NOTARY_KEYCHAIN_PROFILE is not set. The app is not notarized, so a downloaded copy"
    echo "needs Open Anyway in System Settings. To notarize, store a profile with"
    echo "  xcrun notarytool store-credentials <name>"
    echo "and run NOTARY_KEYCHAIN_PROFILE=<name> $0"
    exit 0
fi
if ! codesign -dv "$APP" 2>&1 | grep -q '^Authority=Developer ID Application:'; then
    echo "The app is not signed with a Developer ID, so Apple would reject it. Build it with" >&2
    echo "  CODESIGN_IDENTITY='Developer ID Application: <Name> (<TEAMID>)' scripts/build-app.sh" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/submit.zip"
set -- --keychain-profile "$PROFILE"
[ -z "${NOTARY_KEYCHAIN:-}" ] || set -- "$@" --keychain "$NOTARY_KEYCHAIN"
xcrun notarytool submit "$WORK/submit.zip" "$@" --wait --output-format json > "$WORK/result.json"
cat "$WORK/result.json"
if ! grep -q '"status" *: *"Accepted"' "$WORK/result.json"; then
    id="$(sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' "$WORK/result.json" | head -n 1)"
    echo "Notarization was not accepted. Details: xcrun notarytool log $id $*" >&2
    exit 1
fi
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute -vv "$APP"
echo "Notarized and stapled $APP. Package it now with scripts/package.sh."
