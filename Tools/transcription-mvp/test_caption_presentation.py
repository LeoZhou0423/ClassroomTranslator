import unittest

from asr_core import TranscriptLedger, decode_window_start
from caption_presentation import CaptionPresentation
from live_language import group_rows
from sentence_boundary import boundary_state


class PresentationTests(unittest.TestCase):
    def test_vad_gap_does_not_discard_recorded_quiet_words(self):
        rate = 16000
        self.assertEqual(
            decode_window_start(int(31.348 * rate), int(22.412 * rate)), int(22.412 * rate)
        )
        self.assertGreaterEqual(decode_window_start(50 * rate, 20 * rate), 20 * rate)
        self.assertEqual(decode_window_start(rate, None), 0)

    def test_repaired_ellipsis_is_not_a_finished_sentence(self):
        original = "In a sense you could be."
        lang = self.language(original)
        lang["0:0"]["english"] = "In a sense, you could be..."
        result = CaptionPresentation().snapshot(
            self.source(original), lang, {}, [], "recording", now=0
        )
        self.assertEqual(result["rows"], [])

    def test_active_audio_review_cannot_be_sealed(self):
        rows = self.source()
        rows[0]["review_status"] = "checking"
        result = CaptionPresentation().snapshot(rows, self.language(), {}, [], "recording", now=0)
        self.assertEqual(result["rows"], [])

    def test_trailing_preposition_waits_for_names(self):
        self.assertEqual(
            boundary_state("In Aristotle and Plato and also perhaps a little bit in."), "incomplete"
        )

    def test_complete_sentence_needs_evidence_not_elapsed_time(self):
        p = CaptionPresentation()
        self.assertEqual(
            len(
                p.snapshot(
                    self.source(), self.language(), {}, [], "recording", now=0, paused=False
                )["rows"]
            ),
            1,
        )
        result = p.snapshot(
            self.source(), self.language(), {}, [], "recording", now=0.1, paused=True
        )
        self.assertEqual(len(result["rows"]), 1)

    def test_translation_error_is_not_frozen_and_retry_can_fill_chinese(self):
        p = CaptionPresentation()
        lang = self.language(status="error")
        lang["0:0"]["chinese"] = ""
        self.assertEqual(p.snapshot(self.source(), lang, {}, [], "recording", now=0)["rows"], [])
        result = p.snapshot(
            self.source(), self.language(), {}, [], "recording", now=0.1, paused=False
        )
        self.assertEqual(result["language_rows"]["0:0"]["chinese"], "完整句子。")

    def test_plato_sentence_commits_without_global_pause_or_next_sentence(self):
        text = "And we're going to look primarily at what Plato has to say about this, but we're going to cover a few other thinkers as well."
        result = CaptionPresentation().snapshot(
            self.source(text), self.language(text), {}, [], "recording", now=0, paused=False
        )
        self.assertEqual(len(result["rows"]), 1)
        self.assertTrue(result["language_rows"]["0:0"]["chinese"])

    def test_generated_period_cannot_complete_nominal_fragment(self):
        text = "One fundamental feature of experience"
        lang = self.language(text)
        lang["0:0"]["english"] = text + "."
        p = CaptionPresentation()
        result = p.snapshot(self.source(text), lang, {}, [], "recording", now=100)
        self.assertEqual(result["rows"], [])
        self.assertEqual(
            boundary_state("One fundamental feature of experience is change."), "complete"
        )

    def test_more_detail_continues_before_commit(self):
        p = CaptionPresentation()
        text = "We will go into a little bit more."
        rows = self.source(text) + [
            {"id": "1:0", "utterance": 1, "text": "More detail.", "final": True}
        ]
        self.assertEqual(
            p.snapshot(rows, self.language(text), {}, [], "recording", now=0)["rows"], []
        )
        self.assertEqual(len(group_rows(rows)), 1)

    def test_unknown_first_voice_is_labelled_once_after_identification(self):
        p = CaptionPresentation()
        speakers = {"0": {"speaker_id": 7, "role": "speaker", "label": "说话人"}}
        first = p.snapshot(self.source(), self.language(), speakers, [], "recording", now=0)
        self.assertEqual(first["speaker_rows"]["0"]["label"], "")
        speakers = {"0": {"speaker_id": 7, "role": "teacher", "label": "老师"}}
        second = p.snapshot(self.source(), self.language(), speakers, [], "recording", now=1)
        self.assertEqual(second["speaker_rows"]["0"]["label"], "老师")
        speakers = {"0": {"speaker_id": 7, "role": "student", "label": "学生"}}
        third = p.snapshot(self.source(), self.language(), speakers, [], "recording", now=2)
        self.assertEqual(third["speaker_rows"]["0"]["label"], "老师")

    def source(self, text="This is a complete sentence."):
        return [{"id": "0:0", "utterance": 0, "text": text, "final": True}]

    def language(self, text="This is a complete sentence.", status="done"):
        return {
            "0:0": {
                "english": text,
                "original": text,
                "chinese": "完整句子。",
                "members": ["0:0"],
                "status": status,
            }
        }

    def test_no_provisional_rows_are_committed(self):
        p = CaptionPresentation()
        s = p.snapshot(
            self.source(), self.language(status="translating"), {}, [], "recording", now=0
        )
        self.assertEqual(s["rows"], [])
        self.assertEqual(len(s["live"]), 1)
        s = p.snapshot(
            self.source(), self.language(status="translating"), {}, [], "recording", now=5
        )
        self.assertEqual(s["rows"], [])

    def test_committed_text_translation_and_role_are_immutable(self):
        p = CaptionPresentation()
        rows = self.source()
        lang = self.language()
        speakers = {"0": {"speaker_id": 0, "label": "老师"}}
        p.snapshot(rows, lang, speakers, [], "recording", now=0)
        initial = p.snapshot(rows, lang, speakers, [], "recording", now=2)
        lang["0:0"]["english"] = "Revised text."
        lang["0:0"]["chinese"] = "修改"
        speakers["0"]["label"] = "学生"
        changed = p.snapshot(rows, lang, speakers, [], "recording", now=3)
        self.assertEqual(initial, changed)

    def test_unfinished_clause_waits_and_merges_only_in_preview(self):
        p = CaptionPresentation()
        rows = self.source("The demon who")
        p.snapshot(rows, self.language("The demon who"), {}, [], "recording", now=0)
        self.assertEqual(
            p.snapshot(rows, self.language("The demon who"), {}, [], "recording", now=5)["rows"], []
        )
        rows = self.source("The demon who watches over you.")
        lang = self.language("The demon who watches over you.")
        p.snapshot(rows, lang, {}, [], "recording", now=6)
        self.assertEqual(len(p.snapshot(rows, lang, {}, [], "recording", now=8)["rows"]), 1)

    def test_sealed_rows_cannot_remerge_in_either_source_stage(self):
        ledger = TranscriptLedger()
        ledger.update(0, "The first fragment", True)
        ledger.sealed_ids = {"0:0"}
        ledger.update(1, "Continues here.", True)
        rows = ledger.snapshot()[0]
        self.assertEqual(len(rows), 2)
        self.assertEqual(len(group_rows(rows, {"0:0"})), 2)

    def test_stop_flushes_fragment_and_reset_drops_previous_session(self):
        p = CaptionPresentation()
        rows = self.source("A final fragment")
        lang = self.language("A final fragment")
        p.snapshot(rows, lang, {}, [], "done", now=0)
        self.assertEqual(len(p.snapshot(rows, lang, {}, [], "done", now=2)["rows"]), 1)
        p.reset()
        self.assertEqual(p.snapshot([], {}, {}, [], "idle", now=3)["rows"], [])

    def test_later_sentence_does_not_jump_ahead_of_pending_sentence(self):
        p = CaptionPresentation()
        rows = self.source() + [
            {"id": "1:0", "utterance": 1, "text": "Second sentence.", "final": True}
        ]
        lang = self.language(status="translating")
        lang["1:0"] = {"english": "Second sentence.", "chinese": "第二句。", "status": "done"}
        p.snapshot(rows, lang, {}, [], "recording", now=0)
        result = p.snapshot(rows, lang, {}, [], "recording", now=5)
        self.assertEqual(result["rows"], [])
        self.assertTrue(any("Second sentence." in item["stable"] for item in result["live"]))

    def test_pending_area_keeps_backend_sentence_units_separate(self):
        p = CaptionPresentation()
        rows = [
            {"id": "0:0", "utterance": 0, "text": "Hello everyone.", "final": True},
            {"id": "0:1", "utterance": 0, "text": "Today we discuss.", "final": True},
            {"id": "0:2", "utterance": 0, "text": "The first topic is ethics.", "final": True},
        ]
        lang = {
            row["id"]: {
                "english": row["text"],
                "original": row["text"],
                "chinese": "",
                "members": [row["id"]],
                "status": "queued",
            }
            for row in rows
        }
        result = p.snapshot(rows, lang, {}, [], "recording", now=0)
        self.assertEqual(result["rows"], [])
        stable_lines = [item["stable"] for item in result["live"] if item["stable"]]
        self.assertEqual(
            stable_lines,
            ["Hello everyone.", "Today we discuss.", "The first topic is ethics."],
        )

    def test_audio_boundary_merge_retains_ownership_when_sealed(self):
        ledger = TranscriptLedger()
        ledger.update(1, "The first section is devoted to the question", True)
        ledger.update(2, "of character, how might college change who you are?", True)
        rows = ledger.snapshot()[0]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["source_members"], ["1:0", "2:0"])
        grouped = group_rows(rows)
        self.assertEqual(grouped[0]["members"], ["1:0", "2:0"])
        lang = {
            "1:0": {
                "original": rows[0]["text"],
                "english": rows[0]["text"],
                "chinese": "课程讨论品格。",
                "status": "done",
                "members": ["1:0", "2:0"],
            }
        }
        p = CaptionPresentation()
        p.snapshot(rows, lang, {}, [], "recording", now=0)
        initial = p.snapshot(rows, lang, {}, [], "recording", now=2)
        self.assertEqual(len(initial["rows"]), 1)
        ledger.sealed_ids = set(p.consumed)
        split = ledger.snapshot()[0]
        self.assertEqual(len(split), 2)
        later = p.snapshot(split, lang, {}, [], "recording", now=3)
        self.assertEqual(later, initial)
        self.assertEqual(p.consumed, {"1:0", "2:0"})
