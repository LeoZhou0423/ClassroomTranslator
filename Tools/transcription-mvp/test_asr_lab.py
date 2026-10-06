import unittest
from asr_core import TranscriptLedger, sentence_units, accepted_english, reconcile_boundary, AudioWindowOwners
from asr_lab import Lab
import numpy as np
class Rules(unittest.TestCase):
 def test_short_final_keeps_preview(self):
  x=TranscriptLedger(); x.update(0,'We study data structures. This is important.'); x.update(0,'This is important.',True)
  self.assertIn('We study data structures.',x.text())
 def test_empty_final_keeps_preview(self):
  x=TranscriptLedger(); x.update(0,'What is love?'); x.update(0,'',True); self.assertEqual(x.text(),'What is love?')
 def test_stable_closed_sentence_moves(self):
  x=TranscriptLedger(); x.update(0,'Hello world. We study'); x.update(0,'Hello world. We study data'); rows,live=x.snapshot(); self.assertEqual(rows[0]['text'],'Hello world.')
 def test_append_after_period(self):
  x=TranscriptLedger(); x.update(0,'Hello world.'); x.update(0,'Hello world. Another sentence.',True); self.assertEqual(len(x.snapshot()[0]),2)
 def test_repeated_different_segments_retained(self):
  x=TranscriptLedger(); x.update(0,'Hello world.',True); x.update(1,'Hello world.',True); self.assertEqual(len(x.snapshot()[0]),2)
 def test_late_partial_cannot_overwrite(self):
  x=TranscriptLedger(); x.update(0,'Hello world.',True); x.update(0,'Bad replacement'); self.assertEqual(x.text(),'Hello world.')
 def test_context_can_revise_final(self):
  x=TranscriptLedger(); x.update(0,"Classes on debt.",True); x.update(0,"Classes on death. We study philosophy.",True,revision=True); self.assertIn("Classes on death.",x.text())
 def test_distinct_audio_repetitions_preserved(self):
  x=TranscriptLedger(); x.update(0,"Hello world. I will eventually respond to--",True); x.update(1,"I will eventually respond to Professor Kagan.",True); self.assertEqual(x.text().count("I will eventually"),2)
 def test_full_window_is_replacement(self):
  x=TranscriptLedger(); x.update(0,"I will eventually respond to Professor Kagan.",True); x.update(0,"I will eventually respond to Professor Kagan, but it takes longer.",True,revision=True,full_window=True); self.assertEqual(x.text().count("I will eventually"),1)
 def test_empty_full_window_keeps_text(self):
  x=TranscriptLedger(); x.update(0,"Hello world."); x.update(0,"",True,revision=True,full_window=True); self.assertEqual(x.text(),"Hello world.")
 def test_full_window_can_correct_shorter_result(self):
  x=TranscriptLedger(); x.update(0,"Hello world. Hello world."); x.update(0,"Hello world.",True,revision=True,full_window=True); self.assertEqual(x.text(),"Hello world.")
 def test_export_keeps_live_tail_in_audio_order(self):
  x=TranscriptLedger(); x.update(0,"First unfinished"); x.update(1,"Second finished.",True); self.assertEqual(x.text(),"First unfinished\nSecond finished.")
 def test_boundary_recovers_missing_words(self):
  a="You might reasonably expect or hope that a class on death would--"
  b="so that if this is not the class you were looking for, you can leave."
  bridge="reasonably expect or hope that a class on death would talk about so that if this is not the class you were looking for"
  result=reconcile_boundary(a,b,bridge); self.assertIsNotNone(result); self.assertEqual((result[0]+" "+result[1]).count("talk about"),1); self.assertTrue(result[1].endswith("you can leave."))
 def test_boundary_requires_both_anchors(self):
  self.assertIsNone(reconcile_boundary("One two three four five.","Six seven eight nine ten.","One two three four invented continuation."))
 def test_window_end_does_not_force_sentence(self):
  x=TranscriptLedger(); x.update(0,"You can visit during office",True); x.update(1,"hours. Ask a question.",True); self.assertEqual(x.text(),"You can visit during office hours.\nAsk a question.")
 def test_stable_punctuation_can_revise(self):
  x=TranscriptLedger(); x.update(0,"Hello world. We study",full_window=True); x.update(0,"Hello world. We study more",full_window=True); self.assertEqual(x.snapshot()[0][0]["text"],"Hello world."); x.update(0,"Hello world, we study more",full_window=True); self.assertNotIn("Hello world.",[r["text"] for r in x.snapshot()[0]])
 def test_early_correction_keeps_prior_stable_sentence(self):
  x=TranscriptLedger(); x.update(0,"Hello world. My name is Hagan",full_window=True); x.update(0,"Hello world. My name is Hagan today",full_window=True); x.update(0,"Hello world. My name is Kagan today",full_window=True); self.assertEqual(x.snapshot()[0][0]["text"],"Hello world.")
 def test_full_window_suffix_does_not_erase_prefix(self):
  x=TranscriptLedger(); x.update(0,"We study computer science and data structures every day. This matters.",full_window=True); x.update(0,"This matters.",True,revision=True,full_window=True); self.assertIn("We study computer science",x.text())
 def test_growing_audio_owner_is_immutable(self):
  owners=AudioWindowOwners(); self.assertEqual(owners.owner(1000),0); self.assertEqual(owners.owner(5000),1); self.assertEqual(owners.owner(1000),0)
 def test_title_abbreviation_does_not_split(self):
  self.assertEqual(sentence_units("Dr. Smith teaches. Why?"),["Dr. Smith teaches.","Why?"])
 def test_quoted_sentence_closes(self):
  self.assertEqual(sentence_units('He said "Hello!" Next sentence.'),['He said "Hello!"',"Next sentence."])
 def test_noise_foreign(self):
  self.assertEqual(accepted_english('[music]'),''); self.assertEqual(accepted_english('这是中文。'),'')
 def test_decimal(self): self.assertEqual(sentence_units('It is 3.14. Why?'),['It is 3.14.','Why?'])
 def test_final_queue_is_durable(self):
  x=Lab(); a=np.zeros(16000,dtype=np.float32); x._submit(0,a,False,0); x._submit(0,a,True,0); x._submit(1,a,True,1); self.assertEqual(len(x.finals),2); self.assertFalse(x.partials)
if __name__=='__main__': unittest.main()
