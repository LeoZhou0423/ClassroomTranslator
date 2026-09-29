from __future__ import annotations

import time
import wave
from pathlib import Path

import numpy as np
import sherpa_onnx

from transcription_core import acceptable, clean

ROOT = Path(__file__).resolve().parent
MODEL = ROOT / "models" / "whisper-tiny"
SAMPLE = ROOT.parent / "sherpa" / "models" / "sherpa-onnx-streaming-zipformer-en-2023-06-26" / "test_wavs" / "0.wav"
RATE = 16_000


def read_wav(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as source:
        assert source.getnchannels() == 1
        assert source.getsampwidth() == 2
        assert source.getframerate() == RATE
        return np.frombuffer(source.readframes(source.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0


def main() -> None:
    if not SAMPLE.is_file():
        raise SystemExit(f"缺少测试音频：{SAMPLE}")
    samples = read_wav(SAMPLE)

    recognizer = sherpa_onnx.OfflineRecognizer.from_whisper(
        encoder=str(MODEL / "tiny-encoder.int8.onnx"),
        decoder=str(MODEL / "tiny-decoder.int8.onnx"),
        tokens=str(MODEL / "tiny-tokens.txt"),
        language="", task="transcribe", num_threads=2,
    )
    stream = recognizer.create_stream()
    stream.accept_waveform(RATE, samples)
    started = time.perf_counter()
    recognizer.decode_stream(stream)
    text = clean(stream.result.text)
    elapsed = time.perf_counter() - started
    assert acceptable(text), f"Whisper 输出未通过质量门：{text!r}"

    config = sherpa_onnx.VadModelConfig()
    config.silero_vad.model = str(MODEL / "silero_vad.int8.onnx")
    config.silero_vad.threshold = 0.25
    config.silero_vad.min_silence_duration = 0.7
    config.silero_vad.min_speech_duration = 0.25
    config.sample_rate = RATE
    vad = sherpa_onnx.VoiceActivityDetector(config, buffer_size_in_seconds=30)
    padded = np.concatenate((np.zeros(RATE, np.float32), samples, np.zeros(RATE, np.float32)))
    for start in range(0, len(padded), 512):
        vad.accept_waveform(padded[start : start + 512])
    vad.flush()
    segments = []
    while not vad.empty():
        segments.append(len(vad.front.samples) / RATE)
        vad.pop()
    assert segments, "Silero VAD 没有检测到语音段"

    print(f"Whisper: {text}")
    print(f"Decode: {elapsed:.2f}s for {len(samples) / RATE:.2f}s audio")
    print(f"VAD segments: {segments}")


if __name__ == "__main__":
    main()
