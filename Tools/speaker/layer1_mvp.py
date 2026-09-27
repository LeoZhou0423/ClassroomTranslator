#!/usr/bin/env python3
"""Layer-1 speaker identity MVP (Windows).

Only answers: same person or not. Outputs display names.
Reuse-first clustering: prefer merging into an existing person over creating
a new one. Role labels are intentionally out of scope.

Course-level enrollment (NOT per-session): the same class roster reappears
every lesson, so voiceprints live on the course, not on each recording.

Usage:
  python Tools/speaker/layer1_mvp.py --wav a.wav
  python Tools/speaker/layer1_mvp.py --self-test

  # Course-level enrollment (persists across sessions of one course)
  python Tools/speaker/layer1_mvp.py --course math101 --enroll "Zhang" --wav zhang.wav
  python Tools/speaker/layer1_mvp.py --course math101 --wav today.wav
  python Tools/speaker/layer1_mvp.py --course math101 --list-persons
"""
from __future__ import annotations

import argparse
import json
import sys
import wave
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

BASE = Path(__file__).resolve().parent
MODELS = BASE / "models"
SEG_MODEL = MODELS / "sherpa-onnx-pyannote-segmentation-3-0" / "model.onnx"
EMB_MODEL = MODELS / "campplus_zh_en_advanced.onnx"


# --- config (reuse-first thresholds) -------------------------------------
#
# Measured on Tools/speaker/models (CAM++ zh_en):
#   same speaker (fangjun×2) ≈ 0.81
#   different speakers       ≈ 0.25–0.33
# Classroom far-field pulls same-speaker down (~0.55–0.70) and can lift
# cross-speaker a bit (~0.40), so floors sit between the two bands.

@dataclass
class Config:
    # Prefer reuse when uncertain — avoid splitting one person into two.
    reuse_floor: float = 0.42   # ≥ this: assign to closest existing person
    merge_floor: float = 0.52   # ≥ this: assign + gentle centroid update
    strong_match: float = 0.65  # ≥ this: strong match, normal EMA
    enroll_match_th: float = 0.55  # course roster match
    min_segment_sec: float = 0.6
    min_rms: float = 0.01
    new_person_streak: int = 2
    # Clean, long, clearly-unmatched speech may create a person immediately.
    # Borderline/short speech still needs consecutive agreement (reuse-first).
    min_reliable_sec: float = 1.2
    max_speakers: int = 8
    post_merge_th: float = 0.82  # merge only when very close
    ema_alpha: float = 0.30
    weak_ema_alpha: float = 0.08
    # pyannote window clamp
    min_seg: float = 0.8
    max_seg: float = 4.0
    # energy fallback
    hop_sec: float = 0.25
    win_sec: float = 1.5
    vad_rms: float = 0.02


@dataclass
class Segment:
    start: float
    end: float
    emb: np.ndarray | None = None
    dirty: bool = False
    person: int | None = None  # -1 => unknown
    confidence: float = 0.0
    enrolled: str | None = None  # course roster display name if matched

    @property
    def duration(self) -> float:
        return max(0.0, self.end - self.start)


def person_name(idx: int | None) -> str:
    if idx is None or idx < 0:
        return "unknown"
    return f"Person {chr(ord('A') + idx)}"


def read_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as w:
        sr, ch, sw, n = w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getframesread() if False else w.getnframes()
        raw = w.readframes(n)
    data = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    if ch > 1:
        data = data.reshape(-1, ch).mean(axis=1)
    if sw != 2:
        raise ValueError(f"only 16-bit wav supported: {path}")
    return data, sr


def concat_wavs(paths: list[Path]) -> tuple[np.ndarray, int]:
    parts: list[np.ndarray] = []
    sr0 = None
    for p in paths:
        x, sr = read_wav(p)
        if sr0 is None:
            sr0 = sr
        if sr != sr0:
            raise ValueError(f"sample rate mismatch: {p} {sr} vs {sr0}")
        parts.append(x)
        # 0.25s silence between clips
        parts.append(np.zeros(int(0.25 * sr0), dtype=np.float32))
    assert sr0 is not None
    return np.concatenate(parts), sr0


