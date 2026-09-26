"""Quick-entry grammar: ``Research @stonks #deep #review $``.

* ``@name`` / ``@"Client Work"`` picks a project (exact, prefix, then substring
  match, case-insensitive); ``@none`` clears it. Projects are never created.
* ``#tag`` adds a tag; unknown tags are created by Toggl automatically.
* a lone ``$`` marks the entry billable.
"""

from __future__ import annotations

import re
import shlex
from dataclasses import dataclass, field
from typing import Any


class ParseError(ValueError):
    def __init__(self, message: str, candidates: list[str] | None = None):
        super().__init__(message)
        self.candidates = candidates or []


@dataclass
class QuickEntry:
    description: str = ""
    project_id: int | None = None
    project_set: bool = False
    tags: list[str] = field(default_factory=list)
    billable: bool | None = None


_TOKEN = re.compile(r'@"[^"]*"|#"[^"]*"|\S+')


def match_project(name: str, projects: list[dict[str, Any]]) -> dict[str, Any]:
    needle = name.strip().lower()
    pool = [p for p in projects if p.get("active", True)] or projects
    for test in (lambda n: n == needle, lambda n: n.startswith(needle), lambda n: needle in n):
        hits = [p for p in pool if test(str(p.get("name", "")).lower())]
        if len(hits) == 1:
            return hits[0]
        if len(hits) > 1:
            exact = [p for p in hits if str(p.get("name", "")).lower() == needle]
            if len(exact) == 1:
                return exact[0]
            raise ParseError(f"project '@{name}' is ambiguous", [str(p.get("name")) for p in hits][:8])
    raise ParseError(f"no project matches '@{name}'",
                     [str(p.get("name")) for p in pool if needle[:1] and str(p.get("name", "")).lower().startswith(needle[:1])][:8])


def parse(text: str, projects: list[dict[str, Any]]) -> QuickEntry:
    result = QuickEntry()
    words: list[str] = []
    for raw in _TOKEN.findall(text or ""):
        if raw == "$":
            result.billable = True
        elif raw.startswith("@") and len(raw) > 1:
            name = raw[1:]
            if name.startswith('"'):
                name = shlex.split(name)[0] if name.count('"') >= 2 else name.strip('"')
            result.project_set = True
            if name.lower() == "none":
                result.project_id = None
            else:
                result.project_id = int(match_project(name, projects)["id"])
        elif raw.startswith("#") and len(raw) > 1:
            tag = raw[1:].strip('"')
            if tag and tag not in result.tags:
                result.tags.append(tag)
        else:
            words.append(raw)
    result.description = " ".join(words).strip()
    return result
