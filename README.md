<p align="center">
  <img src="docs/images/app-icon.png" width="128" alt="Claude Profiles icon">
</p>

<h1 align="center">Claude Profiles</h1>

<p align="center">
  <b>All your Claude subscriptions, side by side.</b><br>
  Each of your Claude subscriptions runs in its own Claude Desktop window with its own Dock icon,<br>
  and your ordinary local Claude Code sessions follow you from one window to the next.
</p>

<p align="center">
  <a href="https://github.com/trukhinyuri/ClaudeProfiles/actions/workflows/ci.yml"><img src="https://github.com/trukhinyuri/ClaudeProfiles/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License"></a>
</p>

<p align="center">
  <img src="docs/images/main-window.png" width="820" alt="Claude Profiles window listing four subscriptions with their usage">
</p>

## Why

Claude Desktop holds one signed-in account at a time. If you pay for more than one subscription (a personal plan and a work plan, or one per client), switching means signing out and in again, losing open windows, and hunting for the session you were in.

Claude Profiles gives every subscription its own Claude window with its own Dock icon, all open at once. Ordinary local Claude Code conversations, local skills and memory can follow you between windows. Projects and Cowork use a different workflow: capture available context, check it in a new native conversation in the other account, then continue there. The original cloud object and its permissions stay with its account.

The continuation features described below reflect the current source checkout; check your installed release before expecting those controls. A session appearing in another sidebar is not proof that its history or Project is available. Use the [continuation acceptance checklist](docs/CONTINUITY.md) to check the actual workflow on your Claude version.

A live check of the development build successfully captured a local Cowork task, uploaded its text context through Claude's normal file picker, and verified that a new Cowork conversation in another profile understood the original objective, earlier events and latest state. This establishes one-way text-context reading for that test. A round trip, binary attachments and a complete cloud Project transfer remain unverified; see the [validation record](docs/CONTINUITY.md#validation-record).

## Features

- **One window per subscription.** Each profile is the official Claude Desktop app running with its own sign-in. No code is patched or injected.
- **Labeled Dock icons.** `WORK`, `LAB` or `TEAM` on a color of your choice tells you which account a window belongs to. The launchers work from Spotlight too.
- **Local Code continuity.** Ordinary local Claude Code sessions appear across windows. Project workers and cloud Cowork stay with their owning account; legacy local Cowork requires its original profile.
- **Shared local setup.** Before a profile window starts, it gets supported local tools and display preferences from the main app. Account settings, Remote Control access and cloud project state remain separate. Sign-ins are never copied.
- **Usage at a glance.** Five-hour and weekly usage for every subscription, from what Claude Desktop itself records. The one with the most headroom is highlighted.
- **Knows who is signed in.** Every row shows the email of the account in that window and warns if it is not the one you intended.
- **Easy to add and remove.** Enter an email, sign in inside the new window, done. Removing moves the profile to the Trash, so nothing is lost by accident.
- **Capture local Cowork context.** **Continue work…** can save the available local task transcripts, tool results, subagent history, local project context and selected task artifacts without asking the source Claude to summarize. Review the recorded gaps, verify the context in a new destination conversation, then register that conversation before continuing.
- **Capture available Project and Cowork views.** Read one view or run a bounded read-only sweep through supported Project sections or the open Cowork conversation. Save discovered text, references and gaps in the same workspace. The result remains partial; it does not establish a complete cloud history or export original artifact files. A manual reviewed handoff is also available.
- **Session checks.** Use **Check sessions** or `claude-profiles doctor` to inspect local session inventory, account-owned workers, missing working folders or local Cowork history, and each profile's Remote Control configuration without changing anything.
- **Menu bar and CLI.** Open any subscription from the menu bar, or script it with `claude-profiles`.
- **Rebuilds profile copies after Claude updates.** App copies use APFS clones where supported and are staged and verified before replacement. Recheck your continuation workflow after upstream updates because Claude's storage and interface can change.

