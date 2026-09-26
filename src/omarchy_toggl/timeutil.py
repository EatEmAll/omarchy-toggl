"""Time helpers shared by the CLI, sync and stats code.

All timestamps are handled as timezone-aware datetimes. The API wants UTC
RFC3339 with a trailing ``Z``; display and day bucketing use the local
system timezone, which is what the QML side uses too.
"""

from __future__ import annotations

import re
from datetime import date, datetime, time, timedelta, timezone, tzinfo


def now_utc() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


def local_tz() -> tzinfo:
    return datetime.now().astimezone().tzinfo or timezone.utc


def parse_iso(value: str | None) -> datetime | None:
    if not value:
        return None
    text = str(value).strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    dt = datetime.fromisoformat(text)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=local_tz())
    return dt


def to_api(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def local_date(dt: datetime, tz: tzinfo | None = None) -> date:
    return dt.astimezone(tz or local_tz()).date()


def day_start(day: date, tz: tzinfo | None = None) -> datetime:
    return datetime.combine(day, time(0, 0), tzinfo=tz or local_tz())


def week_start(day: date, beginning_of_week: int = 1) -> date:
    """Toggl encodes the first weekday as Sunday=0, Monday=1, ..."""
    toggl_dow = (day.weekday() + 1) % 7  # Python Monday=0 -> Toggl Monday=1
    back = (toggl_dow - int(beginning_of_week)) % 7
    return day - timedelta(days=back)


_REL = re.compile(r"^([+-])\s*(\d+)\s*(m|min|h|hr|s)?$", re.I)
_CLOCK = re.compile(r"^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$", re.I)


def parse_when(text: str, now: datetime | None = None, tz: tzinfo | None = None) -> datetime:
    """Parse the human time formats accepted by the DurationField.

    Accepts ISO timestamps, ``14:02``, ``2:02pm``, ``-15m``/``+1h`` relative to
    now, and an optional ``today``/``yesterday`` prefix before a clock time.
    Mirrors ``parseDuration`` in ui/Model.js; the shared cases live in the tests.
    """
    tz = tz or local_tz()
    now = (now or now_utc()).astimezone(tz)
    raw = str(text or "").strip()
    if not raw:
        raise ValueError("empty time")
    low = raw.lower()
    if low == "now":
        return now
    rel = _REL.match(low)
    if rel:
        sign, amount, unit = rel.groups()
        unit = (unit or "m").lower()
        seconds = int(amount) * (3600 if unit.startswith("h") else 1 if unit == "s" else 60)
        return now + timedelta(seconds=seconds if sign == "+" else -seconds)
    base = now.date()
    for prefix, offset in (("yesterday", -1), ("today", 0)):
        if low.startswith(prefix):
            base = base + timedelta(days=offset)
            low = low[len(prefix):].strip()
            break
    clock = _CLOCK.match(low)
    if clock:
        hour = int(clock.group(1))
        minute = int(clock.group(2) or 0)
        meridiem = (clock.group(3) or "").lower()
        if meridiem == "pm" and hour < 12:
            hour += 12
        if meridiem == "am" and hour == 12:
            hour = 0
        if hour > 23 or minute > 59:
            raise ValueError(f"invalid clock time: {text}")
        return datetime.combine(base, time(hour, minute), tzinfo=tz)
    try:
        return parse_iso(raw)  # type: ignore[return-value]
    except ValueError as exc:
        raise ValueError(f"unrecognised time: {text}") from exc
