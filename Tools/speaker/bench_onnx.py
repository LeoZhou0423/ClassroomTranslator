#!/usr/bin/env python3
"""Benchmark CPU inference cost of speaker diarization ONNX models (Windows host).

- silero_vad.onnx : raw-audio stateful VAD, 16 kHz, 512-sample chunks.
- campplus_zh_en_advanced.onnx : speaker embedding, input fbank features [N, T, 80].
"""
from __future__ import annotations

import time
import wave
from pathlib import Path

import numpy as np

BASE = Path(__file__).parent / "models"


def read_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as w:
        sr = w.getframerate()
        ch = w.getnchannels()
        sw = w.getsampwidth()
        n = w.getnframes()
        raw = w.readframes(n)
    if sw == 2:
        data = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    else:
        raise ValueError(f"unsupported sampwidth {sw}")
    if ch > 1:
        data = data.reshape(-1, ch).mean(axis=1)
    return data, sr


def stats(xs: list[float]) -> str:
    a = np.asarray(xs)
    return f"mean={a.mean()*1000:.1f}ms median={np.median(a)*1000:.1f}ms min={a.min()*1000:.1f}ms max={a.max()*1000:.1f}ms"


def bench_vad() -> None:
    import onnxruntime as ort

    path = BASE / "silero_vad.onnx"
    sess = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
    print("[silero_vad] inputs:", [(i.name, i.shape) for i in sess.get_inputs()])
    wav, sr = read_wav(BASE / "0-four-speakers-zh.wav")
    print(f"[silero_vad] test wav: {BASE/'0-four-speakers-zh.wav'} sr={sr} dur={len(wav)/sr:.2f}s")
    chunk = 512
    h = np.zeros((2, 1, 64), dtype=np.float32)
    c = np.zeros((2, 1, 64), dtype=np.float32)
    # warmup
    x = np.zeros((1, chunk), dtype=np.float32)
    for _ in range(5):
        sess.run(None, {"x": x, "h": h, "c": c})
    lat = []
    speech = 0
    n_chunks = len(wav) // chunk
    t0 = time.perf_counter()
    for i in range(n_chunks):
        x = wav[i * chunk:(i + 1) * chunk].astype(np.float32).reshape(1, -1)
        t = time.perf_counter()
        prob, h, c = sess.run(None, {"x": x, "h": h, "c": c})
        lat.append(time.perf_counter() - t)
        if float(prob) > 0.5:
            speech += 1
    total = time.perf_counter() - t0
    audio_dur = n_chunks * chunk / sr
    print(f"[silero_vad] chunks={n_chunks} speech_chunks={speech} {stats(lat)}")
    print(f"[silero_vad] wall={total:.3f}s for {audio_dur:.2f}s audio -> RTF={total/audio_dur:.4f}")


def bench_embed() -> None:
    import onnxruntime as ort

    path = BASE / "campplus_zh_en_advanced.onnx"
    so = ort.SessionOptions()
    so.intra_op_num_threads = 1  # emulate single-thread mobile-ish CPU
    sess = ort.InferenceSession(str(path), sess_options=so, providers=["CPUExecutionProvider"])
    print("[campplus] inputs:", [(i.name, i.shape) for i in sess.get_inputs()])
    print("[campplus] outputs:", [(o.name, o.shape) for o in sess.get_outputs()])
    rng = np.random.default_rng(0)
    for seconds in (1.0, 2.0, 4.0, 12.0):
        frames = int(seconds * 100)  # 10ms hop
        x = rng.standard_normal((1, frames, 80), dtype=np.float32) * 0.1
        for _ in range(3):
            sess.run(None, {"x": x})
        lat = []
        for _ in range(10):
            t = time.perf_counter()
            out = sess.run(None, {"x": x})
            lat.append(time.perf_counter() - t)
        emb = out[0]
        print(f"[campplus] win={seconds:.0f}s frames={frames} {stats(lat)} out_shape={emb.shape}")


if __name__ == "__main__":
    bench_vad()
    bench_embed()
