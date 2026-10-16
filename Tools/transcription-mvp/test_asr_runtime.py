"""Regression tests for stop/drain, audio conversion, and shared export state."""
import io
import json
import queue
import tempfile
import threading
import unittest
import wave
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import numpy as np
import asr_lab

class RuntimeTests(unittest.TestCase):
    def test_empty_class_does_not_start_postprocessing(self):
        lab=asr_lab.Lab();lab.phase='done'
        with patch.object(lab,'state',return_value={'rows':[]}), patch.object(asr_lab,'start_revision') as revision, patch.object(asr_lab,'start_summary') as summary:
            lab._start_postprocessing()
            revision.assert_not_called();summary.assert_not_called()

    def test_delayed_revision_callback_cannot_summarize_next_recording(self):
        lab=asr_lab.Lab()
        old_directory=Path('completed-class')
        lab.session_dir=old_directory;lab.phase='done'
        old_state={'phase':'done','transcript':'First class content.','rows':[{'id':'0:0','text':'First class content.'}]}
        with patch.object(lab,'state',return_value=old_state), patch.object(asr_lab,'start_revision') as revision, patch.object(asr_lab,'start_summary') as summary:
            lab._start_postprocessing()
            callback=revision.call_args.kwargs['on_done']
            lab.session_dir=Path('new-live-class');lab.phase='recording'
            callback()
        self.assertEqual(summary.call_args.args[0],old_directory)
        self.assertIs(summary.call_args.args[1],old_state)
        self.assertEqual(revision.call_args.args[0],old_directory)

    def test_summary_is_hidden_during_capture_but_available_after_stop(self):
        lab=asr_lab.Lab();lab.session_dir=Path('test-class')
        with patch.object(asr_lab,'read_summary',return_value={'status':'done','text':'stale summary'}):
            for phase in ('loading','recording','paused','stopping'):
                lab.phase=phase
                self.assertIsNone(lab.state()['summary'])
            lab.phase='done'
            self.assertEqual(lab.state()['summary']['text'],'stale summary')

    def test_pause_is_same_session_and_stop_can_drain_it(self):
        lab=asr_lab.Lab();lab.phase='recording'
        lab.pause()
        self.assertEqual(lab.phase,'paused')
        self.assertTrue(lab.pause_event.is_set())
        self.assertIn('pause',lab.audio.get_nowait())
        lab.resume()
        self.assertFalse(lab.pause_event.is_set())
        lab.pause();lab.stop()
        self.assertEqual(lab.phase,'stopping')
        self.assertTrue(lab.stop_event.is_set())

    def setUp(self):
        # Audio lifecycle tests do not run the independent language models.
        # A delayed real revision callback can otherwise escape this test and
        # create a summary thread inside a later test's global Thread spy.
        revision=patch.object(asr_lab,'start_revision')
        revision.start()
        self.addCleanup(revision.stop)
        language = patch.object(asr_lab, 'LANGUAGE')
        mocked = language.start()
        mocked.snapshot.return_value = {}
        mocked.usage = {}
        self.addCleanup(language.stop)
        speakers=patch.object(asr_lab,'SPEAKERS')
        mocked_speakers=speakers.start()
        mocked_speakers.snapshot.return_value={}
        mocked_speakers.error=None
        self.addCleanup(speakers.stop)

    def test_stop_during_decode_drains_final_and_saves_same_text(self):
        entered,release = threading.Event(),threading.Event()
        class Decoder:
            def create_stream(self):
                stream=SimpleNamespace(result=SimpleNamespace(text=''))
                stream.accept_waveform=lambda rate,audio:setattr(stream,'samples',audio)
                return stream
            def decode_stream(self,stream):
                if len(stream.samples)==32000:
                    entered.set()
                    if not release.wait(3): raise RuntimeError('test decode timeout')
                    stream.result.text='We study data structures.'
                else: stream.result.text='We study data structures. This matters.'
        with tempfile.TemporaryDirectory() as folder, patch.object(asr_lab,'ROOT',Path(folder)), patch.object(asr_lab,'models',return_value=[{'name':'small','ready':True}]), patch.object(asr_lab.sherpa_onnx.OfflineRecognizer,'from_whisper',return_value=Decoder()):
            lab=asr_lab.Lab()
            def capture(samples):
                lab.stop_event.wait(3); lab.capture_done.set()
            def vad(directory):
                lab._submit(0,np.full(32000,.03,dtype=np.float32),False,0)
                if not entered.wait(3): raise RuntimeError('decode never entered')
                lab._submit(0,np.full(64000,.03,dtype=np.float32),True,0)
                with lab.condition: lab.vad_done=True; lab.condition.notify_all()
            lab._capture=capture;lab._vad=vad;lab.start({'model':'small'})
            self.assertTrue(entered.wait(3));lab.stop();release.set();lab.worker.join(5)
            self.assertFalse(lab.worker.is_alive());self.assertEqual(lab.phase,'done')
            self.assertEqual(lab.ledger.text(),'We study data structures.\nThis matters.')
            self.assertEqual((lab.session_dir/'transcript.txt').read_text(),lab.state()['transcript'])
            result=json.loads((lab.session_dir/'result.json').read_text())
            self.assertEqual(result['transcript'],lab.state()['transcript'])
            self.assertEqual(result['logs'][-1]['event'],'session_complete')
            self.assertFalse(any(x['event'].endswith('_error') for x in lab.logs))
    def test_model_failure_is_reported_as_failure(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(asr_lab,"ROOT",Path(folder)), patch.object(asr_lab,"models",return_value=[{"name":"small","ready":True}]), patch.object(asr_lab.sherpa_onnx.OfflineRecognizer,"from_whisper",side_effect=RuntimeError("model failed")):
            lab=asr_lab.Lab();lab.start({"model":"small"});lab.worker.join(3)
            self.assertEqual(lab.phase,"error");self.assertEqual(lab.state()["error"],"model failed");self.assertFalse(lab.logs[-1]["success"])
    def test_blocked_file_capture_can_stop(self):
        lab=asr_lab.Lab();lab.config={'source':'wav'};lab.audio=queue.Queue(maxsize=1);lab.audio.put(np.zeros(1))
        thread=threading.Thread(target=lab._capture,args=(np.zeros(32000),));thread.start();lab.stop_event.set();thread.join(1)
        self.assertFalse(thread.is_alive());self.assertTrue(lab.capture_done.is_set())
    def test_stereo_48k_wav_becomes_mono_16k(self):
        data=io.BytesIO()
        with wave.open(data,'wb') as target:
            target.setnchannels(2);target.setsampwidth(2);target.setframerate(48000)
            stereo=np.column_stack((np.full(4800,3276),np.full(4800,9830))).astype('<i2')
            target.writeframes(stereo.tobytes())
        samples=asr_lab.read_wav(data.getvalue())
        self.assertEqual(len(samples),1600);self.assertAlmostEqual(float(samples[100:-100].mean()),.2,places=3)
    def test_live_export_keeps_audio_order(self):
        lab=asr_lab.Lab();lab.ledger.update(0,'First unfinished');lab.ledger.update(1,'Second finished.',True)
        self.assertEqual(lab.state()['transcript'],'First unfinished\nSecond finished.')

if __name__=='__main__':unittest.main()
