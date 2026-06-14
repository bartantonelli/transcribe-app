#!/bin/bash
# build.sh — Build Transcribe.app from pinned sources, end-to-end.
#
# Reproducible: every version is pinned in versions.env or requirements.lock.
# Safe to re-run; intermediate downloads are cached under cache/.

set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"

# shellcheck disable=SC1091
source versions.env

mkdir -p cache build
APP="$ROOT/build/Transcribe.app"

step() { echo ""; echo "==> $*"; }

# Sanity checks for tools we need (all built into macOS or trivial).
for tool in curl tar git osacompile iconutil sips codesign rsync; do
    command -v "$tool" >/dev/null || { echo "Missing tool: $tool"; exit 1; }
done

# ---------------------------------------------------------------
step "1/9 Compile AppleScript droplet -> Transcribe.app"
# ---------------------------------------------------------------
rm -rf "$APP"
osacompile -o "$APP" app/droplet.applescript

# ---------------------------------------------------------------
step "2/9 Download portable Python ${PYTHON_VERSION} (${PYTHON_RELEASE})"
# ---------------------------------------------------------------
PY_TARBALL="cache/$(basename "$PYTHON_URL")"
if [ ! -f "$PY_TARBALL" ]; then
    curl -L --fail -o "$PY_TARBALL" "$PYTHON_URL"
fi

# ---------------------------------------------------------------
step "3/9 Extract Python into the .app"
# ---------------------------------------------------------------
PY_ROOT="$APP/Contents/Resources/python"
mkdir -p "$PY_ROOT"
tar -xzf "$PY_TARBALL" -C "$PY_ROOT" --strip-components=1
PY="$PY_ROOT/bin/python3"
echo "    $("$PY" --version)"

# ---------------------------------------------------------------
step "4/9 Install pinned Python dependencies (slow, ~5-10 min)"
# ---------------------------------------------------------------
"$PY" -m pip install --upgrade pip
# Lock file is a full pip freeze, so --no-deps is safe and prevents resolver
# drift. Every transitive dep is already listed with an exact version.
"$PY" -m pip install --no-deps -r requirements.lock

# ---------------------------------------------------------------
step "5/9 Clone whisper-diarization @ ${WD_COMMIT:0:10}"
# ---------------------------------------------------------------
WD="$APP/Contents/Resources/whisper-diarization"
rm -rf "$WD"
git clone --quiet "$WD_REPO" "$WD"
(cd "$WD" && git checkout --quiet "$WD_COMMIT")
rm -rf "$WD/.git" "$WD/tests"
find "$WD" -name '*.ipynb' -delete

# ---------------------------------------------------------------
step "6/9 Download models (~3 GB, slowest network step)"
# ---------------------------------------------------------------
HF_DIR="$APP/Contents/Resources/models/huggingface"
NEMO_DIR="$APP/Contents/Resources/models/torch"
WHISPER_MODEL="$WHISPER_MODEL" \
HF_FORCED_ALIGNER="$HF_FORCED_ALIGNER" \
HF_PUNCTUATION="$HF_PUNCTUATION" \
NEMO_VAD_MODEL="$NEMO_VAD_MODEL" \
NEMO_MSDD_MODEL="$NEMO_MSDD_MODEL" \
    "$PY" scripts/download_models.py --hf-home "$HF_DIR" --torch-home "$NEMO_DIR"

# ---------------------------------------------------------------
step "7/9 Generate icon and install it"
# ---------------------------------------------------------------
"$PY" scripts/make_icon.py cache/icon_1024.png
ICONSET="cache/Transcribe.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
    sz=${spec%% *}; name=${spec#* }
    sips -z "$sz" "$sz" cache/icon_1024.png \
        --out "$ICONSET/icon_${name}.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/droplet.icns"

# ---------------------------------------------------------------
step "8/9 Install worker script and strip caches"
# ---------------------------------------------------------------
cp app/transcribe.sh "$APP/Contents/Resources/transcribe.sh"
chmod +x "$APP/Contents/Resources/transcribe.sh"
find "$APP" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
find "$APP" -name '*.pyc' -delete 2>/dev/null || true
find "$APP" -path '*/site-packages/tests' -type d -exec rm -rf {} + 2>/dev/null || true

# pip-installed CLI wrappers bake the absolute build path into their shebang
# (e.g. `#!/Users/<you>/codes/.../python3`). They leak your username and don't
# work on the user's machine anyway because the .app moves. We never call any
# of them — transcribe.sh invokes Resources/python/bin/python3 directly — so
# nuke every text shebang script in bin/, keeping the python binary + symlinks.
BIN="$APP/Contents/Resources/python/bin"
for f in "$BIN"/*; do
    [ -L "$f" ] && continue                          # keep symlinks (python, python3)
    case "$(file -b "$f" 2>/dev/null)" in
        *text\ executable*|*Python\ script*) rm "$f" ;;
    esac
done

# ---------------------------------------------------------------
step "9/9 Re-sign the bundle (ad-hoc) so Finder shows the icon"
# ---------------------------------------------------------------
codesign --force --deep --sign - "$APP" 2>&1 | tail -2

SIZE=$(du -sh "$APP" | cut -f1)
echo ""
echo "================================================"
echo "  Built: $APP"
echo "  Size:  $SIZE"
echo "================================================"
echo ""
echo "Test it: drag any .m4a / .mp3 / .wav / .mp4 onto the app."
