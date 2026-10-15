"""Tests for the sealed credential store and the classroom revision pass."""
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import secrets_crypto

TEMP = Path(tempfile.mkdtemp(prefix='lingoclass-secrets-'))


class ShamirTests(unittest.TestCase):
    def test_every_three_of_four_quorum_reconstructs(self):
        secret = bytes(range(32))
        shares = secrets_crypto.split_secret(secret, 3, 4, os.urandom)
        self.assertEqual([len(share) for share in shares], [33] * 4)
        for skip in range(4):
            quorum = [(shares[i][0], shares[i][1:]) for i in range(4) if i != skip]
            self.assertEqual(secrets_crypto.combine_shares(quorum, minimum=3), secret)

    def test_two_shares_are_not_enough(self):
        shares = secrets_crypto.split_secret(b'topsecretmaterial', 3, 4, os.urandom)
        with self.assertRaises(secrets_crypto.SecretError):
            secrets_crypto.combine_shares([(shares[0][0], shares[0][1:]),
                                           (shares[1][0], shares[1][1:])], minimum=3)

    def test_mask_round_trip_and_hides_the_share(self):
        share = bytes(range(16))
        pad = os.urandom(16)
        masked = secrets_crypto.mask_share(share, pad)
        self.assertNotEqual(masked, share)
        self.assertEqual(secrets_crypto.mask_share(masked, pad), share)


class SealTests(unittest.TestCase):
    def setUp(self):
        self.passphrase = 'unit-test-passphrase'
        self.document = secrets_crypto.seal_document(b'{"bigmodel":"sk-unit"}', self.passphrase, epoch=4)

    def test_round_trip(self):
        payload, epoch = secrets_crypto.open_document(json.loads(json.dumps(self.document)), self.passphrase)
        self.assertEqual(json.loads(payload), {'bigmodel': 'sk-unit'})
        self.assertEqual(epoch, 4)

    def test_modified_field_fails_the_attestation(self):
        tampered = dict(self.document, epoch=99)
        with self.assertRaises(secrets_crypto.SecretError):
            secrets_crypto.open_document(tampered, self.passphrase)

    def test_revoked_document_refuses_to_open(self):
        revoked = secrets_crypto.seal_document(b'{}', self.passphrase, epoch=5, revoked=True)
        with self.assertRaises(secrets_crypto.SecretError):
            secrets_crypto.open_document(revoked, self.passphrase)

    def test_wrong_passphrase_is_rejected(self):
        with self.assertRaises(secrets_crypto.SecretError):
            secrets_crypto.open_document(json.loads(json.dumps(self.document)), 'not the passphrase')

    def test_unsupported_kdf_parameters_are_rejected(self):
        hostile = json.loads(json.dumps(self.document))
        hostile['kdf']['n'] = 1024
        with self.assertRaises(secrets_crypto.SecretError):
            secrets_crypto.open_document(hostile, self.passphrase)


class StoreTests(unittest.TestCase):
    def test_environment_key_wins_over_the_repository(self):
        import secrets_store
        with patch.dict(os.environ, {'LINGOCLASS_MIMO_KEY': 'sk-from-environment'}), \
                patch.object(secrets_store, 'load', side_effect=AssertionError('repository was consulted')):
            self.assertEqual(secrets_store.provider_key('mimo'), 'sk-from-environment')

    def test_environment_key_does_not_access_keychain(self):
        import secrets_store
        with patch.dict(os.environ, {'LINGOCLASS_MIMO_KEY': 'test-env'}), patch.object(secrets_store, '_from_keyring', side_effect=AssertionError('keychain accessed')):
            self.assertEqual(secrets_store.provider_key('mimo'), 'test-env')

    def test_denied_keychain_is_not_retried_by_status_polling(self):
        import secrets_store
        with patch.dict(secrets_store._keyring_cache, {}, clear=True), patch('keyring.get_password', side_effect=RuntimeError('denied')) as read:
            for _ in range(10):
                self.assertEqual(secrets_store._from_keyring('mimo'), '')
            self.assertEqual(read.call_count, 1)

    def test_successful_keychain_read_is_cached(self):
        import secrets_store
        with patch.dict(secrets_store._keyring_cache, {}, clear=True), patch('keyring.get_password', return_value='test-key') as read:
            for _ in range(10):
                self.assertEqual(secrets_store._from_keyring('mimo'), 'test-key')
            self.assertEqual(read.call_count, 1)

    def test_unknown_provider_resolves_to_empty(self):
        import secrets_store
        with patch.dict(os.environ, {}, clear=False):
            self.assertEqual(secrets_store.provider_key('nobody'), '')

    def test_aliases_map_to_the_same_provider(self):
        import secrets_store
        with patch.dict(os.environ, {'LINGOCLASS_ZHIPU_KEY': 'sk-alias'}):
            self.assertEqual(secrets_store.provider_key('bigmodel'), 'sk-alias')
            self.assertEqual(secrets_store.provider_key('glm'), 'sk-alias')

    def test_debug_escape_hatch(self):
        import secrets_store
        with patch.dict(os.environ, {'LINGOCLASS_ALLOW_DEBUG': '1', 'LD_PRELOAD': '/tmp/evil.so'}), \
                patch.object(secrets_store, '_debugger_attached', return_value=True):
            self.assertFalse(secrets_store._tamper_detected())
        with patch.dict(os.environ, {}, clear=False), \
                patch.object(secrets_store, '_debugger_attached', return_value=True):
            self.assertTrue(secrets_store._tamper_detected())


