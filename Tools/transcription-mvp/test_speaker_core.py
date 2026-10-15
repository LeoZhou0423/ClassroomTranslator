import unittest

import numpy as np

from speaker_core import OnlineSpeakerClusterer, RevisableRoleState, correct_role_with_cues, SpeakerRoleAnalyzer, TranscriptItem


class SpeakerCoreTests(unittest.TestCase):
    def test_similar_embeddings_keep_one_person(self):
        clusterer = OnlineSpeakerClusterer()
        first, _ = clusterer.assign(np.array([1.0, 0.0], np.float32), 0)
        second, _ = clusterer.assign(np.array([0.98, 0.05], np.float32), 1)
        self.assertEqual((first, second), (0, 0))
        self.assertEqual(len(clusterer.centroids), 1)

    def test_new_person_needs_two_agreeing_windows_and_backfills(self):
        clusterer = OnlineSpeakerClusterer()
        clusterer.assign(np.array([1.0, 0.0], np.float32), 0)
        provisional, _ = clusterer.assign(np.array([0.0, 1.0], np.float32), 1)
        confirmed, backfill = clusterer.assign(np.array([0.05, 0.98], np.float32), 2)
        self.assertIsNone(provisional)
        self.assertEqual(confirmed, 1)
        self.assertEqual(backfill, 1)

    def test_student_cues_correct_a_teacher_biased_minilm_result(self):
        label, score = correct_role_with_cues(
            "Could you explain that again? I do not understand this part.", "teacher", 0.93
        )
        self.assertEqual(label, "student")
        self.assertGreaterEqual(score, 0.85)

    def test_professor_address_and_questions_are_student_evidence(self):
        text = (
            "Professor, I have a question. Can you tell me what is data structure? "
            "And why must we study computer science? Please tell me."
        )
        label, score = correct_role_with_cues(text, "teacher", 0.97)
        self.assertEqual(label, "student")
        self.assertGreaterEqual(score, 0.85)

    def test_teacher_can_ask_can_you_tell_me(self):
        text = "Can you tell me why this algorithm is faster? What do you think?"
        label, score = correct_role_with_cues(text, "teacher", 0.91)
        self.assertEqual(label, "teacher")
        self.assertGreaterEqual(score, 0.91)

    def test_one_opposing_result_does_not_flip_role(self):
        state = RevisableRoleState()
        for _ in range(3):state.update(0.95)
        changed = state.update(0.10)
        self.assertFalse(changed)
        self.assertEqual(state.label, "teacher")

    def test_sustained_opposing_evidence_corrects_old_role(self):
        state = RevisableRoleState()
        for _ in range(3):state.update(0.95)
        state.update(0.10)
        changed = state.update(0.08)
        self.assertTrue(changed)
        self.assertEqual(state.label, "student")
        self.assertGreaterEqual(state.score, 0.9)

    def test_unknown_role_and_ordinary_lecture_evidence(self):
        state = RevisableRoleState()
        self.assertIsNone(state.label)
        state.update(.5)
        self.assertIsNone(state.label)
        state.update(.90)
        self.assertEqual(state.label, 'teacher')
        state.update(.6)
        self.assertEqual(state.label, 'teacher')

    def test_voice_variation_does_not_create_second_person(self):
        clusterer = OnlineSpeakerClusterer()
        clusterer.assign(np.array([1., 0.]), 0)
        speaker, _ = clusterer.assign(np.array([.55, .835]), 1)
        self.assertEqual(speaker, 0)
        self.assertEqual(len(clusterer.centroids), 1)

    def test_recognized_voice_clears_stale_candidate(self):
        clusterer = OnlineSpeakerClusterer()
        clusterer.assign(np.array([1., 0.]), 0)
        clusterer.assign(np.array([0., 1.]), 1)
        clusterer.assign(np.array([1., 0.]), 2)
        self.assertEqual(clusterer.assign(np.array([0., 1.]), 3), (None, None))
        self.assertEqual(len(clusterer.centroids), 1)

    def test_teacher_personal_aside_is_not_student_keyword(self):
        self.assertEqual(correct_role_with_cues("I think this is a useful example.", "teacher", .94)[0], 'teacher')

    def test_lecture_without_instruction_keywords_can_be_teacher(self):
        analyzer = SpeakerRoleAnalyzer.__new__(SpeakerRoleAnalyzer)
        analyzer.roles = {}
        analyzer.role_states = {}
        analyzer.role_text_snapshots = {}
        analyzer._teacher_probability = lambda text: .91
        items = [TranscriptItem(text, 0) for text in (
            "Plato distinguishes knowledge from opinion.",
            "Consider the argument about the nature of justice.",
            "The conclusion depends on the earlier premise.")]
        analyzer.update_roles(items)
        self.assertEqual(analyzer.roles[0][0], 'teacher')

    def test_instruction_keyword_does_not_promote_student(self):
        self.assertEqual(correct_role_with_cues('Make sure you save the PDF.','student',.8)[0],'student')

    def test_missing_voiceprint_is_not_last_teacher(self):
        clusterer=OnlineSpeakerClusterer();clusterer.assign(np.array([1.,0.]),0)
        self.assertEqual(clusterer.assign(np.zeros(2),1),(None,None))


if __name__ == "__main__":
    unittest.main()
