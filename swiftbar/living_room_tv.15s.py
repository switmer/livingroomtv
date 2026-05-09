#!/usr/bin/env python3
"""SwiftBar plugin: Living Room TV control.

Polls `tv status --json` and renders a menu bar tile with now-playing,
transport controls, and scene buttons.

Install:
  ln -s ~/tv/swiftbar/living_room_tv.15s.py \
    "$HOME/Library/Application Support/SwiftBar/Plugins/living_room_tv.15s.py"
Then refresh SwiftBar.
"""
from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
from pathlib import Path

# <xbar.title>Living Room TV</xbar.title>
# <xbar.version>v0.1</xbar.version>
# <xbar.author>steve</xbar.author>
# <xbar.desc>Apple TV status + scene controls via the `tv` CLI.</xbar.desc>

TV = os.environ.get("TV_BIN", str(Path.home() / ".local" / "bin" / "tv"))
SHORTCUTS = "/usr/bin/shortcuts"
ASK_AI = str(Path.home() / "tv" / "swiftbar" / "ask_ai.sh")
STATUS_TIMEOUT = 6  # seconds; short so menu bar stays responsive


def run_tv(*args: str, timeout: int = STATUS_TIMEOUT, capture: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        [TV, *args],
        capture_output=capture,
        text=not capture,  # only True when capture=False
        timeout=timeout,
    )


def fetch_status() -> dict | None:
    try:
        r = subprocess.run(
            [TV, "status", "--json"],
            capture_output=True, text=True, timeout=STATUS_TIMEOUT,
        )
        if r.returncode != 0:
            return None
        return json.loads(r.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError):
        return None


def fetch_artwork_b64() -> str | None:
    try:
        r = subprocess.run(
            [TV, "artwork", "--width", "180", "--height", "180"],
            capture_output=True, timeout=STATUS_TIMEOUT,
        )
        if r.returncode != 0 or not r.stdout:
            return None
        return base64.b64encode(r.stdout).decode("ascii")
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None


