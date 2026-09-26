#!/usr/bin/env python3
"""ONNX -> CoreML conversion for the speaker-embedding model (CAM++).

Path (coremltools >= 6 removed the native ONNX importer):
  onnx -> onnx2pytorch (torch nn.Module) -> torch.jit.trace -> coremltools -> .mlpackage

Fixed input shape [1, frames, 80] (pad/truncate at runtime), mirroring
Tools/accent/convert_accent_to_coreml.py.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    here = Path(__file__).parent
    p.add_argument("--onnx", type=Path, default=here / "models" / "campplus_zh_en_advanced.onnx")
    p.add_argument("--out", type=Path, default=here / "models" / "SpeakerCAM++ZHEng.mlpackage")
    p.add_argument("--seconds", type=float, default=4.0, help="fixed input window in seconds (100 fbank frames/s)")
    p.add_argument("--fp16", action="store_true", default=True)
    p.add_argument("--no-fp16", dest="fp16", action="store_false")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    import numpy as np
    import torch
    import coremltools as ct
    import onnx
    from onnx2pytorch import ConvertModel

    print(f"torch {torch.__version__} | coremltools {ct.__version__} | onnx {onnx.__version__}")
    frames = int(round(args.seconds * 100))
    example = torch.randn(1, frames, 80) * 0.1

    print(f"[1/5] load ONNX: {args.onnx}")
    onnx_model = onnx.load(str(args.onnx))
    print("      opset:", [(o.domain or "ai.onnx", o.version) for o in onnx_model.opset_import])

    print("[2/5] onnx2pytorch ConvertModel ...")
    try:
        torch_model = ConvertModel(onnx_model, experimental=False)
    except Exception as e:
        print(f"      ConvertModel(experimental=False) failed: {type(e).__name__}: {e}")
        print("      retry experimental=True ...")
        torch_model = ConvertModel(onnx_model, experimental=True)
    torch_model.eval()

    print("[3/5] parity check vs onnxruntime (random input) ...")
    import onnxruntime as ort

    sess = ort.InferenceSession(str(args.onnx), providers=["CPUExecutionProvider"])
    in_name = sess.get_inputs()[0].name
    ref = sess.run(None, {in_name: example.numpy()})[0]
    with torch.no_grad():
        got = torch_model(example).numpy()
    diff = float(np.max(np.abs(ref - got)))
    print(f"      ref shape={ref.shape} got shape={got.shape} max|diff|={diff:.3e}")
    if ref.shape != got.shape or diff > 1e-3:
        print("      ERROR: parity check failed", file=sys.stderr)
        return 2

    print("[4/5] torch.jit.trace ...")
    try:
        traced = torch.jit.trace(torch_model, example, strict=False)
        print("      trace OK")
    except Exception as e:
        print(f"      trace failed: {e}; falling back to script")
        traced = torch.jit.script(torch_model)

    print("[5/5] coremltools convert ...")
    t0 = time.time()
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="fbank", shape=example.shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="embedding")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16 if args.fp16 else ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS15,
    )
    print(f"      convert done in {time.time()-t0:.1f}s")
    mlmodel.author = "ClassroomTranslator research"
    mlmodel.short_description = "Speaker embedding CAM++ (3D-Speaker zh_en advanced), input log-mel fbank [1,T,80] @16kHz"
    mlmodel.user_defined_metadata["modelSource"] = (
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/"
        "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"
    )
    mlmodel.user_defined_metadata["license"] = "Apache-2.0 (3D-Speaker / ModelScope iic/speech_campplus_sv_zh_en_16k-common_advanced)"
    mlmodel.user_defined_metadata["sampleRate"] = "16000"
    mlmodel.user_defined_metadata["frameShiftMs"] = "10"
    mlmodel.user_defined_metadata["numFrames"] = str(frames)

    out = args.out.resolve()
    if out.exists():
        import shutil
        shutil.rmtree(out) if out.is_dir() else out.unlink()
    mlmodel.save(str(out))
    print(f"saved: {out}")

    # ---- verify artifact ----
    print("[verify] reopen .mlpackage ...")
    loaded = ct.models.MLModel(str(out))
    spec = loaded.get_spec()
    for i in spec.description.input:
        dims = [(d.dim_param or d.dim_value) for d in i.type.multiArrayType.shape.dim]
        print(f"  IN  {i.name} {dims}")
    for o in spec.description.output:
        dims = [(d.dim_param or d.dim_value) for d in o.type.multiArrayType.shape.dim]
        print(f"  OUT {o.name} {dims}")
    print(f"  spec version: {spec.specificationVersion}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
