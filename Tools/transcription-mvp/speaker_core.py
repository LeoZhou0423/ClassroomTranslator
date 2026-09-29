from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import sherpa_onnx

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[1]
SPEAKER_MODEL = REPO / "Tools" / "speaker" / "models" / "campplus_zh_en_advanced.onnx"
sys.path.insert(0, str(REPO / "Tools" / "speaker"))
from role_classifier import RoleClassifier  # noqa: E402


@dataclass
class TranscriptItem:
    text: str
    speaker_id: int | None = None


@dataclass
class RevisableRoleState:
    label: str | None = None
    score: float = 0.0
    opposing_label: str | None = None
    opposing_count: int = 0

    def update(self, teacher_probability: float) -> bool:
        """Apply hysteresis while allowing sustained contrary evidence to relabel."""
        teacher_probability = min(max(teacher_probability, 0.0), 1.0)
        candidate = "teacher" if teacher_probability >= 0.72 else "student" if teacher_probability <= 0.28 else None
        candidate_score = teacher_probability if candidate == "teacher" else 1.0 - teacher_probability
        if candidate is None:
            self.opposing_label = None
            self.opposing_count = 0
            return False
        if self.label is None:
            self.label, self.score = candidate, candidate_score
            return True
        if candidate == self.label:
            self.score = 0.65 * self.score + 0.35 * candidate_score
            self.opposing_label = None
            self.opposing_count = 0
            return False
        if self.opposing_label == candidate:
            self.opposing_count += 1
        else:
            self.opposing_label = candidate
            self.opposing_count = 1
        if self.opposing_count < 2:
            return False
        self.label, self.score = candidate, candidate_score
        self.opposing_label = None
        self.opposing_count = 0
        return True


TEACHER_CUES = (
    "learning intention", "today we", "we are going", "let's look", "please open",
    "remember to", "make sure", "the answer is", "for example", "our objective",
    "who can tell me", "what do you think", "does anyone", "can you tell me", "could you tell me",
)
STUDENT_CUES = (
    "i think", "i don't know", "i do not know", "my answer is", "i'm not sure", "is it",
)
STRONG_STUDENT_CUES = (
    "professor, i have a question", "professor i have a question", "i have a question",
    "i don't understand", "i do not understand", "can you explain", "could you explain",
)


def correct_role_with_cues(text: str, label: str, score: float) -> tuple[str, float]:
    """Correct MiniLM's known weak student-short-answer cases conservatively."""
    lowered = text.lower()
    teacher_hits = sum(cue in lowered for cue in TEACHER_CUES)
    student_hits = sum(cue in lowered for cue in STUDENT_CUES)
    strong_student_hits = sum(cue in lowered for cue in STRONG_STUDENT_CUES)
    if strong_student_hits:
        return "student", max(score if label == "student" else 0.85, 0.85)
    if student_hits and not teacher_hits:
        return "student", max(score if label == "student" else 0.85, 0.85)
    if teacher_hits and not student_hits:
        return "teacher", max(score if label == "teacher" else 0.85, 0.85)
    return label, score


def normalize(vector: np.ndarray) -> np.ndarray | None:
    norm = float(np.linalg.norm(vector))
    return vector / norm if norm > 0 else None


class OnlineSpeakerClusterer:
    """Conservative two-hit speaker clustering matching the macOS policy."""

    def __init__(self, threshold: float = 0.60, max_speakers: int = 4):
        self.threshold = min(max(threshold, 0.45), 0.75)
        self.merge_floor = self.threshold - 0.12
        self.max_speakers = min(max(max_speakers, 2), 4)
        self.centroids: list[np.ndarray] = []
        self.pending: tuple[np.ndarray, int] | None = None
        self.last_speaker: int | None = None

    def assign(self, embedding: np.ndarray, item_index: int) -> tuple[int, int | None]:
        unit = normalize(embedding)
        if unit is None:
            return self.last_speaker or 0, None
        if not self.centroids:
            self.centroids.append(unit)
            self.last_speaker = 0
            return 0, None

        similarities = [float(np.dot(unit, centroid)) for centroid in self.centroids]
        best = int(np.argmax(similarities))
        if similarities[best] >= self.merge_floor:
            alpha = 0.30 if similarities[best] >= self.threshold else 0.08
            updated = normalize((1 - alpha) * self.centroids[best] + alpha * unit)
            if updated is not None:
                self.centroids[best] = updated
            self.last_speaker = best
            return best, None

        if len(self.centroids) < self.max_speakers:
            if self.pending is not None and float(np.dot(self.pending[0], unit)) >= self.threshold:
                centroid = normalize((self.pending[0] + unit) * 0.5)
                self.centroids.append(centroid if centroid is not None else unit)
                new_id = len(self.centroids) - 1
                backfill = self.pending[1]
                self.pending = None
                self.last_speaker = new_id
                return new_id, backfill
            self.pending = (unit, item_index)

        self.last_speaker = best
        return best, None


