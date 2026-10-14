import unittest
import tempfile
import wave
from pathlib import Path
from types import SimpleNamespace
import numpy as np
from unittest.mock import patch, Mock
from asr_quality import review_reason, select_audio_revision, retain_missing_edges, audio_supports_proposal
from asr_correction import ASRCorrector, valid_correction, valid_semantic_proposal, valid_contextual_repair
from asr_core import TranscriptLedger


class QualityTests(unittest.TestCase):
    def test_contextual_mode_can_fix_word_without_audio(self):
        self.assertTrue(valid_contextual_repair('You need to add some Reddit.','You need to add some credit.'))
        self.assertTrue(valid_contextual_repair('Your father\'s corrupt.','Your file is corrupt.'))
        self.assertTrue(valid_contextual_repair('Just like my circles and bottoms.','Just like my circles and buttons.'))
        service=ASRCorrector();response=Mock(status_code=200)
        response.json.return_value={'choices':[{'message':{'content':'{"text":"You need to add some credit.","uncertain":false}'}}]}
        with patch('asr_correction.requests.post',return_value=response):
            text,status=service.correct('You need to add some Reddit.','Printing balance.','test','https://example.test',contextual=True)
            self.assertEqual((text,status),('You need to add some credit.','context_repaired'))

    def test_contextual_mode_marks_unclear_without_free_story(self):
        self.assertTrue(valid_contextual_repair('Some badly broken sentence.','[Unclear]'))
        self.assertFalse(valid_contextual_repair('A printing class.',''))
        self.assertFalse(valid_contextual_repair('A printing class.','Return only JSON with preceding context.'))
        self.assertFalse(valid_contextual_repair('A printing class.','We are traveling on a spaceship towards Mars.'))

    def test_uncertainty_stays_internal_and_student_questions_not_filtered(self):
        service=ASRCorrector();response=Mock(status_code=200)
        response.json.return_value={'choices':[{'message':{'content':'{"text":"[Unclear]","uncertain":true,"background_probability":0}'}}]}
        with patch('asr_correction.requests.post',return_value=response):
            text,status=service.correct('Some broken words.','','test','https://example.test',contextual=True)
            self.assertEqual(text,'')
            self.assertEqual(status,'context_suppressed')
        response.json.return_value={'choices':[{'message':{'content':'{"text":"How do I print this?","uncertain":false,"background_probability":0.99}'}}]}
        with patch('asr_correction.requests.post',return_value=response):
            text,status=service.correct('How do I print this?','','test','https://example.test',contextual=True)
            self.assertNotEqual(status,'context_background')

    def test_strong_unrelated_chat_can_be_filtered(self):
        service=ASRCorrector();response=Mock(status_code=200)
        response.json.return_value={'choices':[{'message':{'content':'{"text":"We are going to the train station after dinner.","uncertain":false,"background_probability":0.99}'}}]}
        with patch('asr_correction.requests.post',return_value=response):
            self.assertEqual(service.correct('We are going to the train station after dinner.','A graphic design lecture.','test','https://example.test',contextual=True)[1],'context_background')
    def test_runtime_semantic_review_applies_only_supported_candidate(self):
        import asr_lab
        for evidence,expected,status in [('This is a class on death.','This is a class on death.','verified'),
                                          ('This is a class on debt.','This is a class on debt.','unverified')]:
            with self.subTest(evidence=evidence),tempfile.TemporaryDirectory() as folder:
                lab=asr_lab.Lab();lab.session_dir=Path(folder);lab.config={'model':'small'}
                original='This is a class on debt.'
                lab.ledger.update(0,original,True,full_window=True)
                with wave.open(str(Path(folder)/'original.wav'),'wb') as out:
                    out.setnchannels(1);out.setsampwidth(2);out.setframerate(16000)
                    out.writeframes(np.zeros(16000,dtype='<i2').tobytes())
                stream=SimpleNamespace(result=SimpleNamespace(text=evidence),accept_waveform=Mock())
                decoder=Mock();decoder.create_stream.return_value=stream
                with patch.object(lab,'decoder',return_value=decoder),patch.object(asr_lab,'LANGUAGE') as language,patch.object(asr_lab.CORRECTOR,'correct',return_value=('This is a class on death.','proposal')):
                    lab._review_audio(0,'',original,0,16000,0,'semantic','Philosophy of mortality.')
                    self.assertEqual(lab.ledger.entries[0].best,expected)
                    self.assertEqual(lab.ledger.entries[0].review_status,status)
                    self.assertEqual(language.submit.call_count,int(status=='verified'))

    def test_stale_semantic_review_cannot_overwrite_newer_text(self):
        import asr_lab
        with tempfile.TemporaryDirectory() as folder:
            lab=asr_lab.Lab();lab.session_dir=Path(folder);lab.config={'model':'small'}
            lab.ledger.update(0,'A newer unrelated sentence.',True,full_window=True)
            with wave.open(str(Path(folder)/'original.wav'),'wb') as out:
                out.setnchannels(1);out.setsampwidth(2);out.setframerate(16000);out.writeframes(np.zeros(16000,dtype='<i2').tobytes())
            decoder=Mock();decoder.create_stream.return_value=SimpleNamespace(result=SimpleNamespace(text='This is a class on death.'),accept_waveform=Mock())
            with patch.object(lab,'decoder',return_value=decoder),patch.object(asr_lab,'LANGUAGE'),patch.object(asr_lab.CORRECTOR,'correct',return_value=('This is a class on death.','proposal')):
                lab._review_audio(0,'','This is a class on debt.',0,16000,0,'semantic')
                self.assertEqual(lab.ledger.entries[0].best,'A newer unrelated sentence.')
    def test_context_candidate_requires_independent_audio(self):
        original='This is a class on debt.'
        proposal='This is a class on death.'
        self.assertTrue(valid_semantic_proposal(original,proposal))
        self.assertFalse(audio_supports_proposal(original,proposal,original))
        self.assertTrue(audio_supports_proposal(original,proposal,'Well this is a class on death today.'))

    def test_word_elsewhere_is_not_audio_support(self):
        self.assertFalse(audio_supports_proposal('This is a class on debt.','This is a class on death.',
                                                'Death is interesting. This is a class on debt.'))
        self.assertFalse(audio_supports_proposal('This is a class on debt.','This is a class on death.',
                                                'This is a class on debt. This is a class on death.'))

    def test_semantic_guard_rejects_facts_and_rewrites(self):
        self.assertFalse(valid_semantic_proposal('I came here in 1992.','He came here in 1992.'))
        self.assertFalse(valid_semantic_proposal('We will not discuss death.','We will discuss death.'))
        self.assertFalse(valid_semantic_proposal('My name is Shelly Kagan.','My name is Shelley Kagan.'))
        self.assertFalse(valid_semantic_proposal('We study philosophy.','We study financial philosophy.'))
        self.assertFalse(valid_semantic_proposal('Sarah teaches philosophy.','Laura teaches philosophy.'))

    def test_semantic_cache_is_separate_from_grammar_cache(self):
        service=ASRCorrector();response=Mock(status_code=200)
        response.json.return_value={'choices':[{'message':{'content':'{"text":"This is a class on death."}'}}]}
        with patch('asr_correction.requests.post',return_value=response) as request:
            self.assertEqual(service.correct('This is a class on debt.','','test','https://example.test')[1],'rejected')
            self.assertEqual(service.correct('This is a class on debt.','','test','https://example.test',semantic=True)[1],'proposal')
            self.assertEqual(request.call_count,2)
    def test_missing_final_prefix_keeps_audio_history(self):
        before='Good morning everyone. Welcome to our philosophy class on death.'
        ledger=TranscriptLedger()
        ledger.update(0,before,full_window=True)
        ledger.update(0,'Welcome to our philosophy class on death.',final=True,revision=True,full_window=True)
        self.assertEqual(ledger.text(),before.replace(' everyone. Welcome',' everyone.\nWelcome'))

    def test_explicit_review_can_remove_false_prefix(self):
        ledger=TranscriptLedger()
        ledger.update(0,'False prefix. Welcome to our philosophy class on death.',full_window=True)
        ledger.update(0,'Welcome to our philosophy class on death.',final=True,revision=True,full_window=True,allow_trim=True)
        self.assertNotIn('False',ledger.text())

    def test_review_only_for_suspect_result(self):
        self.assertEqual(review_reason('Good morning, welcome to our philosophy class.',''),'empty_final')
        self.assertEqual(review_reason('Good morning.','Good morning.'),'')

    def test_anchored_audio_candidate_replaces_without_duplicate(self):
        text='Welcome to our philosophy class.'
        result=select_audio_revision('',text,'Good morning. Welcome to our philosophy class.')
        self.assertEqual(result.count('Welcome'),1)
        self.assertTrue(result.startswith('Good morning'))

    def test_unrelated_candidate_rejected(self):
        self.assertEqual(select_audio_revision('','We study philosophy.','Thank you for watching.'),'We study philosophy.')

    def test_no_free_completion(self):
        self.assertFalse(valid_correction('We study death.','We study financial debt.'))
        self.assertFalse(valid_correction('I came here in 1992.','He came here in 1992.'))
        self.assertFalse(valid_correction('We will not discuss death.','We will discuss death.'))
        self.assertTrue(valid_correction('This sentences has bad grammar.','This sentence has bad grammar.'))

    def test_correction_cache_and_rejected_result(self):
        service=ASRCorrector()
        response=Mock()
        response.status_code=200
        response.json.return_value={'choices':[{'message':{'content':'{"text":"He came here in 1992."}'}}]}
        with patch('asr_correction.requests.post',return_value=response) as request:
            self.assertEqual(service.correct('I came here in 1992.','','test','https://example.test')[0],'I came here in 1992.')
            service.correct('I came here in 1992.','','test','https://example.test')
            self.assertEqual(request.call_count,1)

    def test_quota_error_does_not_retry_every_caption(self):
        service=ASRCorrector()
        response=Mock(status_code=403)
        response.json.return_value={'error':{'code':'insufficient_quota'}}
        with patch('asr_correction.requests.post',return_value=response) as request:
            self.assertEqual(service.correct('That is.','','test','https://example.test')[1],'quota_unavailable')
            self.assertEqual(service.correct('For that.','','test','https://example.test')[1],'quota_unavailable')
            self.assertEqual(request.call_count,1)


if __name__=='__main__':unittest.main()

