from __future__ import annotations

import asyncio
import sys
from typing import Optional

import typer

from tv import config as cfg
from tv import state as state_fmt

app = typer.Typer(no_args_is_help=True, add_completion=False, help="Living-room control CLI.")
scene_app = typer.Typer(no_args_is_help=True, help="Room-mode scenes.")
apps_app = typer.Typer(no_args_is_help=True, help="Apple TV app launching.")
pref_app = typer.Typer(no_args_is_help=True, help="Household preferences.")
lg_app = typer.Typer(no_args_is_help=True, help="LG webOS TV direct control (speaker volume, mute).")
app.add_typer(scene_app, name="scene")
app.add_typer(apps_app, name="app")
app.add_typer(pref_app, name="pref")
app.add_typer(lg_app, name="lg")


@lg_app.command("pair")
def lg_pair(host: str = typer.Argument(..., help="LG TV LAN address, e.g. 192.168.4.31")):
    """Pair with the LG TV. Accept the on-screen prompt."""
    from tv.adapters import lg_webos
    try:
        key = _run(lg_webos.pair(host))
    except Exception as e:
        typer.secho(f"pairing failed: {e}", fg=typer.colors.RED, err=True)
        raise typer.Exit(code=1)
    typer.secho(f"Paired with {host}. Client key saved to ~/.config/tv/lg.json", fg=typer.colors.GREEN)
    typer.echo(f"  key: {key[:12]}…")


@lg_app.command("status")
def lg_status(json_out: bool = typer.Option(False, "--json")):
    """Query current LG TV state (volume / mute / power / app)."""
    from tv.adapters import lg_webos
    state = _run(lg_webos.get_state())
    if state is None:
        typer.secho("LG unreachable (or not paired).", fg=typer.colors.YELLOW, err=True)
        raise typer.Exit(code=1)
    typer.echo(state_fmt.as_json(state) if json_out else str(state))


@lg_app.command("volume")
def lg_volume(percent: int = typer.Argument(..., help="Absolute LG volume 0-100.")):
    """Set LG TV speaker volume directly (webOS)."""
    from tv.adapters import lg_webos
    result = _run(lg_webos.set_volume(percent))
    typer.echo(f"lg volume: {result}%")


@lg_app.command("mute")
def lg_mute():
    """Mute LG TV speakers."""
    from tv.adapters import lg_webos
    _run(lg_webos.set_mute(True))
    typer.echo("lg muted")


@lg_app.command("unmute")
def lg_unmute():
    """Unmute LG TV speakers."""
    from tv.adapters import lg_webos
    _run(lg_webos.set_mute(False))
    typer.echo("lg unmuted")


@pref_app.command("show")
def pref_show(json_out: bool = typer.Option(False, "--json")):
    """Print all preferences."""
    from tv import preferences
    data = preferences.load()
    if json_out:
        typer.echo(state_fmt.as_json(data))
        return
    for section, keys in data.items():
        typer.echo(f"[{section}]")
        for k, v in keys.items():
            typer.echo(f"  {k} = {v!r}")


@pref_app.command("get")
def pref_get(key: str = typer.Argument(..., help="Dotted key, e.g. shows.kid_show.")):
    from tv import preferences
    value = preferences.get_value(key)
    if value is None:
        raise typer.Exit(code=1)
    typer.echo(value)


@pref_app.command("set")
def pref_set(
    key: str = typer.Argument(..., help="Dotted key, e.g. shows.kid_show."),
    value: str = typer.Argument(..., help="New value."),
):
    from tv import preferences
    preferences.set_value(key, value)
    typer.echo(f"{key} = {value!r}")


@pref_app.command("path")
def pref_path():
    """Print the absolute path to the preferences file."""
    from tv import preferences
    typer.echo(str(preferences.PREFS_FILE))

SHORTCUT_APPS = {
    "netflix": "Netflix",
    "disney": "Disney+",
    "hbo": "HBO Max",
    "hulu": "Hulu",
    "prime": "Prime Video",
    "paramount": "Paramount+",
    "peacock": "Peacock",
    "appletv": "TV",
    "youtube": "YouTube TV",
    "spotify": "Spotify",
    "music": "Music",
    "search": "Search",
}


