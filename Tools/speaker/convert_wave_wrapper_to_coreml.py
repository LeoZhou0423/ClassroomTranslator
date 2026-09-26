#!/usr/bin/env python3
"""Waveform wrapper (fbank inside the graph) -> CoreML .mlpackage.

Run inside WSL (see wsl_convert.sh) because PyPI coremltools has no Windows
wheel with BlobWriter; a Windows run is still useful up to the serialization
step to catch trace/MIL errors early.

  SpeakerWaveWrapper(waveform[1,64000], numSamples[1,1]) -> embedding[1,192]

Parity checks before saving:
  1. traced torch output == eager wrapper output (identical inputs)
  2. re-opened .mlpackage input/output shapes and dtypes
Numeric parity of the *converted* model against torch can only be measured
on macOS (CoreML runtime); see SpeakerFeature.md Mac verification checklist.
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
    p.add_argument("--out", type=Path, default=here / "models" / "SpeakerCAMWaveZHEng.mlpackage")
    p.add_argument("--seconds", type=float, default=4.0)
    p.add_argument("--fp16", action="store_true", default=True)
    p.add_argument("--no-fp16", dest="fp16", action="store_false")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    here = Path(__file__).parent
    sys.path.insert(0, str(here))

    import numpy as np
    import torch
    import coremltools as ct

    from wave_wrapper import SpeakerWaveWrapper, WAVE_LEN

    print(f"torch {torch.__version__} | coremltools {ct.__version__}")

    print("[1/5] build wrapper ...")
    model = SpeakerWaveWrapper(args.checkpoint, masked=True).eval()
    example_wave = (torch.randn(1, WAVE_LEN) * 0.1).to(torch.float32)
    example_len = torch.tensor([[float(int(args.seconds * 16000))]], dtype=torch.float32)

    print("[2/5] eager reference ...")
    with torch.no_grad():
        ref = model(example_wave, example_len).numpy()

    print("[3/5] torch.jit.trace ...")
    with torch.no_grad():
        traced = torch.jit.trace(model, (example_wave, example_len), strict=False)
    with torch.no_grad():
        got = traced(example_wave, example_len).numpy()
    diff = float(np.max(np.abs(ref - got)))
    cos = float(np.dot(ref.ravel(), got.ravel()) / (np.linalg.norm(ref) * np.linalg.norm(got) + 1e-9))
    print(f"  trace parity: max|diff|={diff:.3e} cos={cos:.6f}")
    if diff > 1e-4:
        print("  ERROR: traced graph diverges from eager model", file=sys.stderr)
        return 3

    print("[4/5] coremltools convert ...")
    t0 = time.time()
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="waveform", shape=(1, WAVE_LEN), dtype=np.float32),
            ct.TensorType(name="numSamples", shape=(1, 1), dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="embedding")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16 if args.fp16 else ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS15,
    )
    print(f"  convert done in {time.time() - t0:.1f}s")
    mlmodel.author = "ClassroomTranslator research"
    mlmodel.short_description = (
        "Speaker embedding CAM++ (3D-Speaker zh_en advanced) with kaldi fbank "
        "frontend embedded: waveform [1,64000] + numSamples [1,1] @16kHz -> 192-d embedding"
    )
    mlmodel.user_defined_metadata["modelSource"] = (
        "https://www.modelscope.cn/models/iic/speech_campplus_sv_zh_en_16k-common_advanced"
    )
    mlmodel.user_defined_metadata["license"] = "Apache-2.0"
    mlmodel.user_defined_metadata["frontend"] = "kaldi-native-fbank 1.22.3 port (sherpa-onnx 1.13.8 config)"
    mlmodel.user_defined_metadata["sampleRate"] = "16000"
    mlmodel.user_defined_metadata["windowSeconds"] = "4.0"
    mlmodel.user_defined_metadata["numSamplesRange"] = "9600..64000"

    out = args.out.resolve()
    if out.exists():
        import shutil

        shutil.rmtree(out) if out.is_dir() else out.unlink()
    mlmodel.save(str(out))
    print(f"saved: {out}")

    print("[5/5] reopen .mlpackage ...")
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