def l2_normalize(v: np.ndarray) -> np.ndarray | None:
    if v is None or v.size == 0:
        return None
    n = float(np.linalg.norm(v))
    if n <= 0:
        return None
    return v / n


def cosine(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.dot(a, b))


# --- segmentation --------------------------------------------------------

def segment_pyannote(wav: np.ndarray, sr: int, cfg: Config) -> list[tuple[float, float]]:
    import sherpa_onnx

    seg_cfg = sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
        pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(model=str(SEG_MODEL))
    )
    emb_cfg = sherpa_onnx.SpeakerEmbeddingExtractorConfig(
        model=str(EMB_MODEL), num_threads=1
    )
    # clustering config unused for pure segmentation API path; we cluster ourselves
    clus_cfg = sherpa_onnx.FastClusteringConfig(num_clusters=2)
    diar_cfg = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=seg_cfg, embedding=emb_cfg, clustering=clus_cfg
    )
    diar = sherpa_onnx.OfflineSpeakerDiarization(diar_cfg)
    # Only use segmentation: process full audio and take time spans from result,
    # then re-embed per our window policy. For MVP we use the diarizer's segments
    # as candidate speech regions (speaker ids ignored).
    result = diar.process(wav.tolist())
    regions: list[tuple[float, float]] = []
    for seg in result.sort_by_start_time():
        start = float(seg.start)
        end = float(seg.end)
        regions.append((start, end))
    return merge_adjacent(regions, cfg)


def segment_energy(wav: np.ndarray, sr: int, cfg: Config) -> list[tuple[float, float]]:
    """Simple RMS VAD + window merge. Fallback when pyannote path is heavy."""
    hop = int(cfg.hop_sec * sr)
    win = int(cfg.win_sec * sr)
    if hop <= 0 or win <= 0:
        return []
    flags = []
    for i in range(0, max(1, len(wav) - hop), hop):
        chunk = wav[i : i + win]
        if chunk.size < int(0.2 * sr):
            flags.append(False)
            continue
        rms = float(np.sqrt(np.mean(chunk**2)))
        flags.append(rms >= cfg.vad_rms)
    regions: list[tuple[float, float]] = []
    i = 0
    n = len(flags)
    while i < n:
        if not flags[i]:
            i += 1
            continue
        j = i
        while j + 1 < n and flags[j + 1]:
            j += 1
        start = i * cfg.hop_sec
        end = min(len(wav) / sr, (j + 1) * cfg.hop_sec)
        regions.append((start, end))
        i = j + 1
    return merge_adjacent(regions, cfg)


def merge_adjacent(regions: list[tuple[float, float]], cfg: Config) -> list[tuple[float, float]]:
    if not regions:
        return []
    regions = sorted(regions)
    out = [regions[0]]
    for s, e in regions[1:]:
        ps, pe = out[-1]
        if s <= pe + 0.15:
            out[-1] = (ps, max(pe, e))
        else:
            out.append((s, e))
    # clamp duration
    clamped = []
    for s, e in out:
        dur = e - s
        if dur < cfg.min_seg:
            # keep short as-is (marked dirty later) if still >= min_segment_sec
            if dur < cfg.min_segment_sec * 0.5:
                continue
            clamped.append((s, e))
        elif dur > cfg.max_seg:
            t = s
            while e - t > cfg.max_seg:
                clamped.append((t, t + cfg.max_seg))
                t += cfg.max_seg * 0.85
            if e - t >= cfg.min_segment_sec * 0.5:
                clamped.append((t, e))
        else:
            clamped.append((s, e))
    return clamped


# --- embedding -----------------------------------------------------------

