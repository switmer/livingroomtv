from __future__ import annotations

import asyncio
import ipaddress
import os
import sys
import time
import warnings
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import Any

# pyatv emits DeprecationWarnings from its service constructors; our usage is
# functionally correct and the filter chain isn't catching them cleanly across
# versions. Drop DeprecationWarnings at the display layer instead — this is
# robust regardless of what filter state pyatv installs internally.
_orig_showwarning = warnings.showwarning


def _filtered_showwarning(message, category, filename, lineno, file=None, line=None):
    if issubclass(category, DeprecationWarning):
        return
    _orig_showwarning(message, category, filename, lineno, file, line)


warnings.showwarning = _filtered_showwarning

import pyatv
from pyatv.const import Protocol
from pyatv.interface import AppleTV as AppleTVInterface, BaseConfig

from tv import config as cfg


PAIRABLE_PROTOCOLS = (Protocol.Companion, Protocol.AirPlay)


def _timing() -> bool:
    return os.environ.get("TV_TIMING") == "1"


def _ts(label: str, start: float) -> None:
    """Emit a timing line to stderr when TV_TIMING=1 is set."""
    if _timing():
        elapsed_ms = (time.perf_counter() - start) * 1000
        print(f"[tv timing] {label}: {elapsed_ms:.0f}ms", file=sys.stderr, flush=True)


@dataclass
class DiscoveredDevice:
    identifier: str
    name: str
    address: str
    model: str | None
    protocols: list[str]

    def to_dict(self) -> dict[str, Any]:
        return {
            "identifier": self.identifier,
            "name": self.name,
            "address": self.address,
            "model": self.model,
            "protocols": self.protocols,
        }


async def scan(timeout: float = 5.0, identifier: str | None = None) -> list[BaseConfig]:
    loop = asyncio.get_running_loop()
    kwargs: dict[str, Any] = {"timeout": timeout}
    if identifier:
        kwargs["identifier"] = identifier
    return await pyatv.scan(loop, **kwargs)


def summarize(atv_config: BaseConfig) -> DiscoveredDevice:
    return DiscoveredDevice(
        identifier=atv_config.identifier or "",
        name=atv_config.name,
        address=str(atv_config.address),
        model=getattr(atv_config, "model_str", None) or str(getattr(atv_config, "device_info", "") or "") or None,
        protocols=sorted({s.protocol.name for s in atv_config.services}),
    )


async def pair_device(device_id: str | None, pin_provider) -> dict[str, str]:
    """Pair with the target Apple TV. `pin_provider` is a callable returning the 4-digit pin string.

    Returns a dict of {protocol_name: credentials_string} for paired protocols.
    """
    configs = await scan(identifier=device_id) if device_id else await scan()
    if not configs:
        raise RuntimeError("No Apple TV found on the network.")
    atv_config = configs[0]

    paired: dict[str, str] = {}
    loop = asyncio.get_running_loop()

    for protocol in PAIRABLE_PROTOCOLS:
        if not atv_config.get_service(protocol):
            continue
        handler = await pyatv.pair(atv_config, protocol, loop)
        try:
            await handler.begin()
            pin = pin_provider(protocol.name)
            handler.pin(int(pin))
            await handler.finish()
            if handler.has_paired:
                paired[protocol.name] = handler.service.credentials
        finally:
            await handler.close()

    if not paired:
        raise RuntimeError("Pairing failed on all protocols.")

    device_id = atv_config.identifier or ""
    cfg.set_device_credentials(device_id, paired)
    _cache_address_from_config(device_id, atv_config)
    if not cfg.default_device_id():
        cfg.set_default_device_id(device_id)
    return paired


_SERVICE_BUILDERS = {
    "AirPlay": lambda port, ident, props, creds: pyatv.conf.AirPlayService(
        identifier=ident, port=port, credentials=creds, properties=props
    ),
    "Companion": lambda port, ident, props, creds: pyatv.conf.CompanionService(
        port=port, credentials=creds, properties=props
    ),
    "RAOP": lambda port, ident, props, creds: pyatv.conf.RaopService(
        identifier=ident, port=port, credentials=creds, properties=props
    ),
    "MRP": lambda port, ident, props, creds: pyatv.conf.MrpService(
        identifier=ident, port=port, credentials=creds, properties=props
    ),
    "DMAP": lambda port, ident, props, creds: pyatv.conf.DmapService(
        identifier=ident, port=port, credentials=creds, properties=props
    ),
}


