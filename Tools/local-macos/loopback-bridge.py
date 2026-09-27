#!/usr/bin/env python3
"""Windows system-output (WASAPI loopback) → macOS VM mic.

Captures what the PC is *playing* (not the microphone) and streams PCM
s16le mono 48 kHz into the container PulseAudio `mic_sink` (same path as
mic-bridge.ps1). Use this to feed video/audio playback into the VM as if
it were a classroom microphone.

  python Tools/local-macos/loopback-bridge.py
  python Tools/local-macos/loopback-bridge.py --device "扬声器 (Realtek(R) Audio)"
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import time

import numpy as np

RATE = 48000
CHANNELS = 1
BLOCK = 1024


def find_loopback(name: str | None):
    import soundcard as sc

    mics = sc.all_microphones(include_loopback=True)
    if name:
        for m in mics:
            if name.lower() in m.name.lower():
                return m
        raise SystemExit("loopback device not found: " + name + "\n" + "\n".join(m.name for m in mics))
    speaker = sc.default_speaker()
    for m in mics:
        if m.name == speaker.name:
            return m
    # any loopback
    for m in mics:
        if m.is_loopback if hasattr(m, "is_loopback") else True:
            return m
    raise SystemExit("no WASAPI loopback device")


def stream_to_container(container: str, gain: float) -> int:
    import soundcard as sc

    mic = find_loopback(None)
    print(f"loopback device: {mic.name}", flush=True)
    print(f"streaming system audio -> docker exec {container} pacat mic_sink", flush=True)

    cmd = [
        "docker", "exec", "-i", container,
        "pacat", "--server=unix:/run/pulse/native",
        "--playback", "--device=mic_sink",
        "--raw", "--format=s16le", f"--rate={RATE}", f"--channels={CHANNELS}",
    ]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    assert proc.stdin is not None

    try:
        with mic.recorder(samplerate=RATE, channels=2) as rec:
            while True:
                data = rec.record(numframes=BLOCK)  # float32 [frames, ch]
                mono = data.mean(axis=1) if data.ndim > 1 else data
                mono = np.clip(mono * gain, -1.0, 1.0)
                pcm = (mono * 32767.0).astype("<i2").tobytes()
                try:
                    proc.stdin.write(pcm)
                    proc.stdin.flush()
                except BrokenPipeError:
                    print("pacat pipe closed; restarting", flush=True)
                    try:
                        proc.kill()
                    except Exception:
                        pass
                    time.sleep(1)
                    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
                    assert proc.stdin is not None
    except KeyboardInterrupt:
        pass
    finally:
        try:
            proc.stdin.close()
            proc.wait(timeout=2)
        except Exception:
            proc.kill()
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default=None, help="loopback device name substring")
    ap.add_argument("--gain", type=float, default=1.5, help="linear gain for quiet system mix")
    ap.add_argument("--container", default="classroomtranslator-macos")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    if args.list:
        import soundcard as sc

        for m in sc.all_microphones(include_loopback=True):
            print(m.name)
        return 0

    # device override via env for find_loopback
    if args.device:
        import soundcard as sc

        mics = sc.all_microphones(include_loopback=True)
        chosen = next((m for m in mics if args.device.lower() in m.name.lower()), None)
        if not chosen:
            print("not found", file=sys.stderr)
            return 2
        # monkey-patch default for this run
        global find_loopback
        find_loopback = lambda name=None: chosen  # type: ignore

    return stream_to_container(args.container, args.gain)


if __name__ == "__main__":
    raise SystemExit(main())
