#!/bin/sh
# Stage and verify before replacing the app; keep the previous version as a ZIP outside Applications.
set -eu
cd "$(dirname "$0")/.."
DEST="${1:-$HOME/Applications/Claude Profiles}"
APP="$DEST/Baton.app"
BACKUPS="$HOME/Library/Application Support/Claude Profiles/AppBackups"
# Baton, or the same app from before it was renamed.
if pgrep -f '/Baton.app/Contents/MacOS/Baton' >/dev/null 2>&1 \
    || pgrep -f '/Claude Profiles.app/Contents/MacOS/ClaudeProfiles' >/dev/null 2>&1; then
    echo 'Quit Baton (or Claude Profiles, its earlier name) from its menu before installing. Your Claude windows can stay open.' >&2
    exit 1
fi
mkdir -p "$DEST"
STAGE="$(mktemp -d "$DEST/.install.XXXXXX")"
ZIP=""
cleanup() {
    # Put the previous app back if the new one is not in place; keep the staging folder if even that fails.
    if [ ! -e "$APP" ] && [ -d "$STAGE/previous.app" ]; then mv "$STAGE/previous.app" "$APP" || return 0; fi
    rm -rf "$STAGE"
}
trap cleanup EXIT HUP INT TERM
ditto 'build/Baton.app' "$STAGE/Baton.app"
codesign --verify --strict "$STAGE/Baton.app"
if [ -e "$APP" ]; then
    mkdir -p "$BACKUPS" && chmod 700 "$BACKUPS"
    ZIP="$BACKUPS/Baton $(date +%Y-%m-%d-%H%M%S).zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    unzip -tq "$ZIP" >/dev/null
    mv "$APP" "$STAGE/previous.app"
fi
mv "$STAGE/Baton.app" "$APP"
echo "Installed to $APP"
[ -z "$ZIP" ] || echo "Previous version saved as $ZIP"

# Keep the three latest ZIPs. Older installers kept runnable .previous-*.app copies beside the app; the ZIPs replace them.
if command -v trash >/dev/null 2>&1; then
    ls -t "$BACKUPS"/*.zip 2>/dev/null | tail -n +4 | while IFS= read -r old; do trash "$old" || true; done
    for old in "$DEST"/.previous-*.app; do
        [ -d "$old" ] && trash "$old" && echo "Moved $(basename "$old") to the Trash"
    done
fi
exit 0
