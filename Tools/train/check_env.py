#!/usr/bin/env python3
"""Check / prepare training env on the 4090D box."""
from __future__ import annotations

import os
import subprocess
import sys

PY = "/root/miniconda3/bin/python"


def sh(cmd: str) -> None:
    print(f"\n$ {cmd}", flush=True)
    r = subprocess.run(cmd, shell=True, executable="/bin/bash")
    if r.returncode != 0:
        print(f"[warn] exit={r.returncode}", flush=True)


def main() -> int:
    sh("export PATH=/root/miniconda3/bin:$PATH")
    sh(f"{PY} --version")
    sh(f"{PY} -c 'import torch; print(\"torch\", torch.__version__, \"cuda\", torch.cuda.is_available(), torch.cuda.get_device_name(0))'")
    sh(f"{PY} -c 'import transformers; print(\"transformers\", transformers.__version__)'")
    sh(f"{PY} -c 'import datasets; print(\"datasets\", datasets.__version__)'")
    sh(f"{PY} -c 'import sklearn; print(\"sklearn\", sklearn.__version__)'")
    sh("nvidia-smi -L")
    sh("df -h /root/autodl-tmp /root")
    sh("ls -la /root/autodl-tmp")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
