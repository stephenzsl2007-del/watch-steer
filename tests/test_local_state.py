import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('local_state', Path(__file__).resolve().parents[1] / 'tools/local_state.py')
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)


class LocalStateTests(unittest.TestCase):
    def test_fresh_users_have_distinct_persistent_private_tokens(self):
        with tempfile.TemporaryDirectory() as base:
            tokens = []
            for user in ['first', 'second']:
                folder = Path(base) / user
                with patch.dict(os.environ, {'WATCHSTEER_STATE_DIR': str(folder)}, clear=True):
                    token = state.pairing_token()
                    self.assertEqual(token, state.pairing_token())
                    self.assertGreaterEqual(len(token), 24)
                    self.assertEqual(folder.stat().st_mode & 0o777, 0o700)
                    self.assertEqual((folder / 'pairing-token').stat().st_mode & 0o777, 0o600)
                    tokens.append(token)
            self.assertNotEqual(*tokens)

    def test_override_preserves_existing_pairing(self):
        with tempfile.TemporaryDirectory() as base:
            with patch.dict(os.environ, {'WATCHSTEER_STATE_DIR': base}, clear=True):
                original = state.pairing_token()
                with patch.dict(os.environ, {'WATCHSTEER_TOKEN': 'temporary-test-override-0123456789'}):
                    self.assertNotEqual(state.pairing_token(), original)
                self.assertEqual(state.pairing_token(), original)

    def test_invalid_override_rejected(self):
        with tempfile.TemporaryDirectory() as base:
            with patch.dict(os.environ, {'WATCHSTEER_STATE_DIR': base, 'WATCHSTEER_TOKEN': 'short'}, clear=True):
                with self.assertRaises(ValueError): state.pairing_token()
