#!/usr/bin/env python3
"""Validate the full open-source diarization pipeline with sherpa-onnx Python API.

1) Embedding sanity: same-speaker vs different-speaker cosine similarity.
2) Full diarization on 0-four-speakers-zh.wav (pyannote segmentation + CAM++ + clustering).
3) Wall-clock cost per embedding (this host's CPU).
"""
from __future__ import annotations

import time
import wave
from pathlib import Path

import numpy as np

BASE = Path(__file__).parent
MODELS = BASE / "models"


def read_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as w:
        sr, ch, sw, n = w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes()
        raw = w.readframes(n)
    data = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    if ch > 1:
        data = data.reshape(-1, ch).mean(axis=1)
    assert sw == 2, sw
    return data, sr


def emb_of(extractor, wav: np.ndarray, sr: int) -> np.ndarray:
    s = extractor.create_stream()
    s.accept_waveform(sr, wav)
    return np.asarray(extractor.compute(s), dtype=np.float32)


def test_embeddings() -> None:
    import sherpa_onnx

    cfg = sherpa_onnx.SpeakerEmbeddingExtractorConfig(
        model=str(MODELS / "campplus_zh_en_advanced.onnx"), num_threads=1
    )
    extractor = sherpa_onnx.SpeakerEmbeddingExtractor(cfg)
    clips = {}
    for name in ["fangjun-sr-1.wav", "fangjun-sr-2.wav", "leijun-sr-1.wav"]:
        clips[name], sr = read_wav(MODELS / name)
    embs = {}
    for name, w in clips.items():
        t = time.perf_counter()
        embs[name] = emb_of(extractor, w, sr)
        dt = time.perf_counter() - t
        print(f"[emb] {name}: dur={len(w)/sr:.2f}s dim={embs[name].shape} infer={dt*1000:.0f}ms")

    def cos(a, b):
        return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b)))

    names = list(clips)
    print("[emb] cosine matrix:")
    for i in names:
        for j in names:
            if i < j:
                tag = "SAME " if i.split("-")[0] == j.split("-")[0] else "DIFF "
                print(f"  {tag}{i} vs {j}: {cos(embs[i], embs[j]):.4f}")


def test_full_diarization() -> None:
    import sherpa_onnx

    seg_model = MODELS / "sherpa-onnx-pyannote-segmentation-3-0" / "model.onnx"
    wav_path = MODELS / "0-four-speakers-zh.wav"
    wav, sr = read_wav(wav_path)
    seg_cfg = sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
        pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(model=str(seg_model))
    )
    emb_cfg = sherpa_onnx.SpeakerEmbeddingExtractorConfig(
        model=str(MODELS / "campplus_zh_en_advanced.onnx"), num_threads=1
    )
    clus_cfg = sherpa_onnx.FastClusteringConfig(num_clusters=4)
    cfg = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=seg_cfg, embedding=emb_cfg, clustering=clus_cfg
    )
    diar = sherpa_onnx.OfflineSpeakerDiarization(cfg)
    t0 = time.perf_counter()
    result = diar.process(wav.tolist())
    dt = time.perf_counter() - t0
    dur = len(wav) / sr
    print(f"[diar] sample_rate={diar.sample_rate} audio={dur:.2f}s wall={dt:.2f}s RTF={dt/dur:.4f}")
    segs = result.sort_by_start_time()
    print(f"[diar] segments={result.num_segments} speakers={result.num_speakers}")
    for seg in segs:
        print(f"  {seg.start:7.2f} -- {seg.end:7.2f}  speaker_{seg.speaker}")


if __name__ == "__main__":
    test_embeddings()
    test_full_diarization()
