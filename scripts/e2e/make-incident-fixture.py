#!/usr/bin/env python3
"""Writes Tests/BatonKitTests/Fixtures/handover-incident: the limit handover of 29 September 2026, sanitized.

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
"""
import gzip, json, os, shutil, struct

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Tests", "BatonKitTests", "Fixtures", "handover-incident")
HOME = os.path.join(ROOT, "home")
SUPPORT = os.path.join(HOME, "Library", "Application Support")
STATE = os.path.join(SUPPORT, "Baton")
VERSION = "2.1.284"

WINDOWS = {
    # id: (label, account, org, email, five-hour %, weekly %)
    "main": ("(main)", "11111111-0000-4000-8000-000000000001", "0a000000-0000-4000-8000-000000000001", "main@example.org", 50, 70),
    "atlas": ("ATLAS", "22222222-0000-4000-8000-000000000002", "0a000000-0000-4000-8000-000000000002", "atlas@example.org", 100, 40),
    "bravo": ("BRAVO", "33333333-0000-4000-8000-000000000003", "0a000000-0000-4000-8000-000000000003", "bravo@example.org", 5, 10),
    "cedar": ("CEDAR", "44444444-0000-4000-8000-000000000004", "0a000000-0000-4000-8000-000000000004", "cedar@example.org", 10, 30),
}
GROUP_MAIN = "cg-00000000-0000-4000-8000-00000000a001"
GROUP_NEW = "cg-00000000-0000-4000-8000-00000000a002"


def scope(window):
    return f"{WINDOWS[window][1]}/{WINDOWS[window][2]}"


