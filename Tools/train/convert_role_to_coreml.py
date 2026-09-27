#!/usr/bin/env python3
"""MiniLM role classifier -> CoreML via traced PyTorch (BERT-safe wrap).

Avoids coremltools ONNX frontend (removed in ct>=8) and the known
`int`-cast crash inside BertEmbeddings by freezing position_ids.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn


def extract_vocab(tokenizer_json: Path, out_vocab: Path) -> None:
    data = json.loads(tokenizer_json.read_text(encoding="utf-8"))
    vocab = data["model"]["vocab"]
    size = max(vocab.values()) + 1
    tokens = ["[PAD]"] * size
    for tok, idx in vocab.items():
        if 0 <= idx < size:
            tokens[idx] = tok
    out_vocab.write_text("\n".join(tokens) + "\n", encoding="utf-8")
    print(f"vocab -> {out_vocab} ({size})")


class RoleWrap(nn.Module):
    def __init__(self, model, max_len: int):
        super().__init__()
        self.model = model
        self.max_len = max_len
        pos = torch.arange(max_len).unsqueeze(0)
        self.register_buffer("position_ids", pos)
        self.register_buffer("ones_mask", torch.ones(1, max_len, dtype=torch.int64))

    def forward(self, input_ids: torch.Tensor, attention_mask: torch.Tensor, token_type_ids: torch.Tensor):
        # force static position ids to avoid aten::int in embeddings
        out = self.model.bert(
            input_ids=input_ids,
            attention_mask=attention_mask,
            token_type_ids=token_type_ids,
            position_ids=self.position_ids,
        )
        pooled = out.pooler_output
        return self.model.classifier(pooled)


def main() -> int:
    ap = argparse.ArgumentParser()
    here = Path(__file__).resolve().parent
    ap.add_argument("--src", type=Path, default=here / "role-cls-final")
    ap.add_argument("--out-mlpackage", type=Path,
                    default=here.parent.parent / "ClassroomTranslator" / "Resources" / "RoleMiniLM.mlpackage")
    ap.add_argument("--out-vocab", type=Path,
                    default=here.parent.parent / "ClassroomTranslator" / "Resources" / "role_vocab.txt")
    ap.add_argument("--max-length", type=int, default=128)
    args = ap.parse_args()

    tok = args.src / "tokenizer.json"
    extract_vocab(tok, args.out_vocab)

    from transformers import BertConfig, BertForSequenceClassification
    import coremltools as ct

    print("torch", torch.__version__, "| ct", ct.__version__)
    config = BertConfig.from_json_file(str(args.src / "config.json"))
    model = BertForSequenceClassification.from_pretrained(
        str(args.src / "model.safetensors"), config=config
    )
    model.eval()

    L = args.max_length
    wrap = RoleWrap(model, L).eval()

    ids = torch.zeros(1, L, dtype=torch.int64)
    mask = torch.ones(1, L, dtype=torch.int64)
    types = torch.zeros(1, L, dtype=torch.int64)

    with torch.no_grad():
        ref = wrap(ids, mask, types)
        print("ref logits", ref.shape, ref[0].tolist())

    print("trace...")
    ts = torch.jit.trace(wrap, (ids, mask, types), strict=False)
    ts = torch.jit.freeze(ts)

    print("convert...")
    mlmodel = ct.convert(
        ts,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, L), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, L), dtype=np.int32),
            ct.TensorType(name="token_type_ids", shape=(1, L), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="logits", dtype=np.float32)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS13,
        convert_to="mlprogram",
    )
    mlmodel.author = "ClassroomTranslator"
    mlmodel.short_description = "TalkMoves MiniLM teacher/student classifier"
    mlmodel.input_description["input_ids"] = "WordPiece ids [1,128]"
    mlmodel.input_description["attention_mask"] = "attention mask [1,128]"
    mlmodel.input_description["token_type_ids"] = "segment ids [1,128]"
    mlmodel.output_description["logits"] = "logits [1,2] student=0 teacher=1"

    args.out_mlpackage.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(args.out_mlpackage))
    print("saved", args.out_mlpackage)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
