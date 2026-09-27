#!/bin/bash
set -e
export PATH=/root/miniconda3/bin:$PATH
python - <<'PY'
from pathlib import Path
import torch
from safetensors.torch import save_file

src = Path("/root/autodl-tmp/minilm/pytorch_model.bin")
dst = Path("/root/autodl-tmp/minilm/model.safetensors")
print("loading", src, src.stat().st_size)
state = torch.load(src, map_location="cpu", weights_only=True)
print("keys", len(state))
save_file(state, str(dst))
print("saved", dst, dst.stat().st_size)
PY
ls -lh /root/autodl-tmp/minilm/model.safetensors
