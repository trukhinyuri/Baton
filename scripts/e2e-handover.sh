#!/bin/sh
# The limit handover of 29 September 2026, end to end, with the debug `baton` against a sandbox home and stand-in
# windows: nothing on this Mac is started, quit or read beyond the sandbox. Usage: scripts/e2e-handover.sh
#
# 1. The incident fixture (Tests/BatonKitTests/Fixtures/handover-incident) is written into a new temporary folder.
# 2. `baton handover --from ATLAS --dry-run --json`, then the same without --dry-run, with BATON_SANDBOX_HOME and
#    BATON_FAKE_LAUNCH, which only a debug build reads.
# 3. scripts/e2e/check-handover.py reads what changed and checks it.
set -eu

cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/baton-e2e.XXXXXX")
home="$work/home"
log="$work/fake-launch.log"
echo "Sandbox: $work"

swift build --build-tests >"$work/build.log" 2>&1 || { tail -20 "$work/build.log"; exit 1; }
BATON_E2E_HOME="$home" swift test --skip-build --filter HandoverScenarioTests/materializesTheIncidentForTheEndToEndScript \
    >"$work/materialize.log" 2>&1 || { tail -20 "$work/materialize.log"; exit 1; }
[ -f "$home/Library/Application Support/Baton/profiles.json" ] || { echo "FAIL  the fixture wasn't written" >&2; exit 1; }
python3 scripts/e2e/check-handover.py windows "$log" atlas
: >"$log"

baton="$(swift build --show-bin-path)/baton"
run() { BATON_SANDBOX_HOME="$home" BATON_FAKE_LAUNCH="$log" "$baton" "$@"; }

echo "== baton handover --from ATLAS --dry-run --json"
run handover --from ATLAS --dry-run --json >"$work/dry-run.json"
python3 scripts/e2e/check-handover.py dry-run "$home" "$work/dry-run.json"

echo "== baton handover --from ATLAS --json"
run handover --from ATLAS --json >"$work/result.json"
python3 scripts/e2e/check-handover.py result "$home" "$log" "$work/result.json"

echo "== stand-in windows"
cat "$log"
echo "End-to-end handover passed."
