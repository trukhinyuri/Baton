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

Claude Profiles gives every subscription its own Claude window with its own Dock icon, all open at once. Ordinary local Claude Code conversations, local skills and memory follow you between windows. When one subscription reaches its limit, **Continue work…** opens the same Code session in another window, or starts a Cowork task there with the full history and files attached. Cloud Projects, cloud Cowork and their settings stay with their Claude account.

## Features

- **One window per subscription.** Each profile is the official Claude Desktop app running with its own sign-in. No code is patched or injected.
- **Labeled Dock icons.** `WORK`, `LAB` or `TEAM` on a color of your choice tells you which account a window belongs to. The launchers work from Spotlight too.
- **Local Code continuity.** Ordinary local Claude Code sessions appear across windows. Project workers and cloud Cowork stay with their owning account; legacy local Cowork requires its original profile.
- **Shared local setup.** Before a profile window starts, it gets supported local tools and display preferences from the main app. Account settings, Remote Control access and cloud project state remain separate. Sign-ins are never copied.
- **Usage at a glance.** Five-hour and weekly usage for every subscription, from what Claude Desktop itself records. The one with the most headroom is highlighted.
- **Knows who is signed in.** Every row shows the email of the account in that window and warns if it is not the one you intended.
- **Easy to add and remove.** Enter an email, sign in inside the new window, done. Removing moves the profile to the Trash, so nothing is lost by accident.
- **Continue where a limit stopped you.** **Continue work…** lists the local Code sessions, Project branches and Cowork tasks of every window. Pick one and a subscription with headroom: a Code session or Project branch opens as the same session there, and a Cowork task becomes a new task with its history and files attached, waiting for you to send it. When an open subscription reaches its limit, a banner offers this in one click. No macOS permissions are needed.
- **Session checks.** Use **Check sessions** or `claude-profiles doctor` to inspect local session inventory, account-owned workers, missing working folders or local Cowork history, and each profile's Remote Control configuration without changing anything.
- **Menu bar and CLI.** Open any subscription from the menu bar, or script it with `claude-profiles`.
- **Survives Claude updates.** App copies are APFS clones (almost no disk space) and are rebuilt automatically after Claude Desktop updates.

<p align="center">
  <img src="docs/images/add-subscription.png" width="620" alt="Add a Subscription sheet with a live Dock icon preview">
</p>

## What follows you between profiles

| Work or setting | Behavior |
|---|---|
| Ordinary local Claude Code sessions | Local transcripts stay in `~/.claude`; Claude Profiles shares the sidebar cards. Continue a session in one window at a time. |
| Local Code settings, skills, hooks and memory | Claude reads the same local configuration. Supported Desktop setup and display preferences are also synchronized before a profile opens. |
| Local Cowork tasks | Not shared: their history and runtime belong to the original profile, account and organization. **Continue work…** starts a new task in another profile with the history and the task's files attached. |
| New Claude Code Projects, coordinator, memory, Library and threads | Belong to their Claude account. Open the owning profile and use its native Projects view. Local Project workers also retain their owner; **Continue work…** can open a local branch's conversation in another profile as a regular Code session. |
| Cloud Cowork tasks and projects | Saved to the Claude account; local card synchronization does not transfer them to a different account. |
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

Quit **Claude Profiles** before updating; the Claude windows themselves can stay open. The installer stages and verifies the new app before replacing it, and saves the old app as a ZIP in `~/Library/Application Support/Claude Profiles/AppBackups` (the three latest are kept). Runnable `.previous-*.app` copies left beside the app by 0.2.0 move to the Trash where macOS has the `trash` command. Profile data is not replaced. If you moved the source checkout and Swift reports stale build paths, choose a fresh build directory with `CLAUDE_PROFILES_BUILD_DIR=/tmp/claudeprofiles-build make install`.

