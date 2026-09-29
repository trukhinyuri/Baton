#!/bin/sh
# Checks that the files a contributor or reporter looks for are in place. Usage: scripts/check-repo.sh
set -eu

cd "$(dirname "$0")/.."
failed=0
need() { if [ -s "$1" ]; then echo "ok    $1"; else echo "FAIL  $1 is missing or empty" >&2; failed=1; fi; }
has() { # has <file> <fixed text> <why>
    if grep -qF -- "$2" "$1" 2>/dev/null; then echo "ok    $1: $3"; else echo "FAIL  $1: $3" >&2; failed=1; fi
}

for file in LICENSE README.md CHANGELOG.md CONTRIBUTING.md CODE_OF_CONDUCT.md SECURITY.md \
    .github/ISSUE_TEMPLATE/bug_report.yml .github/ISSUE_TEMPLATE/feature_request.yml .github/ISSUE_TEMPLATE/config.yml \
    .github/PULL_REQUEST_TEMPLATE.md .github/CODEOWNERS; do
    need "$file"
done
has .github/ISSUE_TEMPLATE/config.yml 'blank_issues_enabled: false' "blank issues are off"
has .github/ISSUE_TEMPLATE/config.yml '/security/advisories/new' "security reports go to a private advisory"
has .github/ISSUE_TEMPLATE/bug_report.yml 'id: diagnostics' "the report fills the Diagnostics field"
has .github/ISSUE_TEMPLATE/bug_report.yml 'I reviewed the text above' "the reporter confirms they reviewed the text"
has CODE_OF_CONDUCT.md 'Contributor Covenant' "Contributor Covenant"
has CODE_OF_CONDUCT.md 'version 2.1' "version 2.1"
if [ -e .github/FUNDING.yml ]; then echo "FAIL  .github/FUNDING.yml exists; funding is the owner's decision" >&2; failed=1; fi
# Real people's addresses and account labels never go into a public repo: examples use reserved domains
# (example.org, *.example). The maintainer's own mail domains and window labels are listed here, base64-encoded so this file doesn't spell them out.
personal=$(printf "%s" "dHJ1a2hpblwuY29tfGNsb3VkbGludXhcLmNvbXx0dXhjYXJlXC5jb218WVRSVUtISU58RUxFTkF8Q2xvdWRMaW51eEFzc2lzdGFudA==" | base64 -d)
if [ -d .git ] || [ -f .git ]; then
    found=$(git grep --untracked -n -I -i -E "$personal" -- . ':!scripts/check-repo.sh' 2>/dev/null || true)
else
    found=$(grep -rn -I -i -E "$personal" --exclude-dir=.build --exclude-dir=build --exclude=check-repo.sh . 2>/dev/null || true)
fi
if [ -n "$found" ]; then
    echo "FAIL  personal data (use a reserved example domain or a made-up label):" >&2
    echo "$found" >&2
    failed=1
else
    echo "ok    no personal addresses or account labels"
fi
[ "$failed" = 0 ] && echo "Repository files in place."
exit "$failed"
