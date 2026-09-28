"""Write-path safety: nothing the backend does may write, chmod, lock or read
*through* a planted symlink / hard link / FIFO, or use predictable temp names."""

import contextlib
import json
import os
import signal
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from src.omarchy_toggl import safefs, token
from src.omarchy_toggl.store import Store, cache_dir

ROOT = Path(__file__).resolve().parents[1]


@contextlib.contextmanager
def deadline(seconds=3):
    """Fail instead of hanging (e.g. on a FIFO)."""
    def boom(*_):
        raise AssertionError("operation blocked")
    old = signal.signal(signal.SIGALRM, boom)
    signal.alarm(seconds)
    try:
        yield
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old)


def mode(path):
    return stat.S_IMODE(os.lstat(path).st_mode)


class StoreSafety(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp())
        self.dir = self.base / "omarchy-toggl"
        self.victim = self.base / "victim.txt"
        self.victim.write_text("precious")
        os.chmod(self.victim, 0o644)

    def test_symlink_at_state_is_replaced_not_followed(self):
        self.dir.mkdir()
        os.symlink(self.victim, self.dir / "state.json")
        store = Store(self.dir)
        with store.locked():
            store.save(store.load())
        self.assertEqual(self.victim.read_text(), "precious")
        self.assertFalse((self.dir / "state.json").is_symlink())
        self.assertEqual(mode(self.dir / "state.json"), 0o600)

    def test_hard_link_at_ui_is_replaced_not_written_through(self):
        self.dir.mkdir()
        os.link(self.victim, self.dir / "ui.json")
        store = Store(self.dir)
        store.save_ui({"a": 1})
        self.assertEqual(self.victim.read_text(), "precious")
        self.assertEqual(json.loads((self.dir / "ui.json").read_text()), {"a": 1})

    def test_no_predictable_temp_name(self):
        self.dir.mkdir()
        for name in ("state.json", "ui.json"):
            os.symlink(self.victim, self.dir / f".{name}.{os.getpid()}.tmp")
        store = Store(self.dir)
        store.save(store.load())
        store.save_ui({"x": 1})
        self.assertEqual(self.victim.read_text(), "precious")
        leftovers = [p.name for p in self.dir.iterdir() if p.name.endswith(".tmp") and not p.is_symlink()]
        self.assertEqual(leftovers, [])

    def test_failed_write_leaves_no_temp_file(self):
        store = Store(self.dir)
        with mock.patch("os.replace", side_effect=OSError("disk full")), self.assertRaises(OSError):
            store.save({"schema": 1})
        self.assertEqual([p for p in self.dir.iterdir() if p.name.endswith(".tmp")], [])

    def test_symlinked_cache_folder_is_refused_and_target_unchanged(self):
        target = self.base / "elsewhere"
        target.mkdir(mode=0o755)
        os.chmod(target, 0o755)
        os.symlink(target, self.dir)
        store = Store(self.dir)
        with self.assertRaises(safefs.UnsafePath):
            with store.locked():
                pass
        self.assertEqual(mode(target), 0o755)
        self.assertEqual(list(target.iterdir()), [])

    def test_folder_owned_by_someone_else_is_refused(self):
        self.dir.mkdir()
        with mock.patch("os.getuid", return_value=os.getuid() + 1), self.assertRaises(safefs.UnsafePath):
            with Store(self.dir).locked():
                pass

    def test_lock_uses_no_lock_file(self):
        self.dir.mkdir()
        os.symlink(self.victim, self.dir / "state.lock")
        with Store(self.dir).locked():
            pass
        self.assertEqual(self.victim.read_text(), "precious")
        self.assertEqual(sorted(p.name for p in self.dir.iterdir()), ["state.lock"])

    def test_fifo_and_symlink_reads_do_not_hang_or_follow(self):
        self.dir.mkdir(mode=0o700)
        os.mkfifo(self.dir / "state.json")
        os.symlink("/dev/zero", self.dir / "ui.json")
        store = Store(self.dir)
        with deadline():
            self.assertIsNone(store.load()["running"])  # treated as missing, not followed
            self.assertEqual(store.load_ui(), {})
            store.save(store.load())                      # and replaced by the next write
        self.assertTrue(stat.S_ISREG(os.lstat(self.dir / "state.json").st_mode))

    def test_utf8_round_trip_under_c_locale(self):
        code = (
            "import sys; sys.path.insert(0, %r)\n"
            "from src.omarchy_toggl.store import Store\n"
            "s = Store(%r); st = s.load(); st['entries'] = [{'description': '\\u0412\\u0441\\u0442 \\u4f1a\\u8b70 \\u2713'}]; s.save(st)\n"
            "print(ascii(Store(%r).load()['entries'][0]['description']))\n"
        ) % (str(ROOT), str(self.dir), str(self.dir))
        env = {**os.environ, "LC_ALL": "C", "LANG": "C", "PYTHONUTF8": "0", "PYTHONIOENCODING": "utf-8"}
        out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, env=env, encoding="utf-8")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.strip(), repr("\u0412\u0441\u0442 \u4f1a\u8b70 \u2713").encode("ascii", "backslashreplace").decode())

    def test_relative_xdg_is_ignored(self):
        with mock.patch.dict(os.environ, {"XDG_CACHE_HOME": "relative/cache", "XDG_CONFIG_HOME": "rel"}):
            self.assertTrue(cache_dir().is_absolute())
            self.assertTrue(token.token_file().is_absolute())