Builds are signed ad hoc on your Mac, so Gatekeeper doesn’t get involved. If you download a prebuilt `.zip` from [Releases](https://github.com/trukhinyuri/ClaudeProfiles/releases) instead, macOS will ask you to confirm the first launch in **System Settings → Privacy & Security → Open Anyway**.

## Use it

1. Open **Claude Profiles** and click **Add Subscription**.
2. Enter the account’s email and, if you like, change the Dock label and color.
3. A new Claude window opens. Sign in there with that account, with Google or with email.
4. To keep a profile in the Dock, drag its launcher from `~/Applications/Claude Profiles` (**⋯ → Show Launcher in Finder**) to the Dock. Spotlight finds launchers too (“Claude WORK”). **Keep in Dock** on a running profile window pins the app copy itself, which opens without the profile’s sign-in. While Claude Profiles is running (it stays in the menu bar), it notices that and reopens the window with its profile; the launcher works even when it isn’t.
5. To move work to another subscription, for example when one reaches its limit, click **Continue work…** as described below.

> [!IMPORTANT]
> Don’t work in the same session from two windows at the same time. Close it in one before continuing in another.

To remove a subscription, choose **⋯ → Remove Subscription…**. Its window closes and its app copy and sign-in move to the Trash. Ordinary local Code transcripts remain in `~/.claude`. Legacy Cowork sessions whose files live in that profile move to the Trash with it; old card copies in other profiles are left untouched and do not preserve that history. Cloud projects remain with their Claude account, but this profile can no longer serve their local work.

### Continue work in another profile

<p align="center">
  <img src="docs/images/continue-work.png" width="620" alt="Continue work sheet listing Code sessions, a Project branch and Cowork tasks, with the destination subscription">
</p>

Click **Continue work…**. It lists the local conversations of every window, most recent first: Code sessions, local Project branches and Cowork tasks. Choose one, choose where to continue, and click **Continue in …**. When an open subscription reaches its limit, a banner under the header opens the same sheet.

The signed-in subscription with the most weekly headroom is preselected, and those at their limit are marked. A window's usage is only updated while it is open, so each figure shows its age; a figure older than 3 hours is marked *may be higher now*, and **Most headroom** is only given to a subscription measured in the last 3 hours.

| Conversation | What happens in the other profile |
|---|---|
| Code session | The same session opens there with its whole history, or a copy of it (see below). A closed window opens first. |
| Project branch | A copy of the branch's history opens as a regular Code session. The Project, its coordinator, memory and other branches stay with their account. |
| Cowork task | A new Cowork task opens with a prompt to continue, the full history attached as `history.md`, and copies of the files the task was given and made (up to 10 files, 25 MB each, 50 MB in total). Nothing is sent: review it and send it yourself. Claude shows a caution banner above any prompt that arrives through a link; this one is the prompt Claude Profiles prepared. The prompt names the folders the task worked in; connect them when Claude asks. Connectors, scheduled tasks and Project settings of the original account are not carried over, and the original task stays in its profile. |
| claude.ai chat or cloud Project | Not on this Mac. **Copy handoff request** copies a request to paste into that chat; paste its answer into a new chat in the other subscription. |

Two windows must not write to one session at the same time. **Automatic** therefore continues a Project branch, whose coordinator may write to it again, and a session with a message in the last 10 minutes as a copy: a new session with the same history and files. Other sessions continue as themselves. **Same session** and **As a copy** override this; for a session that may still be running, **Same session** needs **I stopped it** and then reads **Continue Anyway**. A Cowork task written to less than a minute ago may miss its last steps; stop it first.

**Continue All in …** continues every Code session and Project branch of the selected conversation's folder with a message in the last day, in one step, and can also start a new session in that folder. Branches that already belong to the destination are left out.

The session keeps its model if the destination has used that model before. When the destination is closed, Claude Profiles prepares the session there with the source's model and permission mode; bypass and auto permission modes become Accept edits. Otherwise the sheet says which model the session will use, or asks you to choose it in the destination before your first message.

Continuing needs no macOS permissions: the destination window receives a `claude://` link that only that window handles. Nothing is sent on your behalf. Prepared Cowork handoffs are kept in `~/Library/Application Support/Claude Profiles/Handoffs`, readable only by you, and move to the Trash after 30 days.

### Command line

```text
claude-profiles list                          Show every profile, its account and plan usage
claude-profiles add <email> [--label TEXT] [--color #RRGGBB]
                                               Create a profile and open it to sign in
claude-profiles open <profile>                Open a profile's window (id or label)
claude-profiles remove <profile>              Quit it and move its copy and sign-in to the Trash
claude-profiles sync                          Share ordinary local Code session cards across profiles now
claude-profiles doctor [--json]               Inspect sessions and per-profile setup without changing it
claude-profiles conversations [--all]         List local conversations that can continue in another profile
claude-profiles continue <id|last> --to <profile> [--same|--fork] [--anyway] [--dry-run]
                                               Continue one in another profile, as Continue work… does
claude-profiles continue --folder <path> --to <profile> [--since 24h] [--same|--fork] [--new] [--dry-run]
                                               Continue every session of a folder, as Continue All does
claude-profiles handoff --from <profile> --to <profile> --title <text> --context <file>
                       [--folder <absolute-path>] [--source-url <claude.ai-url>] [--open]
claude-profiles refresh                       Rebuild app copies after a Claude Desktop update
```

`continue` takes the start of an id from `conversations`, or `last` for the most recent one. It copies as **Automatic** does; `--fork` always copies, and `--same` keeps the same session but refuses one with a message in the last 10 minutes unless you add `--anyway`. `--folder` continues every session of that folder with a message within `--since` (default `24h`), and `--new` also starts a new session there. `--dry-run` prints what would continue, how, and with which model, without changing anything:

```sh
claude-profiles conversations
claude-profiles continue last --to LAB
claude-profiles continue --folder ~/Projects/api --to LAB --new --dry-run
```

For a claude.ai chat, the `handoff` command saves a Markdown file from context you have reviewed and prints its path. Add `--open` to open the destination profile. It does not change the clipboard or fetch a cloud transcript; copy the saved context into a new conversation yourself. For example:

```sh
claude-profiles handoff --from WORK --to LAB --title "Continue API migration" --context ./handoff.md --open
```

The binary ships inside the app: `ln -s ~/Applications/Claude\ Profiles/Claude\ Profiles.app/Contents/Helpers/claude-profiles /usr/local/bin/`.

## How it works

| What | Where |
|---|---|
| Main Claude app (untouched) | `/Applications/Claude.app`, data in `~/Library/Application Support/Claude` |
| Profile app copies (APFS clones with a Finder icon) | `~/Applications/Claude Profiles/.engines` |
| Launchers you can keep in the Dock | `~/Applications/Claude Profiles/Claude <LABEL>.app` |
| Each profile’s sign-in and window state | `~/Library/Application Support/Claude Profiles/Profiles/<id>` |
| Profile list and backups | `~/Library/Application Support/Claude Profiles` |
| Local Claude Code transcripts, settings, skills, memory | `~/.claude` (already shared by every window) |
| Cloud Projects, cloud Cowork and account settings | Anthropic services, under their owning Claude account |

A profile is Claude Desktop started with its own `--user-data-dir`, which is standard Electron behavior. For ordinary local Code sessions, sharing copies the small sidebar cards between account folders; the conversations themselves already live in `~/.claude`. While any Claude window is open, Code sharing only adds and updates; deletions propagate only when all windows are closed. Replaced and removed Code cards are backed up first.

Legacy local Cowork is inspected only. Claude Profiles does not copy, update or delete its cards, files or old synchronization state. Claude loads its history from the current profile's account and organization directory, so copying a sidebar card can open a blank conversation instead of the original history. Existing copies from earlier versions are preserved. Open the task in its original profile, or use **Continue work…** to start a new task elsewhere with its history and files.

A Code card marked as a native Project or Remote Control worker stays within its account and organization. If an older Claude Profiles version already copied one across account boundaries, the owner is ambiguous: those copies stay untouched and are excluded from synchronization, and **Check sessions** reports them for review. This does not delete the worker, move its files or make its cloud Project available in another account.

Before a profile window starts, Claude Profiles synchronizes local extensions and MCP definitions, SSH setup, downloaded Code builds, selected display preferences and pins for ordinary local Code sessions. Changes made only in that profile are retained for the settings that use three-way merging. Remote Control registrations, tool grants, unknown preferences, cloud project pins, account-specific interface state and scheduler switches stay with each profile. The main window handles waking the Mac for scheduled work. Right after its first sign-in, a profile's window restarts once so Claude can load its account's sessions and settings.

Google sign-in finishes in your browser and comes back to Claude through a `claude://` link, which macOS normally hands to the main Claude app. While a profile window is signing in, Claude Profiles leaves only that window’s app copy registered for those links, and gives them back to the main app as soon as the profile is signed in (or after 15 minutes). The link goes from macOS straight to Claude; Claude Profiles never reads it.

More detail: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

### Privacy

Claude Profiles has no network code and no telemetry. To show the account and usage, it reads the account ID from `config.json`, the matching email from Claude's local IndexedDB cache, and local usage history. It writes eligible local Code session cards, their deletion/archive state, scratch-folder links, and the supported profile settings described above. Cowork session inspection is read-only. Interface synchronization writes only selected records in a closed profile's local stores; it does not copy the database.

In a profile's `config.json`, it changes only theme, zoom and language while preserving sign-in fields and file permissions. Claude sign-in tokens, cookies and passwords are never copied between windows. Setup merge baselines contain hashes, not copies of settings values. Continuing a Cowork task reads its local transcript and files to prepare the handoff, which is created with owner-only access and stays on your Mac until you send it. Backups of local configuration can contain MCP definitions and other private setup; keep the application data directory private.

## FAQ

**Does this combine the limits of my subscriptions?**
No. Each subscription is metered on its own by Anthropic. Claude Profiles only makes it quick to move to another window you are already signed in to.

**Why not switch accounts automatically when a limit is hit?**
That would amount to automated limit evasion. You decide where to work. The app shows where there is headroom and, when a subscription reaches its limit, offers to continue elsewhere; nothing moves until you click.

**What about scheduled tasks?**
Schedules stay with their Claude account and are not copied between profiles. Local scheduled tasks need their owning Claude window; cloud schedules run through Claude without that window, unless the work needs access to your Mac. Waking the Mac for local scheduled work is left to the main app.

**Does it work with Team or Enterprise seats?**
Technically yes, a profile can sign in to any account. Whether you may use a work seat this way is up to your organization.

**What happens when Claude Desktop updates?**
Profile copies are rebuilt from the new version the next time you open them (or right away with `claude-profiles refresh`). Your sign-ins stay.

## Known limitations

- For shared ordinary local Code sessions, archive lists are merged: a session archived in any window is archived in all of them, and un-archiving it in one window doesn’t stick. Undoing the merge safely would need Claude Desktop to tell stale writes from real changes.
- Claude Desktop doesn’t lock sessions across windows. Work in a session from one window at a time.
- Claude reads sessions and interface settings when a window starts, the main window included. New, renamed or archived sessions and changed settings from another window show up after this window restarts. **Continue work…** opens a session in a running window right away.
- What is live stays in the window doing it: which session is running or waiting for you, the Sessions list on the home screen, open side panes, terminal tabs and drafts.
- Cloud Projects, cloud Cowork, Remote Control session ownership, cloud connectors and feature rollout are account-specific. They cannot be transferred by local settings or sidebar synchronization. Projects and their local workers must be continued through the owning account.
- The Routines list shows the tasks of that window’s account. Only eligible ordinary local Code result sessions are shared; cloud tasks and Project workers remain with their owner. Local task prompts use `~/.claude/scheduled-tasks`, which all windows share, so give local tasks in different windows different names.
- Local Cowork tasks require their original profile, account and organization data. Their cards are not shared or removed from other profiles; copies made by old versions may open without history. Continuing one elsewhere starts a new task from its history and files. Removing the original profile moves its files to the Trash.
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
