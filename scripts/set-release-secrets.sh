#!/bin/sh
# Stores the release secrets in the GitHub repository, for maintainers. Usage:
#   scripts/set-release-secrets.sh <certificate.p12> <AuthKey_KEYID.p8> <team id> <key id> <issuer id>
# The .p12 is the Developer ID Application certificate exported with its private key; the .p8 is an App Store Connect
# API key for notarization. Asks for the .p12 password and the Homebrew tap token without showing them, makes a random
# keychain password, and hands every value to `gh secret set` on stdin: nothing lands in the shell history, the
# process list or a file. Checks the certificate before sending anything. Needs the GitHub CLI signed in.
set -eu

if [ $# -ne 5 ]; then
    sed -n '2,3p' "$0" | sed 's/^# //' >&2
    exit 2
fi
absolute() { # absolute <path>: the path as seen from where the script was started
    case $1 in
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$PWD" "$1" ;;
    esac
}
P12=$(absolute "$1")
P8=$(absolute "$2")
cd "$(dirname "$0")/.."
. scripts/product.env
TEAM=$3
KEY_ID=$4
ISSUER=$5
OPENSSL=/usr/bin/openssl

fail() {
    echo "$1" >&2
    exit 1
}
[ -f "$P12" ] || fail "No certificate at $P12."
[ -f "$P8" ] || fail "No API key at $P8."
command -v gh >/dev/null 2>&1 || fail "The GitHub CLI (gh) is not installed: brew install gh, then gh auth login."
gh auth status >/dev/null 2>&1 || fail "The GitHub CLI is not signed in: gh auth login."
gh repo view "$REPO_SLUG" >/dev/null 2>&1 || fail "Can't reach $REPO_SLUG with the GitHub CLI."
grep -q 'BEGIN PRIVATE KEY' "$P8" || fail "$P8 doesn't look like an App Store Connect API key (.p8)."

ask_hidden() { # ask_hidden <prompt>: prints the answer; the terminal doesn't show it
    printf '%s' "$1" >&2
    stty -echo 2>/dev/null || true
    IFS= read -r answer || answer=""
    stty echo 2>/dev/null || true
    printf '\n' >&2
    printf '%s' "$answer"
}

P12_PASSWORD=$(ask_hidden "Password of $(basename "$P12"): ")
export P12_PASSWORD
subject=$("$OPENSSL" pkcs12 -in "$P12" -nokeys -clcerts -passin env:P12_PASSWORD 2>/dev/null |
    "$OPENSSL" x509 -noout -subject 2>/dev/null) || fail "Can't open $P12 with that password."
case $subject in
*"Developer ID Application"*) ;;
*) fail "$P12 holds \"$subject\", not a Developer ID Application certificate." ;;
esac
case $subject in
*"$TEAM"*) ;;
*) fail "The certificate doesn't belong to team $TEAM: $subject" ;;
esac
"$OPENSSL" pkcs12 -in "$P12" -nocerts -nodes -passin env:P12_PASSWORD 2>/dev/null | grep -q 'PRIVATE KEY' ||
    fail "$P12 has no private key: export it from Keychain Access together with its key."
echo "Certificate: $subject"

put() { # put <name>: the value comes on stdin
    gh secret set "$1" -R "$REPO_SLUG" >/dev/null || fail "Couldn't set $1."
    echo "set   $1"
}
base64 -i "$P12" | tr -d '\n' | put MACOS_CERTIFICATE
printf '%s' "$P12_PASSWORD" | put MACOS_CERTIFICATE_PWD
"$OPENSSL" rand -base64 24 | tr -d '\n' | put KEYCHAIN_PASSWORD
printf '%s' "$TEAM" | put APPLE_TEAM_ID
printf '%s' "$KEY_ID" | put AC_API_KEY_ID
printf '%s' "$ISSUER" | put AC_API_ISSUER_ID
base64 -i "$P8" | tr -d '\n' | put AC_API_KEY
unset P12_PASSWORD

TAP_TOKEN=$(ask_hidden "Token with write access to the Homebrew tap (Enter to skip): ")
if [ -n "$TAP_TOKEN" ]; then
    printf '%s' "$TAP_TOKEN" | put HOMEBREW_TAP_PAT
else
    echo "skip  HOMEBREW_TAP_PAT: the release will leave the tap as it is until you set it."
fi
unset TAP_TOKEN

echo "Secrets now in $REPO_SLUG:"
gh secret list -R "$REPO_SLUG" --json name --jq '.[].name' | sed 's/^/  /'
