#!/bin/bash
# Worker script bundled inside Transcribe.app/Contents/Resources/transcribe.sh
# Called by the droplet with one audio file path.
set -u

# Resolve our location inside the .app bundle.
RES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Use only the bundled Python — never the system Python.
export PATH="$RES/python/bin:$PATH"
export PYTHONNOUSERSITE=1
unset PYTHONPATH

# Point HuggingFace and NeMo at the bundled model caches, and force offline.
export HF_HOME="$RES/models/huggingface"
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export TORCH_HOME="$RES/models/torch"

AUDIO="${1:-}"
if [ -z "$AUDIO" ] || [ ! -f "$AUDIO" ]; then
    echo "Usage: transcribe.sh <audio-file>"
    echo "(this script is normally called by Transcribe.app when you drag a file onto it)"
    read -p "Press Return to close..." _
    exit 1
fi

# Absolute paths so working-directory changes are safe.
AUDIO_ABS="$(cd "$(dirname "$AUDIO")" && pwd)/$(basename "$AUDIO")"
WORK="$(dirname "$AUDIO_ABS")"
LOG="${AUDIO_ABS}.log"
BASE="${AUDIO_ABS%.*}"

echo ""
echo "================================================"
echo "  Transcribing: $(basename "$AUDIO_ABS")"
echo "================================================"
echo "  This runs fully offline."
echo "  A ~30 min audio file takes ~15-30 min on CPU."
echo ""

cd "$WORK"
START=$(date +%s)

# Run the actual pipeline in the background so we can show progress.
(
    "$RES/python/bin/python3" "$RES/whisper-diarization/diarize.py" \
        -a "$AUDIO_ABS" --no-stem --language en --device cpu --whisper-model medium.en
) > "$LOG" 2>&1 &
PID=$!

# Live progress: refresh the same line every 5s with the current pipeline stage.
while kill -0 "$PID" 2>/dev/null; do
    sleep 5
    NOW=$(date +%s); EL=$((NOW - START))
    M=$((EL/60)); S=$((EL%60))
    STAGE=$(tail -150 "$LOG" 2>/dev/null | grep -oE \
        "Loading pretrained [a-zA-Z_]+|Generating predictions|Extracting embeddings|scale[0-9]|frame-level VAD|Clustering|Outputs are saved|MSDD|forced.align|punctuat|Loading checkpoint shards|Transcribing" \
        | tail -1)
    [ -z "$STAGE" ] && STAGE="loading models..."
    printf "\r  [%02d:%02d] %-70s" "$M" "$S" "$STAGE"
done
wait "$PID"
RC=$?
ELAPSED=$(( $(date +%s) - START ))
printf "\r%80s\r" ""   # clear the progress line

if [ $RC -eq 0 ]; then
    echo "================================================"
    echo "  DONE in ${ELAPSED}s"
    echo "================================================"
    echo "  Text:      ${BASE}.txt"
    echo "  Subtitles: ${BASE}.srt"
    rm -f "$LOG"
else
    echo "================================================"
    echo "  FAILED (exit $RC)"
    echo "================================================"
    echo "  Last 30 lines of log:"
    tail -30 "$LOG"
    echo ""
    echo "  Full log: $LOG"
fi

echo ""
read -p "Press Return to close this window..." _
