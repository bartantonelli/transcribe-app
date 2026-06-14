# Transcribe.app

A drag-and-drop Mac app that transcribes audio with **speaker labels**, fully offline. Drop an `.m4a`, `.mp3`, `.wav`, or `.mp4` onto it — out comes a `.txt` with `Speaker 0` / `Speaker 1` turns next to the file.

Built on top of [whisper-diarization](https://github.com/MahmoudAshraf97/whisper-diarization) (faster-whisper + NVIDIA NeMo MSDD), wrapped into a self-contained `.app` bundle with a portable Python interpreter and all models pre-downloaded.

- **Runs offline.** No HuggingFace token, no internet at runtime.
- **No setup on the user's machine.** Bundle the .app, double-click, drag a file in.
- **Apple Silicon only** (M-series Macs). Intel support would need a parallel build.

The trade-off is size: the bundle is ~6 GB because we include Python, PyTorch, NeMo, and all model weights.

## Using the prebuilt app

1. Download the latest `Transcribe.app.zip` from the [Releases](#) page (or wherever you publish it — see "Distribution" below).
2. Unzip. The first time you double-click, macOS will refuse to open it because it's unsigned: **right-click → Open → Open**. You only need to do this once.
3. Drag an audio file onto the app icon. A Terminal window appears with live progress; when it finishes, `<your-audio>.txt` and `<your-audio>.srt` sit next to the original.

## Building from source

You'll need an Apple Silicon Mac and ~15 GB of free disk space during the build. The output is around 6 GB.

```bash
git clone https://github.com/<you>/transcribe-app.git
cd transcribe-app
./build.sh
open build/Transcribe.app   # or drag an audio file onto it
```

The first build takes 15–30 minutes (downloads ~3 GB of pip packages + ~3 GB of model weights). Re-runs reuse the `cache/` directory and are much faster.

### What `build.sh` does

1. Compiles `app/droplet.applescript` into `build/Transcribe.app`.
2. Downloads a [portable Python](https://github.com/astral-sh/python-build-standalone) tarball at the version pinned in `versions.env` and extracts it into `Resources/python/`.
3. Installs `requirements.lock` (a full `pip freeze`) with `--no-deps` so no resolver drift.
4. Clones whisper-diarization at the pinned commit and copies the relevant scripts into `Resources/whisper-diarization/`.
5. Runs `scripts/download_models.py` which fetches faster-whisper, the forced aligner, the punctuation model, and the two NeMo models into `Resources/models/`.
6. Generates the icon from `scripts/make_icon.py` and converts it to a `.icns`.
7. Installs `app/transcribe.sh` (the worker the droplet calls) into `Resources/`.
8. Strips `__pycache__` and re-signs the bundle ad-hoc so Finder picks up the icon.

### Pinning

Three layers of version pinning keep the build reproducible:

| What | Where |
|---|---|
| Python interpreter | `versions.env` (`PYTHON_VERSION`, `PYTHON_RELEASE`) |
| Pip dependencies | `requirements.lock` (full freeze, including git+https commits for unreleased packages) |
| whisper-diarization | `versions.env` (`WD_COMMIT`) |
| Model versions | `versions.env` (HF repo IDs + NeMo model names) |

To upgrade anything, edit `versions.env`, rebuild once to check it still works, then regenerate the lock with:

```bash
build/Transcribe.app/Contents/Resources/python/bin/python3 -m pip freeze > requirements.lock
```

## Repo layout

```
transcribe-app/
├── build.sh               # The one-shot build
├── versions.env           # Pinned upstream versions
├── requirements.lock      # Pinned pip dependencies (pip freeze output)
├── app/
│   ├── droplet.applescript    # Source for the .app launcher
│   └── transcribe.sh          # Worker script bundled into Resources/
└── scripts/
    ├── download_models.py # Pulls all model artefacts into the bundle
    └── make_icon.py       # Generates the icon programmatically
```

Everything under `build/` and `cache/` is gitignored.

## Distribution

The 6 GB bundle is too big for GitHub's 2 GB-per-file Release asset limit. Options:

- **Hugging Face Hub** (recommended): create a model repo and `hf upload` the zipped app. Free, no per-file size limit, links cleanly from the GitHub README.
- **S3 / R2 / B2**: any object storage works; sign a public URL.
- **Split assets on GitHub**: `split -b 1900m Transcribe.zip Transcribe.zip.part-` then upload the parts; users `cat` them back together. Free, but ugly.

After building, zip with `ditto` (preserves macOS metadata like the icon) before uploading:

```bash
cd build
ditto -c -k --keepParent --sequesterRsrc Transcribe.app Transcribe.zip
```

## Acknowledgements

- [whisper-diarization](https://github.com/MahmoudAshraf97/whisper-diarization) — the pipeline this wraps.
- [faster-whisper](https://github.com/SYSTRAN/faster-whisper) — the transcription engine.
- [NVIDIA NeMo](https://github.com/NVIDIA/NeMo) — the diarization models (MSDD + VAD).
- [python-build-standalone](https://github.com/astral-sh/python-build-standalone) — the portable Python interpreter.

## License

MIT. See [LICENSE](./LICENSE).
