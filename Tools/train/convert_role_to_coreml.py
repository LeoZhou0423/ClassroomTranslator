#!/usr/bin/env python3
"""MiniLM role classifier -> CoreML (BERT-safe: explicit embeddings).

Avoids coremltools dropping gather inputs when position/token_type are
passed through BertEmbeddings. We compose word+position+type ourselves,
then run encoder + classifier head.
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
        emb = model.bert.embeddings
        self.word_embeddings = emb.word_embeddings
        self.position_embeddings = emb.position_embeddings
        self.token_type_embeddings = emb.token_type_embeddings
        self.LayerNorm = emb.LayerNorm
        self.dropout = emb.dropout
        self.encoder = model.bert.encoder
        self.pooler = model.bert.pooler
        self.classifier = model.classifier
        self.max_len = max_len
        self.register_buffer("position_ids", torch.arange(max_len).unsqueeze(0))

    def forward(self, input_ids: torch.Tensor, attention_mask: torch.Tensor, token_type_ids: torch.Tensor):
        # Explicit gathers so CoreML keeps indices as real inputs.
        w = self.word_embeddings(input_ids)
        p = self.position_embeddings(self.position_ids)
        t = self.token_type_embeddings(token_type_ids)
        h = self.LayerNorm(w + p + t)
        h = self.dropout(h)
        ext = attention_mask[:, None, None, :].to(dtype=h.dtype)
        ext = (1.0 - ext) * -10000.0
        enc = self.encoder(h, attention_mask=ext)[0]
        pooled = self.pooler(enc)
        return self.classifier(pooled)


def main() -> int:
    ap = argparse.ArgumentParser()
    here = Path(__file__).resolve().parent
    ap.add_argument("--src", type=Path, default=here / "role-cls-final")
    ap.add_argument(
        "--out-mlpackage",
        type=Path,
        default=here.parent.parent / "ClassroomTranslator" / "Resources" / "RoleMiniLM.mlpackage",
    )
    ap.add_argument(
        "--out-vocab",
        type=Path,
        default=here.parent.parent / "ClassroomTranslator" / "Resources" / "role_vocab.txt",
    )
    ap.add_argument("--max-length", type=int, default=128)
    args = ap.parse_args()

    extract_vocab(args.src / "tokenizer.json", args.out_vocab)

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
        print("ref logits", ref[0].tolist())

    ts = torch.jit.trace(wrap, (ids, mask, types), strict=False)

    print("convert mlprogram FP16 (GitHub size limit)...")
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
