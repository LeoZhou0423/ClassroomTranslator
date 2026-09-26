#!/usr/bin/env python3
r"""sherpa-onnx ASR demo on Windows: full-file decode + chunked streaming decode.

Reports model load time, inference wall time, RTF, time-to-first-partial,
per-chunk decode cost, and WER against reference transcripts (EN test set).

Usage:
  python asr_demo.py --model en
  python asr_demo.py --model zh
  python asr_demo.py --model en --wav D:\path\to\file.wav
  python asr_demo.py --model en --chunk 0.32 --threads 2
"""
import argparse
import contextlib
import glob
import os
import platform
import sys
import time
import wave

import numpy as np
import sherpa_onnx

ROOT = os.path.dirname(os.path.abspath(__file__))
MODELS = {
    "en": {
        "dir": os.path.join(ROOT, "models", "sherpa-onnx-streaming-zipformer-en-2023-06-26"),
        "encoder": "encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx",
        "decoder": "decoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx",
        "joiner": "joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx",
    },
    "zh": {
        "dir": os.path.join(ROOT, "models", "sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20"),
        "encoder": "encoder-epoch-99-avg-1.int8.onnx",
        "decoder": "decoder-epoch-99-avg-1.int8.onnx",
        "joiner": "joiner-epoch-99-avg-1.int8.onnx",
    },
}


def load_wav(path):
    with contextlib.closing(wave.open(path, "rb")) as w:
        assert w.getsampwidth() == 2, "only 16-bit wav supported"
        sr = w.getframerate()
        raw = w.readframes(w.getnframes())
        ch = w.getnchannels()
    x = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    if ch > 1:
        x = x.reshape(-1, ch).mean(axis=1)
    return x, sr


def norm_text(s):
    out = []
    for ch in s.lower():
        out.append(ch if ch.isalnum() else " ")
    return " ".join("".join(out).split())


def wer(ref, hyp):
    r = norm_text(ref).split()
    h = norm_text(hyp).split()
    if not r:
        return 1.0 if h else 0.0
    prev = list(range(len(h) + 1))
    for i, rw in enumerate(r, 1):
        cur = [i]
        for j, hw in enumerate(h, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (rw != hw)))
        prev = cur
    return prev[-1] / len(r)


def build_recognizer(key, threads, endpoint):
    m = MODELS[key]
    d = m["dir"]
    t0 = time.perf_counter()
    rec = sherpa_onnx.OnlineRecognizer.from_transducer(
        tokens=os.path.join(d, "tokens.txt"),
        encoder=os.path.join(d, m["encoder"]),
        decoder=os.path.join(d, m["decoder"]),
        joiner=os.path.join(d, m["joiner"]),
        num_threads=threads,
        sample_rate=16000,
        feature_dim=80,
        decoding_method="greedy_search",
        enable_endpoint_detection=endpoint,
        rule1_min_trailing_silence=2.4,
        rule2_min_trailing_silence=1.2,
        rule3_min_utterance_length=20.0,
        provider="cpu",
    )
    load_s = time.perf_counter() - t0
    size = sum(os.path.getsize(os.path.join(d, n)) for n in
               (m["encoder"], m["decoder"], m["joiner"], "tokens.txt"))
    return rec, load_s, size


def decode_full(rec, samples, sr, repeats=3):
    """Feed the whole waveform at once, then drain. Returns (text, seconds list)."""
    times = []
    text = ""
    for k in range(repeats):
        stream = rec.create_stream()
        stream.accept_waveform(sr, samples)
        stream.input_finished()
        t0 = time.perf_counter()
        while rec.is_ready(stream):
            rec.decode_stream(stream)
        dt = time.perf_counter() - t0
        times.append(dt)
        text = rec.get_result(stream)
    return text, times


