#!/bin/bash
# publish.sh — upload dist/ (from scripts/package.sh) as a GitHub release.
#
#   scripts/publish.sh <tag> <title> <notes-file> [<commit>]
#
# The release stays a draft until every file is up, so the install command
# never sees a half-uploaded release. Each file is retried on its own, which
# matters for multi-GB uploads on a home connection. Safe to re-run: files
# already uploaded are skipped.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:?tag, e.g. v1.2.3}"
TITLE="${2:?title}"
NOTES="${3:?notes file}"
COMMIT="$(git rev-parse "${4:-HEAD}")"
[ -f dist/SHA256SUMS ] || { echo "Missing dist/ — run scripts/package.sh first"; exit 1; }

if ! gh release view "$TAG" >/dev/null 2>&1; then
    gh release create "$TAG" --draft --target "$COMMIT" --title "$TITLE" --notes-file "$NOTES"
fi

for f in dist/*; do
    name="$(basename "$f")"
    if gh release view "$TAG" --json assets --jq '.assets[] | select(.state == "uploaded") | .name' | grep -qx "$name"; then
        echo "have  $name"
        continue
    fi
    for attempt in 1 2 3 4 5; do
        echo "send  $name (attempt $attempt)"
        gh release upload "$TAG" "$f" --clobber && break
        [ "$attempt" = 5 ] && { echo "Giving up on $name; run this script again to resume."; exit 1; }
        sleep 10
    done
done

gh release edit "$TAG" --draft=false --latest
echo "Published $TAG"
