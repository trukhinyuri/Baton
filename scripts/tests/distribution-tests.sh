#!/bin/sh
# Exercise distribution control flow with fake Apple tools. Never use a real key or submit an app.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/claudeprofiles-distribution-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$TEST_ROOT/tools" "$TEST_ROOT/Fake App.app/Contents/MacOS" "$TEST_ROOT/Fake App.app/Contents/Helpers"
APP="$TEST_ROOT/Fake App.app"
touch "$APP/Contents/MacOS/ClaudeProfiles" "$APP/Contents/Helpers/claude-profiles"
cat > "$TEST_ROOT/tools/codesign" <<'STUB'
#!/bin/sh
printf 'codesign' >> "$CP_TEST_LOG"; printf '<%s>' "$@" >> "$CP_TEST_LOG"; printf '\n' >> "$CP_TEST_LOG"
for arg in "$@"; do
  case "$arg" in
    --force) [ "${CP_TEST_SIGN_FAIL:-0}" = 0 ] || exit 1 ;;
    --verify) [ "${CP_TEST_VERIFY_FAIL:-0}" = 0 ] || exit 1 ;;
    --display)
      printf 'Identifier=%s\n' "${CP_TEST_IDENTIFIER:-io.github.trukhinyuri.claudeprofiles}"
      if [ "${CP_TEST_NO_RUNTIME:-0}" = 0 ]; then printf 'CodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=1+3 location=embedded\n'; fi
      if [ "${CP_TEST_NO_TIMESTAMP:-0}" = 0 ]; then printf 'Timestamp=Sep 28, 2026 at 00:00:00\n'; fi
      ;;
  esac
done
STUB
cat > "$TEST_ROOT/tools/xcrun" <<'STUB'
#!/bin/sh
printf 'xcrun' >> "$CP_TEST_LOG"; printf '<%s>' "$@" >> "$CP_TEST_LOG"; printf '\n' >> "$CP_TEST_LOG"
case "$1/$2" in
  notarytool/submit)
    if [ "${CP_TEST_INVALID_JSON:-0}" = 1 ]; then printf 'unreadable'; else
      printf '{"id":"abc-123","status":"%s"}\n' "${CP_TEST_NOTARY_STATUS:-Accepted}"
    fi
    exit "${CP_TEST_NOTARY_EXIT:-0}" ;;
  notarytool/log) printf '{"fixture":true}\n' > "$4" ;;
  stapler/staple|stapler/validate) exit "${CP_TEST_STAPLER_EXIT:-0}" ;;
  *) exit 98 ;;
esac
STUB
cat > "$TEST_ROOT/tools/ditto" <<'STUB'
#!/bin/sh
printf 'ditto' >> "$CP_TEST_LOG"; printf '<%s>' "$@" >> "$CP_TEST_LOG"; printf '\n' >> "$CP_TEST_LOG"
for output in "$@"; do :; done
printf 'fixture archive\n' > "$output"
STUB
cat > "$TEST_ROOT/tools/spctl" <<'STUB'
#!/bin/sh
printf 'spctl' >> "$CP_TEST_LOG"; printf '<%s>' "$@" >> "$CP_TEST_LOG"; printf '\n' >> "$CP_TEST_LOG"
exit "${CP_TEST_SPCTL_EXIT:-0}"
STUB
chmod +x "$TEST_ROOT/tools/"*
PATH="$TEST_ROOT/tools:$PATH"
export PATH
unset CLAUDE_PROFILES_SIGNING_MODE CODESIGN_IDENTITY CODESIGN_KEYCHAIN APPLE_TEAM_ID NOTARY_KEYCHAIN_PROFILE NOTARY_KEYCHAIN NOTARY_REPORT_DIR
COUNT=0
new_case() {
    COUNT=$((COUNT + 1))
    CP_TEST_LOG="$TEST_ROOT/case-$COUNT.log"; export CP_TEST_LOG
    : > "$CP_TEST_LOG"
    OUTPUT="$TEST_ROOT/archive-$COUNT.zip"
    NOTARY_REPORT_DIR="$TEST_ROOT/report-$COUNT"; export NOTARY_REPORT_DIR
}
fail() { echo "Distribution fixture $COUNT failed: $*" >&2; cat "$TEST_ROOT/output.log" >&2; exit 1; }
ok() { "$@" > "$TEST_ROOT/output.log" 2>&1 || fail 'expected success'; }
reject() { if "$@" > "$TEST_ROOT/output.log" 2>&1; then fail 'expected rejection'; fi; }
has() { grep -F -- "$1" "$CP_TEST_LOG" > /dev/null || fail "missing tool call: $1"; }
absent() { if grep -F -- "$1" "$CP_TEST_LOG" > /dev/null; then fail "unexpected tool call: $1"; fi; }
no_archive() { [ ! -e "$OUTPUT" ] || fail 'a rejected operation created a distributable'; }
signed() { env CLAUDE_PROFILES_SIGNING_MODE=developer-id CODESIGN_IDENTITY='Developer ID Application: Fixture (ABCDEFGHIJ)' APPLE_TEAM_ID=ABCDEFGHIJ "$@"; }
notarize() { env APPLE_TEAM_ID=ABCDEFGHIJ NOTARY_KEYCHAIN_PROFILE=fixture-profile "$@" sh "$ROOT/scripts/notarize-app.sh" "$APP" "$OUTPUT"; }

