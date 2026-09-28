# Lane C notes for integration

New Kit files this lane added (nobody else owns them): `AppInstances.swift`, `Redactor.swift`,
`FeedbackReport.swift`, `WindowStatus.swift`, plus `Sources/ClaudeProfiles/ReportSheet.swift`.
No file of another lane was edited. `WindowStatus.swift` adds `extension ProfileManager { func restart(_:) }`
using the module-internal `runningClaudes()`, `engineIsOutdated(_:)` and `RunningClaude.uses(...)`; if lane B
renames those, only that file needs updating.

## For lane B (W10 Local only, W18 wiring)

Local only is shown as "unknown" until W18 passes it in. The hooks already take a per-window map:

- `FeedbackReport.Facts.collect(paths:user:errors:log:lastSync:lastSyncDate:localOnly: [String: Bool])`
  keyed by window id (`"main"` or the profile id).
- `WindowStatus.collect(manager:diagnostics:localOnly: [String: Bool], pending: [String: [String]])`;
  `pending` is the list of "waiting for a restart" lines per window (e.g. "Local only turns on").

Assumed API from `LocalOnly.swift` (not on this branch): something like
`LocalOnly(paths:).state(for windowID: String) -> Bool?` and a way to tell that a change is written but not yet
applied because the window is open. W18 should build the two maps from it in `AppModel.makeReport()`,
`AppModel.refreshStatus()` and `FeedbackReport.command`.

## For lane D (W22 issue templates, W23 docs)

- The app and CLI open
  `https://github.com/<FeedbackReport.repository>/issues/new?template=bug_report.yml&title=…&body=…`.
  GitHub issue forms prefill a field only from a query parameter named after the field's `id`, so
  `bug_report.yml` needs a `textarea` with `id: body` (label e.g. "Report") for the prefilled text to land, plus
  the required "I reviewed the text" checkbox. The body's headings are: `### Environment`, `### Windows`,
  `### Sessions check`, `### Last sync`, `### Recent errors`, `### Log (last N entries)`,
  `### What happened (written by the user, not redacted)`, and for long reports `### Full report`.
- `FeedbackReport.repository = "trukhinyuri/ClaudeProfiles"` is the one place to change on a rename.
- CLI usage gained `claude-profiles report [--save PATH] [--open]`; README can document it.
- Demo screenshots: `CLAUDE_PROFILES_DEMO=1 CLAUDE_PROFILES_DEMO_SHEET=report` (Report a problem) and
  `…_DEMO_SHEET=status` (window status panel).

## Not done in this lane

- W14 String Catalog (English and Russian): slipped to 1.1 as the plan allows.
- W18: left for integration after A and B merge, as instructed.
- The UI changes (VoiceOver labels, widths, wording, the two new sheets) were not checked by hand with
  screenshots here; only built and unit-tested.
- The Browser pane check of the prefilled GitHub form could not run: the pane is not signed in to GitHub.
