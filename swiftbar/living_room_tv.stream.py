#!/usr/bin/env python3
"""SwiftBar streaming plugin: Living Room TV.

Runs `tv watch --json` as a subprocess and re-renders the menu on every
push update from the Apple TV (play/pause/app change) + periodic ticks.

Install by symlinking into SwiftBar's Plugins folder; disable the .15s.py
variant first so there aren't two tiles.
"""
# <xbar.title>Living Room TV (streaming)</xbar.title>
# <xbar.version>v0.2</xbar.version>
# <xbar.desc>Apple TV menu bar with push-based updates.</xbar.desc>
# <swiftbar.type>streamable</swiftbar.type>
from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
from pathlib import Path

TV = os.environ.get("TV_BIN", str(Path.home() / ".local" / "bin" / "tv"))
SHORTCUTS = "/usr/bin/shortcuts"
ASK_AI = str(Path.home() / "tv" / "swiftbar" / "ask_ai.sh")
TICK_SECONDS = "30"
ART_TIMEOUT = 4


def fetch_artwork_b64() -> str | None:
    try:
        r = subprocess.run(
            [TV, "artwork", "--width", "180", "--height", "180"],
            capture_output=True, timeout=ART_TIMEOUT,
        )
        if r.returncode != 0 or not r.stdout:
            return None
        return base64.b64encode(r.stdout).decode("ascii")
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None


