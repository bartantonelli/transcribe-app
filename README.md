# Transcribe.app

A drag-and-drop Mac app that transcribes audio with **speaker labels**, fully offline. Drop an `.m4a`, `.mp3`, `.wav`, or `.mp4` onto it — out comes a `.txt` with `Speaker 0` / `Speaker 1` turns next to the file.

Built on top of [whisper-diarization](https://github.com/MahmoudAshraf97/whisper-diarization) (faster-whisper for the words), with speaker labelling done by pyannote models running on the Mac's Neural Engine, wrapped into a self-contained `.app` bundle with a portable Python interpreter and all models pre-downloaded.

- **Runs offline.** No HuggingFace token, no internet at runtime.
- **No setup on the user's machine.** Bundle the .app, double-click, drag a file in.
- **Apple Silicon only** (M-series Macs). Intel support would need a parallel build.

The trade-off is size: the bundle is ~4.4 GB because we include Python, PyTorch, and all model weights.

## Installing

On an Apple Silicon Mac, open **Terminal** (press ⌘-Space, type "Terminal", press Return), paste this line and press Return:

```bash
curl -fsSL https://github.com/bartantonelli/transcribe-app/releases/latest/download/install.sh | bash
```

It downloads the app (about 4 GB, so give it a while), checks the download, and puts **Transcribe** in your Applications folder, replacing any older copy. It needs about 10 GB of free disk space while installing. After that the app never uses the internet.

Then drag an audio file onto the app icon. A Terminal window appears with live progress; when it finishes, `<your-audio>.txt` and `<your-audio>.srt` sit next to the original.

Installing this way avoids the "unidentified developer" warning, because macOS only shows it for apps downloaded with a browser. If you copy the app over by AirDrop or a USB stick instead and macOS refuses to open it, **right-click → Open → Open** once.

## Building from source

You'll need an Apple Silicon Mac with the Xcode Command Line Tools (`xcode-select --install`) and ~10 GB of free disk space during the build. The output is around 4.4 GB.

```bash
git clone https://github.com/bartantonelli/transcribe-app.git
cd transcribe-app
./build.sh
open build/Transcribe.app   # or drag an audio file onto it
```

The first build takes 15–30 minutes (downloads ~1 GB of pip packages + ~3.6 GB of model weights). Re-runs reuse the `cache/` directory and are much faster.

### What `build.sh` does

1. Compiles `app/droplet.applescript` into `build/Transcribe.app`.
2. Downloads a [portable Python](https://github.com/astral-sh/python-build-standalone) tarball at the version pinned in `versions.env` and extracts it into `Resources/python/`.
3. Installs `requirements.lock` (a full `pip freeze`) with `--no-deps` so no resolver drift.
4. Clones whisper-diarization at the pinned commit, applies the local fixes in `patches/whisper-diarization/`, and keeps its `helpers.py` in `Resources/whisper-diarization/`.
5. Runs `scripts/download_models.py` which fetches faster-whisper, the forced aligner, and the punctuation model into `Resources/models/`.
6. Generates the icon from `scripts/make_icon.py` and converts it to a `.icns`.
7. Builds `native/` (the `speaker-native` tool) into `Resources/bin/` and downloads its speaker models into `Resources/models/speaker/`.
8. Installs `app/transcribe.sh` (the worker the droplet calls) and `app/pipeline.py` (the pipeline it runs) into `Resources/`.
9. Strips `__pycache__` and re-signs the bundle ad-hoc so Finder picks up the icon.

### How a recording is processed

| Stage | Engine | Runs on |
|---|---|---|
| Words | Whisper medium.en (faster-whisper, int8) | CPU |
| Word timing | MMS-300m forced aligner | GPU |
| Who spoke when | pyannote segmentation + embeddings (SpeakerKit, Core ML) | Neural Engine / GPU |
| Punctuation | punctuate-all | GPU |

`app/pipeline.py` runs the same steps and models as whisper-diarization's `diarize.py`, so the words are the same, with two changes that make it several times faster:

- Speaker labelling used to be NVIDIA NeMo on the CPU and took about four fifths of the run time. It now takes seconds.
- Word timing and speaker labelling only need the audio, so they run alongside transcription instead of after it. The aligner also works one window at a time, which gives the same output but needs under 1 GB of memory instead of ~10 GB.

Transcription itself is now nearly all of the run time (about 4× faster than real time on an M3).

To compare two transcripts (words, exact text, and speaker labels):

```bash
python3 scripts/ab_compare.py old.txt new.txt
```

### Pinning

Three layers of version pinning keep the build reproducible:

| What | Where |
|---|---|
| Python interpreter | `versions.env` (`PYTHON_VERSION`, `PYTHON_RELEASE`) |
| Pip dependencies | `requirements.lock` (full freeze, including git+https commits for unreleased packages) |
| whisper-diarization | `versions.env` (`WD_COMMIT`) |
| Model versions | `versions.env` (HF repo IDs, speaker model revision) |
| speaker-native | `native/Package.swift` + `native/Package.resolved` |

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
│   ├── pipeline.py            # The transcription pipeline (bundled into Resources/)
│   └── transcribe.sh          # Worker script bundled into Resources/
├── native/                # speaker-native: speaker labelling on the Neural Engine (Swift)
├── patches/
│   └── whisper-diarization/   # Local fixes applied on top of the pinned commit
└── scripts/
    ├── ab_compare.py      # Compare two transcripts (words + speaker labels)
    ├── download_models.py # Pulls all model artefacts into the bundle
    ├── install.sh         # One-line installer published with each release
    ├── package.sh         # Zips and splits the built app into release assets
    └── make_icon.py       # Generates the icon programmatically
```

Everything under `build/` and `cache/` is gitignored.

## Releasing

The zipped app is bigger than GitHub's 2 GB-per-file limit for release assets, so it is published in parts, with checksums and the installer:

```bash
./build.sh
scripts/package.sh          # writes dist/: zip parts, SHA256SUMS, install.sh
gh release create v1.2.3 dist/* --title "Transcribe 1.2.3" --notes "..."
```

`scripts/install.sh` (the one-line install above) downloads the parts from the latest release, verifies them against `SHA256SUMS`, joins them and installs the app.

## Acknowledgements

- [whisper-diarization](https://github.com/MahmoudAshraf97/whisper-diarization) — the pipeline this wraps.
- [faster-whisper](https://github.com/SYSTRAN/faster-whisper) — the transcription engine.
- [WhisperKit / SpeakerKit](https://github.com/argmaxinc/WhisperKit) and [pyannote](https://github.com/pyannote/pyannote-audio) — speaker labelling on the Neural Engine.
- [python-build-standalone](https://github.com/astral-sh/python-build-standalone) — the portable Python interpreter.

## License

MIT. See [LICENSE](./LICENSE).