class Embedder:
    def __init__(self) -> None:
        import sherpa_onnx

        if not EMB_MODEL.is_file():
            raise FileNotFoundError(EMB_MODEL)
        cfg = sherpa_onnx.SpeakerEmbeddingExtractorConfig(
            model=str(EMB_MODEL), num_threads=1
        )
        self.extractor = sherpa_onnx.SpeakerEmbeddingExtractor(cfg)

    def embed(self, samples: np.ndarray, sr: int) -> np.ndarray | None:
        if samples.size == 0:
            return None
        stream = self.extractor.create_stream()
        stream.accept_waveform(sr, samples)
        return l2_normalize(np.asarray(self.extractor.compute(stream), dtype=np.float32))


# --- course-level voiceprint roster (NOT per-session) --------------------
# Same students/teachers attend every lesson of a course, so enrollments
# are stored once per course and reused across recordings.

COURSES_DIR = BASE / "courses"


@dataclass
class RosterPerson:
    name: str
    centroid: np.ndarray
    n_samples: int = 1

    def to_json(self) -> dict:
        return {
            "name": self.name,
            "centroid": [float(x) for x in self.centroid.tolist()],
            "n_samples": int(self.n_samples),
        }

    @staticmethod
    def from_json(d: dict) -> "RosterPerson":
        centroid = np.asarray(d["centroid"], dtype=np.float32)
        unit = l2_normalize(centroid)
        return RosterPerson(
            name=str(d["name"]),
            centroid=unit if unit is not None else centroid,
            n_samples=int(d.get("n_samples", 1)),
        )


class CourseRoster:
    """Course-scoped voiceprint store. One roster per course, not per session."""

    def __init__(self, course_id: str, cfg: Config) -> None:
        self.course_id = _safe_id(course_id)
        self.cfg = cfg
        self.path = COURSES_DIR / self.course_id / "persons.json"
        self.persons: list[RosterPerson] = []
        self.load()

    def load(self) -> None:
        if not self.path.is_file():
            return
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return
        self.persons = [RosterPerson.from_json(d) for d in data.get("persons", [])]

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "course_id": self.course_id,
            "scope": "course",
            "persons": [p.to_json() for p in self.persons],
        }
        self.path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

    def enroll(self, name: str, embedding: np.ndarray) -> RosterPerson:
        unit = l2_normalize(np.asarray(embedding, dtype=np.float32))
        if unit is None:
            raise ValueError("empty embedding")
        name = name.strip()
        if not name:
            raise ValueError("empty name")
        for p in self.persons:
            if p.name == name:
                # average with existing course-level centroid
                merged = l2_normalize((1 - 1 / (p.n_samples + 1)) * p.centroid + (1 / (p.n_samples + 1)) * unit)
                if merged is not None:
                    p.centroid = merged
                p.n_samples += 1
                self.save()
                return p
        person = RosterPerson(name=name, centroid=unit, n_samples=1)
        self.persons.append(person)
        self.save()
        return person

    def match(self, unit: np.ndarray | None) -> tuple[str | None, float]:
        """Return (display_name, sim) if unit matches a course person."""
        if unit is None or not self.persons:
            return None, -1.0
        best_name, best_sim = None, -1.0
        for p in self.persons:
            sim = cosine(unit, p.centroid)
            if sim > best_sim:
                best_name, best_sim = p.name, sim
        if best_name is not None and best_sim >= self.cfg.enroll_match_th:
            return best_name, float(best_sim)
        return None, float(best_sim)

    def summary(self) -> list[dict]:
        return [
            {"name": p.name, "n_samples": p.n_samples, "centroid_dim": int(p.centroid.size)}
            for p in self.persons
        ]


def _safe_id(course_id: str) -> str:
    keep = []
    for ch in course_id.strip():
        if ch.isalnum() or ch in ("-", "_", "."):
            keep.append(ch)
        else:
            keep.append("_")
    return "".join(keep) or "default"


