#!/usr/bin/env python3
"""Fine-tune small encoder as teacher/student 2-class (JSONL input)."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from datasets import Dataset, DatasetDict, load_dataset
from sklearn.metrics import accuracy_score, classification_report, f1_score
from transformers import (
    AutoModelForSequenceClassification,
    AutoTokenizer,
    EarlyStoppingCallback,
    Trainer,
    TrainingArguments,
)

DEFAULT_MODEL = "microsoft/MiniLM-L12-H384-uncased"
LABEL2ID = {"student": 0, "teacher": 1}
ID2LABEL = {0: "student", 1: "teacher"}


def load_jsonl(path: Path) -> list[dict]:
    rows = []
    with path.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            if "text" in d and "label" in d:
                rows.append({"text": str(d["text"]), "label": int(d["label"])})
    return rows


def build_dataset(data_dir: Path) -> DatasetDict:
    train_rows = load_jsonl(data_dir / "train.jsonl")
    test_rows = load_jsonl(data_dir / "test.jsonl")
    if not train_rows:
        raise SystemExit(f"no train.jsonl in {data_dir}")
    if not test_rows:
        rng = np.random.default_rng(42)
        idx = rng.permutation(len(train_rows))
        cut = max(1, int(len(train_rows) * 0.15))
        test_rows = [train_rows[i] for i in idx[:cut]]
        train_rows = [train_rows[i] for i in idx[cut:]]
    rng = np.random.default_rng(42)
    idx = rng.permutation(len(train_rows))
    n_val = max(1, int(len(train_rows) * 0.1))
    val_rows = [train_rows[i] for i in idx[:n_val]]
    train_rows = [train_rows[i] for i in idx[n_val:]]

    def counts(rows):
        t = sum(1 for r in rows if r["label"] == 1)
        return {"n": len(rows), "teacher": t, "student": len(rows) - t}

    print("train", counts(train_rows), "val", counts(val_rows), "test", counts(test_rows), flush=True)
    return DatasetDict(
        train=Dataset.from_list(train_rows),
        validation=Dataset.from_list(val_rows),
        test=Dataset.from_list(test_rows),
    )


def compute_metrics(eval_pred):
    logits, labels = eval_pred
    preds = np.argmax(logits, axis=-1)
    return {
        "accuracy": accuracy_score(labels, preds),
        "f1_macro": f1_score(labels, preds, average="macro"),
        "f1_teacher": f1_score(labels, preds, pos_label=1),
        "f1_student": f1_score(labels, preds, pos_label=0),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-dir", type=Path, default=Path("/root/autodl-tmp/talkmoves_jsonl"))
    ap.add_argument("--output", type=Path, default=Path("/root/autodl-tmp/role-cls"))
    ap.add_argument("--model", type=str, default=DEFAULT_MODEL)
    ap.add_argument("--epochs", type=float, default=3.0)
    ap.add_argument("--batch-size", type=int, default=64)
    ap.add_argument("--lr", type=float, default=2e-5)
    ap.add_argument("--max-length", type=int, default=128)
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    ds = build_dataset(args.data_dir)

    print("loading model...", flush=True)
    tokenizer = AutoTokenizer.from_pretrained(args.model)
    model = AutoModelForSequenceClassification.from_pretrained(
        args.model, num_labels=2, id2label=ID2LABEL, label2id=LABEL2ID
    )

    def tok(batch):
        return tokenizer(batch["text"], truncation=True, padding="max_length", max_length=args.max_length)

    print("tokenizing...", flush=True)
    ds = ds.map(tok, batched=True, batch_size=1000, remove_columns=["text"])
    ds.set_format("torch")
    (args.output / "data_stats.json").write_text(
        json.dumps({k: len(v) for k, v in ds.items()}, indent=2), encoding="utf-8"
    )

    training_args = TrainingArguments(
        output_dir=str(args.output / "checkpoints"),
        num_train_epochs=args.epochs,
        per_device_train_batch_size=args.batch_size,
        per_device_eval_batch_size=args.batch_size * 2,
        learning_rate=args.lr,
        weight_decay=0.01,
        logging_steps=20,
        eval_strategy="epoch",
        save_strategy="epoch",
        load_best_model_at_end=True,
        metric_for_best_model="f1_macro",
        greater_is_better=True,
        fp16=True,
        report_to=[],
        seed=args.seed,
        dataloader_num_workers=4,
        save_total_limit=2,
    )

    trainer = Trainer(
        model=model,
        args=training_args,
        train_dataset=ds["train"],
        eval_dataset=ds["validation"],
        compute_metrics=compute_metrics,
        callbacks=[EarlyStoppingCallback(early_stopping_patience=2)],
    )

    print("training...", flush=True)
    train_result = trainer.train()
    print("train:", train_result.metrics, flush=True)

    test_metrics = trainer.evaluate(ds["test"], metric_key_prefix="test")
    print("test:", test_metrics, flush=True)

    preds = trainer.predict(ds["test"])
    y_true = preds.label_ids
    y_pred = np.argmax(preds.predictions, axis=-1)
    report = classification_report(y_true, y_pred, target_names=["student", "teacher"], digits=4)
    print(report, flush=True)

    final_dir = args.output / "final"
    trainer.save_model(str(final_dir))
    tokenizer.save_pretrained(str(final_dir))
    (args.output / "test_report.txt").write_text(report, encoding="utf-8")
    (args.output / "test_metrics.json").write_text(json.dumps(test_metrics, indent=2), encoding="utf-8")
    print(f"saved model -> {final_dir}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
