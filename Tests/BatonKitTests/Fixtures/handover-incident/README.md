Writes Tests/BatonKitTests/Fixtures/handover-incident: the limit handover of 29 September 2026, sanitized.

Usage: scripts/e2e/make-incident-fixture.py   (rewrites the fixture folder; commit what it writes)

ATLAS is open and at its five-hour limit. Its 70 sessions: 42 cards Remote Control made (6 in a folder ATLAS still
serves, 2 in a folder both ATLAS and CEDAR serve, 34 in a folder no window serves), 19 in a folder a rule keeps for
ATLAS's and CEDAR's accounts, and 9 ordinary ones. One group holds 64 of them, a second group 3; 15 are pinned. The
limit cut 8 sessions mid-turn, and 3 of those have an auto-continue entry. BRAVO has the most room and is closed;
CEDAR and the main window have less.

Times are tokens the materializer replaces, relative to when a test or scripts/e2e-handover.sh runs:
"@S+7200@" (epoch seconds), "@MS-600@" (epoch milliseconds), "@ISO-300@" and "@ISOF-300@" (ISO 8601, the second with
milliseconds). Local Storage and IndexedDB are described in stores.json and written by the materializer with Baton's
own LevelDB writer, which also makes stand-ins for Claude.app and the profiles' app copies, and renames dot-claude to
.claude (hidden folders don't travel as test resources). Every account, email, label, folder and title is made up.
