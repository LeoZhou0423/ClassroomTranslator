from __future__ import annotations

import gzip
import re
from dataclasses import dataclass


def clean(text: str) -> str:
    return " ".join(text.split()).strip()


def words(text: str) -> list[str]:
    return re.findall(r"[\w']+", text.lower(), flags=re.UNICODE)


def compression_ratio(text: str) -> float:
    raw = text.encode("utf-8")
    return len(raw) / max(1, len(gzip.compress(raw)))


def acceptable(text: str) -> bool:
    text = clean(text)
    tokens = words(text)
    if not tokens:
        return False
    if len(tokens) >= 8 and len(set(tokens)) / len(tokens) <= 0.25:
        return False
    return compression_ratio(text) <= 2.4


def merge_overlap(previous: str, current: str, minimum: int = 2) -> str:
    previous, current = clean(previous), clean(current)
    if not previous:
        return current
    if not current:
        return previous
    old, new = previous.split(), current.split()
    old_norm, new_norm = words(previous), words(current)
    if new_norm[: len(old_norm)] == old_norm:
        return current
    if old_norm[: len(new_norm)] == new_norm:
        return previous
    for size in range(min(len(old_norm), len(new_norm)), minimum - 1, -1):
        if old_norm[-size:] == new_norm[:size]:
            tail = new[size:]
            return previous if not tail else previous + " " + " ".join(tail)
    return current


def append_text(previous: str, current: str) -> str:
    previous, current = previous.rstrip(), clean(current)
    if not current:
        return previous
    if not previous:
        return current
    separator = "" if current[0] in ".,!?;:，。！？；：" else " "
    return previous + separator + current


def format_sentences(text: str) -> str:
    """Format committed text without changing the appendable canonical value."""
    text = clean(text)
    if not text:
        return ""
    # Don't split decimal points, but treat sentence punctuation as a display boundary.
    text = re.sub(r"(?<!\d)\.(?!\d)(?=[ \t]|$)[ \t]*", ".\n", text)
    text = re.sub(r"([!?。！？]+)[ \t]*", r"\1\n", text)
    return text.rstrip("\n")


def strip_committed_prefix(hypothesis: str, committed: str) -> str:
    hypothesis, committed = clean(hypothesis), clean(committed)
    if not committed:
        return hypothesis
    hypothesis_parts = hypothesis.split()
    committed_parts = committed.split()
    if len(hypothesis_parts) < len(committed_parts):
        return ""
    for actual, expected in zip(hypothesis_parts, committed_parts):
        if words(actual) != words(expected):
            return hypothesis
    return " ".join(hypothesis_parts[len(committed_parts):])


def reconcile_final_segment(committed_preview: str, final_hypothesis: str) -> str:
    """A full final hypothesis replaces the provisional partial for its segment."""
    final_hypothesis = clean(final_hypothesis)
    return final_hypothesis if final_hypothesis else clean(committed_preview)


@dataclass
class LocalAgreement:
    previous: str = ""
    stable: str = ""

    def update(self, hypothesis: str) -> tuple[str, str]:
        hypothesis = clean(hypothesis)
        if not self.previous:
            self.previous = hypothesis
            return self.stable, hypothesis
        left, right = self.previous.split(), hypothesis.split()
        common: list[str] = []
        for a, b in zip(left, right):
            if words(a) != words(b):
                break
            common.append(b)
        if len(common) > len(self.stable.split()):
            self.stable = " ".join(common)
        self.previous = hypothesis
        volatile = " ".join(right[len(self.stable.split()):])
        return self.stable, volatile

    def reset(self) -> None:
        self.previous = ""
        self.stable = ""