def _run(coro):
    try:
        return asyncio.run(coro)
    except RuntimeError as e:
        typer.secho(f"error: {e}", fg=typer.colors.RED, err=True)
        raise typer.Exit(code=1)


@app.command()
def discover(
    timeout: float = typer.Option(5.0, help="Scan timeout in seconds."),
    json_out: bool = typer.Option(False, "--json", help="Emit JSON."),
):
    """Scan the network for Apple TVs."""
    from tv.adapters import apple_tv

    configs = _run(apple_tv.scan(timeout=timeout))
    devices = [apple_tv.summarize(c).to_dict() for c in configs]
    if json_out:
        typer.echo(state_fmt.as_json(devices))
        return
    if not devices:
        typer.echo("No Apple TVs found.")
        return
    default_id = cfg.default_device_id()
    for d in devices:
        marker = " *" if d["identifier"] == default_id else ""
        typer.echo(f"{d['name']} ({d['address']}){marker}")
        typer.echo(f"  id:        {d['identifier']}")
        if d["model"]:
            typer.echo(f"  model:     {d['model']}")
        typer.echo(f"  protocols: {', '.join(d['protocols'])}")


@app.command()
def pair(
    device_id: Optional[str] = typer.Option(None, "--id", help="Target device identifier."),
):
    """Interactively pair with the Apple TV. Run this once."""
    from tv.adapters import apple_tv

    def pin_provider(protocol_name: str) -> str:
        return typer.prompt(f"Enter the 4-digit PIN shown on the TV for {protocol_name}")

    paired = _run(apple_tv.pair_device(device_id, pin_provider))
    typer.secho(f"Paired protocols: {', '.join(paired.keys())}", fg=typer.colors.GREEN)


@app.command()
def on(device_id: Optional[str] = typer.Option(None, "--id")):
    """Wake the Apple TV."""
    from tv.adapters import apple_tv
    _run(apple_tv.wake(device_id))


@app.command()
def wake(device_id: Optional[str] = typer.Option(None, "--id")):
    """Alias for `tv on`."""
    from tv.adapters import apple_tv
    _run(apple_tv.wake(device_id))


@app.command()
def off(device_id: Optional[str] = typer.Option(None, "--id")):
    """Sleep the Apple TV (LG follows via CEC)."""
    from tv.adapters import apple_tv
    _run(apple_tv.sleep(device_id))


@app.command()
def play(device_id: Optional[str] = typer.Option(None, "--id")):
    """Play current media."""
    from tv.adapters import apple_tv
    _run(apple_tv.play(device_id))


@app.command()
def pause(device_id: Optional[str] = typer.Option(None, "--id")):
    """Pause current media."""
    from tv.adapters import apple_tv
    _run(apple_tv.pause(device_id))


@app.command()
def menu(device_id: Optional[str] = typer.Option(None, "--id")):
    """Menu / back."""
    from tv.adapters import apple_tv
    _run(apple_tv.nav("menu", device_id))


@app.command()
def home(device_id: Optional[str] = typer.Option(None, "--id")):
    """Home screen."""
    from tv.adapters import apple_tv
    _run(apple_tv.nav("home", device_id))


@app.command()
def up(device_id: Optional[str] = typer.Option(None, "--id")):
    from tv.adapters import apple_tv
    _run(apple_tv.nav("up", device_id))


@app.command()
def down(device_id: Optional[str] = typer.Option(None, "--id")):
    from tv.adapters import apple_tv
    _run(apple_tv.nav("down", device_id))


@app.command()
def left(device_id: Optional[str] = typer.Option(None, "--id")):
    from tv.adapters import apple_tv
    _run(apple_tv.nav("left", device_id))


@app.command()
def right(device_id: Optional[str] = typer.Option(None, "--id")):
    from tv.adapters import apple_tv
    _run(apple_tv.nav("right", device_id))


@app.command()
def select(device_id: Optional[str] = typer.Option(None, "--id")):
    from tv.adapters import apple_tv
    _run(apple_tv.nav("select", device_id))