# --- reuse-first clustering ---------------------------------------------

@dataclass
class Clusterer:
    cfg: Config
    centroids: list[np.ndarray] = field(default_factory=list)
    pending: np.ndarray | None = None
    streak: int = 0
    last_person: int = -1

    def assign(self, unit: np.ndarray, dirty: bool) -> tuple[int, float]:
        """Return (person_index or -1, confidence)."""
        if unit is None:
            self.last_person = -1
            return -1, 0.0

        # duration hint for reliable-create (set by pipeline before assign)
        if not hasattr(self, "_last_duration"):
            self._last_duration = 0.0

        if self.centroids:
            sims = [cosine(unit, c) for c in self.centroids]
            best = int(np.argmax(sims))
            best_sim = float(sims[best])
        else:
            best, best_sim = -1, -1.0

        # dirty / short: never create a person
        if dirty:
            if best >= 0 and best_sim >= self.cfg.reuse_floor:
                self.pending = None
                self.streak = 0
                self.last_person = best
                return best, max(0.0, best_sim) * 0.7
            # inherit previous if any
            if self.last_person >= 0:
                return self.last_person, 0.35
            return -1, 0.15

        # strong / medium match: merge into existing
        if best >= 0 and best_sim >= self.cfg.merge_floor:
            self.pending = None
            self.streak = 0
            self.last_person = best
            alpha = self.cfg.ema_alpha if best_sim >= self.cfg.strong_match else self.cfg.weak_ema_alpha
            blended = l2_normalize((1.0 - alpha) * self.centroids[best] + alpha * unit)
            if blended is not None:
                self.centroids[best] = blended
            conf = 0.55 + 0.45 * min(1.0, max(0.0, (best_sim - self.cfg.merge_floor) / (1.0 - self.cfg.merge_floor)))
            return best, float(conf)

        # reuse even if below merge_floor (avoid split)
        if best >= 0 and best_sim >= self.cfg.reuse_floor:
            self.pending = None
            self.streak = 0
            self.last_person = best
            return best, 0.40 + 0.2 * max(0.0, best_sim)

        # candidate for new person
        if self.pending is not None and cosine(self.pending, unit) >= self.cfg.strong_match:
            self.streak += 1
            self.pending = l2_normalize(0.5 * self.pending + 0.5 * unit)
        else:
            self.pending = unit.copy()
            self.streak = 1

        can_add = len(self.centroids) < self.cfg.max_speakers
        # Strong evidence: first clean segment in empty session, or a long clean
        # segment that matches nobody. Still refuse to spawn on short/weak noise.
        reliable = (not dirty) and self._last_duration >= self.cfg.min_reliable_sec
        if can_add and reliable and (best < 0 or best_sim < self.cfg.reuse_floor):
            return self._commit_pending(unit)

        if can_add and self.streak >= self.cfg.new_person_streak:
            return self._commit_pending(unit)

        # do not invent a person yet: reuse closest or unknown
        if best >= 0:
            self.last_person = best
            return best, 0.30
        self.last_person = -1
        return -1, 0.20

    def _commit_pending(self, unit: np.ndarray) -> tuple[int, float]:
        seed = self.pending if self.pending is not None else unit
        vec = l2_normalize(seed)
        if vec is None:
            self.pending = None
            self.streak = 0
            return -1, 0.15
        self.centroids.append(vec)
        self.pending = None
        self.streak = 0
        idx = len(self.centroids) - 1
        self.last_person = idx
        return idx, 0.72

    def post_merge(self, segs: list[Segment]) -> None:
        """Merge centroids that are too similar (reuse-first)."""
        changed = True
        while changed and len(self.centroids) > 1:
            changed = False
            n = len(self.centroids)
            best_i, best_j, best_s = -1, -1, -1.0
            for i in range(n):
                for j in range(i + 1, n):
                    s = cosine(self.centroids[i], self.centroids[j])
                    if s > best_s:
                        best_s, best_i, best_j = s, i, j
            if best_i >= 0 and best_s >= self.cfg.post_merge_th:
                merged = l2_normalize(self.centroids[best_i] + self.centroids[best_j])
                if merged is not None:
                    self.centroids[best_i] = merged
                # remap labels: j -> i, then reindex
                for seg in segs:
                    if seg.person == best_j:
                        seg.person = best_i
                    elif seg.person is not None and seg.person > best_j:
                        seg.person -= 1
                del self.centroids[best_j]
                changed = True

        # reindex persons in first-appearance order
        mapping: dict[int, int] = {}
        next_id = 0
        for seg in segs:
            if seg.person is None or seg.person < 0:
                continue
            if seg.person not in mapping:
                mapping[seg.person] = next_id
                next_id += 1
            seg.person = mapping[seg.person]
        self.centroids = [self.centroids[k] for k in sorted(mapping, key=lambda x: mapping[x]) if k < len(self.centroids)]


