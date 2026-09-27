# Continuity: verification and limits

Claude Profiles supports two different forms of continuation. Ordinary local Code sessions share their existing transcript. Projects and Cowork need a separate native conversation in the destination account, supplied with captured context. That second conversation has its own ID, history, tools and permissions. Here, a **workspace** means Claude Profiles' private local context archive, not a Claude cloud Project.

This document describes the current source implementation. Release v0.2.0 offers the manual handoff form; the captured-workspace workflow is newer development work. A version number, passing unit tests or a visible sidebar card does not establish that a particular Claude session can continue. Confirm the behavior below in the installed app.

## Available paths

| Source | What the implementation preserves | What still needs verification |
|---|---|---|
| Ordinary local Code | Existing local transcript, eligible sidebar card and supported local setup. Cards synchronize at launch, periodically and on demand. | The destination opens that transcript and its working folder; a fresh response uses its early and recent context. Use one window at a time. |
| Local Cowork | Every record in the available local task JSONL transcripts, including available tool results, subagents and rewind history; supported local project instructions/memory; supported uploads, outputs and transcript metadata. | Source history must be present. Read the manifest: external folders, cloud-only context, profile-wide memory, credentials and live runtime are excluded or unavailable. Exact history can exceed the destination's usable context. |
| Code Projects | One current view, or a bounded sweep of supported General goal/instructions, memory files, observed thread groups/links, older message pages/tool results and Library inventory pages. | Always partial. Hidden threads, unsupported scrolling, older history and original artifact bytes may be missing. The implementation has automated tests; live Accessibility operation and complete historical coverage remain unverified. |
| Cloud Cowork conversations | One current view, or a bounded sweep of pagination, tool details and supported scrolling within the open conversation. | Always partial. It does not navigate the Cowork project or other tasks, infer local JSONL history, or copy attachments/runtime. Live sweep operation remains unverified. |
| Manual handoff | The exact context the user enters, saved as Markdown. | Completeness depends on that supplied context. This path does not fetch the source conversation. |

Captures do not need a response from the source model, so reading available local history or an open view can work while its account has no remaining model quota. The destination still needs its own access and remaining quota. Claude Profiles does not combine limits or switch accounts automatically.

## First check on your Mac

Use a small task with an identifiable early decision, a later result and a harmless output file. Keep the original available until the round trip succeeds. Do not change profile storage by hand to make this check pass: the purpose is to verify the normal installed workflow.

1. **Record versions and identity.** Record the installed Claude Profiles version, Claude Desktop version/build, macOS version and the source/destination profile labels. Verify the signed-in account in both native windows. Launch profiles through Claude Profiles or their labeled launchers. Verify that the required Projects or Cowork feature is actually present in the destination account.
2. **Check local prerequisites.** Run **Check sessions**. Resolve missing history or working folders relevant to this task. Its report checks local consistency; it does not prove cloud access. Confirm any needed folder, Remote Control connection and tool access separately in the destination account.
3. **Stop at a known point.** Finish or pause source work, including workers that could still change its files. A checkbox in Claude Profiles records your confirmation; it cannot pause a cloud worker for you.
4. **Use the matching path below.** Review the actual history and files, rather than relying on the conversation's title or a summary.
5. **Verify in the destination.** Ask for the original objective, the early decision, the latest result with evidence, the exact output contents and the next action. Check those answers against the source. Have Claude list unavailable context and tools. A successful open, attachment upload or plausible answer alone is insufficient.
6. **Continue one small task.** After context verification and activation, perform a small authorized next step. Check its output yourself. Pause there, carry its latest context back and verify the original account can use that new result. Only this round trip establishes continuation for the tested workflow and versions.

### Ordinary local Code

Finish the active turn and close the session in the source window. In **Continue work…**, use **Share local sessions now**. Restart an already open destination window once its other tasks finish so it reloads the cards. Open the same local session, confirm the earlier messages and working folder, then perform steps 5–6 above. Native Project/Remote Control worker cards are excluded from cross-account sharing even when they look like local sessions.

### Local Cowork

1. Choose **Read local Cowork history and files…**, select the source profile/task, confirm it is paused, then choose **Read selected history**.
2. Review the transcript, file inventory and limitations. Save the captured context to a new workspace, or append to the workspace already used for this work. If the source changes after review, refresh and capture it again; the old review is not accepted as current.
3. Review the saved files. Use **Copy context check & open profile**, then select an appropriate new destination conversation or Project and give it access to the workspace folder. Paste and send the copied read-only check. If a Project coordinator cannot read local files, that check permits one read-only helper solely to inspect the supplied context. Missing access must be reported before work begins.
4. Compare its answer with the saved source. Paste this new native conversation's link into Claude Profiles, confirm it checked the context and listed gaps, then choose **Record continuation & copy work prompt**. This records the separate destination object and active profile. Send the work prompt only in that verified conversation.
5. Before another switch, capture the newest stopping point and append it to the same workspace. Earlier captures remain there. If the new conversation is cloud-only, local Cowork capture cannot read it: use **Read available views**, a single current-view capture or a reviewed manual handoff. Supply missing history/files explicitly; the Accessibility capture is partial even after a sweep.

