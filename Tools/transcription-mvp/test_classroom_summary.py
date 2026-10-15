import unittest
import json
import tempfile
from pathlib import Path
from unittest.mock import patch,Mock
from classroom_summary import summary_text,generate,read_summary,validate_summary

class SummaryTests(unittest.TestCase):
    def test_real_assignment_is_not_mistaken_for_a_missing_input_reply(self):
        text='## 作业\n老师要求：请提供实验数据，并于周五提交报告。'
        self.assertEqual(validate_summary(text),text)
    def test_empty_source_does_not_make_a_paid_request(self):
        with patch('classroom_summary.requests.post') as post:
            with self.assertRaises(ValueError):generate('  ','key','https://example.com')
            post.assert_not_called()

    def test_missing_material_reply_is_not_accepted_or_merged(self):
        response=Mock(status_code=200)
        response.json.return_value={'choices':[{'message':{'content':'看起来您还没有粘贴课堂记录的具体内容，后面没有实际的摘要文本。请提供需要整理的课堂记录。'}}]}
        with patch('classroom_summary.requests.post',return_value=response) as post:
            with self.assertRaises(ValueError):generate(('word '*1500+'\n')*3,'key','https://example.com')
            self.assertEqual(post.call_count,1)
            sent=json.loads(post.call_args.kwargs['json']['messages'][1]['content'])
            self.assertIn('word',sent['transcript'])

    def test_existing_invalid_summary_becomes_retryable_error(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)
            (path/'summary.json').write_text(json.dumps({'status':'done','text':'请提供需要整理的课堂记录。'}),encoding='utf-8')
            self.assertEqual(read_summary(path)['status'],'error')

    def test_uses_corrected_text_and_excludes_merged_and_annotations(self):
        rows={'rows':[{'id':'a','text':'raw'},{'id':'b','text':'duplicate'},{'id':'c','text':'[Unclear]'}]}
        language={'a':{'english':'Corrected sentence.','members':['a','b']}}
        self.assertEqual(summary_text(rows,language),'Corrected sentence.')
    def test_excludes_background(self):
        self.assertEqual(summary_text({'rows':[{'id':'a','text':'private conversation'}]},{'a':{'background_candidate':True}}),'')
    def test_missing_key(self):
        with self.assertRaises(ValueError):generate('class','', 'https://example.com')
    def test_long_class_is_summarized_in_chunks_and_merged(self):
        response=Mock(status_code=200)
        response.json.return_value={'choices':[{'message':{'content':'summary'}}]}
        with patch('classroom_summary.requests.post',return_value=response) as post:
            self.assertEqual(generate(('word '*1500+'\n')*3,'test-key','https://example.com'),'summary')
            self.assertEqual(post.call_count,4)
