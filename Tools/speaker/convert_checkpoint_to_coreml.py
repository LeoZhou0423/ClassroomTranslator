#!/usr/bin/env python3
"""ModelScope CAMPPlus checkpoint -> CoreML .mlpackage (proven project pattern).

Mirrors Tools/accent/convert_accent_to_coreml.py:
  build torch module (3D-Speaker source vendored in ./thirdparty) ->
  load state_dict -> torch.jit.trace -> coremltools.convert -> .mlpackage

Also cross-checks the traced torch model against the sherpa-onnx ONNX export
(models/campplus_zh_en_advanced.onnx) on identical fbank input.
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    here = Path(__file__).parent
    p.add_argument("--checkpoint", type=Path, default=here / "models" / "campplus_cn_en_common.pt")
    p.add_argument("--onnx", type=Path, default=here / "models" / "campplus_zh_en_advanced.onnx")
    p.add_argument("--out", type=Path, default=here / "models" / "SpeakerCAM++ZHEng.mlpackage")
    p.add_argument("--seconds", type=float, default=4.0)
    p.add_argument("--fp16", action="store_true", default=True)
    p.add_argument("--no-fp16", dest="fp16", action="store_false")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    here = Path(__file__).parent
    sys.path.insert(0, str(here / "thirdparty"))

    import numpy as np
    import torch
    import coremltools as ct

    print(f"torch {torch.__version__} | coremltools {ct.__version__}")

    from speakerlab.models.campplus.DTDNN import CAMPPlus

    frames = int(round(args.seconds * 100))
    example = torch.randn(1, frames, 80, dtype=torch.float32) * 0.1

    print(f"[1/5] build CAMPPlus(feat_dim=80, embedding_size=192, ...)")
    model = CAMPPlus(
        feat_dim=80,
        embedding_size=192,
        growth_rate=32,
        bn_size=4,
        init_channels=128,
        config_str="batchnorm-relu",
        memory_efficient=True,
    )
    print(f"[2/5] load checkpoint: {args.checkpoint}")
    sd = torch.load(str(args.checkpoint), map_location="cpu", weights_only=True)
    missing, unexpected = model.load_state_dict(sd, strict=False)
    if missing or unexpected:
        print(f"  missing={len(missing)} e.g. {missing[:5]}")
        print(f"  unexpected={len(unexpected)} e.g. {unexpected[:5]}")
        if missing:
            print("  ERROR: missing weights", file=sys.stderr)
            return 2
    model.eval()

    print("[3/5] parity check vs sherpa-onnx ONNX export ...")
    try:
        import onnxruntime as ort

        sess = ort.InferenceSession(str(args.onnx), providers=["CPUExecutionProvider"])
        ref = sess.run(None, {sess.get_inputs()[0].name: example.numpy()})[0]
        with torch.no_grad():
            got = model(example).numpy()
        diff = float(np.max(np.abs(ref - got)))
        cos = float(np.dot(ref.ravel(), got.ravel()) / (np.linalg.norm(ref) * np.linalg.norm(got) + 1e-9))
        print(f"  ref shape={ref.shape} got shape={got.shape}")
        print(f"  max|diff|={diff:.3e}  cos={cos:.6f}")
        if diff > 1e-3:
            print("  ERROR: torch/ONNX mismatch", file=sys.stderr)
            return 3
    except FileNotFoundError:
        print("  (onnx not present, skip cross-check)")

    print("[4/5] torch.jit.trace ...")
    with torch.no_grad():
        traced = torch.jit.trace(model, example, strict=False)
    print("  trace OK")

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
    print(f"  convert done in {time.time()-t0:.1f}s")
    mlmodel.author = "ClassroomTranslator research"
    mlmodel.short_description = (
        "Speaker embedding CAM++ (3D-Speaker zh_en advanced), input log-mel fbank [1,T,80] @16kHz, 192-d output"
    )
    mlmodel.user_defined_metadata["modelSource"] = (
        "https://www.modelscope.cn/models/iic/speech_campplus_sv_zh_en_16k-common_advanced"
    )
    mlmodel.user_defined_metadata["license"] = "Apache-2.0"
    mlmodel.user_defined_metadata["sampleRate"] = "16000"
    mlmodel.user_defined_metadata["frameShiftMs"] = "10"
    mlmodel.user_defined_metadata["numFrames"] = str(frames)

    out = args.out.resolve()
    if out.exists():
        import shutil

        shutil.rmtree(out) if out.is_dir() else out.unlink()
    mlmodel.save(str(out))
    print(f"saved: {out}")

    print("[verify] reopen .mlpackage ...")
    loaded = ct.models.MLModel(str(out))
    spec = loaded.get_spec()
    for i in spec.description.input:
        dims = list(i.type.multiArrayType.shape)
        print(f"  IN  {i.name} {dims} elem={i.type.multiArrayType.dataType}")
    for o in spec.description.output:
        dims = list(o.type.multiArrayType.shape)
        print(f"  OUT {o.name} {dims} elem={o.type.multiArrayType.dataType}")
    print(f"  specificationVersion: {spec.specificationVersion}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
