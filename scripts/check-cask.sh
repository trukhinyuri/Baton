#!/bin/sh
# Runs brew style and brew audit --new --strict on the cask in a throwaway local tap, then removes the tap.
# Installs nothing. Until the release it names exists, audit fails on the download; until the build is
# notarized, on the signature; and homebrew/cask's notability check never applies to a personal tap.
set -eu

cd "$(dirname "$0")/.."
. scripts/product.env
CASK="packaging/homebrew/Casks/$CASK_TOKEN.rb"
TAP_NAME="local-check/$CASK_TOKEN"
TAP_DIR="$(brew --repository)/Library/Taps/local-check/homebrew-$CASK_TOKEN"

brew tap-new --no-git "$TAP_NAME" >/dev/null
trap 'brew untap "$TAP_NAME" >/dev/null 2>&1 || true' EXIT HUP INT TERM
mkdir -p "$TAP_DIR/Casks"
cp "$CASK" "$TAP_DIR/Casks/"
status=0
brew style --cask "$TAP_NAME/$CASK_TOKEN" || status=1
brew audit --cask --new --strict "$TAP_NAME/$CASK_TOKEN" || status=1
exit "$status"
