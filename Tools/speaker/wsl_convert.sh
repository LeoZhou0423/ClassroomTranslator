#!/usr/bin/env bash
# Run the CoreML conversion inside WSL Ubuntu.
#
# Why WSL: coremltools publishes no Windows wheels; built from sdist on Windows it
# lacks libmilstoragepython (BlobWriter), so mlprogram export fails with
# "RuntimeError: BlobWriter not loaded". The manylinux wheel ships BlobWriter,
# so we convert under WSL with a uv-provisioned CPython 3.12.
set -euo pipefail

UV="$HOME/.local/bin/uv"
VENV="$HOME/spenv"
PYUV_INDEX="https://mirrors.aliyun.com/pypi/simple/"
CPU_FINDLINKS="https://mirrors.aliyun.com/pytorch-wheels/cpu/"
BASE="/mnt/d/Project/ClassroomTranslator/Tools/speaker"

echo "== [1/5] provision uv =="
if [ ! -x "$UV" ]; then
  mkdir -p "$HOME/.local/bin" "$HOME/uvtmp"
  cd "$HOME/uvtmp"
  URL="https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-unknown-linux-gnu.tar.gz"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 -o uv.tar.gz "$URL"
  else
    wget -O uv.tar.gz "$URL"
  fi
  tar xzf uv.tar.gz
  find . -name uv -type f -perm -u+x -exec cp {} "$UV" \;
  chmod +x "$UV"
fi
"$UV" --version

echo "== [2/5] provision CPython 3.12 venv =="
if [ ! -x "$VENV/bin/python" ]; then
  "$UV" venv --python 3.12 "$VENV"
fi
"$VENV/bin/python" -V

echo "== [3/5] install deps (aliyun mirror) =="
"$UV" pip install --python "$VENV/bin/python" --index-url "$PYUV_INDEX" \
  numpy coremltools onnx onnxruntime
"$UV" pip install --python "$VENV/bin/python" --index-url "$PYUV_INDEX" \
  --find-links "$CPU_FINDLINKS" "torch==2.6.0+cpu"

echo "== [4/5] environment =="
"$VENV/bin/python" - <<'PYEOF'
import coremltools as ct, torch, sys
print("python", sys.version.split()[0], "| torch", torch.__version__, "| coremltools", ct.__version__)
from coremltools.converters.mil.backend.mil import load as _l
print("BlobWriter available:", _l.BlobWriter is not None)
PYEOF

echo "== [5/5] convert =="
"$VENV/bin/python" "$BASE/convert_checkpoint_to_coreml.py"
echo "WSL_CONVERT_DONE=$?"
