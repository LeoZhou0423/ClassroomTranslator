"""Portable, deterministic transcript rules; no UI/audio/model dependencies."""
from __future__ import annotations
import re
from difflib import SequenceMatcher
from dataclasses import dataclass, field
from transcription_core import clean, acceptable, LocalAgreement


def token_spans(text):
    return list(re.finditer(r"\S+", text))


def normalized(text):
    return [re.sub(r"[^\w']", "", m.group().lower()) for m in token_spans(text)]


class AudioWindowOwners:
    """Immutable ownership keyed by VAD's absolute sample origin."""
    def __init__(self): self.origins = {}
    def owner(self,start):
        if start not in self.origins: self.origins[start] = len(self.origins)
        return self.origins[start]


def reconcile_boundary(previous, current, bridge):
    """Use an audio-boundary re-decode only with independent anchors on BOTH sides.

    No guessed words or global duplicate removal: unmatched bridge hypotheses
    leave both original utterances intact.
    """
    a,b,c = normalized(previous),normalized(current),normalized(bridge)
    if not a or not b or not c: return None
    offset = max(0,len(a)-60)
    left = [m for m in SequenceMatcher(None,a[offset:],c,autojunk=False).get_matching_blocks() if m.size >= 4]
    right = [m for m in SequenceMatcher(None,b[:60],c,autojunk=False).get_matching_blocks() if m.size >= 4]
    candidates = [(l,r) for l in left for r in right if l.b+l.size <= r.b and l.a+offset+l.size >= len(a)-35 and r.a <= 20]
    if not candidates: return None
    l,r = max(candidates,key=lambda p:p[0].size+p[1].size)
    asp,bsp,csp = token_spans(previous),token_spans(current),token_spans(bridge)
    # Keep the right anchor in its original utterance; assign the recovered
    # boundary passage to the preceding utterance exactly once.
    left_text = previous[:asp[offset+l.a].start()] + bridge[csp[l.b].start():csp[r.b].start()].strip()
    right_text = current[bsp[r.a].start():]
    return clean(left_text),clean(right_text)


def preserve_snapshot(previous, current):
    previous, current = clean(previous), clean(current)
    if not current: return previous
    if not previous: return current
    old, new = normalized(previous), normalized(current)
    if new[:len(old)] == old: return current
    if old[:len(new)] == new: return previous
    for count in range(min(len(old), len(new)), 1, -1):
        if old[-count:] == new[:count]:
            spans = token_spans(current)
            return previous if count == len(spans) else previous + " " + current[spans[count].start():]
    # A short final often contains only the tail; retain the displayed prefix.
    return previous if len(new) < len(old) else current


def accepted_english(text):
    text = re.sub(r"[\[(](?:music|noise|silence|applause|laughter|inaudible|video playback|static|audio out|blank_audio|no_speech)[\])]", "", text, flags=re.I)
    text = clean(text)
    if text.lower().strip(".!? ") in {"music", "noise", "silence", "inaudible"}: return ""
    letters = sum(c.isalpha() for c in text)
    foreign = len(re.findall(r"[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]", text))
    if letters and foreign / letters > .2: return ""
    return text if acceptable(text) else ""


def sentence_units(text, include_tail=True):
    units, start = [], 0
    for match in re.finditer(r"[.!?。！？]+[\"'”’]*(?=\s|$)", text):
        preceding = re.search(r"([A-Za-z]+)$",text[:match.start()])
        if match.group() == "." and preceding and preceding.group(1).lower() in {"mr","mrs","ms","dr","prof","sr","jr"} and text[match.end():].strip(): continue
        # A digit before and after a period denotes a decimal, not a boundary.
        if match.group() == "." and match.start() > 0 and text[match.start()-1].isdigit() and match.end() < len(text) and text[match.end()].isdigit(): continue
        unit = text[start:match.end()].strip()
        if unit: units.append(unit)
        start = match.end()
    tail = text[start:].strip()
    if include_tail and tail: units.append(tail)
    return units


