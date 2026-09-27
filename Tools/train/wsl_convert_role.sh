#!/usr/bin/env bash
# Convert TalkMoves MiniLM role classifier -> CoreML under WSL (BlobWriter).
set -euo pipefail

UV="$HOME/.local/bin/uv"
VENV="$HOME/roleenv"
PYUV_INDEX="https://mirrors.aliyun.com/pypi/simple/"
CPU_FINDLINKS="https://mirrors.aliyun.com/pytorch-wheels/cpu/"
BASE="/mnt/d/Project/ClassroomTranslator/Tools/train"

if [ ! -x "$UV" ]; then
  mkdir -p "$HOME/.local/bin" "$HOME/uvtmp"
  cd "$HOME/uvtmp"
  curl -fL --retry 3 -o uv.tar.gz "https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-unknown-linux-gnu.tar.gz"
  tar xzf uv.tar.gz
  find . -name uv -type f -perm -u+x -exec cp {} "$UV" \;
  chmod +x "$UV"
fi

if [ ! -x "$VENV/bin/python" ]; then
  "$UV" venv --python 3.12 "$VENV"
fi

"$UV" pip install --python "$VENV/bin/python" --index-url "$PYUV_INDEX" \
  numpy coremltools transformers torch accelerate safetensors

# torch CPU wheel if needed
"$VENV/bin/python" - <<'PY'
import importlib.util, subprocess, sys
if importlib.util.find_spec("torch") is None:
    subprocess.check_call([
        sys.executable, "-m", "pip", "install", "torch",
        "--index-url", "https://mirrors.aliyun.com/pytorch-wheels/cpu/",
    ])
print("torch ok")
PY

cd "$BASE"
"$VENV/bin/python" convert_role_to_coreml.py \
  --src "$BASE/role-cls-final" \
  --out-mlpackage "/mnt/d/Project/ClassroomTranslator/ClassroomTranslator/Resources/RoleMiniLM.mlpackage" \
  --out-vocab "/mnt/d/Project/ClassroomTranslator/ClassroomTranslator/Resources/role_vocab.txt"

echo DONE
ls -la /mnt/d/Project/ClassroomTranslator/ClassroomTranslator/Resources/RoleMiniLM.mlpackage
