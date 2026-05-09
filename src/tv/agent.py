"""Natural-language agent for driving the Apple TV via Claude tool use."""
from __future__ import annotations

import asyncio
import json
import os
import sys
from pathlib import Path
from typing import Any

from anthropic import Anthropic

from tv import config as cfg
from tv import preferences as prefs
from tv.adapters import apple_tv

DEFAULT_MODEL = "claude-haiku-4-5-20251001"
MAX_ITERATIONS = 8
API_KEY_FILE = cfg.CONFIG_DIR / "anthropic_api_key"
LOG_FILE = cfg.CONFIG_DIR / "ai.log"


READ_ONLY_TOOLS = {"get_status", "get_preferences", "list_apps"}


def actions_to_steps(actions: list[dict[str, Any]]) -> list[prefs.SceneStep]:
    """Convert AI tool_use actions into scene primitive steps.

    Read-only tools (get_status, list_apps, get_preferences) are dropped —
    they were just the model gathering context, not replayable intent.
    Unknown / unmappable tools are also dropped rather than poisoning the
    saved scene with steps that can't execute.

    Mapping matches `scenes.py` primitives exactly:
      launch_app     → launch_app
      search         → find (arg: query)
      set_volume     → set_volume
      mute / unmute  → mute / unmute
      control_playback → pause|play|play_pause|volume_up|volume_down
      navigate       → (dropped — scene runner has no nav primitive)
      power on/off   → wake / sleep
      run_scene      → run_scene (nested)
    """
    steps: list[prefs.SceneStep] = []
    for a in actions:
        name = a.get("name", "")
        inp = a.get("input") or {}
        if name in READ_ONLY_TOOLS:
            continue
        if name == "launch_app":
            steps.append(prefs.SceneStep("launch_app", {"name": inp.get("name", "")}))
        elif name == "search":
            q = inp.get("query", "")
            if q:
                steps.append(prefs.SceneStep("find", {"query": q}))
        elif name == "set_volume":
            steps.append(prefs.SceneStep("set_volume", {"percent": float(inp.get("percent", 0))}))
        elif name == "mute":
            steps.append(prefs.SceneStep("mute", {}))
        elif name == "unmute":
            steps.append(prefs.SceneStep("unmute", {}))
        elif name == "control_playback":
            action = inp.get("action", "")
            if action in {"play", "pause", "play_pause", "volume_up", "volume_down"}:
                steps.append(prefs.SceneStep(action, {}))
        elif name == "power":
            state = inp.get("state", "")
            if state == "on":
                steps.append(prefs.SceneStep("wake", {}))
            elif state == "off":
                steps.append(prefs.SceneStep("sleep", {}))
        # run_scene / navigate: no scene primitive; dropped silently to avoid
        # saving a step that would no-op at replay time.
    return steps


def _log_call(entry: dict[str, Any]) -> None:
    cfg.ensure_dir()
    with LOG_FILE.open("a") as f:
        f.write(json.dumps(entry, default=str) + "\n")


SYSTEM_PROMPT_BASE = """You are the control plane for a home Apple TV 4K (Living Room, LG C3 OLED, tvOS 26).

You plan and execute actions using the tools below. Be decisive — one or two tool calls is usually enough.

Tool-choice policy (apply in order):
1. If the user names an **app** ("open Netflix", "launch Disney+"), use `launch_app` — never `search`.
2. If the user names a **title or keyword** ("put on Bluey", "find Severance", "something with dragons"), use `search`. Do not auto-select a result — stop at the results page.
3. If the user expresses **room intent** ("movie mode", "kids mode", "all off", "goodnight", "bedtime"), use `run_scene` with the matching name.
4. For **volume**:
   - When the LG webOS adapter is paired (check `speaker_output` in `get_status` — "tv_speakers" means LG is active), volume commands hit the real TV speakers and `volume` in status is the actual TV level.
   - Absolute ("set to 30%", "half volume") → `set_volume(percent)`. This is reliable when LG is paired.
   - Relative small ("a bit louder", "turn it down") → one `control_playback(volume_up|volume_down)`.
   - Relative larger ("a lot louder") → `set_volume` with a reasonable absolute target instead of staircasing.
   - "Mute" / "silence" → `mute`. "Unmute" / "turn sound back on" → `unmute`.
   - When LG is NOT paired, `set_volume` and `mute` only affect AirPlay audio. In that case prefer step-based `volume_up|volume_down` for anything relative.
5. For **playback**, use `control_playback` with play/pause/play_pause.
6. For **power**, use `power("on" | "off")`.
7. Use `navigate` only as a last resort for arbitrary UI that no other tool can reach.
8. Call `get_status` first only when the request genuinely needs current state (e.g. "what's playing?", "is the TV on?"). Otherwise skip it.

Household preferences:
- When the user refers to something personal — "my show", "the kid show", "the good-night routine", "the usual" — call `get_preferences` first to resolve the concrete value, then act.
- If preferences has `shows.kid_show`, prefer that over a generic kids search.
- If preferences has `routines.good_night_scene`, use that scene name instead of guessing.
- If preferences has `apps.preferred_default_app`, use it when the user says "open the TV" or "put something on" without naming content.

Hard limits:
- Max 1 `launch_app` per request.
- Max 2 `search` calls per request.
- Max 5 volume taps per request unless the user explicitly asked for more.

After finishing, return one short sentence (≤12 words) describing what you did. This line may be spoken back to the user via Siri."""


