"""Household preferences + scene catalog.

All data lives in ~/.config/tv/preferences.toml. This module is the single
source of truth that the CLI, AI agent, and native macOS app all read from.
"""
from __future__ import annotations

import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import tomli_w

from tv import config as cfg

PREFS_FILE = cfg.CONFIG_DIR / "preferences.toml"


# -----------------------------------------------------------------------------
# Scene data model
# -----------------------------------------------------------------------------

@dataclass
class SceneStep:
    action: str
    args: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        d: dict[str, Any] = {"action": self.action}
        d.update(self.args)
        return d


@dataclass
class Scene:
    id: str
    label: str
    short_label: str
    symbol: str
    color: str          # canonical hex, e.g. "#7C3AED"
    steps: list[SceneStep]
    source: str = "builtin"   # "builtin" | "user" — drives UI affordances (delete only on "user")

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "label": self.label,
            "short_label": self.short_label,
            "symbol": self.symbol,
            "color": self.color,
            "source": self.source,
            "steps": [s.to_dict() for s in self.steps],
        }


# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------

DEFAULT_PREFS: dict[str, Any] = {
    "shows": {
        "kid_show": "Bluey",
        "my_show": "",
    },
    "apps": {
        "preferred_kids_app": "Disney+",
        "preferred_default_app": "TV",
    },
    "routines": {
        "good_night_scene": "bedtime",
        "movie_scene": "movie",
    },
}


# tvOS 26+ shows a 'Who's Watching?' picker after every wake from sleep.
# Default scenes include a `profile` step right after `wake` so the picker
# is dismissed and subsequent steps (find, launch_app) don't silently block.
# Index is 0-based from the leftmost profile. Edit to match your household.
STEVE = 0
KID = 1
SARAH = 2


DEFAULT_SCENES: list[Scene] = [
    Scene(
        id="morning",
        label="Quiet Morning",
        short_label="Morning",
        symbol="sunrise",
        color="#FF9F0A",
        steps=[
            SceneStep("wake"),
            SceneStep("profile", {"index": KID}),
            SceneStep("find", {"query": "Bluey"}),
            SceneStep("volume_down", {"repeat": 3}),
            SceneStep("shortcut", {"name": "Morning Lights"}),
        ],
    ),
    Scene(
        id="movie",
        label="Movie Night",
        short_label="Movie",
        symbol="film",
        color="#7C3AED",
        steps=[
            SceneStep("wake"),
            SceneStep("profile", {"index": STEVE}),
            SceneStep("shortcut", {"name": "Movie Mode Lights"}),
        ],
    ),
    Scene(
        id="dinner",
        label="Family Dinner",
        short_label="Dinner",
        symbol="utensils",
        color="#F0A202",
        steps=[
            SceneStep("wake"),
            SceneStep("profile", {"index": STEVE}),
            SceneStep("launch_app", {"name": "Music"}),
            SceneStep("shortcut", {"name": "Dinner Lights"}),
        ],
    ),
    Scene(
        id="kids",
        label="Kids TV",
        short_label="Kids",
        symbol="baby",
        color="#F97316",
        steps=[
            SceneStep("wake"),
            SceneStep("profile", {"index": KID}),
            SceneStep("launch_app", {"name": "Disney+"}),
            SceneStep("shortcut", {"name": "Kids TV Lights"}),
        ],
    ),
    Scene(
        id="bedtime",
        label="Bedtime",
        short_label="Bedtime",
        symbol="moon",
        color="#E05780",
        steps=[
            SceneStep("pause"),
            SceneStep("sleep"),
            SceneStep("shortcut", {"name": "All Off"}),
        ],
    ),
]


# -----------------------------------------------------------------------------
# Read/write
# -----------------------------------------------------------------------------

def ensure_default_file() -> None:
    if PREFS_FILE.exists():
        return
    cfg.ensure_dir()
    write_all(DEFAULT_PREFS, DEFAULT_SCENES)


def _load_raw() -> dict[str, Any]:
    ensure_default_file()
    with PREFS_FILE.open("rb") as f:
        return tomllib.load(f)


