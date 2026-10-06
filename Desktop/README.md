# LingoClass Desktop

Shared Windows/macOS desktop migration workspace. The product interface is React + TypeScript. The Python runtime owns microphone capture, ONNX Whisper, the transcript ledger, role/speaker pipelines, translation coordination and session persistence. `pywebview` hosts the same built web interface in the platform's native WebView (WebView2 on Windows, WKWebView on macOS); no Rust runtime is required.

## Current integration

The live-caption dashboard uses the existing Python MVP HTTP API for model and microphone selection, recording start/stop, durable caption rows, live hypotheses, Qwen result rows and JSON export. The older diagnostic MVP stays available at `/lab`. Its saved session schema and raw audio remain in `Tools/transcription-mvp/sessions`.

For frontend development, run the Python backend on port 8786 and `npm run dev`. The Vite proxy forwards `/api` requests to that local backend. For a desktop window, build the frontend, install `requirements-desktop.txt`, then run `python desktop_app.py` from `Tools/transcription-mvp`.

## Migration inventory

| Existing capability | Shared destination | Status |
| --- | --- | --- |
| ONNX Whisper, live/final captions, local repair ledger | Python runtime | Integrated in MVP |
| Qwen streaming translation, cache and usage counters | Python runtime | Integrated in MVP; key configured locally |
| Courses, history, session search and export | Shared UI + Python session store | UI structure started; migration pending |
| Voiceprint diarization, speaker aliases, teacher/student MiniLM | Python runtime adapters + shared UI | Existing Python experiment modules; production integration pending |
| Accent/language detection and correction | Python runtime adapters | Migration pending |
| Subtitle overlay and click-through controls | shared window layer | Migration pending on Windows/macOS |
| Apple-only Translation/CoreML/Speech functions | portable provider interfaces with platform adapters | Migration pending; retain Apple provider on macOS where useful |

## Architecture boundary

The React interface and Python domain/runtime are shared. Microphone APIs, OS permission prompts, floating/always-on-top windows, notifications and packaging need small platform adapters. Model/data formats and session exports should stay platform-neutral. Existing Swift files and tests remain the behavioral reference until each capability has a Python implementation and regression coverage.
