"""scripts/install-local.sh and scripts/uninstall.sh never change what they did
not write. Each test runs the real scripts from a throwaway copy of this repo
in a temp HOME, with stub `omarchy`, `omarchy-shell` and `secret-tool`."""

import hashlib
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLUGIN_ID = "io.github.eatemall.toggl"
REAL_RSYNC = shutil.which("rsync")

OMARCHY_STUB = """#!/usr/bin/env bash
echo "omarchy $*" >> "$STUB_LOG"
plugins="$HOME/.config/omarchy/plugins"
case "$1 $2" in
  "plugin list")
    [ -n "${STUB_LIST_FAIL:-}" ] && exit 1
    if [ -d "$plugins/$PLUGIN_ID" ]; then echo '[{"id":"'"$PLUGIN_ID"'","enabled":true}]'; else echo '[]'; fi ;;
  "plugin remove")
    [ -n "${STUB_REMOVE_DECLINE:-}" ] && exit 1
    rm -rf -- "$plugins/$3" ;;
esac
exit 0
"""
RSYNC_SHIM = """#!/usr/bin/env bash
# Simulate an interrupted copy: pass only the first 3 files through, then fail.
if [ -n "${STUB_RSYNC_FAIL:-}" ]; then head -z -n 3 | "%s" "$@"; exit 23; fi
exec "%s" "$@"
""" % (REAL_RSYNC, REAL_RSYNC)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


