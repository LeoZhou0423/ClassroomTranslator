import unittest
from unittest.mock import Mock,patch
from export_dialog import choose_export
class ExportDialogTests(unittest.TestCase):
 def test_cancel(self):
  window=Mock();window.create_file_dialog.return_value=None
  with patch('export_dialog.sys.platform','win32'):self.assertIsNone(choose_export(window,Mock(),'class.docx','docx'))
 def test_empty_rejected(self):
  window=Mock();window.create_file_dialog.return_value=('',)
  with patch('export_dialog.sys.platform','win32'):
   with self.assertRaises(ValueError):choose_export(window,Mock(),'class.docx','docx')
 def test_valid_path_gets_extension(self):
  window=Mock();window.create_file_dialog.return_value=('C:/Users/uking/Documents/class',)
  with patch('export_dialog.sys.platform','win32'):self.assertEqual(choose_export(window,Mock(),'class.docx','docx').suffix,'.docx')
