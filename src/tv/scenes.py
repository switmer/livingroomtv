"""Scene runner: execute the ordered primitive steps defined by each scene
in preferences.toml. No branching, no retries, no clever DSL — just a linear
list of primitives with simple args.
"""
from __future__ import annotations

import asyncio
import shutil
import subprocess
from typing import Any, Awaitable, Callable

from tv import preferences as prefs
from tv.adapters import apple_tv


# -----------------------------------------------------------------------------
# Primitive step handlers
# -----------------------------------------------------------------------------

async def _wake(args: dict[str, Any]) -> dict[str, Any]:
    await apple_tv.wake()
    return {"ok": True}


async def _sleep(args: dict[str, Any]) -> dict[str, Any]:
    await apple_tv.sleep()
    return {"ok": True}


async def _pause(args: dict[str, Any]) -> dict[str, Any]:
    try:
        await apple_tv.pause()
        return {"ok": True}
    except Exception as e:
        # Pause silently no-ops when nothing is playing; don't fail the scene.
        return {"ok": True, "note": f"pause skipped: {e}"}


async def _play(args: dict[str, Any]) -> dict[str, Any]:
    await apple_tv.play()
    return {"ok": True}


async def _play_pause(args: dict[str, Any]) -> dict[str, Any]:
    await apple_tv.nav("play_pause")
    return {"ok": True}


async def _find(args: dict[str, Any]) -> dict[str, Any]:
    query = args.get("query", "")
    if not query:
        return {"ok": False, "error": "find: missing query"}
    result = await apple_tv.find(query)
    return {"ok": True, "find": result}


async def _launch_app(args: dict[str, Any]) -> dict[str, Any]:
    name = args.get("name") or args.get("bundle_id") or ""
    if not name:
        return {"ok": False, "error": "launch_app: missing name"}
    result = await apple_tv.launch_app(name)
    return {"ok": True, "launched": result}


async def _volume_up(args: dict[str, Any]) -> dict[str, Any]:
    repeat = max(1, int(args.get("repeat", 1)))
    for _ in range(repeat):
        await apple_tv.nav("volume_up")
    return {"ok": True, "repeat": repeat}


async def _volume_down(args: dict[str, Any]) -> dict[str, Any]:
    repeat = max(1, int(args.get("repeat", 1)))
    for _ in range(repeat):
        await apple_tv.nav("volume_down")
    return {"ok": True, "repeat": repeat}


async def _set_volume(args: dict[str, Any]) -> dict[str, Any]:
    percent = float(args.get("percent", 0))
    result = await apple_tv.set_volume(percent)
    return {"ok": True, "volume": result}


async def _mute(args: dict[str, Any]) -> dict[str, Any]:
    await apple_tv.mute()
    return {"ok": True}


async def _unmute(args: dict[str, Any]) -> dict[str, Any]:
    result = await apple_tv.unmute()
    return {"ok": True, "volume": result}


async def _shortcut(args: dict[str, Any]) -> dict[str, Any]:
    name = args.get("name", "")
    if not name:
        return {"ok": False, "error": "shortcut: missing name"}
    if shutil.which("shortcuts") is None:
        return {"ok": False, "error": "shortcuts CLI not available"}
    result = subprocess.run(
        ["shortcuts", "run", name],
        capture_output=True, text=True,
    )
    return {"ok": result.returncode == 0, "shortcut": name, "exit": result.returncode}


async def _wait(args: dict[str, Any]) -> dict[str, Any]:
    seconds = float(args.get("seconds", 0))
    if seconds > 0:
        await asyncio.sleep(seconds)
    return {"ok": True, "waited": seconds}


async def _select(args: dict[str, Any]) -> dict[str, Any]:
    await apple_tv.nav("select")
    return {"ok": True}


async def _menu(args: dict[str, Any]) -> dict[str, Any]:
    await apple_tv.nav("menu")
    return {"ok": True}


async def _home(args: dict[str, Any]) -> dict[str, Any]:
    await apple_tv.nav("home")
    return {"ok": True}


async def _profile(args: dict[str, Any]) -> dict[str, Any]:
    """Pick a profile on tvOS 26's 'Who's Watching?' picker by 0-based index.

    Index is counted from the leftmost profile. This primitive:
      1. Waits briefly for the picker to appear (after a wake).
      2. Rams left enough times to guarantee we're on the leftmost profile.
      3. Moves right `index` times to the target.
      4. Presses Select.

    Scenes that cross a sleep/wake boundary on tvOS 26 should include a
    `profile` step right after `wake`, otherwise the picker will block every
    subsequent action.
    """
    index = max(0, int(args.get("index", 0)))
    delay = float(args.get("delay", 1.2))
    await asyncio.sleep(delay)
    # Press left more than any plausible profile count to normalize position.
    for _ in range(8):
        await apple_tv.nav("left")
        await asyncio.sleep(0.08)
    for _ in range(index):
        await apple_tv.nav("right")
        await asyncio.sleep(0.08)
    await apple_tv.nav("select")
    await asyncio.sleep(0.8)  # let the picker dismiss and home screen settle
    return {"ok": True, "profile_index": index}


PRIMITIVES: dict[str, Callable[[dict[str, Any]], Awaitable[dict[str, Any]]]] = {
    "wake": _wake,
    "sleep": _sleep,
    "pause": _pause,
    "play": _play,
    "play_pause": _play_pause,
    "find": _find,
    "launch_app": _launch_app,
    "volume_up": _volume_up,
    "volume_down": _volume_down,
    "set_volume": _set_volume,
    "mute": _mute,
    "unmute": _unmute,
    "shortcut": _shortcut,
    "wait": _wait,
    "select": _select,
    "menu": _menu,
    "home": _home,
    "profile": _profile,
}


# -----------------------------------------------------------------------------
# Public runner
# -----------------------------------------------------------------------------

async def run(scene_id: str) -> dict[str, Any]:
    """Execute the steps of a scene in order. Returns a summary dict.

    Unknown scene ids raise; unknown step actions are skipped with a note but
    do not abort the rest of the scene (so a typo in one step doesn't block
    the rest of a bedtime routine, for instance).
    """
    scene = prefs.find_scene(scene_id)
    if scene is None:
        raise ValueError(f"unknown scene id '{scene_id}'. known: {', '.join(prefs.scene_ids())}")

    executed: list[dict[str, Any]] = []
    for step in scene.steps:
        handler = PRIMITIVES.get(step.action)
        if handler is None:
            executed.append({
                "action": step.action,
                "ok": False,
                "error": f"unknown primitive '{step.action}'",
            })
            continue
        try:
            result = await handler(step.args)
        except Exception as e:  # keep scene going on one bad step
            result = {"ok": False, "error": str(e)}
        executed.append({"action": step.action, **result})

    return {
        "scene": scene.id,
        "label": scene.label,
        "steps": executed,
    }
