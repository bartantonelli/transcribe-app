#!/bin/bash
# package.sh — turn build/Transcribe.app into release assets under dist/.
#
# GitHub Releases cap each file at 2 GB and the zipped app is bigger, so the
# zip is split into parts. They are kept small (450 MB) because one long
# upload or download that stalls has to start again from scratch. scripts/install.sh downloads the parts, checks them
# against SHA256SUMS, joins them and installs the app.
#
#   ./build.sh && scripts/package.sh
#   scripts/publish.sh vX.Y.Z "Transcribe X.Y.Z" notes.md
set -euo pipefail
cd "$(dirname "$0")/.."
DIST="${DIST:-dist}"   # where the release files go

APP="build/Transcribe.app"
[ -d "$APP" ] || { echo "Missing $APP — run ./build.sh first"; exit 1; }

rm -rf "$DIST" && mkdir -p "$DIST"
echo "==> Zipping $APP (a few minutes)"
# ditto keeps the code signature, icon and symlinks intact.
ditto -c -k --keepParent --sequesterRsrc "$APP" "$DIST/Transcribe.zip"

echo "==> Splitting into 450 MB parts"
(cd "$DIST" && split -b 450m Transcribe.zip Transcribe.zip.part- && rm Transcribe.zip)
(cd "$DIST" && shasum -a 256 Transcribe.zip.part-* > SHA256SUMS)
cp scripts/install.sh "$DIST/install.sh"

echo ""
ls -lh "$DIST"
