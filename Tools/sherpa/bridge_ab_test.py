#!/usr/bin/env python3
"""A/B: does the mic-bridge filter chain (pan+volume=3.0+alimiter) hurt ASR?"""
import sys, os, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asr_demo import load_wav, wer, build_recognizer, decode_full, MODELS

REFS = {
    "0": "AFTER EARLY NIGHTFALL THE YELLOW LAMPS WOULD LIGHT UP HERE AND THERE THE SQUALID QUARTER OF THE BROTHELS",
    "1": "GOD AS A DIRECT CONSEQUENCE OF THE SIN WHICH MAN THUS PUNISHED HAD GIVEN HER A LOVELY CHILD WHOSE PLACE WAS ON THAT SAME DISHONOURED BOSOM TO CONNECT HER PARENT FOR EVER WITH THE RACE AND DESCENT OF MORTALS AND TO BE FINALLY A BLESSED SOUL IN HEAVEN",
}
AB = r"D:\Project\ClassroomTranslator\Build\asr-ab"
VARIANTS = ["resample", "gain-only", "bridge"]

rec, load_s, _ = build_recognizer("en", threads=2, endpoint=False)
print(f"model load {load_s:.2f}s")

print(f"{'file':<10}{'variant':<12}{'WER%':>7}  text")
for n in ("0", "1"):
    for v in VARIANTS:
        p = os.path.join(AB, f"{n}-{v}-16k.wav")
        x, sr = load_wav(p)
        text, _ = decode_full(rec, x, sr, repeats=1)
        w = wer(REFS[n], text) * 100
        print(f"{n:<10}{v:<12}{w:7.1f}  {text[:110]}")