def _build_system_prompt() -> str:
    """Append the current scene catalog to the base prompt so the model can
    reason over the user's actual rituals rather than hardcoded names."""
    scenes = prefs.load_scenes()
    if not scenes:
        return SYSTEM_PROMPT_BASE
    lines = ["Available scenes (call `run_scene` with the id):"]
    for s in scenes:
        step_summary = " → ".join(step.action for step in s.steps) or "(empty)"
        lines.append(f"  - {s.id}: {s.label}. Steps: {step_summary}")
    return SYSTEM_PROMPT_BASE + "\n\n" + "\n".join(lines)


def _build_tools() -> list[dict[str, Any]]:
    """Build the tool schema with the run_scene enum derived from the catalog."""
    scene_enum = prefs.scene_ids() or ["movie"]  # avoid empty enum (API rejects it)
    tools = list(STATIC_TOOLS)
    tools.append({
        "name": "run_scene",
        "description": (
            "Execute a whole-room scene defined in the user's preferences. "
            "Scenes are ordered sequences of primitives (wake / find / launch_app / "
            "volume_down / shortcut / pause / sleep) and can touch multiple devices. "
            "Pass the scene's `id` exactly."
        ),
        "input_schema": {
            "type": "object",
            "properties": {"name": {"type": "string", "enum": scene_enum}},
            "required": ["name"],
        },
    })
    return tools


# Static tools — everything except run_scene, whose enum is dynamic.
STATIC_TOOLS: list[dict[str, Any]] = [
    {
        "name": "get_status",
        "description": "Get current Apple TV state: power, playback, current app, title.",
        "input_schema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "get_preferences",
        "description": (
            "Get household preferences: favorite shows, preferred apps, routine mappings. "
            "Call this when the user references something personal like 'my show', 'the kid show', "
            "'the good-night routine', etc., before picking an action."
        ),
        "input_schema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "list_apps",
        "description": "List all apps installed on the Apple TV with bundle IDs.",
        "input_schema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "launch_app",
        "description": "Open an app on the Apple TV by name (fuzzy match) or bundle id.",
        "input_schema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "App name or bundle id, e.g. 'Netflix', 'Disney+', 'com.apple.TVSearch'."}
            },
            "required": ["name"],
        },
    },
    {
        "name": "search",
        "description": "Open Apple TV's global Search and type a query. Aggregates results across streaming apps.",
        "input_schema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Title or keyword to search for, e.g. 'Bluey' or 'Formula 1'."}
            },
            "required": ["query"],
        },
    },
    {
        "name": "navigate",
        "description": "Send a remote-control key to the Apple TV. Prefer launch_app/search over navigate.",
        "input_schema": {
            "type": "object",
            "properties": {
                "key": {"type": "string", "enum": ["up", "down", "left", "right", "select", "menu", "home"]}
            },
            "required": ["key"],
        },
    },
    {
        "name": "control_playback",
        "description": "Control the currently-playing media.",
        "input_schema": {
            "type": "object",
            "properties": {
                "action": {"type": "string", "enum": ["play", "pause", "play_pause", "volume_up", "volume_down"]}
            },
            "required": ["action"],
        },
    },
    {
        "name": "set_volume",
        "description": "Set absolute volume 0-100.",
        "input_schema": {
            "type": "object",
            "properties": {
                "percent": {"type": "number", "minimum": 0, "maximum": 100}
            },
            "required": ["percent"],
        },
    },
    {
        "name": "mute",
        "description": "Mute the TV (stores the pre-mute volume for restore via unmute).",
        "input_schema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "unmute",
        "description": "Restore volume to the pre-mute level (or a sensible default if unknown).",
        "input_schema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "power",
        "description": "Turn the Apple TV on (wake) or off (sleep). LG TV follows via HDMI-CEC.",
        "input_schema": {
            "type": "object",
            "properties": {"state": {"type": "string", "enum": ["on", "off"]}},
            "required": ["state"],
        },
    },
]


