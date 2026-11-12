"""Transcribe.app pipeline: audio in, speaker-labelled .txt and .srt out.

The same steps and models as whisper-diarization's diarize.py, so the words
are unchanged, but the three steps that only need the audio run side by side
instead of one after another:

    words        Whisper medium.en, faster-whisper int8   CPU (main thread)
    word timing  MMS-300m aligner emissions                GPU (thread)
    speakers     speaker-native (pyannote, Core ML)        Neural Engine (process)

Fully offline. Run with the bundled Python from the folder that holds
whisper-diarization/ (for its helpers), bin/speaker-native and models/.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import wave

RES = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(RES, "whisper-diarization"))

import faster_whisper  # noqa: E402
import torch  # noqa: E402
from ctc_forced_aligner import (  # noqa: E402
    generate_emissions,
    get_alignments,
    get_spans,
    load_alignment_model,
    postprocess_results,
    preprocess_text,
)
from deepmultilingualpunctuation import PunctuationModel  # noqa: E402
from helpers import (  # noqa: E402
    get_realigned_ws_mapping_with_punctuation,
    get_sentences_speaker_mapping,
    get_speaker_aware_transcript,
    get_words_speaker_mapping,
    write_srt,
)

WHISPER_MODEL = "medium.en"
BATCH_SIZE = 8
# The aligner's output is the same at any batch size, but memory is not: 8
# windows at once needs ~10 GB and sends a 16 GB Mac into swap.
ALIGN_BATCH_SIZE = 1

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("audio")
parser.add_argument(
    "--align-device",
    default="mps" if torch.backends.mps.is_available() else "cpu",
    help="where the word-timing model runs (mps = GPU)",
)
parser.add_argument("--timings", action="store_true", help="print how long each step took")
args = parser.parse_args()

t0 = time.time()
timings = {}


def stage(name):
    print(name, flush=True)


def background(fn):
    """Run fn in a thread; .result() waits for it and re-raises its error."""
    box = {}

    def run():
        start = time.time()
        try:
            box["value"] = fn()
        except BaseException as e:  # re-raised in result()
            box["error"] = e
        timings[fn.__name__] = time.time() - start

    thread = threading.Thread(target=run, daemon=True)
    thread.start()

    def result():
        thread.join()
        if "error" in box:
            raise box["error"]
        return box["value"]

    return result


stage("Loading audio")
audio = faster_whisper.decode_audio(args.audio)


def speakers():
    """[(start_ms, end_ms, speaker), ...] from the bundled speaker-native tool."""
    with tempfile.TemporaryDirectory() as tmp:
        wav_path = os.path.join(tmp, "speakers.wav")
        turns_path = os.path.join(tmp, "speakers.json")
        # The same samples the other steps use, so any format they read works.
        with wave.open(wav_path, "wb") as f:
            f.setnchannels(1)
            f.setsampwidth(2)
            f.setframerate(16000)
            f.writeframes((audio.clip(-1, 1) * 32767).astype("<i2").tobytes())
        subprocess.run(
            [
                os.path.join(RES, "bin", "speaker-native"),
                "diarize",
                wav_path,
                "--models",
                os.path.join(RES, "models", "speaker"),
                "--out",
                turns_path,
            ],
            check=True,
        )
        with open(turns_path) as f:
            turns = [tuple(t) for t in json.load(f)]
    # No speech found: one turn over the whole file, as there is nobody to tell apart.
    return turns or [(0, len(audio) // 16, 0)]


def word_timing():
    """Aligner emissions for the whole recording; they don't depend on the words."""
    model, tokenizer = load_alignment_model(args.align_device, dtype=torch.float32)
    emissions, stride = generate_emissions(
        model, torch.from_numpy(audio).to(model.dtype).to(model.device), batch_size=ALIGN_BATCH_SIZE
    )
    return emissions.cpu(), stride, tokenizer


speakers_result = background(speakers)
word_timing_result = background(word_timing)

stage("Transcribing")
start = time.time()
whisper_model = faster_whisper.WhisperModel(WHISPER_MODEL, device="cpu", compute_type="int8")
segments, info = faster_whisper.BatchedInferencePipeline(whisper_model).transcribe(
    audio, "en", suppress_tokens=[-1], batch_size=BATCH_SIZE
)
full_transcript = "".join(segment.text for segment in segments)
del whisper_model
timings["words"] = time.time() - start

stage("Timing words")
start = time.time()
emissions, stride, alignment_tokenizer = word_timing_result()
tokens_starred, text_starred = preprocess_text(full_transcript, romanize=True, language="eng")
aligned, scores, blank_token = get_alignments(emissions, tokens_starred, alignment_tokenizer)
spans = get_spans(tokens_starred, aligned, blank_token)
word_timestamps = postprocess_results(text_starred, spans, stride, scores)
timings["align"] = time.time() - start

stage("Identifying speakers")
speaker_ts = speakers_result()
wsm = get_words_speaker_mapping(word_timestamps, speaker_ts, "start")

stage("Adding punctuation")
start = time.time()
# Restore sentence-ending punctuation so sentences can be kept with one speaker.
labelled = PunctuationModel(model="kredor/punctuate-all").predict([w["word"] for w in wsm], chunk_size=230)
is_acronym = lambda x: re.fullmatch(r"\b(?:[a-zA-Z]\.){2,}", x)  # don't end U.S.A. with a period
for word_dict, label in zip(wsm, labelled):
    word, mark = word_dict["word"], label[1]
    if word and mark in ".?!" and (word[-1] not in ".,;:!?" or is_acronym(word)):
        word += mark
        if word.endswith(".."):
            word = word.rstrip(".")
        word_dict["word"] = word
timings["punctuation"] = time.time() - start

wsm = get_realigned_ws_mapping_with_punctuation(wsm)
ssm = get_sentences_speaker_mapping(wsm, speaker_ts)

base = os.path.splitext(args.audio)[0]
with open(f"{base}.txt", "w", encoding="utf-8-sig") as f:
    get_speaker_aware_transcript(ssm, f)
with open(f"{base}.srt", "w", encoding="utf-8-sig") as srt:
    write_srt(ssm, srt)

if args.timings:
    timings["total"] = time.time() - t0
    print("TIMINGS " + " ".join(f"{k}={v:.0f}s" for k, v in timings.items()), flush=True)
