#!/bin/sh
# Installs build/Baton.app next to the profile launchers.
# Usage: scripts/install-app.sh [DEST] [--dry-run]    scripts/install-app.sh --where [DEST]
# For tests only: --home DIR, --system-apps DIR and --bin-dirs A:B stand in for your home folder, /Applications and
# /usr/local/bin:/opt/homebrew/bin; --app PATH installs another build. They are refused unless --dry-run is given or
# BATON_INSTALL_TEST=1 is set, because a real run's baton refresh and migrate still work on your real home folder.
#
# Stages and verifies the new app in ~/Applications before replacing anything and refuses while Baton (or Claude
# Profiles, its earlier name) runs. An old Claude Profiles.app goes into a dated ZIP in AppBackups, then to the Trash.
# The Baton.app it replaces is kept only as a dated ZIP in AppBackups (the three newest ZIPs are kept). When the app
# goes into ~/Applications/Claude Profiles, the installed baton migrate then renames that folder to Baton, or, with a
# Claude window open, keeps its old name and prints why and what renames it later. --dry-run prints the plan and
# changes nothing; --where prints the folder it would use.
set -eu
cd "$(dirname "$0")/.."
. scripts/install-lib.sh

usage='Usage: scripts/install-app.sh [DEST] [--dry-run] [--where]'
DRY_RUN=0
WHERE=0
EXPLICIT=""
HOME_DIR="$HOME"
SYSTEM_APPS="/Applications"
BIN_DIRS="/usr/local/bin:/opt/homebrew/bin"
BUILT="build/Baton.app"
TEST_OPTION=""
while [ $# -gt 0 ]; do
    case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --where) WHERE=1 ;;
    --home | --system-apps | --bin-dirs | --app)
        [ $# -ge 2 ] || { echo "$1 needs a value. $usage" >&2; exit 2; }
        TEST_OPTION="$1"
        case "$1" in
        --home) HOME_DIR="$2" ;;
        --system-apps) SYSTEM_APPS="$2" ;;
        --bin-dirs) BIN_DIRS="$2" ;;
        --app) BUILT="$2" ;;
        esac
        shift
        ;;
    -*) echo "Unknown option $1. $usage" >&2; exit 2 ;;
    *) EXPLICIT="$1" ;;
    esac
    shift
done
if [ -n "$TEST_OPTION" ] && [ "$DRY_RUN" = 0 ] && [ "${BATON_INSTALL_TEST:-}" != 1 ]; then
    echo "$TEST_OPTION is for tests: use it with --dry-run (or BATON_INSTALL_TEST=1). A real run's baton refresh and migrate work on your real home folder." >&2
    exit 2
fi

APPLICATIONS="$HOME_DIR/Applications"
SUPPORT="$HOME_DIR/Library/Application Support"
NEW_FOLDER="$APPLICATIONS/Baton"
OLD_FOLDER="$APPLICATIONS/Claude Profiles"

# Baton's data folder as the app resolves it, never renamed: Baton's if it exists, else Claude Profiles' if anything
# is there (a link that leads nowhere right now included), else Baton's.
support_root() {
    if [ -d "$SUPPORT/Baton" ]; then echo "$SUPPORT/Baton"
    elif [ -e "$SUPPORT/Claude Profiles" ] || [ -L "$SUPPORT/Claude Profiles" ]; then echo "$SUPPORT/Claude Profiles"
    else echo "$SUPPORT/Baton"; fi
}
# DEST if given, else the launchers folder Baton uses: its own, the Claude Profiles one until it is renamed, or a new one.
choose_dest() {
    if [ -n "$EXPLICIT" ]; then echo "$EXPLICIT"
    elif [ -d "$NEW_FOLDER" ]; then echo "$NEW_FOLDER"
    elif [ -e "$OLD_FOLDER" ] || [ -L "$OLD_FOLDER" ]; then echo "$OLD_FOLDER"
    else echo "$NEW_FOLDER"; fi
}
# Every old Claude Profiles.app with Baton's bundle id: in DEST, in the Claude Profiles folder next to it, and in
# /Applications. One per line.
old_apps() { # old_apps <dest>
    for old in "$1/$OLD_APP" "$(dirname "$1")/Claude Profiles/$OLD_APP" "$SYSTEM_APPS/$OLD_APP"; do
        [ -d "$old" ] && [ "$(bundle_id "$old")" = "$BUNDLE_ID" ] && echo "$old"
    done | awk '!seen[$0]++'
}
# A dated ZIP of an app in AppBackups, named after the app and the folder it is in, checked before the app is
# touched; never overwrites another ZIP. Prints the ZIP's name.
backup() { # backup <app> <name>
    backups="$(support_root)/AppBackups"
    mkdir -p "$backups" && chmod 700 "$backups" || return 1
    zip="$(unique_path "$backups" "$2 ($(basename "$(dirname "$1")")) $(date +%Y-%m-%d-%H%M%S)" zip)"
    ditto -c -k --keepParent "$1" "$zip" && unzip -tq "$zip" >/dev/null && basename "$zip"
}

