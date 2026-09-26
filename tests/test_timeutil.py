import json
import unittest
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from src.omarchy_toggl.timeutil import parse_iso, parse_when, to_api, week_start

UTC = timezone.utc
NOW = datetime(2026, 9, 26, 15, 30, tzinfo=UTC)
CASES = json.loads((Path(__file__).parent / "time_cases.json").read_text())


class TimeTests(unittest.TestCase):
    def test_shared_cases(self):
        for text, expected in CASES.items():
            with self.subTest(text=text):
                got = parse_when(text, now=NOW, tz=UTC)
                self.assertEqual(to_api(got), expected)

    def test_invalid(self):
        for text in ("", "25:00", "banana"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                parse_when(text, now=NOW, tz=UTC)

    def test_week_start(self):
        saturday = date(2026, 9, 26)
        self.assertEqual(week_start(saturday, 1), date(2026, 9, 21))  # Monday
        self.assertEqual(week_start(saturday, 0), date(2026, 9, 20))  # Sunday
        self.assertEqual(week_start(date(2026, 9, 21), 1), date(2026, 9, 21))

    def test_parse_iso_z(self):
        self.assertEqual(parse_iso("2026-09-26T10:00:00Z"), datetime(2026, 9, 26, 10, tzinfo=UTC))
        self.assertEqual(to_api(parse_iso("2026-09-26T12:00:00+02:00")), "2026-09-26T10:00:00Z")


if __name__ == "__main__":
    unittest.main()
