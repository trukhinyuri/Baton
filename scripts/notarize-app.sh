#!/bin/sh
# Submit, staple, assess, then package. This script never publishes a release.
set -eu
APP="${1:-build/Claude Profiles.app}"
OUTPUT="${2:-build/ClaudeProfiles-notarized.zip}"
if [ -z "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
    echo 'NOTARY_KEYCHAIN_PROFILE is required; use notarytool store-credentials first.' >&2; exit 1
fi
if [ -e "$OUTPUT" ]; then
    echo 'The output archive already exists; choose a new output path.' >&2; exit 1
fi
sh "$(dirname "$0")/verify-distribution.sh" "$APP"
REPORT_DIR="${NOTARY_REPORT_DIR:-build/notarization}"
mkdir -p "$REPORT_DIR"
if [ -e "$REPORT_DIR/result.json" ]; then
    echo 'A notarization result already exists; use a new NOTARY_REPORT_DIR to retain the previous submission ID.' >&2; exit 1
fi
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/claudeprofiles-notary.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
ditto -c -k --keepParent "$APP" "$STAGE/submission.zip"
notary() {
    if [ -n "${NOTARY_KEYCHAIN:-}" ]; then
        xcrun notarytool "$@" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --keychain "$NOTARY_KEYCHAIN"
    else
        xcrun notarytool "$@" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE"
    fi
}
SUBMIT_STATUS=0
notary submit "$STAGE/submission.zip" --wait --timeout 20m --output-format json > "$REPORT_DIR/result.json" || SUBMIT_STATUS=$?
STATUS="$(plutil -extract status raw -o - "$REPORT_DIR/result.json" 2>/dev/null || true)"
SUBMISSION_ID="$(plutil -extract id raw -o - "$REPORT_DIR/result.json" 2>/dev/null || true)"
case "$SUBMISSION_ID" in
    ''|*[!A-Za-z0-9-]*) ;;
    *) notary log "$SUBMISSION_ID" "$REPORT_DIR/log.json" || true ;;
esac
if [ "$SUBMIT_STATUS" -ne 0 ] || [ "$STATUS" != Accepted ]; then
    echo "Notarization has not been accepted. See $REPORT_DIR/result.json; no distributable archive was created." >&2
    exit 1
fi
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
sh "$(dirname "$0")/verify-distribution.sh" "$APP"
spctl --assess --type execute --verbose=2 "$APP"
# ZIP files cannot carry a stapled ticket themselves. Repackage the now-stapled app.
ditto -c -k --keepParent "$APP" "$STAGE/distribution.zip"
mv "$STAGE/distribution.zip" "$OUTPUT"
echo "Created notarized distribution: $OUTPUT"
