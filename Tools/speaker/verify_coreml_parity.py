#!/usr/bin/env python3
"""Mac-only end-to-end parity: converted CoreML model vs torch wrapper vs sherpa.

Report section 4.3 gate: cosine(embedding, sherpa reference) >= 0.98 on real
audio. On Windows/WSL the CoreML runtime is unavailable, so this script is
part of the SpeakerFeature.md Mac verification checklist:

  1. python3 verify_wave_wrapper.py            # torch wrapper vs sherpa (gate)
  2. python3 verify_coreml_parity.py           # CoreML runtime vs both (gate)

Requires: coremltools with working libcoremlpython (macOS), torch, numpy,
and optionally sherpa-onnx (skip with --no-sherpa to compare only against
the torch wrapper).
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).parent
MODELS = HERE / "models"
GATE = 0.98


def build_clips(sr: int) -> dict[str, np.ndarray]:
    from verify_wave_wrapper import read_wav

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
    return clips


def pad64k(wav: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    length = min(len(wav), 64000)
    buf = np.zeros((1, 64000), dtype=np.float32)
    buf[0, :length] = wav[:length]
    return buf, np.array([[float(length)]], dtype=np.float32)


def cos(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--mlpackage",
        type=Path,
        default=MODELS / "SpeakerCAMWaveZHEng.mlpackage",
        help="converted waveform-input model",
    )
    parser.add_argument("--no-sherpa", action="store_true", help="skip sherpa comparison")
    args = parser.parse_args()

    sys.path.insert(0, str(HERE))
    import coremltools as ct
    import torch  # noqa: F401
    from wave_wrapper import SpeakerWaveWrapper

    clips = build_clips(16000)

    print(f"loading {args.mlpackage} ...")
    loaded = ct.models.MLModel(str(args.mlpackage))
    wrapper = SpeakerWaveWrapper(MODELS / "campplus_cn_en_common.pt", masked=True).eval()

    extractor = None
    if not args.no_sherpa:
        import sherpa_onnx

        cfg = sherpa_onnx.SpeakerEmbeddingExtractorConfig(
            model=str(MODELS / "campplus_zh_en_advanced.onnx"), num_threads=1
        )
        extractor = sherpa_onnx.SpeakerEmbeddingExtractor(cfg)

    from verify_wave_wrapper import wrapper_embedding, sherpa_embedding

    worst_vs_torch = 1.0
    worst_vs_sherpa = 1.0
    print("== per-clip: CoreML runtime vs torch wrapper vs sherpa ==")
    for name, clip in clips.items():
        wave_np, len_np = pad64k(clip)
        out = loaded.predict({"waveform": wave_np, "numSamples": len_np})
        coreml_emb = np.asarray(out["embedding"], dtype=np.float32).reshape(-1)

        torch_emb = wrapper_embedding(wrapper, clip, 16000)
        c_torch = cos(coreml_emb, torch_emb)
        worst_vs_torch = min(worst_vs_torch, c_torch)
        line = f"  {name:26s} coreml-vs-torch={c_torch:.4f}"
        if extractor is not None:
            ref = sherpa_embedding(extractor, clip, 16000)
            c_ref = cos(coreml_emb, ref)
            worst_vs_sherpa = min(worst_vs_sherpa, c_ref)
            flag = "OK " if c_ref >= GATE else "LOW"
            line += f"  [{flag}] coreml-vs-sherpa={c_ref:.4f}"
        print(line)

    print(f"worst coreml-vs-torch: {worst_vs_torch:.4f}")
    ok = worst_vs_torch >= 0.99
    if extractor is not None:
        print(f"worst coreml-vs-sherpa: {worst_vs_sherpa:.4f} (gate {GATE})")
        ok = ok and worst_vs_sherpa >= GATE
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
