#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    import torch
except ImportError:
    print("torch is required", file=sys.stderr)
    sys.exit(1)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--model-dir",
        type=Path,
        default=Path(__file__).parent / "models" / "accent-id-commonaccent_ecapa",
    )
    p.add_argument("--out", type=Path, default=Path("AccentECAPA.mlpackage"))
    p.add_argument("--labels-out", type=Path, default=None)
    p.add_argument("--input-seconds", type=float, default=3.0)
    p.add_argument("--sample-rate", type=int, default=16000)
    p.add_argument("--verify", type=Path, default=None)
    p.add_argument("--labels-file", type=Path, default=None)
    return p.parse_args()


def load_labels(model_dir: Path, labels_file: Path | None) -> list[str]:
    if labels_file and labels_file.is_file():
        data = json.loads(labels_file.read_text())
        if isinstance(data, dict) and "order" in data:
            return list(data["order"])
        if isinstance(data, list):
            return [str(x) for x in data]

    enc = model_dir / "accent_encoder.txt"
    if not enc.is_file():
        raise FileNotFoundError(f"Missing label encoder: {enc}")

    indexed: list[tuple[int, str]] = []
    for line in enc.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("=") or "starting_index" in line:
            continue
        if "=>" not in line:
            continue
        raw = line.split("=>", 1)[0].strip().strip("'\"")
        try:
            idx = int(line.split("=>", 1)[1].strip())
        except ValueError:
            continue
        indexed.append((idx, raw))
    if not indexed:
        raise ValueError("Could not parse accent_encoder.txt")
    indexed.sort(key=lambda t: t[0])
    return [name for _, name in indexed]


class ManualFullPipeline(torch.nn.Module):
    def __init__(self, feats, norm, emb, clf):
        super().__init__()
        self.feats = feats
        self.norm = norm
        self.emb = emb
        self.clf = clf

    def forward(self, waveform: torch.Tensor) -> torch.Tensor:
        if waveform.dim() == 1:
            waveform = waveform.unsqueeze(0)
        x = self.feats(waveform)
        x = self.norm(x)
        e = self.emb(x)
        output = self.clf(e)
        if output.dim() == 3 and output.shape[1] == 1:
            output = output.squeeze(1)
        return output


class EncoderClassifierWrapper(torch.nn.Module):  # type: ignore[name-defined]
    def __init__(self, encoder, fixed_samples: int):
        super().__init__()
        self.encoder = encoder
        self.fixed_samples = fixed_samples

    def forward(self, waveform: torch.Tensor) -> torch.Tensor:
        if waveform.dim() == 1:
            waveform = waveform.unsqueeze(0)
        if waveform.shape[-1] != self.fixed_samples:
            if waveform.shape[-1] > self.fixed_samples:
                waveform = waveform[..., : self.fixed_samples]
            else:
                pad = self.fixed_samples - waveform.shape[-1]
                waveform = torch.nn.functional.pad(waveform, (0, pad))
        emb = self.encoder.encode_batch(waveform)
        if emb.dim() == 3:
            emb = emb.squeeze(1)
        head = None
        hparams = getattr(self.encoder, "hparams", None)
        if hparams is not None and hasattr(hparams, "classification"):
            head = hparams.classification
        elif hasattr(self.encoder, "classification"):
            head = self.encoder.classification
        else:
            mod = getattr(self.encoder, "mod", None)
            if mod is not None and hasattr(mod, "classifier"):
                head = mod.classifier
        if head is None:
            raise RuntimeError("No classification head found on EncoderClassifier")
        return head(emb)


def _load_state(module: torch.nn.Module, path: Path) -> None:
    obj = torch.load(path, map_location="cpu", weights_only=False)
    if isinstance(obj, dict) and "model" in obj:
        state = obj["model"]
    elif isinstance(obj, dict) and "state_dict" in obj:
        state = obj["state_dict"]
    else:
        state = obj
    cleaned = {}
    for k, v in state.items():
        nk = k
        for prefix in ("module.", "model."):
            if nk.startswith(prefix):
                nk = nk[len(prefix) :]
        cleaned[nk] = v
    missing, unexpected = module.load_state_dict(cleaned, strict=False)
    if missing:
        print(f"  warn missing {path.name}: {len(missing)} keys e.g. {missing[:5]}")
    if unexpected:
        print(f"  warn unexpected {path.name}: {len(unexpected)} keys e.g. {unexpected[:5]}")


