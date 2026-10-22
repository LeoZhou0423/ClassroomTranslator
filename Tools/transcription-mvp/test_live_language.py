import os
import threading
import unittest
from unittest.mock import patch

from live_language import (
    LiveLanguage,
    boundary_score,
    caption_english,
    group_rows,
    repair_clause_boundaries,
)


class LanguageTests(unittest.TestCase):
    def setUp(self):
        # A key stored on the build host must never turn a unit test into a paid request:
        # these cases assert queueing and revision semantics against a patched translate.
        self._correction_disabled = patch.dict(os.environ, {"LINGOCLASS_AI_CORRECTION": "0"})
        self._correction_disabled.start()

    def tearDown(self):
        self._correction_disabled.stop()

    def test_slow_translation_does_not_block_later_sentence(self):
        first_started = threading.Event()
        release = threading.Event()
        second_done = threading.Event()

        def translate(worker, text, emit):
            if text == "This is the first sentence.":
                first_started.set()
                release.wait(3)
            else:
                second_done.set()
            return "translated " + text

        with patch.object(LiveLanguage, "translate", translate):
            worker = LiveLanguage()
            try:
                worker.submit([{"id": "0", "text": "This is the first sentence.", "final": True}])
                self.assertTrue(first_started.wait(2))
                worker.submit(
                    [
                        {"id": "0", "text": "This is the first sentence.", "final": True},
                        {"id": "1", "text": "This is the second sentence.", "final": True},
                    ]
                )
                self.assertTrue(second_done.wait(2))
                self.assertEqual(list(worker.snapshot()), ["0", "1"])
            finally:
                release.set()
                worker.close()

    def test_revision_waits_for_same_row_and_rejects_old_job(self):
        worker = self.make()
        worker.submit([{"id": "0", "text": "This is the old sentence.", "final": True}])
        worker.take_next()
        worker.submit([{"id": "0", "text": "This is the revised sentence.", "final": True}])
        self.assertIsNone(worker.take_next())
        self.assertFalse(worker.publish("0", 0, "This is the old sentence.", chinese="old"))
        worker.inflight.discard((worker.generation, "0"))
        self.assertEqual(worker.take_next()[1][1], "This is the revised sentence.")

    def test_incomplete_fragment_uses_timeout_protection(self):
        worker = self.make()
        worker.submit([{"id": "0:0", "text": "And the very first thing I want--", "final": True}])
        worker.updated["0:0"] -= 30
        worker.first_seen["0:0"] -= 30
        self.assertTrue(worker.ready("0:0", "And the very first thing I want--"))
        worker.submit(
            [{"id": "0:0", "text": "And the very first thing I want--", "final": True}], flush=True
        )
        worker.updated["0:0"] -= 3
        self.assertTrue(worker.ready("0:0", "And the very first thing I want--"))

    def test_timeout_deadline_survives_continuous_refresh(self):
        worker = self.make()
        worker.submit([{"id": "0:0", "text": "And the very first thing I want--", "final": True}])
        worker.first_seen["0:0"] -= 3
        worker.updated["0:0"] = worker.updated.get("0:0", 0) + 10
        # Refreshing updated must not postpone dispatch past the absolute deadline.
        self.assertTrue(worker.ready("0:0", "And the very first thing I want--"))

    def test_absorbing_segmented_sentence_does_not_restart_timer(self):
        worker = self.make()
        first = {"id": "0:0", "utterance": 0, "text": "Hello everyone.", "final": True}
        worker.submit([first])
        worker.updated["0:0"] -= 2.5
        worker.first_seen["0:0"] -= 2.5
        worker.submit(
            [
                first,
                {
                    "id": "0:1",
                    "utterance": 0,
                    "text": "It seemed to work.",
                    "final": True,
                },
            ]
        )
        self.assertIn("0:0", worker.results)
        self.assertEqual(worker.results["0:0"]["members"], ["0:0", "0:1"])
        self.assertTrue(worker.ready("0:0", worker.results["0:0"]["original"]))

    def test_complete_segmented_sentences_stay_separate(self):
        rows = [
            {"id": "0:0", "utterance": 0, "text": "Hello everyone.", "final": True},
            {"id": "0:1", "utterance": 0, "text": "Today we discuss.", "final": True},
            {"id": "0:2", "utterance": 0, "text": "The first topic is ethics.", "final": True},
        ]
        self.assertEqual(len(group_rows(rows)), 3)

    def test_confirmation_dispatches_without_delay(self):
        worker = self.make()
        worker.submit([{"id": "0", "text": "Hi, good morning.", "final": True}])
        self.assertTrue(worker.ready("0", "Hi, good morning."))
        self.assertEqual(worker.take_next()[0], "0")
        self.assertEqual(worker.snapshot()["0"]["dispatch_reason"], "confirmed")

    def test_ready_sentence_bypasses_unconfirmed_fragment(self):
        worker = self.make()
        worker.submit(
            [
                {"id": "0", "text": "That is.", "final": True},
                {"id": "1", "text": "This is a complete sentence.", "final": True},
            ]
        )
        self.assertEqual(worker.take_next()[0], "1")
        worker.updated["0"] -= 10.1
        self.assertEqual(worker.take_next()[0], "0")
        self.assertEqual(worker.snapshot()["0"]["dispatch_reason"], "timeout")
        self.assertIsNone(worker.take_next())

    def test_explicit_confirmation_wakes_pending_fragment(self):
        worker = self.make()
        row = {"id": "0", "text": "That is.", "final": True}
        worker.submit([row])
        self.assertIsNone(worker.take_next())
        worker.submit([{**row, "confirmed": True}])
        self.assertTrue(worker.wake.is_set())
        self.assertEqual(worker.take_next()[0], "0")

    def test_clean_caption_does_not_load_grammar_model(self):
        with patch("live_language.GRAMMAR.correct") as model:
            self.assertEqual(
                caption_english("Now, as I say, this is a class."),
                "Now, as I say, this is a class.",
            )
            model.assert_not_called()

    def test_live_partial_does_not_schedule_paid_translation(self):
        worker = self.make()
        worker.submit(
            [
                {
                    "id": "0:0",
                    "utterance": 0,
                    "text": "A complete sentence about philosophy.",
                    "final": False,
                }
            ]
        )
        self.assertEqual(worker.pending, {})
        worker.submit(
            [
                {
                    "id": "0:0",
                    "utterance": 0,
                    "text": "A complete sentence about philosophy.",
                    "final": True,
                }
            ]
        )
        self.assertIn("0:0", worker.pending)

    def test_stable_sentence_dispatches_before_audio_window_finishes(self):
        worker = self.make()
        worker.submit(
            [
                {
                    "id": "0:0",
                    "utterance": 0,
                    "text": "This is a complete lecture sentence.",
                    "final": False,
                    "stable": True,
                }
            ]
        )
        self.assertEqual(worker.take_next()[0], "0:0")

    def test_completed_windows_do_not_remerge(self):
        worker = self.make()
        first = {"id": "0:0", "utterance": 0, "text": "Hello there.", "final": True}
        worker.submit([first])
        worker.pending.clear()
        worker.publish("0:0", 0, "Hello there.", chinese="你好", status="done")
        worker.submit(
            [
                first,
                {"id": "1:0", "utterance": 1, "text": "And welcome to the class.", "final": True},
            ]
        )
        self.assertNotIn("0:0", worker.pending)

    def test_short_followup_groups_with_previous(self):
        rows = [
            {
                "id": "0:0",
                "utterance": 0,
                "text": "Students feel comfortable calling me Shelly when I was young.",
                "final": True,
            },
            {"id": "0:1", "utterance": 0, "text": "It seemed to work.", "final": True},
        ]
        groups = group_rows(rows)
        self.assertEqual(len(groups), 1)
        repaired = repair_clause_boundaries(groups[0]["text"])
        self.assertIn("Shelly. When I was young, it seemed", repaired)

    def test_cross_window_relative_clause_retranslates_as_one(self):
        worker = self.make()
        first = {
            "id": "0:0",
            "utterance": 0,
            "text": "But it is also the demon who.",
            "final": True,
        }
        worker.submit([first])
        worker.publish("0:0", 0, first["text"], chinese="unfinished", status="done")
        worker.submit(
            [
                first,
                {
                    "id": "1:0",
                    "utterance": 1,
                    "text": "Sort of looks over you during your life.",
                    "final": True,
                },
            ]
        )
        row = worker.results["0:0"]
        self.assertEqual(row["members"], ["0:0", "1:0"])
        self.assertIn("who Sort of looks", row["original"])
        self.assertIn("0:0", worker.pending)
        self.assertTrue(row["translation_stale"])
        self.assertFalse(worker.publish("0:0", 0, first["text"], chinese="old", status="done"))

    def test_cross_window_possessive_continuation(self):
        groups = group_rows(
            [
                {"id": "0", "utterance": 0, "text": "Heraclitus as part of his", "final": True},
                {
                    "id": "1",
                    "utterance": 1,
                    "text": "Of Raphael's painting of the School of Athens.",
                    "final": True,
                },
            ]
        )
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0]["members"], ["0", "1"])

    def test_cross_window_known_speaker_change_stays_separate(self):
        groups = group_rows(
            [
                {"id": "0", "text": "Tell me whether", "final": True, "speaker_id": 1},
                {"id": "1", "text": "Yes it is.", "final": True, "speaker_id": 2},
            ]
        )
        self.assertEqual(len(groups), 2)

    def test_default_worker_repairs_before_translating_and_keeps_role_evidence(self):
        worker = self.make()
        worker.key = "test"
        worker.url = "https://open.bigmodel.cn/api/paas/v4"
        source = "The character section of the um course is about virtue."
        worker.submit([{"id": "0:0", "utterance": 0, "text": source, "final": True}])

        def repaired(*args, **kwargs):
            worker.closed.set()
            return {
                "english": "The character section of the course is about virtue.",
                "chinese": "课程中的品格部分讨论美德。",
                "teacher_probability": 0.98,
                "background_probability": 0,
                "cache_hit": False,
                "usage": {},
            }

        with patch.dict(os.environ):
            os.environ.pop("LINGOCLASS_AI_CORRECTION", None)
            with (
                patch("live_language.PIPELINE.process", side_effect=repaired) as pipeline,
                patch.object(
                    worker,
                    "translate",
                    side_effect=AssertionError("raw translation bypassed correction"),
                ),
            ):
                worker.run()
        self.assertEqual(pipeline.call_count, 1)
        row = worker.snapshot()["0:0"]
        self.assertEqual(row["correction_status"], "context_repaired")
        self.assertEqual(row["teacher_probability"], 0.98)
        self.assertNotIn("um", row["english"])
        self.assertIn("character = 品格 (ethics course)", pipeline.call_args.args[2])

    def make(self):
        with patch.object(threading.Thread, "start"):
            return LiveLanguage()

    def test_revision_and_previous_pair(self):
        worker = self.make()
        worker.submit([{"id": "0:0", "text": "Hello."}, {"id": "1:0", "text": "World."}])
        worker.publish("0:0", 0, "Hello.", chinese="你好", status="done")
        worker.submit([{"id": "0:0", "text": "Hello."}, {"id": "1:0", "text": "New world."}])
        self.assertEqual(worker.snapshot()["0:0"]["chinese"], "你好")
        self.assertFalse(worker.publish("1:0", 0, "World.", chinese="旧世界"))
        self.assertEqual(worker.snapshot()["1:0"]["chinese"], "")

    def test_session_reset_rejects_old_results(self):
        worker = self.make()
        worker.submit([{"id": "0:0", "text": "Hello."}])
        worker.reset()
        worker.submit([{"id": "0:0", "text": "Hello."}])
        self.assertFalse(worker.publish("0:0", 0, "Hello.", chinese="旧结果"))

    def test_unchanged_does_not_requeue(self):
        worker = self.make()
        rows = [{"id": "0:0", "text": "Hello."}]
        worker.submit(rows)
        worker.pending.clear()
        worker.publish("0:0", 0, "Hello.", status="done")
        worker.submit(rows)
        self.assertEqual(worker.pending, {})

    def test_missing_key_explicit_error(self):
        worker = self.make()
        worker.key = ""
        with self.assertRaises(ValueError):
            worker.translate("Hello.", lambda s: None)

    def test_revised_source_does_not_display_old_translation(self):
        worker = self.make()
        worker.submit([{"id": "0:0", "text": "Hello."}])
        worker.publish("0:0", 0, "Hello.", chinese="你好", status="done")
        worker.submit([{"id": "0:0", "text": "Hello there."}])
        self.assertEqual(worker.snapshot()["0:0"]["chinese"], "你好")
        self.assertTrue(worker.snapshot()["0:0"]["translation_stale"])
        self.assertFalse(worker.publish("0:0", 0, "Hello.", chinese="旧译文"))

    def test_boundary_wait_and_deadline(self):
        worker = self.make()
        worker.submit([{"id": "0:0", "text": "during office."}])
        worker.updated["0:0"] -= 0.5
        self.assertFalse(worker.ready("0:0", "during office."))
        worker.updated["0:0"] -= 2
        self.assertTrue(worker.ready("0:0", "during office."))
        self.assertLess(boundary_score("This is something that."), 0.65)
        self.assertGreaterEqual(
            boundary_score("This is a complete sentence about philosophy."), 0.65
        )

    def test_incremental_sse(self):
        worker = self.make()
        worker.key = "test"
        worker.url = "https://example.com/v1"
        from unittest.mock import MagicMock

        response = MagicMock()
        response.ok = True
        response.iter_lines.return_value = [
            b'data: {"choices":[{"delta":{"content":"Hello"}}]}',
            b'data: {"choices":[{"delta":{"content":" world"}}]}',
            b"data: [DONE]",
        ]
        parts = []
        with patch("live_language.requests.post", return_value=response):
            self.assertEqual(worker.translate("Hello.", parts.append), "Hello world")
        self.assertEqual(parts, ["Hello", "Hello world"])

    def test_name_address_disambiguation_preserves_source(self):
        worker = self.make()
        worker.key = "test"
        worker.url = "https://example.com/v1"
        original = "I will eventually respond to Professor Kagan."
        worker.submit(
            [
                {
                    "id": "0",
                    "text": "My name is Shelly Kagan. Please call me Shelly.",
                    "final": True,
                },
                {"id": "1", "text": original, "final": True},
            ]
        )
        from unittest.mock import MagicMock

        response = MagicMock()
        response.ok = True
        response.iter_lines.return_value = [
            b'data: {"choices":[{"delta":{"content":"answer"}}]}',
            b"data: [DONE]",
        ]
        with patch("live_language.requests.post", return_value=response) as request:
            worker.translate(original, lambda s: None)
        sent = request.call_args.kwargs["json"]["messages"][0]["content"]
        self.assertEqual(sent, original)
        domains = request.call_args.kwargs["json"]["translation_options"]["domains"]
        self.assertIn("call me Shelly", domains)
        self.assertNotIn("neuroscience", domains)
        self.assertEqual(worker.snapshot()["1"]["original"], original)

    def test_august_glossary_does_not_change_months(self):
        from unittest.mock import MagicMock

        for text, expected in [
            ("Now I'm gray and august.", True),
            ("We meet in July and August.", False),
        ]:
            worker = self.make()
            worker.key = "test"
            worker.url = "https://example.com/v1"
            worker.submit([{"id": "0", "text": text, "final": True}])
            response = MagicMock()
            response.ok = True
            response.iter_lines.return_value = [
                b'data: {"choices":[{"delta":{"content":"translation"}}]}',
                b"data: [DONE]",
            ]
            with patch("live_language.requests.post", return_value=response) as request:
                worker.translate(text, lambda s: None)
            terms = request.call_args.kwargs["json"]["translation_options"].get("terms", [])
            self.assertEqual(any(t["source"] == "august" for t in terms), expected)


if __name__ == "__main__":
    unittest.main()
