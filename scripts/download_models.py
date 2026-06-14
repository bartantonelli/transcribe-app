"""Pre-download every model needed by the bundled diarization pipeline.

Run with the bundled Python *after* requirements.lock has been installed.
All model files end up under the cache dirs passed in, so the .app stays
self-contained at runtime.
"""
import argparse
import os
import sys
from pathlib import Path


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--hf-home", required=True,
                    help="Destination for HuggingFace model cache (HF_HOME)")
    ap.add_argument("--torch-home", required=True,
                    help="Destination for NeMo / torch cache (TORCH_HOME)")
    args = ap.parse_args()

    hf_home = Path(args.hf_home).resolve()
    torch_home = Path(args.torch_home).resolve()
    hf_home.mkdir(parents=True, exist_ok=True)
    torch_home.mkdir(parents=True, exist_ok=True)

    # These must be set *before* any HuggingFace / NeMo import so the libs
    # write to the bundled directories rather than the user's ~/.cache.
    os.environ["HF_HOME"] = str(hf_home)
    os.environ["TORCH_HOME"] = str(torch_home)

    print(f"HF_HOME    = {hf_home}")
    print(f"TORCH_HOME = {torch_home}")
    print()

    # 1. faster-whisper transcription model.
    whisper_model = os.environ.get("WHISPER_MODEL", "medium.en")
    print(f"== faster-whisper {whisper_model} ==")
    from faster_whisper import WhisperModel  # noqa: E402
    WhisperModel(whisper_model, device="cpu", compute_type="int8")

    # 2. ctc-forced-aligner (MMS-300m).
    print("\n== ctc-forced-aligner (mms-300m-1130) ==")
    from huggingface_hub import snapshot_download  # noqa: E402
    snapshot_download(
        repo_id=os.environ.get(
            "HF_FORCED_ALIGNER", "MahmoudAshraf/mms-300m-1130-forced-aligner"),
    )

    # 3. Punctuation model (kredor/punctuate-all).
    print("\n== punctuation (kredor/punctuate-all) ==")
    snapshot_download(
        repo_id=os.environ.get("HF_PUNCTUATION", "kredor/punctuate-all"),
    )

    # 4. NeMo VAD model — fetched from NGC into TORCH_HOME/NeMo/...
    print(f"\n== NeMo VAD ({os.environ.get('NEMO_VAD_MODEL', 'vad_multilingual_marblenet')}) ==")
    from nemo.collections.asr.models import EncDecClassificationModel  # noqa: E402
    EncDecClassificationModel.from_pretrained(
        os.environ.get("NEMO_VAD_MODEL", "vad_multilingual_marblenet"),
        map_location="cpu",
    )

    # 5. NeMo MSDD model (diarization).
    print(f"\n== NeMo MSDD ({os.environ.get('NEMO_MSDD_MODEL', 'diar_msdd_telephonic')}) ==")
    from nemo.collections.asr.models.msdd_models import NeuralDiarizer  # noqa: E402
    NeuralDiarizer.from_pretrained(
        os.environ.get("NEMO_MSDD_MODEL", "diar_msdd_telephonic"),
        map_location="cpu",
    )

    print("\nAll models downloaded.")


if __name__ == "__main__":
    sys.exit(main())
