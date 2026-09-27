#!/bin/sh
# Sign only the built manager and its bundled helper, from the inside out.
set -eu
APP="${1:-build/Claude Profiles.app}"
MODE="${CLAUDE_PROFILES_SIGNING_MODE:-}"
IDENTITY="${CODESIGN_IDENTITY:--}"
if [ -z "$MODE" ]; then
    if [ "$IDENTITY" = '-' ]; then MODE=ad-hoc; else MODE=developer-id; fi
fi
case "$MODE" in
    ad-hoc)
        if [ "$IDENTITY" != '-' ]; then
            echo 'Ad-hoc mode cannot be combined with a signing identity.' >&2; exit 1
        fi
        ;;
    developer-id)
        if [ -z "$IDENTITY" ] || [ "$IDENTITY" = '-' ]; then
            echo 'Developer ID mode requires CODESIGN_IDENTITY; no ad-hoc fallback is allowed.' >&2; exit 1
        fi
        case "${APPLE_TEAM_ID:-}" in
            ''|*[!A-Z0-9]*) echo 'APPLE_TEAM_ID must be the expected ten-character Apple Team ID.' >&2; exit 1 ;;
        esac
        if [ "${#APPLE_TEAM_ID}" -ne 10 ]; then
            echo 'APPLE_TEAM_ID must be the expected ten-character Apple Team ID.' >&2; exit 1
        fi
        ;;
    *) echo 'CLAUDE_PROFILES_SIGNING_MODE must be ad-hoc or developer-id.' >&2; exit 1 ;;
esac
if [ ! -f "$APP/Contents/MacOS/ClaudeProfiles" ] || [ ! -f "$APP/Contents/Helpers/claude-profiles" ]; then
    echo 'The built app or its helper is missing.' >&2; exit 1
fi

sign_one() {
    set -- --force --sign "$IDENTITY" "$1"
    if [ "$MODE" = developer-id ]; then set -- --options runtime --timestamp "$@"; fi
    if [ -n "${CODESIGN_KEYCHAIN:-}" ]; then set -- --keychain "$CODESIGN_KEYCHAIN" "$@"; fi
    codesign "$@"
}
sign_one "$APP/Contents/Helpers/claude-profiles"
sign_one "$APP"
codesign --verify --deep --strict "$APP"
if [ "$MODE" = developer-id ]; then
    sh "$(dirname "$0")/verify-distribution.sh" "$APP"
else
    echo 'Development build: ad-hoc signature; not notarized. macOS permissions may need reapproval after updates.'
fi
