#!/usr/bin/env python3
r"""Latency probes for streaming ASR: chunk-size sweep + trailing-silence flush.

Usage: python latency_probe.py --model en
"""
import argparse
import os
import time

import numpy as np

import asr_demo as demo


def run(model, wavs, chunk, threads=2):
    rec, load_s, _ = demo.build_recognizer(model, threads, endpoint=False)
    out = []
    for p in wavs:
        x, sr = demo.load_wav(p)
        st = demo.decode_streaming(rec, x, sr, chunk)
        out.append((os.path.basename(p), len(x) / sr, st))
    return load_s, out


def silence_flush(model, wav, threads=2):
    rec, _, _ = demo.build_recognizer(model, threads, endpoint=False)
    x, sr = demo.load_wav(wav)
    x2 = np.concatenate([x, np.zeros(int(1.0 * sr), dtype=np.float32)])
    t = demo.decode_full(rec, x, sr, repeats=2)[0]
    t2 = demo.decode_full(rec, x2, sr, repeats=2)[0]
    return t, t2


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="en")
    ap.add_argument("--threads", type=int, default=2)
    args = ap.parse_args()
    root = os.path.dirname(os.path.abspath(__file__))
    proj = os.path.dirname(os.path.dirname(root))
    if args.model == "en":
        d = os.path.join(demo.MODELS["en"]["dir"], "test_wavs")
        wavs = [os.path.join(d, "0.wav"), os.path.join(d, "1.wav")]
        wavs.append(os.path.join(proj, "Tools", "accent", "models",
                                 "accent-id-commonaccent_ecapa", "data", "us_1.wav"))
    else:
        m = os.path.join(proj, "Tools", "speaker", "models")
        wavs = [os.path.join(m, "fangjun-sr-2.wav"), os.path.join(m, "leijun-sr-1.wav")]

    for chunk in (0.08, 0.16, 0.32, 0.64):
        load_s, res = run(args.model, wavs, chunk, args.threads)
        print(f"\n== chunk={chunk}s (load {load_s:.2f}s)")
        for name, dur, st in res:
            print(f"   {name}: first-partial-after-audio="
                  f"{st['audio_at_first_partial_s']:.2f}s "
                  f"first-partial-wall={st['first_partial_s']*1000:.0f}ms "
                  f"chunk-avg={st['chunk_avg_ms']:.1f}ms "
                  f"chunk-max={st['chunk_max_ms']:.1f}ms "
                  f"n_partials={st['partials']} "
                  f"stream-RTF={st['decode_total_s']/dur:.4f}")

    # trailing silence flush effect
    target = wavs[0]
    t, t2 = silence_flush(args.model, target, args.threads)
    print(f"\n== trailing-silence flush on {os.path.basename(target)}")
    print("   no-silence :", t)
    print("   +1.0s sil   :", t2)


if __name__ == "__main__":
    main()
