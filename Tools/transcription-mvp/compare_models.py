from __future__ import annotations

import argparse
import time
import wave
from pathlib import Path

import numpy as np
import sherpa_onnx

ROOT = Path(__file__).resolve().parent
RATE = 16_000


def read_wav(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as source:
        if source.getnchannels() != 1 or source.getsampwidth() != 2 or source.getframerate() != RATE:
            raise ValueError("测试 WAV 必须是 16 kHz、16-bit、单声道")
        return np.frombuffer(source.readframes(source.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0


def decode(model: str, samples: np.ndarray) -> tuple[str, float]:
    folder = ROOT / "models" / f"whisper-{model}"
    recognizer = sherpa_onnx.OfflineRecognizer.from_whisper(
        encoder=str(folder / f"{model}-encoder.int8.onnx"),
        decoder=str(folder / f"{model}-decoder.int8.onnx"),
        tokens=str(folder / f"{model}-tokens.txt"),
        language="en", task="transcribe", num_threads=4,
    )
    stream = recognizer.create_stream()
    stream.accept_waveform(RATE, samples)
    started = time.perf_counter()
    recognizer.decode_stream(stream)
    return stream.result.text.strip(), time.perf_counter() - started


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("wav", type=Path)
    args = parser.parse_args()
    samples = read_wav(args.wav)
    print(f"audio={len(samples) / RATE:.2f}s")
    for model in ("tiny", "small"):
        text, elapsed = decode(model, samples)
        print(f"{model}: {elapsed:.2f}s ({elapsed / (len(samples) / RATE):.3f}x realtime)\n  {text}")


if __name__ == "__main__":
    main()
