#!/usr/bin/env python3
"""Print wav metadata + downloaded model inventory (diagnostic helper)."""
import contextlib
import glob
import os
import wave

ROOT = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(os.path.dirname(ROOT))

paths = [
    os.path.join(PROJ, "Tools", "speaker", "models", "0-four-speakers-zh.wav"),
    os.path.join(PROJ, "Tools", "speaker", "models", "fangjun-sr-1.wav"),
    os.path.join(PROJ, "Tools", "speaker", "models", "fangjun-sr-2.wav"),
    os.path.join(PROJ, "Tools", "speaker", "models", "leijun-sr-1.wav"),
]
paths += sorted(glob.glob(os.path.join(PROJ, "Tools", "accent", "models",
                                        "accent-id-commonaccent_ecapa", "data", "*.wav")))
paths += sorted(glob.glob(os.path.join(ROOT, "models", "**", "*.wav"), recursive=True))

for p in paths:
    try:
        with contextlib.closing(wave.open(p, "rb")) as w:
            sr, n, ch, sw = w.getframerate(), w.getnframes(), w.getnchannels(), w.getsampwidth()
        rel = os.path.relpath(p, PROJ)
        print(f"{n / sr:7.2f}s  {sr}Hz ch={ch} sw={sw}  {rel}")
    except Exception as e:
        print("ERR", p, e)

print("--- model inventory ---")
for d in sorted(glob.glob(os.path.join(ROOT, "models", "*"))):
    if not os.path.isdir(d):
        continue
    tot = sum(os.path.getsize(f) for f in glob.glob(d + "/**", recursive=True)
              if os.path.isfile(f))
    print(f"{os.path.basename(d)}: {tot:,} bytes")
    for f in sorted(glob.glob(d + "/**", recursive=True)):
        if os.path.isfile(f):
            print("   ", os.path.relpath(f, d), f"{os.path.getsize(f):,}")

en = os.path.join(ROOT, "models", "sherpa-onnx-streaming-zipformer-en-2023-06-26")
for name in ("test_wavs/trans.txt", "README.md"):
    p = os.path.join(en, name)
    if os.path.exists(p):
        print(f"--- {name} ---")
        print(open(p, encoding="utf-8").read())
