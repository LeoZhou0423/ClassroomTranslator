import unittest
from grammar_model import safe_suggestion


class GrammarGuards(unittest.TestCase):
    def test_tense_is_protected(self):
        self.assertFalse(safe_suggestion('Now as I say, this is a class.', 'Now as I said, this is a class.'))
    def test_small_grammar_edit(self):
        self.assertTrue(safe_suggestion('This sentences has bad grammar.', 'This sentence has bad grammar.'))

    def test_protect_number(self):
        self.assertFalse(safe_suggestion('This is Philosophy 176.', 'This is Philosophy 167.'))

    def test_protect_name(self):
        self.assertFalse(safe_suggestion('My name is Shelly Kagan.', 'My name is Shelley Kagan.'))

    def test_protect_negation(self):
        self.assertFalse(safe_suggestion('We will not discuss death.', 'We will discuss death.'))

    def test_reject_empty_or_rewrite(self):
        self.assertFalse(safe_suggestion('We study philosophy.', ''))
        self.assertFalse(safe_suggestion('We study philosophy.', 'People enjoy sports.'))


if __name__ == '__main__':
    unittest.main()
