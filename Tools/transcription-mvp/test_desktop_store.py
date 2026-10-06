import json
import tempfile
import unittest
from pathlib import Path
from desktop_store import DesktopStore

class DesktopStoreTests(unittest.TestCase):
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
