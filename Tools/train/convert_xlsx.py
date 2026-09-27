#!/usr/bin/env python3
"""Convert TalkMoves xlsx (Speaker T/S + Sentence) to JSONL for fast training."""
from __future__ import annotations

import json
from pathlib import Path

import pandas as pd

DATA = Path("/root/autodl-tmp/TalkMoves/data")
OUT = Path("/root/autodl-tmp/talkmoves_jsonl")
OUT.mkdir(parents=True, exist_ok=True)


def convert(path: Path, out_name: str) -> int:
    print(f"reading {path} ...", flush=True)
    df = pd.read_excel(path, engine="openpyxl")
    print(f"  columns={list(df.columns)} rows={len(df)}", flush=True)
    cols = {c.strip().lower(): c for c in df.columns}
    # expected: turn, speaker, sentence, ...
    speaker_col = cols.get("speaker")
    sentence_col = cols.get("sentence")
    if speaker_col is None or sentence_col is None:
        # positional fallback for unnamed first col
        # (Unnamed, Turn, Speaker, Sentence, ...)
        if len(df.columns) >= 4:
            speaker_col = df.columns[2]
            sentence_col = df.columns[3]
        else:
            raise SystemExit(f"cannot find speaker/sentence in {path}")

    df = df[[speaker_col, sentence_col]].copy()
    df.columns = ["speaker", "text"]
    df["speaker"] = df["speaker"].astype(str).str.strip().str.upper()
    df["text"] = df["text"].astype(str).str.strip()
    df = df[df["text"].str.len() >= 2]
    df = df[df["speaker"].isin(["T", "S", "TEACHER", "STUDENT"])]
    df["label"] = df["speaker"].map(lambda s: 1 if s.startswith("T") else 0)

    out_path = OUT / out_name
    with out_path.open("w", encoding="utf-8") as f:
        for rec in df[["text", "label"]].to_dict(orient="records"):
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    n_t = int((df["label"] == 1).sum())
    print(f"  wrote {out_path} n={len(df)} teacher={n_t} student={len(df)-n_t}", flush=True)
    return len(df)


def main() -> int:
    convert(DATA / "train_data_504.xlsx", "train.jsonl")
    convert(DATA / "test_data_63.xlsx", "test.jsonl")
    print("done", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