def _build_config_from_cache(
    device_id: str,
    cache: dict[str, Any],
    creds: dict[str, str],
) -> BaseConfig | None:
    """Construct a pyatv config from cached service metadata without mDNS.

    Returns None when the cache lacks the richer service shape (e.g. from
    an older install that only stored ports). The caller should fall back
    to scan in that case.
    """
    services_cache: dict[str, dict[str, Any]] = cache.get("services") or {}
    if not services_cache or not all(
        isinstance(v, dict) and "port" in v and "properties" in v
        for v in services_cache.values()
    ):
        return None

    address = ipaddress.IPv4Address(cache["host"])
    conf = pyatv.conf.AppleTV(address=address, name=cache.get("name") or "Apple TV")
    for proto_name, meta in services_cache.items():
        builder = _SERVICE_BUILDERS.get(proto_name)
        if builder is None:
            continue
        try:
            svc = builder(
                int(meta["port"]),
                meta.get("identifier"),
                meta.get("properties") or {},
                creds.get(proto_name),
            )
            conf.add_service(svc)
        except Exception:
            continue
    return conf if conf.services else None


def _cache_address_from_config(device_id: str, atv_config: BaseConfig) -> None:
    """Persist freshly-scanned service metadata so the next connect skips scan."""
    services: dict[str, dict[str, Any]] = {}
    for service in atv_config.services:
        try:
            # Properties comes back as a Mapping; coerce to plain dict of str→str
            # so JSON serialization is clean.
            props = {str(k): str(v) for k, v in (service.properties or {}).items()}
            services[service.protocol.name] = {
                "port": int(service.port),
                "identifier": service.identifier,
                "properties": props,
            }
        except Exception:
            continue
    if services:
        cfg.set_device_address(
            device_id=device_id,
            host=str(atv_config.address),
            name=atv_config.name or "Apple TV",
            services=services,
        )


@asynccontextmanager
async def connect(device_id: str | None = None):
    target_id = device_id or cfg.default_device_id()
    if not target_id:
        raise RuntimeError("No paired device. Run `tv pair` first.")

    creds = cfg.get_device_credentials(target_id)
    if not creds:
        raise RuntimeError(f"No credentials stored for device {target_id}. Run `tv pair` first.")

    loop = asyncio.get_running_loop()
    atv_config: BaseConfig | None = None
    scanned = False  # track whether we had to fall back to scan

    # Fast path: build config from cached address, skip mDNS entirely.
    cached = cfg.get_device_address(target_id)
    if cached and cached.get("host"):
        try:
            t0 = time.perf_counter()
            atv_config = _build_config_from_cache(target_id, cached, creds)
            _ts("connect.build_from_cache", t0)
        except Exception:
            atv_config = None  # fall through to scan

    if atv_config is None:
        t0 = time.perf_counter()
        configs = await scan(identifier=target_id)
        _ts("connect.scan", t0)
        if not configs:
            raise RuntimeError(f"Device {target_id} not found on the network.")
        atv_config = configs[0]
        scanned = True
        for proto_name, cred in creds.items():
            try:
                protocol = Protocol[proto_name]
            except KeyError:
                continue
            atv_config.set_credentials(protocol, cred)
        _cache_address_from_config(target_id, atv_config)

    try:
        t0 = time.perf_counter()
        atv: AppleTVInterface = await pyatv.connect(atv_config, loop)
        _ts("connect.pyatv", t0)
    except Exception:
        # Cached address may be stale (IP changed / device replaced). Invalidate
        # the cache and retry once with a fresh scan.
        if not scanned:
            cfg.clear_device_address(target_id)
            t0 = time.perf_counter()
            configs = await scan(identifier=target_id)
            _ts("connect.rescan", t0)
            if not configs:
                raise RuntimeError(f"Device {target_id} not found on the network.")
            atv_config = configs[0]
            for proto_name, cred in creds.items():
                try:
                    protocol = Protocol[proto_name]
                except KeyError:
                    continue
                atv_config.set_credentials(protocol, cred)
            _cache_address_from_config(target_id, atv_config)
            t0 = time.perf_counter()
            atv = await pyatv.connect(atv_config, loop)
            _ts("connect.pyatv_retry", t0)
        else:
            raise

    atv._tv_name = atv_config.name  # stash for status()
    try:
        yield atv
    finally:
        atv.close()


async def wake(device_id: str | None = None) -> None:
    async with connect(device_id) as atv:
        await atv.power.turn_on()


