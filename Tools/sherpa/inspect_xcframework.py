#!/usr/bin/env python3
r"""Unzip + inspect the downloaded macOS xcframeworks: slices, modulemap,
whether onnxruntime symbols are bundled, exported symbols sample."""
import io
import os
import re
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
D = os.path.join(HERE, "models", "_macos_check")


def walk(zipname):
    z = zipfile.ZipFile(os.path.join(D, zipname))
    names = z.namelist()
    print(f"=== {zipname}: {os.path.getsize(os.path.join(D, zipname)):,} bytes, "
          f"{len(names)} entries")
    total = sum(i.file_size for i in z.infolist())
    print(f"    uncompressed total: {total:,} bytes")
    for n in sorted(names):
        i = z.getinfo(n)
        print(f"    {n}  {i.file_size:,}")
    # modulemap / Info.plist
    for n in names:
        if n.endswith("module.modulemap") or n.endswith("Info.plist"):
            print(f"--- {n} ---")
            print(z.read(n).decode("utf-8", "replace")[:1500])
    # search static libs for onnxruntime symbols
    for n in names:
        if n.endswith((".a", ".dylib")):
            data = z.read(n)
            probes = [b"OrtGetApiBase", b"onnxruntime", b"OrtApi", b"SessionOptions"]
            found = [p.decode() for p in probes if p in data]
            # sherpa symbols
            sherpa = len(re.findall(b"SherpaOnnxCreateOnlineRecognizer", data))
            print(f"    {n}: size={len(data):,} ort-probes={found} "
                  f"sherpa-CreateOnlineRecognizer-hits={sherpa}")
    print()


for f in sorted(os.listdir(D)):
    if f.endswith(".zip"):
        walk(f)
