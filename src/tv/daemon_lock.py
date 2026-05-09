"""Single-daemon guard for `tv watch`.

One room = one daemon. The Swift menu-bar app has been spawning `tv watch`
opportunistically on relaunch/reconnect without always reaping the previous
one, which left us with 9 stale daemons emitting contradictory status. The
lock file is the authoritative source of "who owns the watcher for this
device right now".

Design:
- Per-device lock at `~/.config/tv/watch-<device>.lock` (the filename
  carries the device id so a future bedroom TV gets its own lock).
- `fcntl.flock(LOCK_EX | LOCK_NB)` — non-blocking exclusive. If the file
  is locked by a live process, we emit a structured `daemon_error` line
  and exit 0 (so the spawner sees a clean termination, not a crash).
- If the lockfile exists but its PID is dead (crash / SIGKILL), we treat
  it as stale, unlink, and retry the lock.
- Metadata (pid, started_at, device) is written as JSON inside the locked
  file so `ps` isn't needed for diagnostics.
"""
from __future__ import annotations

import fcntl
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from tv import config as cfg


def _lock_path(device_id: str | None) -> Path:
    safe = (device_id or "default").replace(":", "").replace("/", "_")
    return cfg.CONFIG_DIR / f"watch-{safe}.lock"


def _pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # Process exists but owned by another user — treat as alive.
        return True
    except OSError:
        return False
    return True


def _read_metadata(path: Path) -> dict[str, Any] | None:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None


def acquire_or_exit(device_id: str | None) -> int:
    """Acquire the per-device daemon lock or exit with a structured error.

    Returns the file descriptor of the held lock. Caller must keep the fd
    open for the life of the daemon; closing it (or process exit) releases
    the lock. The lockfile is unlinked on a graceful shutdown.

    On failure, emits a JSON `daemon_error` line to stdout (so the Swift
    spawner can read it on the same channel as status) and exits 0.
    """
    cfg.ensure_dir()
    path = _lock_path(device_id)

    # Two attempts: one fresh, one after clearing a stale lock.
    for attempt in range(2):
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            # Locked. Is the holder still alive?
            meta = _read_metadata(path)
            holder_pid = int(meta.get("pid", 0)) if meta else 0
            if attempt == 0 and holder_pid and not _pid_alive(holder_pid):
                # Stale — owner died without releasing. Clear and retry.
                try:
                    path.unlink()
                except FileNotFoundError:
                    pass
                continue
            _emit_already_running(meta)
            sys.exit(0)
        else:
            # Got the lock. Write fresh metadata and return.
            metadata = {
                "pid": os.getpid(),
                "started_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "device_id": device_id,
            }
            os.ftruncate(fd, 0)
            os.lseek(fd, 0, os.SEEK_SET)
            os.write(fd, json.dumps(metadata).encode())
            return fd

    # Fell through — shouldn't happen, but bail cleanly.
    _emit_already_running(None)
    sys.exit(0)


def release(fd: int, device_id: str | None) -> None:
    """Release the lock and unlink the lockfile. Safe to call multiple times."""
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    except OSError:
        pass
    try:
        os.close(fd)
    except OSError:
        pass
    try:
        _lock_path(device_id).unlink()
    except FileNotFoundError:
        pass
    except OSError:
        pass


def _emit_already_running(meta: dict[str, Any] | None) -> None:
    payload = {
        "type": "daemon_error",
        "v": 1,
        "code": "already_running",
        "holder": meta or {},
    }
    try:
        sys.stdout.write(json.dumps(payload) + "\n")
        sys.stdout.flush()
    except OSError:
        pass