### Code Projects and cloud Cowork

Open the relevant source, then choose **Read visible Project or Cowork context…**. Use **Read current view** for one view or **Read available views** for the bounded sweep. macOS Accessibility must already be enabled for Claude Profiles; capture reports missing access without enabling it itself. Verify the selected profile and source before starting, and leave that Claude window untouched during the sweep. Cancellation retains the views already read so they can still be saved.

For Code Projects, the sweep reads supported General goal/instruction fields and memory files, opens observed thread groups and links, loads available older pages and tool results, and visits Library inventory pages. For a cloud Cowork conversation, it only paginates, opens tool details and scrolls that conversation; it never performs Project navigation. Both use only allowlisted native Accessibility actions and stop at action/time/view limits or a changed source.

Review the captured views, inventory and gaps. Manually capture any relevant view the sweep could not visit, and append it to the same workspace. A Library filename/link is an inventory item, not the bytes of its document; an embedded artifact needs its own original file or a separately verified capture. A scroll boundary does not prove that every historical message was loaded. Neither mode claims a complete Project or conversation export. Automated tests cover the bounded sweep, while its live application check remains pending Accessibility access.

The checked native Project artifact menu offered Open, Pin, View thread and Copy link, but no Download action. Do not assume that every Project artifact can be downloaded. Add an original file only when it is already available locally or can be obtained through a supported export/download; otherwise keep its reference and unavailable-content gap explicit. The separate selected-file workflow does not grant access to an unavailable cloud original.

In **Open saved workspace…**, use **Add downloaded/selected files…** to select those available originals. Their exact bytes are appended while earlier context is retained, and Library coverage stays partial. Adding files clears prior review/verification and export references: review the updated workspace, export it again if needed, and verify its new context in the destination before continuing. This workflow has automated tests, and one selected PDF passed live export, native upload and content-reading checks. Other formats and cloud originals remain unverified.

Use **Open saved workspace…** to inspect its captured files and coverage. Create a separate destination Project/conversation through Claude's native UI. Supply the reviewed available context and required files, then use the read-only context check. A cloud Project cannot read a Mac path alone; use a reviewed export or an appropriately connected local worker. A new Cowork conversation may need that first read-only message before its native URL exists. After verifying its reply, register that native link, acknowledge the paused source and activate the destination before copying a work prompt.

The capture sheet only saves context; it does not create or populate the destination Project. Record remaining gaps before work. If required history, files or access cannot be obtained, the acceptance result is **partial**, not passed. The live text-transfer check below did not test a complete cloud Project capture or the bounded Accessibility sweep.

## Preservation, privacy and export

Workspaces live under `~/Library/Application Support/Claude Profiles/Workspaces/<workspace-id>`. Each contains `CONTINUE.md`, `LATEST.json` and immutable snapshots. The manifest records source profiles/links, file sizes and SHA-256 hashes, coverage, limitations and known destination links. New captures append rather than replacing earlier context. Saved payloads are data files; historical instructions are not new authorization. Directories are owner-only and files are readable/writable only by their owner.

The app verifies stored payload integrity and rejects stale revisions. Its one-active-profile record prevents conflicting changes within this workflow; it is not a service-level execution lock. A manually resumed native conversation can still run elsewhere. Source credentials and native runtime are not migrated. Exact transcripts and tool output may themselves contain sensitive information from earlier work, so review the capture before supplying it to another account.

The current source exposes these CLI commands for an already saved workspace:

```text
claude-profiles workspace-info PATH [--json]
claude-profiles workspace-export PATH --to NEW_FOLDER --revision N
```

Review the coverage and revision shown by `workspace-info`; use that revision for export. `NEW_FOLDER` must not exist. Export produces:

- `CONTEXT.md`: every captured text entry, quoted with its manifest and coverage; this is not a generated summary.
- `files/`: individual original file bytes under safe prefixed filenames that retain their extensions.
- `ATTACHMENTS.json`: the mapping from those filenames to original logical paths, sizes and hashes.
- `workspace.zip`: the manifest and retained payloads for local restoration or backup.

Attach `CONTEXT.md` through Claude's normal file picker, then attach required files from `files/` individually when their formats are supported. The live Cowork test accepted the Markdown file but showed the ZIP as disabled and unselectable. Keep the ZIP as a local archive; it is not a supported native Project import. Do not rename an unsupported file to bypass the picker. List any rejected or unreadable file as missing context and supply an accepted representation separately if needed.