async def _run_tool(name: str, args: dict[str, Any]) -> str:
    try:
        if name == "get_status":
            return json.dumps(await apple_tv.status(), default=str)
        if name == "get_preferences":
            return json.dumps(prefs.load())
        if name == "list_apps":
            return json.dumps(await apple_tv.list_apps())
        if name == "launch_app":
            result = await apple_tv.launch_app(args["name"])
            return json.dumps({"launched": result})
        if name == "search":
            result = await apple_tv.find(args["query"])
            return json.dumps({"search": result})
        if name == "navigate":
            await apple_tv.nav(args["key"])
            return json.dumps({"ok": True, "key": args["key"]})
        if name == "control_playback":
            await apple_tv.nav(args["action"])
            return json.dumps({"ok": True, "action": args["action"]})
        if name == "set_volume":
            result = await apple_tv.set_volume(args["percent"])
            return json.dumps({"volume": result})
        if name == "mute":
            await apple_tv.mute()
            return json.dumps({"muted": True})
        if name == "unmute":
            restored = await apple_tv.unmute()
            return json.dumps({"volume": restored})
        if name == "power":
            if args["state"] == "on":
                await apple_tv.wake()
            else:
                await apple_tv.sleep()
            return json.dumps({"power": args["state"]})
        if name == "run_scene":
            from tv import scenes
            scene_id = args.get("name", "")
            if scene_id not in prefs.scene_ids():
                return json.dumps({
                    "error": f"unknown scene '{scene_id}'. allowed: {', '.join(prefs.scene_ids())}"
                })
            return json.dumps(await scenes.run(scene_id))
        return json.dumps({"error": f"unknown tool: {name}"})
    except Exception as e:
        return json.dumps({"error": str(e)})


def _load_api_key() -> str | None:
    key = os.environ.get("ANTHROPIC_API_KEY")
    if key:
        return key
    if API_KEY_FILE.exists():
        return API_KEY_FILE.read_text().strip()
    return None


def save_api_key(key: str) -> None:
    cfg.ensure_dir()
    API_KEY_FILE.write_text(key.strip() + "\n")
    os.chmod(API_KEY_FILE, 0o600)


async def run(
    prompt: str,
    model: str = DEFAULT_MODEL,
    verbose: bool = False,
    dry_run: bool = False,
) -> dict[str, Any]:
    """Returns {'summary': str, 'actions': [{name, input}], 'model': str}."""
    api_key = _load_api_key()
    if not api_key:
        raise RuntimeError(
            "No Anthropic API key. Set ANTHROPIC_API_KEY or run `tv ai-setup`."
        )

    client = Anthropic(api_key=api_key)
    messages: list[dict[str, Any]] = [{"role": "user", "content": prompt}]
    actions: list[dict[str, Any]] = []

    system_prompt = _build_system_prompt()
    tools = _build_tools()

    final_text = ""
    for _ in range(MAX_ITERATIONS):
        response = client.messages.create(
            model=model,
            max_tokens=1024,
            system=[{"type": "text", "text": system_prompt, "cache_control": {"type": "ephemeral"}}],
            tools=tools,
            messages=messages,
        )

        # Collect any assistant text parts for the final answer.
        assistant_blocks = response.content
        text_parts = [b.text for b in assistant_blocks if b.type == "text"]
        if text_parts:
            final_text = " ".join(text_parts).strip()

        if response.stop_reason != "tool_use":
            break

        # Execute all tool_use blocks, feed results back.
        tool_results: list[dict[str, Any]] = []
        for block in assistant_blocks:
            if block.type != "tool_use":
                continue
            actions.append({"name": block.name, "input": dict(block.input)})
            if verbose:
                print(f"→ {block.name}({json.dumps(block.input)})", file=sys.stderr)
            if dry_run and block.name not in READ_ONLY_TOOLS:
                result = json.dumps({"dry_run": True, "would_run": block.name, "input": dict(block.input)})
            else:
                result = await _run_tool(block.name, block.input)
            if verbose:
                print(f"  {result}", file=sys.stderr)
            tool_results.append({"type": "tool_result", "tool_use_id": block.id, "content": result})

        messages.append({"role": "assistant", "content": assistant_blocks})
        messages.append({"role": "user", "content": tool_results})

    result = {
        "summary": final_text or "done",
        "actions": actions,
        "model": model,
        "dry_run": dry_run,
    }
    _log_call({
        "ts": __import__("datetime").datetime.now().isoformat(timespec="seconds"),
        "prompt": prompt,
        **result,
    })
    return result