<p align="center">
  <img src="docs/images/add-subscription.png" width="620" alt="Add a Subscription sheet with a live Dock icon preview">
</p>

## What follows you between profiles

| Work or setting | Behavior |
|---|---|
| Ordinary local Claude Code sessions | Local transcripts stay in `~/.claude`; Claude Profiles shares the sidebar cards. Continue a session in one window at a time. |
| Local Code settings, skills, hooks and memory | Claude reads the same local configuration. Supported Desktop setup and display preferences are also synchronized before a profile opens. |
| Legacy local Cowork sessions | The native session and runtime stay in their original profile. Capture all available local task transcripts and the supported task files into a reviewed workspace; use them in a new conversation elsewhere. Missing or excluded context is listed. |
| New Claude Code Projects, coordinator, memory, Library and threads | Belong to their Claude account. A bounded capture visits supported settings, memory, observed threads and Library inventory; coverage stays partial. A destination Project is a separate native object; local Project workers also retain their owner. |
| Cloud Cowork tasks and projects | Saved to the Claude account. The bounded conversation capture reads available messages/tool details in the open task; other project context needs separate capture. Local card synchronization does not transfer the original. |
| Remote Control, connected folders and permissions | Configured separately in the profile that will run the work. A folder connected in one account is not automatically exposed to another. |
| Cloud connectors, account instructions, model access and feature availability | Managed by Claude for each account or organization. Configure them in that account's Claude settings. |
| Scheduled tasks | Stay with the account that created them; their schedules are never copied. |

To continue a **new Code Project**, open the profile where you created it, then open **Projects**. Its coordinator, memory and threads are preserved by Claude. If you sign into that same Claude account on another supported device, its cloud work is available there too. Separate subscriptions do not gain access by copying local files; the new Code Projects beta does not support sharing a project with another user. Shared Chat/Cowork projects on Team and Enterprise use Claude's own sharing permissions.

For a Project task that needs your Mac, enable Remote Control and connect the required folder in that profile's **Settings → Claude Code**, then request **Work locally** in the Project. Keep that profile open and the Mac awake. These workers receive the Project's instructions, but its memory is not automatically loaded locally; include the needed context in the task brief.

Claude is rolling out new Projects and the combined Chat/Cowork experience account by account. Different windows can legitimately show different features. Claude Profiles does not copy rollout flags to make them match. See Anthropic's [Code Projects reference](https://code.claude.com/docs/en/claude-projects), [Remote Control](https://code.claude.com/docs/en/remote-control), [Cowork architecture](https://support.claude.com/en/articles/14479288-claude-cowork-architecture-overview), [Cowork projects](https://support.claude.com/en/articles/14116274-organize-your-tasks-with-projects-in-claude-cowork) and [combined Chat/Cowork experience](https://support.claude.com/en/articles/16761823-claude-cowork-and-chat-are-one-claude).

## Staying within Anthropic’s terms

Claude Profiles is built for people who pay for more than one Claude subscription and use each of them themselves. It deliberately does **not** try to get around how Anthropic meters usage:

| Claude Profiles does | Claude Profiles does not |
|---|---|
| Run the official Anthropic-signed Claude Desktop app for every subscription (a local copy whose only change is its Finder icon) | Patch Claude, inject code or call private APIs |
| Let **you** sign in to each window with the official sign-in flow | See, store, copy or forward passwords, email codes or OAuth tokens |
| Show usage that Claude Desktop already records locally | Proxy, pool, share or combine limits between accounts |
| Let **you** choose which window to work in | Switch accounts automatically when a limit is reached |
| Keep every subscription separate, each with its own limits | Help anyone share one subscription among several people |