async def sleep(device_id: str | None = None) -> None:
    async with connect(device_id) as atv:
        await atv.power.turn_off()


async def play(device_id: str | None = None) -> None:
    async with connect(device_id) as atv:
        await atv.remote_control.play()


async def pause(device_id: str | None = None) -> None:
    async with connect(device_id) as atv:
        await atv.remote_control.pause()


async def nav(key: str, device_id: str | None = None) -> None:
    async with connect(device_id) as atv:
        rc = atv.remote_control
        # Volume commands moved to atv.audio in newer pyatv; rc.volume_* is deprecated.
        if key == "volume_up":
            await atv.audio.volume_up()
            return
        if key == "volume_down":
            await atv.audio.volume_down()
            return
        action = {
            "menu": rc.menu,
            "home": rc.home,
            "up": rc.up,
            "down": rc.down,
            "left": rc.left,
            "right": rc.right,
            "select": rc.select,
            "play_pause": rc.play_pause,
            "next": rc.next,           # next track / next chapter
            "previous": rc.previous,   # previous track / previous chapter
            "skip_forward": rc.skip_forward,   # scrub forward within track
            "skip_backward": rc.skip_backward, # scrub backward within track
        }[key]
        await action()


_MUTE_STATE_FILE = cfg.CONFIG_DIR / "volume_before_mute"


async def set_volume(percent: float, device_id: str | None = None) -> float:
    """Set absolute volume, 0.0–100.0.

    Prefers the LG webOS adapter when paired — that hits actual TV-speaker
    volume. Falls through to the AirPlay output volume (mostly inert for
    HDMI-CEC setups, but harmless) when LG isn't configured or is offline.
    """
    percent = max(0.0, min(100.0, float(percent)))
    try:
        from tv.adapters import lg_webos
        if lg_webos.is_configured():
            await lg_webos.set_volume(int(round(percent)))
            return percent
    except Exception:
        pass
    async with connect(device_id) as atv:
        await atv.audio.set_volume(percent)
    return percent


async def get_volume(device_id: str | None = None) -> float | None:
    try:
        from tv.adapters import lg_webos
        if lg_webos.is_configured():
            state = await lg_webos.get_state()
            if state and state.get("volume") is not None:
                return float(state["volume"])
    except Exception:
        pass
    async with connect(device_id) as atv:
        return atv.audio.volume


async def mute(device_id: str | None = None) -> None:
    try:
        from tv.adapters import lg_webos
        if lg_webos.is_configured():
            await lg_webos.set_mute(True)
            return
    except Exception:
        pass
    # Fallback: AirPlay-output mute via pyatv (usually inert on HDMI-CEC setups,
    # but we still record the pre-mute level so `unmute` can restore it).
    async with connect(device_id) as atv:
        current = atv.audio.volume
        await atv.audio.set_volume(0.0)
    if current is not None and current > 0:
        cfg.ensure_dir()
        _MUTE_STATE_FILE.write_text(str(current))


async def unmute(device_id: str | None = None, default: float = 30.0) -> float:
    try:
        from tv.adapters import lg_webos
        if lg_webos.is_configured():
            await lg_webos.set_mute(False)
            return default  # LG doesn't restore a "previous" value; it just unmutes
    except Exception:
        pass
    target = default
    if _MUTE_STATE_FILE.exists():
        try:
            target = float(_MUTE_STATE_FILE.read_text().strip())
        except ValueError:
            pass
        _MUTE_STATE_FILE.unlink(missing_ok=True)
    async with connect(device_id) as atv:
        await atv.audio.set_volume(target)
    return target