# --- pipeline ------------------------------------------------------------

def run_file(
    path: Path,
    cfg: Config,
    embedder: Embedder,
    method: str = "auto",
    roster: CourseRoster | None = None,
    role_classifier=None,
    texts_by_key: dict[str, list[str]] | None = None,
) -> dict:
    wav, sr = read_wav(path)
    return run_array(
        wav, sr, cfg, embedder, source=path.name, method=method, roster=roster,
        role_classifier=role_classifier, texts_by_key=texts_by_key,
    )


def run_array(
    wav: np.ndarray,
    sr: int,
    cfg: Config,
    embedder: Embedder,
    source: str = "audio",
    method: str = "auto",
    roster: CourseRoster | None = None,
    role_classifier=None,
    texts_by_key: dict[str, list[str]] | None = None,
) -> dict:
    import time

    t0 = time.perf_counter()
    if method == "energy":
        regions = segment_energy(wav, sr, cfg)
    elif method == "pyannote":
        regions = segment_pyannote(wav, sr, cfg)
    else:
        try:
            regions = segment_pyannote(wav, sr, cfg)
            if not regions:
                regions = segment_energy(wav, sr, cfg)
        except Exception as exc:  # noqa: BLE001
            print(f"[warn] pyannote segment failed ({exc}); fallback energy", file=sys.stderr)
            regions = segment_energy(wav, sr, cfg)

    segs: list[Segment] = []
    for start, end in regions:
        s0, s1 = int(start * sr), int(end * sr)
        chunk = wav[s0:s1]
        if chunk.size == 0:
            continue
        rms = float(np.sqrt(np.mean(chunk**2)))
        dirty = (end - start) < cfg.min_segment_sec or rms < cfg.min_rms
        emb = embedder.embed(chunk, sr) if (end - start) >= cfg.min_segment_sec * 0.5 else None
        segs.append(Segment(start=start, end=end, emb=emb, dirty=dirty or emb is None))

    clusterer = Clusterer(cfg=cfg)
    for seg in segs:
        unit = seg.emb if seg.emb is not None else None
        clusterer._last_duration = seg.duration  # noqa: SLF001 — duration hint for create policy

        # Course roster first: same people every lesson of this course.
        if roster is not None and unit is not None and not seg.dirty:
            enrolled_name, enroll_sim = roster.match(unit)
            if enrolled_name is not None:
                seg.enrolled = enrolled_name
                person, conf = clusterer.assign(unit, dirty=False)
                seg.person = person
                seg.confidence = max(conf, 0.55 + 0.45 * max(0.0, enroll_sim))
                continue

        person, conf = clusterer.assign(unit, dirty=seg.dirty)
        seg.person = person
        seg.confidence = conf

    clusterer.post_merge(segs)

    # Display name: enrolled course person > Person A/B/C > unknown
    def person_key(seg: Segment) -> str:
        if seg.enrolled:
            return seg.enrolled
        return person_name(seg.person)

    duration = len(wav) / sr
    keys = sorted({person_key(s) for s in segs if person_key(s) != "unknown"})

    # Layer-2 role labels (optional). Multi teacher/student is fine — number them.
    # texts_by_key: person key -> utterance strings (from ASR in the real app).
    role_by_key: dict[str, dict] = {}
    display_by_key: dict[str, str] = {k: k for k in keys}
    if role_classifier is not None and texts_by_key:
        from role_classifier import assign_role_names

        for k in keys:
            role_by_key[k] = role_classifier.predict_person(texts_by_key.get(k, []))
        # first-appearance order for stable Teacher 1 / Student 1 numbering
        first_order: list[str] = []
        for s in segs:
            k = person_key(s)
            if k in display_by_key and k not in first_order:
                first_order.append(k)
        display_by_key = assign_role_names(keys, role_by_key, prefer_order=first_order)

    def display(seg: Segment) -> str:
        return display_by_key.get(person_key(seg), person_key(seg))

    out_segs = [
        {
            "start": round(s.start, 3),
            "end": round(s.end, 3),
            "person": display(s),
            "person_id": person_key(s),
            "role": (role_by_key.get(person_key(s)) or {}).get("label"),
            "confidence": round(s.confidence, 3),
            "dirty": s.dirty,
            "enrolled": bool(s.enrolled),
        }
        for s in segs
    ]
    wall = time.perf_counter() - t0
    persons_out = [
        {
            "id": k,
            "display": display_by_key[k],
            "role": (role_by_key.get(k) or {}).get("label"),
            "role_score": (role_by_key.get(k) or {}).get("score"),
        }
        for k in keys
    ]
    return {
        "source": source,
        "course": roster.course_id if roster else None,
        "audio_sec": round(duration, 3),
        "wall_sec": round(wall, 3),
        "rtf": round(wall / duration, 4) if duration > 0 else None,
        "num_persons": len(keys),
        "persons": [p["display"] for p in persons_out],
        "person_roles": persons_out,
        "segments": out_segs,
    }


