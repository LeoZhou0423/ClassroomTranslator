import unittest
from asr_core import Utterance, TranscriptLedger


class LocalRevisionTests(unittest.TestCase):
    def test_ellipsis_continuation_joins_final_windows(self):
        ledger=TranscriptLedger()
        ledger.update(0,'I was in a wonderful place, with wonderful...',final=True)
        ledger.update(1,'students around me and wonderful teachers.',final=True)
        rows,_=ledger.snapshot()
        self.assertEqual(len(rows),1)
        self.assertIn('wonderful students',rows[0]['text'])
        self.assertIn('wonderful...',ledger.entries[0].best)

    def test_early_word_change_preserves_later_display(self):
        u=Utterance(0)
        for _ in range(2):u.update('My name is Shelley Kagan. Welcome to the class.',full_window=True)
        u.update('My name is Shelly Kagan. Welcome to the class. Today we',full_window=True)
        self.assertIn('Welcome to the class.',u.stable)
        self.assertIn('Shelly',u.stable)

    def test_local_insertion_preserves_frontier(self):
        u=Utterance(0)
        for _ in range(2):u.update('This is our class. We study philosophy.',full_window=True)
        u.update('This is our new class. We study philosophy. Today we',full_window=True)
        self.assertIn('We study philosophy.',u.stable)

if __name__=='__main__':unittest.main()