def load() -> dict[str, dict[str, str]]:
    """Return the flat preferences (shows / apps / routines) merged with defaults.

    Scene tables are excluded — use `load_scenes()` for those.
    """
    parsed = _load_raw()
    merged: dict[str, dict[str, str]] = {}
    for section, keys in DEFAULT_PREFS.items():
        merged[section] = {**keys, **parsed.get(section, {})}
    # Preserve user-added sections, but skip the scenes array-of-tables.
    for section, value in parsed.items():
        if section == "scene":
            continue
        if section not in merged:
            merged[section] = value  # type: ignore[assignment]
    return merged


def load_scenes() -> list[Scene]:
    """Parse the `[[scene]]` array-of-tables into Scene objects.

    If the file has no scenes (legacy from pre-PR-2 installs), inject defaults
    and persist, so every surface has something to render on first open.
    """
    parsed = _load_raw()
    raw_scenes = parsed.get("scene", [])
    if not raw_scenes:
        write_scenes(DEFAULT_SCENES)
        return DEFAULT_SCENES

    scenes: list[Scene] = []
    for entry in raw_scenes:
        try:
            scenes.append(_scene_from_dict(entry))
        except (KeyError, TypeError):
            # Skip malformed entries rather than blowing up every surface.
            continue
    return scenes


def _scene_from_dict(d: dict[str, Any]) -> Scene:
    steps = []
    for raw in d.get("steps", []):
        if not isinstance(raw, dict):
            continue
        action = raw.get("action")
        if not action:
            continue
        args = {k: v for k, v in raw.items() if k != "action"}
        steps.append(SceneStep(action=action, args=args))
    return Scene(
        id=d["id"],
        label=d.get("label", d["id"].replace("-", " ").title()),
        short_label=d.get("short_label", d.get("label", d["id"].title())),
        symbol=d.get("symbol", "circle"),
        color=d.get("color", "#888888"),
        steps=steps,
        source=d.get("source", "builtin"),
    )


def find_scene(scene_id: str) -> Scene | None:
    for s in load_scenes():
        if s.id == scene_id:
            return s
    return None


def scene_ids() -> list[str]:
    return [s.id for s in load_scenes()]


# -----------------------------------------------------------------------------
# Write
# -----------------------------------------------------------------------------

def write_all(prefs_data: dict[str, Any], scenes: list[Scene]) -> None:
    cfg.ensure_dir()
    payload: dict[str, Any] = {}
    for section, keys in prefs_data.items():
        payload[section] = keys
    payload["scene"] = [s.to_dict() for s in scenes]
    PREFS_FILE.write_bytes(tomli_w.dumps(payload).encode("utf-8"))


def write_scenes(scenes: list[Scene]) -> None:
    parsed = _load_raw() if PREFS_FILE.exists() else {}
    flat = {k: v for k, v in parsed.items() if k != "scene"}
    # Ensure core defaults are present
    for section, keys in DEFAULT_PREFS.items():
        flat.setdefault(section, keys)
    write_all(flat, scenes)


def upsert_scene(scene: Scene) -> Scene:
    """Insert a new scene or replace an existing one with the same id."""
    scenes = load_scenes()
    out = [s for s in scenes if s.id != scene.id]
    out.append(scene)
    write_scenes(out)
    return scene


def delete_scene(scene_id: str) -> bool:
    """Delete a user scene. Returns False if not found or if it's a builtin."""
    scenes = load_scenes()
    target = next((s for s in scenes if s.id == scene_id), None)
    if target is None or target.source != "user":
        return False
    write_scenes([s for s in scenes if s.id != scene_id])
    return True


def set_value(dotted_key: str, value: str) -> None:
    if "." not in dotted_key:
        raise ValueError(f"Preference keys must be dotted (section.key), got: {dotted_key}")
    section, key = dotted_key.split(".", 1)
    flat = load()
    flat.setdefault(section, {})[key] = value
    write_all(flat, load_scenes())


def get_value(dotted_key: str) -> str | None:
    if "." not in dotted_key:
        raise ValueError(f"Preference keys must be dotted (section.key), got: {dotted_key}")
    section, key = dotted_key.split(".", 1)
    return load().get(section, {}).get(key)
