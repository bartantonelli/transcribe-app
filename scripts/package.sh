#!/bin/bash
# package.sh — turn build/Transcribe.app into release assets under dist/.
#
# GitHub Releases cap each file at 2 GB and the zipped app is bigger, so the
# zip is split into parts. scripts/install.sh downloads the parts, checks them
# against SHA256SUMS, joins them and installs the app.
#
#   ./build.sh && scripts/package.sh
#   gh release create vX.Y.Z dist/* --title ... --notes ...
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Transcribe.app"
[ -d "$APP" ] || { echo "Missing $APP — run ./build.sh first"; exit 1; }

rm -rf dist && mkdir dist
echo "==> Zipping $APP (a few minutes)"
# ditto keeps the code signature, icon and symlinks intact.
ditto -c -k --keepParent --sequesterRsrc "$APP" dist/Transcribe.zip

echo "==> Splitting into parts under 2 GB"
(cd dist && split -b 1900m Transcribe.zip Transcribe.zip.part- && rm Transcribe.zip)
(cd dist && shasum -a 256 Transcribe.zip.part-* > SHA256SUMS)
cp scripts/install.sh dist/install.sh

echo ""
ls -lh dist
