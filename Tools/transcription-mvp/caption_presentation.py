"""Append-only live captions. Working hypotheses stay in a single preview."""

import time
from copy import deepcopy

from sentence_boundary import boundary_state, continues_previous


class CaptionPresentation:
    def __init__(self):
        self.reset()

    def reset(self):
        self.rows = []
        self.language = {}
        self.speakers = {}
        self.consumed = set()
        self.observed = {}

    def snapshot(self, rows, language, speakers, live, phase, now=None, paused=True):
        now = time.monotonic() if now is None else now
        source = {member: r for r in rows for member in (r.get("source_members") or [r["id"]])}
        for index, row in enumerate(rows):
            identifier = row["id"]
            if identifier in self.consumed:
                continue
            translated = language.get(identifier, {})
            members = list(
                dict.fromkeys(
                    (translated.get("members") or [identifier])
                    + (row.get("source_members") or [identifier])
                )
            )
            if any(member in self.consumed for member in members):
                continue
            text = translated.get("english") or row["text"]
            signature = (text, translated.get("chinese"), tuple(members), translated.get("status"))
            old = self.observed.get(identifier)
            if old is None or old[0] != signature:
                self.observed[identifier] = (signature, now)
            original = translated.get("original") or row["text"]
            state = boundary_state(original)
            following = next((r["text"] for r in rows[index + 1 :] if r["id"] not in members), "")
            if not following and live:
                following = (live[0].get("stable", "") + " " + live[0].get("unstable", "")).strip()
            continued = bool(following and continues_previous(original, following))
            boundary = (state == "complete") or (
                state == "ambiguous" and bool(following) and not continued
            )
            # Generated punctuation cannot close a fragment; generated ellipses also veto commitment.
            boundary = boundary and boundary_state(text) != "incomplete"
            done = translated.get("status") == "done" and bool(
                translated.get("chinese") or translated.get("annotation_suppressed")
            )
            final = all(
                source.get(member, {}).get("final", False)
                and source.get(member, {}).get("review_status") != "checking"
                for member in members
            )
            if not (
                done and final and ((boundary and not continued) or phase in ("done", "error"))
            ):
                # Preserve audio order: later rows cannot jump ahead of this one.
                break
            self.rows.append(deepcopy(row))
            self.language[identifier] = deepcopy(translated)
            self.language[identifier]["members"] = list(members)
            utterance = str(row.get("utterance"))
            speaker = speakers.get(utterance, speakers.get(row.get("utterance")))
            if speaker is not None:
                self.speakers[utterance] = deepcopy(speaker)
                if speaker.get("role") not in ("teacher", "student"):
                    self.speakers[utterance]["label"] = ""
            else:
                self.speakers[utterance] = {"speaker_id": None, "role": "speaker", "label": ""}
            self.consumed.update(members)
        # An unknown first label may be filled once when the same voice is identified.
        known = {
            s.get("speaker_id"): s
            for s in speakers.values()
            if s.get("speaker_id") is not None and s.get("role") in ("teacher", "student")
        }
        for utterance, speaker in self.speakers.items():
            current = speakers.get(utterance, {})
            candidate = known.get(speaker.get("speaker_id")) or (
                current if current.get("role") in ("teacher", "student") else None
            )
            if not speaker.get("label") and candidate:
                speaker.update(deepcopy(candidate))
        preview = []
        hidden = set()
        for row in rows:
            identifier = row["id"]
            if identifier in self.consumed or identifier in hidden:
                continue
            item = language.get(identifier, {})
            hidden.update((item.get("members") or [identifier])[1:])
            text = (item.get("original") or row["text"]).strip()
            if text:
                preview.append(text)
        # Keep backend sentence units as separate provisional lines. Joining
        # them into one string makes fast speech look like a single long blob
        # that "refreshes" into different sentences.
        live_items = [
            {"id": f"preview-{index}", "stable": text, "unstable": ""}
            for index, text in enumerate(preview)
        ]
        for index, item in enumerate(live):
            stable = (item.get("stable") or "").strip()
            unstable = (item.get("unstable") or "").strip()
            if stable or unstable:
                live_items.append({"id": f"live-{index}", "stable": stable, "unstable": unstable})
        return {
            "rows": deepcopy(self.rows),
            "language_rows": deepcopy(self.language),
            "speaker_rows": deepcopy(self.speakers),
            "live": live_items,
        }
