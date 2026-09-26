#!/usr/bin/env python3
r"""Download the macOS static xcframework via api.github.com (github.com is blocked).

The asset URL is fetched with Accept: application/octet-stream so api.github.com
redirects to the CDN. Result: models/_macos_check/<name>
"""
import os
import sys
import urllib.request

ASSETS = {
    # name -> api asset url (from releases/tags/xcframework, v1.13.8)
    "sherpa-onnx-v1.13.8-macos-static.xcframework.zip":
        "https://api.github.com/repos/k2-fsa/sherpa-onnx/releases/assets/554819423",
    "sherpa-onnx-v1.13.8-macos-shared.xcframework.zip":
        "https://api.github.com/repos/k2-fsa/sherpa-onnx/releases/assets/554819465",
}

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "models", "_macos_check")


def main():
    os.makedirs(OUT, exist_ok=True)
    only = sys.argv[1] if len(sys.argv) > 1 else None
    for name, url in ASSETS.items():
        if only and only not in name:
            continue
        dest = os.path.join(OUT, name)
        if os.path.exists(dest) and os.path.getsize(dest) > 0:
            print("[skip]", dest, os.path.getsize(dest))
            continue
        req = urllib.request.Request(url, headers={
            "User-Agent": "Mozilla/5.0",
            "Accept": "application/octet-stream",
        })
        with urllib.request.urlopen(req, timeout=180) as r, open(dest + ".part", "wb") as f:
            while True:
                c = r.read(1 << 20)
                if not c:
                    break
                f.write(c)
        os.replace(dest + ".part", dest)
        print("[ok]", dest, os.path.getsize(dest))


if __name__ == "__main__":
    main()