def fmt_time(secs) -> str:
    if secs is None:
        return "–"
    try:
        s = int(secs)
    except (TypeError, ValueError):
        return "–"
    h, rem = divmod(s, 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


def progress_bar(position, total, width: int = 18) -> str:
    if not total or position is None:
        return ""
    pct = max(0.0, min(1.0, position / total))
    filled = int(round(pct * width))
    return "▓" * filled + "░" * (width - filled)


def line(text: str, **attrs) -> str:
    if not attrs:
        return text
    parts = []
    for k, v in attrs.items():
        sv = str(v)
        if any(c.isspace() for c in sv):
            sv = '"' + sv.replace('"', '\\"') + '"'
        parts.append(f"{k}={sv}")
    return f"{text} | {' '.join(parts)}"


def render(s: dict) -> list[str]:
    out: list[str] = []
    power = s.get("power") or "unknown"
    play_state = s.get("play_state") or ""
    app = s.get("app") or ""
    title = s.get("title") or ""
    series = s.get("series") or ""
    position = s.get("position")
    total = s.get("total_time")
    volume = s.get("volume")
    volume_pct = int(round(volume)) if isinstance(volume, (int, float)) else None
    mute_marker = Path.home() / ".config" / "tv" / "volume_before_mute"
    muted = mute_marker.exists()

    # Menu bar title
    if power == "on":
        glyph = "play.fill" if play_state == "playing" else "pause.fill" if play_state == "paused" else "tv.fill"
        bar = title or series or app or "Living Room"
        bar = bar if len(bar) <= 22 else bar[:21] + "…"
        out.append(f"{bar} | sfimage={glyph}")
    else:
        out.append(":tv: | sfimage=tv color=#888888")

    out.append("---")

    on_badge = "On ✓" if power == "on" else "Off"
    color = "#2ecc71" if power == "on" else "#888888"
    out.append(line(f"Living Room TV — {on_badge}", color=color, size=14))
    out.append("---")

    art_b64 = None
    if power == "on" and (app or title or series):
        art_b64 = fetch_artwork_b64()

    heading_parts = []
    if play_state:
        heading_parts.append(play_state.capitalize())
    if series:
        heading_parts.append(series)
    elif title:
        heading_parts.append(title)
    heading = " · ".join(heading_parts) if heading_parts else "Nothing playing"
    heading_attrs = {"size": 13}
    if art_b64:
        heading_attrs["image"] = art_b64
    out.append(line(heading, **heading_attrs))

    if app:
        out.append(line(app, color="#aaaaaa", size=11))

    bar = progress_bar(position, total)
    if bar:
        out.append(line(f"{bar}  {fmt_time(position)} / {fmt_time(total)}", font="Menlo", size=11, color="#cccccc"))

    out.append("---")
    out.append(line("🤖  Ask AI…", shell=ASK_AI, terminal="false", refresh="false"))
    out.append("---")

    out.append(line("▶ / ⏸  Play / Pause", shell=TV, param0="play-pause", terminal="false", refresh="false"))
    out.append(line("◀  Back", shell=TV, param0="menu", terminal="false", refresh="false"))

    vol_label = f"🔊  Volume — {volume_pct}%" if volume_pct and volume_pct > 0 else "🔊  Volume"
    out.append(vol_label)
    out.append("--" + line("🔈 Volume Down", shell=TV, param0="volume-down", terminal="false", refresh="false"))
    out.append("--" + line("🔊 Volume Up", shell=TV, param0="volume-up", terminal="false", refresh="false"))
    out.append("-----")
    for preset in (10, 25, 50, 75, 100):
        marker = " ✓" if volume_pct is not None and abs(volume_pct - preset) < 3 else ""
        out.append("--" + line(f"{preset}%{marker}", shell=TV, param0="volume", param1=str(preset), terminal="false", refresh="false"))
    out.append("-----")
    if muted:
        out.append("--" + line("🔊 Unmute", shell=TV, param0="unmute", terminal="false", refresh="false"))
    else:
        out.append("--" + line("🔇 Mute", shell=TV, param0="mute", terminal="false", refresh="false"))

    out.append("---")
    out.append("📺  Open App")
    for label, shortcut in [
        ("Netflix", "netflix"), ("Disney+", "disney"), ("HBO Max", "hbo"),
        ("Prime Video", "prime"), ("Hulu", "hulu"), ("Paramount+", "paramount"),
        ("Peacock", "peacock"), ("YouTube TV", "youtube"), ("Apple TV", "appletv"),
        ("Spotify", "spotify"), ("Music", "music"), ("— Search", "search"),
    ]:
        out.append("--" + line(label, shell=TV, param0=shortcut, terminal="false", refresh="false"))

    out.append("---")
    out.append(line("🎬  Movie Mode", shell=TV, param0="scene", param1="movie", terminal="false", refresh="false"))
    out.append(line("🧸  Kids TV", shell=TV, param0="scene", param1="kids", terminal="false", refresh="false"))
    out.append(line("⏵  Resume", shell=TV, param0="scene", param1="resume", terminal="false", refresh="false"))
    out.append(line("💡  Lights Up", shell=SHORTCUTS, param0="run", param1="Lights Up", terminal="false", refresh="false"))
    out.append(line("⏻  All Off", shell=TV, param0="scene", param1="off", terminal="false", refresh="false", color="#e74c3c"))
    out.append("---")
    out.append(line("Open project", shell="/usr/bin/open", param0=str(Path.home() / "tv"), terminal="false"))
    return out


def offline_block() -> list[str]:
    return [
        ":tv: offline | sfimage=tv color=#888888",
        "---",
        line("TV CLI unreachable", color="#999999"),
        line("Retry", refresh="true"),
    ]


def emit(block: list[str]) -> None:
    sys.stdout.write("\n".join(block) + "\n~~~\n")
    sys.stdout.flush()


def main() -> None:
    proc = subprocess.Popen(
        [TV, "watch", "--tick", TICK_SECONDS],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )

    emit([":tv: … | sfimage=tv color=#888888", "---", "Connecting…"])

    try:
        for raw in proc.stdout:
            raw = raw.strip()
            if not raw:
                continue
            try:
                status = json.loads(raw)
            except json.JSONDecodeError:
                continue
            try:
                emit(render(status))
            except Exception as e:
                emit(offline_block() + ["---", f"render error: {e}"])
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