@app.command("next")
def next_track(device_id: Optional[str] = typer.Option(None, "--id")):
    """Next track / chapter (Spotify, Music, video apps)."""
    from tv.adapters import apple_tv
    _run(apple_tv.nav("next", device_id))


@app.command("previous")
def previous_track(device_id: Optional[str] = typer.Option(None, "--id")):
    """Previous track / chapter."""
    from tv.adapters import apple_tv
    _run(apple_tv.nav("previous", device_id))


@app.command("play-pause")
def play_pause(device_id: Optional[str] = typer.Option(None, "--id")):
    """Toggle play/pause."""
    from tv.adapters import apple_tv
    _run(apple_tv.nav("play_pause", device_id))


@app.command("volume-up")
def volume_up(device_id: Optional[str] = typer.Option(None, "--id")):
    from tv.adapters import apple_tv
    _run(apple_tv.nav("volume_up", device_id))


@app.command("volume-down")
def volume_down(device_id: Optional[str] = typer.Option(None, "--id")):
    from tv.adapters import apple_tv
    _run(apple_tv.nav("volume_down", device_id))


@app.command("volume")
def volume(
    percent: float = typer.Argument(..., help="Absolute volume, 0-100."),
    device_id: Optional[str] = typer.Option(None, "--id"),
):
    """Set absolute volume."""
    from tv.adapters import apple_tv
    result = _run(apple_tv.set_volume(percent, device_id))
    typer.echo(f"volume: {result:.0f}%")


@app.command("mute")
def mute(device_id: Optional[str] = typer.Option(None, "--id")):
    """Mute (stores pre-mute volume for `tv unmute`)."""
    from tv.adapters import apple_tv
    _run(apple_tv.mute(device_id))
    typer.echo("muted")


@app.command("unmute")
def unmute(
    default: float = typer.Option(30.0, "--default"),
    device_id: Optional[str] = typer.Option(None, "--id"),
):
    """Restore volume from last mute, or a default if unknown."""
    from tv.adapters import apple_tv
    restored = _run(apple_tv.unmute(device_id, default=default))
    typer.echo(f"volume: {restored:.0f}%")


@app.command()
def artwork(
    out: str = typer.Option("-", "--out", help="Output path, or '-' for stdout."),
    width: int = typer.Option(256, "--width"),
    height: int = typer.Option(256, "--height"),
    device_id: Optional[str] = typer.Option(None, "--id"),
):
    """Dump current playing artwork (PNG/JPEG bytes)."""
    from tv.adapters import apple_tv
    data = _run(apple_tv.artwork(device_id, width=width, height=height))
    if not data:
        raise typer.Exit(code=1)
    if out == "-":
        sys.stdout.buffer.write(data)
    else:
        from pathlib import Path
        Path(out).write_bytes(data)


@app.command()
def status(
    device_id: Optional[str] = typer.Option(None, "--id"),
    json_out: bool = typer.Option(False, "--json"),
):
    """Power + play state + app + title + position."""
    from tv.adapters import apple_tv
    s = _run(apple_tv.status(device_id))
    typer.echo(state_fmt.as_json(s) if json_out else state_fmt.format_status(s))


@app.command("watch")
def watch(
    tick: float = typer.Option(10.0, "--tick", help="Seconds between periodic status refreshes."),
    device_id: Optional[str] = typer.Option(None, "--id"),
    max_lifetime: float = typer.Option(
        6 * 3600,
        "--max-lifetime",
        help="Auto-exit after this many seconds so the Swift host respawns "
             "with a fresh pyatv connection. Backstop against silent staleness.",
    ),
):
    """Long-running daemon: stream status on stdout, accept RPC requests on stdin.

    Wire protocol (line-delimited JSON):
      stdin  : {"type":"rpc_request","v":1,"id":"<uuid>","cmd":"<name>","args":{...}}
      stdout : {"type":"status",       "v":1,...}
               {"type":"rpc_response", "v":1,"id":"<uuid>","ok":true,"result":{...}}

    The RPC surface is narrow: play_pause, play, pause, nav, volume_up,
    volume_down, set_volume, mute, unmute, wake, sleep, launch_app. Multi-step
    commands (scenes, ai, find) stay on the subprocess-spawn path.
    """
    import asyncio as _asyncio
    from tv.adapters import apple_tv
    from tv import daemon_lock

    # Exclusive per-device lock. If another daemon already owns it we emit a
    # structured `daemon_error` line and exit — the Swift spawner reads that
    # on the same stdout channel and reconnects to the existing daemon instead
    # of stacking a second one.
    lock_fd = daemon_lock.acquire_or_exit(device_id)
    try:
        _asyncio.run(apple_tv.run_daemon(
            device_id, tick_interval=tick, max_lifetime=max_lifetime,
        ))
    except KeyboardInterrupt:
        pass
    finally:
        daemon_lock.release(lock_fd, device_id)


