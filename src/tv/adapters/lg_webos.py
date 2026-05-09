"""LG webOS adapter — direct TV-side volume / mute / state.

The Apple TV adapter can't see HDMI-CEC audio state; the LG TV itself can.
This adapter talks to the TV on port 3001 (WebSocket) using the webOS API
that the LG ThinQ app and Home Assistant both use.

Scope: read current TV-speaker volume + mute + app + power, set absolute
volume, toggle mute. No source/input switching, no TV power-on (which
webOS can't reliably trigger without Wake-on-LAN — kept out of scope).

Connection model: a module-level `WebOsClient` is kept alive across calls
in long-running processes (the daemon). Reconnecting on every status tick
was triggering an unguarded-`set_result` race inside `aiowebostv` that
produced a flood of `InvalidStateError: invalid state` tracebacks, and the
reconnect cost itself was pushing `get_state` past its 1.2s tick budget —
so `lg_power_state` was null most of the time. A single persistent client
sidesteps both problems. Short-lived CLI invocations still work: they open
the client, use it, and the event loop tears down on process exit.
"""
from __future__ import annotations

import asyncio
import json
import os
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from aiowebostv import WebOsClient

from tv import config as cfg


LG_CONFIG_FILE = cfg.CONFIG_DIR / "lg.json"
CONNECT_TIMEOUT = 2.5
# After a connect failure, don't retry for this long. Keeps a bad/off TV
# from burning a connect attempt on every status tick.
_FAILURE_BACKOFF = 5.0


# -----------------------------------------------------------------------------
# Credentials
# -----------------------------------------------------------------------------

def load_config() -> dict[str, str]:
    if not LG_CONFIG_FILE.exists():
        return {}
    try:
        return json.loads(LG_CONFIG_FILE.read_text())
    except json.JSONDecodeError:
        return {}


def save_config(host: str, client_key: str) -> None:
    cfg.ensure_dir()
    LG_CONFIG_FILE.write_text(json.dumps({"host": host, "client_key": client_key}, indent=2))
    os.chmod(LG_CONFIG_FILE, 0o600)


def is_configured() -> bool:
    c = load_config()
    return bool(c.get("host") and c.get("client_key"))


def get_host() -> str | None:
    return load_config().get("host")


# -----------------------------------------------------------------------------
# Persistent client
# -----------------------------------------------------------------------------

_client: WebOsClient | None = None
_lock: asyncio.Lock | None = None
_last_failure_at: float = 0.0


def _get_lock() -> asyncio.Lock:
    global _lock
    if _lock is None:
        _lock = asyncio.Lock()
    return _lock


async def _ensure_client() -> WebOsClient | None:
    """Return a connected cached client, or None if unconfigured/unreachable."""
    global _client, _last_failure_at
    c = load_config()
    host = c.get("host")
    key = c.get("client_key")
    if not host:
        return None

    async with _get_lock():
        if _client is not None and _client.is_connected():
            return _client

        loop = asyncio.get_running_loop()
        if loop.time() - _last_failure_at < _FAILURE_BACKOFF:
            return None

        if _client is not None:
            try:
                await _client.disconnect()
            except Exception:
                pass
            _client = None

        client = WebOsClient(host, key, connect_timeout=CONNECT_TIMEOUT)
        try:
            async with asyncio.timeout(CONNECT_TIMEOUT + 0.5):
                await client.connect()
        except Exception:
            _last_failure_at = loop.time()
            try:
                await client.disconnect()
            except Exception:
                pass
            return None
        _client = client
        return client


async def _reset_client() -> None:
    """Drop the cached client after an operation fails on it."""
    global _client, _last_failure_at
    async with _get_lock():
        if _client is not None:
            try:
                await _client.disconnect()
            except Exception:
                pass
            _client = None
        _last_failure_at = asyncio.get_running_loop().time()


async def aclose() -> None:
    """Shut down the cached client. Call during graceful process shutdown."""
    global _client
    async with _get_lock():
        if _client is not None:
            try:
                await _client.disconnect()
            except Exception:
                pass
            _client = None


# Pairing still uses a fresh client — it's a one-shot and needs a null key.
@asynccontextmanager
async def _fresh_connect(host: str, client_key: str | None):
    client = WebOsClient(host, client_key, connect_timeout=CONNECT_TIMEOUT)
    await client.connect()
    try:
        yield client
    finally:
        try:
            await client.disconnect()
        except Exception:
            pass


async def pair(host: str) -> str:
    """Initial pairing — prompts the TV; user accepts; returns stored client_key.

    The TV must be on for pairing to succeed (screen prompt appears).
    """
    async with _fresh_connect(host, None) as client:
        key = client.client_key
        if not key:
            raise RuntimeError("Pairing failed — no client key returned (was the on-TV prompt accepted?)")
        save_config(host, key)
        return key


# -----------------------------------------------------------------------------
# State + control (via persistent client)
# -----------------------------------------------------------------------------

async def get_state(timeout: float = 2.0) -> dict[str, Any] | None:
    """Return the TV's current volume/mute/app/power. None if unreachable."""
    client = await _ensure_client()
    if client is None:
        return None
    try:
        async with asyncio.timeout(timeout):
            volume = await client.get_volume()
            muted = await client.get_muted()
            power = await client.get_power_state()
            app = await client.get_current_app()
            return {
                "volume": volume,
                "muted": bool(muted) if muted is not None else None,
                "power_state": power.get("state") if isinstance(power, dict) else None,
                "current_app_id": app.get("appId") if isinstance(app, dict) else None,
            }
    except Exception:
        await _reset_client()
        return None


async def set_volume(percent: int) -> int:
    v = max(0, min(100, int(percent)))
    client = await _ensure_client()
    if client is None:
        raise RuntimeError("LG TV unreachable.")
    try:
        await client.set_volume(v)
    except Exception:
        await _reset_client()
        raise
    return v


async def set_mute(muted: bool) -> bool:
    client = await _ensure_client()
    if client is None:
        raise RuntimeError("LG TV unreachable.")
    try:
        await client.set_mute(muted)
    except Exception:
        await _reset_client()
        raise
    return muted


async def volume_up() -> None:
    client = await _ensure_client()
    if client is None:
        raise RuntimeError("LG TV unreachable.")
    try:
        await client.volume_up()
    except Exception:
        await _reset_client()
        raise


async def volume_down() -> None:
    client = await _ensure_client()
    if client is None:
        raise RuntimeError("LG TV unreachable.")
    try:
        await client.volume_down()
    except Exception:
        await _reset_client()
        raise
