#!/usr/bin/env python3
"""Reads what `baton handover` did to the sandbox of scripts/e2e-handover.sh and checks it against the incident fixture.

Usage:
  check-handover.py windows <log> <window>...        write the stand-in windows' state: these windows run
  check-handover.py dry-run <home> <dry-run.json>    the plan, and that nothing changed
  check-handover.py result <home> <log> <result.json> what the handover did

Reads only plain files (cards, settings, Baton's state, the stand-ins' log); Local Storage and IndexedDB are checked by
HandoverScenarioTests. Prints one line per check and exits 1 if any failed.
"""
import datetime, json, os, sys

FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Tests", "BatonKitTests", "Fixtures", "handover-incident")
X = json.load(open(os.path.join(FIXTURE, "expected.json")))
RC_KEYS = ["remoteControlSpawn", "projectThreadChild", "rcChild", "bridgeSessionIds"]
failed = False


def check(ok, what):
    global failed
    print(("ok    " if ok else "FAIL  ") + what)
    failed |= not ok


def data_dir(home, window):
    support = os.path.join(home, "Library", "Application Support")
    return os.path.join(support, "Claude") if window == "main" else os.path.join(support, "Baton", "Profiles", window)


def cards(home, window):
    folder = os.path.join(data_dir(home, window), "claude-code-sessions", X["scopes"][window])
    found = {}
    for name in os.listdir(folder) if os.path.isdir(folder) else []:
        if name.startswith("local_") and name.endswith(".json"):
            found[name[:-5]] = json.load(open(os.path.join(folder, name)))
    return found


def entries(home, window):
    config = json.load(open(os.path.join(data_dir(home, window), "claude_desktop_config.json")))
    return config.get("preferences", {}).get("epitaxyPrefs", {}).get("autoResumeRateLimit." + X["accounts"][window], {})


def windows(log, running):
    """The windows run; ATLAS keeps an idle Claude Code process for each of its 8 cut sessions, as Claude Desktop keeps
    one for every session it opened, for hours."""
    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    live = [{"session": s, "window": "atlas", "since": now, "idle": True} for s in X["cut"]] if "atlas" in running else []
    with open(log + ".state.json", "w") as f:
        json.dump({"running": {w: now for w in running}, "live": live}, f)


def dry_run(home, path):
    plan = json.load(open(path))
    check(plan["source"] == "ATLAS" and plan["destination"] == "BRAVO", f"plan: ATLAS to BRAVO ({plan['source']} to {plan['destination']})")
    check(sorted(s["card"] for s in plan["sessions"]) == X["moved"], f"plan: {len(X['moved'])} sessions move ({len(plan['sessions'])})")
    resumes = sorted(s["session"] for s in plan["sessions"] if s["resumes"])
    check(resumes == sorted(X["cut"]), f"plan: {len(X['cut'])} resume ({len(resumes)})")
    check(not any(s["asCopy"] for s in plan["sessions"]), "plan: 8 idle processes in ATLAS, nothing works there, so no copies")
    check(plan["seeding"] == "seed", f"plan: seeds auto-continue ({plan['seeding']})")
    check(any(l.startswith("19 stay in ATLAS: a folder rule") for l in plan["leftovers"]), "plan: 19 kept by the folder rule")
    check("8 stay in ATLAS: Remote Control reaches them there" in plan["leftovers"], "plan: 8 kept by Remote Control")
    check(not os.path.exists(os.path.join(home, "Library", "Application Support", "Baton", "handovers.json")), "dry run: no handover logged")
    check(not set(cards(home, "bravo")) & set(X["moved"]), "dry run: no card shared into BRAVO")