@app.command("now-playing")
def now_playing(
    device_id: Optional[str] = typer.Option(None, "--id"),
    json_out: bool = typer.Option(False, "--json"),
):
    """Current media summary."""
    from tv.adapters import apple_tv
    s = _run(apple_tv.status(device_id))
    typer.echo(state_fmt.as_json(s) if json_out else state_fmt.format_now_playing(s))


@apps_app.command("list")
def app_list(
    device_id: Optional[str] = typer.Option(None, "--id"),
    json_out: bool = typer.Option(False, "--json"),
):
    """List installed apps on the Apple TV."""
    from tv.adapters import apple_tv
    apps = _run(apple_tv.list_apps(device_id))
    if json_out:
        typer.echo(state_fmt.as_json(apps))
        return
    width = max((len(a["name"]) for a in apps), default=12)
    for a in apps:
        typer.echo(f"{a['name']:<{width}}  {a['id']}")


@apps_app.command("open")
def app_open(
    query: str = typer.Argument(..., help="App name or bundle id (substring match on name)."),
    device_id: Optional[str] = typer.Option(None, "--id"),
):
    """Launch an app by name or bundle id."""
    from tv.adapters import apple_tv
    result = _run(apple_tv.launch_app(query, device_id))
    typer.echo(f"launched: {result['name']} ({result['id']})")


def _make_app_shortcut(name: str, query: str):
    @app.command(name=name, help=f"Open {query} on the Apple TV.")
    def _cmd(device_id: Optional[str] = typer.Option(None, "--id")):
        from tv.adapters import apple_tv
        result = _run(apple_tv.launch_app(query, device_id))
        typer.echo(f"launched: {result['name']} ({result['id']})")
    return _cmd


for _shortcut, _target in SHORTCUT_APPS.items():
    _make_app_shortcut(_shortcut, _target)


@app.command("profile")
def profile(
    index: int = typer.Argument(..., help="0-based index from leftmost profile on the 'Who's Watching?' picker."),
    delay: float = typer.Option(0.0, "--delay", help="Seconds to wait before starting (useful right after wake)."),
):
    """Pick a tvOS profile by position on the picker screen.

    Scenes that include a `wake` step on tvOS 26+ should follow with a
    `profile` step — the post-wake picker blocks everything else.
    """
    from tv import scenes
    result = _run(scenes._profile({"index": index, "delay": delay}))
    typer.echo(state_fmt.as_json(result))


@app.command("find")
def find(
    query: str = typer.Argument(..., help="Text to type into Apple TV global Search."),
    device_id: Optional[str] = typer.Option(None, "--id"),
):
    """Open global Search and type the query. Pick the result with the remote."""
    from tv.adapters import apple_tv
    _run(apple_tv.find(query, device_id))
    typer.echo(f"searching: {query}")


@app.command("bluey")
def bluey(device_id: Optional[str] = typer.Option(None, "--id")):
    """Search for Bluey."""
    from tv.adapters import apple_tv
    _run(apple_tv.find("Bluey", device_id))
    typer.echo("searching: Bluey")


