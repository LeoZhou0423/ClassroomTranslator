import unittest
from transcription_core import (
    LocalAgreement,
    acceptable,
    append_text,
    format_sentences,
    merge_overlap,
    reconcile_final_segment,
    strip_committed_prefix,
)


class CoreTests(unittest.TestCase):
    def test_repetition_loop_is_rejected(self):
        self.assertFalse(acceptable("i n i n i n i n i n i n"))

    def test_normal_sentence_is_accepted(self):
        self.assertTrue(acceptable("Today we will compare plant and animal cells"))

    def test_overlap_appends_only_new_tail(self):
        self.assertEqual(
            merge_overlap("plants need water and sunlight", "water and sunlight to make food"),
            "plants need water and sunlight to make food",
        )

    def test_local_agreement_confirms_shared_prefix(self):
        agreement = LocalAgreement()
        agreement.update("today we discuss a cell")
        stable, volatile = agreement.update("today we discuss the cell membrane")
        self.assertEqual(stable, "today we discuss")
        self.assertEqual(volatile, "the cell membrane")

    def test_committed_prefix_is_removed_from_later_hypothesis(self):
        self.assertEqual(
            strip_committed_prefix("Today we discuss data structures in detail", "Today we discuss data structures"),
            "in detail",
        )

    def test_append_text_keeps_punctuation_attached(self):
        self.assertEqual(append_text("What is love", "?"), "What is love?")

    def test_stable_prefix_can_be_promoted_before_vad_final(self):
        agreement = LocalAgreement()
        agreement.update("We deal with data all the time and organize")
        stable, _ = agreement.update("We deal with data all the time and store it")
        history = append_text("", stable)
        remainder = strip_committed_prefix(
            "We deal with data all the time and store it efficiently", history
        )
        self.assertEqual(history, "We deal with data all the time and")
        self.assertEqual(remainder, "store it efficiently")

    def test_committed_sentences_are_displayed_on_separate_lines(self):
        self.assertEqual(
            format_sentences("First sentence. Second sentence! Is this third? unfinished"),
            "First sentence.\nSecond sentence!\nIs this third?\nunfinished",
        )

    def test_closed_sentence_remains_appendable(self):
        canonical = append_text("First sentence.", "More content arrives later")
        self.assertEqual(canonical, "First sentence. More content arrives later")
        self.assertEqual(
            format_sentences(canonical),
            "First sentence.\nMore content arrives later",
        )

    def test_decimal_point_does_not_split_a_sentence(self):
        self.assertEqual(format_sentences("Version 3.14 works. Next"), "Version 3.14 works.\nNext")

    def test_final_replaces_corrected_partial_instead_of_duplicating_it(self):
        partial = "My name is Shelly and I prefer to be Gray and Auguste."
        final = "My name is Shelley and I prefer to be called Shelley."
        self.assertEqual(reconcile_final_segment(partial, final), final)


if __name__ == "__main__": unittest.main()
