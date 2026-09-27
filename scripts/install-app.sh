#!/bin/sh
# Stage and verify before replacing the app; retain the previous version for rollback.
set -eu
cd "$(dirname "$0")/.."
DEST="${1:-$HOME/Applications/Claude Profiles}"
APP="$DEST/Claude Profiles.app"
if pgrep -f '/Claude Profiles.app/Contents/MacOS/ClaudeProfiles' >/dev/null 2>&1; then
    echo 'Quit Claude Profiles from its menu before installing. Your Claude windows can stay open.' >&2
    exit 1
fi
mkdir -p "$DEST"
STAGE="$(mktemp -d "$DEST/.install.XXXXXX")"
BACKUP=""
cleanup() {
    if [ ! -d "$APP" ] && [ -n "$BACKUP" ] && [ -d "$BACKUP" ]; then mv "$BACKUP" "$APP"; fi
    # Only our own staging directory is disposable; never delete the installed or backup app.
    rm -rf "$STAGE"
}
trap cleanup EXIT HUP INT TERM
cp -R 'build/Claude Profiles.app' "$STAGE/Claude Profiles.app"
codesign --verify "$STAGE/Claude Profiles.app"
if [ -e "$APP" ]; then
    BACKUP="$DEST/.previous-$(date +%Y%m%d-%H%M%S)-$$.app"
    mv "$APP" "$BACKUP"
fi
mv "$STAGE/Claude Profiles.app" "$APP"
echo "Installed to $APP"
if [ -n "$BACKUP" ]; then echo "Previous application kept at $BACKUP"; fi