@app.command("ai")
def ai(
    prompt: str = typer.Argument(..., help="What you want the Apple TV to do, in natural language."),
    model: str = typer.Option("claude-haiku-4-5-20251001", "--model", help="Anthropic model."),
    verbose: bool = typer.Option(False, "--verbose", "-v", help="Print tool calls to stderr."),
    dry_run: bool = typer.Option(False, "--dry-run", help="Plan without executing tool calls."),
    json_out: bool = typer.Option(False, "--json", help="Emit the full result as JSON."),
):
    """Natural-language agent. Uses Claude + tool use to drive the Apple TV."""
    from tv import agent
    result = _run(agent.run(prompt, model=model, verbose=verbose, dry_run=dry_run))
    if json_out:
        typer.echo(state_fmt.as_json(result))
    else:
        typer.echo(result["summary"])


@app.command("ai-setup")
def ai_setup(key: Optional[str] = typer.Argument(None, help="Anthropic API key (omit to be prompted).")):
    """Store an Anthropic API key at ~/.config/tv/anthropic_api_key (mode 0600)."""
    from tv import agent
    if key is None:
        key = typer.prompt("Anthropic API key", hide_input=True)
    agent.save_api_key(key)
    typer.secho("Saved.", fg=typer.colors.GREEN)


# Path-only check — does NOT import `agent` (and therefore not `anthropic`),
# so the Mac app can call this on every launch without paying SDK import cost.
_API_KEY_PATH = cfg.CONFIG_DIR / "anthropic_api_key"


@app.command("ai-status")
def ai_status(json_out: bool = typer.Option(False, "--json")):
    """Report whether an Anthropic API key is configured. Cheap (no SDK import)."""
    import os as _os
    configured = bool(_os.environ.get("ANTHROPIC_API_KEY")) or _API_KEY_PATH.exists()
    source = "env" if _os.environ.get("ANTHROPIC_API_KEY") else (
        "file" if _API_KEY_PATH.exists() else None
    )
    if json_out:
        typer.echo(state_fmt.as_json({"configured": configured, "source": source}))
    else:
        typer.echo("configured" if configured else "not configured")


@app.command("ai-clear")
def ai_clear():
    """Remove the saved Anthropic API key file (env vars are not touched)."""
    if _API_KEY_PATH.exists():
        _API_KEY_PATH.unlink()
        typer.secho("Cleared.", fg=typer.colors.GREEN)
    else:
        typer.echo("(no key on file)")


@app.command("ai-log")
def ai_log(
    tail: int = typer.Option(10, "--tail", "-n", help="Number of recent entries."),
    json_out: bool = typer.Option(False, "--json"),
):
    """Show recent AI planner calls."""
    from tv import agent
    if not agent.LOG_FILE.exists():
        typer.echo("(no log yet)")
        return
    lines = agent.LOG_FILE.read_text().splitlines()[-tail:]
    if json_out:
        typer.echo("[" + ",".join(lines) + "]")
        return
    import json as _json
    for raw in lines:
        try:
            e = _json.loads(raw)
        except _json.JSONDecodeError:
            continue
        ts = e.get("ts", "")
        prompt = e.get("prompt", "")
        plan = " → ".join(f"{a['name']}({','.join(f'{k}={v}' for k,v in a['input'].items())})" for a in e.get("actions", []))
        summary = e.get("summary", "")
        typer.echo(f"{ts}  {prompt!r}")
        if plan:
            typer.echo(f"  plan: {plan}")
        typer.echo(f"  → {summary}")
        typer.echo("")


@app.command("siri")
def siri(
    phrase: str = typer.Argument(..., help="Natural-language phrase from Siri/dictation."),
    dry_run: bool = typer.Option(False, "--dry-run"),
):
    """Voice entrypoint. Routes every phrase through the AI planner.

    Use this as the single 'Run Shell Script' action in your Siri Shortcut.
    """
    from tv import agent
    result = _run(agent.run(phrase, dry_run=dry_run))
    typer.echo(result["summary"])


@scene_app.command("list")
def scene_list(json_out: bool = typer.Option(False, "--json")):
    """List all scenes in the catalog."""
    from tv import preferences
    scenes = preferences.load_scenes()
    if json_out:
        typer.echo(state_fmt.as_json([s.to_dict() for s in scenes]))
        return
    for s in scenes:
        steps = " → ".join(step.action for step in s.steps) or "(empty)"
        typer.echo(f"{s.id:<12}  {s.label:<18}  [{steps}]")