async def watch(device_id: str | None = None, tick_interval: float = 30.0):
    """Async generator yielding a status dict on each push update + periodic tick."""
    async with connect(device_id) as atv:
        queue: asyncio.Queue[str] = asyncio.Queue()
        loop = asyncio.get_running_loop()

        class Listener:
            def playstatus_update(self, updater, playstatus):
                loop.call_soon_threadsafe(queue.put_nowait, "push")

            def playstatus_error(self, updater, exception):
                loop.call_soon_threadsafe(queue.put_nowait, "error")

        atv.push_updater.listener = Listener()
        atv.push_updater.start()

        async def render() -> dict[str, Any]:
            playing = await atv.metadata.playing()
            app_obj = getattr(atv.metadata, "app", None)
            power_state = getattr(atv.power, "power_state", None)
            try:
                atv_volume = atv.audio.volume
            except Exception:
                atv_volume = None

            lg_state: dict[str, Any] | None = None
            try:
                from tv.adapters import lg_webos
                if lg_webos.is_configured():
                    lg_state = await lg_webos.get_state(timeout=2.0)
            except Exception:
                lg_state = None

            if lg_state and lg_state.get("volume") is not None:
                volume = float(lg_state["volume"])
                volume_source = "lg"
                muted = lg_state.get("muted")
            else:
                volume = atv_volume
                volume_source = "appletv"
                muted = None

            return {
                "device": getattr(atv, "_tv_name", None) or getattr(atv, "name", None),
                "device_id": device_id or cfg.default_device_id(),
                "power": power_state.name.lower() if power_state else "unknown",
                "play_state": _enum_name(getattr(playing, "device_state", None)),
                "media_type": _enum_name(getattr(playing, "media_type", None)),
                "app": getattr(app_obj, "name", None) if app_obj else None,
                "title": getattr(playing, "title", None),
                "artist": getattr(playing, "artist", None),
                "album": getattr(playing, "album", None),
                "series": getattr(playing, "series_name", None),
                "position": getattr(playing, "position", None),
                "total_time": getattr(playing, "total_time", None),
                "volume": volume,
                "volume_source": volume_source,
                "speaker_output": "tv_speakers" if volume_source == "lg" else "airplay",
                "muted": muted,
            }

        # Emit initial state
        yield await render()

        try:
            while True:
                try:
                    await asyncio.wait_for(queue.get(), timeout=tick_interval)
                except asyncio.TimeoutError:
                    pass
                # Drain any coalesced events
                while not queue.empty():
                    queue.get_nowait()
                try:
                    yield await render()
                except Exception:
                    continue
        finally:
            atv.push_updater.stop()


async def artwork(device_id: str | None = None, width: int = 256, height: int = 256) -> bytes | None:
    async with connect(device_id) as atv:
        art = await atv.metadata.artwork(width=width, height=height)
        return art.bytes if art else None


# -----------------------------------------------------------------------------
# Daemon: long-running process that streams status AND accepts RPC on stdin.
# -----------------------------------------------------------------------------

async def _rpc_nav(atv: AppleTVInterface, key: str) -> dict[str, Any]:
    rc = atv.remote_control
    mapping = {
        "menu": rc.menu, "home": rc.home,
        "up": rc.up, "down": rc.down, "left": rc.left, "right": rc.right,
        "select": rc.select, "play_pause": rc.play_pause,
        "next": rc.next, "previous": rc.previous,
        "skip_forward": rc.skip_forward, "skip_backward": rc.skip_backward,
    }
    if key not in mapping:
        raise ValueError(f"unknown nav key: {key}")
    await mapping[key]()
    return {"ok": True, "key": key}


async def _rpc_set_volume(atv: AppleTVInterface, percent: float) -> dict[str, Any]:
    percent = max(0.0, min(100.0, float(percent)))
    try:
        from tv.adapters import lg_webos
        if lg_webos.is_configured():
            await lg_webos.set_volume(int(round(percent)))
            return {"volume": percent, "source": "lg"}
    except Exception:
        pass
    await atv.audio.set_volume(percent)
    return {"volume": percent, "source": "airplay"}


async def _rpc_mute(atv: AppleTVInterface) -> dict[str, Any]:
    try:
        from tv.adapters import lg_webos
        if lg_webos.is_configured():
            await lg_webos.set_mute(True)
            return {"muted": True, "source": "lg"}
    except Exception:
        pass
    current = atv.audio.volume
    await atv.audio.set_volume(0.0)
    if current is not None and current > 0:
        cfg.ensure_dir()
        _MUTE_STATE_FILE.write_text(str(current))
    return {"muted": True, "source": "airplay"}


async def _rpc_unmute(atv: AppleTVInterface, default: float = 30.0) -> dict[str, Any]:
    try:
        from tv.adapters import lg_webos
        if lg_webos.is_configured():
            await lg_webos.set_mute(False)
            return {"muted": False, "source": "lg"}
    except Exception:
        pass
    target = default
    if _MUTE_STATE_FILE.exists():
        try:
            target = float(_MUTE_STATE_FILE.read_text().strip())
        except ValueError:
            pass
        _MUTE_STATE_FILE.unlink(missing_ok=True)
    await atv.audio.set_volume(target)
    return {"muted": False, "volume": target, "source": "airplay"}