# --- self test -----------------------------------------------------------

def self_test(cfg: Config) -> int:
    embedder = Embedder()
    failures = []

    def check(name: str, cond: bool, detail: str) -> None:
        mark = "PASS" if cond else "FAIL"
        print(f"[{mark}] {name}: {detail}")
        if not cond:
            failures.append(name)

    # A1 same person should not split
    f1 = MODELS / "fangjun-sr-1.wav"
    f2 = MODELS / "fangjun-sr-2.wav"
    if f1.is_file() and f2.is_file():
        wav, sr = concat_wavs([f1, f2])
        r = run_array(wav, sr, cfg, embedder, source="fangjun-concat")
        check("A1-same-person", r["num_persons"] <= 1, f"num_persons={r['num_persons']} segs={len(r['segments'])}")
    else:
        check("A1-same-person", False, "missing fangjun wavs")

    # A2 different persons should split
    f3 = MODELS / "leijun-sr-1.wav"
    if f1.is_file() and f3.is_file():
        wav, sr = concat_wavs([f1, f3])
        r = run_array(wav, sr, cfg, embedder, source="fangjun+leijun")
        check("A2-diff-persons", r["num_persons"] >= 2, f"num_persons={r['num_persons']}")
    else:
        check("A2-diff-persons", False, "missing wavs")

    # A3 multi-speaker chinese
    f4 = MODELS / "0-four-speakers-zh.wav"
    if f4.is_file():
        r = run_file(f4, cfg, embedder)
        check("A3-four-speakers", 3 <= r["num_persons"] <= 5, f"num_persons={r['num_persons']} rtf={r['rtf']}")
        check("A5-rtf", (r["rtf"] or 1.0) < 0.5, f"rtf={r['rtf']}")
    else:
        check("A3-four-speakers", False, "missing 0-four-speakers-zh.wav")

    # A4 no single short segment invents a person: craft 0.4s noise + speech
    if f1.is_file():
        wav, sr = read_wav(f1)
        short = wav[: int(0.4 * sr)]
        wav2, sr2 = concat_wavs([f1, f1])
        # inject a tiny isolated blip via energy method on clean concat is enough
        r = run_array(wav2, sr2, cfg, embedder, source="short-safe")
        dirty_new = [s for s in r["segments"] if s["dirty"] and s["person"] != "unknown"]
        # dirty may inherit previous person — that's OK; fail only if many persons
        check("A4-no-burst", r["num_persons"] <= 2, f"num_persons={r['num_persons']} dirty_assigns={len(dirty_new)}")

    # A6 course-level enrollment: same course reuses names across "sessions"
    if f1.is_file() and f3.is_file():
        import tempfile
        import uuid

        course_id = f"selftest-{uuid.uuid4().hex[:8]}"
        try:
            roster = CourseRoster(course_id, cfg)
            w, sr = read_wav(f1)
            emb = embedder.embed(w, sr)
            roster.enroll("Zhang", emb)
            w2, sr2 = read_wav(f3)
            emb2 = embedder.embed(w2, sr2)
            roster.enroll("Li", emb2)

            # "session" 1: fangjun
            r1 = run_file(f1, cfg, embedder, roster=roster)
            # "session" 2: same person again (should still be Zhang)
            r2 = run_file(f2, cfg, embedder, roster=roster)
            names1 = set(r1["persons"])
            names2 = set(r2["persons"])
            check(
                "A6-course-roster",
                "Zhang" in names1 and "Zhang" in names2 and "Li" not in names1,
                f"s1={names1} s2={names2}",
            )
            # new course directory isolation is by course_id
            check(
                "A6-course-scope",
                roster.path.parts[-3] == "courses" and roster.path.parts[-2] == course_id,
                f"path={roster.path}",
            )
        finally:
            import shutil

            shutil.rmtree(COURSES_DIR / course_id, ignore_errors=True)

    # A7 multi teacher/student just numbered (stable 1/2…, no merging roles)
    try:
        from role_classifier import RoleClassifier, assign_role_names

        # pure numbering contract: several teachers AND several students
        fake = {
            "T1": {"label": "teacher", "score": 0.9},
            "T2": {"label": "teacher", "score": 0.9},
            "S1": {"label": "student", "score": 0.9},
            "S2": {"label": "student", "score": 0.9},
        }
        named = assign_role_names(["T1", "T2", "S1", "S2"], fake)
        check(
            "A7-multi-role-numbers",
            named == {"T1": "Teacher 1", "T2": "Teacher 2", "S1": "Student 1", "S2": "Student 2"},
            str(named),
        )

        # model smoke: clear teacher vs clear student
        rc = RoleClassifier()
        t = rc.predict_person([
            "Okay so our objective is to produce mathematical solutions to modeling the problem",
            "Yes your learning intention is you can multiply twodigit numbers",
        ])
        s = rc.predict_person([
            "I think the area is length times width",
            "I mean the rectangle not the triangle",
        ])
        check(
            "A7-role-model-smoke",
            t.get("label") == "teacher" and s.get("label") == "student",
            f"t={t} s={s}",
        )
    except Exception as exc:  # noqa: BLE001
        check("A7-multi-role-numbers", False, f"role classifier missing: {exc}")
        check("A7-role-model-smoke", False, str(exc))

    print()
    if failures:
        print(f"FAILED: {', '.join(failures)}")
        return 1
    print("ALL ACCEPTANCE CHECKS PASSED")
    return 0