def fmt_time(secs: int | float | None) -> str:
    if secs is None:
        return "–"
    try:
        s = int(secs)
    except (TypeError, ValueError):
        return "–"
    h, rem = divmod(s, 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


def progress_bar(position: int | None, total: int | None, width: int = 18) -> str:
    if not total or position is None:
        return ""
    pct = max(0.0, min(1.0, position / total))
    filled = int(round(pct * width))
    return "▓" * filled + "░" * (width - filled)


def params(*pairs: str) -> str:
    return " ".join(pairs)


ACTION = f"shell={TV} terminal=false refresh=true"
SHORTCUT_ACTION = f"shell={SHORTCUTS} terminal=false refresh=true"


def line(text: str, **attrs) -> str:
    """Emit a SwiftBar line with attributes. Values with whitespace get quoted."""
    if not attrs:
        return text
    parts = []
    for k, v in attrs.items():
        sv = str(v)
        if any(c.isspace() for c in sv):
            sv = '"' + sv.replace('"', '\\"') + '"'
        parts.append(f"{k}={sv}")
    return f"{text} | {' '.join(parts)}"


def main() -> None:
    s = fetch_status()

    # --- Menu bar ---
    if s is None:
        print(":tv: offline | sfimage=tv color=#888888")
        print("---")
        print(line("TV CLI unreachable", color="#999999"))
        print(line("Refresh", refresh="true"))
        return

    power = s.get("power") or "unknown"
    play_state = s.get("play_state") or ""
    app = s.get("app") or ""
    title = s.get("title") or ""
    series = s.get("series") or ""
    position = s.get("position")
    total = s.get("total_time")
    volume = s.get("volume")
    volume_pct = int(round(volume)) if isinstance(volume, (int, float)) else None
    # Only treat 0 as "muted" if the user explicitly muted via `tv mute`
    # (avoids showing "Unmute" when HDMI-CEC audio path just reports 0).
    mute_marker = Path.home() / ".config" / "tv" / "volume_before_mute"
    muted = mute_marker.exists()

    # Menu bar icon + short title
    if power == "on":
        glyph = "play.fill" if play_state == "playing" else "pause.fill" if play_state == "paused" else "tv.fill"
        bar = title or series or app or "Living Room"
        bar = bar if len(bar) <= 22 else bar[:21] + "…"
        print(f"{bar} | sfimage={glyph}")
    else:
        print(":tv: | sfimage=tv color=#888888")

    print("---")

    # --- Header ---
    on_badge = "On ✓" if power == "on" else "Off"
    color = "#2ecc71" if power == "on" else "#888888"
    print(line(f"Living Room TV — {on_badge}", color=color, size=14))
    print("---")

    # --- Now playing block ---
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

    heading_line = {"size": 13}
    if art_b64:
        heading_line["image"] = art_b64
    print(line(heading, **heading_line))

    if app:
        print(line(app, color="#aaaaaa", size=11))

    bar = progress_bar(position, total)
    if bar:
        pos_s = fmt_time(position)
        total_s = fmt_time(total)
        print(line(f"{bar}  {pos_s} / {total_s}", font="Menlo", size=11, color="#cccccc"))

    print("---")

    # --- Ask AI ---
    print(line("🤖  Ask AI…", shell=ASK_AI, terminal="false", refresh="false"))

    print("---")

    # --- Transport ---
    print(line("▶ / ⏸  Play / Pause", shell=TV, param0="play-pause", terminal="false", refresh="true"))
    print(line("◀  Back", shell=TV, param0="menu", terminal="false", refresh="true"))

    # --- Volume ---
    # pyatv reports AirPlay output volume, which reads 0 when audio is via HDMI-CEC to the TV.
    # Only show the percentage when it's non-zero (AirPlay/Apple TV Music playback).
    vol_label = f"🔊  Volume — {volume_pct}%" if volume_pct and volume_pct > 0 else "🔊  Volume"
    print(vol_label)
    print("--" + line("🔈 Volume Down", shell=TV, param0="volume-down", terminal="false", refresh="true"))
    print("--" + line("🔊 Volume Up", shell=TV, param0="volume-up", terminal="false", refresh="true"))
    print("-----")
    for preset in (10, 25, 50, 75, 100):
        marker = " ✓" if volume_pct is not None and abs(volume_pct - preset) < 3 else ""
        print("--" + line(f"{preset}%{marker}", shell=TV, param0="volume", param1=str(preset), terminal="false", refresh="true"))
    print("-----")
    if muted:
        print("--" + line("🔊 Unmute", shell=TV, param0="unmute", terminal="false", refresh="true"))
    else:
        print("--" + line("🔇 Mute", shell=TV, param0="mute", terminal="false", refresh="true"))

    print("---")

    # --- Apps submenu ---
    print("📺  Open App")
    for label, shortcut in [
        ("Netflix", "netflix"),
        ("Disney+", "disney"),
        ("HBO Max", "hbo"),
        ("Prime Video", "prime"),
        ("Hulu", "hulu"),
        ("Paramount+", "paramount"),
        ("Peacock", "peacock"),
        ("YouTube TV", "youtube"),
        ("Apple TV", "appletv"),
        ("Spotify", "spotify"),
        ("Music", "music"),
        ("— Search", "search"),
    ]:
        print("--" + line(label, shell=TV, param0=shortcut, terminal="false", refresh="true"))

    print("---")

    # --- Scenes ---
    print(line("🎬  Movie Mode", shell=TV, param0="scene", param1="movie", terminal="false", refresh="true"))
    print(line("🧸  Kids TV", shell=TV, param0="scene", param1="kids", terminal="false", refresh="true"))
    print(line("⏵  Resume", shell=TV, param0="scene", param1="resume", terminal="false", refresh="true"))
    print(line("💡  Lights Up", shell=SHORTCUTS, param0="run", param1="Lights Up", terminal="false", refresh="true"))
    print(line("⏻  All Off", shell=TV, param0="scene", param1="off", terminal="false", refresh="true", color="#e74c3c"))

    print("---")

    # --- Footer ---
    print(line("↻ Refresh", refresh="true"))
    print(line("Open project in Finder", shell="/usr/bin/open", param0=str(Path.home() / "tv"), terminal="false"))


if __name__ == "__main__":
    main()
