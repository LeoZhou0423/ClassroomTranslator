#!/usr/bin/env python3
"""Teacher/student 2-class classifier (ONNX MiniLM fine-tuned on TalkMoves).

Output is a ROLE only. Multi-person numbering (Teacher 1/2, Student 1/2)
is applied later on the person layer — one person never becomes two roles.

Usage:
  from role_classifier import RoleClassifier
  rc = RoleClassifier()  # default Tools/train/role-cls-onnx
  rc.predict("Okay, let's look at the objective")
  -> {"label": "teacher", "score": 0.91}
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np

DEFAULT_DIR = Path(__file__).resolve().parents[1] / "train" / "role-cls-onnx"
ID2LABEL = {0: "student", 1: "teacher"}


class RoleClassifier:
    def __init__(self, model_dir: str | Path | None = None, max_length: int = 128) -> None:
        from tokenizers import Tokenizer
        import onnxruntime as ort

        self.dir = Path(model_dir) if model_dir else DEFAULT_DIR
        onnx_path = self.dir / "model.onnx"
        if not onnx_path.is_file():
            raise FileNotFoundError(onnx_path)
        self.max_length = max_length
        self.tokenizer = Tokenizer.from_file(str(self.dir / "tokenizer.json"))
        self.tokenizer.enable_truncation(max_length=max_length)
        self.tokenizer.enable_padding(length=max_length, pad_id=0, pad_token="[PAD]")
        self.session = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])

    def encode(self, text: str) -> dict[str, np.ndarray]:
        enc = self.tokenizer.encode(text)
        ids = np.array([enc.ids], dtype=np.int64)
        mask = np.array([enc.attention_mask], dtype=np.int64)
        types = np.array([enc.type_ids], dtype=np.int64)
        return {
            "input_ids": ids,
            "attention_mask": mask,
            "token_type_ids": types,
        }

    def predict(self, text: str) -> dict:
        text = (text or "").strip()
        if not text:
            return {"label": None, "score": 0.0}
        feeds = self.encode(text)
        logits = self.session.run(["logits"], feeds)[0][0]
        # softmax
        e = np.exp(logits - logits.max())
        probs = e / e.sum()
        idx = int(probs.argmax())
        return {
            "label": ID2LABEL[idx],
            "score": float(probs[idx]),
            "probs": {"student": float(probs[0]), "teacher": float(probs[1])},
        }

    def predict_person(self, texts: list[str], min_votes: int = 1, min_score: float = 0.65) -> dict:
        """Majority vote over a person's utterances.

        Low-confidence utterances are ignored so one noisy line cannot flip a role.
        Returns label teacher/student/None + mean score of counted votes.
        """
        votes: list[str] = []
        scores: list[float] = []
        for t in texts:
            if not t or not t.strip():
                continue
            p = self.predict(t)
            if p["label"] is None or p["score"] < min_score:
                continue
            votes.append(p["label"])
            scores.append(p["score"])
        if len(votes) < min_votes:
            return {"label": None, "score": 0.0, "n": len(votes)}
        n_t = sum(1 for v in votes if v == "teacher")
        n_s = len(votes) - n_t
        label = "teacher" if n_t >= n_s else "student"
        mean_score = float(np.mean(scores)) if scores else 0.0
        return {
            "label": label,
            "score": mean_score,
            "n": len(votes),
            "teacher_votes": n_t,
            "student_votes": n_s,
        }


def assign_role_names(
    person_ids: list[str],
    role_by_person: dict[str, dict],
    prefer_order: list[str] | None = None,
) -> dict[str, str]:
    """Map person display keys to Teacher N / Student N / Speaker N.

    Multiple teachers or multiple students are fine — just number them.
    """
    # person_ids: stable keys e.g. "Person A" or enrolled names
    teachers: list[str] = []
    students: list[str] = []
    others: list[str] = []

    order = prefer_order or person_ids
    ordered = [p for p in order if p in set(person_ids)] + [
        p for p in person_ids if p not in set(order)
    ]

    for pid in ordered:
        role = (role_by_person.get(pid) or {}).get("label")
        if role == "teacher":
            teachers.append(pid)
        elif role == "student":
            students.append(pid)
        else:
            others.append(pid)

    out: dict[str, str] = {}
    for i, pid in enumerate(teachers, 1):
        out[pid] = f"Teacher {i}" if len(teachers) > 1 else "Teacher"
    for i, pid in enumerate(students, 1):
        out[pid] = f"Student {i}" if len(students) > 1 else "Student"
    for i, pid in enumerate(others, 1):
        out[pid] = f"Speaker {i}" if len(others) > 1 else "Speaker"
    return out


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser()
    ap.add_argument("text", nargs="?", default="Okay so our objective is to produce mathematical solutions")
    ap.add_argument("--model-dir", default=None)
    args = ap.parse_args()
    rc = RoleClassifier(args.model_dir)
    print(json.dumps(rc.predict(args.text), ensure_ascii=False, indent=2))