def build_manual(model_dir: Path) -> ManualFullPipeline:
    import torch
    from speechbrain.lobes.features import Fbank
    from speechbrain.lobes.models.ECAPA_TDNN import Classifier, ECAPA_TDNN
    from speechbrain.processing.features import InputNormalization

    n_mels = 80
    emb_dim = 192
    n_classes = 16

    compute_features = Fbank(n_mels=n_mels)
    mean_var_norm = InputNormalization(norm_type="sentence", std_norm=False)
    embedding_model = ECAPA_TDNN(
        input_size=n_mels,
        activation=torch.nn.LeakyReLU,
        channels=[1024, 1024, 1024, 1024, 3072],
        kernel_sizes=[5, 3, 3, 3, 1],
        dilations=[1, 2, 3, 4, 1],
        attention_channels=128,
        lin_neurons=emb_dim,
    )
    classifier = Classifier(input_size=emb_dim, out_neurons=n_classes)

    _load_state(embedding_model, model_dir / "embedding_model.ckpt")
    _load_state(classifier, model_dir / "classifier.ckpt")

    norm_path = model_dir / "normalizer_input.ckpt"
    if norm_path.is_file():
        obj = torch.load(norm_path, map_location="cpu", weights_only=False)
        if isinstance(obj, dict):
            src = obj.get("model", obj) if isinstance(obj.get("model", None), dict) else obj
            if "running_mean" in src:
                with torch.no_grad():
                    mean_var_norm.running_mean.copy_(src["running_mean"])
                    if "running_var" in src:
                        mean_var_norm.running_var.copy_(src["running_var"])
                    if "count" in src:
                        mean_var_norm.count = src["count"]

    emb_obj = torch.load(model_dir / "embedding_model.ckpt", map_location="cpu", weights_only=False)
    if isinstance(emb_obj, dict):
        for key in ("mean_var_norm", "normalizer"):
            inner = emb_obj.get(key)
            if isinstance(inner, dict) and "running_mean" in inner:
                with torch.no_grad():
                    mean_var_norm.running_mean.copy_(inner["running_mean"])
                    if "running_var" in inner:
                        mean_var_norm.running_var.copy_(inner["running_var"])

    for m in (compute_features, mean_var_norm, embedding_model, classifier):
        m.eval()
    return ManualFullPipeline(compute_features, mean_var_norm, embedding_model, classifier)


def try_encoder_classifier(model_dir: Path, fixed_samples: int):
    try:
        from speechbrain.inference.classifiers import EncoderClassifier

        model = EncoderClassifier.from_hparams(
            savedir=str(model_dir / "_sb_tmp"),
            source=str(model_dir),
        )
        model.eval()
        return EncoderClassifierWrapper(model, fixed_samples)
    except Exception as e:  # noqa: BLE001
        print(f"EncoderClassifier failed ({e}); using manual modules.")
        return None


def load_wav_mono(path: Path, sample_rate: int):
    import torchaudio

    wav, sr = torchaudio.load(str(path))
    if wav.shape[0] > 1:
        wav = wav.mean(dim=0, keepdim=True)
    if sr != sample_rate:
        wav = torchaudio.functional.resample(wav, sr, sample_rate)
    return wav


def fix_length(wave, num_samples: int):
    import torch

    if wave.shape[-1] >= num_samples:
        return wave[..., :num_samples]
    return torch.nn.functional.pad(wave, (0, num_samples - wave.shape[-1]))


