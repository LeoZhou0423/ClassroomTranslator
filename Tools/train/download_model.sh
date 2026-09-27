#!/bin/bash
set -e
export PATH=/root/miniconda3/bin:$PATH
export HF_HOME=/root/autodl-tmp/hf_cache
export HF_ENDPOINT=https://hf-mirror.com
python - <<'PY'
from huggingface_hub import snapshot_download
path = snapshot_download(
    "microsoft/MiniLM-L12-H384-uncased",
    local_dir="/root/autodl-tmp/minilm",
    local_dir_use_symlinks=False,
)
print("saved", path)
PY
ls -lh /root/autodl-tmp/minilm