async def _rpc_launch_app(atv: AppleTVInterface, args: dict[str, Any]) -> dict[str, Any]:
    # Accept either bundle id directly or a display-name query to resolve.
    bundle_id = args.get("bundle_id")
    if not bundle_id:
        query = args.get("name", "")
        apps = await atv.apps.app_list()
        apps_list = [{"name": a.name, "id": a.identifier} for a in apps]
        result = resolve_app(apps_list, query)
        if isinstance(result, list):
            if not result:
                raise RuntimeError(f"No app matches '{query}'")
            raise RuntimeError(f"Ambiguous query '{query}'")
        bundle_id = result["id"]
    await atv.apps.launch_app(bundle_id)
    return {"ok": True, "bundle_id": bundle_id}


def _rpc_handlers() -> dict[str, Any]:
    """Keep the surface narrow. Scenes, AI, find stay on subprocess path."""
    async def _play_pause(atv, a): await atv.remote_control.play_pause(); return {"ok": True}
    async def _play(atv, a):       await atv.remote_control.play();       return {"ok": True}
    async def _pause(atv, a):      await atv.remote_control.pause();      return {"ok": True}
    async def _vol_up(atv, a):     await atv.audio.volume_up();           return {"ok": True}
    async def _vol_down(atv, a):   await atv.audio.volume_down();         return {"ok": True}
    async def _wake(atv, a):       await atv.power.turn_on();             return {"ok": True}
    async def _sleep(atv, a):      await atv.power.turn_off();            return {"ok": True}
    # No-op RPC used by Swift on popup-open to force an immediate fresh
    # status emission. The rpc_loop `queue.put_nowait("push")` after every
    # handler already does the kicking — this handler just exists so the
    # Swift side can invoke it without one of the mutating RPCs.
    async def _refresh(atv, a):    return {"ok": True}
    return {
        "play_pause": _play_pause,
        "play": _play,
        "pause": _pause,
        "nav": lambda atv, a: _rpc_nav(atv, a.get("key", "")),
        "volume_up": _vol_up,
        "volume_down": _vol_down,
        "set_volume": lambda atv, a: _rpc_set_volume(atv, a.get("percent", 0)),
        "mute": lambda atv, a: _rpc_mute(atv),
        "unmute": lambda atv, a: _rpc_unmute(atv),
        "wake": _wake,
        "sleep": _sleep,
        "launch_app": lambda atv, a: _rpc_launch_app(atv, a),
        "refresh": _refresh,
    }