def result(home, log, path):
    out = json.load(open(path))
    print("line: " + out.get("line", ""))
    check(out.get("state") == "done" and out.get("sourceClosed") is True,
          f"done, ATLAS closed though 8 idle processes were open there ({out.get('state')}, {out.get('sourceClosed')})")
    check(sorted(out.get("resumed", [])) == sorted(X["cut"]), f"{len(X['cut'])} sessions resumed ({len(out.get('resumed', []))})")
    check(out.get("line", "").startswith("ATLAS is at its limit until ") and "and was closed. Your work continues in BRAVO — 8 sessions resumed; "
          "19 stay in ATLAS: a folder rule keeps client for atlas@, cedar@; 8 stay in ATLAS: Remote Control reaches them there." in out.get("line", ""),
          "the one line")
    bravo = cards(home, "bravo")
    check(set(X["moved"]) <= set(bravo), f"every moved card is in BRAVO as itself ({len(set(X['moved']) & set(bravo))} of {len(X['moved'])})")
    kept = X["kept"]["folderRule"] + X["kept"]["remoteControl"]
    check(not set(kept) & set(bravo), "no withheld card is in BRAVO")
    carriers = [f"{w}/{n}" for w in ["main", "bravo", "cedar"] for n, c in cards(home, w).items()
                if any(k in c for k in RC_KEYS) and not (w == "cedar" and n in X["kept"]["ambiguous"])]
    check(not carriers, f"no copy carries Remote Control's keys {carriers[:3]}")
    check(all("remoteControlSpawn" in cards(home, "cedar")[n] for n in X["kept"]["ambiguous"]), "CEDAR's own marked copies are untouched")
    now = datetime.datetime.now().timestamp()
    seeded = entries(home, "bravo")
    cut_cards = [n for n, c in bravo.items() if c.get("cliSessionId") in X["cut"]]
    check(len(cut_cards) == 8 and all(seeded.get(n, {}).get("optedIn") is True and seeded[n]["resetsAt"] < now for n in cut_cards),
          f"auto-continue seeded in BRAVO for the 8, reset passed ({len(seeded)} entries)")
    atlas = entries(home, "atlas")
    check(all(atlas.get(n, {}).get("optedIn") is False for n in X["armed"]), "auto-continue off in ATLAS for its 3 entries")
    prefs = json.load(open(os.path.join(data_dir(home, "bravo"), "claude_desktop_config.json")))["preferences"]["epitaxyPrefs"]
    starred = set(prefs.get("starred-local-code-sessions", []))
    check(set(X["pinnedMoved"]) <= starred, f"the 12 moved pins are in BRAVO's settings ({len(set(X['pinnedMoved']) & starred)})")
    assignments = prefs.get("dframe-group-scopes", {}).get(X["scopes"]["bravo"], {}).get("assignments", {})
    check(all(assignments.get(i) == X["groups"]["id"] for i in X["groups"]["mainMoved"]), f"the group's {len(X['groups']['mainMoved'])} moved sessions keep it")
    check(all(assignments.get(i) == X["groups"]["new"] for i in X["groups"]["newMoved"]), "the group new to BRAVO came along")
    events = open(log).read().split("\n")
    links = [e for e in events if e.startswith("link ")]
    order_ok = "quit atlas" in events and "start bravo" in events and links and \
        events.index("quit atlas") < events.index("start bravo") < events.index(links[0])
    check(order_ok, "ATLAS quit before BRAVO started, BRAVO started before any link")
    check(len(links) == 8 and all(l.startswith("link bravo ") for l in links) and links[-1] == "link bravo " + X["topPin"],
          f"8 links, one at a time, the top pin last ({len(links)})")
    log_entries = json.load(open(os.path.join(home, "Library", "Application Support", "Baton", "handovers.json")))["entries"]
    last = log_entries[-1] if log_entries else {}
    check(last.get("state") == "done" and last.get("destination") == "bravo" and last.get("sourceClosed") is True,
          "handovers.json: done, to BRAVO, ATLAS closed")


if __name__ == "__main__":
    command, rest = sys.argv[1], sys.argv[2:]
    if command == "windows":
        windows(rest[0], rest[1:])
    elif command == "dry-run":
        dry_run(*rest)
    elif command == "result":
        result(*rest)
    else:
        sys.exit(f"unknown command {command}")
    sys.exit(1 if failed else 0)