@dataclass
class Utterance:
    identifier: int
    start: float = 0.0
    best: str = ""
    stable: str = ""
    final: bool = False
    agreement: LocalAgreement = field(default_factory=LocalAgreement)

    def update(self, text, final=False, revision=False, full_window=False, allow_trim=False):
        previous_best = self.best
        previous_stable_count = len(token_spans(self.stable))
        if self.final and not revision: return  # Late partials cannot reopen a completed utterance.
        if revision:
            self.final = False
        if full_window and clean(text):
            # The decoder has re-read the same audio origin: this is a
            # replacement snapshot, never an incremental text fragment.
            new = clean(text)
            old_words,new_words = normalized(self.best),normalized(new)
            # A severe suffix-only result is not a complete replacement. Keep
            # the displayed prefix if the final decoder returns only its tail.
            suffix_only = not allow_trim and len(old_words) >= 10 and len(new_words) < len(old_words)/2 and len(new_words) >= 2 and old_words[-len(new_words):] == new_words
            self.best = self.best if suffix_only else new
            stable_words,current_words = normalized(self.stable),normalized(self.best)
            # Map the displayed frontier through local insertions/deletions.
            # A changed word must not destabilize the rest of the sentence.
            mapped = 0
            matcher = SequenceMatcher(None, normalized(previous_best), current_words, autojunk=False)
            for tag,a0,a1,b0,b1 in matcher.get_opcodes():
                if a1 <= previous_stable_count:
                    mapped = max(mapped,b1)
                elif a0 < previous_stable_count and tag == 'equal':
                    mapped = max(mapped,b0+previous_stable_count-a0)
            spans = token_spans(self.best)
            self.stable = self.best[:spans[mapped-1].end()] if mapped and mapped <= len(spans) else ""
            self.agreement.stable = self.stable
        else:
            self.best = preserve_snapshot(self.best, text)
        if final:
            self.final = True
            self.stable = self.best
        else:
            self.stable, _ = self.agreement.update(self.best)
            # Confirm matching local blocks independently of edits near the
            # beginning. Leave the latest two words provisional when growing.
            blocks = SequenceMatcher(None, normalized(previous_best), normalized(self.best), autojunk=False).get_matching_blocks()
            local_frontier = max((b.b+b.size for b in blocks if b.size >= 3), default=0)
            if len(token_spans(self.best)) > len(token_spans(previous_best)):
                local_frontier = min(local_frontier,max(0,len(token_spans(self.best))-2))
            if local_frontier > len(token_spans(self.stable)):
                spans = token_spans(self.best)
                self.stable = self.best[:spans[local_frontier-1].end()]
            # Stable words can acquire revised punctuation without growing in
            # length. Render the punctuation from the current hypothesis.
            count = len(token_spans(self.stable))
            spans = token_spans(self.best)
            self.stable = self.best[:spans[count-1].end()] if count and count <= len(spans) else ""
            self.agreement.stable = self.stable

    def display(self):
        committed = self.best if self.final else " ".join(sentence_units(self.stable, False))
        rows = [{"id": f"{self.identifier}:{i}", "text": text, "utterance": self.identifier, "start": self.start, "final": self.final}
                for i, text in enumerate(sentence_units(committed))]
        spans = token_spans(self.best)
        count = len(token_spans(committed))
        tail = self.best[spans[count].start():] if count < len(spans) else ""
        stable_count = max(0, len(token_spans(self.stable)) - count)
        tail_spans = token_spans(tail)
        boundary = tail_spans[min(stable_count, len(tail_spans))-1].end() if stable_count and tail_spans else 0
        return rows, {"id": self.identifier, "stable": tail[:boundary].strip(), "unstable": tail[boundary:].strip()}


class TranscriptLedger:
    def __init__(self): self.entries = {}
    def update(self, identifier, text, final=False, start=0.0, revision=False, full_window=False, allow_trim=False):
        item = self.entries.setdefault(identifier, Utterance(identifier, start=start))
        item.update(text, final, revision, full_window, allow_trim)
    def finalize_all(self):
        for item in self.entries.values(): item.update("", True)
    def snapshot(self):
        rows, live = [], []
        for item in sorted(self.entries.values(), key=lambda x: x.identifier):
            pieces, tail = item.display()
            if rows and pieces and rows[-1]["final"] and pieces[0]["final"] and (rows[-1]["text"].rstrip().endswith(("...","…","--","—")) or not re.search(r"[.!?。！？][\"']?$",rows[-1]["text"])):
                # An audio window ending is not a sentence boundary.
                rows[-1]["text"] = rows[-1]["text"].rstrip("-—… ").removesuffix("...")+" "+pieces.pop(0)["text"]
            rows.extend(pieces)
            if tail["stable"] or tail["unstable"]: live.append(tail)
        return rows, live
    def text(self):
        if all(item.final for item in self.entries.values()):
            return "\n".join(row["text"] for row in self.snapshot()[0])
        # Export in audio order, including unfinished text in its own position.
        # Moving all live tails after all final rows silently reorders speech.
        return "\n".join("\n".join(sentence_units(item.best)) for item in
                         sorted(self.entries.values(),key=lambda x:x.identifier) if item.best)
