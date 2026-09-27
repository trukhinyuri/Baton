#!/bin/sh
# Validate distribution identity without replacing or weakening its designated requirement.
set -eu
APP="${1:-build/Claude Profiles.app}"
case "${APPLE_TEAM_ID:-}" in
    ''|*[!A-Z0-9]*) echo 'A valid expected APPLE_TEAM_ID is required for distribution verification.' >&2; exit 1 ;;
esac
if [ "${#APPLE_TEAM_ID}" -ne 10 ]; then
    echo 'A valid expected APPLE_TEAM_ID is required for distribution verification.' >&2; exit 1
fi
# These are verification constraints, never a custom designated requirement used for signing.
REQUIREMENT="anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$APPLE_TEAM_ID\""
codesign --verify --deep --strict "$APP"
for TARGET in "$APP/Contents/Helpers/claude-profiles" "$APP"; do
    codesign --verify --strict "-R=$REQUIREMENT" "$TARGET"
    DETAILS="$(codesign --display --verbose=4 "$TARGET" 2>&1)"
    if ! printf '%s\n' "$DETAILS" | grep -Eq '^CodeDirectory .*flags=.*[(,]runtime[),]'; then
        echo 'A distributed executable is missing hardened runtime.' >&2; exit 1
    fi
    if ! printf '%s\n' "$DETAILS" | grep -Eq '^Timestamp=.+$'; then
        echo 'A distributed executable is missing its secure timestamp.' >&2; exit 1
    fi
done
APP_DETAILS="$(codesign --display --verbose=4 "$APP" 2>&1)"
if ! printf '%s\n' "$APP_DETAILS" | grep -qx 'Identifier=io.github.trukhinyuri.claudeprofiles'; then
    echo 'The distribution app has an unexpected signing identifier.' >&2; exit 1
fi
