#!/bin/bash
# Installs Transcribe.app from the GitHub release. Run in Terminal:
#
#   curl -fsSL https://github.com/bartantonelli/transcribe-app/releases/latest/download/install.sh | bash
#
# Downloads the app (about 3 GB, in parts), checks every part against the
# published checksums, and puts Transcribe.app in /Applications, replacing any
# older copy there. After that the app never needs the internet again.
#
# Set TRANSCRIBE_VERSION=v1.1.0 to install a specific release instead of the latest.
set -euo pipefail

REPO="bartantonelli/transcribe-app"
VERSION="${TRANSCRIBE_VERSION:-latest}"
if [ "$VERSION" = "latest" ]; then
    BASE="https://github.com/$REPO/releases/latest/download"
else
    BASE="https://github.com/$REPO/releases/download/$VERSION"
fi
BASE="${TRANSCRIBE_BASE_URL:-$BASE}"   # for testing against a local folder

fail() { echo ""; echo "Install failed: $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Transcribe only runs on a Mac."
[ "$(uname -m)" = "arm64" ] || fail "Transcribe needs an Apple Silicon Mac (M1 or newer)."

DEST="${TRANSCRIBE_DEST:-/Applications}"       # for testing; normally /Applications
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

# Room for the download, the joined zip and the unpacked app, at the worst moment.
FREE_GB=$(( $(df -k "$DEST" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
[ "$FREE_GB" -ge 10 ] || fail "Need about 10 GB of free disk space; only ${FREE_GB} GB available."

TMP="$(mktemp -d "$DEST/.transcribe-install.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

echo "Installing Transcribe into $DEST"
curl -fsSL -o SHA256SUMS "$BASE/SHA256SUMS" || fail "Could not reach the download server."
PARTS=$(awk '{print $2}' SHA256SUMS)
N=$(echo "$PARTS" | wc -l | tr -d ' ')

i=0
for part in $PARTS; do
    i=$((i + 1))
    echo ""
    echo "Downloading part $i of $N"
    curl -fL --retry 5 --retry-delay 3 -C - --progress-bar -o "$part" "$BASE/$part" \
        || fail "Download of $part was interrupted. Run the install command again."
done

echo ""
echo "Checking the download"
shasum -a 256 -c SHA256SUMS >/dev/null || fail "The download is damaged. Run the install command again."

echo "Unpacking (a minute or two)"
for part in $PARTS; do
    cat "$part" >> Transcribe.zip
    rm "$part"
done
ditto -x -k Transcribe.zip unpacked
rm Transcribe.zip
[ -d unpacked/Transcribe.app ] || fail "The download did not contain Transcribe.app."

rm -rf "$DEST/Transcribe.app"
mv unpacked/Transcribe.app "$DEST/Transcribe.app"
# Downloaded with curl, so macOS should not have quarantined it; clear the flag
# anyway so the app opens with a normal double-click.
xattr -dr com.apple.quarantine "$DEST/Transcribe.app" 2>/dev/null || true

echo ""
echo "Done. Transcribe is in $DEST."
echo "Open it and drop a recording into the window to get a transcript next to the file."
open -R "$DEST/Transcribe.app" 2>/dev/null || true