async def run_daemon(
    device_id: str | None = None,
    tick_interval: float = 10.0,
    max_lifetime: float = 6 * 3600,
) -> None:
    """Long-running daemon: emits status on stdout, reads RPC requests on stdin.

    Wire protocol (line-delimited JSON):
      stdin  : {"type":"rpc_request","v":1,"id":"<uuid>","cmd":"...", "args":{...}}
      stdout : {"type":"status","v":1,...status fields...}
               {"type":"rpc_response","v":1,"id":"<uuid>","ok":true,"result":{...}}

    Staleness self-heal: when the LG adapter reports the display as Active but
    pyatv says the Apple TV is off/unknown for 2 consecutive ticks, we assume
    the pyatv connection has silently rotted (seen twice in the wild after
    ~24h uptime). Exit cleanly; the Swift host detects stream-end and
    respawns with a fresh connection. Also a hard `max_lifetime` cap as a
    backstop against rot modes we haven't characterized yet.

    The RPC surface is deliberately narrow (see `_rpc_handlers`). Scenes, AI,
    pair, find, and other multi-step or interactive commands stay on the
    subprocess-spawn path invoked by the Swift fallback.
    """
    import json as _json
    import time as _time

    started_at = _time.monotonic()
    stale_streak = 0
    STALE_STREAK_THRESHOLD = 2

    async with connect(device_id) as atv:
        queue: asyncio.Queue[str] = asyncio.Queue()
        loop = asyncio.get_running_loop()
        stdout_lock = asyncio.Lock()
        handlers = _rpc_handlers()

        class Listener:
            def playstatus_update(self, updater, playstatus):
                loop.call_soon_threadsafe(queue.put_nowait, "push")

            def playstatus_error(self, updater, exception):
                loop.call_soon_threadsafe(queue.put_nowait, "error")

        atv.push_updater.listener = Listener()
        atv.push_updater.start()

        async def emit(obj: dict[str, Any]) -> None:
            line = _json.dumps(obj, default=str) + "\n"
            async with stdout_lock:
                sys.stdout.write(line)
                sys.stdout.flush()

        async def render_status() -> dict[str, Any]:
            # Heuristic 2: tick-level liveness probe. pyatv can silently rot —
            # metadata calls return stale cached values instead of raising.
            # Wrapping the first real call in a short timeout turns a zombie
            # connection into an exception that status_loop can act on.
            playing = await asyncio.wait_for(atv.metadata.playing(), timeout=2.0)
            app_obj = getattr(atv.metadata, "app", None)
            power_state = getattr(atv.power, "power_state", None)
            try:
                atv_volume = atv.audio.volume
            except Exception:
                atv_volume = None

            lg_state: dict[str, Any] | None = None
            try:
                from tv.adapters import lg_webos
                if lg_webos.is_configured():
                    lg_state = await lg_webos.get_state(timeout=2.0)
            except Exception:
                lg_state = None

            if lg_state and lg_state.get("volume") is not None:
                volume = float(lg_state["volume"])
                volume_source = "lg"
                muted = lg_state.get("muted")
            else:
                volume = atv_volume
                volume_source = "appletv"
                muted = None

            # LG's webOS power_state is the source of truth for display power.
            # pyatv's `power` only reflects the Apple TV device state — it'll
            # read "on" while the physical screen is dark (e.g. Spotify music
            # continues after the TV turns off). When LG is paired, cross-
            # reference so the UI can distinguish "screen on" from "audio only".
            lg_power = lg_state.get("power_state") if lg_state else None
            if lg_power is not None:
                tv_display_on: bool | None = (lg_power == "Active")
            else:
                tv_display_on = None

            # Heuristic 1: LG overrule. LG's webOS client is per-call and
            # always fresh; pyatv is a persistent connection that can serve
            # stale metadata. When they disagree in the specific pattern
            # "LG says Active + pyatv says off/unknown", trust LG and emit
            # power='on'. This turns the failure mode "it says Off when it's
            # On" from a bug into a recovered correct state. Status_loop
            # still trips staleness detection and eventually reconnects, but
            # the user sees truth immediately.
            raw_power = power_state.name.lower() if power_state else "unknown"
            power = raw_power
            if lg_power == "Active" and raw_power in ("off", "unknown"):
                power = "on"

            return {
                "type": "status",
                "v": 1,
                "device": getattr(atv, "_tv_name", None) or getattr(atv, "name", None),
                "device_id": device_id or cfg.default_device_id(),
                "power": power,
                "raw_power": raw_power,  # pyatv's unoverruled report — for debugging
                "tv_display_on": tv_display_on,
                "lg_power_state": lg_power,
                "play_state": _enum_name(getattr(playing, "device_state", None)),
                "media_type": _enum_name(getattr(playing, "media_type", None)),
                "app": getattr(app_obj, "name", None) if app_obj else None,
                "title": getattr(playing, "title", None),
                "artist": getattr(playing, "artist", None),
                "album": getattr(playing, "album", None),
                "series": getattr(playing, "series_name", None),
                "position": getattr(playing, "position", None),
                "total_time": getattr(playing, "total_time", None),
                "volume": volume,
                "volume_source": volume_source,
                "speaker_output": "tv_speakers" if volume_source == "lg" else "airplay",
                "muted": muted,
            }

        def _is_stale(snap: dict[str, Any]) -> bool:
            # LG says the panel is actively lit but pyatv reports the Apple TV
            # as off/unknown. Check `raw_power` (unoverruled) so the LG
            # overrule in render_status doesn't mask the underlying rot.
            return (
                snap.get("lg_power_state") == "Active"
                and snap.get("raw_power") in ("off", "unknown")
            )

        # Heuristic 2 enforcement: consecutive render_status failures mean
        # pyatv is dead or hung. Exit cleanly after a small threshold so
        # Swift respawns us with a fresh connection.
        RENDER_FAIL_THRESHOLD = 3
        render_fail_streak = 0

        async def status_loop() -> None:
            nonlocal stale_streak, render_fail_streak
            try:
                await emit(await render_status())
            except Exception as e:
                print(f"[tv watch] initial render failed: {type(e).__name__}: {e}",
                      file=sys.stderr, flush=True)
            while True:
                # Backstop: hard lifetime cap.
                if _time.monotonic() - started_at > max_lifetime:
                    print(
                        f"[tv watch] max_lifetime ({max_lifetime:.0f}s) reached — "
                        "exiting for fresh respawn",
                        file=sys.stderr, flush=True,
                    )
                    return

                try:
                    await asyncio.wait_for(queue.get(), timeout=tick_interval)
                except asyncio.TimeoutError:
                    pass
                # Drain coalesced push events.
                while not queue.empty():
                    queue.get_nowait()

                try:
                    snap = await render_status()
                    await emit(snap)
                    render_fail_streak = 0
                except Exception as e:
                    render_fail_streak += 1
                    print(
                        f"[tv watch] render_status failed ({render_fail_streak}/"
                        f"{RENDER_FAIL_THRESHOLD}): {type(e).__name__}: {e}",
                        file=sys.stderr, flush=True,
                    )
                    if render_fail_streak >= RENDER_FAIL_THRESHOLD:
                        print(
                            "[tv watch] pyatv liveness probe failed repeatedly — "
                            "exiting for fresh respawn",
                            file=sys.stderr, flush=True,
                        )
                        return
                    continue

                if _is_stale(snap):
                    stale_streak += 1
                    if stale_streak >= STALE_STREAK_THRESHOLD:
                        print(
                            "[tv watch] pyatv staleness detected "
                            f"(LG=Active, raw_power={snap.get('raw_power')!r} x{stale_streak}) — "
                            "exiting for fresh respawn",
                            file=sys.stderr, flush=True,
                        )
                        return
                else:
                    stale_streak = 0

        async def rpc_loop() -> None:
            reader = asyncio.StreamReader()
            protocol = asyncio.StreamReaderProtocol(reader)
            await loop.connect_read_pipe(lambda: protocol, sys.stdin)
            while True:
                line = await reader.readline()
                if not line:
                    return  # stdin EOF — client closed pipe
                try:
                    req = _json.loads(line.decode("utf-8", errors="replace"))
                except _json.JSONDecodeError:
                    continue
                if req.get("type") != "rpc_request":
                    continue
                rid = req.get("id")
                cmd = req.get("cmd", "")
                args = req.get("args") or {}
                handler = handlers.get(cmd)
                if handler is None:
                    await emit({
                        "type": "rpc_response", "v": 1, "id": rid, "ok": False,
                        "error": f"unknown cmd: {cmd}",
                    })
                    continue
                try:
                    result = await handler(atv, args)
                    await emit({
                        "type": "rpc_response", "v": 1, "id": rid, "ok": True,
                        "result": result,
                    })
                    # Kick an immediate status re-emit so the client's UI can
                    # reconcile its optimistic override against real state
                    # within ~100ms instead of waiting up to `tick_interval`.
                    # LG-side commands (volume/mute) wouldn't fire the pyatv
                    # push_updater listener on their own, so this is necessary
                    # for those even when the Apple TV side does nothing.
                    queue.put_nowait("push")
                except Exception as e:
                    await emit({
                        "type": "rpc_response", "v": 1, "id": rid, "ok": False,
                        "error": f"{type(e).__name__}: {e}",
                    })

        # `status_loop` may return voluntarily (staleness / lifetime cap).
        # When it does, cancel `rpc_loop` so the daemon exits instead of
        # hanging on stdin-EOF forever.
        status_task = asyncio.create_task(status_loop())
        rpc_task = asyncio.create_task(rpc_loop())
        try:
            done, _pending = await asyncio.wait(
                {status_task, rpc_task}, return_when=asyncio.FIRST_COMPLETED
            )
            for t in {status_task, rpc_task} - done:
                t.cancel()
                try:
                    await t
                except (asyncio.CancelledError, Exception):
                    pass
            # Re-raise any exception from the completed task so it surfaces.
            for t in done:
                if exc := t.exception():
                    raise exc
        finally:
            try:
                atv.push_updater.stop()
            except Exception:
                pass
            try:
                from tv.adapters import lg_webos
                await lg_webos.aclose()
            except Exception:
                pass


