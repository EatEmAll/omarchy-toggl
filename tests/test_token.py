import os
import tempfile
import unittest
from unittest import mock

from src.omarchy_toggl import token


class TokenTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.env = mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": self.dir}, clear=False)
        self.env.start()
        os.environ.pop("TOGGL_API_TOKEN", None)
        self.nokeyring = mock.patch.object(token, "_secret_tool", return_value=None)
        self.nokeyring.start()

    def tearDown(self):
        self.env.stop()
        self.nokeyring.stop()

    def test_file_fallback_is_0600(self):
        self.assertEqual(token.set_token("abc123"), "file")
        path = token.token_file()
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        self.assertEqual(token.get_token(), ("abc123", "file"))

    def test_insecure_file_rejected(self):
        token.set_token("abc123")
        os.chmod(token.token_file(), 0o644)
        with self.assertRaises(token.TokenError):
            token.get_token()

    def test_env_and_missing(self):
        with self.assertRaises(token.TokenError):
            token.get_token()
        os.environ["TOGGL_API_TOKEN"] = "envtok"
        self.assertEqual(token.get_token(), ("envtok", "env"))

    def test_invalid_token(self):
        with self.assertRaises(token.TokenError):
            token.set_token("has space")

    def test_clear(self):
        token.set_token("abc")
        token.clear_token()
        self.assertFalse(token.token_file().exists())


if __name__ == "__main__":
    unittest.main()
