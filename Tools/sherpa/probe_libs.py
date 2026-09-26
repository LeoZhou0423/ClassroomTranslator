#!/usr/bin/env python3
r"""Probe the framework binaries inside the downloaded xcframeworks:
file kind (static archive vs Mach-O dylib), sherpa symbols, onnxruntime symbols."""
import os
import re
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
D = os.path.join(HERE, "models", "_macos_check")

PROBES = [b"OrtGetApiBase", b"OrtApi", b"onnxruntime", b"OnnxRuntime",
          b"SessionOptionsAppendExecutionProvider", b"sherpa-onnx",
          b"SherpaOnnxCreateOnlineRecognizer", b"SherpaOnnxOfflineRecognizerCreate"]

for zn in sorted(os.listdir(D)):
    if not zn.endswith(".zip"):
        continue
    z = zipfile.ZipFile(os.path.join(D, zn))
    print("==", zn)
    for n in z.namelist():
        if n.endswith(("SherpaOnnxC",)) and not n.endswith("/"):
            info = z.getinfo(n)
            if info.file_size == 0:
                continue
            head = z.open(n).read(4)
            kind = "static-archive(!<arch>)" if head == b"!<arch" else (
                "mach-o dylib" if head[:4] in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe",
                                              b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xce",
                                              b"\xfe\xed\xfa\xcf") else repr(head))
            data = z.read(n)
            hits = [p.decode() for p in PROBES if p in data]
            print(f"   {n}")
            print(f"   size={len(data):,} kind={kind}")
            print(f"   probes found: {hits}")
            print(f"   SherpaOnnxCreateOnlineRecognizer count="
                  f"{len(re.findall(b'SherpaOnnxCreateOnlineRecognizer', data))}")