class RevisionTests(unittest.TestCase):
    def _rows(self):
        return [
            {'id': '0:0', 'original': 'My name is Shelly Kagan.', 'english': 'My name is Shelly Kagan.', 'status': 'done'},
            {'id': '0:1', 'original': 'I will eventually respond to Professor Kagan.',
             'english': 'I will eventually respond to Professor Kagan.', 'status': 'done', 'uncertain': True},
            {'id': '1:0', 'original': 'The reading is due Friday.', 'english': 'The reading is due Friday.', 'status': 'done'},
            {'id': '1:1', 'original': '[Unclear]', 'english': '', 'status': 'done', 'annotation_suppressed': True},
            {'id': '2:0', 'original': 'I will text you about dinner.', 'english': 'I will text you about dinner.',
             'status': 'done', 'background_candidate': True},
            {'id': '3:0', 'original': 'Today we start with the soul.', 'english': 'Today we start with the soul.',
             'status': 'pending'},
        ]

    def test_glossary_recovers_speaker_names(self):
        import classroom_revision
        terms = classroom_revision.glossary_from(self._rows())
        self.assertIn('Shelly Kagan', terms)
        self.assertIn('Shelly', terms)

    def test_only_suspicious_rows_are_selected(self):
        import classroom_revision
        rows = self._rows()
        # "My name is ..." and "respond to Professor ..." are the constructions the
        # fast pass flattens, so both are flagged; plain lecture prose is not.
        flags = [classroom_revision.suspicious(row) for row in rows]
        self.assertEqual(flags, [True, True, False, False, False, False])
        # A dropped Latin name is always worth a second pass.
        rows[2]['latin_name_gaps'] = ['Shelly Kagan']
        self.assertTrue(classroom_revision.suspicious(rows[2]))

    def test_revisable_excludes_suppressed_background_and_unfinished_rows(self):
        import classroom_revision
        rows = self._rows()
        self.assertEqual([classroom_revision.revisable(row) for row in rows],
                         [True, True, True, False, False, False])

    def test_ordered_rows_sorts_by_utterance_then_segment(self):
        import classroom_revision
        rows = classroom_revision.ordered_rows({'10:2': {'id': '10:2'}, '2:11': {'id': '2:11'}, '2:3': {'id': '2:3'}})
        self.assertEqual([row['id'] for row in rows], ['2:3', '2:11', '10:2'])

    def test_revise_replaces_only_the_translation(self):
        import classroom_revision
        directory = TEMP / 'revise-fixture'
        directory.mkdir(parents=True, exist_ok=True)
        language = {'0:0': {'id': '0:0', 'original': 'My name is Shelly Kagan.',
                            'english': '我叫谢莉·卡根', 'chinese': '我叫谢莉·卡根',
                            'teacher_probability': 0.95, 'background_candidate': False, 'status': 'done'}}
        (directory / 'language.json').write_text(json.dumps(language), encoding='utf-8')
        result = {'english': 'My name is Shelly Kagan.', 'chinese': '我叫 Shelly Kagan', 'model': 'mimo-v2.6-flash'}
        with patch.object(classroom_revision.PIPELINE, 'process', return_value=result):
            changed = classroom_revision.revise(directory, 'sk-unit', 'https://api.xiaomimimo.com/v1', full=True)
        saved = json.loads((directory / 'language.json').read_text(encoding='utf-8'))['0:0']
        self.assertEqual(changed, 1)
        self.assertEqual(saved['english'], 'My name is Shelly Kagan.')
        self.assertEqual(saved['chinese'], '我叫 Shelly Kagan')
        self.assertTrue(saved['revised'])
        self.assertEqual(saved['revision_model'], 'mimo-v2.6-flash')
        # The live pass owns the speaker verdicts; revision must not touch them.
        self.assertEqual(saved['teacher_probability'], 0.95)
        self.assertFalse(saved['background_candidate'])

    def test_revise_keeps_the_original_when_the_model_returns_nothing(self):
        import classroom_revision
        directory = TEMP / 'revise-empty'
        directory.mkdir(parents=True, exist_ok=True)
        language = {'0:0': {'id': '0:0', 'original': 'Hello.', 'english': 'Hello.', 'chinese': '你好。', 'status': 'done'}}
        (directory / 'language.json').write_text(json.dumps(language), encoding='utf-8')
        with patch.object(classroom_revision.PIPELINE, 'process', return_value={'english': '', 'chinese': ''}):
            changed = classroom_revision.revise(directory, 'sk-unit', 'https://api.xiaomimimo.com/v1', full=True)
        saved = json.loads((directory / 'language.json').read_text(encoding='utf-8'))['0:0']
        self.assertEqual(changed, 0)
        self.assertEqual(saved['chinese'], '你好。')
        self.assertNotIn('revised', saved)

    def test_start_revision_without_a_key_skips_quietly(self):
        import classroom_revision
        directory = TEMP / 'revise-nokey'
        directory.mkdir(parents=True, exist_ok=True)
        done = []
        with patch.object(classroom_revision, 'revision_credentials', return_value=('', '')):
            classroom_revision.start_revision(directory, on_done=lambda: done.append(True))
        state = json.loads((directory / 'revision.json').read_text(encoding='utf-8'))
        self.assertEqual(state['status'], 'skipped')
        self.assertTrue(done)


if __name__ == '__main__':
    unittest.main()
