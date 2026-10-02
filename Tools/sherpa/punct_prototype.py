#!/usr/bin/env python3
"""Prototype: sherpa-onnx punctuation restoration on fragmented ASR output.

Feeds real classroom fragments (Kagan, PHIL 176 Death) through the
CT-Transformer punctuation model, then re-splits into sentence units the way
the app's StableSentenceUnits would (on .!? boundaries).

Usage: python punct_prototype.py
"""
import os
import time

import sherpa_onnx

MODEL = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     "models", "punct-zh-en-2024-04-12", "model.onnx")

# Real fragments as produced by the streaming ASR path: no sentence marks,
# broken clause boundaries, trailing dashes.
SAMPLES = [
    "My name is Shelly Kagan and the very first thing I want to do is to "
    "invite you to call me Shelly",
    "That is you know if we meet on the street you come talking to me during "
    "office hours you ask some question",
    "Shelly's the name that I respond to I will eventually respond to "
    "Professor Kagan, but the synapses take a bit longer for that It's not "
    "the name I immediately-- recognized",
    "The African blogosphere is rapidly expanding bringing more voices online "
    "in the form of commentaries opinions analyses rants and poetry",
    "Now the question we're going to be asking is what happens when we die "
    "Is there life after death",
]


def split_units(text: str) -> list[str]:
    """Mirror of the app's StableSentenceUnits.split (period guard simplified)."""
    units, start = [], 0
    for i, ch in enumerate(text):
        if ch in ".!?":
            unit = text[start:i + 1].strip()
            if unit:
                units.append(unit)
            start = i + 1
    if start < len(text) and text[start:].strip():
        units.append(text[start:].strip())
    return units


def main() -> None:
    config = sherpa_onnx.OfflinePunctuationConfig(
        model=sherpa_onnx.OfflinePunctuationModelConfig(
            ct_transformer=MODEL,
            num_threads=2,
            debug=False,
            provider="cpu",
        ),
    )
    punct = sherpa_onnx.OfflinePunctuation(config)

    print("model:", MODEL, f"({os.path.getsize(MODEL):,} bytes)")
    for sample in SAMPLES:
        t0 = time.perf_counter()
        out = punct.add_punctuation(sample)
        dt = (time.perf_counter() - t0) * 1000
        print(f"\n--- raw ({len(sample)} chars, {dt:.0f} ms)")
        print("IN :", sample)
        print("OUT:", out)
        print("units:")
        for unit in split_units(out):
            print("  *", unit)


if __name__ == "__main__":
    main()