def data_dir(window):
    return os.path.join(SUPPORT, "Claude") if window == "main" else os.path.join(STATE, "Profiles", window)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def write_json(path, value):
    write(path, json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n")


def write_card(path, card):
    """Claude writes its cards as compact JSON, and Baton finds a card's session id by its exact bytes."""
    write(path, json.dumps(card, separators=(",", ":"), ensure_ascii=False))


def token(kind, offset):
    return f"@{kind}{offset:+d}@"


class Session:
    def __init__(self, name, index, folder, title, marker=False):
        self.name, self.folder, self.title, self.marker = name, folder, title, marker
        self.session = f"5e55e000-0000-4000-8000-{index:012d}"
        self.card = f"local_ca4d0000-0000-4000-8000-{index:012d}"
        self.cut = False
        self.armed = False
        self.age = 7200 + index * 60

    def card_json(self, extra=None):
        card = {"sessionId": self.card, "cliSessionId": self.session, "cwd": self.folder, "originCwd": self.folder,
                "title": self.title, "createdAt": token("MS", -self.age - 600), "lastActivityAt": token("MS", -self.age)}
        if self.marker:
            card["remoteControlSpawn"] = {"ccrSessionId": f"cse_{self.name}", "folder": self.folder, "projectThreadChild": True, "rcChild": True}
            card["bridgeSessionIds"] = [f"bridge_{self.name}"]
        card.update(extra or {})
        return card


def main():
    shutil.rmtree(ROOT, ignore_errors=True)

    # The sessions of ATLAS.
    sessions, index = [], 1
    for i in range(1, 43):
        folder = "/work/bots" if i <= 6 else "/work/bots/shared" if i <= 8 else "/work/assistant"
        sessions.append(Session(f"r{i:02d}", index, folder, f"Worker {i:02d}", marker=True)); index += 1
    for i in range(1, 29):
        folder = "/work/client" if i <= 19 else "/work/app"
        sessions.append(Session(f"o{i:02d}", index, folder, f"Task {i:02d}")); index += 1
    by = {s.name: s for s in sessions}
    for name in ["r09", "r10", "r11", "o20", "o21", "o22", "o23", "o24"]:
        by[name].cut = True
    for name in ["r09", "o20", "o21"]:
        by[name].armed = True

    group_main = [by[f"r{i:02d}"] for i in range(1, 43)] + [by[f"o{i:02d}"] for i in range(1, 23)]
    group_new = [by["o23"], by["o24"], by["o25"]]
    assert len(group_main) == 64
    # The top pin first; the cut ones and some others, 15 in all.
    pinned = [by[n] for n in ["o22", "r01", "o01", "r09", "r10", "r11", "r12", "r13", "r14", "o20", "o21", "o23", "o24", "o25", "r02"]]
    assert len(pinned) == 15

    # Baton's state.
    write_json(os.path.join(STATE, "profiles.json"), [
        {"id": w, "label": WINDOWS[w][0], "email": WINDOWS[w][3], "color": "#1971C2", "createdAt": "2026-09-01T09:00:00Z"}
        for w in ["atlas", "bravo", "cedar"]])
    write_json(os.path.join(STATE, "folder-rules.json"),
               {"version": 1, "rules": [{"folder": "/work/client", "accounts": ["atlas@example.org", "cedar@example.org"]}]})
    write_json(os.path.join(STATE, "local-only.json"), {"version": 1, "enabled": True, "windows": {}})
    write_json(os.path.join(STATE, "limit-sightings.json"), {"version": 1, "sightings": [
        {"session": s.session, "window": "atlas", "pid": 7000 + n, "from": token("ISO", -10800), "lastSeen": token("ISO", -120),
         "version": VERSION, "cwd": s.folder, "account": WINDOWS["atlas"][1]} for n, s in enumerate(sessions)]})

    # Each window.
    for window, (label, account, org, email, five, week) in WINDOWS.items():
        d = data_dir(window)
        write_json(os.path.join(d, "config.json"), {"lastKnownAccountUuid": account})
        write_json(os.path.join(d, "plan-usage-history.json"), {"samples": [{"t": token("MS", -600), "fh": five, "sd": week}]})
        prefs = {}
        if window == "atlas":
            prefs[f"autoResumeRateLimit.{account}"] = {
                s.card: {"resetsAt": token("S", 7200), "attempt": 0, "optedIn": True} for s in sessions if s.armed}
            prefs["dframe-group-scopes"] = {scope("atlas"): groups_value(group_main, group_new)}
            prefs["dframe-local-slice"] = {"pinnedOrder": ["code:" + s.card for s in pinned]}
            prefs["starred-local-code-sessions"] = [s.card for s in pinned]
            prefs["remoteControlPinnedFolders"] = []
        write_json(os.path.join(d, "claude_desktop_config.json"), {"preferences": {"epitaxyPrefs": prefs}})
    cards = lambda w: os.path.join(data_dir(w), "claude-code-sessions", WINDOWS[w][1], WINDOWS[w][2])
    for s in sessions:
        write_card(os.path.join(cards("atlas"), s.card + ".json"), s.card_json())
    for s in [by["r07"], by["r08"]]:
        write_card(os.path.join(cards("cedar"), s.card + ".json"), s.card_json())
    own = {"main": ["m01"], "bravo": ["b01", "b02"], "cedar": ["c01"]}
    others = {}
    for window, names in own.items():
        for name in names:
            s = Session(name, index, "/work/home", f"Own {name}"); index += 1
            others[name] = s
            write_card(os.path.join(cards(window), s.card + ".json"), s.card_json())
            sessions.append(s)

    # Remote Control: ATLAS serves /work/bots, CEDAR /work/bots/shared, BRAVO has it off, the main window none.
    def rc(window, serve, folders):
        key = f"{WINDOWS[window][1]}:{WINDOWS[window][2]}"
        write_json(os.path.join(data_dir(window), "remote-control-state.json"), {"version": 1, "identities": {key: {
            "serve": serve, "folders": {f: {"environmentId": f"env_{window}", "keys": [f]} for f in folders},
            "pendingDelete": [], "pendingUnarchive": []}}})
    rc("atlas", "on", ["/work/bots"])
    rc("cedar", "on", ["/work/bots/shared"])
    rc("bravo", "off", ["/work/assistant"])

    # Claude's cached flags in BRAVO, with the header Claude writes; its auto-continue key isn't known yet.
    flags = {"timestamp": 1790694000000, "mode": "online", "features": {"1234567890": {"value": True, "on": True, "off": False, "source": "force"}}}
    body = gzip.compress(json.dumps(flags).encode(), mtime=0)
    os.makedirs(data_dir("bravo"), exist_ok=True)
    with open(os.path.join(data_dir("bravo"), "fcache"), "wb") as f:
        f.write(bytes([0x43, 0x4C, 0x46, 0x02, 0x00, 0x9A, 0xB7, 0xE2]) + body)

    # Transcripts; the 8 cut sessions end in a limit message.
    for s in sessions:
        slug = "".join(c if c.isascii() and c.isalnum() else "-" for c in s.folder)
        lines = [{"type": "user", "sessionId": s.session, "cwd": s.folder, "entrypoint": "claude-desktop", "version": VERSION,
                  "timestamp": token("ISOF", -s.age), "message": {"role": "user", "content": f"Work on {s.title}"}}]
        if s.cut:
            lines.append({"type": "assistant", "isApiErrorMessage": True, "error": "rate_limit", "apiErrorStatus": 429,
                          "sessionId": s.session, "entrypoint": "claude-desktop", "version": VERSION, "timestamp": token("ISOF", -300),
                          "quotaLimits": {"status": "rejected", "resetsAt": token("S", 7200), "rateLimitType": "five_hour",
                                          "overageStatus": "rejected", "isUsingOverage": False},
                          "message": {"role": "assistant", "content": []}})
        write(os.path.join(HOME, "dot-claude", "projects", slug, s.session + ".jsonl"), "".join(json.dumps(l) + "\n" for l in lines))

    # Local Storage and IndexedDB, written by the materializer.
    bravo_own = [others["b01"], others["b02"]]
    stores = {
        "atlas": {"localStorage": {**sidebar_items("atlas", groups_value(group_main, group_new), pinned),
                                   f"LSS-persisted.autoResumeRateLimit.{WINDOWS['atlas'][1]}": {"value": {
                                       s.card: {"resetsAt": token("S", 7200), "attempt": 0, "optedIn": True} for s in sessions if s.armed},
                                       "tabId": "", "timestamp": token("MS", -300)}},
                  "pins": {"starredIds": [s.card for s in pinned], "updatedAt": token("MS", -3600)}},
        "bravo": {"localStorage": sidebar_items("bravo", {"groups": [{"id": GROUP_MAIN, "name": "Assistant work"}],
                                                          "assignments": {"code:" + s.card: GROUP_MAIN for s in bravo_own},
                                                          "order": {GROUP_MAIN: ["code:" + s.card for s in bravo_own]}}, [others["b01"]]),
                  "pins": {"starredIds": [others["b01"].card], "updatedAt": token("MS", -86400)}},
    }
    write_json(os.path.join(ROOT, "stores.json"), stores)

    # What a handover of ATLAS is expected to do, for the tests and scripts/e2e/check-handover.py.
    moved = [s for s in sessions[:70] if not (s.marker and s.folder.startswith("/work/bots")) and s.folder != "/work/client"]
    write_json(os.path.join(ROOT, "expected.json"), {
        "source": "atlas", "destination": "bravo", "labels": {w: v[0] for w, v in WINDOWS.items()},
        "accounts": {w: v[1] for w, v in WINDOWS.items()}, "scopes": {w: scope(w) for w in WINDOWS},
        "moved": sorted(s.card for s in moved),
        "kept": {"folderRule": sorted(s.card for s in sessions[:70] if s.folder == "/work/client"),
                 "remoteControl": sorted(s.card for s in sessions[:70] if s.marker and s.folder.startswith("/work/bots")),
                 "ambiguous": sorted([by["r07"].card, by["r08"].card])},
        "cut": [by[n].session for n in ["r09", "r10", "r11", "o20", "o21", "o22", "o23", "o24"]],
        "armed": sorted(by[n].card for n in ["r09", "o20", "o21"]),
        "topPin": by["o22"].session,
        "pinnedMoved": [s.card for s in pinned if s in moved],
        "groups": {"id": GROUP_MAIN, "new": GROUP_NEW, "newName": "Release notes",
                   "mainMoved": ["code:" + s.card for s in group_main if s in moved], "newMoved": ["code:" + s.card for s in group_new]},
        "bravoOwn": {"cards": [s.card for s in bravo_own], "pin": others["b01"].card},
    })
    write(os.path.join(ROOT, "README.md"), __doc__.strip() + "\n")


def groups_value(group_main, group_new):
    return {"groups": [{"id": GROUP_MAIN, "name": "Assistant work"}, {"id": GROUP_NEW, "name": "Release notes"}],
            "assignments": {**{"code:" + s.card: GROUP_MAIN for s in group_main}, **{"code:" + s.card: GROUP_NEW for s in group_new}},
            "order": {GROUP_MAIN: ["code:" + s.card for s in group_main], GROUP_NEW: ["code:" + s.card for s in group_new]}}


def sidebar_items(window, groups, pinned):
    """The Local Storage items of the sidebar, as objects; the materializer writes each as JSON text."""
    order = ["code:" + s.card for s in pinned]
    return {
        "dframe-store": {"state": {"sidebarWidth": 260, "pinnedOrder": order, "lastSidebarScopeKey": scope(window),
                                   "customGroupsByScope": {scope(window): groups}}, "version": 1},
        "LSS-persisted.dframe-group-scopes": {"value": {scope(window): groups}, "tabId": "", "timestamp": token("MS", -3600)},
        "LSS-persisted.dframe-local-slice": {"value": {"pinnedOrder": order, "homeProjectsPinnedOrder": []}, "tabId": "", "timestamp": token("MS", -3600)},
        "LSS-persisted.starred-local-code-sessions": {"value": [s.card for s in pinned], "tabId": "", "timestamp": token("MS", -3600)},
    }


if __name__ == "__main__":
    main()