def decode_streaming(rec, samples, sr, chunk_sec):
    """Feed fixed-size chunks as if they arrived in real time."""
    n = int(round(chunk_sec * sr))
    stream = rec.create_stream()
    chunks = [samples[i:i + n] for i in range(0, len(samples), n)]
    t_start = time.perf_counter()
    first_partial = None
    audio_at_first_partial = None
    audio_fed = 0.0
    per_chunk = []
    partials = 0
    last_text = ""
    for c in chunks:
        stream.accept_waveform(sr, c)
        audio_fed += len(c) / sr
        t0 = time.perf_counter()
        while rec.is_ready(stream):
            rec.decode_stream(stream)
        dt = time.perf_counter() - t0
        per_chunk.append(dt)
        txt = rec.get_result(stream)
        if txt and txt != last_text:
            partials += 1
            last_text = txt
            if first_partial is None:
                first_partial = time.perf_counter() - t_start
                audio_at_first_partial = audio_fed
    stream.input_finished()
    t0 = time.perf_counter()
    while rec.is_ready(stream):
        rec.decode_stream(stream)
    tail = time.perf_counter() - t0
    final = rec.get_result(stream)
    wall = time.perf_counter() - t_start
    return {
        "text": final,
        "n_chunks": len(chunks),
        "first_partial_s": first_partial,
        "audio_at_first_partial_s": audio_at_first_partial,
        "partials": partials,
        "decode_total_s": sum(per_chunk) + tail,
        "chunk_avg_ms": 1000 * sum(per_chunk) / len(per_chunk),
        "chunk_max_ms": 1000 * max(per_chunk),
        "wall_s": wall,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", choices=["en", "zh"], required=True)
    ap.add_argument("--wav", action="append", default=[])
    ap.add_argument("--chunk", type=float, default=0.32, help="streaming chunk seconds")
    ap.add_argument("--threads", type=int, default=2)
    ap.add_argument("--repeats", type=int, default=3)
    args = ap.parse_args()

    proj = os.path.dirname(os.path.dirname(ROOT))
    wavs = list(args.wav)
    if not wavs:
        if args.model == "en":
            d = os.path.join(MODELS["en"]["dir"], "test_wavs")
            wavs = [os.path.join(d, "0.wav"), os.path.join(d, "1.wav")]
            wavs += sorted(glob.glob(os.path.join(
                proj, "Tools", "accent", "models",
                "accent-id-commonaccent_ecapa", "data", "*.wav")))
        else:
            m = os.path.join(proj, "Tools", "speaker", "models")
            wavs = [os.path.join(m, "0-four-speakers-zh.wav"),
                    os.path.join(m, "fangjun-sr-1.wav"),
                    os.path.join(m, "fangjun-sr-2.wav"),
                    os.path.join(m, "leijun-sr-1.wav")]

    refs = {}
    trans = os.path.join(MODELS["en"]["dir"], "test_wavs", "trans.txt")
    if os.path.exists(trans):
        for line in open(trans, encoding="utf-8"):
            if line.strip():
                k, v = line.split(maxsplit=1)
                refs[k] = v.strip()

    print(f"== env: python {platform.python_version()} | sherpa-onnx "
          f"{getattr(sherpa_onnx, '__version__', '?')} | {platform.platform()}")
    print(f"== model={args.model} threads={args.threads} chunk={args.chunk}s")
    rec, load_s, msize = build_recognizer(args.model, args.threads, endpoint=False)
    print(f"== model load: {load_s:.3f}s, core model size: {msize/1e6:.1f} MB")

    # warm-up (JIT/session init is folded into the first decode)
    warm = os.path.join(MODELS[args.model]["dir"], "test_wavs", "0.wav")
    if os.path.exists(warm):
        x, sr = load_wav(warm)
        decode_full(rec, x, sr, repeats=1)
        print("== warm-up done")

    total_decode = 0.0
    total_audio = 0.0
    for p in wavs:
        x, sr = load_wav(p)
        dur = len(x) / sr
        text, times = decode_full(rec, x, sr, repeats=args.repeats)
        best = min(times)
        avg = sum(times) / len(times)
        total_decode += best
        total_audio += dur
        name = os.path.relpath(p, proj)
        print(f"\n-- {name}")
        print(f"   audio {dur:.2f}s | full-decode warm {best*1000:.0f}ms "
              f"(avg {avg*1000:.0f}ms of {args.repeats}) | RTF {best/dur:.4f} | "
              f"cold {times[0]*1000:.0f}ms")
        print(f"   TEXT: {text}")
        base = os.path.basename(p)
        if base in refs:
            w = wer(refs[base], text)
            print(f"   WER vs reference: {w*100:.1f}%  (ref: {refs[base]})")

        st = decode_streaming(rec, x, sr, args.chunk)
        print(f"   STREAM[{args.chunk}s chunk]: chunks={st['n_chunks']} "
              f"first-partial-wall={st['first_partial_s']*1000:.0f}ms "
              f"first-partial-after-audio={st['audio_at_first_partial_s']:.2f}s "
              f"partials={st['partials']} decode-sum={st['decode_total_s']*1000:.0f}ms "
              f"chunk-avg={st['chunk_avg_ms']:.1f}ms chunk-max={st['chunk_max_ms']:.1f}ms "
              f"stream-RTF={st['decode_total_s']/dur:.4f}")
        if base in refs:
            print(f"   STREAM WER: {wer(refs[base], st['text'])*100:.1f}%")
        print(f"   STREAM TEXT: {st['text']}")

    print(f"\n== aggregate warm full-decode: audio {total_audio:.2f}s, "
          f"decode {total_decode*1000:.0f}ms, RTF {total_decode/total_audio:.4f}")


if __name__ == "__main__":
    main()