import unittest

from asr_core import TranscriptLedger, accepted_english
from caption_text import latin_name_gaps, strip_annotations, term_source


class CaptionAnnotationTests(unittest.TestCase):
    def test_any_square_annotation_removed_preserving_speech(self):
        self.assertEqual(
            strip_annotations("[MUSIC PLAYING] Hello [Spanish] everyone. [SIDE CONVERSATION]"),
            "Hello everyone.",
        )
        self.assertEqual(strip_annotations("请保存【音乐响起】你的作品。"), "请保存你的作品。")

    def test_parenthetical_sound_descriptions(self):
        for text in ("(upbeat music)", "(soft music playing)", "（欢快的音乐）", "(APPLAUSE)"):
            self.assertEqual(strip_annotations(text), "")
            self.assertEqual(accepted_english(text), "")
        self.assertEqual(
            strip_annotations("(upbeat music) Welcome back everyone."), "Welcome back everyone."
        )
        self.assertEqual(
            strip_annotations("The subject (music theory) is interesting."),
            "The subject (music theory) is interesting.",
        )
        self.assertEqual(
            strip_annotations("品格（ethos）与命运有关。"), "品格（ethos）与命运有关。"
        )

    def test_unclear_segment_is_hidden(self):
        self.assertEqual(strip_annotations("[Unclear] Some guessed sentence."), "")
        self.assertEqual(strip_annotations("Words [ unclear ] more words."), "")
        self.assertEqual(accepted_english("[MUSIC PLAYING]"), "")

    def test_transliterated_away_name_is_reported(self):
        english = (
            "I will eventually respond to Professor Kagan, but the synapses take a bit longer."
        )
        self.assertEqual(
            latin_name_gaps(
                english, "我最终会回应卡根教授，只是反应慢一点。", ["Shelly Kagan", "Shelly"]
            ),
            ["Shelly Kagan"],
        )
        self.assertEqual(
            latin_name_gaps(english, "我最终会回应 Kagan 教授，只是反应慢一点。", ["Shelly Kagan"]),
            [],
        )
        self.assertEqual(latin_name_gaps(english, "没有提到这个名字的一句译文。", ["Plato"]), [])

    def test_glossary_entry_forms_are_both_readable(self):
        self.assertEqual(term_source({"source": "Shelly", "target": "Shelly"}), "Shelly")
        self.assertEqual(term_source("character = 品格 (ethics course)"), "character")

    def test_suppressed_final_does_not_resurrect_a_preview(self):
        ledger = TranscriptLedger()
        ledger.update(0, "A guessed noise sentence.", full_window=True)
        ledger.update(0, "", final=True, revision=True, full_window=True)
        ledger.entries[0].annotation_suppressed = True
        self.assertEqual(ledger.snapshot(), ([], []))
        self.assertEqual(ledger.text(), "")


if __name__ == "__main__":
    unittest.main()
