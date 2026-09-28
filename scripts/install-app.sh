#!/bin/sh
# Installs build/Baton.app next to the profile launchers.
# Usage: scripts/install-app.sh [DEST] [--dry-run]    scripts/install-app.sh --where [DEST]
#
# Stages and verifies the new app before replacing anything, refuses while Baton (or Claude Profiles, its earlier
# name) runs, lets the staged `baton migrate` move Baton's folders from the Claude Profiles name when nothing runs from
# them, and keeps the previous app as a dated ZIP outside Applications. An old Claude Profiles.app goes into a ZIP
# too, then to the Trash. --dry-run prints the plan and changes nothing; --where prints the folder it would use.
set -eu
cd "$(dirname "$0")/.."

DRY_RUN=0
WHERE=0
EXPLICIT=""
for arg in "$@"; do
    case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --where) WHERE=1 ;;
    -*) echo "Unknown option $arg. Usage: scripts/install-app.sh [DEST] [--dry-run]" >&2; exit 2 ;;
    *) EXPLICIT="$arg" ;;
    esac
done

APPLICATIONS="$HOME/Applications"
SUPPORT="$HOME/Library/Application Support"
NEW_FOLDER="$APPLICATIONS/Baton"
OLD_FOLDER="$APPLICATIONS/Claude Profiles"
OLD_APP="Claude Profiles.app"
BUILT="build/Baton.app"
BUNDLE_ID="io.github.trukhinyuri.claudeprofiles"

is_real_dir() { [ -d "$1" ] && [ ! -L "$1" ]; }
# Baton's state folder as the app resolves it: Baton's if it exists, else Claude Profiles' while it is a real folder.
support_root() {
    if [ -d "$SUPPORT/Baton" ]; then echo "$SUPPORT/Baton"
    elif is_real_dir "$SUPPORT/Claude Profiles"; then echo "$SUPPORT/Claude Profiles"
    else echo "$SUPPORT/Baton"; fi
}
# DEST if given, else the launchers folder Baton uses: its own, the Claude Profiles one until it moves, or a new one.
choose_dest() {
    if [ -n "$EXPLICIT" ]; then echo "$EXPLICIT"
    elif [ -d "$NEW_FOLDER" ]; then echo "$NEW_FOLDER"
    elif is_real_dir "$OLD_FOLDER"; then echo "$OLD_FOLDER"
    else echo "$NEW_FOLDER"; fi
}
# A dated ZIP of an app in AppBackups, checked before the app is touched. Prints the ZIP's name.
backup() { # backup <app> <name>
    backups="$(support_root)/AppBackups"
    zip="$2 $(date +%Y-%m-%d-%H%M%S).zip"
    mkdir -p "$backups" && chmod 700 "$backups" && ditto -c -k --keepParent "$1" "$backups/$zip" \
        && unzip -tq "$backups/$zip" >/dev/null && echo "$zip"
}
to_trash() {
    if command -v trash >/dev/null 2>&1; then trash "$1"
    else mv "$1" "$HOME/.Trash/$(basename "$1" .app) $(date +%Y-%m-%d-%H%M%S).app"; fi
}

if [ "$WHERE" = 1 ]; then choose_dest; exit 0; fi

# Baton, or the same app from before it was renamed.
REFUSE=0
if pgrep -f '/Baton.app/Contents/MacOS/Baton' >/dev/null 2>&1 \
    || pgrep -f "/$OLD_APP/Contents/MacOS/ClaudeProfiles" >/dev/null 2>&1; then
    echo 'Quit Baton (or Claude Profiles, its earlier name) from its menu before installing. Your Claude windows can stay open.' >&2
    [ "$DRY_RUN" = 1 ] || exit 1
    REFUSE=1
fi
[ -d "$BUILT" ] || { echo "No $BUILT yet: run scripts/build-app.sh (or make app) first." >&2; exit 1; }