if [ "$WHERE" = 1 ]; then choose_dest; exit 0; fi

# A folder of Baton's earlier name that is a link leading nowhere right now: stop rather than start a new, empty one.
for pair in "$SUPPORT/Claude Profiles:$SUPPORT/Baton" "$OLD_FOLDER:$NEW_FOLDER"; do
    old="${pair%%:*}"
    if dangling "$old" && ! [ -d "${pair#*:}" ]; then
        echo "$old links to $(readlink "$old"), which isn't there right now. Connect it and try again; nothing was installed." >&2
        exit 1
    fi
done
# Installing into the old folder while the Baton one exists would leave Baton.app in the folder Baton no longer uses.
if [ -n "$EXPLICIT" ] && [ "${EXPLICIT%/}" = "$OLD_FOLDER" ] && [ -d "$NEW_FOLDER" ]; then
    echo "Both $NEW_FOLDER and $OLD_FOLDER exist, and Baton uses $NEW_FOLDER: install there (leave out DEST), not into $OLD_FOLDER." >&2
    exit 2
fi

DEST="$(choose_dest)"
# Where Baton.app is once the installed baton migrate has renamed the folder.
if [ "$DEST" = "$OLD_FOLDER" ]; then RENAMED_APP="$NEW_FOLDER/Baton.app"; else RENAMED_APP="$DEST/Baton.app"; fi

# Baton, or the same app from before it was renamed.
REFUSE=0
if pgrep -f '/Baton.app/Contents/MacOS/Baton' >/dev/null 2>&1 \
    || pgrep -f "/$OLD_APP/Contents/MacOS/ClaudeProfiles" >/dev/null 2>&1; then
    echo 'Quit Baton (or Claude Profiles, its earlier name) from its menu before installing.' >&2
    [ "$DRY_RUN" = 1 ] || exit 1
    REFUSE=1
fi
[ -d "$BUILT" ] || { echo "No $BUILT yet: run scripts/build-app.sh (or make app) first." >&2; exit 1; }

if [ "$DRY_RUN" = 1 ]; then
    if codesign --verify --strict "$BUILT" 2>/dev/null; then signature="its signature is valid"
    else signature="its signature doesn't verify, so a real run would stop there"; fi
    echo "Dry run: nothing is changed."
    [ "$REFUSE" = 0 ] || echo "A real run would stop here until Baton is quit; the rest is what it would do then."
    echo "Would stage $BUILT in $APPLICATIONS/.baton-install.XXXXXX and verify it there ($signature)."
    old_apps "$DEST" | while IFS= read -r old; do
        echo "Would save $old as a ZIP in $(support_root)/AppBackups, then move it to the Trash."
    done
    [ ! -e "$DEST/Baton.app" ] || echo "Would save the current $DEST/Baton.app as a ZIP in $(support_root)/AppBackups."
    echo "Would install to $DEST/Baton.app."
    if [ "$DEST" = "$OLD_FOLDER" ]; then
        echo "Would then run the installed baton migrate to rename $OLD_FOLDER to $NEW_FOLDER. With a Claude window open, the folder keeps its old name and this script prints the command that renames it later."
    fi
    echo "Would run the installed baton refresh."
    if [ "$DEST" = "$OLD_FOLDER" ]; then
        print_link_fixes "$BIN_DIRS" "$OLD_FOLDER" "$RENAMED_APP" "Once that folder is renamed, point these command links at Baton:"
    else
        print_link_fixes "$BIN_DIRS" "$OLD_FOLDER" "$RENAMED_APP"
    fi
    exit "$REFUSE"
