#!/bin/sh
# Draws the README's screenshots from the sample data into docs/images. Usage: scripts/screenshots.sh
# Uses build/Baton.app as it is (make app first) and builds nothing. Each picture is drawn by the app itself in demo
# mode (BATON_DEMO_SNAPSHOT, see Sources/BatonApp/DemoSnapshot.swift): no screen capture and no screen-recording
# permission, and demo mode changes nothing on this Mac. Each run gets 20 seconds before it is stopped.
set -eu

cd "$(dirname "$0")/.."
. scripts/product.env
EXE="build/$PRODUCT_NAME.app/Contents/MacOS/$PRODUCT_NAME"
if [ ! -x "$EXE" ]; then
    echo "No $EXE yet: run make app first." >&2
    exit 1
fi
mkdir -p docs/images
WORK="$(mktemp -d "${TMPDIR:-/tmp}/baton-screenshots.XXXXXX")"
failed=0

capture() { # capture <file name> [sheet]: sheet is 1 (Add Subscription) or continue (Continue work…)
    picture="$WORK/$1"
    # Only what the app needs: no Claude or Anthropic settings, nothing else from this shell.
    env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin BATON_DEMO=1 BATON_DEMO_SNAPSHOT="$picture" \
        ${2:+"BATON_DEMO_SHEET=$2"} "$EXE" &
    pid=$!
    # Not waited for yet, so the pid can't belong to anything else; an exited copy shows as a zombie (Z) until then.
    tenths=0
    while state="$(ps -o stat= -p "$pid" 2>/dev/null)" && [ -n "$state" ] && [ "${state#Z}" = "$state" ]; do
        if [ "$tenths" -ge 200 ]; then
            echo "FAIL  $1: the app didn't finish within 20 seconds; stopped it." >&2
            kill "$pid" 2>/dev/null || true
            sleep 1
            kill -KILL "$pid" 2>/dev/null || true
            break
        fi
        sleep 0.1
        tenths=$((tenths + 1))
    done
    status=0
    wait "$pid" || status=$?
    if [ "$status" = 0 ] && [ -s "$picture" ]; then
        mv "$picture" "docs/images/$1"
        echo "ok    docs/images/$1 ($(sips -g pixelWidth -g pixelHeight "docs/images/$1" | awk '/pixel/ {printf "%s%s", sep, $2; sep="×"}') px)"
    else
        echo "FAIL  $1: no picture (exit status $status)." >&2
        failed=1
    fi
}

capture main-window.png
capture add-subscription.png 1
capture continue-work.png continue
rmdir "$WORK" 2>/dev/null || true
exit "$failed"
