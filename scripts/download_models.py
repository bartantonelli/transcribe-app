"""Pre-download the Python-side models needed by the bundled pipeline.

Run with the bundled Python *after* requirements.lock has been installed.
All model files end up under the cache dir passed in, so the .app stays
self-contained at runtime. (The speaker models are fetched separately by
`speaker-native fetch-models`.)
"""
import argparse
import os
import sys
from pathlib import Path


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--hf-home", required=True,
                    help="Destination for HuggingFace model cache (HF_HOME)")
    args = ap.parse_args()

    hf_home = Path(args.hf_home).resolve()
    hf_home.mkdir(parents=True, exist_ok=True)

    # Must be set *before* any HuggingFace import so the libs write to the
    # bundled directory rather than the user's ~/.cache.
    os.environ["HF_HOME"] = str(hf_home)
    print(f"HF_HOME = {hf_home}\n")

    # 1. faster-whisper transcription model.
    whisper_model = os.environ.get("WHISPER_MODEL", "medium.en")
    print(f"== faster-whisper {whisper_model} ==")
    from faster_whisper import WhisperModel  # noqa: E402
    WhisperModel(whisper_model, device="cpu", compute_type="int8")

    # 2. ctc-forced-aligner (MMS-300m). The repo ships the same weights twice
    # (model.safetensors and pytorch_model.bin, 1.2 GB each); transformers
    # loads the safetensors copy, so skip the other.
    print("\n== ctc-forced-aligner (mms-300m-1130) ==")
    from huggingface_hub import snapshot_download  # noqa: E402
    snapshot_download(
        repo_id=os.environ.get(
            "HF_FORCED_ALIGNER", "MahmoudAshraf/mms-300m-1130-forced-aligner"),
        ignore_patterns=["pytorch_model.bin"],
    )

    # 3. Punctuation model (kredor/punctuate-all).
    print("\n== punctuation (kredor/punctuate-all) ==")
    snapshot_download(
        repo_id=os.environ.get("HF_PUNCTUATION", "kredor/punctuate-all"),
    )

    print("\nAll models downloaded.")


if __name__ == "__main__":
    sys.exit(main())
