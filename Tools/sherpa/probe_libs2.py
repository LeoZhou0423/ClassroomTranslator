#!/usr/bin/env python3
r"""Deeper probe: file magic, dylib deps, whether onnxruntime code is present."""
import os
import re
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
D = os.path.join(HERE, "models", "_macos_check")

ORT_CODE = [b"SequentialExecutor", b"onnxruntime::", b"GraphViewer", b"SessionState"]
DYLIB_REF = [b"@rpath/", b"/usr/lib/libc++.1.dylib", b"libonnxruntime", b"@loader_path/"]

for zn in sorted(os.listdir(D)):
    if not zn.endswith(".zip"):
        continue
    z = zipfile.ZipFile(os.path.join(D, zn))
    print("==", zn)
    for n in z.namelist():
        if n.endswith("Versions/A/SherpaOnnxC"):
            data = z.read(n)
            print("   file:", n, f"{len(data):,} bytes")
            print("   magic:", data[:8].hex())
            print("   ORT code markers:", [p.decode() for p in ORT_CODE if p in data])
            print("   dylib refs:", [p.decode(errors="replace")
                                     for p in DYLIB_REF if p in data])
            deps = sorted(set(re.findall(rb"[/@][A-Za-z0-9_@.+-]+\.dylib", data)))
            print("   dylib paths:", [d.decode() for d in deps][:25])
