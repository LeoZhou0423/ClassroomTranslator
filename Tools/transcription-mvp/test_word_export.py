import io
import unittest
import zipfile
from xml.etree import ElementTree
from word_export import word_document

class WordExportTests(unittest.TestCase):
    def test_valid_ooxml_preserves_bilingual_content_and_xml_characters(self):
        text='老师: Good morning & welcome <everyone>.\n早上好，欢迎大家。\n\nStudent: Why?'
        output=word_document(text,'课堂记录')
        with zipfile.ZipFile(io.BytesIO(output)) as bundle:
            for name in bundle.namelist():ElementTree.fromstring(bundle.read(name))
            document=ElementTree.fromstring(bundle.read('word/document.xml'))
            visible=[e.text or '' for e in document.iter('{http://schemas.openxmlformats.org/wordprocessingml/2006/main}t')]
            self.assertEqual(visible,['课堂记录',*text.splitlines()])

    def test_empty_export_fails_explicitly(self):
        with self.assertRaises(ValueError):word_document('  ')

if __name__=='__main__':unittest.main()
