"""Offline queue integrity: nothing queued is duplicated, reordered, silently
dropped or applied to the wrong entry."""

import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from email.message import Message
from pathlib import Path

from src.omarchy_toggl.api import QuotaError
from src.omarchy_toggl.sync import MAX_REPLAY, UsageError, _merge_stops
from tests.fakes import ME, FakeOpener, entry, make_engine

ROOT = Path(__file__).resolve().parents[1]


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.opener = FakeOpener().on("GET", "/me", lambda p, b: ME).on("GET", "/me/time_entries", lambda p, b: [])
        self.next_id = iter(range(500, 10000))
        self.created = []

        def create(p, b):
            self.created.append(b)
            return entry(next(self.next_id), b["start"], b.get("stop"), desc=b.get("description", ""), pid=None)
        self.opener.on("POST", "/workspaces/7/time_entries", create)
        self.engine, self.store = make_engine(self.opener)
        self.engine.sync(force=True)

    def set_pending(self, ops):
        with self.store.locked():
            state = self.store.load()
            state["pending"] = ops
            self.store.save(state)

    def pending(self):
        with self.store.locked():
            return self.store.load()["pending"]

    def create_op(self, temp, desc="Offline", running=False):
        body = {"description": desc, "start": "2026-09-26T09:00:00Z"}
        body.update({"duration": -1} if running else {"stop": "2026-09-26T10:00:00Z", "duration": 3600})
        return {"op": "create", "wid": 7, "tempId": temp, "body": body}

    # 1. non-network errors mid-replay never cause re-created duplicates
    def test_transient_error_keeps_progress_no_duplicates(self):
        calls = {"n": 0}

        def update(p, b):
            calls["n"] += 1
            if calls["n"] == 1:
                return (402, "quota")   # quota headers present -> QuotaError (transient)
            return entry(42, "2026-09-26T09:00:00Z", "2026-09-26T10:00:00Z")
        self.opener.on("PUT", "/workspaces/7/time_entries/42", update)
        self.set_pending([self.create_op(-10), self.create_op(-11),
                          {"op": "update", "wid": 7, "id": 42, "body": {"description": "x"}}])
        with self.assertRaises(QuotaError):
            self.engine.sync(force=True)
        self.assertEqual(len(self.created), 2)
        self.assertEqual([op["op"] for op in self.pending()], ["update"])
        self.engine._api = None
        self.engine.sync(force=True)
        self.assertEqual(len(self.created), 2)          # never re-sent
        self.assertEqual(self.pending(), [])

    def test_permanent_refusal_is_dropped_and_reported_not_blocking(self):
        self.opener.on("PUT", "/workspaces/7/time_entries/42", lambda p, b: (400, "project archived"))
        self.set_pending([{"op": "update", "wid": 7, "id": 42, "body": {"description": "x"}}, self.create_op(-12)])
        state = self.engine.sync(force=True)["state"]
        self.assertEqual(state["pending"], [])
        self.assertEqual(len(self.created), 1)          # the queue kept moving
        self.assertEqual(len(state["dropped"]), 1)
        self.assertIn("project archived", state["dropped"][0]["reason"])

    def test_create_with_unreadable_reply_is_not_resent(self):
        self.opener.on("POST", "/workspaces/7/time_entries", lambda p, b: (self.created.append(b), {"weird": 1})[1])
        self.set_pending([self.create_op(-13)])
        state = self.engine.sync(force=True)["state"]
        self.assertEqual(state["pending"], [])
        self.engine.sync(force=True)
        self.assertEqual(len(self.created), 1)
        self.assertEqual(len(state["dropped"]), 1)

    def test_refused_create_is_reported(self):
        self.opener.on("POST", "/workspaces/7/time_entries", lambda p, b: (404, "workspace gone"))
        self.set_pending([self.create_op(-14), {"op": "update", "wid": 7, "id": -14, "body": {"description": "y"}}])
        state = self.engine.sync(force=True)["state"]
        self.assertEqual(state["pending"], [])
        self.assertEqual(len(state["dropped"]), 1)

    # 2. the replay cap never lets the server window overwrite queued changes
    def test_capped_replay_does_not_fetch_over_queued_changes(self):
        self.opener.on("DELETE", "/workspaces/7/time_entries/", lambda p, b: None)
        server = [entry(9000, "2026-09-26T08:00:00Z", "2026-09-26T09:00:00Z")]
        self.opener.on("GET", "/me/time_entries", lambda p, b: server)
        self.set_pending([{"op": "delete", "wid": 7, "id": 1000 + i} for i in range(MAX_REPLAY)]
                         + [{"op": "delete", "wid": 7, "id": 9000}])
        with self.store.locked():
            state = self.store.load()
            state["entries"] = []                        # 9000 already deleted locally
            self.store.save(state)
        gets_before = sum(1 for r in self.opener.requests if r[1] == "/me/time_entries")
        state = self.engine.sync(force=True)["state"]
        self.assertEqual(len(state["pending"]), 1)
        self.assertEqual(sum(1 for r in self.opener.requests if r[1] == "/me/time_entries"), gets_before)
        self.assertEqual(state["entries"], [])           # the deleted entry did not reappear

    # 3. a queued running create + its queued stop is posted finished
    def test_running_create_is_posted_with_its_queued_stop(self):
        self.set_pending([self.create_op(-15, running=True),
                          {"op": "update", "wid": 7, "id": -15,
                           "body": {"stop": "2026-09-26T09:30:00Z", "duration": 1800}}])
        self.engine.sync(force=True)
        self.assertEqual(len(self.created), 1)
        self.assertEqual(self.created[0]["duration"], 1800)
        self.assertEqual(self.created[0]["stop"], "2026-09-26T09:30:00Z")
        self.assertFalse(any(r[0] == "PUT" for r in self.opener.requests))

    def test_merge_keeps_other_edits(self):
        ops = _merge_stops([self.create_op(-1, running=True),
                            {"op": "update", "wid": 7, "id": -1,
                             "body": {"stop": "2026-09-26T09:30:00Z", "duration": 1800, "description": "z"}}])
        self.assertEqual(ops[0]["body"]["duration"], 1800)
        self.assertEqual(ops[1]["body"], {"description": "z"})

    # 4. a new change never overtakes an older queued one
    def test_online_change_queues_behind_blocked_queue(self):
        order = []
        state_quota = {"blocked": True}

        def update(p, b):
            order.append(b.get("description"))
            if state_quota["blocked"]:
                return (402, "quota")
            return entry(42, "2026-09-26T09:00:00Z", "2026-09-26T10:00:00Z", desc=b.get("description"))
        self.opener.on("PUT", "/workspaces/7/time_entries/42", update)
        with self.store.locked():
            state = self.store.load()
            state["entries"] = [{"id": 42, "wid": 7, "description": "orig", "start": "2026-09-26T09:00:00Z",
                                 "stop": "2026-09-26T10:00:00Z", "seconds": 3600, "tags": []}]
            state["pending"] = [{"op": "update", "wid": 7, "id": 42, "body": {"description": "A"}}]
            self.store.save(state)
        self.engine.update(42, {"description": "B"})     # queue still blocked -> B queues behind A
        self.assertEqual([op["body"]["description"] for op in self.pending()], ["A", "B"])
        state_quota["blocked"] = False
        self.engine._api = None
        self.engine.sync(force=True)
        self.assertEqual(order[-2:], ["A", "B"])          # newest wins on Toggl

    # 5. stale temporary ids resolve, unknown ones fail loudly
    def test_stale_temp_id_resolves_to_real_id(self):
        self.opener.on("DELETE", "/workspaces/7/time_entries/", lambda p, b: None)
        self.set_pending([self.create_op(-16)])
        self.engine.sync(force=True)
        real = self.engine.store.load()["idAliases"]["-16"]
        self.engine.delete([-16])
        self.assertTrue(any(r[0] == "DELETE" and r[1].endswith(f"/{real}") for r in self.opener.requests))

    def test_unknown_temp_id_is_an_error(self):
        with self.assertRaises(UsageError):
            self.engine.delete([-999])

    # 6. the idle prompt only acts on the entry it was raised for
    def test_idle_resolve_refuses_other_entry(self):
        with self.store.locked():
            state = self.store.load()
            state["running"] = {"id": 77, "wid": 7, "description": "B", "start": "2026-09-26T11:00:00Z",
                                "stop": None, "tags": []}
            self.store.save(state)
        from src.omarchy_toggl.timeutil import parse_iso
        with self.assertRaises(UsageError):
            self.engine.idle_resolve(parse_iso("2026-09-26T11:30:00Z"), "discard", entry_id=76)
        self.assertEqual(self.store.load()["running"]["id"], 77)

    # 10/11/12
    def test_temp_ids_are_unique(self):
        self.opener.offline = True
        first = self.engine.start("one")["state"]["running"]["id"]
        second = self.engine.start("two")["state"]["running"]["id"]
        self.assertNotEqual(first, second)
        temps = [op.get("tempId") for op in self.pending() if op["op"] == "create"]
        self.assertEqual(len(set(temps)), len(temps))

    def test_toggle_is_one_transaction(self):
        self.opener.on("POST", "/workspaces/7/time_entries",
                       lambda p, b: entry(600, b["start"], None, desc=b["description"], pid=None))
        with self.store.locked():
            state = self.store.load()
            state["entries"] = [{"id": 5, "wid": 7, "description": "last", "start": "2026-09-26T08:00:00Z",
                                 "stop": "2026-09-26T09:00:00Z", "seconds": 3600, "tags": []}]
            self.store.save(state)
        state = self.engine.toggle()["state"]
        self.assertEqual(state["running"]["id"], 600)

    def test_logout_refuses_to_drop_queued_changes(self):
        from tests.fakes import isolated_env
        env, keyring_log = isolated_env()                # never the real keyring
        cache = Path(env["XDG_CACHE_HOME"]) / "omarchy-toggl"
        cache.mkdir(parents=True, mode=0o700)
        (cache / "state.json").write_text(json.dumps({"schema": 1, "pending": [{"op": "delete", "wid": 7, "id": 1}]}))
        run = lambda *a: subprocess.run([sys.executable, str(ROOT / "src/toggl.py"), "auth", "logout", *a],
                                        capture_output=True, text=True, env=env, timeout=30)
        refused = run()
        self.assertEqual(refused.returncode, 2, refused.stdout)
        self.assertEqual(len(json.loads((cache / "state.json").read_text())["pending"]), 1)
        self.assertFalse(keyring_log.exists())           # refused before touching the keyring
        self.assertEqual(run("--discard-pending").returncode, 0)
        self.assertIn("clear service omarchy-toggl", keyring_log.read_text())   # the stub, not the real one

if __name__ == "__main__":
    unittest.main()