def verify_parity(torch_model, coreml_path: Path, wav: Path, sample_rate: int, labels: list[str], num_samples: int) -> None:
    import coremltools as ct
    import numpy as np
    import torch

    wave = fix_length(load_wav_mono(wav, sample_rate), num_samples)
    with torch.no_grad():
        ref = torch_model(wave)
        ref_prob = torch.softmax(ref, dim=-1)[0].cpu().numpy()

    mlmodel = ct.models.MLModel(str(coreml_path))
    try:
        input_names = [i.name for i in mlmodel.get_spec().description.input]
    except Exception:
        input_names = ["waveform"]
    arr = wave.squeeze(0).cpu().numpy().astype(np.float32)
    out = mlmodel.predict({input_names[0]: arr})
    out_key = next(iter(out))
    ml_logits = np.asarray(out[out_key]).reshape(-1).astype(np.float64)
    ml_prob = np.exp(ml_logits - ml_logits.max())
    ml_prob = ml_prob / ml_prob.sum()

    torch_idx = int(ref_prob.argmax())
    ml_idx = int(ml_prob.argmax())
    print(f"  torch top: {labels[torch_idx]} ({float(ref_prob[torch_idx]):.3f})")
    print(f"  coreml top: {labels[ml_idx]} ({float(ml_prob[ml_idx]):.3f})")
    print(f"  max |prob| diff: {float(np.max(np.abs(ref_prob - ml_prob))):.4f}")


def main() -> int:
    args = parse_args()
    import numpy as np
    import torch
    import coremltools as ct

    model_dir = args.model_dir.resolve()
    if not model_dir.is_dir():
        print(f"Model dir not found: {model_dir}", file=sys.stderr)
        return 1

    labels = load_labels(model_dir, args.labels_file)
    print(f"Labels ({len(labels)}): {labels}")

    num_samples = int(round(args.input_seconds * args.sample_rate))
    example = (torch.randn(1, num_samples) * 0.01).to(torch.float32)

    model = try_encoder_classifier(model_dir, num_samples)
    if model is None:
        model = build_manual(model_dir)
    model.eval()

    with torch.no_grad():
        try:
            ref = model(example)
            print(f"Smoke output: {tuple(ref.shape)} (expect [1, {len(labels)}])")
            if ref.shape[-1] != len(labels):
                print(f"ERROR class dim {ref.shape[-1]} != {len(labels)}", file=sys.stderr)
                return 2
        except Exception as e:  # noqa: BLE001
            import traceback

            print(f"Smoke forward failed: {e}", file=sys.stderr)
            traceback.print_exc()
            return 3

    print("Tracing…")
    traced = None
    try:
        traced = torch.jit.trace(model, example, strict=False)
        print("trace OK")
    except Exception as e:
        print(f"trace failed ({e}); trying script…")
        try:
            traced = torch.jit.script(model)
            print("script OK")
        except Exception as e2:
            print(f"script failed: {e2}", file=sys.stderr)
            import traceback

            traceback.print_exc()
            return 4

    print("Converting with coremltools…")
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="waveform", shape=example.shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="logits")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
    )

    mlmodel.author = "CommonAccent / ClassroomTranslator"
    mlmodel.short_description = "English accent classifier (ECAPA-TDNN, 16 classes)"
    mlmodel.user_defined_metadata["labels"] = json.dumps(labels)
    mlmodel.user_defined_metadata["sampleRate"] = str(args.sample_rate)
    mlmodel.user_defined_metadata["inputSeconds"] = str(args.input_seconds)
    mlmodel.user_defined_metadata["numSamples"] = str(num_samples)

    out = args.out.resolve()
    if out.exists():
        import shutil

        if out.is_dir():
            shutil.rmtree(out)
        else:
            out.unlink()
    mlmodel.save(str(out))
    print(f"Saved: {out}")

    labels_out = (args.labels_out or (out.parent / "labels.json")).resolve()
    labels_out.write_text(
        json.dumps(
            {
                "order": labels,
                "sampleRate": args.sample_rate,
                "inputSeconds": args.input_seconds,
                "numSamples": num_samples,
            },
            indent=2,
        )
    )
    print(f"Labels: {labels_out}")

    if args.verify and args.verify.is_file():
        print("Verifying parity…")
        try:
            verify_parity(model, out, args.verify, args.sample_rate, labels, num_samples)
        except Exception as e:  # noqa: BLE001
            print(f"verify skipped: {e}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