class TokenSafety(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp())
        self.env = mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": str(self.base / "config")})
        self.env.start()
        self.nokeyring = mock.patch.object(token, "_secret_tool", return_value=None)
        self.nokeyring.start()
        self.victim = self.base / "victim.txt"
        self.victim.write_text("precious")
        os.chmod(self.victim, 0o644)
        self.folder = self.base / "config" / "omarchy-toggl"

    def tearDown(self):
        self.env.stop()
        self.nokeyring.stop()

    def test_symlink_at_token_is_replaced_not_followed(self):
        self.folder.mkdir(parents=True, mode=0o700)
        os.symlink(self.victim, self.folder / "token")
        token.set_token("abc123")
        self.assertEqual(self.victim.read_text(), "precious")
        self.assertEqual(mode(self.victim), 0o644)
        self.assertFalse((self.folder / "token").is_symlink())
        self.assertEqual(mode(self.folder / "token"), 0o600)
        self.assertEqual(token.get_token(), ("abc123", "file"))

    def test_hard_link_at_token_is_replaced(self):
        self.folder.mkdir(parents=True, mode=0o700)
        os.link(self.victim, self.folder / "token")
        token.set_token("abc123")
        self.assertEqual(self.victim.read_text(), "precious")

    def test_dangling_symlink_is_not_created_through(self):
        self.folder.mkdir(parents=True, mode=0o700)
        ghost = self.base / "ghost"
        os.symlink(ghost, self.folder / "token")
        token.set_token("abc123")
        self.assertFalse(ghost.exists())

    def test_symlinked_token_folder_is_refused(self):
        target = self.base / "shared"
        target.mkdir(mode=0o755)
        os.chmod(target, 0o755)
        (self.base / "config").mkdir()
        os.symlink(target, self.folder)
        with self.assertRaises(OSError):
            token.set_token("abc123")
        self.assertEqual(mode(target), 0o755)
        self.assertEqual(list(target.iterdir()), [])

    def test_symlinked_or_fifo_token_is_refused_on_read(self):
        self.folder.mkdir(parents=True, mode=0o700)
        os.symlink("/dev/zero", self.folder / "token")
        with deadline(), self.assertRaises(token.TokenError):
            token.get_token()
        os.unlink(self.folder / "token")
        os.mkfifo(self.folder / "token", 0o600)
        with deadline(), self.assertRaises(token.TokenError):
            token.get_token()

    def test_logout_removes_dangling_symlink_but_not_target(self):
        self.folder.mkdir(parents=True, mode=0o700)
        os.symlink(self.victim, self.folder / "token")
        token.clear_token()
        self.assertFalse(os.path.lexists(self.folder / "token"))
        self.assertEqual(self.victim.read_text(), "precious")


class RuntimeWrites(unittest.TestCase):
    def test_cli_writes_no_bytecode_into_plugin_folder(self):
        with tempfile.TemporaryDirectory() as plugin:
            src = Path(plugin) / "src"
            subprocess.run(["cp", "-r", str(ROOT / "src"), str(src)], check=True)
            for cache in src.rglob("__pycache__"):
                subprocess.run(["rm", "-rf", str(cache)], check=True)
            env = {**os.environ, "XDG_CACHE_HOME": tempfile.mkdtemp(), "PYTHONDONTWRITEBYTECODE": ""}
            env.pop("PYTHONDONTWRITEBYTECODE")
            out = subprocess.run([sys.executable, str(src / "toggl.py"), "status"], capture_output=True, text=True, env=env)
            self.assertEqual(out.returncode, 0, out.stderr)
            self.assertEqual(list(src.rglob("__pycache__")), [])


if __name__ == "__main__":
    unittest.main()
