#!/usr/bin/env python3
"""Try several ONNX->torch conversion backends and check numeric parity vs onnxruntime.

Backends:
  A. onnx2pytorch ConvertModel(experimental=False)
  B. onnx2pytorch ConvertModel(experimental=True)
  C. onnx2torch.convert
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

BASE = Path(__file__).parent
ONNX = BASE / "models" / "campplus_zh_en_advanced.onnx"


def main() -> int:
    import torch
    import onnx
    import onnxruntime as ort

    frames = 400
    example = torch.randn(1, frames, 80, dtype=torch.float32) * 0.1
    sess = ort.InferenceSession(str(ONNX), providers=["CPUExecutionProvider"])
    ref = sess.run(None, {sess.get_inputs()[0].name: example.numpy()})[0]
    onnx_model = onnx.load(str(ONNX))

    def check(name, model) -> bool:
        try:
            model.eval()
            with torch.no_grad():
                got = model(example).numpy()
            diff = float(np.max(np.abs(ref - got)))
            cos = float(
                np.dot(ref.ravel(), got.ravel())
                / (np.linalg.norm(ref) * np.linalg.norm(got) + 1e-9)
            )
            print(f"[{name}] shape={got.shape} max|diff|={diff:.3e} cos={cos:.4f}")
            return diff < 1e-3
        except Exception as e:
            print(f"[{name}] FORWARD FAILED: {type(e).__name__}: {e}")
            return False

    ok = False

    # A/B: onnx2pytorch
    try:
        from onnx2pytorch import ConvertModel

        for exp in (False, True):
            try:
                m = ConvertModel(onnx_model, experimental=exp)
                if check(f"onnx2pytorch experimental={exp}", m):
                    ok = True
                    break
            except Exception as e:
                print(f"[onnx2pytorch experimental={exp}] CONSTRUCT FAILED: {type(e).__name__}: {e}")
    except Exception as e:
        print("onnx2pytorch import failed:", e)

    # C: onnx2torch
    if not ok:
        try:
            import onnx2torch

            m = onnx2torch.convert(onnx_model)
            if check("onnx2torch", m):
                ok = True
        except Exception as e:
            print(f"[onnx2torch] FAILED: {type(e).__name__}: {e}")

    print("RESULT:", "parity OK via", "a backend" if ok else "NONE")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
