# Functions scripts/install-app.sh and the Makefile use, kept apart so tests can run them in a temporary folder.
# Sourced, never run. Reads nothing outside the paths it is given; only to_trash changes anything.

OLD_APP="Claude Profiles.app"
BUNDLE_ID="io.github.trukhinyuri.claudeprofiles"

# The folder a command link points into, with a relative target read from the link's own folder.
link_target() { # link_target <link>
    target="$(readlink "$1")" || return 1
    case "$target" in
    /*) echo "$target" ;;
    *) echo "$(dirname "$1")/$target" ;;
    esac
}

# Command links named claude-profiles or baton in <bin dirs> (colon-separated) that point into the old app
# (Claude Profiles.app, wherever it is) or into the old launchers folder. One link per line.
stale_links() { # stale_links <bin dirs> <old launchers folder>
    old_ifs="$IFS"
    IFS=:
    for dir in $1; do
        IFS="$old_ifs"
        for name in claude-profiles baton; do
            link="$dir/$name"
            [ -L "$link" ] || continue
            target="$(link_target "$link")" || continue
            case "$target" in
            "$2"/* | */"$OLD_APP"/* | */"$OLD_APP") echo "$link" ;;
            esac
        done
        IFS=:
    done
    IFS="$old_ifs"
}

# The exact command that points each stale link at <app>'s baton, with sudo where the folder isn't writable, under
# <heading> (by default, that they point at the old app or folder).
print_link_fixes() { # print_link_fixes <bin dirs> <old launchers folder> <app> [heading]
    links="$(stale_links "$1" "$2")"
    [ -n "$links" ] || return 0
    echo "${4:-These command links point at the old app or folder. Point them at Baton:}"
    echo "$links" | while IFS= read -r link; do
        sudo=""
        [ -w "$(dirname "$link")" ] || sudo="sudo "
        echo "  ${sudo}ln -sf \"$3/Contents/Helpers/baton\" \"$link\""
    done
}

# Whether baton migrate moved <old> to <new>, read from the folders: it also exits 0 when both already existed.
renamed() { # renamed <old> <new>
    ! [ -e "$1" ] && ! [ -L "$1" ] && [ -d "$2/Baton.app" ]
}

# What to say after the installed baton migrate exited with <status>, for Baton.app installed in <dest>, the old
# launchers folder; <new> is the folder's new name. baton migrate has already printed why a rename was kept.
follow_up() { # follow_up <status> <dest> <new>
    if [ "$1" = 0 ] && renamed "$2" "$3"; then
        echo "Baton.app is now in $3/Baton.app: its folder has the Baton name."
        return 0
    fi
    case "$1" in
    0) echo "Baton.app is installed in $2/Baton.app, but $3 exists too, so Baton uses that folder; the line above says what to do." ;;
    3) echo "Baton.app is installed in $2/Baton.app and works from there; the line above says why the folder keeps its old name." ;;
    *) echo "baton migrate failed (exit $1). Baton.app is installed in $2/Baton.app and works from there. To rename the folder later, quit Baton, close every Claude window and run: \"$2/Baton.app/Contents/Helpers/baton\" migrate" ;;
    esac
}

# Where Baton.app ends up: in the renamed folder once baton migrate renamed it, else where it was installed.
final_app() { # final_app <status> <dest> <old launchers folder> <new>
    if [ "$1" = 0 ] && [ "$2" = "$3" ] && renamed "$3" "$4"; then echo "$4/Baton.app"; else echo "$2/Baton.app"; fi
}

# <dir>/<stem>.<ext>, or with " 2", " 3"… after the stem while that name is taken: never overwrites anything.
unique_path() { # unique_path <dir> <stem> <ext>
    path="$1/$2.$3"
    n=2
    while [ -e "$path" ] || [ -L "$path" ]; do
        path="$1/$2 $n.$3"
        n=$((n + 1))
    done
    echo "$path"
}

# A link that leads nowhere right now, say to a disk that isn't connected.
dangling() { # dangling <path>
    [ -L "$1" ] && ! [ -e "$1" ]
}

# Moves <item> to the Trash. macOS 14 has no trash command; then it goes into ~/.Trash under a name no other item
# there has, with the time added before its extension. HOME_DIR stands in for the home folder, as in install-app.sh.
to_trash() { # to_trash <item>
    if command -v trash >/dev/null 2>&1; then trash "$1"
    else
        name="$(basename "$1")"
        mkdir -p "${HOME_DIR:-$HOME}/.Trash" \
            && mv "$1" "$(unique_path "${HOME_DIR:-$HOME}/.Trash" "${name%.*} $(date +%Y-%m-%d-%H%M%S)" "${name##*.}")"
    fi
}

# The app bundle's identifier, empty if it has none.
bundle_id() { # bundle_id <app>
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}
