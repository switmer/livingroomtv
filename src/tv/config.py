from __future__ import annotations

import json
import os
import tomllib
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

CONFIG_DIR = Path(os.environ.get("TV_CONFIG_DIR", Path.home() / ".config" / "tv"))
CONFIG_FILE = CONFIG_DIR / "config.toml"
CREDENTIALS_FILE = CONFIG_DIR / "credentials.json"
ADDRESSES_FILE = CONFIG_DIR / "addresses.json"


def ensure_dir() -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)


def load_config() -> dict[str, Any]:
    if not CONFIG_FILE.exists():
        return {}
    with CONFIG_FILE.open("rb") as f:
        return tomllib.load(f)


def save_config(data: dict[str, Any]) -> None:
    ensure_dir()
    lines: list[str] = []
    for key, value in data.items():
        if isinstance(value, str):
            lines.append(f'{key} = "{value}"')
        elif isinstance(value, dict):
            lines.append(f"\n[{key}]")
            for k, v in value.items():
                if isinstance(v, str):
                    lines.append(f'{k} = "{v}"')
                else:
                    lines.append(f"{k} = {json.dumps(v)}")
        else:
            lines.append(f"{key} = {json.dumps(value)}")
    CONFIG_FILE.write_text("\n".join(lines) + "\n")


def default_device_id() -> str | None:
    return load_config().get("default_device_id")


def set_default_device_id(device_id: str) -> None:
    cfg = load_config()
    cfg["default_device_id"] = device_id
    save_config(cfg)


def load_credentials() -> dict[str, dict[str, str]]:
    if not CREDENTIALS_FILE.exists():
        return {}
    return json.loads(CREDENTIALS_FILE.read_text())


def save_credentials(creds: dict[str, dict[str, str]]) -> None:
    ensure_dir()
    CREDENTIALS_FILE.write_text(json.dumps(creds, indent=2))
    os.chmod(CREDENTIALS_FILE, 0o600)


def set_device_credentials(device_id: str, protocol_creds: dict[str, str]) -> None:
    all_creds = load_credentials()
    existing = all_creds.get(device_id, {})
    existing.update(protocol_creds)
    all_creds[device_id] = existing
    save_credentials(all_creds)


def get_device_credentials(device_id: str) -> dict[str, str]:
    return load_credentials().get(device_id, {})


# -----------------------------------------------------------------------------
# Cached device addresses (to skip pyatv.scan() on every connect)
# -----------------------------------------------------------------------------

def load_addresses() -> dict[str, dict[str, Any]]:
    if not ADDRESSES_FILE.exists():
        return {}
    try:
        return json.loads(ADDRESSES_FILE.read_text())
    except (json.JSONDecodeError, OSError):
        return {}


def save_addresses(data: dict[str, dict[str, Any]]) -> None:
    ensure_dir()
    ADDRESSES_FILE.write_text(json.dumps(data, indent=2, sort_keys=True))


def set_device_address(
    device_id: str,
    host: str,
    name: str,
    services: dict[str, dict[str, Any]],
) -> None:
    """Cache the LAN address + per-service metadata for a paired device.

    `services` is a dict of protocol_name → {port, identifier, properties}.
    The properties are the mDNS TXT-record fields that pyatv needs for
    protocol-feature detection; reconstructing without them causes
    Companion handshake to hang.
    """
    data = load_addresses()
    data[device_id] = {
        "host": host,
        "name": name,
        "services": services,
        "last_seen": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    save_addresses(data)


def get_device_address(device_id: str) -> dict[str, Any] | None:
    return load_addresses().get(device_id)


def clear_device_address(device_id: str) -> None:
    data = load_addresses()
    if device_id in data:
        del data[device_id]
        save_addresses(data)