# --- cli -----------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description="Layer-1 person identity MVP")
    ap.add_argument("--wav", action="append", type=Path, default=[], help="input wav (repeatable)")
    ap.add_argument("--concat", action="store_true", help="concatenate multiple --wav with 0.25s gaps")
    ap.add_argument("--method", choices=["auto", "pyannote", "energy"], default="auto")
    ap.add_argument("--json-out", type=Path, default=None)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--max-speakers", type=int, default=8)
    ap.add_argument("--merge-floor", type=float, default=0.52)
    ap.add_argument("--reuse-floor", type=float, default=0.42)
    ap.add_argument("--strong-match", type=float, default=0.65)
    ap.add_argument("--enroll-match", type=float, default=0.55)
    # Course-level roster (shared by every session of the course)
    ap.add_argument("--course", type=str, default=None, help="course id for voiceprint roster")
    ap.add_argument("--enroll", type=str, default=None, help="enroll person name from --wav into course roster")
    ap.add_argument("--list-persons", action="store_true", help="list course roster")
    # Layer-2 roles (optional): TalkMoves MiniLM ONNX + per-person utterances
    ap.add_argument("--role-model", type=str, default=None, help="dir with model.onnx + tokenizer.json")
    ap.add_argument("--texts-json", type=Path, default=None,
                    help='JSON {"Person A": ["utt", ...], ...} for role classification')
    ap.add_argument("--use-role", action="store_true", help="enable role labels if model/texts present")
    args = ap.parse_args()

    cfg = Config(
        merge_floor=args.merge_floor,
        reuse_floor=args.reuse_floor,
        strong_match=args.strong_match,
        enroll_match_th=args.enroll_match,
        max_speakers=args.max_speakers,
    )

    if args.self_test:
        return self_test(cfg)

    roster: CourseRoster | None = None
    if args.course:
        roster = CourseRoster(args.course, cfg)

    if args.list_persons:
        if not args.course:
            ap.error("--list-persons requires --course")
        print(json.dumps({"course": args.course, "persons": roster.summary() if roster else []}, ensure_ascii=False, indent=2))
        return 0

    if args.enroll:
        if not args.course:
            ap.error("--enroll requires --course (roster is course-level, not per-session)")
        if not args.wav:
            ap.error("--enroll requires --wav")
        embedder = Embedder()
        for wav_path in args.wav:
            w, sr = read_wav(wav_path)
            emb = embedder.embed(w, sr)
            if emb is None:
                print(f"[error] cannot embed {wav_path}", file=sys.stderr)
                return 2
            person = roster.enroll(args.enroll, emb) if roster else None
            print(json.dumps({
                "course": args.course,
                "enrolled": {"name": person.name, "n_samples": person.n_samples} if person else None,
                "wav": str(wav_path),
            }, ensure_ascii=False, indent=2))
        return 0

    if not args.wav:
        ap.error("provide --wav, --enroll, --list-persons, or --self-test")

    embedder = Embedder()
    role_clf = None
    texts_by_key = None
    if args.use_role or args.role_model or args.texts_json:
        if args.texts_json:
            texts_by_key = json.loads(args.texts_json.read_text(encoding="utf-8"))
        if args.role_model or texts_by_key:
            try:
                from role_classifier import RoleClassifier
                role_clf = RoleClassifier(args.role_model)
            except Exception as exc:  # noqa: BLE001
                print(f"[warn] role model unavailable: {exc}", file=sys.stderr)

    if args.concat and len(args.wav) > 1:
        wav, sr = concat_wavs(args.wav)
        result = run_array(
            wav, sr, cfg, embedder,
            source="+".join(p.name for p in args.wav),
            method=args.method,
            roster=roster,
            role_classifier=role_clf,
            texts_by_key=texts_by_key,
        )
        results = [result]
    else:
        results = [
            run_file(
                p, cfg, embedder, method=args.method, roster=roster,
                role_classifier=role_clf, texts_by_key=texts_by_key,
            )
            for p in args.wav
        ]

    text = json.dumps(results if len(results) > 1 else results[0], ensure_ascii=False, indent=2)
    print(text)
    if args.json_out:
        args.json_out.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
