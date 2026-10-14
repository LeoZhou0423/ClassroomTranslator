import unittest
from unittest.mock import patch,Mock
from classroom_summary import summary_text,generate

class SummaryTests(unittest.TestCase):
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