if [ "$DRY_RUN" = 1 ]; then
    codesign --verify --strict "$BUILT"
    DEST="$(choose_dest)"
    echo "Dry run: nothing is changed."
    [ "$REFUSE" = 0 ] || echo "A real run would stop here until Baton is quit; the rest is what it would do then."
    echo "Would stage $BUILT in $APPLICATIONS/.baton-install.XXXXXX and verify it there (its signature is valid)."
    echo "Would run the staged baton migrate, which moves Baton's folders from the Claude Profiles name if nothing runs from them."
    if [ -z "$EXPLICIT" ] && [ "$DEST" = "$OLD_FOLDER" ]; then
        echo "Would install to $NEW_FOLDER/Baton.app if the folders move, else to $DEST/Baton.app."
    else
        echo "Would install to $DEST/Baton.app."
    fi
    for old in "$OLD_FOLDER/$OLD_APP" "$DEST/$OLD_APP"; do
        [ ! -d "$old" ] || [ "$old" = "${SEEN:-}" ] || echo "Would save $old as a ZIP in $(support_root)/AppBackups, then move it to the Trash."
        SEEN="$old"
    done
    [ ! -e "$DEST/Baton.app" ] || echo "Would save the current $DEST/Baton.app as a ZIP in $(support_root)/AppBackups."
    exit "$REFUSE"
fi

# Staged on the same volume as the launchers and outside the Claude Profiles folder, so moving that folder can't
# move the staged app and the final step is a rename.
mkdir -p "$APPLICATIONS"
STAGE="$(mktemp -d "$APPLICATIONS/.baton-install.XXXXXX")"
APP=""
cleanup() {
    # Put the previous app back if the new one is not in place; keep the staging folder if even that fails.
    if [ -n "$APP" ] && [ ! -e "$APP" ] && [ -d "$STAGE/previous.app" ]; then mv "$STAGE/previous.app" "$APP" || return 0; fi
    rm -rf "$STAGE"
}
trap cleanup EXIT HUP INT TERM

ditto "$BUILT" "$STAGE/Baton.app"
codesign --verify --strict "$STAGE/Baton.app"
CLI="$STAGE/Baton.app/Contents/Helpers/baton"
if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGE/Baton.app/Contents/Info.plist")" != "$BUNDLE_ID" ] \
    || [ ! -x "$CLI" ] || ! "$CLI" --version >/dev/null; then
    echo "The staged Baton.app is incomplete; nothing was installed." >&2
    exit 1
fi

# The old app in the Claude Profiles folder goes into a ZIP first: if baton migrate moves the folder, it sends that
# app to the Trash.
OLD_SAVED=""
OLD_ZIP=""
if [ -d "$OLD_FOLDER/$OLD_APP" ]; then
    OLD_ZIP="$(backup "$OLD_FOLDER/$OLD_APP" "Claude Profiles")"
    OLD_SAVED="$OLD_FOLDER/$OLD_APP"
fi

# Exit 3: kept under the old name because something runs from it; installing next to it is still right.
set +e
"$CLI" migrate
status=$?
set -e
if [ "$status" != 0 ] && [ "$status" != 3 ]; then
    echo "baton migrate failed (exit $status); nothing was installed." >&2
    exit 1
fi

DEST="$(choose_dest)"
APP="$DEST/Baton.app"
mkdir -p "$DEST"
if [ -d "$DEST/$OLD_APP" ]; then
    if [ "$DEST/$OLD_APP" != "$OLD_SAVED" ]; then OLD_ZIP="$(backup "$DEST/$OLD_APP" "Claude Profiles")"; fi
    to_trash "$DEST/$OLD_APP"
    echo "Moved the old $OLD_APP to the Trash: Baton.app replaces it."
fi
ZIP=""
if [ -e "$APP" ]; then
    ZIP="$(backup "$APP" "Baton")"
    mv "$APP" "$STAGE/previous.app"
fi
mv "$STAGE/Baton.app" "$APP"
BACKUPS="$(support_root)/AppBackups"
echo "Installed to $APP"
[ -z "$OLD_ZIP" ] || echo "The old $OLD_APP is saved as $BACKUPS/$OLD_ZIP"
[ -z "$ZIP" ] || echo "Previous version saved as $BACKUPS/$ZIP"

# Keep the three latest ZIPs. Older installers kept runnable .previous-*.app copies beside the app; the ZIPs replace them.
if command -v trash >/dev/null 2>&1; then
    ls -t "$BACKUPS"/*.zip 2>/dev/null | tail -n +4 | while IFS= read -r old; do trash "$old" || true; done
    for old in "$DEST"/.previous-*.app; do
        [ -d "$old" ] && trash "$old" && echo "Moved $(basename "$old") to the Trash"
    done
fi
exit 0
