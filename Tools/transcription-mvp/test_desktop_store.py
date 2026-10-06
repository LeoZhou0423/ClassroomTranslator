import json
import tempfile
import unittest
from pathlib import Path
from desktop_store import DesktopStore

class DesktopStoreTests(unittest.TestCase):
    def test_classroom_batch_edit_and_voice_identity_names(self):
        with tempfile.TemporaryDirectory() as directory:
            store=DesktopStore(directory)
            session=Path(directory,'sessions','20261006-120000-a123');session.mkdir(parents=True)
            (session/'result.json').write_text(json.dumps({'rows':[{'id':'a','utterance':0},{'id':'b','utterance':1},{'id':'c','utterance':2}],'transcript':'Original.'}))
            (session/'speakers.json').write_text(json.dumps({'0':{'speaker_id':7,'label':'老师'},'1':{'speaker_id':7,'label':'老师'},'2':{'speaker_id':8,'label':'老师'}}))
            store.edit_classroom(session.name,[{'id':'a','original':'First.','translated':'第一句'},{'id':'b','original':'Second.','translated':'第二句'}],{'7':'Shelly'})
            result=DesktopStore(directory).record(session.name)
            labels=[result['speaker_names'].get(str(p['speaker_id']),p['label']) for p in result['speaker_rows'].values()]
            self.assertEqual(labels,['Shelly','Shelly','老师'])
            self.assertEqual(result['content_edits']['b']['original'],'Second.')
            with self.assertRaises(ValueError):store.edit_classroom(session.name,[{'id':'a','original':'Changed.'}],{'999':'Invalid'})
            self.assertEqual(store.record(session.name)['content_edits']['a']['original'],'First.')

    def test_content_edits_survive_background_updates_and_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            store=DesktopStore(directory)
            session=Path(directory,'sessions','20261006-120000-a123');session.mkdir(parents=True)
            source={'transcript':'Hello.','rows':[{'id':'0','text':'Hello.'}],'config':{}}
            (session/'result.json').write_text(json.dumps(source))
            store.edit_content(session.name,'0',{'speaker':'Shelly','original':'Good morning.','translated':'早上好。'})
            (session/'language.json').write_text(json.dumps({'0':{'english':'Hello.','chinese':'旧译文'}}))
            restored=DesktopStore(directory).record(session.name)
            self.assertEqual(restored['content_edits']['0']['speaker'],'Shelly')
            self.assertEqual(restored['content_edits']['0']['original'],'Good morning.')
            self.assertEqual(json.loads((session/'result.json').read_text()),source)
            with self.assertRaises(ValueError):store.edit_content(session.name,'missing',{'original':'Invalid.'})

    def test_edit_delete_preserves_recordings(self):
        with tempfile.TemporaryDirectory() as directory:
            store=DesktopStore(directory)
            course=store.create_course({'name':'Old'})
            session=Path(directory,'sessions','20261006-120000-a123');session.mkdir(parents=True)
            (session/'result.json').write_text(json.dumps({'transcript':'Hello.','config':{'course_id':course['id'],'course_name':'Old'}}))
            store.edit_course(course['id'],{'name':'New','scheduleType':'weekly'})
            self.assertEqual(DesktopStore(directory).library()['courses'][0]['name'],'New')
            store.delete_course(course['id'])
            library=DesktopStore(directory).library()
            self.assertEqual(library['courses'],[])
            self.assertEqual(len(library['records']),1)
            self.assertTrue((session/'result.json').exists())

    def test_course_and_preferences_survive_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            store=DesktopStore(directory)
            course=store.create_course({'name':'  Data structures  ','accentCode':'en-US'})
            store.update_settings({'model':'tiny','font_size':17,'api_key':'must-not-persist'})
            restored=DesktopStore(directory)
            self.assertEqual(restored.library()['courses'][0]['name'],'Data structures')
            self.assertEqual(restored.settings()['model'],'tiny')
            self.assertNotIn('must-not-persist',Path(directory,'library.json').read_text())
            self.assertEqual(restored.library()['courses'][0]['id'],course['id'])

    def test_history_reads_latest_background_translation(self):
        with tempfile.TemporaryDirectory() as directory:
            store=DesktopStore(directory)
            session=Path(directory,'sessions','20261005-120000-a123');session.mkdir(parents=True)
            result={'transcript':'Hello there.','rows':[{'id':'0:0','text':'Hello there.','final':True}],'metrics':{'captured_seconds':4},'config':{}}
            (session/'result.json').write_text(json.dumps(result))
            (session/'language.json').write_text(json.dumps({'0:0':{'chinese':'Hello in Chinese'}}))
            self.assertEqual(len(store.library()['records']),1)
            self.assertEqual(store.record(session.name)['language_rows']['0:0']['chinese'],'Hello in Chinese')

    def test_recurrence_and_record_rename_survive_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            store=DesktopStore(directory)
            for repeat in ('single','daily','weekly','monthly'):
                self.assertEqual(store.create_course({'name':repeat,'scheduleType':repeat})['scheduleType'],repeat)
            with self.assertRaises(ValueError):store.create_course({'name':'bad','scheduleType':'invalid'})
            session=Path(directory,'sessions','20261005-120000-a123');session.mkdir(parents=True)
            (session/'result.json').write_text(json.dumps({'transcript':'Hello.','config':{}}))
            store.rename_record(session.name,'Week 1')
            self.assertEqual(DesktopStore(directory).library()['records'][0]['title'],'Week 1')
            with self.assertRaises(ValueError):store.rename_record(session.name,'  ')

    def test_path_traversal_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):DesktopStore(directory).record_path('../models')

if __name__=='__main__':unittest.main()
