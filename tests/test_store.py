import json
import multiprocessing
import tempfile
import unittest
from pathlib import Path

from src.omarchy_toggl.store import Store, remember_range


def _bump(directory, n):
    store = Store(Path(directory))
    for _ in range(n):
        with store.locked():
            state = store.load()
            state["counter"] = state.get("counter", 0) + 1
            store.save(state)


class StoreTests(unittest.TestCase):
    def test_roundtrip_and_schema_guard(self):
        d = Path(tempfile.mkdtemp())
        store = Store(d)
        self.assertEqual(store.load()["schema"], 1)
        (d / "state.json").write_text(json.dumps({"schema": 99, "running": {"id": 1}}))
        self.assertIsNone(store.load()["running"])
        (d / "state.json").write_text("{broken")
        self.assertEqual(store.load()["entries"], [])

    def test_lock_serialises_processes(self):
        d = tempfile.mkdtemp()
        procs = [multiprocessing.Process(target=_bump, args=(d, 25)) for _ in range(4)]
        for p in procs:
            p.start()
        for p in procs:
            p.join()
        self.assertEqual(Store(Path(d)).load()["counter"], 100)
        self.assertEqual([p.name for p in Path(d).iterdir() if p.name.endswith(".tmp")], [])

    def test_range_lru(self):
        state = {"ranges": {}}
        for i in range(6):
            remember_range(state, f"k{i}", {"fetchedAt": i})
        self.assertEqual(sorted(state["ranges"]), ["k2", "k3", "k4", "k5"])


if __name__ == "__main__":
    unittest.main()


class PermissionTests(unittest.TestCase):
    def test_cache_is_private(self):
        import os, stat
        d = Path(tempfile.mkdtemp()) / "omarchy-toggl"
        store = Store(d)
        with store.locked():
            store.save(store.load())
            store.save_ui({"a": 1})
        self.assertEqual(stat.S_IMODE(os.stat(d).st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(os.stat(d / "state.json").st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(d / "ui.json").st_mode), 0o600)