new_case; ok sh "$ROOT/scripts/sign-app.sh" "$APP"
has '<--sign><->'; absent '<--timestamp>'; absent '<-R='
new_case; reject env CLAUDE_PROFILES_SIGNING_MODE=unknown sh "$ROOT/scripts/sign-app.sh" "$APP"; absent 'codesign'
new_case; reject env CLAUDE_PROFILES_SIGNING_MODE=developer-id sh "$ROOT/scripts/sign-app.sh" "$APP"; absent 'codesign'
new_case; reject env CLAUDE_PROFILES_SIGNING_MODE=ad-hoc CODESIGN_IDENTITY=anything sh "$ROOT/scripts/sign-app.sh" "$APP"; absent 'codesign'
new_case; reject env CLAUDE_PROFILES_SIGNING_MODE=developer-id CODESIGN_IDENTITY=fixture APPLE_TEAM_ID=bad sh "$ROOT/scripts/sign-app.sh" "$APP"; absent 'codesign'
new_case; reject signed env CP_TEST_SIGN_FAIL=1 sh "$ROOT/scripts/sign-app.sh" "$APP"; absent '<--sign><->'
new_case; ok signed env CODESIGN_KEYCHAIN="$TEST_ROOT/isolated keychain" sh "$ROOT/scripts/sign-app.sh" "$APP"
has '<--options><runtime><--timestamp>'; has "<--keychain><$TEST_ROOT/isolated keychain>"
has 'certificate leaf[subject.OU] = "ABCDEFGHIJ"'; has '1.2.840.113635.100.6.1.13'
first="$(head -n 1 "$CP_TEST_LOG")"
case "$first" in *'/Contents/Helpers/claude-profiles>'*) ;; *) fail 'helper was not signed first' ;; esac
absent '<--deep><--force>'; absent '<--requirements>'; absent '<--sign><->'
new_case; reject signed env CP_TEST_VERIFY_FAIL=1 sh "$ROOT/scripts/sign-app.sh" "$APP"
new_case; reject signed env CP_TEST_NO_RUNTIME=1 sh "$ROOT/scripts/sign-app.sh" "$APP"
new_case; reject signed env CP_TEST_NO_TIMESTAMP=1 sh "$ROOT/scripts/sign-app.sh" "$APP"
new_case; reject signed env CP_TEST_IDENTIFIER=unexpected sh "$ROOT/scripts/sign-app.sh" "$APP"
new_case; reject sh "$ROOT/scripts/notarize-app.sh" "$APP" "$OUTPUT"; absent 'notarytool'; no_archive
new_case; reject notarize CP_TEST_VERIFY_FAIL=1; absent 'notarytool'; no_archive
new_case; reject notarize CP_TEST_NOTARY_STATUS=Invalid; absent '<stapler>'; no_archive
new_case; reject notarize CP_TEST_NOTARY_EXIT=1; absent '<stapler>'; no_archive
new_case; reject notarize CP_TEST_INVALID_JSON=1; absent '<stapler>'; no_archive
new_case; reject notarize CP_TEST_STAPLER_EXIT=1; absent 'spctl'; no_archive
new_case; reject notarize CP_TEST_SPCTL_EXIT=1; no_archive
new_case; ok notarize NOTARY_KEYCHAIN="$TEST_ROOT/isolated keychain"
has '<--keychain-profile><fixture-profile><--keychain>'; has '<stapler><staple>'; has '<stapler><validate>'; has 'spctl<--assess>'
[ -f "$OUTPUT" ] || fail 'accepted distribution was not packaged'
[ -f "$NOTARY_REPORT_DIR/result.json" ] || fail 'submission result was not retained'
awk '
  /xcrun<stapler><validate>/ { validated = 1 }
  /spctl<--assess>/ { assessed = 1 }
  /ditto.*distribution.zip/ { if (!validated || !assessed) exit 1; packaged = 1 }
  END { if (!packaged) exit 1 }
' "$CP_TEST_LOG" || fail 'final packaging happened before ticket validation and assessment'
# Repeated runs must not replace a previous output or submission record.
reject notarize; has '<stapler><validate>'
new_case; mkdir "$NOTARY_REPORT_DIR"; printf '{"previous":true}' > "$NOTARY_REPORT_DIR/result.json"
reject notarize; absent 'notarytool'; no_archive
printf 'Distribution shell fixtures passed: %s cases (no real signing or submissions).\n' "$COUNT"