async def list_apps(device_id: str | None = None) -> list[dict[str, str]]:
    async with connect(device_id) as atv:
        apps = await atv.apps.app_list()
        return sorted(
            [{"name": a.name, "id": a.identifier} for a in apps],
            key=lambda x: x["name"].lower(),
        )


def resolve_app(apps: list[dict[str, str]], query: str) -> dict[str, str] | list[dict[str, str]]:
    """Return a single app matching `query` or a list of candidates if ambiguous."""
    q = query.strip().lower()
    # exact bundle id wins
    for a in apps:
        if a["id"].lower() == q:
            return a
    # exact name
    for a in apps:
        if a["name"].lower() == q:
            return a
    # case-insensitive substring
    matches = [a for a in apps if q in a["name"].lower()]
    if len(matches) == 1:
        return matches[0]
    return matches


async def find(
    query: str,
    device_id: str | None = None,
) -> dict[str, object]:
    """Open Apple TV global Search and type `query`.

    Previous version polled `atv.keyboard.text_focus_state` for a NotFocused→
    Focused transition before typing. On tvOS 26 that API returns `Focused`
    immediately (stale cached state from wherever the TV was before), so the
    old code fired `text_set` before the Search app had actually mounted its
    text field — nothing typed, search page stayed empty.

    New flow is timing-based and always correct:
      1. Wake if asleep
      2. Home → short settle
      3. Launch TVSearch → 1.5s to let the Search UI fully mount
      4. Remote select → reveal / activate the text field (harmless if
         already focused; text_clear below wipes any stray character)
      5. text_clear + text_set
    """
    async with connect(device_id) as atv:
        # Wake if asleep — typing into a sleeping TV silently fails.
        power_state = getattr(atv.power, "power_state", None)
        if power_state is not None and power_state.name.lower() != "on":
            await atv.power.turn_on()
            await asyncio.sleep(1.0)

        await atv.remote_control.home()
        await asyncio.sleep(0.8)
        await atv.apps.launch_app("com.apple.TVSearch")
        await asyncio.sleep(1.5)          # Search UI mount
        await atv.remote_control.select() # activate text field
        await asyncio.sleep(0.5)
        await atv.keyboard.text_clear()
        await atv.keyboard.text_set(query)
        return {"query": query}