The initial one-way text check below passed without binary artifacts; a subsequent selected PDF passed live export, native upload and content-reading checks. Other attachment formats, complete cloud Project capture and a return trip remain unverified. An accepted attachment also does not prove that every byte fits the model's context or was read. Older installed builds may not expose these export commands or the individual-file export.

## Updating and rollback

Quit Claude Profiles before updating it; Claude windows may remain open for the application installer. The installer stages and verifies the new app and retains the previous app beside it as `.previous-<date>-<id>.app`. That is an application rollback copy, not a backup of your sessions. Profile data, ordinary Code transcripts and workspaces remain in their existing locations. Keep a normal backup of those locations if the work matters.

After Claude Desktop updates, finish work and close a profile before rebuilding its engine. A replacement engine is staged and its version, executable and signature verified before atomic replacement; a failure preserves or restores the old engine. A successfully verified replacement does not retain a permanent previous-engine archive. Never delete profile data to fix an engine update.

Repeat the small acceptance check for each workflow you depend on after an upstream update. The local storage and Accessibility structures are observed implementation details, not an Anthropic compatibility API. If a new build refuses a source format or page, keep the source intact and report the version and failure; a guessed or truncated capture is not a substitute.

## Validation record

A live native-UI pilot used an installed **0.3.0 development build** of Claude Profiles and Claude Desktop **2.9939.2**. This is not a public v0.3.0 release announcement or a claim about other engines/accounts. Private task content, profile identities and native links are omitted here.

The source was one local Cowork task. Its capture retained one exact JSONL transcript with **21 records**, its rendered text and source metadata: **three text payloads totalling 211,534 bytes**, with **zero binary artifacts**. `CONTEXT.md` was uploaded through the normal file picker into a new native Cowork conversation in another profile. Its read-only reply correctly identified the original objective, earlier access failures, the latest unchanged state, record/byte counts and missing context. It did not resume the historical task. It also explicitly recognized that the ZIP, global memory, tools and permissions had not been supplied.

A separate synthetic one-page PDF was then added through the installed app, exported as an individual file and uploaded through Claude's normal picker. The exported bytes and SHA-256 matched the original; the destination correctly read its identifier, three values and total without those answers being provided in the prompt. This checks one supported file type, not cloud Library extraction or arbitrary attachments.

This demonstrates **one-way reading of the available local text context and one selected PDF**. Use the checklist to record your own versions, early/latest facts and output evidence; neither this pilot nor unit tests establish a complete Project migration.

| Check | Evidence | Result |
|---|---|---|
| Installed development app | GUI identified development version 0.3.0; Claude engine 2.9939.2 | Observed in this pilot |
| Ordinary local Code round trip | Same transcript, early/latest facts, working-folder access and returned result | Not tested in this pilot |
| Local Cowork capture | 1 JSONL, 21 records, 3 retained text payloads, 211,534 payload bytes, 0 binary artifacts | Passed for this text-only source |
| Text upload and destination reading | Native picker accepted `CONTEXT.md`; separate native Cowork gave the checked read-only answer | Passed one way |
| ZIP attachment | Native picker greyed out `workspace.zip` and did not allow selecting it | Rejected; use as a local archive |
| Individual attachment | One synthetic PDF added/exported through the app, exact bytes/hash checked, accepted by the native picker and content correctly read by destination Cowork | Passed for this PDF; other formats and cloud originals unverified |
| Bounded sweep implementation | Automated fixtures cover supported Project/Cowork navigation, data preservation, limits and source changes | Automated tests passed; live Accessibility operation pending |
| Cloud Project coverage | Views/threads/documents inspected; missing history, Library files and artifacts listed. Checked artifact menu had no Download action. | Full capture and automatic sweep not live-verified; cloud originals are not guaranteed |
| Return to another profile | New stopping point appended, earlier context retained, latest result correctly used after switching back | Not yet verified |
| Upgrade | Previous app retained, profile data preserved, required continuation checks repeated on new engine | Not tested in this pilot |

Unit tests cover data preservation, source changes, unsafe paths, integrity, revision conflicts, capture exclusions and update rollback. They cannot establish which account has a cloud feature, whether a particular model read a large attachment, or whether live Claude UI continued the work. Record those separately with a real task.

Anthropic describes account ownership and availability in [Code Projects](https://code.claude.com/docs/en/claude-projects), [Remote Control](https://code.claude.com/docs/en/remote-control), [Cowork projects](https://support.claude.com/en/articles/14116274-organize-your-tasks-with-projects-in-claude-cowork) and [account data export](https://support.claude.com/en/articles/9450526-export-your-claude-data). Native sharing permissions, where available, remain separate from Claude Profiles' local context workflow.
