import time
import unittest

from src.omarchy_toggl.api import NetError
from src.omarchy_toggl.sync import UsageError, normalize
from tests.fakes import ME, NOW, FakeOpener, entry, make_engine


def api_with_entries(entries):
    opener = FakeOpener()
    opener.on("GET", "/me", lambda p, b: ME)
    opener.on("GET", "/me/time_entries", lambda p, b: entries)
    return opener


class SyncTests(unittest.TestCase):
    def test_first_sync_fetches_meta_and_window(self):
        opener = api_with_entries([
            entry(1, "2026-09-26T09:00:00Z", "2026-09-26T10:00:00Z", pid=3),
            entry(2, "2026-09-26T11:30:00Z", None, desc="Research"),
        ])
        engine, store = make_engine(opener)
        out = engine.sync(force=True)
        state = out["state"]
        self.assertTrue(state["auth"]["ok"])
        self.assertEqual(state["auth"]["workspaceId"], 7)
        self.assertEqual(state["running"]["id"], 2)
        self.assertEqual([e["id"] for e in state["entries"]], [1])
        self.assertEqual(state["entries"][0]["projectName"], "stonks")
        self.assertEqual(len(state["projects"]), 3)
        self.assertEqual(state["quota"]["user"]["remaining"], 23)
        paths = [r[1] for r in opener.requests]
        self.assertEqual(paths, ["/me", "/me/time_entries"])

    def test_throttle_and_single_call(self):
        opener = api_with_entries([])
        engine, _ = make_engine(opener)
        engine.sync(force=True)
        n = len(opener.requests)
        out = engine.sync()
        self.assertEqual(out["result"], {"skipped": "throttled"})
        self.assertEqual(len(opener.requests), n)

    def test_quota_guard_skips(self):
        opener = api_with_entries([])
        engine, store = make_engine(opener)
        with store.locked():
            state = store.load()
            state["auth"] = {"ok": True, "workspaceId": 7}
            state["quota"] = {"user": {"remaining": 2, "resetsAt": int(time.time()) + 600}}
            store.save(state)
        out = engine.sync(force=True)
        self.assertEqual(out["result"], {"skipped": "quota"})
        self.assertEqual(out["state"]["error"]["kind"], "quota")
        self.assertEqual(opener.requests, [])

    def test_running_detected_by_negative_duration(self):
        e = normalize({"id": 1, "start": "2026-09-26T10:00:00Z", "stop": "2026-09-26T10:00:00Z", "duration": -1789})
        self.assertIsNone(e["stop"])

    def test_start_stops_running_then_creates(self):
        opener = api_with_entries([entry(2, "2026-09-26T11:00:00Z", None)])
        opener.on("PATCH", "/workspaces/7/time_entries/2/stop",
                  lambda p, b: entry(2, "2026-09-26T11:00:00Z", "2026-09-26T12:00:00Z"))
        opener.on("POST", "/workspaces/7/time_entries",
                  lambda p, b: entry(3, b["start"], None, desc=b["description"], pid=b["project_id"]))
        engine, _ = make_engine(opener)
        engine.sync(force=True)
        state = engine.start("Write", 1, ["deep"])["state"]
        self.assertEqual(state["running"]["id"], 3)
        self.assertEqual(state["running"]["projectName"], "Snowball")
        self.assertEqual(state["entries"][0]["id"], 2)
        self.assertEqual(state["entries"][0]["seconds"], 3600)
        methods = [r[0] for r in opener.requests[2:]]
        self.assertEqual(methods, ["PATCH", "POST"])
        self.assertEqual(opener.requests[-1][3]["tags"], ["deep"])

    def test_offline_start_is_queued_then_replayed(self):
        opener = api_with_entries([])
        engine, _ = make_engine(opener)
        engine.sync(force=True)
        opener.offline = True
        state = engine.start("Offline work")["state"]
        self.assertLess(state["running"]["id"], 0)
        self.assertEqual(len(state["pending"]), 1)
        self.assertEqual(state["error"]["kind"], "net")
        temp = state["running"]["id"]
        state = engine.stop()["state"]  # stop of a temp entry is queued too
        self.assertEqual(len(state["pending"]), 2)
        opener.offline = False
        created = {}

        def create(p, b):
            created.update(b)
            return entry(50, b["start"], None, desc=b["description"], pid=None)
        opener.on("POST", "/workspaces/7/time_entries", create)
        opener.on("PUT", "/workspaces/7/time_entries/50",
                  lambda p, b: entry(50, created["start"], b["stop"], desc="Offline work", pid=None))
        opener.on("GET", "/me/time_entries", lambda p, b: [entry(50, created["start"], "2026-09-26T12:00:00Z", desc="Offline work", pid=None)])
        state = engine.sync(force=True)["state"]
        self.assertEqual(state["pending"], [])
        self.assertIsNone(state["error"])
        self.assertEqual(state["entries"][0]["id"], 50)
        self.assertTrue(all(e["id"] != temp for e in state["entries"]))

    def test_update_validation(self):
        opener = api_with_entries([entry(1, "2026-09-26T09:00:00Z", "2026-09-26T10:00:00Z")])
        engine, _ = make_engine(opener)
        engine.sync(force=True)
        with self.assertRaises(UsageError):
            engine.update(1, {"start": "2026-09-26T10:30:00Z"})
        with self.assertRaises(UsageError):
            engine.update(1, {"stop": "2026-09-27T10:30:00Z"})

    def test_update_times_sends_duration(self):
        opener = api_with_entries([entry(1, "2026-09-26T09:00:00Z", "2026-09-26T10:00:00Z")])
        opener.on("PUT", "/workspaces/7/time_entries/1", lambda p, b: entry(1, b["start"], b["stop"]))
        engine, _ = make_engine(opener)
        engine.sync(force=True)
        state = engine.update(1, {"start": "2026-09-26T08:30:00Z"})["state"]
        body = opener.requests[-1][3]
        self.assertEqual(body["duration"], 5400)
        self.assertEqual(state["entries"][0]["seconds"], 5400)

    def test_delete_and_continue(self):
        opener = api_with_entries([entry(1, "2026-09-26T09:00:00Z", "2026-09-26T10:00:00Z", pid=3)])
        opener.on("DELETE", "/workspaces/7/time_entries/1", lambda p, b: None)
        opener.on("POST", "/workspaces/7/time_entries",
                  lambda p, b: entry(9, b["start"], None, desc=b["description"], pid=b["project_id"]))
        engine, _ = make_engine(opener)
        engine.sync(force=True)
        state = engine.continue_entry()["state"]
        self.assertEqual(state["running"]["projectId"], 3)
        self.assertEqual(state["running"]["start"], "2026-09-26T12:00:00Z")
        state = engine.delete([1])["state"]
        self.assertEqual(state["entries"], [])

    def test_idle_discard_continue(self):
        opener = api_with_entries([entry(2, "2026-09-26T10:00:00Z", None)])
        opener.on("PUT", "/workspaces/7/time_entries/2", lambda p, b: entry(2, "2026-09-26T10:00:00Z", b["stop"]))
        opener.on("POST", "/workspaces/7/time_entries", lambda p, b: entry(3, b["start"], None))
        engine, _ = make_engine(opener)
        engine.sync(force=True)
        from src.omarchy_toggl.timeutil import parse_iso
        state = engine.idle_resolve(parse_iso("2026-09-26T11:40:00Z"), "discard-continue")["state"]
        self.assertEqual(state["entries"][0]["stop"], "2026-09-26T11:40:00Z")
        self.assertEqual(state["running"]["id"], 3)

    def test_add_manual_entry(self):
        opener = api_with_entries([])
        opener.on("POST", "/workspaces/7/time_entries", lambda p, b: entry(11, b["start"], b["stop"], desc=b["description"]))
        engine, _ = make_engine(opener)
        engine.sync(force=True)
        from src.omarchy_toggl.timeutil import parse_iso
        state = engine.add("Meeting", 2, [], False, parse_iso("2026-09-26T09:00:00Z"), parse_iso("2026-09-26T09:30:00Z"))["state"]
        self.assertEqual(state["entries"][0]["seconds"], 1800)
        self.assertEqual(opener.requests[-1][3]["duration"], 1800)
        with self.assertRaises(UsageError):
            engine.add("x", None, [], False, parse_iso("2026-09-26T13:00:00Z"), parse_iso("2026-09-26T14:00:00Z"))

    def test_range_fetch_cached(self):
        opener = api_with_entries([entry(1, "2026-08-03T09:00:00Z", "2026-08-03T10:00:00Z")])
        engine, _ = make_engine(opener)
        engine.sync(force=True)
        state = engine.fetch_range("2026-08-03", "2026-08-09")["state"]
        self.assertIn("2026-08-03_2026-08-09", state["ranges"])
        n = len(opener.requests)
        self.assertEqual(engine.fetch_range("2026-08-03", "2026-08-09")["result"], {"skipped": "cached"})
        self.assertEqual(len(opener.requests), n)


if __name__ == "__main__":
    unittest.main()