async def launch_app(query: str, device_id: str | None = None) -> dict[str, str]:
    apps = await list_apps(device_id)
    result = resolve_app(apps, query)
    if isinstance(result, list):
        if not result:
            raise RuntimeError(f"No app matches '{query}'. Try `tv app list`.")
        names = ", ".join(a["name"] for a in result)
        raise RuntimeError(f"Ambiguous query '{query}'. Matches: {names}")
    async with connect(device_id) as atv:
        await atv.apps.launch_app(result["id"])
    return result


async def status(device_id: str | None = None) -> dict[str, Any]:
    async with connect(device_id) as atv:
        playing = await atv.metadata.playing()
        power_state = getattr(atv.power, "power_state", None)
        power = power_state.name.lower() if power_state else "unknown"

        total = getattr(playing, "total_time", None)
        position = getattr(playing, "position", None)

        app_obj = getattr(atv.metadata, "app", None)
        atv_volume: float | None = None
        try:
            atv_volume = atv.audio.volume
        except Exception:
            pass

        # Merge LG TV-side state when paired and reachable. Falls through silently
        # if the LG adapter isn't configured or the TV is off.
        lg_state: dict[str, Any] | None = None
        try:
            from tv.adapters import lg_webos
            if lg_webos.is_configured():
                lg_state = await lg_webos.get_state()
        except Exception:
            lg_state = None

        if lg_state and lg_state.get("volume") is not None:
            volume = float(lg_state["volume"])
            volume_source = "lg"
            muted = lg_state.get("muted")
        else:
            volume = atv_volume
            volume_source = "appletv"
            muted = None

        lg_power = lg_state.get("power_state") if lg_state else None
        tv_display_on = (lg_power == "Active") if lg_power is not None else None

        return {
            "device": getattr(atv, "_tv_name", None) or getattr(atv, "name", None),
            "device_id": device_id or cfg.default_device_id(),
            "power": power,
            "tv_display_on": tv_display_on,
            "lg_power_state": lg_power,
            "play_state": _enum_name(getattr(playing, "device_state", None)),
            "media_type": _enum_name(getattr(playing, "media_type", None)),
            "app": getattr(app_obj, "name", None) if app_obj else None,
            "title": getattr(playing, "title", None),
            "artist": getattr(playing, "artist", None),
            "album": getattr(playing, "album", None),
            "series": getattr(playing, "series_name", None),
            "position": position,
            "total_time": total,
            "volume": volume,
            "volume_source": volume_source,
            "speaker_output": "tv_speakers" if volume_source == "lg" else "airplay",
            "muted": muted,
        }


def _enum_name(value) -> str | None:
    if value is None:
        return None
    return getattr(value, "name", str(value)).lower()