Each subscription keeps its own limits, applied by Anthropic as usual; Claude Profiles doesn’t raise any of them. Use only subscriptions that are yours and follow Anthropic’s [Consumer Terms](https://www.anthropic.com/legal/consumer-terms) and [Usage Policy](https://www.anthropic.com/legal/aup). If your plans come from an employer, check that their policies allow this setup. This project is not legal advice.

## Install

Requirements: macOS 14 or later, [Claude Desktop](https://claude.ai/download) in `/Applications`, and Xcode or the Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/trukhinyuri/ClaudeProfiles.git
cd ClaudeProfiles
make install        # builds Claude Profiles.app and copies it to ~/Applications/Claude Profiles
```

Quit **Claude Profiles** before updating; the Claude windows themselves can stay open. The installer stages and verifies the new app before replacing it, and keeps the old app beside it as `.previous-<date>-<id>.app` for rollback. Profile data is not replaced. If you moved the source checkout and Swift reports stale build paths, choose a fresh build directory with `CLAUDE_PROFILES_BUILD_DIR=/tmp/claudeprofiles-build make install`.

Builds are signed ad hoc on your Mac, so Gatekeeper doesn’t get involved. If you download a prebuilt `.zip` from [Releases](https://github.com/trukhinyuri/ClaudeProfiles/releases) instead, macOS will ask you to confirm the first launch in **System Settings → Privacy & Security → Open Anyway**.

## Use it

1. Open **Claude Profiles** and click **Add Subscription**.
2. Enter the account’s email and, if you like, change the Dock label and color.
3. A new Claude window opens. Sign in there with that account, with Google or with email.
4. To keep a profile in the Dock, drag its launcher from `~/Applications/Claude Profiles` (**⋯ → Show Launcher in Finder**) to the Dock. Spotlight finds launchers too (“Claude WORK”). **Keep in Dock** on a running profile window pins the app copy itself, which opens without the profile’s sign-in. While Claude Profiles is running (it stays in the menu bar), it notices that and reopens the window with its profile; the launcher works even when it isn’t.
5. To continue an ordinary local Code session in another profile, finish its active turn and close it in the first window, then open it from the other window's sidebar. To carry Projects or Cowork work into another profile, use **Continue work…** as described below.

> [!IMPORTANT]
> Don’t work in the same session from two windows at the same time. Close it in one before continuing in another.

To remove a subscription, choose **⋯ → Remove Subscription…**. Its window closes and its app copy and sign-in move to the Trash. Ordinary local Code transcripts remain in `~/.claude`. Legacy Cowork sessions whose files live in that profile move to the Trash with it; old card copies in other profiles are left untouched and do not preserve that history. Cloud projects remain with their Claude account, but this profile can no longer serve their local work.

### Continue work in another profile

**Ordinary local Code:** stop or finish the current turn, select **Share local sessions now** in **Continue work…**, then open the same session in the destination profile. If that window was already open, restart it after its other tasks finish so Claude reloads its local cards. The transcript stays the same; avoid editing it in both windows at once.

**Local Cowork history:** choose **Read local Cowork history and files…**. Pause the source task, select it and read the capture. Save it to a new private workspace or append it to an existing one; earlier captures remain available. Review its history, files and explicit gaps. Use **Copy context check & open profile** to verify that a new destination conversation can read the saved context before it starts work. After checking its reply, record its native link and use **Record continuation & copy work prompt**. You paste and send each prompt yourself. The workspace records one active profile; it does not stop Claude or enforce a lock in Anthropic's service.

**Cloud Projects or cloud Cowork:** choose **Read visible Project or Cowork context…** while the source is open. **Read current view** reads only that view. **Read available views** runs a bounded read-only sweep: Code Projects include supported goal/instruction settings, memory files, observed thread groups and links, available older messages/tool details, and Library inventory pages. In Cowork it stays within the open conversation, reading available pagination, tool details and supported scrolling. Leave the selected Claude window untouched during the sweep; cancel if needed, then save the views already read. It sends no messages or setting changes. Captures remain **partial** because historical boundaries, hidden branches and original artifact bytes are not proven complete. The sweep has automated test coverage; its live Accessibility-based operation remains unverified. Follow the [acceptance checklist](docs/CONTINUITY.md) before using its result.

**Saved workspaces:** **Open saved workspace…** lets you inspect saved coverage and files, export captured context, verify it in a separate native destination and record where work is active. A cloud Project cannot read a Mac path by itself; attach `CONTEXT.md` and any required supported files from the export's `files/` folder, or configure an appropriate local worker. `workspace.zip` is a local backup/portable archive: the tested native Cowork picker rejected ZIP uploads. Check missing or unsupported attachments explicitly. Saving or uploading files alone does not establish successful continuation; follow the [acceptance checks](docs/CONTINUITY.md).

Use **Add downloaded/selected files…** for originals you already have or can obtain through a supported export/download. It preserves their exact bytes and earlier workspace context, keeps Library coverage partial, and clears the previous destination verification so the updated context must be checked again. Live attachment ingestion remains unverified.

**Manual handoff:** if the automatic local capture does not cover your task, you can still supply reviewed context:

1. Click **Continue work…**, then **Copy handoff request for source Claude**. Paste the request into the original conversation while it can still respond. If the source has already reached its limit, write the context yourself from its visible transcript, files and decisions.
2. Review the context and paste it into the form. Include the objective, current state, completed work and evidence, remaining steps, required files/tools, and the next action. Choose the source and destination profiles; optionally add the source conversation link and an existing working folder.
3. Click **Save handoff & open destination**. Claude Profiles saves a private local Markdown file and copies a continuation prompt to the clipboard. Paste it into a new conversation in the destination profile, review it and send it yourself.

The original Project, memory, Library and cloud thread history stay in their account. Local Cowork capture preserves available history as reference files for a new conversation; it does not install that history as the destination's original native session or move its live runtime. Neither capture nor a manual handoff grants access to source connectors or external working folders. Configure those in the destination separately. Before switching back, pause the destination and append its latest context to the same workspace, then verify the next destination again.

Saved manual handoffs are in `~/Library/Application Support/Claude Profiles/Handoffs`; captured workspaces are in the adjacent `Workspaces` directory. The app reads source content only when you use the corresponding capture controls. It never sends a handoff or starts destination work automatically. See [Continuity: verification and limits](docs/CONTINUITY.md) for the full acceptance checklist and the status of portable workspace exports.

### Command line

```text
claude-profiles list                          Show every profile, its account and plan usage
claude-profiles add <email> [--label TEXT] [--color #RRGGBB]
                                               Create a profile and open it to sign in
claude-profiles open <profile>                Open a profile's window (id or label)
claude-profiles remove <profile>              Quit it and move its copy and sign-in to the Trash
claude-profiles sync                          Share ordinary local Code session cards across profiles now
claude-profiles doctor [--json]               Inspect sessions and per-profile setup without changing it
claude-profiles cowork-history <profile> [--json]
                                               List available local Cowork history; does not capture cloud tasks
claude-profiles workspace-info <path> [--json]
                                               Verify saved workspace bytes and show coverage and native links
claude-profiles workspace-export <path> --to <new-folder> --revision <n>
                                               Export the reviewed revision without uploading or sending it
claude-profiles handoff --from <profile> --to <profile> --title <text> --context <file>
                       [--folder <absolute-path>] [--source-url <claude.ai-url>] [--open]
claude-profiles refresh                       Rebuild app copies after a Claude Desktop update
```

The `handoff` command saves a Markdown file from context you have reviewed and prints its path. Add `--open` to open the destination profile. Unlike the GUI, the CLI does not change the clipboard; copy the saved context into a new conversation yourself. It does not fetch a cloud transcript. For example:

```sh
claude-profiles handoff --from WORK --to LAB --title "Continue API migration" --context ./handoff.md --open
```

The workspace commands operate on an existing saved workspace. `workspace-info` verifies its stored files, not destination access. `workspace-export` requires the revision you reviewed and a new destination folder. It produces `CONTEXT.md`, individual files in `files/`, their provenance mapping in `ATTACHMENTS.json`, and `workspace.zip` for local backup/restoration. Attach supported files individually in Claude; the archive is not a native import format. See [export status](docs/CONTINUITY.md#preservation-privacy-and-export) for what has actually been checked.

The binary ships inside the app: `ln -s ~/Applications/Claude\ Profiles/Claude\ Profiles.app/Contents/Helpers/claude-profiles /usr/local/bin/`.

## How it works

| What | Where |
|---|---|
| Main Claude app (untouched) | `/Applications/Claude.app`, data in `~/Library/Application Support/Claude` |
| Profile app copies (APFS clones with a Finder icon) | `~/Applications/Claude Profiles/.engines` |
| Launchers you can keep in the Dock | `~/Applications/Claude Profiles/Claude <LABEL>.app` |
| Each profile’s sign-in and window state | `~/Library/Application Support/Claude Profiles/Profiles/<id>` |
| Profile list and backups | `~/Library/Application Support/Claude Profiles` |
| Captured context, provenance and continuation links | `~/Library/Application Support/Claude Profiles/Workspaces/<workspace-id>` |
| Local Claude Code transcripts, settings, skills, memory | `~/.claude` (already shared by every window) |
| Cloud Projects, cloud Cowork and account settings | Anthropic services, under their owning Claude account |

A profile is Claude Desktop started with its own `--user-data-dir`, which is standard Electron behavior. For ordinary local Code sessions, sharing copies the small sidebar cards between account folders; the conversations themselves already live in `~/.claude`. While any Claude window is open, Code sharing only adds and updates; deletions propagate only when all windows are closed. Replaced and removed Code cards are backed up first.

Legacy local Cowork synchronization is inventory-only. Claude Profiles does not update or delete its native cards, files or old synchronization state. An explicit capture copies supported source content into a separate private workspace. Claude loads native Cowork history from the current profile's account and organization directory, so copying a sidebar card can open a blank conversation instead of the original history. Existing copies from earlier versions are preserved. Open the session in its original profile, or use **Continue work…** to prepare a new conversation elsewhere.

A Code card marked as a native Project or Remote Control worker stays within its account and organization. If an older Claude Profiles version already copied one across account boundaries, the owner is ambiguous: those copies stay untouched and are excluded from synchronization, and **Check sessions** reports them for review. This does not delete the worker, move its files or make its cloud Project available in another account.

Before a profile window starts, Claude Profiles synchronizes local extensions and MCP definitions, SSH setup, downloaded Code builds, selected display preferences and pins for ordinary local Code sessions. Changes made only in that profile are retained for the settings that use three-way merging. Remote Control registrations, tool grants, unknown preferences, cloud project pins, account-specific interface state and scheduler switches stay with each profile. The main window handles waking the Mac for scheduled work. Right after its first sign-in, a profile's window restarts once so Claude can load its account's sessions and settings.

Google sign-in finishes in your browser and comes back to Claude through a `claude://` link, which macOS normally hands to the main Claude app. While a profile window is signing in, Claude Profiles leaves only that window’s app copy registered for those links, and gives them back to the main app as soon as the profile is signed in (or after 15 minutes). The link goes from macOS straight to Claude; Claude Profiles never reads it.

More detail: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

### Privacy

Claude Profiles has no network code and no telemetry. To show the account and usage, it reads the account ID from `config.json`, the matching email from Claude's local IndexedDB cache, and local usage history. It writes eligible local Code session cards, their deletion/archive state, scratch-folder links, and the supported profile settings described above. Explicit captures save a separate context workspace without changing source messages or settings. The bounded sweep navigates supported read-only views and disclosure controls in the selected window. Accessibility capture requires an existing macOS grant; the app does not enable it itself. Interface synchronization writes only selected records in a closed profile's local stores; it does not copy the database.

In a profile's `config.json`, it changes only theme, zoom and language while preserving sign-in fields and file permissions. Claude sign-in stores are never copied between windows. Setup merge baselines contain hashes, not copies of settings values. Manual handoffs contain only the context you enter. Captured workspaces contain the selected available history and files, with owner-only access, hashes and provenance. Exact conversation and tool output may include secrets or private information that were present in that conversation; capture does not silently redact it. Review it before giving a destination account access. Backups of local configuration can contain MCP definitions and other private setup; keep the application data directory private.

## FAQ

**Does this combine the limits of my subscriptions?**
No. Each subscription is metered on its own by Anthropic. Claude Profiles only makes it quick to move to another window you are already signed in to.

**Why not switch accounts automatically when a limit is hit?**
That would amount to automated limit evasion. You decide where to work; the app only shows where there is headroom.

**What about scheduled tasks?**
Schedules stay with their Claude account and are not copied between profiles. Local scheduled tasks need their owning Claude window; cloud schedules run through Claude without that window, unless the work needs access to your Mac. Waking the Mac for local scheduled work is left to the main app.

**Does it work with Team or Enterprise seats?**
Technically yes, a profile can sign in to any account. Whether you may use a work seat this way is up to your organization.

**What happens when Claude Desktop updates?**
Profile copies are rebuilt from the new version the next time you open them (or right away with `claude-profiles refresh`). Your sign-ins stay.

## Known limitations

- For shared ordinary local Code sessions, archive lists are merged: a session archived in any window is archived in all of them, and un-archiving it in one window doesn’t stick. Undoing the merge safely would need Claude Desktop to tell stale writes from real changes.
- Claude Desktop doesn’t lock sessions across windows. Work in a session from one window at a time.
- Claude reads sessions and interface settings when a window starts, the main window included. New, renamed or archived sessions and changed settings from another window show up after this window restarts.
- What is live stays in the window doing it: which session is running or waiting for you, the Sessions list on the home screen, open side panes, terminal tabs and drafts.
- Cloud Projects, cloud Cowork, Remote Control session ownership, cloud connectors and feature rollout are account-specific. Local synchronization does not transfer them. A context-based continuation uses a separate conversation or Project with its own native history and permissions.
- The Routines list shows the tasks of that window’s account. Only eligible ordinary local Code result sessions are shared; cloud tasks and Project workers remain with their owner. Local task prompts use `~/.claude/scheduled-tasks`, which all windows share, so give local tasks in different windows different names.
- Legacy local Cowork requires its original profile, account and organization data to resume the original session. Its cards are not shared or removed from other profiles; existing copies may open without history. Removing the original profile moves its files to the Trash. A saved capture preserves only the content listed in its manifest, not the runtime or every referenced external file.
- A captured file being present does not prove that Claude read it or that it fits the destination's context window. Verify early and recent facts, required artifacts and the next action before continuing. Visible-view capture remains partial even when its text looks complete.
- A Project Library link does not supply the artifact's original bytes. The checked native artifact menu had no Download action. Add originals only when available through a supported path; unavailable artifacts remain explicit context gaps.
- Claude Desktop’s local storage formats are not a public compatibility API. Account-owned workers are handled separately from ordinary local cards; run **Check sessions** after updating Claude.
- There is no Developer ID signature yet, so prebuilt downloads need a one-time “Open Anyway”.

## Uninstall

Remove your profiles in the app first (this quits them and moves their data to the Trash), then:

```sh
make uninstall
rm -rf ~/Library/Application\ Support/Claude\ Profiles ~/Applications/Claude\ Profiles
```

## Contributing

Issues and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Run `make test` before sending a change.

## License

[MIT](LICENSE) © Yuri Trukhin

Claude Profiles is an independent project and is not affiliated with, endorsed by or sponsored by Anthropic. Claude is a trademark of Anthropic, PBC.
