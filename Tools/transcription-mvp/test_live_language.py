import threading
import unittest
from unittest.mock import patch
from live_language import LiveLanguage
from live_language import boundary_score
from live_language import group_rows, repair_clause_boundaries
from live_language import caption_english


class LanguageTests(unittest.TestCase):
    def test_incomplete_fragment_uses_timeout_protection(self):
        worker=self.make();worker.submit([{'id':'0:0','text':'And the very first thing I want--','final':True}])
        worker.updated['0:0']-=30;worker.first_seen['0:0']-=30
        self.assertTrue(worker.ready('0:0','And the very first thing I want--'))
        worker.submit([{'id':'0:0','text':'And the very first thing I want--','final':True}],flush=True)
        worker.updated['0:0']-=3
        self.assertTrue(worker.ready('0:0','And the very first thing I want--'))

    def test_confirmation_dispatches_without_delay(self):
        worker=self.make()
        worker.submit([{'id':'0','text':'Hi, good morning.','final':True}])
        self.assertTrue(worker.ready('0','Hi, good morning.'))
        self.assertEqual(worker.take_next()[0],'0')
        self.assertEqual(worker.snapshot()['0']['dispatch_reason'],'confirmed')

    def test_fifo_and_ten_second_protection(self):
        worker=self.make()
        worker.submit([{'id':'0','text':'That is.','final':True},
                       {'id':'1','text':'This is a complete sentence.','final':True}])
        self.assertIsNone(worker.take_next())
        worker.updated['0']-=10.1
        self.assertEqual(worker.take_next()[0],'0')
        self.assertEqual(worker.snapshot()['0']['dispatch_reason'],'timeout')
        self.assertEqual(worker.take_next()[0],'1')

    def test_explicit_confirmation_wakes_pending_fragment(self):
        worker=self.make()
        row={'id':'0','text':'That is.','final':True}
        worker.submit([row]);self.assertIsNone(worker.take_next())
        worker.submit([{**row,'confirmed':True}])
        self.assertTrue(worker.wake.is_set())
        self.assertEqual(worker.take_next()[0],'0')

    def test_clean_caption_does_not_load_grammar_model(self):
        with patch('live_language.GRAMMAR.correct') as model:
            self.assertEqual(caption_english('Now, as I say, this is a class.'),'Now, as I say, this is a class.')
            model.assert_not_called()
    def test_live_partial_does_not_schedule_paid_translation(self):
        worker=self.make()
        worker.submit([{'id':'0:0','utterance':0,'text':'A complete sentence about philosophy.','final':False}])
        self.assertEqual(worker.pending,{})
        worker.submit([{'id':'0:0','utterance':0,'text':'A complete sentence about philosophy.','final':True}])
        self.assertIn('0:0',worker.pending)

    def test_completed_windows_do_not_remerge(self):
        worker=self.make()
        first={'id':'0:0','utterance':0,'text':'Hello there.','final':True}
        worker.submit([first]);worker.pending.clear()
        worker.publish('0:0',0,'Hello there.',chinese='你好',status='done')
        worker.submit([first,{'id':'1:0','utterance':1,'text':'And welcome to the class.','final':True}])
        self.assertNotIn('0:0',worker.pending)
    def test_short_followup_groups_with_previous(self):
        rows=[{'id':'0:0','utterance':0,'text':'Students feel comfortable calling me Shelly when I was young.','final':True},
              {'id':'0:1','utterance':0,'text':'It seemed to work.','final':True}]
        groups=group_rows(rows)
        self.assertEqual(len(groups),1)
        repaired=repair_clause_boundaries(groups[0]['text'])
        self.assertIn('Shelly. When I was young, it seemed',repaired)

    def make(self):
        with patch.object(threading.Thread,'start'):
            return LiveLanguage()

    def test_revision_and_previous_pair(self):
        worker=self.make()
        worker.submit([{'id':'0:0','text':'Hello.'},{'id':'1:0','text':'World.'}])
        worker.publish('0:0',0,'Hello.',chinese='你好',status='done')
        worker.submit([{'id':'0:0','text':'Hello.'},{'id':'1:0','text':'New world.'}])
        self.assertEqual(worker.snapshot()['0:0']['chinese'],'你好')
        self.assertFalse(worker.publish('1:0',0,'World.',chinese='旧世界'))
        self.assertEqual(worker.snapshot()['1:0']['chinese'],'')

    def test_session_reset_rejects_old_results(self):
        worker=self.make();worker.submit([{'id':'0:0','text':'Hello.'}])
        worker.reset();worker.submit([{'id':'0:0','text':'Hello.'}])
        self.assertFalse(worker.publish('0:0',0,'Hello.',chinese='旧结果'))

    def test_unchanged_does_not_requeue(self):
        worker=self.make();rows=[{'id':'0:0','text':'Hello.'}]
        worker.submit(rows);worker.pending.clear();worker.publish('0:0',0,'Hello.',status='done')
        worker.submit(rows)
        self.assertEqual(worker.pending,{})

    def test_missing_key_explicit_error(self):
        worker=self.make();worker.key=''
        with self.assertRaises(ValueError):worker.translate('Hello.',lambda s:None)

    def test_translation_remains_visible_during_revision(self):
        worker=self.make();worker.submit([{'id':'0:0','text':'Hello.'}])
        worker.publish('0:0',0,'Hello.',chinese='你好',status='done')
        worker.submit([{'id':'0:0','text':'Hello there.'}])
        self.assertEqual(worker.snapshot()['0:0']['chinese'],'你好')
        self.assertTrue(worker.snapshot()['0:0']['translation_stale'])

    def test_boundary_wait_and_deadline(self):
        worker=self.make();worker.submit([{'id':'0:0','text':'during office.'}])
        worker.updated['0:0']-=3
        self.assertFalse(worker.ready('0:0','during office.'))
        worker.updated['0:0']-=8
        self.assertTrue(worker.ready('0:0','during office.'))
        self.assertLess(boundary_score('This is something that.'),.65)
        self.assertGreaterEqual(boundary_score('This is a complete sentence about philosophy.'),.65)

    def test_incremental_sse(self):
        worker=self.make();worker.key='test'
        from unittest.mock import MagicMock
        response=MagicMock();response.ok=True
        response.iter_lines.return_value=[b'data: {"choices":[{"delta":{"content":"Hello"}}]}', b'data: {"choices":[{"delta":{"content":" world"}}]}',b'data: [DONE]']
        parts=[]
        with patch('live_language.requests.post',return_value=response):
            self.assertEqual(worker.translate('Hello.',parts.append),'Hello world')
        self.assertEqual(parts,['Hello','Hello world'])

    def test_name_address_disambiguation_preserves_source(self):
        worker=self.make();worker.key='test'
        original='I will eventually respond to Professor Kagan.'
        worker.submit([{'id':'0','text':'My name is Shelly Kagan. Please call me Shelly.','final':True},
                       {'id':'1','text':original,'final':True}])
        from unittest.mock import MagicMock
        response=MagicMock();response.ok=True
        response.iter_lines.return_value=[b'data: {"choices":[{"delta":{"content":"answer"}}]}',b'data: [DONE]']
        with patch('live_language.requests.post',return_value=response) as request:
            worker.translate(original,lambda s:None)
        sent=request.call_args.kwargs['json']['messages'][0]['content']
        self.assertIn('When someone addresses me as Professor Kagan',sent)
        self.assertEqual(worker.snapshot()['1']['original'],original)

    def test_august_glossary_does_not_change_months(self):
        from unittest.mock import MagicMock
        for text,expected in [("Now I'm gray and august.",True),('We meet in July and August.',False)]:
            worker=self.make();worker.key='test';worker.submit([{'id':'0','text':text,'final':True}])
            response=MagicMock();response.ok=True
            response.iter_lines.return_value=[b'data: {"choices":[{"delta":{"content":"translation"}}]}',b'data: [DONE]']
            with patch('live_language.requests.post',return_value=response) as request:
                worker.translate(text,lambda s:None)
            terms=request.call_args.kwargs['json']['translation_options'].get('terms',[])
            self.assertEqual(any(t['source']=='august' for t in terms),expected)

if __name__=='__main__':unittest.main()

