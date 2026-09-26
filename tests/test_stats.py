import unittest
from datetime import date, datetime, timezone

from src.omarchy_toggl.stats import compute, range_stats

UTC = timezone.utc
NOW = datetime(2026, 9, 26, 12, tzinfo=UTC)


def e(start, stop, pid=None, name=None, billable=False):
    return {"start": start, "stop": stop, "projectId": pid, "projectName": name,
            "projectColor": "#fff" if pid else None, "billable": billable}


class StatsTests(unittest.TestCase):
    def test_midnight_split(self):
        entries = [e("2026-09-25T23:00:00Z", "2026-09-26T01:30:00Z", 1, "Snowball")]
        s = compute(entries, 1, today=date(2026, 9, 26), tz=UTC, now=NOW)
        self.assertEqual(s["today"]["total"], 5400)
        self.assertEqual(s["week"]["total"], 9000)
        by_day = {d["date"]: d["seconds"] for d in s["week"]["byDay"]}
        self.assertEqual(by_day["2026-09-25"], 3600)

    def test_week_start_and_projects(self):
        entries = [
            e("2026-09-21T08:00:00Z", "2026-09-21T10:00:00Z", 1, "Snowball", True),
            e("2026-09-20T08:00:00Z", "2026-09-20T09:00:00Z", 2, "Generic"),  # Sunday: previous week
            e("2026-09-22T08:00:00Z", "2026-09-22T08:30:00Z"),
        ]
        s = compute(entries, 1, today=date(2026, 9, 26), tz=UTC, now=NOW)
        self.assertEqual(s["week"]["from"], "2026-09-21")
        self.assertEqual(s["week"]["total"], 9000)
        self.assertEqual(s["week"]["billable"], 7200)
        names = [p["name"] for p in s["week"]["byProject"]]
        self.assertEqual(names, ["Snowball", "(No project)"])
        self.assertIsNone(s["week"]["byProject"][1]["color"])
        self.assertEqual(s["week"]["byProject"][0]["days"][0], 7200)
        sunday = compute(entries, 0, today=date(2026, 9, 26), tz=UTC, now=NOW)
        self.assertEqual(sunday["week"]["total"], 12600)

    def test_count(self):
        s = range_stats([e("2026-09-26T08:00:00Z", "2026-09-26T09:00:00Z")], date(2026, 9, 26), date(2026, 9, 26), UTC, NOW)
        self.assertEqual(s["count"], 1)


if __name__ == "__main__":
    unittest.main()
