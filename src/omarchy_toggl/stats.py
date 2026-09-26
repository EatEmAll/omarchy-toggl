"""Today/week aggregates for the CLI and notifications.

The panel computes live range stats itself in ui/Model.js (so the running
entry ticks); these mirror the same rules: finished entries only, entries that
cross midnight are split between days, "No project" has ``color: None``.
"""

from __future__ import annotations

from collections import OrderedDict
from datetime import date, datetime, timedelta, tzinfo
from typing import Any, Iterable

from .timeutil import day_start, local_tz, parse_iso, week_start


def _pieces(entry: dict[str, Any], tz: tzinfo, now: datetime) -> Iterable[tuple[date, float]]:
    start = parse_iso(entry.get("start"))
    stop = parse_iso(entry.get("stop")) or now
    if not start or stop <= start:
        return []
    out = []
    cursor = start.astimezone(tz)
    stop = stop.astimezone(tz)
    while cursor < stop:
        next_midnight = day_start(cursor.date() + timedelta(days=1), tz)
        end = min(stop, next_midnight)
        out.append((cursor.date(), (end - cursor).total_seconds()))
        cursor = end
    return out


def range_stats(entries: list[dict[str, Any]], first: date, last: date, tz: tzinfo | None = None,
                now: datetime | None = None) -> dict[str, Any]:
    tz = tz or local_tz()
    now = now or datetime.now(tz)
    days = [(first + timedelta(days=i)) for i in range((last - first).days + 1)]
    by_day = {d: 0.0 for d in days}
    projects: "OrderedDict[Any, dict[str, Any]]" = OrderedDict()
    total = billable = 0.0
    count = 0
    for entry in entries:
        touched = False
        for day, seconds in _pieces(entry, tz, now):
            if day < first or day > last:
                continue
            touched = True
            total += seconds
            if entry.get("billable"):
                billable += seconds
            by_day[day] += seconds
            key = entry.get("projectId")
            bucket = projects.get(key)
            if bucket is None:
                bucket = projects[key] = {
                    "projectId": key,
                    "name": entry.get("projectName") or "(No project)",
                    "color": entry.get("projectColor") if key else None,
                    "seconds": 0.0,
                    "days": [0.0] * len(days),
                }
            bucket["seconds"] += seconds
            bucket["days"][(day - first).days] += seconds
        count += 1 if touched else 0
    by_project = sorted(projects.values(), key=lambda p: -p["seconds"])
    for bucket in by_project:
        bucket["seconds"] = round(bucket["seconds"])
        bucket["days"] = [round(s) for s in bucket["days"]]
    return {
        "from": first.isoformat(),
        "to": last.isoformat(),
        "total": round(total),
        "billable": round(billable),
        "count": count,
        "byDay": [{"date": d.isoformat(), "seconds": round(by_day[d])} for d in days],
        "byProject": by_project,
    }


def compute(entries: list[dict[str, Any]], beginning_of_week: int = 1, today: date | None = None,
            tz: tzinfo | None = None, now: datetime | None = None) -> dict[str, Any]:
    tz = tz or local_tz()
    now = now or datetime.now(tz)
    today = today or now.astimezone(tz).date()
    first = week_start(today, beginning_of_week)
    return {
        "today": range_stats(entries, today, today, tz, now),
        "week": range_stats(entries, first, first + timedelta(days=6), tz, now),
    }


def hms(seconds: float) -> str:
    seconds = int(max(0, seconds))
    return f"{seconds // 3600}:{seconds % 3600 // 60:02d}:{seconds % 60:02d}"
