#!/usr/bin/env python3
"""Download sherpa-onnx ASR models from hf-mirror (github/hf direct blocked in this env).

Usage: python download_models.py [--only en|zh]
Files land in ./models/<model-dir>/
"""
import os
import sys
import urllib.request

BASE = os.path.dirname(os.path.abspath(__file__))
HF = "https://hf-mirror.com/{repo}/resolve/main/{path}"

MODELS = {
    "en": {
        "repo": "csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26",
        "dir": "sherpa-onnx-streaming-zipformer-en-2023-06-26",
        "files": [
            "encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx",
            "decoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx",
            "joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx",
            "bpe.model",
            "tokens.txt",
            "README.md",
            "test_wavs/0.wav",
            "test_wavs/1.wav",
            "test_wavs/trans.txt",
        ],
    },
    "zh": {
        "repo": "csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20",
        "dir": "sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20",
        "files": [
            "encoder-epoch-99-avg-1.int8.onnx",
            "decoder-epoch-99-avg-1.int8.onnx",
            "joiner-epoch-99-avg-1.int8.onnx",
            "bpe.model",
            "tokens.txt",
            "README.md",
        ],
    },
}


def fetch(url: str, dest: str) -> None:
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        print(f"[skip] {dest} ({os.path.getsize(dest):,} bytes)", flush=True)
        return
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    tmp = dest + ".part"
    with urllib.request.urlopen(req, timeout=120) as r, open(tmp, "wb") as f:
        total = int(r.headers.get("Content-Length") or 0)
        done = 0
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
            done += len(chunk)
            print(f"  {os.path.basename(dest)}: {done:,}/{total:,}", end="\r", flush=True)
    os.replace(tmp, dest)
    print(f"[ok]   {dest} ({os.path.getsize(dest):,} bytes)", flush=True)


def main() -> None:
    only = None
    if "--only" in sys.argv:
        only = sys.argv[sys.argv.index("--only") + 1]
    for key, m in MODELS.items():
        if only and key != only:
            continue
        for path in m["files"]:
            fetch(HF.format(repo=m["repo"], path=path),
                  os.path.join(BASE, "models", m["dir"], path))
    print("DONE", flush=True)


if __name__ == "__main__":
    main()