@scene_app.command("run")
def scene_run(
    scene_id: str = typer.Argument(..., help="Scene id (see `tv scene list`)."),
):
    """Run a scene by id."""
    from tv import scenes
    try:
        result = _run(scenes.run(scene_id))
    except ValueError as e:
        typer.secho(str(e), fg=typer.colors.RED, err=True)
        raise typer.Exit(code=1)
    typer.echo(state_fmt.as_json(result))


@scene_app.command("save")
def scene_save():
    """Persist a user scene. Reads one JSON object from stdin:

    {
      "id": "bluey-time",               # optional; auto-slugged from label if omitted
      "label": "Bluey time",            # required
      "short_label": "Bluey",           # optional; defaults to first word of label
      "symbol": "sparkles",             # optional; defaults to "sparkles"
      "color": "#7C3AED",               # optional; defaults to "#7C3AED"
      "actions": [                      # required; AI tool-use list from `tv ai --json`
        {"name": "launch_app", "input": {"name": "Disney+"}},
        {"name": "set_volume", "input": {"percent": 10}}
      ]
    }

    Emits the saved scene as JSON on stdout.
    """
    import json as _json
    from tv import agent, preferences

    try:
        payload = _json.loads(sys.stdin.read())
    except _json.JSONDecodeError as e:
        typer.secho(f"invalid JSON on stdin: {e}", fg=typer.colors.RED, err=True)
        raise typer.Exit(code=1)

    label = (payload.get("label") or "").strip()
    if not label:
        typer.secho("`label` is required", fg=typer.colors.RED, err=True)
        raise typer.Exit(code=1)

    actions = payload.get("actions") or []
    if not isinstance(actions, list) or not actions:
        typer.secho("`actions` must be a non-empty list", fg=typer.colors.RED, err=True)
        raise typer.Exit(code=1)

    steps = agent.actions_to_steps(actions)
    if not steps:
        typer.secho("no replayable steps — all actions were read-only or unsupported", fg=typer.colors.RED, err=True)
        raise typer.Exit(code=1)

    # Auto-slug the id from label if the caller didn't provide one. Keep it
    # simple: lowercase, non-alnum → hyphen, collapse repeats, trim.
    def _slug(s: str) -> str:
        import re
        s = re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")
        return s or "scene"

    scene = preferences.Scene(
        id=(payload.get("id") or _slug(label)).strip(),
        label=label,
        short_label=(payload.get("short_label") or label.split()[0]).strip(),
        symbol=(payload.get("symbol") or "sparkles").strip(),
        color=(payload.get("color") or "#7C3AED").strip(),
        steps=steps,
        source="user",
    )
    saved = preferences.upsert_scene(scene)
    typer.echo(state_fmt.as_json(saved.to_dict()))


@scene_app.command("delete")
def scene_delete(
    scene_id: str = typer.Argument(..., help="Scene id to delete."),
):
    """Delete a user-created scene. Builtins cannot be deleted."""
    from tv import preferences
    ok = preferences.delete_scene(scene_id)
    if not ok:
        typer.secho(
            f"scene '{scene_id}' not found or is a builtin (not deletable)",
            fg=typer.colors.RED, err=True,
        )
        raise typer.Exit(code=1)
    typer.echo(state_fmt.as_json({"deleted": scene_id}))


# Auto-register one subcommand per scene in the catalog so `tv scene movie`,
# `tv scene bedtime`, etc. keep working. The scene set is read at import time;
# re-import (or restart) to pick up newly added scenes.
def _register_scene_shortcuts() -> None:
    from tv import preferences
    try:
        scenes_ = preferences.load_scenes()
    except Exception:
        return
    for s in scenes_:
        # `list` and `run` are explicit commands; don't shadow them.
        if s.id in ("list", "run"):
            continue
        def _make(sid: str, slabel: str):
            @scene_app.command(name=sid, help=f"Run the {slabel!r} scene.")
            def _cmd():
                from tv import scenes as scene_runner
                result = _run(scene_runner.run(sid))
                typer.echo(state_fmt.as_json(result))
            return _cmd
        _make(s.id, s.label)

_register_scene_shortcuts()


if __name__ == "__main__":
    app()
