#!/bin/bash
# Publishes a new version: ./release.sh 1.1
# Bumps VERSION, builds both packages, tags, pushes, and creates the GitHub release.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: ./release.sh <version>   e.g. ./release.sh 1.1" >&2; exit 1; }
NEW="$1"
[[ "$NEW" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "version must look like 1.1 or 1.1.2" >&2; exit 1; }

# A release built from a dirty tree is not reproducible from its own tag.
[[ -z "$(git status --porcelain)" ]] || { echo "working tree is dirty; commit first" >&2; exit 1; }
[[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || { echo "not on main" >&2; exit 1; }
git rev-parse "v$NEW" >/dev/null 2>&1 && { echo "tag v$NEW already exists" >&2; exit 1; }

PREV="$(cat VERSION)"
echo "==> $PREV -> $NEW"
echo "$NEW" > VERSION
git add VERSION
git commit -q -m "Version $NEW"

echo "==> Building packages"
./make-dmg.sh >/dev/null
./make-zip.sh >/dev/null

# Tag after the version commit so the tag builds the thing it claims to be.
git tag -a "v$NEW" -m "Uberkey $NEW"
git push -q origin main
git push -q origin "v$NEW"

# Release notes: the commit subjects since the last tag, which is what changed.
NOTES=$(git log --pretty='- %s' "v$PREV..v$NEW" 2>/dev/null | grep -v '^- Version ' || true)
[[ -n "$NOTES" ]] || NOTES="- See the commit history."

gh release create "v$NEW" dist/Uberkey.dmg dist/Uberkey.zip \
  --title "Uberkey $NEW" \
  --notes "$NOTES

**Install:** download \`Uberkey.dmg\`, drag Uberkey into Applications, then **right-click it and choose Open** — not a double-click, as Uberkey is not notarised. Grant Accessibility access when asked.

**Updating an existing copy:** replace the app and reopen it. The Accessibility grant carries over, because every release is signed with the same certificate."

echo
echo "==> Released v$NEW"
gh release view "v$NEW" --json url --jq .url
