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
for tool in curl tar git iconutil sips codesign rsync swift; do
    command -v "$tool" >/dev/null || { echo "Missing tool: $tool"; exit 1; }
done

# ---------------------------------------------------------------
step "1/10 Create the Transcribe.app bundle"
# ---------------------------------------------------------------
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp app/Info.plist "$APP/Contents/Info.plist"

# ---------------------------------------------------------------
step "2/10 Download portable Python ${PYTHON_VERSION} (${PYTHON_RELEASE})"
# ---------------------------------------------------------------
PY_TARBALL="cache/$(basename "$PYTHON_URL")"
if [ ! -f "$PY_TARBALL" ]; then
    curl -L --fail -o "$PY_TARBALL" "$PYTHON_URL"
fi

# ---------------------------------------------------------------
step "3/10 Extract Python into the .app"
# ---------------------------------------------------------------
PY_ROOT="$APP/Contents/Resources/python"
mkdir -p "$PY_ROOT"
tar -xzf "$PY_TARBALL" -C "$PY_ROOT" --strip-components=1
PY="$PY_ROOT/bin/python3"
echo "    $("$PY" --version)"

# ---------------------------------------------------------------
step "4/10 Install pinned Python dependencies (slow, ~5-10 min)"
# ---------------------------------------------------------------
"$PY" -m pip install --upgrade pip
# Lock file is a full pip freeze, so --no-deps is safe and prevents resolver
# drift. Every transitive dep is already listed with an exact version.
"$PY" -m pip install --no-deps -r requirements.lock

# ---------------------------------------------------------------
step "5/10 Clone whisper-diarization @ ${WD_COMMIT:0:10}"
# ---------------------------------------------------------------
WD="$APP/Contents/Resources/whisper-diarization"
rm -rf "$WD"
git clone --quiet "$WD_REPO" "$WD"
(cd "$WD" && git checkout --quiet "$WD_COMMIT")
# Local fixes on top of the pinned commit (e.g. single-spaced transcripts).
for p in "$ROOT"/patches/whisper-diarization/*.patch; do
    (cd "$WD" && git apply "$p")
    echo "    applied $(basename "$p")"
done
# The app runs its own app/pipeline.py; from whisper-diarization it only needs
# the helper functions (and the licence that goes with them).
find "$WD" -mindepth 1 -maxdepth 1 ! -name helpers.py ! -name LICENSE -exec rm -rf {} +

# ---------------------------------------------------------------
step "6/10 Download models (~3.6 GB, slowest network step)"
# ---------------------------------------------------------------
HF_DIR="$APP/Contents/Resources/models/huggingface"
WHISPER_MODEL="$WHISPER_MODEL" \
HF_FORCED_ALIGNER="$HF_FORCED_ALIGNER" \
HF_PUNCTUATION="$HF_PUNCTUATION" \
    "$PY" scripts/download_models.py --hf-home "$HF_DIR"

# ---------------------------------------------------------------
step "7/10 Generate icon and install it"
# ---------------------------------------------------------------
# Pillow is only needed to draw the icon, so it stays out of the bundle.
"$PY" -m pip install --quiet --target cache/buildtools "pillow==$PILLOW_VERSION"
PYTHONPATH=cache/buildtools "$PY" scripts/make_icon.py cache/icon_1024.png
ICONSET="cache/Transcribe.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
    sz=${spec%% *}; name=${spec#* }
    sips -z "$sz" "$sz" cache/icon_1024.png \
        --out "$ICONSET/icon_${name}.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Transcribe.icns"

# ---------------------------------------------------------------
step "8/10 Build the app window and speaker-native, download speaker models"
# ---------------------------------------------------------------
# Some Command Line Tools installs keep a stale *.private.swiftinterface from an
# older version, which makes every Package.swift fail to compile. If so, build
# against a clean copy of SwiftPM's libraries instead of touching /Library.
PM_LIBS="$(dirname "$(dirname "$(xcrun -f swift)")")/lib/swift/pm"
PD="$PM_LIBS/ManifestAPI/PackageDescription.swiftmodule"
if [ -f "$PD/arm64-apple-macos.private.swiftinterface" ] && \
   [ "$PD/arm64-apple-macos.private.swiftinterface" -ot "$PM_LIBS/ManifestAPI/libPackageDescription.dylib" ]; then
    rm -rf cache/swiftpm-libs && cp -R "$PM_LIBS" cache/swiftpm-libs
    find cache/swiftpm-libs -name '*.private.swiftinterface' -delete
    export SWIFTPM_CUSTOM_LIBS_DIR="$ROOT/cache/swiftpm-libs"
fi
(cd native && swift build -c release --product speaker-native && swift build -c release --product Transcribe)
cp native/.build/release/Transcribe "$APP/Contents/MacOS/Transcribe"
mkdir -p "$APP/Contents/Resources/bin"
cp native/.build/release/speaker-native "$APP/Contents/Resources/bin/"
# A few small files from Hugging Face. The request sometimes times out and can
# leave files half-downloaded, so check the models really load and start over
# if they don't.
SPEAKER_MODELS="$APP/Contents/Resources/models/speaker"
for attempt in 1 2 3 4 5; do
    if "$APP/Contents/Resources/bin/speaker-native" fetch-models "$SPEAKER_MODELS" --revision "$SPEAKERKIT_REVISION" \
        && "$APP/Contents/Resources/bin/speaker-native" check "$SPEAKER_MODELS"; then
        break
    fi
    [ "$attempt" = 5 ] && { echo "Could not download the speaker models"; exit 1; }
    rm -rf "$SPEAKER_MODELS"
    sleep 10
done
# Download bookkeeping, not needed at run time.
find "$SPEAKER_MODELS" -name .cache -type d -exec rm -rf {} + 2>/dev/null || true

# ---------------------------------------------------------------
step "9/10 Install the pipeline and strip caches"
# ---------------------------------------------------------------
cp app/pipeline.py "$APP/Contents/Resources/pipeline.py"
find "$APP" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
find "$APP" -name '*.pyc' -delete 2>/dev/null || true
find "$APP" -path '*/site-packages/tests' -type d -exec rm -rf {} + 2>/dev/null || true

# pip-installed CLI wrappers bake the absolute build path into their shebang
# (e.g. `#!/Users/<you>/codes/.../python3`). They leak your username and don't
# work on the user's machine anyway because the .app moves. We never call any
# of them — the app invokes Resources/python/bin/python3 directly — so
# nuke every text shebang script in bin/, keeping the python binary + symlinks.
BIN="$APP/Contents/Resources/python/bin"
for f in "$BIN"/*; do
    [ -L "$f" ] && continue                          # keep symlinks (python, python3)
    case "$(file -b "$f" 2>/dev/null)" in
        *text\ executable*|*Python\ script*) rm "$f" ;;
    esac
done
# Links to the scripts just removed (2to3, idle3, ...) would be left dangling,
# which `codesign --verify --strict` rejects.
find "$BIN" -type l ! -exec test -e {} \; -delete

# ---------------------------------------------------------------
step "10/10 Re-sign the bundle (ad-hoc) so Finder shows the icon"
# ---------------------------------------------------------------
codesign --force --deep --sign - "$APP" 2>&1 | tail -2

SIZE=$(du -sh "$APP" | cut -f1)
echo ""
echo "================================================"
echo "  Built: $APP"
echo "  Size:  $SIZE"
echo "================================================"
echo ""
echo "Test it: open the app and drop any .m4a / .mp3 / .wav / .mp4 into its window."
