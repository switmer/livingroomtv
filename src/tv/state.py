from __future__ import annotations

import json
from typing import Any


def format_status(s: dict[str, Any]) -> str:
    lines = [
        f"device:      {s.get('device') or s.get('device_id') or 'unknown'}",
        f"power:       {s.get('power')}",
        f"play_state:  {s.get('play_state')}",
        f"media_type:  {s.get('media_type')}",
        f"app:         {s.get('app')}",
        f"title:       {s.get('title')}",
    ]
    if s.get("series"):
        lines.append(f"series:      {s['series']}")
    if s.get("artist"):
        lines.append(f"artist:      {s['artist']}")
    if s.get("album"):
        lines.append(f"album:       {s['album']}")
    if s.get("position") is not None and s.get("total_time") is not None:
        lines.append(f"position:    {s['position']}/{s['total_time']}s")
    return "\n".join(lines)


def format_now_playing(s: dict[str, Any]) -> str:
    app = s.get("app") or "—"
    state = s.get("play_state") or "—"
    title = s.get("title") or "(nothing playing)"
    extras = []
    if s.get("series"):
        extras.append(s["series"])
    if s.get("artist"):
        extras.append(s["artist"])
    suffix = f" — {' · '.join(extras)}" if extras else ""
    return f"[{app}] {state}: {title}{suffix}"


def as_json(obj: Any) -> str:
    return json.dumps(obj, indent=2, default=str)
