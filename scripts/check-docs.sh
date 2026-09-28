#!/bin/sh
# Checks the docs against what 1.0 does. Usage: scripts/check-docs.sh
# - no mention of features 1.0 removed (Project branches, shared sidebar groups, handoff requests);
# - every relative link points at a file that exists, and every #anchor at a heading;
# - the anchors the app and the issue forms link to exist in the README;
# - VERSION matches the newest CHANGELOG entry.
set -eu

cd "$(dirname "$0")/.."
exec python3 - "$@" <<'PY'
import os, re, sys, unicodedata

docs = ["README.md", "CONTRIBUTING.md", "SECURITY.md", "CODE_OF_CONDUCT.md", "packaging/homebrew/README.md"]
for root, _, files in os.walk("docs"):
    docs += [os.path.join(root, f) for f in files if f.endswith(".md")]
failed = False

def fail(message):
    global failed
    failed = True
    print("FAIL  " + message, file=sys.stderr)

def slug(heading):
    # GitHub's anchors: lower case, punctuation dropped, spaces become hyphens.
    text = re.sub(r"<[^>]+>|[`*_]|\[([^\]]*)\]\([^)]*\)", r"\1", heading).strip().lower()
    text = "".join(c for c in text if c in " -" or unicodedata.category(c)[0] in "LN")
    return text.replace(" ", "-")

def anchors(path):
    found, seen, fenced = set(), {}, False
    for line in open(path, encoding="utf-8"):
        if line.startswith("```"):
            fenced = not fenced
        if fenced:
            continue
        match = re.match(r"#{1,6} +(.*?) *#* *$", line)
        if match:
            base = slug(match.group(1))
            count = seen.get(base, 0)
            seen[base] = count + 1
            found.add(base if count == 0 else f"{base}-{count}")
    return found

# "handoff" as a word: the Cowork continuation still keeps its files in Handoffs/ (CoworkHandoff).
removed = re.compile(r"project branch|sidebar group|\bhandoff\b", re.IGNORECASE)
for path in docs:
    text = open(path, encoding="utf-8").read()
    for number, line in enumerate(text.splitlines(), 1):
        if removed.search(line):
            fail(f"{path}:{number}: mentions a feature 1.0 removed: {removed.search(line).group(0)}")
    for target in re.findall(r"\]\(([^)\s]+)\)|href=\"([^\"]+)\"|src=\"([^\"]+)\"", text):
        target = next(t for t in target if t)
        if re.match(r"[a-z]+:", target):
            continue
        file, _, anchor = target.partition("#")
        resolved = os.path.normpath(os.path.join(os.path.dirname(path), file)) if file else path
        if not os.path.exists(resolved):
            fail(f"{path}: link to a missing file: {target}")
        elif anchor and resolved.endswith(".md") and anchor not in anchors(resolved):
            fail(f"{path}: link to a missing heading: {target}")

# Anchors linked from outside the docs: the app's footer and the issue forms.
readme = anchors("README.md")
outside = set()
for root in ["Sources", ".github"]:
    for directory, _, files in os.walk(root):
        for name in files:
            body = open(os.path.join(directory, name), encoding="utf-8", errors="ignore").read()
            outside |= set(re.findall(r"github\.com/[^/\s\"]+/[^/#\s\"]+#([a-z0-9-]+)", body))
for anchor in sorted(outside):
    if anchor not in readme:
        fail(f"README.md has no heading for #{anchor}, which the app or an issue form links to")

version = open("VERSION").read().strip()
newest = re.search(r"^## (\S+)", open("CHANGELOG.md", encoding="utf-8").read(), re.MULTILINE)
if not newest or newest.group(1) != version:
    fail(f"VERSION is {version} but the newest CHANGELOG entry is {newest.group(1) if newest else 'missing'}")

if failed:
    sys.exit(1)
print(f"Docs checked: {len(docs)} files, {len(outside)} outside anchors, version {version}.")
PY