fi

# Staged on the same volume as the launchers and outside the Claude Profiles folder, so renaming that folder can't
# move the staged app and the final step is a rename.
mkdir -p "$APPLICATIONS"
STAGE="$(mktemp -d "$APPLICATIONS/.baton-install.XXXXXX")"
APP="$DEST/Baton.app"
INSTALLED=0
cleanup() {
    # Put the previous app back if the new one never got into place; keep the staging folder if even that fails.
    if [ "$INSTALLED" = 0 ] && [ ! -e "$APP" ] && [ -d "$STAGE/previous.app" ]; then mv "$STAGE/previous.app" "$APP" || return 0; fi
    rm -rf "$STAGE"
}
trap cleanup EXIT HUP INT TERM

ditto "$BUILT" "$STAGE/Baton.app"
codesign --verify --strict "$STAGE/Baton.app"
STAGED_CLI="$STAGE/Baton.app/Contents/Helpers/baton"
if [ "$(bundle_id "$STAGE/Baton.app")" != "$BUNDLE_ID" ] || [ ! -x "$STAGED_CLI" ] || ! "$STAGED_CLI" --version >/dev/null; then
    echo "The staged Baton.app is incomplete; nothing was installed." >&2
    exit 1
fi

# Old copies of the app go into a ZIP, then to the Trash: Baton.app replaces them, and only one copy may run.
BACKUPS="$(support_root)/AppBackups"
old_apps "$DEST" | while IFS= read -r old; do
    zip="$(backup "$old" "Claude Profiles")"
    if to_trash "$old"; then
        echo "Moved the old $old to the Trash: Baton.app replaces it. A copy is saved as $BACKUPS/$zip"
    else
        echo "Couldn't move the old $old to the Trash; move it there yourself. A copy is saved as $BACKUPS/$zip" >&2
    fi
done

mkdir -p "$DEST"
ZIP=""
if [ -e "$APP" ]; then
    ZIP="$(backup "$APP" "Baton")"
    mv "$APP" "$STAGE/previous.app"
fi
mv "$STAGE/Baton.app" "$APP"
INSTALLED=1
echo "Installed to $APP"
[ -z "$ZIP" ] || echo "Previous version saved as $BACKUPS/$ZIP"

# The installed baton renames the Claude Profiles folder it now lives in; exit 3 keeps the old name for now and says why.
STATUS=0
if [ "$DEST" = "$OLD_FOLDER" ]; then
    set +e
    "$APP/Contents/Helpers/baton" migrate
    STATUS=$?
    set -e
    follow_up "$STATUS" "$DEST" "$NEW_FOLDER"
fi
FINAL="$(final_app "$STATUS" "$DEST" "$OLD_FOLDER" "$NEW_FOLDER")"

# Engines after a Claude Desktop update, and launchers that call baton at its new path.
"$FINAL/Contents/Helpers/baton" refresh || echo "baton refresh failed; run \"$FINAL/Contents/Helpers/baton\" refresh once Baton is set up." >&2
if [ "$FINAL" = "$RENAMED_APP" ]; then
    print_link_fixes "$BIN_DIRS" "$OLD_FOLDER" "$FINAL"
else
    print_link_fixes "$BIN_DIRS" "$OLD_FOLDER" "$RENAMED_APP" "Once that folder is renamed, point these command links at Baton:"
fi

# Keep the three latest ZIPs. Older installers kept runnable .previous-*.app copies beside the app; the ZIPs replace them.
ls -t "$BACKUPS"/*.zip 2>/dev/null | tail -n +4 | while IFS= read -r old; do to_trash "$old" || true; done
for old in "$(dirname "$FINAL")"/.previous-*.app; do
    [ -d "$old" ] && to_trash "$old" && echo "Moved $(basename "$old") to the Trash"
done
exit 0