class SpeakerRoleAnalyzer:
    def __init__(self, threshold: float = 0.60, max_speakers: int = 4):
        config = sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(SPEAKER_MODEL), num_threads=1)
        self.extractor = sherpa_onnx.SpeakerEmbeddingExtractor(config)
        self.clusterer = OnlineSpeakerClusterer(threshold, max_speakers)
        self.role_classifier = RoleClassifier()
        self.roles: dict[int, tuple[str, float]] = {}
        self.role_states: dict[int, RevisableRoleState] = {}
        self.role_text_snapshots: dict[int, str] = {}

    def embedding(self, samples: np.ndarray) -> np.ndarray | None:
        if len(samples) < 9_600 or float(np.sqrt(np.mean(np.square(samples)))) < 0.003:
            return None
        stream = self.extractor.create_stream()
        stream.accept_waveform(16_000, samples)
        return np.asarray(self.extractor.compute(stream), dtype=np.float32)

    def assign(self, samples: np.ndarray, item_index: int) -> tuple[int | None, int | None]:
        embedding = self.embedding(samples)
        if embedding is None:
            return self.clusterer.last_speaker, None
        return self.clusterer.assign(embedding, item_index)

    def update_roles(self, items: list[TranscriptItem]) -> None:
        grouped: dict[int, list[str]] = {}
        for item in items:
            if item.speaker_id is not None:
                grouped.setdefault(item.speaker_id, []).append(item.text)
        for speaker_id, utterances in grouped.items():
            combined = " ".join(utterances)
            if len(utterances) < 2 or len(combined) < 12:
                continue
            if self.role_text_snapshots.get(speaker_id) == combined:
                continue
            self.role_text_snapshots[speaker_id] = combined
            cumulative = self._teacher_probability(combined)
            recent = utterances[-4:]
            recent_context = self._teacher_probability(" ".join(recent))
            weights = np.arange(1, len(recent) + 1, dtype=np.float64)
            recent_probs = np.asarray([self._teacher_probability(text) for text in recent])
            recent_weighted = float(np.average(recent_probs, weights=weights))
            probability = 0.15 * cumulative + 0.65 * recent_context + 0.20 * recent_weighted
            state = self.role_states.setdefault(speaker_id, RevisableRoleState())
            state.update(probability)
            if state.label is not None:
                self.roles[speaker_id] = (state.label, state.score)

    def _teacher_probability(self, text: str) -> float:
        result = self.role_classifier.predict(text)
        if not result["label"]:
            return 0.5
        label, score = correct_role_with_cues(text, result["label"], result["score"])
        return score if label == "teacher" else 1.0 - score

    def names(self, speaker_ids: set[int]) -> dict[int, str]:
        groups: dict[str, list[int]] = {"teacher": [], "student": [], "speaker": []}
        for speaker_id in sorted(speaker_ids):
            role = self.roles.get(speaker_id, ("speaker", 0))[0]
            groups[role if role in ("teacher", "student") else "speaker"].append(speaker_id)
        names: dict[int, str] = {}
        labels = {"teacher": "教授", "student": "学生", "speaker": "说话人"}
        for role, ids in groups.items():
            for rank, speaker_id in enumerate(ids, 1):
                names[speaker_id] = labels[role] + (str(rank) if len(ids) > 1 else "")
        return names