@unittest.skipUnless(REAL_RSYNC and shutil.which("jq") and shutil.which("git"), "needs rsync, jq and git")
class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="omarchy-toggl-inst-"))
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.repo = self.tmp / "repo"
        shutil.copytree(ROOT, self.repo, symlinks=True,
                        ignore=shutil.ignore_patterns("__pycache__", ".pytest_cache"))
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        for name, body in (("omarchy", OMARCHY_STUB), ("omarchy-shell", "#!/bin/sh\nexit 0\n"),
                           ("secret-tool", '#!/bin/sh\necho "secret-tool $*" >> "$STUB_LOG"\n'),
                           ("rsync", RSYNC_SHIM)):
            p = self.bin / name
            p.write_text(body)
            p.chmod(0o755)
        self.target = self.home / ".config/omarchy/plugins" / PLUGIN_ID
        self.marker = self.target / ".omarchy-toggl-install"
        self.wrapper = self.home / ".local/bin/omarchy-toggl"
        self.log = self.tmp / "log"
        self.victim = self.tmp / "victim.txt"
        self.victim.write_text("precious")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_script(self, name, *args, **env):
        full_env = {"HOME": str(self.home), "PATH": f"{self.bin}:{os.environ['PATH']}",
                    "STUB_LOG": str(self.log), "PLUGIN_ID": PLUGIN_ID, "LC_ALL": "C.UTF-8",
                    "GIT_CONFIG_NOSYSTEM": "1", **env}
        return subprocess.run(["bash", str(self.repo / "scripts" / name), *args], capture_output=True,
                              text=True, env=full_env, timeout=60)

    def install(self, **env):
        return self.run_script("install-local.sh", "--no-enable", **env)

    def assertInstalled(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.marker.is_file())

    def assertRefused(self, result, text):
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(text, result.stderr)

    # -- basics ------------------------------------------------------------
    def test_fresh_and_repeat_install(self):
        self.assertInstalled(self.install())
        lines = self.marker.read_text().splitlines()
        self.assertTrue(lines[0].startswith("# omarchy-toggl install manifest v2"))
        self.assertIn(f"{sha(self.repo / 'manifest.json')}  manifest.json", lines)
        self.assertFalse((self.target / "tests").exists())
        self.assertFalse((self.target / ".github").exists())
        self.assertTrue(self.wrapper.is_file())
        # the installed copy is complete enough to run
        cli = subprocess.run(["python3", str(self.target / "src/toggl.py"), "status"], capture_output=True, text=True,
                             env={**os.environ, "XDG_CACHE_HOME": str(self.tmp / "cache")}, timeout=30)
        self.assertEqual(cli.returncode, 0, cli.stderr)
        self.assertEqual(list(self.target.rglob("__pycache__")), [])
        self.assertInstalled(self.install())

    def test_untracked_file_in_checkout_is_not_installed(self):
        (self.repo / "secret-notes.txt").write_text("do not ship")
        self.assertInstalled(self.install())
        self.assertFalse((self.target / "secret-notes.txt").exists())

    def test_bad_manifest_id_writes_nothing(self):
        manifest = self.repo / "manifest.json"
        manifest.write_text(manifest.read_text().replace(f'"{PLUGIN_ID}"', '"../../escape"'))
        self.assertRefused(self.install(), "unexpected plugin id")
        self.assertFalse((self.home / ".config").exists())

    # -- user changes are never overwritten ----------------------------------
    def test_edited_file_is_not_overwritten(self):
        self.install()
        edited = self.target / "src/BarWidget.qml"
        edited.write_text(edited.read_text() + "// mine\n")
        before = edited.read_text()
        (self.repo / "src/BarWidget.qml").write_text((self.repo / "src/BarWidget.qml").read_text() + "// upstream\n")
        self.assertRefused(self.install(), "src/BarWidget.qml")
        self.assertEqual(edited.read_text(), before)

    def test_user_added_file_where_plugin_ships_one(self):
        self.install()
        (self.target / "CHANGELOG.md").unlink()
        lines = [l for l in self.marker.read_text().splitlines() if not l.endswith("  CHANGELOG.md")]
        self.marker.write_text("\n".join(lines) + "\n")
        (self.target / "CHANGELOG.md").write_text("mine")
        self.assertRefused(self.install(), "CHANGELOG.md")
        self.assertEqual((self.target / "CHANGELOG.md").read_text(), "mine")

    def test_symlinked_file_and_folders_are_refused_and_untouched(self):
        self.install()
        # a symlinked file
        (self.target / "LICENSE").unlink()
        (self.target / "LICENSE").symlink_to(self.victim)
        self.assertRefused(self.install(), "LICENSE (symlink)")
        self.assertEqual(self.victim.read_text(), "precious")
        (self.target / "LICENSE").unlink()
        # a symlinked folder holding unchanged plugin files (reviewer's case)
        elsewhere = self.tmp / "ui-elsewhere"
        shutil.move(str(self.target / "src/ui"), elsewhere)
        (self.target / "src/ui").symlink_to(elsewhere)
        self.assertRefused(self.install(), "src/ui (symlinked folder)")
        self.assertTrue((self.target / "src/ui").is_symlink())
        (self.target / "src/ui").unlink()
        shutil.move(str(elsewhere), self.target / "src/ui")
        # a file where a folder should be, and a folder where a file ships
        shutil.move(str(self.target / "docs"), self.tmp / "docs")
        (self.target / "docs").write_text("x")
        self.assertRefused(self.install(), "docs (not a folder)")
        (self.target / "docs").unlink()
        shutil.move(str(self.tmp / "docs"), self.target / "docs")
        (self.target / "README.md").unlink()
        (self.target / "README.md").mkdir()
        self.assertRefused(self.install(), "README.md (not a regular file)")

    def test_refused_run_changes_nothing(self):
        self.install()
        snapshot = {p: p.read_bytes() for p in self.target.rglob("*") if p.is_file()}
        (self.target / "LICENSE").write_text("mine")
        snapshot[self.target / "LICENSE"] = b"mine"
        (self.repo / "README.md").write_text("new upstream readme")
        self.assertNotEqual(self.install().returncode, 0)
        now = {p: p.read_bytes() for p in self.target.rglob("*") if p.is_file()}
        self.assertEqual(now, snapshot)

    # -- stale files -----------------------------------------------------------
    def test_stale_files(self):
        self.install()
        old = self.target / "src/old"
        old.mkdir()
        (old / "A.qml").write_text("a")
        (old / "B.qml").write_text("b")
        with self.marker.open("a") as m:
            m.write(f"{sha(old / 'A.qml')}  src/old/A.qml\n{sha(old / 'B.qml')}  src/old/B.qml\n")
        (old / "B.qml").write_text("b edited")
        result = self.install()
        self.assertInstalled(result)
        self.assertFalse((old / "A.qml").exists())
        self.assertEqual((old / "B.qml").read_text(), "b edited")
        self.assertIn("src/old/B.qml", result.stderr)

    def test_stale_file_under_symlinked_folder_is_not_followed(self):
        self.install()
        ext = self.tmp / "ext"
        ext.mkdir()
        (ext / "S.qml").write_text("s")
        (self.target / "src/extra").symlink_to(ext)
        with self.marker.open("a") as m:
            m.write(f"{sha(ext / 'S.qml')}  src/extra/S.qml\n")
        self.assertInstalled(self.install())
        self.assertEqual((ext / "S.qml").read_text(), "s")

    # -- ownership -------------------------------------------------------------
    def test_foreign_git_managed_and_symlinked_marker_folders(self):
        self.target.mkdir(parents=True)
        (self.target / "x").write_text("theirs")
        self.assertRefused(self.install(), "not created by this installer")
        self.assertEqual((self.target / "x").read_text(), "theirs")
        shutil.rmtree(self.target)
        (self.target / ".git").mkdir(parents=True)
        self.assertRefused(self.install(), "managed by 'omarchy plugin add'")
        shutil.rmtree(self.target)
        self.install()
        self.marker.unlink()
        self.marker.symlink_to(self.victim)
        self.assertRefused(self.install(), "not created by this installer")
        self.assertEqual(self.victim.read_text(), "precious")

    def test_v1_marker_upgrade(self):
        self.install()
        paths = [l[66:] for l in self.marker.read_text().splitlines()[1:] if not l.endswith("@wrapper")]
        v1 = f"# omarchy-toggl install manifest v1: {PLUGIN_ID}\n" + "\n".join(paths) + "\n"
        self.marker.write_text(v1)
        self.assertInstalled(self.install())
        self.assertIn("manifest v2", self.marker.read_text().splitlines()[0])
        # an edited file under a v1 marker cannot be verified -> refused
        self.marker.write_text(v1)
        (self.target / "README.md").write_text("edited")
        self.assertRefused(self.install(), "README.md")

    def test_interrupted_fresh_install_can_be_rerun(self):
        # Without the journal there would be files but no marker -> "not ours" lockout.
        self.assertNotEqual(self.install(STUB_RSYNC_FAIL="1").returncode, 0)
        self.assertInstalled(self.install())

    def test_interrupted_update_then_new_checkout_can_be_rerun(self):
        self.install()
        names = (".gitignore", "CHANGELOG.md", "LICENSE", "README.md")
        for name in names:
            (self.repo / name).write_text((self.repo / name).read_text() + "\nversion 2\n")
        self.assertNotEqual(self.install(STUB_RSYNC_FAIL="1").returncode, 0)
        # the checkout moves on again (another git pull) before the re-run
        for name in names:
            (self.repo / name).write_text((self.repo / name).read_text() + "\nversion 3\n")
        self.assertInstalled(self.install())
        self.assertEqual((self.target / "README.md").read_text(), (self.repo / "README.md").read_text())

    # -- CLI wrapper -----------------------------------------------------------
    def test_wrapper_rules(self):
        self.wrapper.parent.mkdir(parents=True)
        os.mkfifo(self.wrapper)
        result = self.install()           # a FIFO must not hang the installer
        self.assertInstalled(result)
        self.assertTrue(stat.S_ISFIFO(os.lstat(self.wrapper).st_mode))
        self.wrapper.unlink()
        self.wrapper.write_text("#!/bin/sh\necho someone else\n")
        self.assertInstalled(self.install())
        self.assertIn("someone else", self.wrapper.read_text())
        self.wrapper.unlink()
        self.assertInstalled(self.install())   # now ours
        self.wrapper.write_text(self.wrapper.read_text() + "# edited\n")
        self.assertInstalled(self.install())
        self.assertIn("# edited", self.wrapper.read_text())

    # -- uninstall -------------------------------------------------------------
    def make_user_data(self):
        cache = self.home / ".cache/omarchy-toggl"
        cache.mkdir(parents=True)
        (cache / "state.json").write_text("{}")
        (cache / "notes.txt").write_text("mine")
        config = self.home / ".config/omarchy-toggl"
        config.mkdir(parents=True)
        (config / "token").write_text("tok")
        return cache, config

    def test_uninstall_declined_changes_nothing(self):
        self.install()
        cache, config = self.make_user_data()
        result = self.run_script("uninstall.sh", "--purge", STUB_REMOVE_DECLINE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.target.is_dir())
        self.assertTrue(self.wrapper.exists())
        self.assertTrue((cache / "state.json").exists())
        self.assertTrue((config / "token").exists())
        self.assertNotIn("secret-tool", self.log.read_text())

    def test_uninstall_when_plugin_list_fails_still_requires_removal(self):
        self.install()
        cache, _ = self.make_user_data()
        result = self.run_script("uninstall.sh", "--purge", STUB_LIST_FAIL="1", STUB_REMOVE_DECLINE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.target.is_dir())
        self.assertTrue((cache / "state.json").exists())
        self.assertNotIn("Removed", result.stdout)

    def test_uninstall_purge_removes_only_ours(self):
        self.install()
        cache, config = self.make_user_data()
        result = self.run_script("uninstall.sh", "--purge")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.target.exists())
        self.assertFalse(self.wrapper.exists())
        self.assertFalse((cache / "state.json").exists())
        self.assertEqual((cache / "notes.txt").read_text(), "mine")
        self.assertFalse(config.exists())

    def test_uninstall_never_follows_symlinks(self):
        self.install()
        real = self.tmp / "real-cache"
        real.mkdir()
        (real / "state.json").write_text("keep")
        (self.home / ".cache").mkdir()
        (self.home / ".cache/omarchy-toggl").symlink_to(real)
        self.wrapper.write_text(self.wrapper.read_text())  # unchanged content
        self.marker.unlink()
        self.marker.symlink_to(self.victim)                # symlinked marker is not trusted
        result = self.run_script("uninstall.sh", "--purge")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((real / "state.json").read_text(), "keep")
        self.assertEqual(self.victim.read_text(), "precious")
        self.assertTrue(self.wrapper.exists())             # hash unknown -> kept


if __name__ == "__main__":
    unittest.main()
