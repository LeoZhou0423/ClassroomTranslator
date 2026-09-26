#!/usr/bin/env python3
"""Verify the waveform wrapper against the sherpa-onnx reference embedding.

Report SPEAKER-RESEARCH.md section 4.3 requires cosine(wrapper, sherpa) >=
0.98 on real audio before the wrapped model may ship. sherpa computes
variable-length fbank (kaldi-native-fbank) + CAM++ via ONNX; the wrapper
computes the same frontend in torch over a fixed 4 s window with
valid-frame masking.

Also reports:
  * naive (unmasked pad-to-4 s) cosine  -> the A/B baseline, i.e. what the
    report's original "zero pad to 400 frames" plan would have produced;
  * pairwise cosine margins (same vs different speaker) for wrapper vs
    reference, to confirm clustering thresholds (tau = 0.6) still separate.
"""
from __future__ import annotations

import sys
import wave
from pathlib import Path

import numpy as np

HERE = Path(__file__).parent
MODELS = HERE / "models"
GATE = 0.98


def read_wav(path: Path, start_s: float = 0.0, end_s: float | None = None) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as w:
        sr, ch, sw = w.getframerate(), w.getnchannels(), w.getsampwidth()
        n = w.getnframes()
        raw = w.readframes(n)
    data = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    if ch > 1:
        data = data.reshape(-1, ch).mean(axis=1)
    if end_s is not None or start_s > 0:
        a = int(start_s * sr)
        b = len(data) if end_s is None else min(len(data), int(end_s * sr))
        data = data[a:b]
    return data, sr


def sherpa_embedding(extractor, wav: np.ndarray, sr: int) -> np.ndarray:
    s = extractor.create_stream()
    s.accept_waveform(sr, wav)
    return np.asarray(extractor.compute(s), dtype=np.float32)


def wrapper_embedding(model, wav: np.ndarray, sr: int) -> np.ndarray:
    import torch

    assert sr == 16000, sr
    L = min(len(wav), 64000)
    buf = np.zeros(64000, dtype=np.float32)
    buf[:L] = wav[:L]
    wave_t = torch.from_numpy(buf).reshape(1, 64000)
    n_t = torch.tensor([[float(L)]], dtype=torch.float32)
    with torch.no_grad():
        out = model(wave_t, n_t)
    return out.reshape(-1).numpy()


def cos(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


def main() -> int:
    import sherpa_onnx
    import torch

    sys.path.insert(0, str(HERE))
    from wave_wrapper import SpeakerWaveWrapper

    checkpoint = MODELS / "campplus_cn_en_common.pt"
    masked = SpeakerWaveWrapper(checkpoint, masked=True).eval()
    naive = SpeakerWaveWrapper(checkpoint, masked=False).eval()

    cfg = sherpa_onnx.SpeakerEmbeddingExtractorConfig(
        model=str(MODELS / "campplus_zh_en_advanced.onnx"), num_threads=1
    )
    extractor = sherpa_onnx.SpeakerEmbeddingExtractor(cfg)

    clips: dict[str, np.ndarray] = {}
    fj1, sr = read_wav(MODELS / "fangjun-sr-1.wav")
    clips["fangjun-full(2.30s)"] = fj1
    clips["fangjun-short(1.20s)"] = fj1[: int(1.20 * sr)]
    fj2, _ = read_wav(MODELS / "fangjun-sr-2.wav", end_s=4.0)
    clips["fangjun-b(4.00s)"] = fj2
    lj1, _ = read_wav(MODELS / "leijun-sr-1.wav", end_s=4.0)
    clips["leijun(4.00s)"] = lj1
    four, _ = read_wav(MODELS / "0-four-speakers-zh.wav")
    clips["fourA-spk0(3.5s)"] = four[int(0.5 * sr) : int(4.0 * sr)]
    clips["fourA-spk0(1.5s)"] = four[int(0.5 * sr) : int(2.0 * sr)]
    clips["fourB-spk1(3.5s)"] = four[int(7.2 * sr) : int(10.7 * sr)]
    clips["fourC-spk2(3.0s)"] = four[int(14.0 * sr) : int(17.0 * sr)]

    refs, got_masked, got_naive = {}, {}, {}
    print("== per-clip cosine vs sherpa reference (gate >= 0.98) ==")
    worst = 1.0
    for name, clip in clips.items():
        refs[name] = sherpa_embedding(extractor, clip, sr)
        got_masked[name] = wrapper_embedding(masked, clip, sr)
        got_naive[name] = wrapper_embedding(naive, clip, sr)
        c_m = cos(got_masked[name], refs[name])
        c_n = cos(got_naive[name], refs[name])
        worst = min(worst, c_m)
        flag = "OK " if c_m >= GATE else "LOW"
        print(f"  [{flag}] {name:26s} masked={c_m:.4f}  naive={c_n:.4f}")

    print(f"worst masked cosine: {worst:.4f} (gate {GATE})")

    names = list(clips)

    def pair_report(title: str, table: dict[str, np.ndarray], same_ref: dict[str, str]) -> None:
        print(f"== {title} ==")
        same_vals, diff_vals = [], []
        for i, a in enumerate(names):
            for b in names[i + 1 :]:
                v = cos(table[a], table[b])
                same = same_ref[a] == same_ref[b]
                (same_vals if same else diff_vals).append(v)
        if same_vals:
            print(f"  SAME: min={min(same_vals):.4f} mean={sum(same_vals)/len(same_vals):.4f}")
        if diff_vals:
            print(f"  DIFF: max={max(diff_vals):.4f} mean={sum(diff_vals)/len(diff_vals):.4f}")

    same_ref = {
        "fangjun-full(2.30s)": "fangjun",
        "fangjun-short(1.20s)": "fangjun",
        "fangjun-b(4.00s)": "fangjun",
        "leijun(4.00s)": "leijun",
        "fourA-spk0(3.5s)": "spk0",
        "fourA-spk0(1.5s)": "spk0",
        "fourB-spk1(3.5s)": "spk1",
        "fourC-spk2(3.0s)": "spk2",
    }
    pair_report("reference (sherpa) margins", refs, same_ref)
    pair_report("wrapper masked margins", got_masked, same_ref)
    pair_report("wrapper naive margins", got_naive, same_ref)

    return 0 if worst >= GATE else 1


if __name__ == "__main__":
    sys.exit(main())
